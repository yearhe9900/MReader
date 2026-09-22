// `TYP-04` 基础排版语义（纯 Dart + Flutter `InlineSpan`）。
//
//   · 首行缩进 2 字符（全角空格，与字号无关）；
//   · `<b>` / `<i>` 内联样式支持（白名单；其它标签原样显示文本）；
//   · `<img>` 图片标记 → `WidgetSpan`（`CNT-01` 内嵌图片渲染）；
//   · `\x00A:href\x00文字\x00A\x00` 链接标记 → 可点下划线 `TextSpan`（`CNT-04b`）；
//   · `\x00ID:id\x00` 锚点标记渲染吞掉不上屏（`CNT-04b`）。
//
// **不做完整 CSS 级联**（`TYP-04` 明确说不做）；不做 `<br>` / 表格 / 脚注（`M2a-T02`）。
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 首行缩进前缀：两个全角空格（U+3000），宽度恒 = 2 × 中文字宽。
const String _kIndentPrefix = '\u3000\u3000';

/// 给段落文本加首行缩进（`TYP-04`）。
///
/// 全角空格（U+3000）宽度恒 = 1 个中文字宽，不受字号 / 字体影响。
/// 对纯英文段落亦适用（宽度约 2em，符合中文排版惯例）。
String withFirstLineIndent(String text) => '$_kIndentPrefix$text';

/// 白名单：只保留 `<b>` 和 `<i>` 的开闭标签，其它标签在上游已剥离。
final RegExp _inlineTagPattern = RegExp(r'<(/?)([bi])>');

/// 把一段含 `<b>` / `<i>` 标签的文本解析成 [InlineSpan] 列表，供 `Text.rich` 消费。
///
/// 逐字符扫标签，跟踪 bold / italic 状态，切出「带样式」与「不带样式」片段。
/// 未识别标签（如 `<unknown>`）**原样显示文本**（不吞内容、不报错）。
///
/// [baseStyle] 作为基线；bold / italic 叠加在其上（`copyWith`）。
List<InlineSpan> parseInlineStyles(String text, TextStyle baseStyle) {
  final List<InlineSpan> spans = <InlineSpan>[];
  bool bold = false;
  bool italic = false;
  int cursor = 0;

  for (final Match match in _inlineTagPattern.allMatches(text)) {
    // 标签之前的纯文本。
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

  // 尾部纯文本。
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

/// 把一段含标记的文本解析成 [InlineSpan] 列表。
///
/// 标记格式（与 `section_extractor.dart` 写入一致）：
/// - 图片：`\x00IMG:src\x00` → [WidgetSpan]（异步加载，失败占位图标）；
/// - 链接：`\x00A:href\x00文字\x00A\x00` → 文字带下划线 [TextSpan]，
///   挂 [TapGestureRecognizer]，onTap 时调 [onLinkTap] 传出 href；
/// - 锚点：`\x00ID:id\x00` → 吞掉（不上屏，不产生 span）。
///
/// 按 NUL 切分：奇数段 = 标记体，偶数段 = 可见文本（可能含 `<b>`/`<i>`）。
///
/// recognizer 生命周期由调用方管理：所有 recognizer 经 [recognizerSink]
/// 收集，调用方负责 `dispose`（推荐用 [InlineParagraph]，自动管理）。
/// [onLinkTap] 为 null 时链接只渲染下划线样式，不创建 recognizer。
///
/// 脏数据容错：未闭合的 `\x00A:` 开标记延伸到段末；孤立 `\x00A\x00`
/// 闭标记吞掉；未知标记体（非 IMG/A/ID）吞掉。绝不抛异常。
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
  // 按 NUL 字符分割：奇数段 = 标记体，偶数段 = 可见文本。
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
      // 可见文本段：调 parseInlineStyles 处理 <b>/<i>。
      final List<InlineSpan> segments = parseInlineStyles(part, baseStyle);
      if (openHref == null) {
        spans.addAll(segments);
      } else {
        // 链接文字：叠加下划线样式 + recognizer（链接内可含 <b>/<i>）。
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

/// 整段可点链接的段落 widget（`CNT-04b`）：管理 recognizer 生命周期。
///
/// [parseContentSpans] 创建的 [TapGestureRecognizer] 必须 `dispose`：
/// - span 因输入变化重建时，旧 recognizer 延后到帧结束再释放
///   （当前帧渲染树仍可能引用旧 span 的 recognizer，立即 dispose 会崩）；
/// - State.dispose 时释放当前批。
/// 输入不变的 rebuild 复用缓存 span 列表，不重复创建 recognizer。
class InlineParagraph extends StatefulWidget {
  const InlineParagraph({
    super.key,
    required this.text,
    required this.style,
    required this.resolveImage,
    this.onLinkTap,
  });

  /// 含标记的段落文本（`section_extractor` 抽取产物）。
  final String text;

  /// 基线样式。
  final TextStyle style;

  /// 图片加载回调（`BookSource.readResource`）。
  final Future<Uint8List?> Function(String href) resolveImage;

  /// 链接点击回调（href 为归一化形态）；null = 链接不可点，仅下划线展示。
  final void Function(String href)? onLinkTap;

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
        oldWidget.onLinkTap != widget.onLinkTap) {
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
    _spans = parseContentSpans(
      widget.text,
      widget.style,
      widget.resolveImage,
      onLinkTap: widget.onLinkTap,
      recognizerSink: sink,
    );
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

/// 异步加载的内嵌图片 widget（`CNT-01`）。
///
/// 生命周期：`initState` 发起加载 → 加载中显示进度指示 → 成功显示图片 → 失败显示占位图标。
/// 每次 rebuild 不重新加载（`_bytes` 缓存在 State 里）。
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
