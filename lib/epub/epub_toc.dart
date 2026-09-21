// EPUB 目录（TOC）解析：EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx` 双路径（`RD-01`）。
//
// 本文件**只做「已解析对象 -> 目录条目」的转换**：zip 解包与资源命中由调用方通过
// [parseToc] 的 `lookup` 回调注入，因此这里不依赖 `archive`，也不碰文件系统。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'text_codec.dart';
import 'xml_util.dart';
import 'zip_paths.dart';

/// 目录条目。
class EpubTocEntry {
  const EpubTocEntry({
    required this.href,
    required this.title,
    required this.level,
    required this.locate,
  });

  /// 归一化后的包内路径（如 `OEBPS/text/ch1.xhtml`）。
  final String href;

  /// 目录标题（nav / ncx 里的文本，已折叠空白）。
  final String title;

  /// 层级深度：`0` = 顶层；子项 `+1`（**来自真实嵌套深度**，不是扁平序号）。
  final int level;

  /// fragment id（href 中 `'#'` 之后的部分），无则 `''`。
  final String locate;
}

/// 解析 EPUB 目录。
///
/// - **EPUB3**：OPF manifest 里 `properties` 含 `nav` 的 item → 解析其
///   `<nav epub:type="toc">` 的嵌套 `<ol><li><a>`；
/// - **EPUB2**：manifest 里 media-type 为 `application/x-dtbncx+xml` 的 item
///   （或后缀 `.ncx`）→ 解析 `navMap` 的嵌套 `navPoint`，
///   `<navLabel><text>` 为标题，level 按嵌套深度；
/// - 两者皆无 / 解析后为空 → 返回**空列表**（调用方降级为「按 spine 的平坦目录」）。
///
/// [lookup] 用于按包内路径取资源字节，通常直接复用 `epub_parser` 的命中逻辑
/// （含大小写不敏感与百分号三试探）。
List<EpubTocEntry> parseToc({
  required XmlDocument opfDoc,
  required String opfDir,
  required Uint8List? Function(String packagePath) lookup,
}) {
  final _ManifestItems items = _collectManifestItems(opfDoc, opfDir);

  // 路径一：EPUB3 nav。
  for (final _ManifestItem item in items.navs) {
    final Uint8List? bytes = lookup(item.href);
    if (bytes == null) continue;
    final List<EpubTocEntry> entries = _parseNav(item.href, bytes);
    if (entries.isNotEmpty) return entries;
  }

  // 路径二：EPUB2 ncx。
  for (final _ManifestItem item in items.ncxs) {
    final Uint8List? bytes = lookup(item.href);
    if (bytes == null) continue;
    final List<EpubTocEntry> entries = _parseNcx(item.href, bytes);
    if (entries.isNotEmpty) return entries;
  }

  return const <EpubTocEntry>[];
}

// ---------------------------------------------------------------------------
// manifest 扫描
// ---------------------------------------------------------------------------

/// manifest 里与目录相关的条目。
class _ManifestItems {
  const _ManifestItems({required this.navs, required this.ncxs});

  /// `properties` 含 `nav` 的项（EPUB3）。
  final List<_ManifestItem> navs;

  /// NCX（EPUB2）。
  final List<_ManifestItem> ncxs;
}

class _ManifestItem {
  const _ManifestItem({required this.href, required this.mediaType});

  final String href;
  final String mediaType;
}

/// 扫描 OPF manifest，挑出 nav 与 ncx。
_ManifestItems _collectManifestItems(XmlDocument opfDoc, String opfDir) {
  final List<_ManifestItem> navs = <_ManifestItem>[];
  final List<_ManifestItem> ncxs = <_ManifestItem>[];

  for (final XmlElement item in findAllByLocalName(opfDoc, 'item')) {
    final String? href = item.getAttribute('href');
    if (href == null || href.trim().isEmpty) continue;

    final String mediaType =
        (item.getAttribute('media-type') ?? '').trim().toLowerCase();
    final String resolved = resolveHref(opfDir, href);
    if (resolved.isEmpty) continue;

    final String properties =
        (item.getAttribute('properties') ?? '').toLowerCase();
    final bool isNav = properties
        .split(RegExp(r'\s+'))
        .any((String token) => token.trim() == 'nav');

    if (isNav) {
      navs.add(_ManifestItem(href: resolved, mediaType: mediaType));
      continue; // nav 文档同时可能是 ncx 的替代品，但绝不当 ncx 处理
    }
    if (mediaType == 'application/x-dtbncx+xml' ||
        resolved.toLowerCase().endsWith('.ncx')) {
      ncxs.add(_ManifestItem(href: resolved, mediaType: mediaType));
    }
  }
  return _ManifestItems(navs: navs, ncxs: ncxs);
}

// ---------------------------------------------------------------------------
// EPUB3 nav.xhtml
// ---------------------------------------------------------------------------

