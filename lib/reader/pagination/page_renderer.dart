// 单页内容渲染器（T05-c，R2 方案）：ClipRect + Transform.translate(−preHeight)
// + Column 相交段落**完整渲染**。
//
// 为什么整段渲染：Flutter 的 `Text.rich` 无法只渲染段落的中间几行——取页
// 首行所属段落起、到页尾相交段落止的**完整段落**叠成 Column，整体上移到页
// 首行、ClipRect 裁到页框。页外内容被裁但不省排版（`RenderParagraph` 布局
// 缓存，相邻页复用同一段落实例时不重复排）。
//
// 与测量一致性的四个支点（页内容必须与 `page_paginator.dart` 的行测量同高同断）：
//   1. 同宽：Column 收紧到 `config.pageWidth`（= 测量 `layout(maxWidth:)`）；
//   2. 同样式 / 同缩进：`InlineParagraph(style: config.textStyle)` + 每段
//      `withFirstLineIndent`（投影恒加缩进的渲染侧对偶）；
//   3. 同缩放：包 `MediaQuery(textScaler: linear(config.textScaleFactor))`
//      ——测量用的就是这个线性缩放，不随系统非线性缩放漂移；
//   4. 同 strut：包 `DefaultTextStyle(config.textStyle)`——`InlineParagraph`
//      的根 `TextSpan` 无 style，不包则 strut 吃 ambient 默认样式，字号小时
//      行高被 strut 抬高、与测量漂移。
// 段间距：页内相邻段之间放 `SizedBox(paragraphSpacing)`，与切页预算
// 「页内加、跨页不加」同口径（页首段前不加——它要么是页首行所属段的起点，
// 要么是上一页的延续，上一页的间距已在上一页预算内）。
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../typography/typeset.dart';
import '../highlight_follow.dart';
import '../selection_overlay.dart';
import 'page_breaker.dart';
import 'page_paginator.dart';

/// 页首行之前的「段内前缀高」：页首行所属段落中、位于页首行之前的行高之和。
///
/// 渲染 Column 从该段落开头画起，整体平移 −[pageContentPreHeight] 后页首行
/// 正好贴页顶。纯函数——滚动容器 / 落位计算也用它。
double pageContentPreHeight(List<MeasuredLine> lines, PageSlice page) {
  if (page.lineCount == 0 || page.firstLine >= lines.length) return 0;
  double height = 0;
  int i = page.firstLine;
  final int pStart = lines[i].paragraphIndex;
  while (i > 0 && lines[i - 1].paragraphIndex == pStart) {
    i--;
    height += lines[i].height;
  }
  return height;
}

/// 一页的正文内容（不含章标题——标题高由视图层裁进 `clipHeight` / 调度器）。
class PageContent extends StatelessWidget {
  const PageContent({
    super.key,
    required this.paragraphs,
    required this.lines,
    required this.page,
    required this.config,
    required this.resolveImage,
    this.onLinkTap,
    this.highlightQuery,
    this.chapterHref,
    this.selection,
    this.speakingPara,
    this.clipHeight,
  });

  /// 章节原文段落（`ExtractedSection.paragraphs`，与测量输入同一列表）。
  final List<String> paragraphs;

  /// 章行表（与 [page] 同一快照；只追加的活列表，见文件头契约）。
  final List<MeasuredLine> lines;

  /// 要渲染的页（`PageSlice`，取 `firstLine/lineCount`）。
  final PageSlice page;

  /// 排版参数（宽度 / 样式 / 段间距 / 缩放，与测量同一实例）。
  final PaginationConfig config;

  /// 图片加载回调（透传 `InlineParagraph` → `_InlineImage`）。
  final Future<Uint8List?> Function(String href) resolveImage;

  /// 链接点击回调；null = 链接仅下划线不可点。
  final void Function(String href)? onLinkTap;

  /// 搜索高亮关键词；null / 空 = 不高亮。
  final String? highlightQuery;

  /// 所在章 href（`AI-02`/`AI-03` 划词定位）：非空时每段挂
  /// [paragraphKey]，供长按命中（`findParagraphAt`）；null = 不挂 key。
  final String? chapterHref;

