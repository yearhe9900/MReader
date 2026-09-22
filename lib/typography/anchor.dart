// `TYP-02` 位置锚定：字号 / 行距变化后，把当前章保持在视口同一相对位置。
//
// 设计：
//   1. 设置变更前：用 GlobalKey + RenderBox 定位「当前章块顶」与「视口顶」的像素差，
//      换算出「视口顶落在当前章的相对位置」（0.0 = 章顶，1.0 = 章底）；
//   2. 设置变更后（`setState` → 列表重建 → 新布局）：用同一个章块的 GlobalKey
//      重新测量，算出要 `jumpTo` 的 delta，使「同一相对位置」仍对齐视口顶。
//
// 本文件只做**纯数值计算**（不依赖 Flutter widget 树），便于 `test/typography/` 里
// 用纯 Dart `test()` 直接断言（本项目已两次实证 `testWidgets` + 真异步 IO 挂死）。
import 'package:flutter/material.dart';

/// 设置变更前的位置锚点（不可变快照）。
class ScrollAnchor {
  const ScrollAnchor({
    required this.chapterIndex,
    required this.relativePos,
  });

  /// 当前章索引（仅供调试；计算不依赖它）。
  final int chapterIndex;

  /// 视口顶落在当前章的相对位置（0.0 = 章顶，1.0 = 章底）。
  final double relativePos;

  /// 从当前 widget 树快照中抓取锚点。
  ///
  /// 失败条件（任一为 null / 无内容）返回 `null`，调用方应跳过校正。
  static ScrollAnchor? capture({
    required ScrollController? controller,
    required RenderBox? viewportBox,
    required RenderBox? chapterBox,
    required int chapterIndex,
  }) {
    if (controller == null || !controller.hasClients) return null;
    if (viewportBox == null || chapterBox == null) return null;
    final double chapterHeight = chapterBox.size.height;
    if (chapterHeight <= 0) return null;

    final double viewportTop =
        viewportBox.localToGlobal(Offset.zero).dy;
    final double chapterTop =
        chapterBox.localToGlobal(Offset.zero).dy;
    final double relPos =
        ((viewportTop - chapterTop) / chapterHeight).clamp(0.0, 1.0);

    return ScrollAnchor(
      chapterIndex: chapterIndex,
      relativePos: relPos,
    );
  }

  /// 重建后，算出使「同一相对位置仍对齐视口顶」所需的滚动 delta。
  ///
  /// [newViewportTop] / [newChapterTop]：重建后的新全局 y 坐标（逻辑像素）。
  /// [newChapterHeight]：重建后章块的新高度。
  ///
  /// 返回 `null` 表示偏移 ≤ 1px，无需校正。
  double? correctionFromRaw({
    required double newViewportTop,
    required double newChapterTop,
    required double newChapterHeight,
  }) {
    if (newChapterHeight <= 0) return null;

    // 目标：章块顶 + relativePos × 章块高 应该 = 视口顶
    final double expectedChapterTop =
        newViewportTop - relativePos * newChapterHeight;
    final double delta = newChapterTop - expectedChapterTop;
    return delta.abs() > 1.0 ? delta : null;
  }

  /// 便捷版：直接传入重建后的 [RenderBox]，内部取坐标。
  double? correction({
    required ScrollController? controller,
    required RenderBox? viewportBox,
    required RenderBox? chapterBox,
  }) {
    if (controller == null || !controller.hasClients) return null;
    if (viewportBox == null || chapterBox == null) return null;
    final double chapterHeight = chapterBox.size.height;
    if (chapterHeight <= 0) return null;

    return correctionFromRaw(
      newViewportTop: viewportBox.localToGlobal(Offset.zero).dy,
      newChapterTop: chapterBox.localToGlobal(Offset.zero).dy,
      newChapterHeight: chapterHeight,
    );
  }

  @override
  String toString() =>
      'ScrollAnchor(ch: $chapterIndex, rel: ${relativePos.toStringAsFixed(4)})';
}