/// 解析 `nav.xhtml`：优先用 `package:html` 宽松解析（EPUB3 的 nav 常是脏 XHTML），
/// 宽松解析拿不到 `<nav>` 时再回落 `package:xml` 严格解析。
List<EpubTocEntry> _parseNav(String navPath, Uint8List bytes) {
  final String text = decodeText(bytes);
  if (text.trim().isEmpty) return const <EpubTocEntry>[];

  final String navDir = p.posix.dirname(navPath);

  final dom.Document? htmlDoc = _tryParseHtml(text);
  if (htmlDoc != null) {
    final dom.Element? nav = _findTocNav(htmlDoc);
    if (nav != null) {
      final dom.Element? ol = _firstDescendantByTag(nav, 'ol');
      if (ol != null) {
        final List<EpubTocEntry> out = <EpubTocEntry>[];
        _walkNavOl(ol, navDir, 0, out);
        if (out.isNotEmpty) return out;
      }
    }
  }

  // 回落：严格 XML 解析（部分 nav 文档是严格 XHTML，html 解析器会打乱结构）。
  final XmlDocument? xmlDoc = tryParseXml(text);
  if (xmlDoc == null) return const <EpubTocEntry>[];
  final XmlElement? xmlNav = _findTocNavXml(xmlDoc);
  final XmlElement? xmlOl =
      xmlNav == null ? null : firstElementIn(xmlNav, 'ol');
  if (xmlOl == null) return const <EpubTocEntry>[];
  final List<EpubTocEntry> out = <EpubTocEntry>[];
  _walkNavOlXml(xmlOl, navDir, 0, out);
  return out;
}

/// 找 `<nav epub:type="toc">`；找不到就退回第一个 `<nav>`（现实里大量书省写了 epub:type）。
dom.Element? _findTocNav(dom.Document doc) {
  final List<dom.Element> navs = <dom.Element>[];
  void scan(dom.Node node) {
    for (final dom.Node child in node.nodes) {
      if (child is! dom.Element) continue;
      if (child.localName?.toLowerCase() == 'nav') navs.add(child);
      scan(child);
    }
  }

  scan(doc);
  if (navs.isEmpty) return null;
  for (final dom.Element nav in navs) {
    for (final MapEntry<Object, String> attr in nav.attributes.entries) {
      if (!'${attr.key}'.toLowerCase().endsWith('type')) continue;
      if (attr.value.trim().toLowerCase() == 'toc') return nav;
    }
  }
  return navs.first;
}

/// `package:xml` 版本的 `_findTocNav`。
XmlElement? _findTocNavXml(XmlDocument doc) {
  final List<XmlElement> navs =
      findAllByLocalName(doc, 'nav').toList(growable: false);
  if (navs.isEmpty) return null;
  for (final XmlElement nav in navs) {
    for (final XmlAttribute attr in nav.attributes) {
      if (!attr.name.local.toLowerCase().endsWith('type')) continue;
      if (attr.value.trim().toLowerCase() == 'toc') return nav;
    }
  }
  return navs.first;
}

/// 按 `<ol><li><a>` 递归收集，depth 即 `level`。
void _walkNavOl(
  dom.Element ol,
  String navDir,
  int level,
  List<EpubTocEntry> out,
) {
  for (final dom.Element li in ol.children) {
    if (li.localName?.toLowerCase() != 'li') continue;

    final dom.Element? anchor = _firstAnchorOutsideNestedList(li);
    if (anchor != null) {
      final String raw = (anchor.attributes['href'] ?? '').trim();
      final String title = collapseWhitespace(anchor.text);
      if (raw.isNotEmpty && title.isNotEmpty) {
        final EpubTocEntry? entry = _makeEntry(navDir, raw, title, level);
        if (entry != null) out.add(entry);
      }
    }

    final dom.Element? nested = _firstChildByTag(li, 'ol');
    if (nested != null) _walkNavOl(nested, navDir, level + 1, out);
  }
}

/// `package:xml` 版本的 `_walkNavOl`。
void _walkNavOlXml(
  XmlElement ol,
  String navDir,
  int level,
  List<EpubTocEntry> out,
) {
  for (final XmlElement li in ol.childElements) {
    if (li.name.local != 'li') continue;

    final XmlElement? anchor = firstElementIn(li, 'a');
    if (anchor != null) {
      final String raw = (anchor.getAttribute('href') ?? '').trim();
      final String title = collapsedText(anchor);
      if (raw.isNotEmpty && title.isNotEmpty) {
        final EpubTocEntry? entry = _makeEntry(navDir, raw, title, level);
        if (entry != null) out.add(entry);
      }
    }

    XmlElement? nested;
    for (final XmlElement child in li.childElements) {
      if (child.name.local == 'ol') {
        nested = child;
        break;
      }
    }
    if (nested != null) _walkNavOlXml(nested, navDir, level + 1, out);
  }
}

