// 分页测量层：原文投影 + 行测量 + 「可见偏移 → 原文偏移」映射。
//
// 测量留 root isolate（`TextPainter` 依赖渲染引擎）；「行 → 页」切页抽到
// `page_breaker.dart`（不 import Flutter，纯 `test()` 可单测）。
//
// 投影：进度偏移口径 = 段落**原文**（含 `\x00` 标记与 `<b>/<i>` 标签），
// 但标记不上屏——投影产可见文本 + `rawOfVisible` 映射，行边界再映回原文
// （`a␀IMG:x.png␀b` → `a␣b`，`␣` = 1 个 U+FFFC）。语义必须与
// `typeset.dart` span 构建一致，由 `pagination_measure_test.dart` 对拍钉死。
// 投影恒加首行缩进（`kFirstLineIndentPrefix`，与渲染侧
// `withFirstLineIndent` 一致）——故可见偏移比原文偏移多 2 个缩进字符。
// 已知边界（里程碑 §2）：图片占位 48×48，真图尺寸进测量归 T05；链接
// 下划线不改变行度量，故不叠链接样式。
import 'package:flutter/material.dart';

import '../../typography/typeset.dart';
import 'page_breaker.dart';

/// 图片占位尺寸（= `typeset.dart` 里 `_InlineImage` 加载态 / 错误态的 48×48）。
const Size kImagePlaceholderSize = Size(48, 48);

/// 分页排版参数（T02 的 `PaginationCache` 直接拿它做配置哈希失效）。
class PaginationConfig {
  const PaginationConfig({
    required this.pageWidth,
    required this.pageHeight,
    required this.textStyle,
    this.paragraphSpacing = 8,
    this.imageSize = kImagePlaceholderSize,
    this.textScaleFactor = 1,
  });

  /// 正文可用宽（视口宽 − 左右页边距）。
  final double pageWidth;

  /// 正文可用高（视口高 − 上下留白 / 顶栏避让等，由调用方算好）。
  final double pageHeight;

  /// 正文基线样式（`resolveTextStyle(settings, theme:)` 的产物）。
  final TextStyle textStyle;

  /// 段间距（页内相邻段之间；跨页不加）。
  final double paragraphSpacing;

  /// 内嵌图片占位尺寸。
  final Size imageSize;

  /// 系统字体缩放（`MediaQuery.textScalerOf` 的线性等效值）。
  final double textScaleFactor;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaginationConfig &&
          runtimeType == other.runtimeType &&
          pageWidth == other.pageWidth &&
          pageHeight == other.pageHeight &&
          textStyle == other.textStyle &&
          paragraphSpacing == other.paragraphSpacing &&
          imageSize == other.imageSize &&
          textScaleFactor == other.textScaleFactor;

  @override
  int get hashCode => Object.hash(
        pageWidth,
        pageHeight,
        textStyle,
        paragraphSpacing,
        imageSize,
        textScaleFactor,
      );

  @override
  String toString() => 'PaginationConfig(${pageWidth}x$pageHeight, '
      'spacing=$paragraphSpacing, scale=$textScaleFactor)';
}

/// 一段原文的「可见投影」。
class VisibleProjection {
  const VisibleProjection({
    required this.visible,
    required this.rawOfVisible,
    required this.spans,
    required this.placeholderCount,
    required this.rawLength,
  });

  /// 可见文本（排版 offset 空间）：段首含 2 字符缩进前缀
  /// （`kFirstLineIndentPrefix`），每个图片标记占 **1 个** `U+FFFC` 槽位。
  /// 故可见偏移 ≈ 原文偏移 + 2（标签 / 标记另计）。
  final String visible;

  /// `rawOfVisible[i]` = 第 i 个可见位置在原文中的起始下标
  /// （图片槽位 = 该标记的起始下标；缩进前缀映射到 0）。
  final List<int> rawOfVisible;

  /// 测量用 span（文本 span 长度之和 + 槽位数 == `visible.length`）。
  final List<InlineSpan> spans;

  /// 图片占位数（`TextPainter.setPlaceholderDimensions` 需要同长列表）。
  final int placeholderCount;

  /// 原文长度（段末哨兵：可见位置越界时映射到它）。
  final int rawLength;

  @override
  String toString() =>
      'VisibleProjection(visible=${visible.length}, placeholders=$placeholderCount, raw=$rawLength)';
}

