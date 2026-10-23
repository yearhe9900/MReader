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
import 'package:mreader/format/cbz_source.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/format/dart_txt_source.dart';
import 'package:mreader/format/mobi_source.dart';
import 'package:mreader/format/rust_kernel_source.dart';
import 'package:mreader/highperf/high_perf_capability.dart';
import 'package:mreader/highperf/high_perf_registry.dart';
import 'package:mreader/src/rust/api/kernel.dart' as rk;
import 'package:mreader/src/rust/frb_generated.dart';

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

/// 伪 PNG 字节（同 `cbz_source_test`：真实 PNG 魔数 + 可辨识标签尾）。
Uint8List _pngTagged(String tag) => Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ...utf8.encode(tag),
    ]);

/// CBZ 样本：乱序图片页 + macOS 垃圾 + 非图片条目（等价性对照与回落共用）。
/// 页序期望 = 自然序 `pages/1.png` → `pages/2.jpg` → `pages/10.jpg`。
Uint8List _cbzBytes() => zipEntries(<EpubEntry>[
      EpubEntry('pages/10.jpg', _pngTagged('10')),
      EpubEntry('__MACOSX/._1.png', _pngTagged('junk')),
      EpubEntry('pages/2.jpg', _pngTagged('2')),
      EpubEntry('pages/1.png', _pngTagged('1')),
      EpubEntry('ComicInfo.xml', utf8.encode('<ComicInfo/>')),
    ]);

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

