// 纯 Dart 的 EPUB 解析层。
//
// 对外只暴露一个纯函数式入口：`字节流 -> EpubBook`，不与 UI 耦合，
// 这样单测可以直接在内存里造一本 EPUB 来验证，后续也能直接丢进 isolate。
//
// 注意：这里只解析「结构」（元数据 / manifest / spine / 目录 / 加密标记）。
// 章节正文的 XHTML -> 文本转换在 section_extractor.dart 里按需调用。
//
// 错误口径：一律抛 [MReaderFormatException]（文案唯一来源 `lib/format/error_messages.dart`），
// 调用方据此给用户**可读的中文提示**（`RD-05`），绝不白屏。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../format/error_messages.dart';
import '../model/epub_book.dart';
import 'epub_toc.dart';
import 'text_codec.dart';
import 'xml_util.dart';
import 'zip_paths.dart';

/// **已废弃**：保留为 [MReaderFormatException] 的子类，仅为兼容既有引用。
///
/// 新代码请直接抛 [MReaderFormatException]（错误码 + 唯一中文文案）。
@Deprecated('改用 MReaderFormatException（RD-05 唯一文案来源）')
class EpubParseException extends MReaderFormatException {
  const EpubParseException(this.rawMessage)
      : super(FormatErrorCode.corruptFile);

  /// 旧式自由文本消息（本类只为兼容而存在）。
  final String rawMessage;

  @override
  String get message => rawMessage;

  @override
  String toString() => rawMessage;
}

/// 把一个 EPUB 字节流解析成 [EpubBook]。
///
/// 步骤：
/// 1. 解 zip；
/// 2. 读 `META-INF/container.xml` 找出 OPF 的真实路径（**绝不硬编码** `OEBPS/content.opf`）；
/// 3. 解析 OPF 的 metadata / manifest / spine；
/// 4. **加密检测**（读 `META-INF/encryption.xml`，`RD-05`）——必须在返回可读章节之前；
/// 5. 解析目录（EPUB3 nav / EPUB2 ncx 双路径，`RD-01`）；
/// 6. 按 spine 顺序取出各章 XHTML 的原始字节。
///
/// 失败一律抛 [MReaderFormatException]，消息可读。
Future<EpubBook> parseEpub(Uint8List bytes, {String fileName = ''}) async {
  if (bytes.isEmpty) {
    throw const MReaderFormatException(FormatErrorCode.emptyFile);
  }

  final Archive? archive = tryDecodeZip(bytes);
  if (archive == null) {
    throw const MReaderFormatException(FormatErrorCode.notZip);
  }

  // 建立包内路径索引。EPUB 内部一律使用 '/'，但可能出现 './' 前缀或重复斜杠。
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, String> lowerIndex = <String, String>{};
  for (final ArchiveFile f in archive.files) {
    if (!f.isFile) continue;
    final String name = normalizeZipPath(f.name);
    if (name.isEmpty) continue;
    files[name] = contentOfArchiveFile(f);
    lowerIndex[name.toLowerCase()] = name;
  }

  /// 供本函数与 [parseToc] 共用的命中逻辑（大小写不敏感 + 百分号三试探）。
  Uint8List? lookup(String packagePath) =>
      lookupInFiles(files, lowerIndex, packagePath);

  // 1) container.xml -> OPF 路径
  final Uint8List? containerBytes = lookup('META-INF/container.xml');
  if (containerBytes == null) {
    throw const MReaderFormatException(FormatErrorCode.missingContainer);
  }

  final XmlDocument? containerDoc = tryParseXml(decodeText(containerBytes));
  if (containerDoc == null) {
    throw const MReaderFormatException(FormatErrorCode.badContainerXml);
  }

  String? opfPath;
  for (final XmlElement el in findAllByLocalName(containerDoc, 'rootfile')) {
    final String? full = el.getAttribute('full-path');
    if (full != null && full.trim().isNotEmpty) {
      opfPath = normalizeZipPath(full);
      break;
    }
  }
  if (opfPath == null || opfPath.isEmpty) {
    throw const MReaderFormatException(FormatErrorCode.missingOpf);
  }

  final Uint8List? opfBytes = lookup(opfPath);
  if (opfBytes == null) {
    throw MReaderFormatException(
      FormatErrorCode.corruptFile,
      detail: 'OPF 不存在于包内：$opfPath',
    );
  }

  final XmlDocument? opfDoc = tryParseXml(decodeText(opfBytes));
  if (opfDoc == null) {
    throw MReaderFormatException(FormatErrorCode.badOpf, detail: opfPath);
  }

  // OPF 所在目录，作为 manifest href 的相对基准。
  final String opfDir = p.posix.dirname(opfPath);

  // 2) metadata（按 localName 匹配，兼容各种命名空间前缀写法）
  final String title = firstLocalizedText(opfDoc, 'title');
  final String author = firstLocalizedText(opfDoc, 'creator');
  final String language = firstLocalizedText(opfDoc, 'language');

  // 3) manifest：id -> href / media-type
  final Map<String, String> idToHref = <String, String>{};
  final Map<String, String> idToMediaType = <String, String>{};
  for (final XmlElement item in findAllByLocalName(opfDoc, 'item')) {
    final String? id = item.getAttribute('id');
    final String? href = item.getAttribute('href');
    if (id == null || href == null || href.trim().isEmpty) continue;
    idToHref[id] = resolveHref(opfDir, href);
    final String? mediaType = item.getAttribute('media-type');
    if (mediaType != null) idToMediaType[id] = mediaType;
  }

  // 4) 加密检测（RD-05）：必须在返回任何可读章节之前。
  _rejectEncryptedEpub(files, lowerIndex, idToHref, idToMediaType);

  // 5) 目录（RD-01）：无目录时返回空列表，由调用方降级为平坦目录。
  final List<EpubTocEntry> toc =
      parseToc(opfDoc: opfDoc, opfDir: opfDir, lookup: lookup);

  // 6) spine：阅读顺序
  final List<EpubSection> sections = <EpubSection>[];
  for (final XmlElement itemref in findAllByLocalName(opfDoc, 'itemref')) {
    final String? linear = itemref.getAttribute('linear');
    if (linear != null && linear.toLowerCase() == 'no') {
      continue; // 规范里 linear="no" 表示非主线内容，跳过。
    }
    final String? idref = itemref.getAttribute('idref');
    if (idref == null) continue;

    final String? href = idToHref[idref];
    if (href == null) continue;

    final Uint8List? data = lookup(href);
    if (data == null) continue; // 资源缺失：优雅跳过，不让整本书解析失败。

    // 图片 / 字体 / CSS 等资源**不当章节**。
    // media-type 缺失时用扩展名 + 字节魔数兜底（现实里封面图常被塞进 spine 且漏写 media-type）。
    if (!looksTextual(idToMediaType[idref], href, data)) continue;

    sections.add(EpubSection(id: idref, href: href, rawBytes: data));
  }

  if (sections.isEmpty) {
    throw const MReaderFormatException(FormatErrorCode.emptySpine);
  }

  return EpubBook(
    title: title,
    author: author,
    language: language,
    fileName: fileName,
    sections: sections,
    toc: toc,
  );
}