/// `<b>` / `<i>` 白名单（与 `typeset.dart` 的 `_inlineTagPattern` 同语义）。
final RegExp _inlineTagPattern = RegExp(r'<(/?)([bi])>');

/// 分页门面：原文段落 → 行 → 页。
abstract final class PagePaginator {
  /// 章节字符总数（`Σ paragraph.length`，与 `BookSource.totalCharCount()` 口径一致）。
  static int charCountOf(List<String> paragraphs) {
    int total = 0;
    for (final String p in paragraphs) {
      total += p.length;
    }
    return total;
  }

  /// 原文 → 可见投影（见本文件头部说明）。
  ///
  /// 恒在段首种子 [kFirstLineIndentPrefix]（与渲染侧 `withFirstLineIndent`
  /// 一致）：缩进字符不属原文，映射到原文偏移 0。
  static VisibleProjection project(String raw, TextStyle baseStyle) {
    final StringBuffer visible = StringBuffer();
    final List<int> rawOfVisible = <int>[];
    final List<InlineSpan> spans = <InlineSpan>[];
    final StringBuffer segment = StringBuffer();
    bool bold = false;
    bool italic = false;
    int placeholders = 0;

    // 首行缩进：进可见文本与首段 span；原文映射指向段首（0）。
    visible.write(kFirstLineIndentPrefix);
    segment.write(kFirstLineIndentPrefix);
    rawOfVisible.add(0);
    rawOfVisible.add(0);

    void flushSegment() {
      if (segment.isEmpty) return;
      spans.add(TextSpan(text: segment.toString(), style: _mergedStyle(baseStyle, bold, italic)));
      segment.clear();
    }

    int i = 0;
    while (i < raw.length) {
      final String ch = raw[i];

      if (ch == '\x00') {
        final int close = raw.indexOf('\x00', i + 1);
        if (close < 0) break; // 未闭合标记：吞掉剩余（与 typeset 的容错一致）
        final String body = raw.substring(i + 1, close);
        if (body.startsWith('IMG:') && body.length > 'IMG:'.length) {
          // 图片：占 1 个可见槽位（映射到标记起点），span 用占位 widget。
          flushSegment();
          visible.writeCharCode(0xFFFC);
          rawOfVisible.add(i);
          spans.add(WidgetSpan(
            child: SizedBox(
              width: kImagePlaceholderSize.width,
              height: kImagePlaceholderSize.height,
            ),
            alignment: PlaceholderAlignment.middle,
          ));
          placeholders++;
        }
        // 链接 / 锚点 / 未知标记：一律吞掉（不上屏、不占 offset）。
        i = close + 1;
        continue;
      }

      final Match? tag = _inlineTagPattern.matchAsPrefix(raw, i);
      if (tag != null) {
        flushSegment();
        final bool isClose = tag.group(1) == '/';
        if (tag.group(2) == 'b') {
          bold = !isClose;
        } else {
          italic = !isClose;
        }
        i = tag.end;
        continue;
      }

      // 普通字符：按 UTF-16 code unit 逐个入账（与 `String.length` 偏移口径一致）。
      visible.write(ch);
      rawOfVisible.add(i);
      segment.write(ch);
      i++;
    }
    flushSegment();

    return VisibleProjection(
      visible: visible.toString(),
      rawOfVisible: rawOfVisible,
      spans: spans,
      placeholderCount: placeholders,
      rawLength: raw.length,
    );
  }

