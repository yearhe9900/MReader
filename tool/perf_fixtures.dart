// 性能样本构造器（纯 Dart）。**样本不入库**——只由 `tool/gen_perf_fixtures.dart`
// 写到系统临时目录供人工测量，或由 `test/perf/*` 在内存里现造。
//
// 为什么单独成库：`tool/gen_perf_fixtures.dart`（命令行写盘）与 `test/perf/*`
// （内存单测）共用同一套构造器，避免样本定义出现两份。
//
// 依赖只有 `archive` / `dart:convert` / `dart:typed_data`。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 造一本 EPUB（`>= chapters` 章；可带若干「大体积但可忽略内容」的图片资源）。
///
/// - [chapters]：章数；
/// - [paragraphsPerChapter]：每章段落数（决定单章体量）；
/// - [imageCount] / [imageBytesEach]：非章节资源（图片）数量与单个未压缩字节数。
///   用于验证 `PERF-02` ①「非章节资源**不得**在结构解析后常驻」——图片是**高度可压缩**
///   的全零字节，解压后体积即 [imageBytesEach]，一旦被预解压就会显著抬高常驻内存。
Uint8List buildEpub({
  int chapters = 320,
  int paragraphsPerChapter = 12,
  int imageCount = 0,
  int imageBytesEach = 0,
}) {
  final Archive archive = Archive();
  void add(String path, List<int> bytes) {
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('mimetype', utf8.encode('application/epub+zip'));
  add(
    'META-INF/container.xml',
    utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>',
    ),
  );

  final StringBuffer manifest = StringBuffer();
  final StringBuffer spine = StringBuffer();
  for (int i = 1; i <= chapters; i++) {
    final String id = 'c$i';
    manifest.writeln(
      '<item id="$id" href="text/ch$i.xhtml" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.writeln('<itemref idref="$id"/>');
  }
  for (int i = 1; i <= imageCount; i++) {
    manifest.writeln(
      '<item id="img$i" href="img/p$i.png" media-type="image/png"/>',
    );
  }
  add(
    'OEBPS/content.opf',
    utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>性能样本</dc:title>'
      '<dc:creator>生成器</dc:creator>'
      '<dc:language>zh</dc:language>'
      '</metadata>'
      '<manifest>$manifest</manifest>'
      '<spine>$spine</spine>'
      '</package>',
    ),
  );

  for (int i = 1; i <= chapters; i++) {
    final StringBuffer body = StringBuffer('<h1>第$i章 标题</h1>');
    for (int p = 1; p <= paragraphsPerChapter; p++) {
      body.write(
        '<p>第$i章第$p段正文内容，用于产生可解析的段落结构并撑大单章体量。</p>',
      );
    }
    add(
      'OEBPS/text/ch$i.xhtml',
      utf8.encode(
        '<html xmlns="http://www.w3.org/1999/xhtml">'
        '<head><title>第$i章</title></head>'
        '<body>$body</body></html>',
      ),
    );
  }

  if (imageCount > 0 && imageBytesEach > 0) {
    // 全零字节：zip 压缩后极小，但解压后体积 = imageBytesEach。
    final Uint8List img = Uint8List(imageBytesEach);
    for (int i = 1; i <= imageCount; i++) {
      add('OEBPS/img/p$i.png', img);
    }
  }

  final List<int>? encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

/// 造一本「单章超长」的 EPUB（`PERF-03`：正文必须**逐段**取出，而不是一条巨型文本）。
///
/// [paragraphs] 段，每段约 [charsPerParagraph] 字符 → 单章总字符数 ≈ 二者之积。
Uint8List buildLongChapterEpub({
  int paragraphs = 1200,
  int charsPerParagraph = 100,
}) {
  final Archive archive = Archive();
  void add(String path, List<int> bytes) {
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('mimetype', utf8.encode('application/epub+zip'));
  add(
    'META-INF/container.xml',
    utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>',
    ),
  );
  add(
    'OEBPS/content.opf',
    utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>超长单章</dc:title><dc:creator>生成器</dc:creator>'
      '<dc:language>zh</dc:language></metadata>'
      '<manifest><item id="c1" href="text/ch1.xhtml" '
      'media-type="application/xhtml+xml"/></manifest>'
      '<spine><itemref idref="c1"/></spine></package>',
    ),
  );

  final String filler = '字' * charsPerParagraph;
  final StringBuffer body = StringBuffer('<h1>超长章</h1>');
  for (int p = 1; p <= paragraphs; p++) {
    body.write('<p>第$p段$filler</p>');
  }
  add(
    'OEBPS/text/ch1.xhtml',
    utf8.encode(
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>超长章</title>'
      '</head><body>$body</body></html>',
    ),
  );

  final List<int>? encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

/// 造一段大 TXT（`>= chapters` 章；体量由段落数撑起，默认约 20MB+）。
///
/// 每章以「第N章」开头（满足 `DartTxtSource` 的分章规则），其余为足量正文。
Uint8List buildTxt({int chapters = 800, int paragraphsPerChapter = 300}) {
  final StringBuffer out = StringBuffer();
  for (int c = 1; c <= chapters; c++) {
    out.writeln('第$c章 标题$c');
    for (int p = 1; p <= paragraphsPerChapter; p++) {
      out.writeln('这是第$c章的第$p段正文内容，用于撑大样本体积并产生足量章节。');
    }
  }
  return Uint8List.fromList(utf8.encode(out.toString()));
}
