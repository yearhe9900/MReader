// 阅读页 chrome 的上下渐进模糊带（2026-11-06 当口口径，接 §2.118）。
//
// §2.118 里「唤出悬浮工具栏 ⇒ 底部读数行 `Opacity(0)` 不绘制」已作废：读数行
// **两态都可见**，改由正文上下两条渐进模糊带把 chrome 与正文分开——靠近屏幕
// 上下缘的正文被逐段糊开、往页面中间逐渐清晰，顶栏与悬浮胶囊压在这层之上。
//
// 曲线复用 mi_like_ui 的 `MiGradientBlur.bandsFor`（σ 阶梯 + `MiFilterCache`
// 复用 native filter），底部只是把同一条曲线沿 y 镜像；**不改移植体**。
//
// ⚠️ 三条红线：
//  * 禁 `Opacity` / `FadeTransition` / `ShaderMask` 包模糊层——会把
//    `BackdropFilter` 的 backdrop 隔离成空（磨砂整段消失）；
//  * 压色是**独立的兄弟层**、画在模糊之上（`MiTopBar` 同构），不是模糊的父层；
//  * 本层 `IgnorePointer` 且不参与正文预算：chrome 显隐不改正文排版几何。
import 'package:flutter/material.dart';

import '../ui/mi_like_ui/mi_like_ui.dart';

/// 一条贴在屏幕边缘的渐进模糊 + 压色带。
class ReaderChromeEdgeBlur extends StatelessWidget {
  const ReaderChromeEdgeBlur({
    super.key,
    required this.extent,
    required this.pageColor,
    this.fromTop = true,
  }) : assert(extent > 0, 'extent 必须为正');

  /// 作用区高（dp）；σ 从边缘的最强档逐段递减到区底归零。
  final double extent;

  /// 页面底色（`ReaderPage._pageColor`）——压色与读数行同源，接缝不可见。
  final Color pageColor;

  /// `true` = 屏幕上缘（最强模糊在带顶）；`false` = 下缘（曲线镜像）。
  final bool fromTop;

  /// 压色在边缘的 α（往带内渐隐）。只压色，不做半透明遮罩包模糊。
  static const double scrimAlpha = 0.55;

  @override
  Widget build(BuildContext context) {
    // `underSurface: false`：压色是渐变、没有实心段 ⇒ 每段模糊都要画。
    final List<MiTopBarBlurBand> bands = MiGradientBlur.bandsFor(
      extent: extent,
      underSurface: false,
    );
    final Alignment begin =
        fromTop ? Alignment.topCenter : Alignment.bottomCenter;
    final Alignment end =
        fromTop ? Alignment.bottomCenter : Alignment.topCenter;
    return IgnorePointer(
      child: SizedBox(
        width: double.infinity,
        height: extent,
        child: Stack(
          children: <Widget>[
            for (final MiTopBarBlurBand band in bands)
              Positioned(
                left: 0,
                right: 0,
                top: fromTop ? band.top : null,
                bottom: fromTop ? null : band.top,
                height: band.height,
                child: ClipRect(
                  child: BackdropFilter(
                    filter: MiFilterCache.blur(band.sigma),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            // 压色：边缘一档页底色、往带内渐隐；独立兄弟层，画在模糊之上。
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: begin,
                    end: end,
                    stops: const <double>[0.0, 0.45, 1.0],
                    colors: <Color>[
                      pageColor.withValues(alpha: scrimAlpha),
                      pageColor.withValues(alpha: scrimAlpha * 0.5),
                      pageColor.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
