// `TYP-04` 基础排版语义（纯 Dart + Flutter `InlineSpan`）。
//
//   · 首行缩进 2 字符（全角空格，与字号无关）；
//   · `<b>` / `<i>` 内联样式支持（白名单；其它标签原样显示文本）。
//
// **不做完整 CSS 级联**（`TYP-04` 明确说不做）；不做 `<br>` / 表格 / 脚注（`M2a-T02`）。
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
