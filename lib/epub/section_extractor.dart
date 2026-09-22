// XHTML -> 纯文本段落。纯 Dart，不依赖 Flutter。
//
// 只做「够用」的块级结构保留：<p> / <div> / <br> / <h1..h6> / <li> 等视为段落边界。
// 图片、CSS、脚注、ruby、SVG 一律优雅跳过，绝不因为脏 HTML 崩掉。
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'text_codec.dart';
import 'zip_paths.dart';

/// 一章解析后的可显示内容。
class ExtractedSection {
  const ExtractedSection({this.title = '', this.paragraphs = const <String>[]});

  /// 章标题：优先取正文里第一个 h1~h6，退而取 `<title>`（长度合理时）；取不到则为空串。
  final String title;

  /// 段落列表，按出现顺序。渲染时用 '\n\n' 连接即可保留段间距。
  final List<String> paragraphs;

  bool get isEmpty => paragraphs.isEmpty;
}

/// 会被当作「段落边界」的块级标签。
const Set<String> _blockTags = <String>{
  'p', 'div', 'br', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'li', 'ul', 'ol', 'blockquote', 'pre', 'section', 'article',
  'header', 'footer', 'aside', 'figure', 'figcaption',
  'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th',
  'dd', 'dt', 'dl', 'hr', 'nav', 'main', 'address',
};

/// 直接整棵跳过的标签（不产生任何文本）。
const Set<String> _skipTags = <String>{
  'script', 'style', 'head', 'title', 'meta', 'link', 'svg', 'noscript',
  'audio', 'video', 'iframe', 'object', 'embed',
};

/// 把一章 XHTML 的原始字节解析成 [ExtractedSection]。
///
/// 这是纯函数（无 IO、无 Flutter），可以直接单测。
///
/// [baseDir]：XHTML 文件所在目录的包内路径（如 `OEBPS/text`），用于把
/// `<img src="...">` 的相对路径归一化为绝对包内路径。为空时 src 原样保留。
ExtractedSection extractSection(Uint8List bytes, {String baseDir = ''}) {
  final String? decoded = _tryDecodeText(bytes);
  if (decoded == null) return const ExtractedSection();
  final String source = decoded;

  final dom.Document? doc = _tryParseHtml(source);
  if (doc == null) {
    // 连宽松解析都失败：退化为「粗暴去标签」，至少让用户看到字。
    return ExtractedSection(paragraphs: _stripTags(source));
  }

  final dom.Element? body = doc.body ?? doc.documentElement;
  if (body == null) return const ExtractedSection();

  final List<String> paragraphs = <String>[];
  final StringBuffer buffer = StringBuffer();
  _walk(body, paragraphs, buffer, baseDir);
  _flush(buffer, paragraphs);

  final _ResolvedTitle title = _resolveTitle(body, doc);

  // 只有当「章标题取自正文里的 h1~h6」时，才把与之重复的首段去掉，
  // 避免「UI 单独渲染的标题」与「正文首段」重复显示同一句话。
  // 若标题其实来自 XHTML 的 `<title>`（正文里没有对应的标题块），
  // 那么首段是**真正的正文**，绝不能删（回归 fixture 覆盖此点）。
  final List<String> visible = (title.fromHeading &&
          title.text.isNotEmpty &&
          paragraphs.isNotEmpty &&
          paragraphs.first == title.text)
      ? paragraphs.sublist(1)
      : paragraphs;

  return ExtractedSection(title: title.text, paragraphs: visible);
}

/// 尝试解码；失败返回 null。
String? _tryDecodeText(Uint8List bytes) {
  try {
    return decodeText(bytes);
  } catch (_) {
    return null;
  }
}

/// 尝试用宽松 HTML 解析器解析；失败返回 null。
dom.Document? _tryParseHtml(String source) {
  try {
    return html_parser.parse(source);
  } catch (_) {
    return null;
  }
}