/// 真内核组的 FRB 初始化（进程内只试一次）。
///
/// 2026-10-23 修：此前真内核组直接调 `RustKernelSource.open`，而 FRB 生成的
/// API 要求先 `RustLib.init()`——没初始化时 `open` 抛 “has not been
/// initialized”，整组被 `markTestSkipped` 吞掉（看起来跳过是「无原生库」，
/// 实际是「没 init」，用例从未真正跑过）。现在先 init，失败才判「原生库不可用」。
bool? _kernelReady;
Future<bool> _ensureKernel() async {
  final bool? cached = _kernelReady;
  if (cached != null) return cached;
  try {
    await RustLib.init();
    return _kernelReady = true;
  } catch (_) {
    return _kernelReady = false;
  }
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

  group('CBZ 页表构建（纯函数，口径对齐 CbzSource）', () {
    rk.RkChapter page(int id, String href) => rk.RkChapter(
        id: id,
        title: '第 ${id + 1} 页',
        href: href,
        charLen: 0,
        kind: 'image',
        part_: 0);

    test('过滤 macOS 垃圾 / 隐藏文件 / 非图片条目', () {
      final List<CbzPageRef> pages = buildCbzPageList(<rk.RkChapter>[
        page(0, 'pages/2.jpg'),
        page(1, '__MACOSX/._2.jpg'),
        page(2, '.DS_Store'),
        page(3, '._cover.png'),
        page(4, 'ComicInfo.xml'),
        page(5, 'info.txt'),
      ]);
      expect(<String>[for (final CbzPageRef p in pages) p.href],
          <String>['pages/2.jpg']);
    });

    test('归一化条目名（./ 前缀与反斜杠）', () {
      final List<CbzPageRef> pages =
          buildCbzPageList(<rk.RkChapter>[page(7, r'./a\b/1.png')]);
      expect(pages.single.href, 'a/b/1.png');
      expect(pages.single.kernelId, 7);
    });

    test('自然序排序：数值序且大小写不敏感（内核 natural_cmp 对齐 compareNatural）', () {
      // 内核 natural_cmp 大小写**敏感**（'Page10' 会排到 'page1' 前）；
      // 宿主用 compareNatural 重排后 = Dart 基线口径（大小写不敏感、数值序）。
      final List<CbzPageRef> pages = buildCbzPageList(<rk.RkChapter>[
        page(0, 'Page10.jpg'),
        page(1, 'page2.jpg'),
        page(2, 'page1.jpg'),
      ]);
      expect(<String>[for (final CbzPageRef p in pages) p.href],
          <String>['page1.jpg', 'page2.jpg', 'Page10.jpg']);
      // 内核页索引跟随排序重排（资源键映射不随位置错位）。
      expect(<int>[for (final CbzPageRef p in pages) p.kernelId],
          <int>[2, 1, 0]);
    });

    test('大小写撞名去重（小写键只收第一件）', () {
      final List<CbzPageRef> pages = buildCbzPageList(<rk.RkChapter>[
        page(0, 'Page1.png'),
        page(1, 'page1.png'),
        page(2, 'page2.png'),
      ]);
      expect(pages.length, 2);
      expect(
          pages
              .where((CbzPageRef p) => p.href.toLowerCase() == 'page1.png')
              .single
              .kernelId,
          0);
    });

    test('全为垃圾条目 → 空页表（上层抛 noImagePages、回落 CbzSource 报同型错）', () {
      expect(
        buildCbzPageList(<rk.RkChapter>[page(0, '__MACOSX/._1.png')]),
        isEmpty,
      );
    });
  });

  group('CBZ 择实现与回落', () {
    test('capabilityFor(cbz) = cbzPages；cbr / pdf 仍无候选', () {
      const BookRegistry registry = BookRegistry();
      expect(registry.capabilityFor(FormatKind.cbz),
          HighPerfCapability.cbzPages);
      expect(registry.capabilityFor(FormatKind.cbr), isNull);
      expect(registry.capabilityFor(FormatKind.pdf), isNull);
    });

    test('无加速层 → CbzSource', () async {
      final BookRegistry registry =
          BookRegistry(highPerf: HighPerfRegistry.fallback());
      final BookSource source = await openBook(
        fileName: 'a.cbz',
        bytes: _cbzBytes(),
        registry: registry,
      );
      expect(source, isA<CbzSource>());
      expect(source.implId, 'dart-cbz');
      await source.dispose();
    });

    test('探测可用但 Rust 打开失败 → CbzSource（失败不冒泡）', () async {
      final HighPerfRegistry hp = await _availableRegistry();
      expect(hp.has(HighPerfCapability.cbzPages), isTrue);
      final BookSource source = await openBook(
        fileName: 'a.cbz',
        bytes: _cbzBytes(),
        registry: BookRegistry(highPerf: hp),
      );
      // 本机恰好构建了原生库时 Rust 源打开成功亦可（与 epub 组同口径）。
      expect(source.implId, anyOf('dart-cbz', 'rust-cbz'));
      await source.dispose();
    });
  });

  group('Rust 内核源 BookSource 契约（需原生库）', () {
    test('meta / chapters / content / 权重 / 资源 / dispose', () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过内核源契约（RustLib.init 失败）');
        return;
      }
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

    test('CBZ：内核源与 CbzSource 等价（页表 / 内容 / 元数据 / 封面 / 资源）',
        () async {
      if (!await _ensureKernel()) {
        markTestSkipped('原生库不可用，跳过 CBZ 内核源契约（RustLib.init 失败）');
        return;
      }
      late RustKernelSource source;
      try {
        source = await RustKernelSource.open(
          fileName: '张三 - 样本.cbz',
          bytes: _cbzBytes(),
        );
      } catch (e) {
        markTestSkipped('原生库不可用，跳过 CBZ 内核源契约：$e');
        return;
      }
      final CbzSource dart =
          CbzSource(fileName: '张三 - 样本.cbz', bytes: _cbzBytes());
      expect(source.implId, 'rust-cbz');

      // 章节列表逐条对齐（href = 归一化条目名、标题「第 N 页」、自然序）。
      final List<Chapter> rustChapters = await source.chapters();
      final List<Chapter> dartChapters = await dart.chapters();
      expect(<String>[for (final Chapter c in rustChapters) c.href],
          <String>['pages/1.png', 'pages/2.jpg', 'pages/10.jpg']);
      expect(<String>[for (final Chapter c in rustChapters) c.href],
          <String>[for (final Chapter c in dartChapters) c.href]);
      expect(<String>[for (final Chapter c in rustChapters) c.title],
          <String>[for (final Chapter c in dartChapters) c.title]);

      // 内容 = 单元素图片页序列（元素 = 条目名）。
      for (int i = 0; i < rustChapters.length; i++) {
        final ChapterContent a = await source.content(i);
        final ChapterContent b = await dart.content(i);
        expect(a.imagePages, b.imagePages);
        expect(a.paragraphs, isNull);
      }

      // 元数据：META-04 文件名规则链（标题/作者）+ 封面 = 自然序首页原始字节。
      final BookMeta ma = await source.load();
      final BookMeta mb = await dart.load();
      expect(ma.title, mb.title);
      expect(ma.author, mb.author);
      expect(ma.titleOrigin, mb.titleOrigin);
      expect(ma.authorOrigin, mb.authorOrigin);
      expect((ma.cover as PendingCover).bytes,
          (mb.cover as PendingCover).bytes);
      expect((ma.cover as PendingCover).format,
          (mb.cover as PendingCover).format);

      // 资源字节逐页一致（读出的正是对应页的可辨识标签）。
      for (final Chapter c in rustChapters) {
        expect(await source.readResource(c.href),
            await dart.readResource(c.href));
      }
      await source.dispose();
      await dart.dispose();
    });
  });
}
