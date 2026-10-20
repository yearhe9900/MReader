// `DartEpubSource` / `openBook` / `parseToc` 的行为测试（M1-T02A）。
//
// 期望值来源：
//   1. `test/fixtures/*.epub` + `baseline.json`（M0 期固化的规范契约，**不改基线**）；
//   2. 本文件用 `epub_builder.dart` 现场构造的结构化样本（目录层级 / 加密标记 / 锚点），
//      其期望值先经 `.scratch/` 探针实测再写入断言。
//
// 本文件在 VM 上跑（`flutter test`），故允许用 `dart:io` 读 fixture；
// `lib/format/**` 与 `lib/epub/**` 仍保持零 `dart:io`。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/epub/epub_parser.dart';
import 'package:mreader/model/epub_book.dart';
import 'package:mreader/task/isolate_runner.dart';

import 'epub_builder.dart';

/// 记录派发的 spy runner（真实派发照走，仅旁路记录调用）。
class _RecordingRunner extends IsolateRunner {
  final List<(Object?, Object?, String?)> calls = <(Object?, Object?, String?)>[];

  @override
  Future<R> run<M, R>(IsolateTask<M, R> task, M message, {String? debugLabel}) {
    calls.add((task, message, debugLabel));
    return super.run<M, R>(task, message, debugLabel: debugLabel);
  }
}

/// 派发必失败的 runner（模拟 spawn 失败 / 派发层故障，验回落路径）。
class _FailingRunner extends IsolateRunner {
  @override
  Future<R> run<M, R>(IsolateTask<M, R> task, M message, {String? debugLabel}) =>
      throw StateError('isolate 派发失败（模拟）');
}

/// 篡改 flatTitles 的 runner（验 `chapters()` **确实咨询**预取表 / 未命中回退现场取）。
///
/// 真实解析照跑，只把 [EpubStructure.flatTitles] 换成注入值——让「预取表内容」与
/// 「现场解压所得」**故意不一致**，从而可断言消费方的取值优先级（预取表优先）。
class _FlatTitlesRunner extends IsolateRunner {
  _FlatTitlesRunner(this.replacement);

  final Map<String, String> replacement;

  @override
  Future<R> run<M, R>(
    IsolateTask<M, R> task,
    M message, {
    String? debugLabel,
  }) async {
    final R out = await super.run<M, R>(task, message, debugLabel: debugLabel);
    if (out is EpubParseOutcome && out.structure != null) {
      final EpubStructure s = out.structure!;
      final EpubStructure tampered = EpubStructure(
        title: s.title,
        author: s.author,
        language: s.language,
        description: s.description,
        creators: s.creators,
        fileName: s.fileName,
        sections: s.sections,
        toc: s.toc,
        coverCandidates: s.coverCandidates,
        flatTitles: replacement,
      );
      return EpubParseOutcome.ok(tampered) as R;
    }
    return out;
  }
}

final Directory _fixturesDir = Directory('test/fixtures');
final File _baselineFile = File('${_fixturesDir.path}/baseline.json');

/// href 的「可比较形态」：百分号解码 + 小写。
///
/// 口径与 `test/epub/epub_fixtures_test.dart` 保持一致：解析器给的是**按 OPF 声明**得到的
/// 逻辑路径，而 baseline 记录的是**包内真实条目**路径（`fx02b` / `fx03` 两类脏书二者形态不同）。
String _normHref(String href) {
  try {
    return Uri.decodeComponent(href).toLowerCase();
  } catch (_) {
    return href.toLowerCase();
  }
}

Uint8List? _readFixture(String name) {
  final File file = File('${_fixturesDir.path}/$name');
  if (!file.existsSync()) return null;
  return file.readAsBytesSync();
}

// ---------------------------------------------------------------------------
// 现场构造的样本（期望值由 .scratch 探针实测得出）
// ---------------------------------------------------------------------------

/// EPUB3：nav 位于 `nav/` 子目录，href 带 `../`，三层嵌套，另含一个无链接项。
Uint8List _epub3WithNav() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '三级目录',
          version: '3.0',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
            itemXml('c3', 'text/ch3.xhtml', 'application/xhtml+xml'),
            itemXml('nav', 'nav/nav.xhtml', 'application/xhtml+xml',
                properties: 'nav'),
          ].join(),
          spine: <String>[
            itemrefXml('c1'),
            itemrefXml('c2'),
            itemrefXml('c3'),
          ].join(),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一卷', paragraphs: <String>['卷首。'])),
      textEntry('OEBPS/text/ch2.xhtml',
          xhtmlDoc(title: '二 起', heading: '第一章', paragraphs: <String>['章首。'])),
      textEntry('OEBPS/text/ch3.xhtml',
          xhtmlDoc(title: '三 起', heading: '第一节', paragraphs: <String>['节首。'])),
      textEntry(
        'OEBPS/nav/nav.xhtml',
        navXhtml('<nav epub:type="toc"><ol>'
            '<li><a href="../text/ch1.xhtml">第一卷</a>'
            '<ol><li><a href="../text/ch2.xhtml">第一章</a>'
            '<ol><li><a href="../text/ch3.xhtml#c3">第一节</a></li></ol>'
            '</li></ol></li>'
            '<li><span>无链接项</span></li>'
            '</ol></nav>'),
      ),
    ]);

