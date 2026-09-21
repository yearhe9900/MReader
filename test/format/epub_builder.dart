// 测试脚手架：在内存里程序化拼装 EPUB（供 test/format/* 与 .scratch/ 探针复用）。
//
// 为什么不用 Python fixture：本批要验的目录层级 / 加密标记是**结构**问题，
// 用 Dart 现场拼 zip 更直接，且能与断言写在同一处（`make_fixtures.py` 的基线契约不动）。
//
// 本文件放在 test/ 下（测试脚手架），**不属于 lib/ 产物**。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 一条 zip 条目：包内路径 + 原始字节。
class EpubEntry {
  const EpubEntry(this.name, this.bytes);

  /// 包内路径（使用 `'/'`）。
  final String name;

  /// 原始字节。
  final List<int> bytes;
}

/// 文本条目（UTF-8）。
EpubEntry textEntry(String name, String content) =>
    EpubEntry(name, utf8.encode(content));

/// 把条目打成 zip 字节流；`mimetype` 自动置顶。
Uint8List zipEntries(List<EpubEntry> entries) {
  final Archive archive = Archive();
  final List<EpubEntry> ordered = <EpubEntry>[
    if (!entries.any((EpubEntry e) => e.name == 'mimetype'))
      EpubEntry('mimetype', utf8.encode('application/epub+zip')),
    ...entries,
  ];
  for (final EpubEntry entry in ordered) {
    archive.addFile(ArchiveFile(entry.name, entry.bytes.length, entry.bytes));
  }
  final List<int>? encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

/// `META-INF/container.xml`。
String containerXml(String opfPath, {String encoding = 'UTF-8'}) =>
    '<?xml version="1.0" encoding="$encoding"?>'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles>'
    '<rootfile full-path="$opfPath" media-type="application/oebps-package+xml"/>'
    '</rootfiles></container>';

/// OPF（默认 EPUB2 写法；EPUB3 场景传 `version: '3.0'`）。
String opfXml({
  required String title,
  required String manifest,
  required String spine,
  String author = '作者',
  String language = 'zh',
  String version = '2.0',
  String extraMetadata = '',
  String spineAttrs = '',
}) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="$version" '
    'unique-identifier="uid">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>$title</dc:title>'
    '<dc:creator>$author</dc:creator>'
    '<dc:language>$language</dc:language>'
    '$extraMetadata'
    '</metadata>'
    '<manifest>$manifest</manifest>'
    '<spine$spineAttrs>$spine</spine>'
    '</package>';

/// manifest `<item>`。
String itemXml(
  String id,
  String href,
  String mediaType, {
  String? properties,
}) =>
    '<item id="$id" href="$href" media-type="$mediaType"'
    '${properties == null ? '' : ' properties="$properties"'}/>';

/// spine `<itemref>`。
String itemrefXml(String idref, {String? linear}) =>
    '<itemref idref="$idref"${linear == null ? '' : ' linear="$linear"'}/>';

/// XHTML 章节。
String xhtmlDoc({
  String? title,
  String? heading,
  List<String> paragraphs = const <String>[],
  String? rawBody,
}) {
  final String head = title == null ? '' : '<head><title>$title</title></head>';
  final String body = rawBody ??
      '<body>${heading == null ? '' : '<h1>$heading</h1>'}'
          '${paragraphs.map((String p) => '<p>$p</p>').join()}</body>';
  return '<html xmlns="http://www.w3.org/1999/xhtml">$head$body</html>';
}

/// EPUB3 nav 文档。
String navXhtml(String navBody) =>
    '<html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head><title>目录</title></head>'
    '<body>$navBody</body></html>';

/// EPUB2 NCX 文档。
String ncxXml(String navMapBody) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
    '<head><meta name="dtb:uid" content="uid"/></head>'
    '<docTitle><text>目录</text></docTitle>'
    '<navMap>$navMapBody</navMap>'
    '</ncx>';

/// `META-INF/encryption.xml`：单个 `<EncryptedData>`。
String encryptionXml(String algorithm, String uri) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
    'xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
    '<enc:EncryptedData>'
    '<enc:EncryptionMethod Algorithm="$algorithm"/>'
    '<enc:CipherData><enc:CipherReference URI="$uri"/></enc:CipherData>'
    '</enc:EncryptedData>'
    '</encryption>';
