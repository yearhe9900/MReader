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

import 'epub_builder.dart';

final Directory _fixturesDir = Directory('test/fixtures');
final File _baselineFile = File('${_fixturesDir.path}/baseline.json');

/// href 的「可比较形态」：百分号解码 + 小写。
///
/// 口径与 `test/epub_fixtures_test.dart` 保持一致：解析器给的是**按 OPF 声明**得到的
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
      expect(await source.chapters(), isEmpty);
      expect((await source.content(0)).isEmpty, isTrue);
      expect(await source.totalCharCount(), isNull);
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
}
