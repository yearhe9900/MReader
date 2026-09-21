// EPUB 目录（TOC）解析：EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx` 双路径（`RD-01`）。
//
// 本文件**只做「已解析对象 -> 章节列表」的转换**：zip 解包与资源命中由调用方通过
// [parseToc] 的 `lookup` 回调注入，因此这里不依赖 `archive`，也不碰文件系统。
//
// 返回类型是 [Chapter] —— 全项目唯一的章节类型（`lib/model/chapter.dart`）。
// **不要再引入第二份「目录条目」类型**：目录项与章节结构相同，两份类型会导致无意义的字段搬运。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../model/chapter.dart';
import 'text_codec.dart';
import 'xml_util.dart';
import 'zip_paths.dart';

/// 解析 EPUB 目录，返回 [Chapter] 列表。
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
List<Chapter> parseToc({
  required XmlDocument opfDoc,
  required String opfDir,
  required Uint8List? Function(String packagePath) lookup,
}) {
  final _ManifestItems items = _collectManifestItems(opfDoc, opfDir);

  // 路径一：EPUB3 nav。
  for (final _ManifestItem item in items.navs) {
    final Uint8List? bytes = lookup(item.href);
    if (bytes == null) continue;
    final List<Chapter> chapters = _parseNav(item.href, bytes);
    if (chapters.isNotEmpty) return chapters;
  }

  // 路径二：EPUB2 ncx。
  for (final _ManifestItem item in items.ncxs) {
    final Uint8List? bytes = lookup(item.href);
    if (bytes == null) continue;
    final List<Chapter> chapters = _parseNcx(item.href, bytes);
    if (chapters.isNotEmpty) return chapters;
  }

  return const <Chapter>[];
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
List<Chapter> _parseNav(String navPath, Uint8List bytes) {
  final String text = decodeText(bytes);
  if (text.trim().isEmpty) return const <Chapter>[];

  final String navDir = p.posix.dirname(navPath);

  final dom.Document? htmlDoc = _tryParseHtml(text);
  if (htmlDoc != null) {
    final dom.Element? nav = _findTocNav(htmlDoc);
    if (nav != null) {
      final dom.Element? ol = _firstDescendantByTag(nav, 'ol');
      if (ol != null) {
        final List<Chapter> out = <Chapter>[];
        _walkNavOl(ol, navDir, navPath, 0, out);
        if (out.isNotEmpty) return out;
      }
    }
  }

  // 回落：严格 XML 解析（部分 nav 文档是严格 XHTML，html 解析器会打乱结构）。
  final XmlDocument? xmlDoc = tryParseXml(text);
  if (xmlDoc == null) return const <Chapter>[];
  final XmlElement? xmlNav = _findTocNavXml(xmlDoc);
  final XmlElement? xmlOl =
      xmlNav == null ? null : firstElementIn(xmlNav, 'ol');
  if (xmlOl == null) return const <Chapter>[];
  final List<Chapter> out = <Chapter>[];
  _walkNavOlXml(xmlOl, navDir, navPath, 0, out);
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
  String selfPath,
  int level,
  List<Chapter> out,
) {
  for (final dom.Element li in ol.children) {
    if (li.localName?.toLowerCase() != 'li') continue;

    final dom.Element? anchor = _firstAnchorOutsideNestedList(li);
    if (anchor != null) {
      final String raw = (anchor.attributes['href'] ?? '').trim();
      final String title = collapseWhitespace(anchor.text);
      if (raw.isNotEmpty && title.isNotEmpty) {
        final Chapter? chapter =
            _makeChapter(navDir, selfPath, raw, title, level);
        if (chapter != null) out.add(chapter);
      }
    }

    final dom.Element? nested = _firstChildByTag(li, 'ol');
    if (nested != null) _walkNavOl(nested, navDir, selfPath, level + 1, out);
  }
}

/// `package:xml` 版本的 `_walkNavOl`。
void _walkNavOlXml(
  XmlElement ol,
  String navDir,
  String selfPath,
  int level,
  List<Chapter> out,
) {
  for (final XmlElement li in ol.childElements) {
    if (li.name.local != 'li') continue;

    final XmlElement? anchor = _firstAnchorOutsideNestedListXml(li);
    if (anchor != null) {
      final String raw = (anchor.getAttribute('href') ?? '').trim();
      final String title = collapsedText(anchor);
      if (raw.isNotEmpty && title.isNotEmpty) {
        final Chapter? chapter =
            _makeChapter(navDir, selfPath, raw, title, level);
        if (chapter != null) out.add(chapter);
      }
    }

    XmlElement? nested;
    for (final XmlElement child in li.childElements) {
      if (child.name.local == 'ol') {
        nested = child;
        break;
      }
    }
    if (nested != null) _walkNavOlXml(nested, navDir, selfPath, level + 1, out);
  }
}

// ---------------------------------------------------------------------------
// EPUB2 toc.ncx
// ---------------------------------------------------------------------------

/// 解析 `toc.ncx`（严格 XML）：`navMap` 下的嵌套 `navPoint`。
List<Chapter> _parseNcx(String ncxPath, Uint8List bytes) {
  final XmlDocument? doc = tryParseXml(decodeText(bytes));
  if (doc == null) return const <Chapter>[];

  XmlElement? navMap;
  for (final XmlElement element in findAllByLocalName(doc, 'navMap')) {
    navMap = element;
    break;
  }
  if (navMap == null) return const <Chapter>[];

  final String ncxDir = p.posix.dirname(ncxPath);
  final List<Chapter> out = <Chapter>[];
  _walkNavPoints(navMap, ncxDir, ncxPath, 0, out);
  return out;
}

/// 递归收集 `navPoint`；**只有直接子 `navPoint` 才升层**（避免把 `<content>` 里的深层节点误算）。
void _walkNavPoints(
  XmlElement parent,
  String ncxDir,
  String selfPath,
  int level,
  List<Chapter> out,
) {
  for (final XmlElement point in parent.childElements) {
    if (point.name.local != 'navPoint') continue;

    final String title = _navLabelText(point);
    // **只取本层的 `<content>`**：不下钻到嵌套 `navPoint` 的 `<content>`，
    // 否则父级标题会凭空指向子项的文件。
    final String src = _ownLevelContentSrc(point) ?? '';
    if (src.trim().isNotEmpty && title.isNotEmpty) {
      final Chapter? chapter =
          _makeChapter(ncxDir, selfPath, src, title, level);
      if (chapter != null) out.add(chapter);
    }
    _walkNavPoints(point, ncxDir, selfPath, level + 1, out);
  }
}

/// `navPoint` **直接子元素**里的 `<content src="…">`。
String? _ownLevelContentSrc(XmlElement point) {
  for (final XmlElement child in point.childElements) {
    if (child.name.local != 'content') continue;
    return child.getAttribute('src');
  }
  return null;
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
// 共用：href -> 章节
// ---------------------------------------------------------------------------

/// 把目录里的相对 href 解析成 [Chapter]。
///
/// **关键点 1**：nav / ncx 里的 href 是**相对目录文件自身**的（不是相对 OPF 目录），
/// 因此基准目录是 `dirname(selfPath)`。这是本文件最容易写错的一点，已由用例覆盖
/// 「nav 位于子目录 + href 带 `../`」。
///
/// **关键点 2**：`<a href="#c1">` 这类**纯 fragment 链接**指向**目录文件自身**
/// （EPUB3 允许 nav 与正文同文件），此时 href 取 [selfPath]，`locate` 为 `c1`。
///
/// href 为空且无 fragment 的条目返回 `null`（不产生目录项）。
Chapter? _makeChapter(
  String baseDir,
  String selfPath,
  String rawHref,
  String title,
  int level,
) {
  final String href = rawHref.trim();
  final int hash = href.indexOf('#');
  final String locate = hash >= 0 ? href.substring(hash + 1).trim() : '';
  final String withoutFragment = hash >= 0 ? href.substring(0, hash) : href;

  final String resolved;
  if (withoutFragment.trim().isEmpty) {
    if (locate.isEmpty) return null; // 空 href 且无 fragment：丢弃
    resolved = selfPath; // 纯 fragment：指向目录文件自身
  } else {
    resolved = resolveHref(baseDir, withoutFragment);
    if (resolved.isEmpty) return null;
  }

  return Chapter(
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

// ---------------------------------------------------------------------------
// DOM 小工具（package:xml）—— 与上面两个 html 版本**语义必须一致**
// ---------------------------------------------------------------------------

/// 在 `<li>` 里找第一个 `<a>`，**不下钻嵌套 `<ol>`**（xml 版）。
///
/// 不能用 `firstElementIn(li, 'a')`：它是**递归整个子树**的，
/// 当 `<li>` 自己没 `<a>` 时会取到嵌套 `<ol>` 子项的锚点，导致父级凭空多一条错层条目。
XmlElement? _firstAnchorOutsideNestedListXml(XmlElement li) {
  for (final XmlElement child in li.childElements) {
    if (child.name.local == 'ol') continue;
    if (child.name.local == 'a') return child;
    final XmlElement? found = _firstAnchorOutsideNestedListXml(child);
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
