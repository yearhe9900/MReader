// `lib/library/import_service_test.dart`：ImportService 单测。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/import_service.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';

import '../format/epub_builder.dart';
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