// ---------------------------------------------------------------------------
// EPUB2 toc.ncx
// ---------------------------------------------------------------------------

/// 解析 `toc.ncx`（严格 XML）：`navMap` 下的嵌套 `navPoint`。
List<EpubTocEntry> _parseNcx(String ncxPath, Uint8List bytes) {
  final XmlDocument? doc = tryParseXml(decodeText(bytes));
  if (doc == null) return const <EpubTocEntry>[];

  XmlElement? navMap;
  for (final XmlElement element in findAllByLocalName(doc, 'navMap')) {
    navMap = element;
    break;
  }
  if (navMap == null) return const <EpubTocEntry>[];

  final String ncxDir = p.posix.dirname(ncxPath);
  final List<EpubTocEntry> out = <EpubTocEntry>[];
  _walkNavPoints(navMap, ncxDir, 0, out);
  return out;
}

/// 递归收集 `navPoint`；**只有直接子 `navPoint` 才升层**（避免把 `<content>` 里的深层节点误算）。
void _walkNavPoints(
  XmlElement parent,
  String ncxDir,
  int level,
  List<EpubTocEntry> out,
) {
  for (final XmlElement point in parent.childElements) {
    if (point.name.local != 'navPoint') continue;

    final String title = _navLabelText(point);
    final String src = firstAttributeIn(point, 'content', 'src') ?? '';
    if (src.trim().isNotEmpty && title.isNotEmpty) {
      final EpubTocEntry? entry = _makeEntry(ncxDir, src, title, level);
      if (entry != null) out.add(entry);
    }
    _walkNavPoints(point, ncxDir, level + 1, out);
  }
}

/// `<navLabel><text>` 的文本；找不到 navLabel 时退化为第一个 `<text>`。
String _navLabelText(XmlElement point) {
  for (final XmlElement child in point.childElements) {
    if (child.name.local != 'navLabel') continue;
    final String text = collapsedText(child);
    if (text.isNotEmpty) return text;
  }
  return firstLocalizedText(point, 'text');
}

// ---------------------------------------------------------------------------
// 共用：href -> 目录条目
// ---------------------------------------------------------------------------

/// 把目录里的相对 href 解析成 [EpubTocEntry]。
///
/// **关键点**：nav / ncx 里的 href 是**相对目录文件自身**的（不是相对 OPF 目录），
/// 因此基准目录是 `dirname(navPath)`。这是本文件最容易写错的一点，已由 fixture 覆盖
/// 「nav 位于子目录 + href 带 `../`」的用例。
///
/// 解析不出文件路径（如纯 fragment `'#c1'`）的条目不产生目录项，返回 `null`。
EpubTocEntry? _makeEntry(
  String baseDir,
  String rawHref,
  String title,
  int level,
) {
  final String href = rawHref.trim();
  final int hash = href.indexOf('#');
  final String locate = hash >= 0 ? href.substring(hash + 1).trim() : '';
  final String withoutFragment = hash >= 0 ? href.substring(0, hash) : href;

  final String resolved = resolveHref(baseDir, withoutFragment);
  if (resolved.isEmpty) return null;

  return EpubTocEntry(
    href: resolved,
    title: title,
    level: level,
    locate: locate,
  );
}

// ---------------------------------------------------------------------------
// DOM 小工具（package:html）
// ---------------------------------------------------------------------------

/// 深度优先找第一个 localName 匹配的后代元素（不含 [root] 自身）。
dom.Element? _firstDescendantByTag(dom.Node root, String tag) {
  for (final dom.Node node in root.nodes) {
    if (node is! dom.Element) continue;
    if (node.localName?.toLowerCase() == tag) return node;
    final dom.Element? found = _firstDescendantByTag(node, tag);
    if (found != null) return found;
  }
  return null;
}

/// 直接子元素里按标签名找第一个。
dom.Element? _firstChildByTag(dom.Element parent, String tag) {
  for (final dom.Element child in parent.children) {
    if (child.localName?.toLowerCase() == tag) return child;
  }
  return null;
}

/// 在 `<li>` 里找第一个 `<a>`，**不下钻嵌套 `<ol>`**（嵌套列表的锚点属于子项）。
dom.Element? _firstAnchorOutsideNestedList(dom.Element li) {
  for (final dom.Node node in li.nodes) {
    if (node is! dom.Element) continue;
    final String? tag = node.localName?.toLowerCase();
    if (tag == 'ol') continue;
    if (tag == 'a') return node;
    final dom.Element? found = _firstAnchorOutsideNestedList(node);
    if (found != null) return found;
  }
  return null;
}

/// 尝试用宽松 HTML 解析器解析；失败返回 `null`。
dom.Document? _tryParseHtml(String source) {
  try {
    return html_parser.parse(source);
  } catch (_) {
    return null;
  }
}
