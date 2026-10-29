// XHTML -> 纯文本段落。纯 Dart，不依赖 Flutter。
//
// 只做「够用」的块级结构保留：<p> / <div> / <h1..h6> / <li> 等视为段落边界；
// <br> 为行内换行（CNT-02），<table> 按行退化为纯文本（CNT-03）；链接与锚点写成 NUL 包裹标记（CNT-04a，格式见 [extractSection] 的 dart doc）。
// 图片、CSS、脚注、ruby、SVG 一律优雅跳过，绝不因为脏 HTML 崩掉。
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../diagnostics/perf_log.dart';
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

/// 把一章 XHTML 的原始字节解析成 [ExtractedSection]（纯函数，可直接单测）。
///
/// [baseDir]：XHTML 文件所在目录的包内路径（如 `OEBPS/text`），用于把
/// `<img src="...">` 的相对路径归一化为绝对包内路径；为空时 src 原样保留。
///
/// ## CNT-04a 标记格式（NUL 包裹，渲染层吞掉、绝不显示到屏幕上）
///
/// | 标记 | 含义 |
/// |---|---|
/// | `\x00A:<href>\x00文字\x00A\x00` | 链接：归一化后的 href 包住所包文字 |
/// | `\x00ID:<id>\x00` | 锚点：跳转目标；块级元素的标记位于**段落开头** |
///
/// 两类标记可共存于同一段落（脚注返回锚：段首 ID + 段内链接）。href 归一化口径：
/// `#frag` 原样保留；跨文件与 `<img src>` 同走 [resolveHref]（fragment 切出后接回）。
/// 查询：章内 `#id` = `paragraphs.indexWhere((p) => p.contains('\x00ID:$id\x00'))`；
/// 链接 = 按 `\x00` 切分后奇数段以 `A:` 开头者即 href（闭合标记为 `A`）。
ExtractedSection extractSection(Uint8List bytes, {String baseDir = ''}) {
  // ── 首帧「一次性门」定位探针（§2.69 附四/五）──
  // 把 `extractSection` 内部切成三段计时：三段之和远小于 `reader.content` 总耗时 ⇒
  // 慢在**门外**（引擎 / 归档读取器首触），「提前开门」方案才有效。
  // 用 PerfWatch 保持 `reader.*` 口径，且可被 `--dart-define=MREADER_PERF_LOG=false` 整体静音。
  final PerfWatch decodeWatch = PerfLog.watch('se.decode');
  final String? decoded = _tryDecodeText(bytes);
  decodeWatch.done('rawKB=${bytes.length ~/ 1024}');
  if (decoded == null) return const ExtractedSection();
  final String source = decoded;

  final PerfWatch parseWatch = PerfLog.watch('se.parse');
  final dom.Document? doc = _tryParseHtml(source);
  parseWatch.done('chars=${source.length}');
  if (doc == null) {
    // 连宽松解析都失败：退化为「粗暴去标签」，至少让用户看到字。
    return ExtractedSection(paragraphs: _stripTags(source));
  }

  final dom.Element? body = doc.body ?? doc.documentElement;
  if (body == null) return const ExtractedSection();

  final PerfWatch walkWatch = PerfLog.watch('se.walk');
  final List<String> paragraphs = <String>[];
  final StringBuffer buffer = StringBuffer();
  _walk(body, paragraphs, buffer, baseDir);
  _flush(buffer, paragraphs);
  // CNT-04a：纯标记段落（块级 id 嵌套块级子元素时产生）接力到相邻段落。
  _mergeMarkerOnlyParagraphs(paragraphs);
  walkWatch.done('paras=${paragraphs.length}');

  final _ResolvedTitle title = _resolveTitle(body, doc);

  // 只有「章标题取自正文里的 h1~h6」时才把与之重复的首段去掉（避免与 UI 单独渲染的
  // 标题重复）；若标题来自 `<title>`，首段是**真正的正文**，绝不能删。
  // 比较用「剥离标记后的可见文本」（CNT-04a：带 id 的 h1 首段含 ID 标记）。
  final bool dropFirstTitle = title.fromHeading &&
      title.text.isNotEmpty &&
      paragraphs.isNotEmpty &&
      _visibleText(paragraphs.first) == title.text;
  final List<String> visible =
      dropFirstTitle ? paragraphs.sublist(1) : paragraphs;
  // 首段被剥去时，把它开头的标记接力到新的首段——指向标题的锚点不失效。
  if (dropFirstTitle && visible.isNotEmpty) {
    final String markers =
        _kLeadingMarkers.firstMatch(paragraphs.first)?.group(0) ?? '';
    if (markers.isNotEmpty) visible[0] = markers + visible[0];
  }

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
/// 其它内联标签（`<span>` / `<em>` 等）只留文字；`<a>` 特殊（CNT-04a）：
/// 带 href 时写 `\x00A:…\x00` 链接标记，无 href 只留文字。
const Set<String> _preservedInlineTags = <String>{'b', 'i'};

/// 深度优先遍历，遇到块级标签就切段。
///
/// 例外（专用路径，不走通用切段）：`<br>` 行内换行（`CNT-02`）、
/// `<table>` 按行退化为纯文本（`CNT-03`，见 [_walkTable]）。
/// [baseDir] 用于把 `<img src="...">` 的相对路径归一化为绝对包内路径。
void _walk(dom.Node node, List<String> out, StringBuffer buffer, String baseDir) {
  // 入口节点本身是 <table>（fragment 定位路径可能直接给出表节点）时同样走按行退化，
  // 不退回「每单元格一段」的切法。
  if (node is dom.Element && _tagName(node) == 'table') {
    _flush(buffer, out);
    _walkTable(node, out, baseDir);
    return;
  }
  for (final dom.Node child in node.nodes) {
    if (child is dom.Text) {
      // HTML 规则：空白折叠成单个空格。
      buffer.write(child.text.replaceAll(_kWhitespaceRun, ' '));
      continue;
    }
    if (child is! dom.Element) continue;

    final String tag = _tagName(child);
    if (_skipTags.contains(tag)) continue;

    // <br>：行内换行（`CNT-02`）——写入 '\n' 不切段，诗歌等逐行内容保持「行距」。
    // '\n' 由代码写入、不受空白折叠影响；_flush 的 trim 会去掉段首段尾换行。
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

    // <table>：按行退化为纯文本（`CNT-03`）——悬挂文本先成段，行的组装（单元格
    // ' | ' 连接、整行一个段落）全在 _walkTable 内完成，不走通用块逻辑。
    if (tag == 'table') {
      _flush(buffer, out);
      _walkTable(child, out, baseDir);
      continue;
    }

    final bool isBlock = _blockTags.contains(tag);
    if (isBlock) _flush(buffer, out);

    // CNT-04a：id / name 锚点标记。块级 flush 之后写入 → 标记位于段落**开头**
    // （「跳到 #id」= 找含该标记的段落滚过去）；内联元素（如 `<a id>`）落在当前
    // 缓冲位置；可与链接标记共存（脚注返回锚的常见组合）。
    final String? anchorId = _anchorIdOf(child);
    if (anchorId != null) buffer.write('\x00ID:$anchorId\x00');

    // CNT-04a：`<a href>` 链接标记——归一化后的 href 包住所包文字；无 href 不产生标记。
    final String? linkHref =
        tag == 'a' ? _normalizeLinkHref(baseDir, child.attributes['href']) : null;
    if (linkHref != null) buffer.write('\x00A:$linkHref\x00');

    // 保留白名单内联标签（`<b>` / `<i>`），写成字面 HTML 供渲染层解析。
    final bool preserve = _preservedInlineTags.contains(tag);
    if (preserve) buffer.write('<$tag>');
    _walk(child, out, buffer, baseDir);
    if (preserve) buffer.write('</$tag>');

    if (linkHref != null) buffer.write('\x00A\x00');

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

// ---------------------------------------------------------------------------
// CNT-04a：链接与锚点标记
// ---------------------------------------------------------------------------

/// 段落里成对的 NUL 标记（`\x00…\x00`）。
final RegExp _kAnyMarkerPair = RegExp(r'\x00[^\x00]*\x00');

/// 段落**开头**连续的 NUL 标记（用于标题剥离时把锚点接力到下一段）。
final RegExp _kLeadingMarkers = RegExp(r'^(?:\x00[^\x00]*\x00)+');

/// **HTML 空白折叠**（一串连续空白 → 单个空格）。
///
/// 必须提成 `static final`：曾在 [_walk] 的**每个 Text 节点**上现场构造 `RegExp`，
/// 实测是开书 CPU 的大户；提出后只构造一次（首次使用时），`\s+` 语义**一字未改**。
final RegExp _kWhitespaceRun = RegExp(r'\s+');

/// 兜底去标签用的「任意标签」模式（仅 [_stripTags] 一处用，构造次数可忽略）。
final RegExp _kAnyTag = RegExp(r'<[^>]*>');

/// 取标签名的**小写**形式，供 `_skipTags` / `_blockTags` 等小写集合比对。
///
/// ## R2：为什么不是直接 `localName.toLowerCase()`（§2.69 附九）
/// [_walk] 对**每个元素节点**都要调一次，而 `toLowerCase()` 即便已小写也要完整扫描
/// 并分配新串（实测开书窗口的大头之一）；小写化本身**不能删**（HTML 允许 `<P>`、
/// `<BR>`，脏书 fixture 覆盖大写标签）。故先做「是否已小写」的廉价判定
/// （`codeUnitAt` 逐字符比、零分配）：已小写（绝大多数节点）**直接返回原串**；
/// 含大写才退回 `toLowerCase()`，**语义一字不差**。
String _tagName(dom.Element element) {
  final String? name = element.localName;
  if (name == null || name.isEmpty) return '';
  for (int i = 0; i < name.length; i++) {
    final int c = name.codeUnitAt(i);
    // 'A'(65) ~ 'Z'(90) 与 'a'(97) ~ 'z'(122) 同时出现 ⇒ 必然含大写。
    if (c >= 65 && c <= 90 && c < 97) return name.toLowerCase();
    if (c >= 97 && c <= 122) continue; // 小写字母：继续
    // 非 ASCII（中文标签名等）：UTF-16 里不会有 >122 的 ASCII 大写，
    // 但可能有中文；中文 `toLowerCase()` 是恒等，**直接返回**即可。
    return name.toLowerCase();
  }
  return name; // 全小写：原样返回
}

/// 剥离全部 NUL 标记后的可见文本（渲染层吞标记，口径与之一致）。
String _visibleText(String paragraph) =>
    paragraph.replaceAll(_kAnyMarkerPair, '').replaceAll('\x00', '').trim();

/// 元素的锚点 id：优先 `id` 属性；`<a>` 兼容旧式 `name`（脚注常用）。
String? _anchorIdOf(dom.Element element) {
  final String? id = element.attributes['id'];
  if (id != null && id.trim().isNotEmpty) return id.trim();
  final String tag = element.localName?.toLowerCase() ?? '';
  if (tag == 'a') {
    final String? name = element.attributes['name'];
    if (name != null && name.trim().isNotEmpty) return name.trim();
  }
  return null;
}

/// 归一化 `<a href>`：纯 fragment（`#fn1`）原样；跨文件路径走 [resolveHref]
/// （与 `<img src>` 同一手法），fragment 单独切出后接回（resolveHref 会丢弃它）。
///
/// 返回 `null` 表示不产生链接标记（无 href / 空白 href）。
String? _normalizeLinkHref(String baseDir, String? raw) {
  if (raw == null) return null;
  final String href = raw.trim();
  if (href.isEmpty) return null;
  final int hash = href.indexOf('#');
  if (hash == 0) return href; // 纯 `#fragment`：保持原样
  final String pathPart = hash > 0 ? href.substring(0, hash) : href;
  final String fragment = hash > 0 ? href.substring(hash) : '';
  if (pathPart.trim().isEmpty) return href; // 防御畸形 ` #x`
  return resolveHref(baseDir, pathPart) + fragment;
}

/// CNT-04a：把「纯标记段落」（只有 ID/链接标记、无可见文字）并入相邻段落。
///
/// 块级带 id 元素嵌套块级子元素时（`<aside id="fn"><p>…</p></aside>`）ID 标记会被
/// flush 成独立纯标记段（渲染层吞标记后是空白段），接力到**下一段**开头（锚点语义 =
/// 下一段内容的位置）；无下一段则挂上一段末尾；整章皆空则丢弃。
void _mergeMarkerOnlyParagraphs(List<String> paragraphs) {
  for (int i = 0; i < paragraphs.length;) {
    if (_visibleText(paragraphs[i]).isNotEmpty) {
      i++;
      continue;
    }
    final String markers = paragraphs.removeAt(i);
    if (i < paragraphs.length) {
      paragraphs[i] = markers + paragraphs[i];
    } else if (paragraphs.isNotEmpty) {
      paragraphs[paragraphs.length - 1] += markers;
    }
    // 空列表 / 仅此一段：丢弃（无可见内容，且渲染层会吞掉标记）。
  }
}

/// CNT-03：把 `<table>` 退化为「每个 `<tr>` 一个段落」的纯文本。
///
/// - `<caption>` 退化为表格前的独立段落（内容不丢失）；
/// - 收集所有 `<tr>`（透明穿过 `thead` / `tbody` / `tfoot`，不进入嵌套表格或单元格
///   ——那些随所在单元格递归降级，避免同一内容既并入单元格又单独成行）；
/// - 每行 `td` / `th` 文本以 `' | '` 连接，整行只产出一个段落，整行无内容不产出；
/// - 单元格内容仍走通用 [_walk]（`<b>` / `<i>` 保留字面标签、`<br>` 变 `'\n'`、
///   嵌套表格递归降级）；产出纯文本随渲染自然折行，宽表格不横向溢出。
void _walkTable(dom.Element table, List<String> out, String baseDir) {
  // <caption>：表题/表说明退化为表格前的独立段落，避免内容丢失。
  for (final dom.Node child in table.nodes) {
    if (child is dom.Element && _tagName(child) == 'caption') {
      final List<String> caption = <String>[];
      final StringBuffer captionBuffer = StringBuffer();
      _walk(child, caption, captionBuffer, baseDir);
      _flush(captionBuffer, caption);
      out.addAll(caption);
    }
  }

  final List<dom.Element> rows = <dom.Element>[];
  _collectTableRows(table, rows);
  for (final dom.Element tr in rows) {
    final List<String> cells = <String>[];
    for (final dom.Element cell in _rowCells(tr)) {
      final List<String> cellParagraphs = <String>[];
      final StringBuffer cellBuffer = StringBuffer();
      _walk(cell, cellParagraphs, cellBuffer, baseDir);
      _flush(cellBuffer, cellParagraphs);
      cells.add(cellParagraphs.join('\n'));
    }
    // 整行无内容（全空单元格）不产出段落。
    if (!cells.any((String text) => text.isNotEmpty)) continue;
    out.add(cells.join(' | ').trim());
  }
}

/// 收集 [root]（`<table>`）子树里的所有 `<tr>`（文档序）：透明穿过 `thead` / `tbody`
/// / `tfoot` 包装层，在 `tr` 处停下，跳过嵌套 `<table>` 与 `td` / `th`（嵌套内容随
/// 所在单元格递归处理，避免既并入单元格文本又单独成行的重复）。
void _collectTableRows(dom.Node root, List<dom.Element> rows) {
  for (final dom.Node child in root.nodes) {
    if (child is! dom.Element) continue;
    final String tag = child.localName?.toLowerCase() ?? '';
    if (tag == 'tr') {
      rows.add(child);
      continue;
    }
    if (tag == 'table' || tag == 'td' || tag == 'th') continue;
    _collectTableRows(child, rows);
  }
}

/// 收集一行（`<tr>`）内的 `td` / `th` 单元格（文档序）：不进入单元格内部找单元格
/// （畸形嵌套忽略），也不进入嵌套 `<table>`（内容随所在单元格的 [_walk] 递归降级）。
List<dom.Element> _rowCells(dom.Element tr) {
  final List<dom.Element> cells = <dom.Element>[];
  void visit(dom.Node node) {
    for (final dom.Node child in node.nodes) {
      if (child is! dom.Element) continue;
      final String tag = child.localName?.toLowerCase() ?? '';
      if (tag == 'td' || tag == 'th') {
        cells.add(child);
      } else if (tag != 'table') {
        visit(child);
      }
    }
  }

  visit(tr);
  return cells;
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
/// 返回值额外标注来源：只有来源是正文标题块（h1~h6）时调用方才应把重复的首段去掉
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

String _collapse(String value) =>
    value.replaceAll(_kWhitespaceRun, ' ').trim();

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
      .replaceAll(_kAnyTag, ' ')
      .replaceAll(_kWhitespaceRun, ' ')
      .trim();
  if (text.isEmpty) return const <String>[];
  return <String>[text];
}

/// 从 [fragment] 锚点起的段落（`Chapter.locate` 的 **best-effort** 实现）。
///
/// 语义：找 `id`（或 `name`）等于 [fragment] 的元素，**只保留它之后的内容**（文档序：
/// 锚点子树 → 后续兄弟 → 逐层向上的后续兄弟）。容错：找不到锚点 / 解析失败 /
/// [fragment] 为空一律**退回整章段落**，绝不抛异常也不返回空（脏书锚点丢失常见，
/// 「显示整章」远好于「报错不给读」）。
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
  _mergeMarkerOnlyParagraphs(whole);
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
  _mergeMarkerOnlyParagraphs(paragraphs);
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
