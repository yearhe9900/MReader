// 纯 Dart 的 EPUB 解析层。
//
// 对外只暴露一个纯函数式入口：`字节流 -> EpubBook`，不与 UI 耦合，
// 这样单测可以直接在内存里造一本 EPUB 来验证，后续也能直接丢进 isolate。
//
// 注意：这里只解析「结构」（元数据 / manifest / spine）。
// 章节正文的 XHTML -> 文本转换在 section_extractor.dart 里按需调用。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../model/epub_book.dart';
import 'text_codec.dart';

/// 解析失败时抛出。message 是可直接展示给用户的中文提示。
class EpubParseException implements Exception {
  EpubParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把一个 EPUB 字节流解析成 [EpubBook]。
///
/// 步骤：
/// 1. 解 zip；
/// 2. 读 `META-INF/container.xml` 找出 OPF 的真实路径（**绝不硬编码** `OEBPS/content.opf`）；
/// 3. 解析 OPF 的 metadata / manifest / spine；
/// 4. 按 spine 顺序取出各章 XHTML 的原始字节。
///
/// 失败一律抛 [EpubParseException]，消息可读，不让调用方看到白屏。
Future<EpubBook> parseEpub(Uint8List bytes, {String fileName = ''}) async {
  final Archive? archive = _tryDecodeZip(bytes);
  if (archive == null) {
    throw EpubParseException('解压失败：该文件不是有效的 EPUB（本质应是 zip）。');
  }

  // 建立包内路径索引。EPUB 内部一律使用 '/'，但可能出现 './' 前缀或重复斜杠。
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, String> lowerIndex = <String, String>{};
  for (final ArchiveFile f in archive.files) {
    if (!f.isFile) continue;
    final String name = _normalizeZipPath(f.name);
    if (name.isEmpty) continue;
    files[name] = _contentOf(f);
    lowerIndex[name.toLowerCase()] = name;
  }

  // 1) container.xml -> OPF 路径
  final Uint8List? containerBytes =
      _lookup(files, lowerIndex, 'META-INF/container.xml');
  if (containerBytes == null) {
    throw EpubParseException('缺少 META-INF/container.xml，不是合法的 EPUB 结构。');
  }

  final XmlDocument? containerDoc = _tryParseXml(decodeText(containerBytes));
  if (containerDoc == null) {
    throw EpubParseException('META-INF/container.xml 解析失败（XML 格式错误）。');
  }

  String? opfPath;
  for (final XmlElement el in _findAll(containerDoc, 'rootfile')) {
    final String? full = el.getAttribute('full-path');
    if (full != null && full.trim().isNotEmpty) {
      opfPath = _normalizeZipPath(full);
      break;
    }
  }
  if (opfPath == null || opfPath.isEmpty) {
    throw EpubParseException('container.xml 中没有找到 rootfile（OPF 路径缺失）。');
  }

  final Uint8List? opfBytes = _lookup(files, lowerIndex, opfPath);
  if (opfBytes == null) {
    throw EpubParseException('OPF 文件不存在于包内：$opfPath');
  }

  final XmlDocument? opfDoc = _tryParseXml(decodeText(opfBytes));
  if (opfDoc == null) {
    throw EpubParseException('OPF 解析失败（XML 格式错误）：$opfPath');
  }

  // OPF 所在目录，作为 manifest href 的相对基准。
  final String opfDir = p.posix.dirname(opfPath);

  // 2) metadata（按 localName 匹配，兼容各种命名空间前缀写法）
  final String title = _firstText(opfDoc, 'title');
  final String author = _firstText(opfDoc, 'creator');
  final String language = _firstText(opfDoc, 'language');

  // 3) manifest：id -> href / media-type
  final Map<String, String> idToHref = <String, String>{};
  final Map<String, String> idToMediaType = <String, String>{};
  for (final XmlElement item in _findAll(opfDoc, 'item')) {
    final String? id = item.getAttribute('id');
    final String? href = item.getAttribute('href');
    if (id == null || href == null || href.trim().isEmpty) continue;
    idToHref[id] = _resolveHref(opfDir, href);
    final String? mediaType = item.getAttribute('media-type');
    if (mediaType != null) idToMediaType[id] = mediaType;
  }

  // 4) spine：阅读顺序
  final List<EpubSection> sections = <EpubSection>[];
  for (final XmlElement itemref in _findAll(opfDoc, 'itemref')) {
    final String? linear = itemref.getAttribute('linear');
    if (linear != null && linear.toLowerCase() == 'no') {
      continue; // 规范里 linear="no" 表示非主线内容，跳过。
    }
    final String? idref = itemref.getAttribute('idref');
    if (idref == null) continue;

    final String? href = idToHref[idref];
    if (href == null) continue;

    final Uint8List? data = _lookup(files, lowerIndex, href);
    if (data == null) continue; // 资源缺失：优雅跳过，不让整本书解析失败。

    // 图片 / 字体 / CSS 等资源**不当章节**。
    // media-type 缺失时用扩展名 + 字节魔数兜底（现实里封面图常被塞进 spine 且漏写 media-type）。
    if (!_looksTextual(idToMediaType[idref], href, data)) continue;

    sections.add(EpubSection(id: idref, href: href, rawBytes: data));
  }

  if (sections.isEmpty) {
    throw EpubParseException('spine 为空：找不到任何可阅读的章节。');
  }

  return EpubBook(
    title: title,
    author: author,
    language: language,
    fileName: fileName,
    sections: sections,
  );
}

// ---------------------------------------------------------------------------
// 以下为内部工具函数
// ---------------------------------------------------------------------------

/// 尝试解 zip；把异常收敛成 null，由上层转成可读的中文错误。
Archive? _tryDecodeZip(Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return null;
  }
}

