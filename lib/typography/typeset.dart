// `TYP-04` 基础排版语义（纯 Dart + Flutter `InlineSpan`）。
//
//   · 首行缩进 2 字符（全角空格，与字号无关）；
//   · `<b>` / `<i>` 内联样式支持（白名单；其它标签原样显示文本）；
//   · `<img>` 图片标记 → `WidgetSpan`（`CNT-01` 内嵌图片渲染）；
//   · `\x00A:href\x00文字\x00A\x00` 链接标记 → 可点下划线 `TextSpan`（`CNT-04b`）；
//   · `\x00ID:id\x00` 锚点标记渲染吞掉不上屏（`CNT-04b`）。
//
// **不做完整 CSS 级联**（`TYP-04`）；不做 `<br>` / 表格 / 脚注。
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 首行缩进前缀：两个全角空格（U+3000），宽度恒 = 2 × 中文字宽。
/// 渲染（`withFirstLineIndent`）与分页测量（`page_paginator.dart` 的 `project`）共用，保证行断一致。
const String kFirstLineIndentPrefix = '\u3000\u3000';

/// 给段落文本加首行缩进（`TYP-04`）。全角空格（U+3000）宽度恒 = 1 个中文字宽、
/// 不受字号 / 字体影响，纯英文段落亦适用（约 2em，符合中文排版惯例）。
String withFirstLineIndent(String text) => '$kFirstLineIndentPrefix$text';

/// 搜索命中高亮底色（琥珀半透明；`CNT-06` 验收②「关键词高亮」）。半透明以适配
/// 亮 / 暗主题与各背景色板（`TYP-08`），不覆盖文字颜色语义（粗体 / 链接下划线）。
const Color kSearchHighlightColor = Color(0x66FFC107);

/// 划词选区高亮底色（`AI-02`/`AI-03`）。与搜索高亮同范式：只叠 `backgroundColor`、
/// 不改文字颜色语义；着色在搜索高亮**之后**应用（选中段底色以选区为准）。
const Color kSelectionHighlightColor = Color(0x6642A5F5);

/// 朗读段高亮底色（`TTS-01`/`TTS-02`）。绿色与搜索琥珀 / 选区蓝区分；
/// 同款半透明、只叠底色不改文字颜色语义。
const Color kSpeakingHighlightColor = Color(0x6666BB6A);

/// 白名单：只保留 `<b>` 和 `<i>` 的开闭标签，其它标签在上游已剥离。
final RegExp _inlineTagPattern = RegExp(r'<(/?)([bi])>');

/// 把一段含 `<b>` / `<i>` 标签的文本解析成 [InlineSpan] 列表（供 `Text.rich`）：
/// 逐字符扫标签跟踪 bold / italic 状态切出带 / 不带样式片段，未识别标签
/// **原样显示文本**（不吞内容、不报错）；[baseStyle] 为基线，bold / italic 叠加其上。
List<InlineSpan> parseInlineStyles(String text, TextStyle baseStyle) {
  final List<InlineSpan> spans = <InlineSpan>[];
  bool bold = false;
  bool italic = false;
  int cursor = 0;

  for (final Match match in _inlineTagPattern.allMatches(text)) {
    if (match.start > cursor) {
      final String segment = text.substring(cursor, match.start);
      spans.add(TextSpan(
        text: segment,
        style: _mergedStyle(baseStyle, bold, italic),
      ));
    }

    final bool isClose = match.group(1) == '/';
    final String tag = match.group(2)!;

    if (tag == 'b') bold = !isClose;
    if (tag == 'i') italic = !isClose;

    cursor = match.end;
  }

  if (cursor < text.length) {
    final String segment = text.substring(cursor);
    spans.add(TextSpan(
      text: segment,
      style: _mergedStyle(baseStyle, bold, italic),
    ));
  }

  // 空段落也要有一个空 TextSpan，否则 Text.rich 会拿到空列表。
  if (spans.isEmpty) {
    spans.add(TextSpan(text: '', style: baseStyle));
  }

  return spans;
}

/// 叠加 bold / italic 到 [base] 上；两者都不激活则返回原 [base]。
TextStyle _mergedStyle(TextStyle base, bool bold, bool italic) {
  if (!bold && !italic) return base;
  return base.copyWith(
    fontWeight: bold ? FontWeight.bold : null,
    fontStyle: italic ? FontStyle.italic : null,
  );
}