  /// 测量整章：逐段排版 → 行（偏移已映射回**章内拼接原文空间**）。
  ///
  /// 每段用同一样式同一可用宽独立排版——与渲染侧「每段一个 `InlineParagraph`」
  /// 同构，故行断与渲染一致；贪心断行只依赖「行首字符 + 宽 + 样式」，页内段
  /// 续行单独重排也得相同行断（「页内渲染 == 测量结果」的依据）。
  ///
  /// [startIndex] / [baseOffset]：增量测量用——`paragraphs[0]` 在章内的段下标
  /// 与原文起始偏移。全量（默认 0/0）与逐段产出**完全相同**的行表（契约钉死）。
  static List<MeasuredLine> measureParagraphs({
    required List<String> paragraphs,
    required PaginationConfig config,
    int startIndex = 0,
    int baseOffset = 0,
  }) {
    assert(config.pageWidth > 0 && config.pageHeight > 0, '分页宽高必须为正');
    final List<MeasuredLine> lines = <MeasuredLine>[];
    int paragraphBase = baseOffset;

    for (int p = 0; p < paragraphs.length; p++) {
      final int index = startIndex + p;
      final String raw = paragraphs[p];
      final VisibleProjection projection = project(raw, config.textStyle);

      if (projection.visible.isNotEmpty) {
        final TextPainter painter = TextPainter(
          text: TextSpan(style: config.textStyle, children: projection.spans),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.linear(config.textScaleFactor),
          maxLines: null,
        );
        if (projection.placeholderCount > 0) {
          painter.setPlaceholderDimensions(List<PlaceholderDimensions>.filled(
            projection.placeholderCount,
            PlaceholderDimensions(size: config.imageSize, alignment: PlaceholderAlignment.middle),
          ));
        }
        painter.layout(maxWidth: config.pageWidth);
        final List<LineMetrics> metrics = painter.computeLineMetrics();

        // 行首字符偏移：`LineMetrics` 无 startIndex/endIndex，取「行垂直中点、
        // x=0」的最近位置（取中点而非行顶：行顶落在两行交界处归属有歧义）；
        // 行尾 = 下一行行首、末行 = 段末。
        final List<int> starts = <int>[];
        for (final LineMetrics metric in metrics) {
          final double y = metric.baseline - metric.ascent + metric.height / 2;
          int offset = painter.getPositionForOffset(Offset(0, y)).offset;
          if (starts.isNotEmpty && offset < starts.last) offset = starts.last;
          starts.add(offset);
        }

        for (int i = 0; i < metrics.length; i++) {
          final int visibleStart = starts[i];
          final int visibleEnd = i + 1 < starts.length ? starts[i + 1] : projection.visible.length;
          if (visibleEnd <= visibleStart) continue; // 零宽行不占字符、不产行
          lines.add(MeasuredLine(
            start: paragraphBase + _rawOffsetOf(projection, visibleStart),
            end: paragraphBase + _rawOffsetOf(projection, visibleEnd),
            height: metrics[i].height,
            paragraphIndex: index,
            quality: _qualityAt(projection, visibleEnd),
          ));
        }
      }

      paragraphBase += raw.length;
    }
    return lines;
  }

  /// 门面：段落 + 排版参数 → 页表。
  static List<PageSlice> paginate({
    required List<String> paragraphs,
    required PaginationConfig config,
  }) {
    final List<MeasuredLine> lines = measureParagraphs(paragraphs: paragraphs, config: config);
    return PageBreaker.paginate(
      lines,
      pageHeight: config.pageHeight,
      paragraphSpacing: config.paragraphSpacing,
    );
  }

  /// 可见偏移 → 段内原文偏移（越界取段末哨兵）。
  static int _rawOffsetOf(VisibleProjection projection, int visibleOffset) {
    // 缩进前缀占可见下标 0/1，映射到原文 0（段首含标签时即段起点）。
    if (visibleOffset < 0) return 0;
    if (visibleOffset >= projection.rawOfVisible.length) return projection.rawLength;
    return projection.rawOfVisible[visibleOffset];
  }

  /// 行尾断点质量（判据：该行最后一个**可见**字符）。
  static LineBreakQuality _qualityAt(VisibleProjection projection, int visibleEnd) {
    if (visibleEnd >= projection.visible.length) return LineBreakQuality.paragraphEnd;
    if (visibleEnd <= 0) return LineBreakQuality.none;
    final String ch = projection.visible[visibleEnd - 1];
    if (ch == '\uFFFC') return LineBreakQuality.strong; // 图片边界
    if ('。！？；…!?;'.contains(ch)) return LineBreakQuality.strong;
    if ('，、,'.contains(ch)) return LineBreakQuality.weak;
    if (ch == ' ' || ch == '\u3000' || ch == '\t' || ch == '\n' || ch == '\r') {
      return LineBreakQuality.space;
    }
    return LineBreakQuality.none;
  }

  static TextStyle _mergedStyle(TextStyle base, bool bold, bool italic) {
    if (!bold && !italic) return base;
    return base.copyWith(
      fontWeight: bold ? FontWeight.bold : null,
      fontStyle: italic ? FontStyle.italic : null,
    );
  }
}