/// EPUB2：只有 `toc.ncx`，两层 `navPoint`。
Uint8List _epub2WithNcx() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: 'NCX目录',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
            itemXml('ncx', 'toc.ncx', 'application/x-dtbncx+xml'),
          ].join(),
          spine: <String>[itemrefXml('c1'), itemrefXml('c2')].join(),
          spineAttrs: ' toc="ncx"',
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '上 起', heading: '上部', paragraphs: <String>['上。'])),
      textEntry('OEBPS/text/ch2.xhtml',
          xhtmlDoc(title: '下 起', heading: '下部', paragraphs: <String>['下。'])),
      textEntry(
        'OEBPS/toc.ncx',
        ncxXml('<navPoint id="n1"><navLabel><text>上部</text></navLabel>'
            '<content src="text/ch1.xhtml"/>'
            '<navPoint id="n2"><navLabel><text>其下</text></navLabel>'
            '<content src="text/ch2.xhtml"/></navPoint>'
            '</navPoint>'),
      ),
    ]);

/// 没有任何目录的普通书（应降级为「按 spine 的平坦目录」）。
Uint8List _epubNoToc() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '无目录',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一章', paragraphs: <String>['正文。'])),
    ]);

/// 无目录且**无任何标题**的书（预取值为空串：已预取但无标题 -> 「第 1 章」占位）。
Uint8List _epubNoTocNoHeading() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '无标题章',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry(
          'OEBPS/text/ch1.xhtml', xhtmlDoc(paragraphs: <String>['无标题正文。'])),
    ]);

/// 无目录 + `linear="no"` 非主线章（验 skip 预取模式下命中标题的「（非主线）」后缀）。
Uint8List _epubNoTocNonLinear() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '非主线',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml') +
              itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1') + itemrefXml('c2', linear: 'no'),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一', heading: '主线章', paragraphs: <String>['主线内容。'])),
      textEntry('OEBPS/text/ch2.xhtml',
          xhtmlDoc(title: '二', heading: '附录章', paragraphs: <String>['附录内容。'])),
    ]);

/// nav 的 href 带 `#frag`，且锚点在章节中部。
Uint8List _epubWithFragment() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '带锚点',
          version: '3.0',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          ].join(),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry(
        'OEBPS/text/ch1.xhtml',
        xhtmlDoc(
          title: '一 起',
          rawBody: '<body><h1>第一章</h1><p>前段。</p>'
              '<p id="c1">锚点段。</p><p>后段。</p></body>',
        ),
      ),
      textEntry(
        'OEBPS/nav.xhtml',
        navXhtml('<nav epub:type="toc"><ol>'
            '<li><a href="text/ch1.xhtml#c1">第一章</a></li>'
            '</ol></nav>'),
      ),
    ]);

/// 带 `META-INF/encryption.xml` 的书。
///
/// [fontMediaType] 非空时，包内会多一个 `fonts/f1.ttf` 资源（用于「目标是字体」的判定）。
Uint8List _encrypted(
  String algorithm,
  String uri, {
  String? fontMediaType,
}) =>
    zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry('META-INF/encryption.xml', encryptionXml(algorithm, uri)),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '加密书',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            if (fontMediaType != null) itemXml('font1', 'fonts/f1.ttf', fontMediaType),
          ].join(),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一章', paragraphs: <String>['正文。'])),
      EpubEntry('OEBPS/fonts/f1.ttf', List<int>.filled(16, 0x11)),
    ]);

/// 与 [_epubWithFragment] 相同，但 nav 指向**不存在**的锚点（验「优雅退回整章」）。
Uint8List _epubWithMissingAnchor() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '坏锚点',
          version: '3.0',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          ].join(),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry(
        'OEBPS/text/ch1.xhtml',
        xhtmlDoc(
          title: '一 起',
          rawBody: '<body><h1>第一章</h1><p>前段。</p>'
              '<p id="c1">锚点段。</p><p>后段。</p></body>',
        ),
      ),
      textEntry(
        'OEBPS/nav.xhtml',
        navXhtml('<nav epub:type="toc"><ol>'
            '<li><a href="text/ch1.xhtml#nope">第一章</a></li>'
            '</ol></nav>'),
      ),
    ]);

/// nav 用**前缀命名空间**书写（html 宽松解析拿不到 `localName == 'nav'`），
/// 从而强制走 `epub_toc.dart` 的 **XML 回落路径**；
/// 其中父 `<li>` 自己**没有** `<a>`、只有嵌套 `<ol>`。
Uint8List _epubWithPrefixedNav() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: 'XML回落',
          version: '3.0',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
            itemXml('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          ].join(),
          spine: <String>[itemrefXml('c1'), itemrefXml('c2')].join(),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一章', paragraphs: <String>['一。'])),
      textEntry('OEBPS/text/ch2.xhtml',
          xhtmlDoc(title: '二 起', heading: '第二章', paragraphs: <String>['二。'])),
      textEntry(
        'OEBPS/nav.xhtml',
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<x:html xmlns:x="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops">'
        '<x:body><x:nav epub:type="toc"><x:ol>'
        '<x:li><x:span>无子项链接</x:span>'
        '<x:ol><x:li><x:a href="text/ch1.xhtml">子一</x:a></x:li>'
        '<x:li><x:a href="text/ch2.xhtml">子二</x:a></x:li></x:ol>'
        '</x:li>'
        '</x:ol></x:nav></x:body></x:html>',
      ),
    ]);

/// nav 与正文同文件写法：条目是**纯 fragment** 链接（`<a href="#c1">`）。
Uint8List _epubWithPureFragmentNav() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '纯fragment',
          version: '3.0',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('nav', 'nav.xhtml', 'application/xhtml+xml', properties: 'nav'),
          ].join(),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一章', paragraphs: <String>['一。'])),
      textEntry(
        'OEBPS/nav.xhtml',
        navXhtml('<nav epub:type="toc"><ol>'
            '<li><a href="#c1">第一章</a></li>'
            '</ol></nav>'),
      ),
    ]);