// ---------------------------------------------------------------------------
// 图片 / 链接 / 锚点标记解析（`CNT-01` 内嵌图片、`CNT-04b` 链接可点）
// ---------------------------------------------------------------------------

/// 图片标记体前缀（`section_extractor` 写入的 `\x00IMG:src\x00` 内层）。
const String _kImgMarker = 'IMG:';

/// 链接开标记体前缀（`\x00A:href\x00` 内层）。
const String _kLinkOpen = 'A:';

/// 链接闭标记体（`\x00A\x00` 内层）。
const String _kLinkClose = 'A';

/// 锚点标记体前缀（`\x00ID:id\x00` 内层）——渲染吞掉，不上屏。
const String _kIdMarker = 'ID:';

/// 把含标记的文本解析成 [InlineSpan] 列表：图片 → [WidgetSpan]（异步加载，失败占位）；
/// 链接 → 下划线 [TextSpan] + recognizer（onTap 调 [onLinkTap] 传 href；为 null 只渲染
/// 下划线不建 recognizer）；锚点吞掉不上屏。按 NUL 切分：奇数段 = 标记体，偶数段 =
/// 可见文本（可含 `<b>`/`<i>`）。recognizer 经 [recognizerSink] 交调用方 `dispose`
/// （推荐 [InlineParagraph] 自动管理）。脏数据容错**绝不抛异常**：未闭合开标记延伸到
/// 段末，孤立闭标记与未知标记体吞掉。
List<InlineSpan> parseContentSpans(
  String text,
  TextStyle baseStyle,
  Future<Uint8List?> Function(String href) resolveImage, {
  void Function(String href)? onLinkTap,
  List<TapGestureRecognizer>? recognizerSink,
}) {
  if (!text.contains('\x00')) {
    // 无任何标记：走纯文本路径（性能更优，不引入 WidgetSpan 开销）。
    return parseInlineStyles(text, baseStyle);
  }

  final List<InlineSpan> spans = <InlineSpan>[];
  final List<String> parts = text.split('\x00');
  // 当前链接状态：href 非空 = 处于链接文字内。
  String? openHref;
  TapGestureRecognizer? openRecognizer;

  // 收掉当前链接（脏数据：未闭合就开新链接 / 段末未闭合）。
  void closeLink() {
    openHref = null;
    openRecognizer = null;
  }

  for (int i = 0; i < parts.length; i++) {
    final String part = parts[i];
    if (i.isOdd) {
      if (part.startsWith(_kImgMarker)) {
        final String src = part.substring(_kImgMarker.length);
        if (src.isNotEmpty) {
          spans.add(WidgetSpan(
            child: _InlineImage(src: src, resolveImage: resolveImage),
          ));
        }
      } else if (part.startsWith(_kLinkOpen)) {
        // 脏数据容错：嵌套开标记 → 先静默收掉旧链接再开新链接。
        closeLink();
        final String href = part.substring(_kLinkOpen.length);
        if (href.isNotEmpty) {
          openHref = href;
          if (onLinkTap != null) {
            final TapGestureRecognizer recognizer = TapGestureRecognizer()
              ..onTap = () {
                onLinkTap(href);
              };
            openRecognizer = recognizer;
            recognizerSink?.add(recognizer);
          }
        }
      } else if (part == _kLinkClose) {
        closeLink();
      } else if (part.startsWith(_kIdMarker)) {
        // 锚点标记：渲染吞掉（锚点定位在 reader 层派生扫描原文）。
      }
      // 其余未知标记体 → 吞掉（防御脏数据）
    } else if (part.isNotEmpty) {
      final List<InlineSpan> segments = parseInlineStyles(part, baseStyle);
      if (openHref == null) {
        spans.addAll(segments);
      } else {
        // 链接内可含 `<b>`/`<i>`（各片段挂同一 recognizer）。
        for (final InlineSpan segment in segments) {
          final TextSpan plain = segment as TextSpan;
          spans.add(TextSpan(
            text: plain.text,
            style: _linkStyle(plain.style ?? baseStyle),
            recognizer: openRecognizer,
          ));
        }
      }
    }
  }

  if (spans.isEmpty) {
    spans.add(TextSpan(text: '', style: baseStyle));
  }
  return spans;
}

/// 链接样式：在基线上叠加下划线（`CNT-04b`）。
TextStyle _linkStyle(TextStyle base) =>
    base.copyWith(decoration: TextDecoration.underline);