/// 尝试解析 XML；失败返回 null。
XmlDocument? _tryParseXml(String text) {
  try {
    return XmlDocument.parse(text);
  } catch (_) {
    return null;
  }
}

/// 取 ArchiveFile 的字节内容。
///
/// 用 `dynamic` + 类型判断，兼容 archive 3.x 里 content 可能是
/// `Uint8List` 或 `List<int>` 的不同实现细节。
Uint8List _contentOf(ArchiveFile file) {
  final dynamic content = file.content;
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  return Uint8List(0);
}

/// 归一化包内路径：统一分隔符、去掉 './' 与开头的 '/'、压掉重复斜杠。
String _normalizeZipPath(String raw) {
  var s = raw.replaceAll('\\', '/');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  s = s.replaceAll(RegExp(r'/+'), '/');
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
}

/// 解码 href 里的百分号转义（如 `%20` -> 空格，`%E7%AC%AC` -> 中文字符）。
///
/// 用 `Uri.decodeComponent`：它按 UTF-8 解码且**不会**把 '+' 当成空格。
/// 遇到畸形转义就原样返回，不抛异常。
String _decodePercent(String value) {
  if (!value.contains('%')) return value;
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

/// 把路径里的非 ASCII 字符做百分号编码（保留 '/' 等保留字符，不做多余转义）。
///
/// 用于匹配「zip 条目名本身就是百分号编码」的畸形 EPUB（回归 fixture fx02b）：
/// 这类书的 href 与条目名**解码后**一致，需要用「编码后」的形态去命中真实条目名。
String _encodePercent(String value) {
  if (_isAllAscii(value)) return value;
  try {
    return Uri.encodeFull(value);
  } catch (_) {
    return value;
  }
}

/// 是否全部为 ASCII。
bool _isAllAscii(String value) {
  for (int i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) > 0x7F) return false;
  }
  return true;
}

/// 把 manifest 里的相对 href 解析成相对于 OPF 目录的规范化包内路径。
String _resolveHref(String baseDir, String href) {
  var h = href.trim();

  // 去掉 fragment 与 query（spine 指向的是文件本身）。
  final int hash = h.indexOf('#');
  if (hash >= 0) h = h.substring(0, hash);
  final int question = h.indexOf('?');
  if (question >= 0) h = h.substring(0, question);

  h = _decodePercent(h).replaceAll('\\', '/');
  if (h.isEmpty) return '';

  final String joined = (baseDir.isEmpty || baseDir == '.')
      ? h
      : p.posix.join(baseDir, h);
  return p.posix.normalize(joined);
}