// ---------------------------------------------------------------------------
// 加密检测（RD-05）
// ---------------------------------------------------------------------------

/// IDPF / Adobe 的**字体混淆**算法：DRM-free 书给内嵌字体做的混淆，**不算加密**。
const Set<String> _fontObfuscationAlgorithms = <String>{
  'http://www.idpf.org/2008/embedding', // IDPF 字体混淆
  'http://ns.adobe.com/pdf/enc#RC', // Adobe 字体混淆
};

/// 字体资源扩展名。
const Set<String> _fontExtensions = <String>{
  'otf', 'ttf', 'ttc', 'woff', 'woff2',
};

/// 检测 `META-INF/encryption.xml` 并拒绝真正加密的书。
///
/// 判定规则（**逐条对齐 `RD-05`**，务必不要误杀正常书）：
/// 1. `encryption.xml` **不存在 → 不加密**；
/// 2. 存在时逐个看 `<EncryptedData>`，取其 `<EncryptionMethod Algorithm>` 与
///    `<CipherReference URI>`；
/// 3. `Algorithm` 属字体混淆（IDPF / Adobe）→ **不算加密**；
/// 4. 被加密目标是**字体资源**（扩展名，或 manifest 里 media-type 为字体）→ **不算加密**；
/// 5. 其余情况（非字体目标 + 非字体混淆算法）→ 判为加密，抛 [FormatErrorCode.encryptedEpub]。
void _rejectEncryptedEpub(
  Map<String, Uint8List> files,
  Map<String, String> lowerIndex,
  Map<String, String> idToHref,
  Map<String, String> idToMediaType,
) {
  final Uint8List? encBytes =
      lookupInFiles(files, lowerIndex, 'META-INF/encryption.xml');
  if (encBytes == null) return; // 规则 1：不存在 -> 不加密

  final XmlDocument? doc = tryParseXml(decodeText(encBytes));
  if (doc == null) {
    // encryption.xml 自己都解不开：不作为加密证据（避免把脏书误判为加密而拒开）。
    return;
  }

  for (final XmlElement data in findAllByLocalName(doc, 'EncryptedData')) {
    final String algorithm =
        (firstAttributeIn(data, 'EncryptionMethod', 'Algorithm') ?? '').trim();
    final String uri =
        (firstAttributeIn(data, 'CipherReference', 'URI') ?? '').trim();

    // 规则 3：字体混淆算法 -> 不算加密。
    if (_fontObfuscationAlgorithms.contains(algorithm)) continue;

    // 规则 4：目标是字体 -> 不算加密。
    if (_isFontResource(uri, idToHref, idToMediaType)) continue;

    // 规则 5：判为加密。detail 只给调试用的资源 URI。
    throw MReaderFormatException(
      FormatErrorCode.encryptedEpub,
      detail: uri.isEmpty ? null : 'encrypted: $uri',
    );
  }
}

/// [uri]（`<CipherReference URI>`，包内相对路径）是否指向字体资源。
bool _isFontResource(
  String uri,
  Map<String, String> idToHref,
  Map<String, String> idToMediaType,
) {
  final String target = resolveHref('', uri).toLowerCase();
  if (target.isEmpty) return false;

  final int dot = target.lastIndexOf('.');
  if (dot >= 0 && dot < target.length - 1) {
    if (_fontExtensions.contains(target.substring(dot + 1))) return true;
  }

  for (final MapEntry<String, String> entry in idToHref.entries) {
    if (entry.value.toLowerCase() != target) continue;
    final String mediaType =
        (idToMediaType[entry.key] ?? '').toLowerCase().trim();
    if (mediaType.startsWith('font/')) return true;
    if (mediaType.startsWith('application/font')) return true;
    if (mediaType.startsWith('application/x-font')) return true;
    if (mediaType == 'application/vnd.ms-opentype') return true;
  }
  return false;
}
