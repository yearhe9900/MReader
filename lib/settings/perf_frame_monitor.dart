// 帧预算监控（`UI-06` 自动降级的帧侧触发器）。
//
// 口径对齐玻璃库 `GlassPerformanceMonitor`：单帧 `FrameTiming.rasterDuration`
// 超 [PerfDegradePolicy.frameBudget]（16ms）计「超预算」，连续
// [PerfDegradePolicy.sustainedOverBudgetFrames]（60）帧触发一次回调。
// 与库的差异是**动作**：库只发 `FlutterError` 警告（debug/profile），
// 本监控调 [onBudgetExceeded] 促成**降档**（`GlassRuntime.noteBudgetDegraded`，
// 会话内、不持久化）——这是 `UI-06`「性能预算与降级」的生效链。
//
// 用法（`main.dart` 组合根）：
//   `PerfFrameMonitor(onBudgetExceeded: GlassRuntime.noteBudgetDegraded).start();`
// 计数 / 触发语义纯逻辑部分在 [PerfBudgetTracker]（`perf_prefs_store.dart`，已单测）。
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'perf_prefs_store.dart';

/// 连续超预算帧 → 触发一次降档的帧监控。
///
/// `addTimingsCallback` 每帧一次回调（可忽略级开销），debug / profile / release
/// 同口径启用（自动降级是产品能力，不是调试工具）。
class PerfFrameMonitor {
  /// 创建帧监控；[tracker] 缺省新建（阈值 = 60 帧），测试可注入小阈值。
  PerfFrameMonitor({
    required this.onBudgetExceeded,
    PerfBudgetTracker? tracker,
  }) : tracker = tracker ?? PerfBudgetTracker();

  /// 连续超预算满阈值时的回调（接 `GlassRuntime.noteBudgetDegraded`）。
  final void Function() onBudgetExceeded;

  /// 连续超预算帧计数器（触发语义见 [PerfBudgetTracker.recordFrame]）。
  final PerfBudgetTracker tracker;

  bool _running = false;

  /// 是否已挂接帧时序回调。
  bool get isRunning => _running;

  /// 挂接 [SchedulerBinding.addTimingsCallback]（幂等）。
  void start() {
    if (_running) return;
    _running = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  /// 摘除帧时序回调（幂等）。
  void stop() {
    if (!_running) return;
    _running = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  /// 测试注入口：直接喂帧时序（无需真实渲染循环）。
  @visibleForTesting
  void simulateTimings(List<FrameTiming> timings) => _onTimings(timings);

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming timing in timings) {
      final bool overBudget =
          timing.rasterDuration > PerfDegradePolicy.frameBudget;
      if (tracker.recordFrame(overBudget: overBudget)) {
        onBudgetExceeded();
      }
    }
  }
}