/// 内联标签白名单：保留为段落文本里的 HTML 标签，供 `typeset.dart` 的
/// `parseInlineStyles` 解析为 `TextSpan`（`TYP-04` `<b>` / `<i>` 支持）。
///
/// 其它内联标签（`<span>` / `<a>` / `<em>` 等）的文本内容正常保留，但标签本身剥掉。
const Set<String> _preservedInlineTags = <String>{'b', 'i'};

/// 深度优先遍历，遇到块级标签就切段。
///
/// [baseDir] 用于把 `<img src="...">` 的相对路径归一化为绝对包内路径。
void _walk(dom.Node node, List<String> out, StringBuffer buffer, String baseDir) {
  for (final dom.Node child in node.nodes) {
    if (child is dom.Text) {
      // HTML 规则：空白折叠成单个空格。
      buffer.write(child.text.replaceAll(RegExp(r'\s+'), ' '));
      continue;
    }
    if (child is! dom.Element) continue;

    final String tag = child.localName?.toLowerCase() ?? '';
    if (_skipTags.contains(tag)) continue;

    // <br>：行内换行（`CNT-02`）——写入 '\n' 不切段，诗歌等逐行内容
    // 保持「行距」而非「段间距」。'\n' 是代码写入的，不受 Text 节点
    // 空白折叠影响；_flush 的 trim 会自然去掉段首段尾换行。
    if (tag == 'br') {
      buffer.write('\n');
      continue;
    }
    // <hr>：段落分割（保持既有语义）。
    if (tag == 'hr') {
      _flush(buffer, out);
      continue;
    }

    // <img>：写入图片占位标记（NUL 包裹，不会出现在正常文本里）。
    // src 路径归一化为绝对包内路径（相对于 XHTML 文件所在目录）。
    if (tag == 'img') {
      final String? src = child.attributes['src'];
      if (src != null && src.trim().isNotEmpty) {
        final String resolved =
            baseDir.isEmpty ? src.trim() : resolveHref(baseDir, src.trim());
        buffer.write('\x00IMG:$resolved\x00');
      }
      continue; // <img> 是 void 元素，无子节点
    }

    final bool isBlock = _blockTags.contains(tag);
    if (isBlock) _flush(buffer, out);

    // 保留白名单内联标签（`<b>` / `<i>`），写成字面 HTML 供渲染层解析。
    final bool preserve = _preservedInlineTags.contains(tag);
    if (preserve) buffer.write('<$tag>');
    _walk(child, out, buffer, baseDir);
    if (preserve) buffer.write('</$tag>');

    if (isBlock) _flush(buffer, out);
  }
}

/// 把当前缓冲冲成一个段落（trim 后为空则丢弃）。
void _flush(StringBuffer buffer, List<String> out) {
  final String text = buffer.toString().trim();
  buffer.clear();
  if (text.isEmpty) return;
  out.add(text);
}

/// 章标题及其来源。
class _ResolvedTitle {
  const _ResolvedTitle(this.text, {required this.fromHeading});

  /// 标题文本；取不到为空串。
  final String text;

  /// 来源：取自正文里的 h1~h6（true）还是 XHTML 的 `<title>`（false）。
  final bool fromHeading;
}

/// 章标题：h1~h6 -> `<title>`（长度 <= 60 才采用，避免那句「书名 - 出版社」）。
///
/// 返回值额外标注来源：只有来源是正文标题块（h1~h6）时，调用方才应把重复的首段去掉
/// （见 [extractSection]）；来自 `<title>` 时首段是真正文，不能删。
_ResolvedTitle _resolveTitle(dom.Element body, dom.Document doc) {
  for (final String tag in const <String>['h1', 'h2', 'h3', 'h4', 'h5', 'h6']) {
    final dom.Element? element = _firstElementByTag(body, tag);
    if (element == null) continue;
    final String text = _collapse(element.text);
    if (text.isNotEmpty) return _ResolvedTitle(text, fromHeading: true);
  }

  final dom.Element? titleElement = _firstElementByTag(doc, 'title');
  if (titleElement != null) {
    final String text = _collapse(titleElement.text);
    if (text.isNotEmpty && text.length <= 60) {
      return _ResolvedTitle(text, fromHeading: false);
    }
  }
  return const _ResolvedTitle('', fromHeading: false);
}