/// 在包内查找资源。依次尝试下列候选（一律**大小写不敏感**）：
/// 1. 归一化后的原路径；
/// 2. 百分号**解码**后的路径（`%E7%AC%AC` -> 中文，匹配 zip 内是真实中文名的书，fx02a）；
/// 3. 百分号**编码**后的路径（中文 -> `%E7%AC%AC`，匹配 zip 条目名本身即编码的畸形书，fx02b）。
Uint8List? _lookup(
  Map<String, Uint8List> files,
  Map<String, String> lowerIndex,
  String path,
) {
  final Set<String> candidates = <String>{
    _normalizeZipPath(path),
    _normalizeZipPath(_decodePercent(path)),
    _normalizeZipPath(_encodePercent(path)),
  };
  for (final String candidate in candidates) {
    if (candidate.isEmpty) continue;
    final Uint8List? direct = files[candidate];
    if (direct != null) return direct;
    final String? byLower = lowerIndex[candidate.toLowerCase()];
    if (byLower != null) return files[byLower];
  }
  return null;
}

/// 按 localName 递归收集元素，忽略命名空间前缀差异。
Iterable<XmlElement> _findAll(XmlNode root, String localName) sync* {
  for (final XmlElement element in root.childElements) {
    if (element.name.local == localName) yield element;
    yield* _findAll(element, localName);
  }
}

/// 递归拼接节点内的全部文本（只取 XmlText，天然跳过注释）。
void _collectText(XmlNode node, StringBuffer buffer) {
  for (final XmlNode child in node.children) {
    if (child is XmlText) {
      buffer.write(child.value);
    } else if (child is XmlElement) {
      _collectText(child, buffer);
    }
  }
}

/// 取某个 localName 下第一段非空文本。
String _firstText(XmlDocument doc, String localName) {
  for (final XmlElement element in _findAll(doc, localName)) {
    final StringBuffer buffer = StringBuffer();
    _collectText(element, buffer);
    final String text =
        buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// media-type 缺失时的兜底：需要排除出 spine 的**非文本**资源扩展名。
const Set<String> _binaryExtensions = <String>{
  'png', 'jpg', 'jpeg', 'jpe', 'gif', 'bmp', 'webp', 'tif', 'tiff',
  'ico', 'svg', 'avif', 'heic', 'apng',
  'mp3', 'mp4', 'm4a', 'ogg', 'oga', 'wav', 'aac', 'flac', 'webm', 'avi', 'mov',
  'ttf', 'otf', 'woff', 'woff2', 'eot',
  'css', 'js', 'mjs',
};

/// 该 spine 项是否可能是「文本内容」。
///
/// 判定顺序：
/// 1. 有明确 media-type：`image/` `audio/` `video/` 或含 css/font/javascript 的一律排除；
/// 2. media-type 缺失：先按扩展名判断，再用字节魔数（PNG/JPEG/GIF/BMP/WEBP）兜底嗅探。
///
/// 现实里（回归 fixture fx07b）封面图常被塞进 spine 且漏写 media-type，
/// 只看 media-type 会把它当正文段落输出。
bool _looksTextual(String? mediaType, String href, Uint8List bytes) {
  if (mediaType != null && mediaType.isNotEmpty) {
    final String m = mediaType.toLowerCase();
    if (m.startsWith('image/')) return false;
    if (m.startsWith('audio/')) return false;
    if (m.startsWith('video/')) return false;
    if (m.contains('css')) return false;
    if (m.contains('font')) return false;
    if (m.contains('javascript')) return false;
    return true;
  }
  return !_looksBinaryByExtension(href) && !_looksBinaryByMagic(bytes);
}

/// 扩展名兜底：href 以已知二进制扩展名结尾 -> 不是文本。
bool _looksBinaryByExtension(String href) {
  final String path = _normalizeZipPath(_decodePercent(href)).toLowerCase();
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  final String ext = path.substring(dot + 1);
  return _binaryExtensions.contains(ext);
}

/// 字节魔数兜底：文件头就能看出是图片等二进制 -> 不是文本。
bool _looksBinaryByMagic(Uint8List bytes) {
  final int n = bytes.length;
  if (n >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) return true; // BMP "BM"
  if (n >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return true; // JPEG
  }
  if (n >= 4) {
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return true; // PNG
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return true; // GIF8
    }
    if (n >= 12 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return true; // WEBP (RIFF....WEBP)
    }
  }
  return false;
}
