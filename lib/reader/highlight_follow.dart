// `TTS-02` 朗读高亮与自动跟随（M3-T06）。
//
// 三件东西：
//   · [HighlightFollow] —— 跟随开关策略：手动滚动即暂停跟随（`TTS-02` ③），
//     重新开读时复位；判定本身无状态，接线在 reader_page；
//   · [isParagraphVisible] —— 纯函数：段落矩形与视口的「足够可见」判定
//     （`TTS-02` ②：可见就不滚——避免短段逐段抖动；不可见才滚入可视区）；
//   · [SpeakingHighlight] —— 朗读段高亮包装（ListView / PagedScroller /
//     PageContent 三渲染路径共用）。
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../typography/typeset.dart' show kSpeakingHighlightColor;

/// TTS-02 自动跟随策略（纯策略，可单测）。
class HighlightFollow {
  bool _following = true;

  /// 是否仍应自动跟随（手动滚动过 → false，直到 [reset]）。
  bool get shouldFollow => _following;

  /// 手动滚动（手指拖拽 / 翻页手势）→ 暂停自动跟随（`TTS-02` ③）。
  void noteManualScroll() => _following = false;

  /// 重新开读 → 恢复跟随（`TTS-02` ③ 的复位侧，由开读按钮调用）。
  void reset() => _following = true;
}

/// 段落是否「足够可见」（纯函数；`TTS-02` ②的判定面）。
///
/// 判据：段落与视口的相交高 ≥ min(段高, 视口高) × [ratio]（默认 0.5）——
/// 段落过半在屏（超长段则占屏过半）即认为已滚入可视区，不再滚动；
/// 懒构建未上屏（调用方测不到矩形）由调用方按「不可见」处理。
bool isParagraphVisible(Rect paragraph, Rect viewport, {double ratio = 0.5}) {
  final double overlap = paragraph.intersect(viewport).height;
  if (overlap <= 0) return false;
  final double need = math.min(paragraph.height, viewport.height) * ratio;
  return overlap >= need;
}

/// 朗读段高亮（`TTS-02` ①：高亮与朗读内容一致）。
///
/// **结构恒定**：恒为一层 [DecoratedBox]（不活跃时空白 decoration），
/// `active` 只切 decoration 不换子树形状——若按 active 在「裸 child /
/// 包一层」之间切换，child 元素会搬家重建，[InlineParagraph] 的手势
/// recognizer 与图片 State 全部重来。恒定包装下翻转零重建。
class SpeakingHighlight extends StatelessWidget {
  const SpeakingHighlight({
    super.key,
    required this.active,
    required this.child,
  });

  /// 当前是否为正在朗读的段落。
  final bool active;

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: active
            ? const BoxDecoration(color: kSpeakingHighlightColor)
            : const BoxDecoration(),
        child: child,
      );
}