String _collapse(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 按标签名找第一个后代元素（大小写不敏感）。
dom.Element? _firstElementByTag(dom.Node root, String tag) {
  for (final dom.Node node in root.nodes) {
    if (node is! dom.Element) continue;
    if (node.localName?.toLowerCase() == tag) return node;
    final dom.Element? found = _firstElementByTag(node, tag);
    if (found != null) return found;
  }
  return null;
}

/// 最后兜底：正则去标签。
List<String> _stripTags(String source) {
  final String text = source
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty) return const <String>[];
  return <String>[text];
}

/// 从 [fragment] 锚点起的段落（`Chapter.locate` 的 **best-effort** 实现）。
///
/// 语义：在 XHTML 里找 `id`（或 `name`）等于 [fragment] 的元素，**只保留它之后的内容**
/// （文档序：锚点子树 → 其后续兄弟 → 逐层向上的后续兄弟）。
///
/// 容错：找不到锚点、解析失败、[fragment] 为空 —— 一律**退回整章段落**，
/// 绝不抛异常也不返回空（脏书里锚点丢失很常见，「显示整章」远好于「报错不给读」）。
///
/// [baseDir]：XHTML 文件所在目录的包内路径，用于 `<img src>` 路径归一化。
List<String> extractParagraphsFromFragment(
  Uint8List bytes,
  String fragment, {
  String baseDir = '',
}) {
  final String needle = fragment.trim();
  final String? decoded = _tryDecodeText(bytes);
  if (decoded == null) return const <String>[];

  final dom.Document? doc = _tryParseHtml(decoded);
  if (doc == null) return _stripTags(decoded);

  final dom.Element? body = doc.body ?? doc.documentElement;
  if (body == null) return const <String>[];

  final List<String> whole = <String>[];
  final StringBuffer wholeBuffer = StringBuffer();
  _walk(body, whole, wholeBuffer, baseDir);
  _flush(wholeBuffer, whole);
  if (needle.isEmpty) return whole;

  final dom.Element? anchor = _findAnchor(body, needle);
  if (anchor == null) return whole;

  final List<String> paragraphs = <String>[];
  final StringBuffer buffer = StringBuffer();
  _walk(anchor, paragraphs, buffer, baseDir);
  _flush(buffer, paragraphs);
  for (final dom.Node node in _nodesAfter(anchor)) {
    _walk(node, paragraphs, buffer, baseDir);
    _flush(buffer, paragraphs);
  }
  return paragraphs;
}

/// 找 `id` 或 `name` 等于 [id] 的元素（锚点常写成 `<a id="…">` 或 `<a name="…">`）。
dom.Element? _findAnchor(dom.Node root, String id) {
  for (final dom.Node node in root.nodes) {
    if (node is! dom.Element) continue;
    if (node.id == id) return node;
    final String? name = node.attributes['name'];
    if (name != null && name == id) return node;
    final dom.Element? found = _findAnchor(node, id);
    if (found != null) return found;
  }
  return null;
}

/// 文档序中 [target] **之后**的全部节点（先近后远：后续兄弟 -> 逐层向上的后续兄弟）。
List<dom.Node> _nodesAfter(dom.Node target) {
  final List<List<dom.Node>> levels = <List<dom.Node>>[];
  dom.Node? cur = target;
  while (cur != null && cur is! dom.Document) {
    final dom.Node? parent = cur.parentNode;
    if (parent != null) {
      final List<dom.Node> siblings = parent.nodes;
      final int index = siblings.indexOf(cur);
      if (index >= 0 && index + 1 < siblings.length) {
        levels.add(siblings.sublist(index + 1));
      }
    }
    cur = parent;
  }
  final List<dom.Node> ordered = <dom.Node>[];
  for (final List<dom.Node> level in levels.reversed) {
    ordered.addAll(level);
  }
  return ordered;
}