  /// 划词选区（已按本章过滤）：[ParaSelection.paraIndex] 命中的段落着色。
  final ({int paraIndex, int start, int end})? selection;

  /// 当前朗读段下标（本章内；`TTS-02` 高亮跟随）；null = 本章无朗读段。
  final int? speakingPara;

  /// 页框高（默认 [PaginationConfig.pageHeight]；页 0 传
  /// `pageHeight − headingHeight`——标题占高由视图层另行渲染）。
  final double? clipHeight;

  @override
  Widget build(BuildContext context) {
    // 裁切框高 = **本页内容的自然高**（[PageSlice.height]），不是 `pageHeight`。
    //
    // ##⚠️ 改为 `page.height` 的原因（2026-10-06，负责人截图「文字丢失上一半」）
    //
    // 改前取 `config.pageHeight`（视口高），而调用方 [PagedScroller] 用
    // `Positioned(top: e.top, height: e.height, child: PageContent(...))`
    // ——外层盒只有 `PageSlice.height`（内容自然高，如 58；末页常远小于视口高）。
    // 两层高度不一致 ⇒ 内层 `OverflowBox` 按 `pageHeight` 排版、允许内容向下延伸，
    // 外层 `Positioned` 却只给 `e.height` ⇒ **超出部分连同底部若干行一起被裁掉**。
    //
    // 症状随「视口高 − 内容高」差值放大：真机分页模式下 `pageHeight` 是整个
    // 视口高（近屏高），末页内容远不足一屏 ⇒ 差值最大 ⇒ 末页底部整行丢失、
    // 看起来像「文字被吃掉一半」。
    //
    // 用 `page.height` 后内外盒一致：裁切范围 = 本页实际内容，**不裁任何一行**，
    // 页间留白由 `PageSlice.height` 与下一页 `top` 的差自然形成
    // （见 [PagedScroller] 「页框 = `PageSlice.height`」的注释）。
    //
    // `clipHeight` 仍保留：页 0 传 `pageHeight − headingHeight`（标题占高），
    // 那是**故意**只露一部分的语义，非此bug。
    final double height = clipHeight ?? page.height;
    final Widget empty = SizedBox(width: config.pageWidth, height: height);
    if (page.lineCount == 0 || page.firstLine >= lines.length) return empty;

    final int first = page.firstLine;
    final int last = (first + page.lineCount - 1).clamp(0, lines.length - 1);
    final int pStart = lines[first].paragraphIndex;
    final int pEnd = lines[last].paragraphIndex;
    final double preHeight = pageContentPreHeight(lines, page);

    final List<Widget> children = <Widget>[];
    for (int p = pStart; p <= pEnd && p < paragraphs.length; p++) {
      if (p > pStart) {
        children.add(SizedBox(height: config.paragraphSpacing));
      }
      final ({int paraIndex, int start, int end})? sel =
          selection != null && selection!.paraIndex == p ? selection : null;
      children.add(SpeakingHighlight(
        active: speakingPara == p,
        child: InlineParagraph(
          key: chapterHref == null ? null : paragraphKey(chapterHref!, p),
          text: withFirstLineIndent(paragraphs[p]),
          style: config.textStyle,
          resolveImage: resolveImage,
          onLinkTap: onLinkTap,
          highlightQuery: highlightQuery,
          selection: sel == null ? null : (start: sel.start, end: sel.end),
        ),
      ));
    }

    return SizedBox(
      width: config.pageWidth,
      height: height,
      child: ClipRect(
        // 页框高与内容高解耦：完整段落常高于页框——OverflowBox 给 Column
        // tight 宽（stretch 同测量宽）+ 无界高（RenderFlex 不报 overflow），
        // 越界部分由外层 ClipRect 裁掉。
        child: OverflowBox(
          minWidth: config.pageWidth,
          maxWidth: config.pageWidth,
          minHeight: 0,
          maxHeight: double.infinity,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(config.textScaleFactor),
            ),
            child: DefaultTextStyle(
              style: config.textStyle,
              child: Transform.translate(
                offset: Offset(0, -preHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
