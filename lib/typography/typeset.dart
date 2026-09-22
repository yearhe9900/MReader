// `TYP-04` 基础排版语义（纯 Dart + Flutter `InlineSpan`）。
//
//   · 首行缩进 2 字符（全角空格，与字号无关）；
//   · `<b>` / `<i>` 内联样式支持（白名单；其它标签原样显示文本）；
//   · `<img>` 图片标记 → `WidgetSpan`（`CNT-01` 内嵌图片渲染）。
//
// **不做完整 CSS 级联**（`TYP-04` 明确说不做）；不做 `<br>` / 表格 / 脚注（`M2a-T02`）。
import 'dart:typed_data';

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
// 图片标记解析（`CNT-01` 内嵌图片渲染）
// ---------------------------------------------------------------------------

/// 图片占位标记的 NUL 包裹格式（与 `section_extractor.dart` 写入的格式一致）。
const String _kImgPrefix = '\x00IMG:';

/// 把一段含图片标记（`\x00IMG:src\x00`）的文本解析成 [InlineSpan] 列表。
///
/// 文本段调 [parseInlineStyles]（复用 `<b>` / `<i>` 白名单）；
/// 图片段构造 [WidgetSpan]，child 为异步加载的图片 widget。
///
/// [resolveImage] 是图片加载回调：`href → Future<Uint8List?>`（来自 `BookSource.readResource`）。
/// 图片加载失败时渲染占位图标（不崩溃）。
List<InlineSpan> parseContentSpans(
  String text,
  TextStyle baseStyle,
  Future<Uint8List?> Function(String href) resolveImage,
) {
  if (!text.contains(_kImgPrefix)) {
    // 无图片标记：走纯文本路径（性能更优，不引入 WidgetSpan 开销）。
    return parseInlineStyles(text, baseStyle);
  }

  final List<InlineSpan> spans = <InlineSpan>[];
  // 按 NUL 字符分割：奇数段 = 图片标记（IMG:src），偶数段 = 纯文本。
  final List<String> parts = text.split('\x00');
  for (int i = 0; i < parts.length; i++) {
    if (i.isOdd) {
      // 图片标记：IMG:src
      final String marker = parts[i];
      if (marker.startsWith('IMG:')) {
        final String src = marker.substring(4);
        if (src.isNotEmpty) {
          spans.add(WidgetSpan(
            child: _InlineImage(src: src, resolveImage: resolveImage),
          ));
        }
      }
      // 非 IMG: 前缀的标记 → 忽略（防御脏数据）
    } else {
      // 纯文本段：调 parseInlineStyles 处理 <b>/<i>
      if (parts[i].isNotEmpty) {
        spans.addAll(parseInlineStyles(parts[i], baseStyle));
      }
    }
  }

  if (spans.isEmpty) {
    spans.add(TextSpan(text: '', style: baseStyle));
  }
  return spans;
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