/// `CNT-05`：3 章 spine（c2 标 `linear="no"`），nav 目录**只列 ch1 / ch3**
/// ——linear=no 章未被目录覆盖，应按平坦目录补入并标注「（非主线）」。
Uint8List _epubLinearNoNotInToc() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '非主线未入目录',
          version: '3.0',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
            itemXml('c3', 'text/ch3.xhtml', 'application/xhtml+xml'),
            itemXml('nav', 'nav.xhtml', 'application/xhtml+xml',
                properties: 'nav'),
          ].join(),
          spine: <String>[
            itemrefXml('c1'),
            itemrefXml('c2', linear: 'no'),
            itemrefXml('c3'),
          ].join(),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一回', paragraphs: <String>['一。'])),
      textEntry(
          'OEBPS/text/ch2.xhtml',
          xhtmlDoc(
              title: '二 起',
              heading: '第二回',
              paragraphs: <String>['非主线正文。'])),
      textEntry('OEBPS/text/ch3.xhtml',
          xhtmlDoc(title: '三 起', heading: '第三回', paragraphs: <String>['三。'])),
      textEntry(
        'OEBPS/nav.xhtml',
        navXhtml('<nav epub:type="toc"><ol>'
            '<li><a href="text/ch1.xhtml">第一回</a></li>'
            '<li><a href="text/ch3.xhtml">第三回</a></li>'
            '</ol></nav>'),
      ),
    ]);

/// `CNT-05`：2 章 spine（c2 标 `linear="no"`），nav 目录**两章都列**
/// ——linear=no 章已被目录覆盖，只标注「（非主线）」、不重复补入。
Uint8List _epubLinearNoInToc() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '非主线已入目录',
          version: '3.0',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
            itemXml('nav', 'nav.xhtml', 'application/xhtml+xml',
                properties: 'nav'),
          ].join(),
          spine: <String>[
            itemrefXml('c1'),
            itemrefXml('c2', linear: 'no'),
          ].join(),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '上册', paragraphs: <String>['上。'])),
      textEntry(
          'OEBPS/text/ch2.xhtml',
          xhtmlDoc(
              title: '二 起',
              heading: '注释篇',
              paragraphs: <String>['注释正文。'])),
      textEntry(
        'OEBPS/nav.xhtml',
        navXhtml('<nav epub:type="toc"><ol>'
            '<li><a href="text/ch1.xhtml">上册</a></li>'
            '<li><a href="text/ch2.xhtml">注释篇</a></li>'
            '</ol></nav>'),
      ),
    ]);

/// `CNT-05`：spine 里 `linear="no"` 的**图片**仍按资源过滤剔除
/// ——linear=no 不是绕过「图片/字体/CSS 不当章节」过滤的通行证。
Uint8List _epubLinearNoImage() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '非主线图片',
          manifest: <String>[
            itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
            itemXml('cover', 'images/cover.png', 'image/png'),
          ].join(),
          spine: <String>[
            itemrefXml('c1'),
            itemrefXml('cover', linear: 'no'),
          ].join(),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一章', paragraphs: <String>['正文。'])),
      // PNG 魔数即可（media-type 命中后不会解压读取）。
      EpubEntry('OEBPS/images/cover.png', <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    ]);