/// 对已解析的 span 列表做搜索高亮后处理（`CNT-06` 验收②「关键词高亮」）：对每个
/// [TextSpan] 文本按 [query] **非重叠**切分（与各格式 `search()` 命中计数口径一致），
/// 命中片段样式叠 [color] 背景——原颜色 / 粗斜体 / 下划线全保留，[TextSpan.recognizer]
/// **复制**到所有子片段（链接整段可点性不变）；[WidgetSpan] 不参与切分。[query] 空或
/// 无命中返回原列表；本函数**不创建** recognizer（生命周期归 [InlineParagraph]）。
/// 两条解析路径产出的都是扁平 span 列表，故只做顶层切分、不递归 children。
List<InlineSpan> highlightSpans(
  List<InlineSpan> spans,
  String query, {
  Color color = kSearchHighlightColor,
}) {
  if (query.isEmpty) return spans;
  final List<InlineSpan> out = <InlineSpan>[];
  bool any = false;
  for (final InlineSpan span in spans) {
    final String? text = span is TextSpan ? span.text : null;
    if (text == null || !text.contains(query)) {
      out.add(span);
      continue;
    }
    any = true;
    final TextSpan textSpan = span as TextSpan;
    final TextStyle? base = textSpan.style;
    final TextStyle highlight =
        (base ?? const TextStyle()).copyWith(backgroundColor: color);
    int cursor = 0;
    while (true) {
      final int at = text.indexOf(query, cursor);
      if (at < 0) break;
      if (at > cursor) {
        out.add(TextSpan(
          text: text.substring(cursor, at),
          style: base,
          recognizer: textSpan.recognizer,
        ));
      }
      out.add(TextSpan(
        text: query,
        style: highlight,
        recognizer: textSpan.recognizer,
      ));
      cursor = at + query.length;
    }
    if (cursor < text.length) {
      out.add(TextSpan(
        text: text.substring(cursor),
        style: base,
        recognizer: textSpan.recognizer,
      ));
    }
  }
  return any ? out : spans;
}

/// 对已解析的 span 列表做**选区**着色后处理（`AI-02`/`AI-03` 划词高亮）：按渲染文本
/// 空间偏移 `[start, end)` 切分，命中片段叠 [color] 背景，原样式与
/// [TextSpan.recognizer] 全保留（与 [highlightSpans] 同范式）；[WidgetSpan] 按 1 个
/// 替换字符计入偏移、自身不切分；无交集返回原列表。着色在 span 内而非 overlay：
/// 分页相邻页同段双实例被 ClipRect 裁切，翻页动画期 overlay 会与文字错位，
/// span 内着色随页图层一起走，天然同步。
List<InlineSpan> selectionSpans(
  List<InlineSpan> spans,
  int start,
  int end, {
  Color color = kSelectionHighlightColor,
}) {
  if (end <= start || start < 0) return spans;
  final List<InlineSpan> out = <InlineSpan>[];
  int cursor = 0;
  bool any = false;
  for (final InlineSpan span in spans) {
    final String? text = span is TextSpan ? span.text : null;
    if (text == null) {
      out.add(span);
      cursor += 1; // WidgetSpan 占 1 个替换字符（toPlainText 同口径）。
      continue;
    }
    final int spanEnd = cursor + text.length;
    if (spanEnd <= start || cursor >= end) {
      out.add(span);
      cursor = spanEnd;
      continue;
    }
    any = true;
    final TextSpan textSpan = span as TextSpan;
    final int from = start > cursor ? start - cursor : 0;
    final int to = end < spanEnd ? end - cursor : text.length;
    if (from > 0) {
      out.add(TextSpan(
        text: text.substring(0, from),
        style: textSpan.style,
        recognizer: textSpan.recognizer,
      ));
    }
    out.add(TextSpan(
      text: text.substring(from, to),
      style: (textSpan.style ?? const TextStyle())
          .copyWith(backgroundColor: color),
      recognizer: textSpan.recognizer,
    ));
    if (to < text.length) {
      out.add(TextSpan(
        text: text.substring(to),
        style: textSpan.style,
        recognizer: textSpan.recognizer,
      ));
    }
    cursor = spanEnd;
  }
  return any ? out : spans;
}

