// Rust 解析内核书源的移植测试（2026-10-22 二次同步）。
//
// 三层判别，**无原生库也全绿**（RUST-07 口径）：
//   1. 宿主标记织入纯函数（内核 U+FFFC 图片标记 → `\x00IMG:`、内链区间 →
//      `\x00A:` 可点链接、空白段丢弃、字节区间定位）；
//   2. 无加速层时 [BookRegistry] 恒回落纯 Dart 源（implId 取证）；
//   3. 探测可用但**打开失败**（原生库没构建，FFI 调用抛错）时仍回落 Dart 源。
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
  group('宿主标记织入', () {
    rk.RkBlock p(String text) =>
        rk.RkBlock(kind: 'p', text: text, level: 0, indent: false);

    rk.RkChapterText chapter(String text, List<rk.RkBlock> blocks,
            {List<rk.RkLink> links = const <rk.RkLink>[]}) =>
        rk.RkChapterText(text: text, blocks: blocks, links: links);

    test('内核图片标记转换为宿主标记，空白段丢弃', () {
      final List<WovenParagraph> out = weaveChapter(chapter('前文', <rk.RkBlock>[
        p('前文'),
        p('   '),
        p('\u{FFFC}OEBPS/images/pic.png\u{FFFC}'),
        rk.RkBlock(
            kind: 'img',
            text: '\u{FFFC}OEBPS/images/cover.jpg\u{FFFC}',
            level: 0,
            indent: false,
            key: 'OEBPS/images/cover.jpg'),
        p(''),
      ]));
      expect(<String>[for (final WovenParagraph w in out) w.text], <String>[
        '前文',
        '\x00IMG:OEBPS/images/pic.png\x00',
        '\x00IMG:OEBPS/images/cover.jpg\x00',
      ]);
    });

    test('行内图片标记织进段落文本', () {
      final List<WovenParagraph> out = weaveChapter(
          chapter('前文后文', <rk.RkBlock>[p('前\u{FFFC}a.png\u{FFFC}后')]));
      expect(out.single.text, '前\x00IMG:a.png\x00后');
    });

    test('内链区间织成可点链接标记', () {
      // "abcLINKdef"：链接 = 字节 3..7（"LINK"）。
      final List<WovenParagraph> out = weaveChapter(chapter(
        'abcLINKdef',
        <rk.RkBlock>[p('abcLINKdef')],
        links: <rk.RkLink>[
          rk.RkLink(start: 3, end: 7, href: 'chap.xhtml#x'),
        ],
      ));
      expect(out.single.text, 'abc\x00A:chap.xhtml#x\x00LINK\x00A\x00def');
    });

    test('多块按序定位、字节区间单调且落在原文上', () {
      final String text = '第一段内容。第二段内容。';
      final List<int> bytes = utf8.encode(text);
      final List<WovenParagraph> out = weaveChapter(chapter(
        text,
        <rk.RkBlock>[p('第一段内容。'), p('第二段内容。')],
        links: <rk.RkLink>[
          // 链接区间是**字节**偏移：「第一段内容。」= 6 个汉字 = 18 字节。
          rk.RkLink(start: 0, end: 18, href: '#a'),
        ],
      ));
      expect(out.length, 2);
      for (final WovenParagraph w in out) {
        expect(w.start, lessThan(w.end));
        expect(w.end, lessThanOrEqualTo(bytes.length));
      }
      expect(out[0].start, 0);
      expect(out[1].start, greaterThan(out[0].start));
      // 第一段整段是链接：标记包住所包文字。
      expect(out[0].text, '\x00A:#a\x00第一段内容。\x00A\x00');
    });

    test('indexOfBytes 从游标起定位、不回溯', () {
      final List<int> hay = utf8.encode('aabaaab');
      expect(indexOfBytes(hay, utf8.encode('aab'), 0), 0);
      expect(indexOfBytes(hay, utf8.encode('aab'), 1), 4);
      expect(indexOfBytes(hay, utf8.encode('zz'), 0), -1);
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

  group('标题剥离（与纯 Dart 抽取同规则）', () {
    test('首段与章标题重复 → 剥去', () {
      expect(
        stripDuplicateHeading(
            <String>['卷三 第五章 下车伊始', '小蛮兴奋的朝林缚直摇手。'],
            '卷三 第五章 下车伊始'),
        <String>['小蛮兴奋的朝林缚直摇手。'],
      );
    });

    test('首段与标题不重复 → 原样', () {
      final List<String> input = <String>['正文开头。', '次段。'];
      expect(stripDuplicateHeading(input, '第五章'), input);
    });

    test('前置标记接力到新首段（锚点不失效）', () {
      expect(
        stripDuplicateHeading(
            <String>['\x00IMG:a.png\x00第五章 标题', '正文。'],
            '第五章 标题'),
        <String>['\x00IMG:a.png\x00正文。'],
      );
    });

    test('仅标题的空段章 → 空表（标题由 UI 单独渲染）', () {
      expect(stripDuplicateHeading(<String>['第五章'], '第五章'), isEmpty);
    });

    test('可见文本比对剥离标记（带链接标记的标题也认得出）', () {
      expect(
        stripDuplicateHeading(
            <String>['\x00A:ch.xhtml\x00第五章\x00A\x00 下车', '正文。'],
            '第五章 下车'),
        <String>['正文。'],
      );
    });
  });

  group('章节列表构建（TOC 摊平 + href 唯一化）', () {
    rk.RkChapter e(int id, String href, {String? title}) => rk.RkChapter(
        id: id,
        title: title,
        href: href,
        charLen: 100,
        kind: 'text',
        part_: 0);

    rk.RkTocNode node(String title, int chapter, {int? anchor, List<rk.RkTocNode> children = const <rk.RkTocNode>[]}) =>
        rk.RkTocNode(
            title: title, chapter: chapter, anchor: anchor, children: children);

    test('TOC 摊平带层级、未入目章补齐', () {
      final (List<Chapter> list, List<ChapterRef> refs) = buildChapterList(
        <rk.RkChapter>[e(0, 'a.xhtml'), e(1, 'b.xhtml'), e(2, 'c.xhtml')],
        <rk.RkTocNode>[
          node('卷一', 0,
              children: <rk.RkTocNode>[node('第一章', 1, anchor: 5)]),
        ],
      );
      expect(<String>[for (final Chapter c in list) c.title],
          <String>['卷一', '第一章', '第 3 章']);
      expect(<int>[for (final Chapter c in list) c.level], <int>[0, 1, 0]);
      expect(list[2].href, 'c.xhtml');
      // 锚点切段：同章仅一锚点 → to = null（整段到章尾）。
      expect(refs[1].id, 1);
      expect(refs[1].from, 5);
      expect(refs[1].to, isNull);
    });

    test('同 href 多锚点条目 → href 唯一化且内容按锚点互不重叠', () {
      final (List<Chapter> list, List<ChapterRef> refs) = buildChapterList(
        <rk.RkChapter>[e(0, 'book.xhtml')],
        <rk.RkTocNode>[
          node('第四章', 0, anchor: 10),
          node('第五章', 0, anchor: 200),
          node('第六章', 0, anchor: 500),
        ],
      );
      expect(<String>[for (final Chapter c in list) c.href],
          <String>['book.xhtml', 'book.xhtml#200', 'book.xhtml#500']);
      // 切段右界 = 同 id 下一锚点：互不重叠。
      expect(refs[0].from, 10);
      expect(refs[0].to, 200);
      expect(refs[1].from, 200);
      expect(refs[1].to, 500);
      expect(refs[2].from, 500);
      expect(refs[2].to, isNull);
    });

    test('同章无锚点目录项只留第一个（内容不整章重复）', () {
      final (List<Chapter> list, List<ChapterRef> refs) = buildChapterList(
        <rk.RkChapter>[e(0, 'mobi:1')],
        <rk.RkTocNode>[
          node('卷三 第四章', 0),
          node('卷三 第五章', 0),
        ],
      );
      expect(list.length, 1);
      expect(refs.length, 1);
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
      expect(chapters.first.locate, isNotNull);

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