void main() {
  // =====================================================================
  // A. 真实 fixture：`openBook` -> chapters() / content() 对齐 baseline
  // =====================================================================
  if (!_baselineFile.existsSync()) {
    test('fixture 回归：未找到 test/fixtures/baseline.json', () {}, skip: '缺少 baseline.json');
    return;
  }

  final Map<String, dynamic> root =
      jsonDecode(_baselineFile.readAsStringSync()) as Map<String, dynamic>;
  final Map<String, dynamic> baseline = root['baseline'] as Map<String, dynamic>;

  const List<String> openFixtures = <String>[
    'fx01_opf_in_item_dir.epub',
    'fx02a_percent_href_real_cjk_name.epub',
    'fx02b_percent_zip_entry_name.epub',
    'fx03_case_mismatch.epub',
    'fx04_gbk_no_decl.epub',
    'fx05_malformed_xhtml.epub',
    'fx06_linear_no.epub',
    'fx07a_cover_in_spine_with_media_type.epub',
    'fx07b_cover_in_spine_no_media_type.epub',
  ];

  group('openBook + baseline（真实脏书）', () {
    for (final String name in openFixtures) {
      final Uint8List? bytes = _readFixture(name);
      test(name, () async {
        final Map<String, dynamic> b = baseline[name] as Map<String, dynamic>;
        final BookSource source = await openBook(fileName: name, bytes: bytes!);
        expect(source.implId, 'dart-epub');

        final List<Chapter> chapters = await source.chapters();
        final Map<String, dynamic>? titleMap = b['预期章标题'] as Map<String, dynamic>?;
        final Map<String, dynamic>? textMap = b['预期每章文本'] as Map<String, dynamic>?;

        if (b.containsKey('预期章节(href)')) {
          final List<String> expected =
              (b['预期章节(href)'] as List<dynamic>).cast<String>();
          // 无 TOC 的 fixture：章节数 == spine 数，且顺序一致。
          expect(chapters.length, expected.length, reason: '$name 章节数量');
        }

        int indexOfHref(String href) => chapters.indexWhere(
            (Chapter c) => _normHref(c.href) == _normHref(href));

        if (titleMap != null) {
          for (final MapEntry<String, dynamic> e in titleMap.entries) {
            final int i = indexOfHref(e.key);
            expect(i, isNonNegative, reason: '$name 找不到章节 ${e.key}');
            expect(chapters[i].title, e.value, reason: '$name 章节 ${e.key} 的标题');
          }
        }

        if (textMap != null) {
          for (final MapEntry<String, dynamic> e in textMap.entries) {
            final int i = indexOfHref(e.key);
            expect(i, isNonNegative, reason: '$name 找不到章节 ${e.key}');
            final List<String> expectedParagraphs =
                (e.value as List<dynamic>).cast<String>();
            final ChapterContent content = await source.content(i);
            // 口径与 fixture 回归一致：baseline 记的是「含标题块在内的原文序列」。
            expect(
              <String>[chapters[i].title, ...content.paragraphList],
              expectedParagraphs,
              reason: '$name 章节 ${e.key} 的文本块序列',
            );
          }
        }

        await source.dispose();
      }, skip: bytes == null ? '缺少 fixture：$name' : null);
    }
  });

  // =====================================================================
  // B. 目录双路径
  // =====================================================================
  group('目录解析（RD-01）', () {
    test('EPUB3 nav：层级来自真实嵌套深度，href 相对 nav 文件解析', () async {
      final BookSource source =
          await openBook(fileName: 'nav3.epub', bytes: _epub3WithNav());
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.length, 3, reason: '无链接项不应产生目录条目');
      expect(
        chapters.map((Chapter c) => (c.title, c.level, c.href, c.locate)).toList(),
        <(String, int, String, String)>[
          ('第一卷', 0, 'OEBPS/text/ch1.xhtml', ''),
          ('第一章', 1, 'OEBPS/text/ch2.xhtml', ''),
          ('第一节', 2, 'OEBPS/text/ch3.xhtml', 'c3'),
        ],
        reason: 'nav 位于 nav/ 子目录且 href 带 ../，必须解析到 OEBPS/text/*',
      );
      await source.dispose();
    });

    test('EPUB2 toc.ncx：嵌套 navPoint 给出层级', () async {
      final BookSource source =
          await openBook(fileName: 'ncx2.epub', bytes: _epub2WithNcx());
      final List<Chapter> chapters = await source.chapters();

      expect(
        chapters.map((Chapter c) => (c.title, c.level, c.href)).toList(),
        <(String, int, String)>[
          ('上部', 0, 'OEBPS/text/ch1.xhtml'),
          ('其下', 1, 'OEBPS/text/ch2.xhtml'),
        ],
      );
      await source.dispose();
    });

    test('双路径皆无：降级为按 spine 的平坦目录', () async {
      final BookSource source =
          await openBook(fileName: 'noToc.epub', bytes: _epubNoToc());
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.length, 1);
      expect(chapters.single.level, 0);
      expect(chapters.single.locate, '');
      expect(chapters.single.href, 'OEBPS/text/ch1.xhtml');
      expect(chapters.single.title, '第一章', reason: '标题取自该章正文的 h1');
      await source.dispose();
    });

    test('XML 回落路径：父 li 无 <a> 时不产生错层条目（只自身不下钻嵌套 ol）', () async {
      final BookSource source = await openBook(
        fileName: 'prefixNav.epub',
        bytes: _epubWithPrefixedNav(),
      );
      final List<Chapter> chapters = await source.chapters();

      expect(
        chapters.map((Chapter c) => (c.title, c.level, c.href)).toList(),
        <(String, int, String)>[
          ('子一', 1, 'OEBPS/text/ch1.xhtml'),
          ('子二', 1, 'OEBPS/text/ch2.xhtml'),
        ],
        reason: '父 li 没有自己的 <a>，不应因下钻嵌套 ol 而多出一条 level=0 的条目',
      );
      await source.dispose();
    });

    test('纯 fragment 锚点（<a href="#c1">）：href 取目录文件自身 + locate', () async {
      final BookSource source = await openBook(
        fileName: 'pureFrag.epub',
        bytes: _epubWithPureFragmentNav(),
      );
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.single.href, 'OEBPS/nav.xhtml');
      expect(chapters.single.locate, 'c1');
      expect(chapters.single.title, '第一章');
      // nav 文件不在 spine 里：内容按同序号 section 兜底（best-effort，不抛异常）。
      expect((await source.content(0)).paragraphList, isNotEmpty);
      await source.dispose();
    });

    test('parseEpub 也会把目录一并解析进 EpubBook.toc', () async {
      final EpubBook book = await parseEpub(_epub2WithNcx(), fileName: 'ncx2');
      expect(book.toc.length, 2);
      expect(book.toc.first.title, '上部');
      final EpubBook noToc = await parseEpub(_epubNoToc(), fileName: 'noToc');
      expect(noToc.toc, isEmpty);
    });
  });

  // =====================================================================
  // C. fragment 定位（Chapter.locate）
  // =====================================================================
  group('章内定位 locate', () {
    test('locate 非空：content 从 fragment 起，前面段落被丢弃', () async {
      final BookSource source =
          await openBook(fileName: 'frag.epub', bytes: _epubWithFragment());
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.single.locate, 'c1');
      final ChapterContent content = await source.content(0);
      expect(content.paragraphs, <String>['锚点段。', '后段。']);
      await source.dispose();
    });

    test('锚点不存在时不报错，退回整章（含锚点之前的段落）', () async {
      final BookSource source = await openBook(
        fileName: 'frag.epub',
        bytes: _epubWithMissingAnchor(),
      );
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.single.locate, 'nope');
      final ChapterContent content = await source.content(0);
      expect(content.paragraphList, contains('前段。'),
          reason: '锚点丢失时应显示整章，而不是空内容或报错');
      await source.dispose();
    });
  });

  // =====================================================================
  // D. 加密拒绝（RD-05）
  // =====================================================================
  group('加密检测（RD-05）', () {
    const String aes = 'http://www.w3.org/2001/04/xmlenc#aes128-cbc';
    const String idpfFont = 'http://www.idpf.org/2008/embedding';
    const String adobeFont = 'http://ns.adobe.com/pdf/enc#RC';

    test('非字体目标 + AES -> 拒绝，且文案取自唯一来源', () async {
      final BookSource source = await openBook(
        fileName: 'enc.epub',
        bytes: _encrypted(aes, 'OEBPS/text/ch1.xhtml'),
      );
      await expectLater(
        source.chapters(),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.encryptedEpub,
        )),
      );
      expect(
        kFormatErrorMessages[FormatErrorCode.encryptedEpub],
        '这是一本加密的 EPUB，暂不支持打开。',
      );
    });

    test('字体混淆（IDPF）算法 -> 不算加密，正常打开', () async {
      final BookSource source = await openBook(
        fileName: 'enc.epub',
        bytes: _encrypted(idpfFont, 'OEBPS/fonts/f1.ttf',
            fontMediaType: 'font/ttf'),
      );
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.length, 1);
      await source.dispose();
    });

    test('Adobe 字体混淆 + 字体目标 -> 不算加密', () async {
      final BookSource source = await openBook(
        fileName: 'enc.epub',
        bytes: _encrypted(adobeFont, 'OEBPS/fonts/f1.ttf'),
      );
      expect((await source.chapters()).length, 1);
      await source.dispose();
    });

    test('AES 但目标恰是字体（manifest media-type 为 font/ttf）-> 不算加密', () async {
      final BookSource source = await openBook(
        fileName: 'enc.epub',
        bytes: _encrypted(aes, 'OEBPS/fonts/f1.ttf',
            fontMediaType: 'font/ttf'),
      );
      expect((await source.chapters()).length, 1);
      await source.dispose();
    });

    test('无 encryption.xml -> 不受影响', () async {
      final BookSource source =
          await openBook(fileName: 'noToc.epub', bytes: _epubNoToc());
      expect((await source.chapters()).length, 1);
      await source.dispose();
    });
  });

  // =====================================================================
  // E. 分发与错误文案
  // =====================================================================
  group('格式分发与错误', () {
    test('非 zip 字节 + .epub 扩展名 -> notZip 文案，不崩溃', () async {
      final BookSource source = await openBook(
        fileName: 'renamed.epub',
        bytes: Uint8List.fromList(utf8.encode('这不是一个 zip 文件')),
      );
      await expectLater(
        source.chapters(),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.notZip,
        )),
      );
      expect(
        kFormatErrorMessages[FormatErrorCode.notZip],
        '解压失败：该文件不是有效的 EPUB（EPUB 本质是一个 zip 包）。',
      );
    });

    test('是 zip 但缺 container.xml -> missingContainer', () async {
      final Uint8List bytes =
          zipEntries(<EpubEntry>[textEntry('hello.txt', 'not an epub')]);
      final BookSource source =
          await openBook(fileName: 'a.epub', bytes: bytes);
      await expectLater(
        source.chapters(),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.missingContainer,
        )),
      );
    });

    test('空字节 -> emptyFile', () async {
      final BookSource source =
          await openBook(fileName: 'a.epub', bytes: Uint8List(0));
      await expectLater(
        source.chapters(),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.emptyFile,
        )),
      );
    });

    test('sniffFormat：扩展名优先，魔数纠偏，其余 unsupported', () {
      expect(
        sniffFormat(fileName: 'a.epub', bytes: Uint8List.fromList(<int>[1, 2, 3])),
        FormatKind.epub,
        reason: '扩展名 .epub 优先（.zip 改名后要交给 EPUB 解析器给可读错误）',
      );
      expect(
        sniffFormat(
          fileName: 'a.txt',
          bytes: Uint8List.fromList(utf8.encode('纯文本')),
        ),
        FormatKind.txt,
      );
      expect(
        sniffFormat(
          fileName: 'noext',
          bytes: Uint8List.fromList(utf8.encode('纯文本')),
        ),
        FormatKind.txt,
        reason: '无扩展名但可判为文本 -> TXT 兜底',
      );
      expect(
        sniffFormat(
          fileName: 'a.bin',
          bytes: Uint8List.fromList(<int>[0x00, 0x01, 0x02, 0x03]),
        ),
        FormatKind.unsupported,
      );
    });
  });

  // =====================================================================
  // F. implId / capabilities / 搜索 / 字符数
  // =====================================================================
  group('实现标识与能力', () {
    test('implId 与 capabilities', () async {
      final BookSource source =
          await openBook(fileName: 'nav3.epub', bytes: _epub3WithNav());
      expect(source.implId, 'dart-epub');
      final SourceCapabilities caps = source.capabilities();
      expect(caps.hasImages, isTrue);
      expect(caps.hasFootnotes, isTrue);
      expect(caps.reflowable, isTrue);
      expect(caps.searchable, isTrue);
      expect(caps.charCountSupported, isTrue);
      await source.dispose();
    });

    test('load()：origin 为闭合枚举，封面为 NoCover（本提交只改类型不改语义）', () async {
      final BookSource source =
          await openBook(fileName: 'nav3.epub', bytes: _epub3WithNav());
      final BookMeta meta = await source.load();
      expect(meta.title, '三级目录');
      expect(meta.author, '作者');
      expect(meta.language, 'zh');
      expect(meta.cover, isA<NoCover>(), reason: 'nav3 无封面候选');
      expect(meta.titleOrigin, MetaOrigin.metadata);
      expect(meta.authorOrigin, MetaOrigin.metadata);
      expect(meta.coverOrigin, MetaOrigin.none);
      expect(meta.auto, isNotNull, reason: 'M1 阶段 auto 由解析写入、恒非空');
      await source.dispose();
    });

    test('构造不解析（惰性）：坏字节直到首次 chapters() 才抛错', () async {
      final DartEpubSource source = DartEpubSource(
        fileName: 'bad.epub',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(source.implId, 'dart-epub', reason: '构造本身不应触发解析');
      await expectLater(
        source.chapters(),
        throwsA(isA<MReaderFormatException>()),
      );
      await source.dispose();
      expect(source.isDisposed, isTrue);
    });

    test('totalCharCount 与 search（朴素子串 + 进度 + 可取消）', () async {
      final BookSource source =
          await openBook(fileName: 'nav3.epub', bytes: _epub3WithNav());

      // 段落字符数之和：卷首。/ 章首。/ 节首。 = 3 + 3 + 3
      expect(await source.totalCharCount(), 9);

      final List<SearchEvent> events = await source
          .search('卷', cancel: CancelToken())
          .toList();
      final List<SearchHit> hits =
          events.map((SearchEvent e) => e.hit).whereType<SearchHit>().toList();
      final List<double> progress =
          events.map((SearchEvent e) => e.progress).whereType<double>().toList();

      expect(hits.length, 1, reason: '「卷」只出现在第 1 章的正文与标题（标题不参与搜索）');
      expect(hits.single.chapterIndex, 0);
      expect(hits.single.chapterTitle, '第一卷');
      expect(hits.single.context, '卷首。');
      expect(progress.length, 3, reason: '每章结束回报一次进度');
      expect(progress.last, 1.0);

      // 取消后不再产出事件
      final CancelToken token = CancelToken()..cancel();
      expect(await source.search('卷', cancel: token).toList(), isEmpty);

      await source.dispose();
    });

    test('chapterCharCounts：逐章字数（T03 字数加权原料），Σ == totalCharCount',
        () async {
      final BookSource source =
          await openBook(fileName: 'nav3.epub', bytes: _epub3WithNav());

      // 三章各一段 3 字（卷首。/ 章首。/ 节首。）——与 totalCharCount=9 同口径。
      final List<int>? counts = await source.chapterCharCounts();
      expect(counts, <int>[3, 3, 3]);
      expect(
        counts!.fold<int>(0, (int a, int b) => a + b),
        await source.totalCharCount(),
        reason: 'Σ chapterCharCounts == totalCharCount（接口文档承诺）',
      );

      // 缓存：二次调用同一实例。
      expect(identical(counts, await source.chapterCharCounts()), isTrue);

      await source.dispose();
    });
  });

  // =====================================================================
  // G. dispose 契约（RUST-01：上层无感，绝不抛）
  // =====================================================================
  group('dispose 契约（RUST-01）', () {
    test('dispose 之后：各方法返回优雅空结果、不抛异常', () async {
      final DartEpubSource source =
          DartEpubSource(fileName: 'g.epub', bytes: _epub3WithNav());
      await source.dispose();

      final BookMeta meta = await source.load();
      expect(meta.title, '未命名');
      expect(meta.titleOrigin, MetaOrigin.none);
      expect(meta.authorOrigin, MetaOrigin.none);
      expect(meta.coverOrigin, MetaOrigin.none);
      expect(meta.cover, isA<NoCover>());
      // 释放后 load() 的返回须满足 BookMeta 自身的不变式（META-01）：
      // author 不得留空（统一兜底「未知作者」），且三个 origin 均为合法 MetaOrigin。
      expect(meta.author.isNotEmpty, isTrue);
      expect(
        <MetaOrigin>[meta.titleOrigin, meta.authorOrigin, meta.introOrigin],
        everyElement(isIn(MetaOrigin.values)),
      );
      expect(await source.chapters(), isEmpty);
      expect((await source.content(0)).isEmpty, isTrue);
      expect(await source.totalCharCount(), isNull);
      expect(await source.chapterCharCounts(), isNull);
      expect(await source.search('卷', cancel: CancelToken()).toList(), isEmpty);
    });

    test('dispose 竞态：content 已挂起后再 dispose，不抛（返回空）', () async {
      final DartEpubSource source =
          DartEpubSource(fileName: 'g.epub', bytes: _epub3WithNav());
      await source.chapters(); // 先准备，让 content 的 await 一定走「已就绪」分支
      final Future<ChapterContent> pending = source.content(0);
      await source.dispose();
      expect((await pending).isEmpty, isTrue);
    });

    test('dispose 之后不再重新解析（_bookOnce 返回 null，坏字节也不再抛）', () async {
      final DartEpubSource source = DartEpubSource(
        fileName: 'bad.epub',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );
      // 故意不先解析：dispose 后任何调用都不应触发解析，更不应抛出。
      await source.dispose();
      expect(await source.chapters(), isEmpty);
      expect((await source.load()).title, '未命名');
    });
  });

  // =====================================================================
  // H. linear="no" 可见并标注（CNT-05，M2a-T02）
  // =====================================================================
  group('linear="no" 可见并标注（CNT-05）', () {
    test('未被目录覆盖的 linear=no 章：按平坦目录补入并标注（验收①②）', () async {
      final BookSource source = await openBook(
        fileName: 'linNoA.epub',
        bytes: _epubLinearNoNotInToc(),
      );
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.length, 3, reason: '验收②：总数包含 linear=no 章');
      expect(
        chapters.map((Chapter c) => (c.title, c.href, c.locate)).toList(),
        <(String, String, String)>[
          ('第一回', 'OEBPS/text/ch1.xhtml', ''),
          ('第三回', 'OEBPS/text/ch3.xhtml', ''),
          ('第二回（非主线）', 'OEBPS/text/ch2.xhtml', ''),
        ],
        reason: '验收①：linear=no 项带「（非主线）」标注；'
            '目录项保持原序，补入项按平坦目录追加',
      );
      final ChapterContent content = await source.content(2);
      expect(content.paragraphList, <String>['非主线正文。'],
          reason: '补入项可正常读出正文');
      await source.dispose();
    });

    test('toc 已覆盖的 linear=no 章：同样标注、不重复补入（验收①）', () async {
      final BookSource source = await openBook(
        fileName: 'linNoB.epub',
        bytes: _epubLinearNoInToc(),
      );
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.length, 2, reason: '目录已含 linear=no 章，不应重复补入');
      expect(chapters[0].title, '上册');
      expect(chapters[1].title, '注释篇$kNonLinearTitleSuffix',
          reason: '验收①：toc 已含的 linear=no 项同样标注');
      expect(chapters[1].href, 'OEBPS/text/ch2.xhtml');
      expect(chapters[1].locate, '');
      expect((await source.content(1)).paragraphList, <String>['注释正文。']);
      await source.dispose();
    });

    test('常规书不回归：无 linear=no 时章节表不变、标题无标注', () async {
      final BookSource source = await openBook(
        fileName: 'nav3.epub',
        bytes: _epub3WithNav(),
      );
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.length, 3);
      expect(
        chapters
            .map((Chapter c) => (c.title, c.level, c.href, c.locate))
            .toList(),
        <(String, int, String, String)>[
          ('第一卷', 0, 'OEBPS/text/ch1.xhtml', ''),
          ('第一章', 1, 'OEBPS/text/ch2.xhtml', ''),
          ('第一节', 2, 'OEBPS/text/ch3.xhtml', 'c3'),
        ],
        reason: '与 B 组既有断言一致：主线书的章节表逐字不变',
      );
      for (final Chapter c in chapters) {
        expect(c.title.endsWith(kNonLinearTitleSuffix), isFalse);
      }
      await source.dispose();
    });

    test('linear=no 的图片仍按资源过滤剔除', () async {
      final BookSource source = await openBook(
        fileName: 'linNoImg.epub',
        bytes: _epubLinearNoImage(),
      );
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.length, 1,
          reason: 'linear=no 的封面 png 不当章节（资源过滤照常执行）');
      expect(chapters.single.href, 'OEBPS/text/ch1.xhtml');
      await source.dispose();
    });

    test('fx06 真实脏书：linear=no 章保留进章节表并标注（验收①②）', () async {
      final Uint8List? bytes = _readFixture('fx06_linear_no.epub');
      final BookSource source =
          await openBook(fileName: 'fx06_linear_no.epub', bytes: bytes!);
      final List<Chapter> chapters = await source.chapters();

      expect(chapters.length, 3, reason: '验收②：总数包含 linear=no 章');
      expect(chapters[0].title, '第一章');
      expect(chapters[1].title, '第二章$kNonLinearTitleSuffix',
          reason: '验收①：linear=no 项带「（非主线）」标注');
      expect(chapters[1].href, 'OEBPS/text/ch2.xhtml');
      expect(chapters[2].title, '第三章');
      await source.dispose();
    }, skip: _readFixture('fx06_linear_no.epub') == null
        ? '缺少 fixture：fx06_linear_no.epub'
        : null);
  });

  // =====================================================================
  // I. PERF-01 接线（M2a-T06）：解析经后台 isolate 任务 + 派发失败回落
  // =====================================================================
  group('PERF-01 接线（M2a-T06）', () {
    test('解析派发给后台 isolate 任务 parseEpubStructureTask（接线断言 + 去重）', () async {
      final _RecordingRunner runner = _RecordingRunner();
      final Uint8List bytes = _epub3WithNav();
      final DartEpubSource source = DartEpubSource(
        fileName: 'nav3.epub',
        bytes: bytes,
        runner: runner,
      );
      final BookMeta meta = await source.load();
      expect(meta.title, '三级目录', reason: '结构经信封回传、主 isolate 绑定后语义不变');

      expect(runner.calls, hasLength(1), reason: '解析任务只派发一次（Future 去重）');
      final (Object? task, Object? message, String? label) = runner.calls.single;
      expect(identical(task, parseEpubStructureTask), isTrue,
          reason: '派发的必须是纯数据任务 parseEpubStructureTask，'
              '而非含闭包、不可跨 isolate 的 parseEpubResult');
      expect(message, isA<EpubParseRequest>());
      final EpubParseRequest req = message as EpubParseRequest;
      expect(req.fileName, 'nav3.epub');
      expect(identical(req.bytes, bytes), isTrue);
      expect(label, isNotEmpty);

      await source.chapters();
      await source.content(0);
      expect(runner.calls, hasLength(1), reason: '后续调用复用缓存，不再派发');
      await source.dispose();
    });

    test('派发失败回落主 isolate：结果与业务错误语义均不变', () async {
      final _FailingRunner runner = _FailingRunner();
      final BookSource source = DartEpubSource(
        fileName: 'nav3.epub',
        bytes: _epub3WithNav(),
        runner: runner,
      );
      expect((await source.chapters()).length, 3, reason: '回落路径解析结果不变');
      expect((await source.content(0)).paragraphList, isNotEmpty);
      await source.dispose();

      final BookSource bad = DartEpubSource(
        fileName: 'bad.epub',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        runner: runner,
      );
      await expectLater(
        bad.chapters(),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.notZip,
        )),
        reason: '业务错误（信封）原样抛出，与未接 isolate 前同型同码',
      );
      await bad.dispose();
    });
  });

  // =====================================================================
  // J. flatTitles 预取（PERF-01 残余项）：无目录书平坦目录取标题移入解析 isolate
  // =====================================================================
  group('flatTitles 预取（PERF-01 残余项）', () {
    test('无目录书：解析期预取 href -> 标题（纯数据结构同样携带）', () async {
      final EpubStructure structure =
          await parseEpubStructure(_epubNoToc(), fileName: 'noToc.epub');
      expect(
        structure.flatTitles,
        <String, String>{'OEBPS/text/ch1.xhtml': '第一章'},
        reason: 'toc 为空 -> 预取表填充；值取自该章正文 h1',
      );

      final EpubBook book =
          await parseEpub(_epubNoToc(), fileName: 'noToc.epub');
      expect(book.flatTitles, structure.flatTitles,
          reason: 'EpubBook 原样携带预取表');
    });

    test('有目录书：不填充预取表（标题取自 toc，无需解压正文）', () async {
      final EpubStructure structure =
          await parseEpubStructure(_epub2WithNcx(), fileName: 'ncx2.epub');
      expect(structure.flatTitles, isEmpty);
    });

    test('无标题章：预取值为空串（已预取但无标题），章节表补「第 1 章」占位', () async {
      final EpubBook book =
          await parseEpub(_epubNoTocNoHeading(), fileName: 'noHead.epub');
      expect(
        book.flatTitles,
        <String, String>{'OEBPS/text/ch1.xhtml': ''},
        reason: '空标题也存：键在 = 已预取，查不到键才是未预取',
      );

      final BookSource source =
          await openBook(fileName: 'noHead.epub', bytes: _epubNoTocNoHeading());
      expect((await source.chapters()).single.title, '第 1 章');
      await source.dispose();
    });

    test('chapters() 咨询预取表：注入值压过现场解压所得', () async {
      final BookSource source = DartEpubSource(
        fileName: 'noToc.epub',
        bytes: _epubNoToc(),
        runner: _FlatTitlesRunner(
            <String, String>{'OEBPS/text/ch1.xhtml': '注入标题'}),
      );
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.single.title, '注入标题',
          reason: '预取表命中时不得回退现场解压（现场解压会得「第一章」）');
      await source.dispose();
    });

    test('预取表未命中：回退现场解压取标题（手造 EpubBook / 补入路径的旧行为）', () async {
      final BookSource source = DartEpubSource(
        fileName: 'noToc.epub',
        bytes: _epubNoToc(),
        runner: _FlatTitlesRunner(const <String, String>{}),
      );
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.single.title, '第一章',
          reason: 'miss -> 现场解压回退，与预取路径同值');
      await source.dispose();
    });

    // ----------------------------------------------------------------
    // 挂账 #6：prefetchFlatTitles=false（搜索路径跳过全书标题预取）
    // ----------------------------------------------------------------
    test('#6 skip 预取：无目录书 flatTitles 全占位（键在值空，不解压）', () async {
      final EpubStructure structure = await parseEpubStructure(
        _epubNoToc(),
        fileName: 'noToc.epub',
        prefetchFlatTitles: false,
      );
      expect(
        structure.flatTitles,
        <String, String>{'OEBPS/text/ch1.xhtml': ''},
        reason: '占位而非空 map：键在 = 已预取语义，防消费方 miss 回退现场解压',
      );

      // 键集必须与真预取完全一致（缺文件章两边都跳过）。
      final EpubStructure prefetched =
          await parseEpubStructure(_epubNoToc(), fileName: 'noToc.epub');
      expect(structure.flatTitles.keys.toSet(),
          prefetched.flatTitles.keys.toSet(),
          reason: '占位与真预取同键集（绑定期过滤一致）');
      expect(prefetched.flatTitles['OEBPS/text/ch1.xhtml'], '第一章',
          reason: '对照：真预取取 h1');
    });

    test('#6 skip 预取：chapters() 命中占位不回退现场解压（得「第 1 章」占位）', () async {
      final DartEpubSource source = DartEpubSource(
        fileName: 'noToc.epub',
        bytes: _epubNoToc(),
        prefetchFlatTitles: false,
      );
      expect((await source.chapters()).single.title, '第 1 章',
          reason: '占位空串命中：不得现场解压（现场解压会得「第一章」）——'
              '该路径只服务搜索，不消费章节表标题');
      await source.dispose();
    });

    test('#6 skip 预取：search() 命中标题仍是真实 h1，与预取模式同值', () async {
      Future<String?> firstHitTitle({required bool prefetch}) async {
        final DartEpubSource source = DartEpubSource(
          fileName: 'noToc.epub',
          bytes: _epubNoToc(),
          prefetchFlatTitles: prefetch,
        );
        String? title;
        await for (final SearchEvent event
            in source.search('正文', cancel: CancelToken())) {
          title = event.hit?.chapterTitle ?? title;
        }
        await source.dispose();
        return title;
      }

      expect(await firstHitTitle(prefetch: false), '第一章',
          reason: 'skip 模式：标题从 search() 扫描循环的 extractSection 零成本取');
      expect(await firstHitTitle(prefetch: true), '第一章',
          reason: '预取模式回归：两路同源同值（预取存的就是同一 h1）');
    });

    test('#6 skip 预取：非主线章命中标题保留「（非主线）」后缀', () async {
      final DartEpubSource source = DartEpubSource(
        fileName: 'nl.epub',
        bytes: _epubNoTocNonLinear(),
        prefetchFlatTitles: false,
      );
      final List<SearchEvent> events =
          await source.search('附录内容', cancel: CancelToken()).toList();
      final List<SearchHit> hits =
          events.map((SearchEvent e) => e.hit).nonNulls.toList();
      expect(hits, hasLength(1));
      expect(hits.single.chapterTitle, '附录章（非主线）',
          reason: '与 chapters() 的平坦目录同源同值（CNT-05 后缀不丢）');
      await source.dispose();
    });

    test('#6 skip 预取：有目录书 search 标题仍取自 toc（不受开关影响）', () async {
      final DartEpubSource source = DartEpubSource(
        fileName: 'ncx2.epub',
        bytes: _epub2WithNcx(),
        prefetchFlatTitles: false,
      );
      final List<SearchEvent> events =
          await source.search('上。', cancel: CancelToken()).toList();
      final List<SearchHit> hits =
          events.map((SearchEvent e) => e.hit).nonNulls.toList();
      expect(hits.single.chapterTitle, '上部',
          reason: '有 toc：命中标题取目录项，与预取开关无关（既有语义回归）');
      await source.dispose();
    });
  });
}