/// 整段可点链接的段落 widget（`CNT-04b`）：管理 recognizer 生命周期——span 因输入
/// 变化重建时，旧 recognizer 延后到帧结束再释放（当前帧渲染树仍可能引用旧 span 的
/// recognizer，立即 dispose 会崩）；State.dispose 时释放当前批。输入不变的 rebuild
/// 复用缓存 span 列表，不重复创建 recognizer。
class InlineParagraph extends StatefulWidget {
  const InlineParagraph({
    super.key,
    required this.text,
    required this.style,
    required this.resolveImage,
    this.onLinkTap,
    this.highlightQuery,
    this.selection,
  });

  /// 含标记的段落文本（`section_extractor` 抽取产物）。
  final String text;

  /// 基线样式。
  final TextStyle style;

  /// 图片加载回调（`BookSource.readResource`）。
  final Future<Uint8List?> Function(String href) resolveImage;

  /// 链接点击回调（href 为归一化形态）；null = 链接不可点，仅下划线展示。
  final void Function(String href)? onLinkTap;

  /// 搜索高亮关键词（`CNT-06` 验收②）：非空时命中片段叠高亮底色（[highlightSpans]
  /// 后处理，快路径与标记路径都覆盖）；`null` / 空串 = 不高亮。
  final String? highlightQuery;

  /// 划词选区（`AI-02`/`AI-03`）：渲染文本空间 `[start, end)` 非空时该段对应片段叠
  /// 选区底色（[selectionSpans] 后处理，在搜索高亮**之后**）；`null` = 无选区。
  final ({int start, int end})? selection;

  @override
  State<InlineParagraph> createState() => _InlineParagraphState();
}

class _InlineParagraphState extends State<InlineParagraph> {
  List<InlineSpan> _spans = <InlineSpan>[];
  List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _buildSpans();
  }

  @override
  void didUpdateWidget(covariant InlineParagraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.onLinkTap != widget.onLinkTap ||
        oldWidget.highlightQuery != widget.highlightQuery ||
        oldWidget.selection != widget.selection) {
      final List<TapGestureRecognizer> stale = _recognizers;
      _buildSpans();
      // 旧批延后到帧结束释放：当前帧渲染树仍引用旧 span 的 recognizer。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final TapGestureRecognizer recognizer in stale) {
          recognizer.dispose();
        }
      });
    }
  }

  void _buildSpans() {
    final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
    List<InlineSpan> spans = parseContentSpans(
      widget.text,
      widget.style,
      widget.resolveImage,
      onLinkTap: widget.onLinkTap,
      recognizerSink: sink,
    );
    // `CNT-06` 验收②：搜索高亮后处理（快路径与标记路径统一在此收口）。
    final String? query = widget.highlightQuery;
    if (query != null && query.isNotEmpty) {
      spans = highlightSpans(spans, query);
    }
    // `AI-02`/`AI-03`：选区着色在搜索高亮之后（选中段底色以选区为准）。
    final ({int start, int end})? selection = widget.selection;
    if (selection != null && selection.end > selection.start) {
      spans = selectionSpans(spans, selection.start, selection.end);
    }
    _spans = spans;
    _recognizers = sink;
  }

  @override
  void dispose() {
    for (final TapGestureRecognizer recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers = <TapGestureRecognizer>[];
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(TextSpan(children: _spans));
  }
}

/// 异步加载的内嵌图片 widget（`CNT-01`）：`initState` 发起加载（`_bytes` 缓存在
/// State，rebuild 不重新加载），加载中 / 失败分别显示进度 / 占位图标。
class _InlineImage extends StatefulWidget {
  const _InlineImage({required this.src, required this.resolveImage});

  /// 图片的绝对包内路径（已由 `section_extractor` 归一化）。
  final String src;

  /// 图片加载回调（`BookSource.readResource`）。
  final Future<Uint8List?> Function(String href) resolveImage;

  @override
  State<_InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends State<_InlineImage> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Uint8List? bytes = await widget.resolveImage(widget.src);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
        _error = bytes == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error || _bytes == null) {
      return SizedBox(
        width: 48,
        height: 48,
        child: Icon(
          Icons.broken_image,
          size: 32,
          color: Theme.of(context).colorScheme.outline,
        ),
      );
    }
    return Image.memory(
      _bytes!,
      fit: BoxFit.contain,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
        return SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.broken_image,
            size: 32,
            color: Theme.of(context).colorScheme.outline,
          ),
        );
      },
    );
  }
}
