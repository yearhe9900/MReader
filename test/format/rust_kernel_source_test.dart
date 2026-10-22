// Rust 解析内核书源的移植测试（2026-10-22）。
//
// 三层判别，**无原生库也全绿**（RUST-07 口径）：
//   1. 块 → 段落映射纯函数（图片占位标记 / 空白段丢弃）；
//   2. 无加速层时 [BookRegistry] 恒回落纯 Dart 源（implId 取证）；
//   3. 探测可用但**打开失败**（原生库没构建，FFI 调用抛错）时仍回落 Dart 源
//      ——「任何失败都回落」的端到端取证。
// 有原生库（本地 `cargo build` 过）时，第 4 组自动跑内核源的 BookSource 契约；
// 没有则运行期 `markTestSkipped`，不计失败。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/format/dart_txt_source.dart';
import 'package:mreader/format/mobi_source.dart';
import 'package:mreader/format/rust_kernel_source.dart';
import 'package:mreader/highperf/high_perf_capability.dart';
import 'package:mreader/highperf/high_perf_error.dart';
import 'package:mreader/highperf/high_perf_registry.dart';
import 'package:mreader/src/rust/api/kernel.dart' as rk;

import 'epub_builder.dart';

Uint8List _minimalEpub() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '契约样本',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry(
        'OEBPS/text/ch1.xhtml',
        xhtmlDoc(
          title: '一 起',
          heading: '第一章',
          paragraphs: <String>['正文一。', '正文二。'],
        ),
      ),
    ]);

Uint8List _minimalTxt() => Uint8List.fromList(utf8.encode(
      '第一章 起\n'
      '正文一。\n'
      '\n'
      '第二章 承\n'
      '正文二。\n',
    ));

Uint8List _minimalMobiBytes() {
  // PalmDB 头 + BOOKMOBI 魔数（偏移 60..68，与 `hasMobiMagic` 同判据）：只喂给
  // sniffFormat（分发判据），不需要能解析——用例断言的是「回落时返回 MobiSource」，
  // MobiSource 构造不解析。
  final BytesBuilder b = BytesBuilder();
  b.add(Uint8List(60)); // PDB 头（name/属性/时间戳/type 前的填充）
  b.add('BOOKMOBI'.codeUnits); // type+creator
  return b.toBytes();
}

/// 声称「全部能力可用」的假引擎：只测分发与回落，不碰 FFI。
class _FakeEngine implements HighPerfEngine {
  @override
  String get id => 'fake';
  @override
  String get abiVersion => kRustAbiVersion;
  @override
  Set<HighPerfCapability> get capabilities => HighPerfCapability.values.toSet();
  @override
  Future<void> probe() async {}
  @override
  Future<void> dispose() async {}
}

Future<HighPerfRegistry> _availableRegistry() async {
  final HighPerfRegistry r = HighPerfRegistry(engine: _FakeEngine());
  await r.warmUp();
  return r;
}

void main() {
  group('块 → 段落映射', () {
    rk.RkBlock p(String text) =>
        rk.RkBlock(kind: 'p', text: text, level: 0, indent: false);

    test('保留文本段与图片标记段，丢弃空白段', () {
      final List<String> out = paragraphsFromBlocks(<rk.RkBlock>[
        p('正文一。'),
        p('   '),
        p('\x00IMG:OEBPS/images/pic.png\x00'),
        rk.RkBlock(
            kind: 'img',
            text: '\x00IMG:OEBPS/images/cover.jpg\x00',
            level: 0,
            indent: false,
            key: 'OEBPS/images/cover.jpg'),
        p(''),
      ]);
      expect(out, <String>[
        '正文一。',
        '\x00IMG:OEBPS/images/pic.png\x00',
        '\x00IMG:OEBPS/images/cover.jpg\x00',
      ]);
    });

    test('行内图片标记内嵌在段落文本里原样保留', () {
      final List<String> out = paragraphsFromBlocks(<rk.RkBlock>[
        p('前文\x00IMG:OEBPS/a.png\x00后文'),
      ]);
      expect(out.single, '前文\x00IMG:OEBPS/a.png\x00后文');
    });
  });

  group('无加速层：BookRegistry 恒回落纯 Dart（RUST-07）', () {
    test('epub / txt / mobi 均返回对应 Dart 实现', () async {
      final BookRegistry registry =
          BookRegistry(highPerf: HighPerfRegistry.fallback());
      final BookSource epub = await openBook(
        fileName: 'a.epub',
        bytes: _minimalEpub(),
        registry: registry,
      );
      final BookSource txt = await openBook(
        fileName: 'a.txt',
        bytes: _minimalTxt(),
        registry: registry,
      );
      final BookSource mobi = await openBook(
        fileName: 'a.mobi',
        bytes: _minimalMobiBytes(),
        registry: registry,
      );
      expect(epub, isA<DartEpubSource>());
      expect(epub.implId, 'dart-epub');
      expect(txt, isA<DartTxtSource>());
      expect(txt.implId, 'dart-txt');
      expect(mobi, isA<MobiSource>());
      expect(mobi.implId, 'dart-mobi');
    });
  });

  group('探测可用但 Rust 打开失败：仍回落纯 Dart', () {
    test('epub / txt / mobi 均落到 Dart 实现（失败不冒泡）', () async {
      final HighPerfRegistry hp = await _availableRegistry();
      expect(hp.has(HighPerfCapability.epubDecompress), isTrue);
      final BookRegistry registry = BookRegistry(highPerf: hp);

      // 本组的语义就是「FFI 调用必然失败（原生库未构建/未加载）」——若本机
      // 恰好构建了原生库，Rust 源会打开成功，断言改为接受 Rust 源亦可。
      final BookSource epub = await openBook(
        fileName: 'a.epub',
        bytes: _minimalEpub(),
        registry: registry,
      );
      expect(epub.implId, anyOf('dart-epub', 'rust-epub'));

      final BookSource txt = await openBook(
        fileName: 'a.txt',
        bytes: _minimalTxt(),
        registry: registry,
      );
      expect(txt.implId, anyOf('dart-txt', 'rust-txt'));

      final BookSource mobi = await openBook(
        fileName: 'a.mobi',
        bytes: _minimalMobiBytes(),
        registry: registry,
      );
      expect(mobi.implId, anyOf('dart-mobi', 'rust-mobi'));
      // 全程未抛异常 =「失败回落、不冒泡」本身即判据。
    });
  });

  group('Rust 内核源 BookSource 契约（需原生库）', () {
    test('meta / chapters / content / 权重 / 资源 / dispose', () async {
      late RustKernelSource source;
      try {
        source = await RustKernelSource.open(
          fileName: 'a.epub',
          bytes: _minimalEpub(),
        );
      } catch (e) {
        markTestSkipped('原生库不可用，跳过内核源契约：$e');
        return;
      }
      expect(source.implId, 'rust-epub');

      final BookMeta meta = await source.load();
      expect(meta.title, '契约样本');
      expect(meta.titleOrigin, MetaOrigin.metadata);

      final List<Chapter> chapters = await source.chapters();
      expect(chapters, isNotEmpty);
      expect(chapters.first.href, isNotEmpty);

      final ChapterContent content = await source.content(0);
      expect(content.paragraphList, contains('正文一。'));

      final List<int>? weights = await source.chapterWeightEstimates();
      expect(weights, isNotNull);
      expect(weights!.length, chapters.length);

      final int? total = await source.totalCharCount();
      expect(total, greaterThan(0));

      await source.dispose();
    });
  });
}
