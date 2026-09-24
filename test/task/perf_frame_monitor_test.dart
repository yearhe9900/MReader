// `M2b-T07`：帧预算监控单测（`UI-06` 自动降级的帧侧触发器，接线批）。
//
// 纯 Dart `test()`；帧时序经 `@visibleForTesting simulateTimings` 注入
// （无需真实渲染循环）。[FrameTiming] 用 dart:ui 的**测试工厂**构造（微秒时间戳）：
// `rasterDuration = rasterFinish − rasterStart`。
// 计数 / 触发纯逻辑已由 `perf_prefs_store_test.dart` 覆盖，这里验接线口径与边沿语义。
// 断言预期值均先**人工推演**（各用例注释给出推演式）。
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/perf_frame_monitor.dart';
import 'package:mreader/settings/perf_prefs_store.dart';

/// 构造一帧光栅耗时为 [raster] 的帧时序（时间锚点任意，只看差值）。
FrameTiming _frame(Duration raster) {
  const int vsyncStart = 1000;
  const int rasterStart = 2000;
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: vsyncStart,
    buildFinish: 1500,
    rasterStart: rasterStart,
    rasterFinish: rasterStart + raster.inMicroseconds,
    rasterFinishWallTime: rasterStart + raster.inMicroseconds,
  );
}

void main() {
  // start / stop 需要调度器绑定（addTimingsCallback）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerfFrameMonitor（超预算口径与触发）', () {
    test('口径 = rasterDuration > 16ms（边界：恰 16ms 不算超预算）', () {
      // 推演：判据是**严格大于**（_onTimings）：16ms 整 = 预算内不触发；
      // 16ms + 1µs = 超预算触发（阈值 1 = 每超预算帧触发一次）；8ms 不触发。
      int fired = 0;
      final PerfFrameMonitor monitor = PerfFrameMonitor(
        onBudgetExceeded: () => fired++,
        tracker: PerfBudgetTracker(threshold: 1),
      );

      monitor.simulateTimings(
        <FrameTiming>[_frame(const Duration(milliseconds: 16))],
      );
      expect(fired, 0);

      monitor.simulateTimings(
        <FrameTiming>[_frame(const Duration(milliseconds: 16, microseconds: 1))],
      );
      expect(fired, 1);

      monitor.simulateTimings(
        <FrameTiming>[_frame(const Duration(milliseconds: 8))],
      );
      expect(fired, 1);
    });

    test('连续超预算满阈值触发一次（边沿触发，触发后清零）', () {
      // 推演（threshold=3）：2 帧 → 0 次；第 3 帧 → 1 次（清零）；第 4、5 帧 →
      // 仍 1 次；第 6 帧 → 2 次。
      int fired = 0;
      final PerfFrameMonitor monitor = PerfFrameMonitor(
        onBudgetExceeded: () => fired++,
        tracker: PerfBudgetTracker(threshold: 3),
      );
      final FrameTiming over = _frame(const Duration(milliseconds: 20));

      monitor.simulateTimings(<FrameTiming>[over, over]);
      expect(fired, 0);
      monitor.simulateTimings(<FrameTiming>[over]);
      expect(fired, 1);
      monitor.simulateTimings(<FrameTiming>[over, over]);
      expect(fired, 1);
      monitor.simulateTimings(<FrameTiming>[over]);
      expect(fired, 2);
    });

    test('预算内一帧打断连续计数（计数重来）', () {
      // 推演（threshold=3）：超×2 + 预算内×1 + 超×2 → 0 次（连续被打断）；
      // 再超 1 帧（重新累计 3）→ 1 次。
      int fired = 0;
      final PerfFrameMonitor monitor = PerfFrameMonitor(
        onBudgetExceeded: () => fired++,
        tracker: PerfBudgetTracker(threshold: 3),
      );
      final FrameTiming over = _frame(const Duration(milliseconds: 20));
      final FrameTiming under = _frame(const Duration(milliseconds: 8));

      monitor.simulateTimings(<FrameTiming>[over, over, under, over, over]);
      expect(fired, 0);
      monitor.simulateTimings(<FrameTiming>[over]);
      expect(fired, 1);
    });

    test('一次回调多帧逐帧计数（addTimingsCallback 每批可多帧）', () {
      // 推演（threshold=2）：一批 3 个超预算帧 → 第 2 帧触发 1 次、第 3 帧计 1；
      // 再喂 1 帧 → 达 2 触发第 2 次。
      int fired = 0;
      final PerfFrameMonitor monitor = PerfFrameMonitor(
        onBudgetExceeded: () => fired++,
        tracker: PerfBudgetTracker(threshold: 2),
      );
      final FrameTiming over = _frame(const Duration(milliseconds: 20));

      monitor.simulateTimings(<FrameTiming>[over, over, over]);
      expect(fired, 1);
      monitor.simulateTimings(<FrameTiming>[over]);
      expect(fired, 2);
    });

    test('start / stop 幂等切换 isRunning', () {
      // 推演：重复 start / stop 不重复挂摘、状态稳定。
      final PerfFrameMonitor monitor = PerfFrameMonitor(onBudgetExceeded: () {});
      expect(monitor.isRunning, isFalse);
      monitor.start();
      expect(monitor.isRunning, isTrue);
      monitor.start();
      expect(monitor.isRunning, isTrue);
      monitor.stop();
      expect(monitor.isRunning, isFalse);
      monitor.stop();
      expect(monitor.isRunning, isFalse);
    });
  });
}
