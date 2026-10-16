// 宽度自适应胶囊分类标签行（MReader 侧变体，2026-10-16）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 与移植体 `mi_like_ui` 的 `MiPillTabBar` 的关系
// ══════════════════════════════════════════════════════════════════════════════
// 视觉 / 交互逐项同 `MiPillTabBar`（stadium 胶囊、200ms easeOut 填充过渡、
// 明暗双配方、横滑 + gap/edgeInset、**胶囊内 backdrop 磨砂 + 两遍绘制**——
// 2026-10-16 上游「统一透明 token」批全跟随拍板，两遍绘制防相邻胶囊串色与
// 双层 AA 叠乘），唯一差异 = **胶囊宽度规则**（负责人 2026-10-16 拍板）：
//   · `MiPillTabBar` 是**定宽**（87.6，参考项目实测）；
//   · 本类**自适应宽**：min = 当前宽度 87.6（[minWidth]）、max = 当前宽度 ×2
//     = 175.2（[maxWidth]）；胶囊宽 = clamp(文字自然宽 + 2×[textInset],
//     min, max)，超出 max 的标签以省略号截断。
// 为什么不改移植体：`lib/ui/mi_like_ui/` 与上游 `mi_like_ui_demo` 保持
// **逐字节一致**（`diff -r` 零差异准绳），MReader 自有行为一律放移植树之外
// （同 `glass_nav_host.dart` 口径）。上游若日后原生支持该规则，再整组替换。
import 'dart:ui';

import 'package:flutter/material.dart';

import 'mi_like_ui/mi_like_ui.dart';

/// 宽度自适应胶囊分类标签行（明暗双模式）。
///
/// 接口与 [MiPillTabBar] 对齐（labels / selectedIndex / onTap / themeMode），
/// 便于整组互换。宽度规则与几何常量见 [minWidth] / [maxWidth] / [textInset]。
class AdaptivePillTabBar extends StatelessWidget {
  const AdaptivePillTabBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onTap,
    this.themeMode = MiThemeMode.dark,
  });

  /// 胶囊最小宽度 = 参考项目定宽（`MiPillTabMetrics.itemWidth`，87.6）。
  static const double minWidth = MiPillTabMetrics.itemWidth;

  /// 胶囊最大宽度 = 最小宽度 × 2（175.2）；标签超出即省略号截断。
  static const double maxWidth = MiPillTabMetrics.itemWidth * 2;

  /// 胶囊内文字两侧内距（单侧）。宽度公式：
  /// `clamp(文字宽 + 2×textInset, minWidth, maxWidth)`。
  ///
  /// 取 16dp（≈1.15em @ 13.85）：3 字内标签仍落在最小宽内（观感与定宽版
  /// 一致），更长标签逐字放宽、留呼吸感，直到最大宽钳位转省略号。
  static const double textInset = 16;

  /// 各分类标签文案。
  final List<String> labels;

  /// 选中项下标。
  final int selectedIndex;

  /// 点按回调，参数为被点标签下标。
  final ValueChanged<int> onTap;

  /// 明暗模式，驱动配色配方。
  final MiThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    // labels 非空与 selectedIndex 范围校验在 build：const 构造断言不支持
    // .length 求值（放构造器会封死 const 构造，同 MiPillTabBar 口径）。
    assert(labels.isNotEmpty, 'labels 不能为空');
    assert(
      selectedIndex >= 0 && selectedIndex < labels.length,
      'selectedIndex 必须落在 labels 范围内',
    );
    final MiPillTabPalette palette = MiPillTabPalette.of(themeMode);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    final ImageFilter blur = ImageFilter.blur(
      sigmaX: MiTransparencyTokens.blurSigma,
      sigmaY: MiTransparencyTokens.blurSigma,
    );
    // 宽度先算一遍：plates 与 fills 两遍必须逐胶囊同宽（对齐同一栅格）。
    final List<double> widths = <double>[
      for (final String label in labels) _pillWidthFor(label, scaler, direction),
    ];
    // 两遍绘制（同移植体 MiPillTabBar，上游「统一透明 token」批）：
    // plates（磨砂）在下、fills（填充/文案/手势）在上。所有磨砂先于任何
    // 填充绘制，backdrop 只含背景/身后内容，相邻胶囊的填充不进入彼此的
    // 模糊源（无串色）。
    final List<Widget> plates = <Widget>[];
    final List<Widget> fills = <Widget>[];
    for (var i = 0; i < labels.length; i++) {
      if (i > 0) {
        plates.add(const SizedBox(width: MiPillTabMetrics.gap));
        fills.add(const SizedBox(width: MiPillTabMetrics.gap));
      }
      final bool selected = i == selectedIndex;
      // pass 1：磨砂取景框 —— clip 到胶囊形状后做 backdrop 模糊，
      // 只有胶囊内部透射磨砂，间隙/行外不糊。
      plates.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(MiDimens.radiusPill),
          child: BackdropFilter(
            filter: blur,
            child: SizedBox(
              width: widths[i],
              height: MiPillTabMetrics.pillHeight,
            ),
          ),
        ),
      );
      // pass 2：半透明填充 + 文案 + 手势。填充沿用 Decoration 自身
      // 圆角 AA（与截图实测的单层边缘 AA 一致，勿再外包 ClipRRect，
      // 两层 AA 叠乘会把边缘覆盖率压成 c²）。
      fills.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            width: widths[i],
            height: MiPillTabMetrics.pillHeight,
            decoration: BoxDecoration(
              color: selected ? palette.selectedFill : palette.unselectedFill,
              borderRadius: BorderRadius.circular(MiDimens.radiusPill),
            ),
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: textInset),
              child: Text(
                labels[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: MiTypography.pillLabel.copyWith(
                  color: selected
                      ? palette.selectedLabel
                      : palette.unselectedLabel,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final double rowWidth = widths.fold<double>(
      0,
      (double sum, double width) => sum + width,
    ) + (labels.length - 1) * MiPillTabMetrics.gap;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding:
          const EdgeInsets.symmetric(horizontal: MiPillTabMetrics.edgeInset),
      child: SizedBox(
        width: rowWidth,
        height: MiPillTabMetrics.pillHeight,
        child: Stack(
          children: [
            Positioned.fill(child: Row(children: plates)),
            Positioned.fill(child: Row(children: fills)),
          ],
        ),
      ),
    );
  }

  /// 单个胶囊宽度：`clamp(文字自然宽 + 2×textInset, minWidth, maxWidth)`。
  double _pillWidthFor(String label, TextScaler scaler, TextDirection direction) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: label, style: MiTypography.pillLabel),
      textDirection: direction,
      textScaler: scaler,
    )..layout();
    return (tp.width + 2 * textInset).clamp(minWidth, maxWidth);
  }
}
