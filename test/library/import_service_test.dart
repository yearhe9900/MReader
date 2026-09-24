// `lib/library/import_service_test.dart`：ImportService 单测。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/import_service.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/platform/pdf_engine.dart';

import '../format/epub_builder.dart';
import '../format/pdf_fakes.dart';
import '../meta/meta_fixtures.dart';

/// 临时目录实现 [AppPaths]，仅用于测试。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir = Directory(
      '${_root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}

/// 最简 TXT 内容（两行，足够通过 sniffFormat 的文本检测）。
Uint8List _txtBytes([String content = '这是正文内容。\n第二行。']) =>
    Uint8List.fromList(content.codeUnits);

void main() {
  group('ImportService', () {
    late Directory tempDir;
    late ImportService service;
    late FileCoverStore coverStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_imp_');
      final AppPaths paths = _TestAppPaths(tempDir);
      coverStore = FileCoverStore(paths);
      service = ImportService(paths, coverStore);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('computeBookId 是确定性的（相同字节 → 相同 ID）', () {
      final Uint8List bytes = _txtBytes();
      final String a = ImportService.computeBookId(bytes);
      final String b = ImportService.computeBookId(bytes);
      expect(a, b);
      expect(a, hasLength(16));
    });

    test('computeBookId：不同字节 → 不同 ID', () {
      final String a = ImportService.computeBookId(_txtBytes('内容A'));
      final String b = ImportService.computeBookId(_txtBytes('内容B'));
      expect(a, isNot(b));
    });

    test('TXT 导入：记录字段正确 + 副本文件存在', () async {
      final Uint8List bytes = _txtBytes('这是测试正文。');
      final BookRecord record = await service.import(
        bytes: bytes,
        fileName: '测试书.txt',
      );

      expect(record.bookId, ImportService.computeBookId(bytes));
      expect(record.fileName, '测试书.txt');
      expect(record.format, 'txt');
      expect(record.title, isNotEmpty);
      expect(record.author, isNotEmpty);
      expect(record.cover, isA<NoCover>());
      expect(record.importedAt, greaterThan(0));

      // 副本文件应存在
      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}${record.filePath}',
      );
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), bytes);
    });

    test('不支持的格式抛 MReaderFormatException', () async {
      // 假装是 zip 文件（PK 头）→ sniffFormat 返回 unsupported
      final Uint8List zipBytes = Uint8List.fromList(<int>[
        0x50, 0x4B, 0x03, 0x04, // PK local file header
        ...List<int>.filled(100, 0x00),
      ]);
      expect(
        () => service.import(bytes: zipBytes, fileName: 'book.zip'),
        throwsA(isA<MReaderFormatException>()),
      );
    });

    test('MOBI 系导入即拒绝：mobiUnsupported（FMT-06 ①；M2b-T05 接入解析器前）',
        () async {
      // PalmDB `BOOKMOBI` 最小复刻（同 test/format/sniffer_test.dart 夹具）：
      // 偏移 0..32 可打印 name（AZW3 实测 `epubor.c`）+ NUL，偏移 60..68 = BOOKMOBI。
      final Uint8List mobiBytes = Uint8List(80);
      const List<int> name = <int>[
        0x65, 0x70, 0x75, 0x62, 0x6F, 0x72, 0x2E, 0x63, // "epubor.c"
      ];
      mobiBytes.setRange(0, name.length, name);
      const List<int> tag = <int>[
        0x42, 0x4F, 0x4F, 0x4B, 0x4D, 0x4F, 0x42, 0x49, // "BOOKMOBI"
      ];
      mobiBytes.setRange(60, 68, tag);

      // 改名 .txt——魔数压过后缀识别为 MOBI 系；导入即拒绝，口径区分
      // 「这是 MOBI，还没支持」（mobiUnsupported）与「不认识的格式」。
      expect(
        () => service.import(bytes: mobiBytes, fileName: '牧神记.txt'),
        throwsA(
          isA<MReaderFormatException>().having(
            (MReaderFormatException e) => e.code,
            'code',
            FormatErrorCode.mobiUnsupported,
          ),
        ),
      );
    });

    test('CBZ 导入：format=cbz、封面物化 StoredCover（META-11 ①）、副本落盘',
        () async {
      final Uint8List bytes = zipEntries(<EpubEntry>[
        EpubEntry('p/2.png', kTinyPng),
        EpubEntry('p/1.png', kTinyPng),
      ]);
      final BookRecord record = await service.import(
        bytes: bytes,
        fileName: '测试漫画.cbz',
      );
      expect(record.format, 'cbz');
      expect(record.filePath.endsWith('.cbz'), isTrue);
      expect(
        record.cover,
        isA<StoredCover>(),
        reason: 'PendingCover → CoverStore.materialize（META-06）',
      );
      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}${record.filePath}',
      );
      expect(await file.exists(), isTrue);
    });

    test('PDF 导入：format=pdf、封面物化 StoredCover（META-10 ①）、副本落盘',
        () async {
      // 渲染内核经组合根注入（`META-10` ③）；本用例注入假引擎，测试离线可跑。
      PdfEngineProvider.current = FakePdfEngine(pageCount: 3);
      addTearDown(
        () => PdfEngineProvider.current = const UnavailablePdfEngine(),
      );
      final BookRecord record = await service.import(
        bytes: minimalPdfBytes(),
        fileName: '小狗钱钱.pdf',
      );
      expect(record.format, 'pdf');
      expect(record.filePath.endsWith('.pdf'), isTrue);
      expect(
        record.cover,
        isA<StoredCover>(),
        reason: 'PendingCover → CoverStore.materialize（META-06）',
      );
      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}${record.filePath}',
      );
      expect(await file.exists(), isTrue);
    });

    test('CBR 导入即拒绝：抛 cbrUnsupported（Q5 与加密文件处理一致）', () async {
      final Uint8List rarLike =
          Uint8List.fromList(<int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]); // "Rar!"
      expect(
        () => service.import(bytes: rarLike, fileName: '漫画.cbr'),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.cbrUnsupported,
        )),
      );
    });
  });
}
