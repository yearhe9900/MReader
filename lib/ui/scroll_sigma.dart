// 滚动速度 → 磨砂 σ 缩放（`UI-02` 的省帧护栏，与上游 demo `_ScrollSigma` 同源）。
//
// `BackdropFilter` 的 backdrop 是下方的滚动内容，**每帧都要重算**，是滚动时最贵
// 的一块。上游首页在快速运动中把 σ 压到 0.6、`MiTopBar.headerBlurBands` 随之把
// 9 段阶梯合并成 3 段（运动掩蔽下曲线细节不可辨），停稳再回满档；本仓移植磨砂
// 曲线时漏掉了这一层，书架因此恒按满档 9 段铺。
//
// ⚠️ 三条约束（与上游一致）：
//  * 速度取**相邻帧位移差**，帧时间戳用 `currentSystemFrameTimeStamp`（不碰墙钟 /
//    定时器）—— 值只取决于滚动事件序列，widget 测试可复现；
//  * 结果**量化到 0.05 档**：`MiFilterCache` 以 σ 为键，连续值会让每帧新建 native
//    filter（缓存形同虚设）；
//  * 速度低于 [stopEpsilon] 直接归零，σ 确定地回到 1.0。
//
// 与上游的一处差异：上游同一 notifier 还驱动内缘亮边（`rimProgress`），故每个
// 滚动事件都 `notifyListeners()`；书架的亮边另有 `_headerRim`，这里只在**换档
// 时**通知（[ValueNotifier] 的 value 语义），避免每帧重建模糊层。
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 把滚动速度换算成磨砂 σ 缩放（1.0 = 满档静止曲线，[minScale] = 满速）。
class ScrollSigma extends ValueNotifier<double> {
  /// 初始值 1.0 = 静止满档。
  ScrollSigma() : super(1.0);

  /// 满速参考（dp/s）：常规滑动 600…1500，取 1200 封顶（上游同值）。
  static const double vRef = 1200;

  /// 满速下的 σ 缩放（上游同值：再低就能看出「糊变轻」）。
  static const double minScale = 0.6;

  /// 速度低于该值（dp/s）即视为静止。
  static const double stopEpsilon = 24;

  ScrollController? _controller;
  double _speed = 0;
  double _lastOffset = 0;
  Duration _lastFrame = Duration.zero;

  /// 绑定滚动控制器：之后每个滚动事件更新 [value]。
  ///
  /// 只能挂一次；重复 attach 会在旧 controller 上遗留监听。
  void attach(ScrollController controller) {
    _controller = controller..addListener(_onScroll);
  }

  void _onScroll() {
    final ScrollController? controller = _controller;
    // listener 只在该 controller 有 position 后才会被调用，仍做防御（解绑窗口期）。
    if (controller == null || !controller.hasClients) return;
    final ScrollPosition position = controller.position;
    if (!position.hasPixels) return;
    final Duration now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final double dt = (now - _lastFrame).inMicroseconds / 1e6;
    final double offset = position.pixels;
    if (dt > 0) {
      final double v = (offset - _lastOffset).abs() / dt;
      // EMA 抹平逐帧抖动；慢速（含收尾）直接归零 → σ 确定地回 1.0。
      _speed = v < stopEpsilon ? 0 : _speed * 0.55 + v * 0.45;
    }
    _lastFrame = now;
    _lastOffset = offset;
    final double target = 1 - (1 - minScale) * (_speed / vRef).clamp(0.0, 1.0);
    // 量化只护 filter 缓存；同档不触发通知（换档才重建模糊层）。
    value = (target * 20).roundToDouble() / 20;
  }

  @override
  void dispose() {
    _controller?.removeListener(_onScroll);
    super.dispose();
  }
}
