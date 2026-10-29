// `lib/format/cbr_source.dart` 单测（`FMT-03`，`Q5` 退化口径）。
//
// 两条分支：
// · **退化分支（现值）**：默认 [UnavailableRarExtractor] → `load()` 抛
//   `cbrUnsupported`（导入即拒绝，与加密文件处理一致）；
// · **升级分支**：假 [RarExtractor] 注入 → 行为与 CBZ 一致（`FMT-03` ②：
//   每页一章 / 自然序 / 首页图封面），锁住将来的升级缝不被改坏。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/cbr_source.dart';
import 'package:mreader/platform/rar_extractor.dart';

/// 伪 PNG 字节（与 `cbz_source_test.dart` 同法：真实魔数 + 可辨识标签尾）。
Uint8List _pngTagged(String tag) => Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ...utf8.encode(tag),
    ]);

/// 假 RAR 解压实现：内存映射直出（验证「若支持，行为与 CBZ 一致」）。
class _FakeRar implements RarExtractor {
  _FakeRar(this.entries, this.payloads);

  final List<String> entries;
  final Map<String, Uint8List> payloads;

  @override
  bool get isAvailable => true;

  @override
  Future<List<String>> listImageEntries(Uint8List archiveBytes) async =>
      entries;

  @override
  Future<Uint8List?> readEntry(Uint8List archiveBytes, String entryName) async =>
      payloads[entryName];
}

void main() {
  group('退化分支（Q5：识别 + 明确提示，导入即拒绝）', () {
    test('sniffFormat(.cbr) → cbr', () {
      expect(
        sniffFormat(fileName: '漫画.cbr', bytes: Uint8List.fromList(<int>[1])),
        FormatKind.cbr,
      );
    });

    test('openBook(.cbr) → dart-cbr；load() 抛 cbrUnsupported（同加密文件处理）', () async {
      final BookSource source = await openBook(
        fileName: '漫画.cbr',
        bytes: Uint8List.fromList(<int>[0x52, 0x61, 0x72, 0x21]), // "Rar!"
      );
      expect(source.implId, 'dart-cbr');
      await expectLater(
        source.load(),
        throwsA(isA<MReaderFormatException>()
            .having((MReaderFormatException e) => e.code, 'code',
                FormatErrorCode.cbrUnsupported)
            .having((MReaderFormatException e) => e.message, 'message',
                contains('转换为 CBZ'))),
      );
      // 导入管道的 finally 仍会 dispose：这里同样要求 dispose 不抛。
      await source.dispose();
    });

    test('UnavailableRarExtractor 恒不可用，读取恒空', () async {
      const RarExtractor extractor = UnavailableRarExtractor();
      expect(extractor.isAvailable, isFalse);
      expect(await extractor.listImageEntries(Uint8List(0)), isEmpty);
      expect(await extractor.readEntry(Uint8List(0), 'x.png'), isNull);
    });

    test('退化模式 readResource 恒 null；dispose 幂等', () async {
      final CbrSource source = CbrSource(
        fileName: 'a.cbr',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(await source.readResource('p/1.png'), isNull);
      await source.dispose();
      await source.dispose();
    });
  });

  group('升级分支（FMT-03 ②：若支持，行为与 CBZ 一致）', () {
    final Map<String, Uint8List> payloads = <String, Uint8List>{
      'p/10.png': _pngTagged('10'),
      'p/2.png': _pngTagged('2'),
    };

    test('页表自然序、每页一章、content = imagePages', () async {
      final CbrSource source = CbrSource(
        fileName: 'a.cbr',
        bytes: Uint8List(0),
        extractor: _FakeRar(<String>['p/10.png', 'p/2.png'], payloads),
      );
      final List<Chapter> chapters = await source.chapters();
      // 人工推演：自然序 2.png < 10.png。
      expect(
        chapters.map((Chapter c) => c.href).toList(),
        <String>['p/2.png', 'p/10.png'],
      );
      expect(
        chapters.map((Chapter c) => c.title).toList(),
        <String>['第 1 页', '第 2 页'],
      );
      expect((await source.content(0)).imagePages, <String>['p/2.png']);
      expect(await source.readResource('p/10.png'), _pngTagged('10'));
      await source.dispose();
    });

    test('封面 = 自然序首页图（META-11 ①② 同 CBZ 口径）', () async {
      final CbrSource source = CbrSource(
        fileName: 'a.cbr',
        bytes: Uint8List(0),
        extractor: _FakeRar(<String>['p/10.png', 'p/2.png'], payloads),
      );
      final BookMeta meta = await source.load();
      final PendingCover cover = meta.cover as PendingCover;
      expect(cover.bytes, _pngTagged('2'), reason: '首页 = 自然序第一张 p/2.png');
      expect(cover.format, CoverFormat.png);
      await source.dispose();
    });

    test('能力可用但页表为空 → noImagePages', () async {
      final CbrSource source = CbrSource(
        fileName: 'a.cbr',
        bytes: Uint8List(0),
        extractor: _FakeRar(const <String>[], const <String, Uint8List>{}),
      );
      await expectLater(
        source.load(),
        throwsA(isA<MReaderFormatException>().having(
            (MReaderFormatException e) => e.code, 'code',
            FormatErrorCode.noImagePages)),
      );
      await source.dispose();
    });
  });
}
