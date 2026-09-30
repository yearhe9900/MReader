// 页即图层（`M-PAGE` T04，选型 §2.3 1/2/3）：翻页动画 = 已排版页图层的
// `Transform`/`ClipRect` 位移与裁切——**动画期零排版、页子树零 rebuild**。
//
// 结构契约（保证 ③ 的 Flutter 翻译，567Reader「截图回放」的 widget 树等价物）：
//   · 每页 = `RepaintBoundary` 包裹的静态层，**排版完成后不再变化**；
//   · `Transform` 在 `RepaintBoundary` **外侧**——动画只改变换矩阵
//     （合成层平移），子层栅格缓存复用，不重光栅化页面内容；
//   · 整体 `ClipRect` 裁到视口，移出的页不越界绘制；
//   · cover 翻页线阴影 = 移动页左缘的渐变条（随页一起平移，alpha 恒定
//     [kEdgeShadow]，动画中不逐帧变化）。
//
// **零 rebuild 的前提在调用方**（T05 接线约定）：`current` / `incoming`
// 传入**同一批稳定 widget 实例**（预排好的页缓存）——实例相同 Flutter
// 跳过子树重建，本组件重建只更新 Transform 矩阵。传新实例 = 该页重建，
// 属接线层违约，契约测试钉住「同实例 → build 不增」。

import 'package:flutter/material.dart';

import 'page_turn_controller.dart';

/// 翻页图层组（无状态；输入 = [PageLayerGeometry] + 两页预排 widget）。
///
/// [geometry] 为 `null`（idle / `none` 模式）→ 只渲染 [current]，
/// [incoming] 忽略——「直接切页」由调用方换实例完成，本组件不参与。
class PageTurnLayers extends StatelessWidget {
  const PageTurnLayers({
    super.key,
    required this.geometry,
    required this.current,
    required this.incoming,
  });

  /// 图层几何（[computeLayerGeometry] 产物；`null` = 静止）。
  final PageLayerGeometry? geometry;

  /// 当前页（预排好的静态页 widget；保持同一实例）。
  final Widget current;

  /// 目标页（预排好的静态页 widget；保持同一实例）。[geometry] 为 null 时忽略。
  final Widget incoming;

  /// 移动页左缘阴影条宽度（逻辑像素）。
  static const double shadowStripWidth = 20;

  @override
  Widget build(BuildContext context) {
    final PageLayerGeometry? g = geometry;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;

        if (g == null) {
          // 静止：单页直渲（仍包 RepaintBoundary——翻页起手即有层可动）。
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _layer(
                  page: current,
                  dx: 0,
                  width: width,
                  layerKey: null,
                  shadowAlpha: 0,
                ),
              ],
            ),
          );
        }

        final Widget currentLayer = _layer(
          page: current,
          dx: g.currentDx,
          width: width,
          layerKey: const ValueKey<String>('mreader-layer-current'),
          shadowAlpha: g.shadowOnIncoming ? 0 : g.edgeShadow,
        );
        final Widget incomingLayer = _layer(
          page: incoming,
          dx: g.incomingDx,
          width: width,
          layerKey: const ValueKey<String>('mreader-layer-incoming'),
          shadowAlpha: g.shadowOnIncoming ? g.edgeShadow : 0,
        );

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // Stack 后者在上：按 incomingOnTop 决定页序（cover prev =
              // 当前页掀起盖在目标页之上）。
              if (g.incomingOnTop) ...<Widget>[currentLayer, incomingLayer],
              if (!g.incomingOnTop) ...<Widget>[incomingLayer, currentLayer],
            ],
          ),
        );
      },
    );
  }

  /// 单页图层：`Transform`（动画时只动矩阵）> `RepaintBoundary`（页栅格层）
  /// > 页 + 可选阴影条。
  Widget _layer({
    required Widget page,
    required double dx,
    required double width,
    required ValueKey<String>? layerKey,
    required double shadowAlpha,
  }) {
    final Widget content = shadowAlpha > 0
        ? Stack(
            fit: StackFit.expand,
            children: <Widget>[
              page,
              // 翻页线阴影：移动页左缘 → 内侧渐隐（黑 → 透明）。
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: shadowStripWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: <Color>[
                        Colors.black.withValues(alpha: shadowAlpha),
                        Colors.black.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          )
        : page;

    return Transform(
      key: layerKey,
      transform: Matrix4.translationValues(dx * width, 0, 0),
      child: RepaintBoundary(child: content),
    );
  }
}
