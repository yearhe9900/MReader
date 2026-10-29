// 统一后台任务抽象的单测（架构 §F；`RUST-05` / `RUST-10` 的纯 Dart 预备）。
//
// 纯 Dart `test()`（不涉及 widget / FakeAsync）。
//
// 覆盖：① `TaskHandle` 的统一语义（进度单调、收尾补发、取消幂等、异常分流）；
// ② `'sync'` 后端与注册表；③ `isolate` 后端的真派发（debugName 取证）、进度回传、
// 取消（kill）、远端失败转述、**派发失败回落本 isolate**。
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/task/background_runner.dart';
import 'package:mreader/task/isolate_background_runner.dart';
import 'package:mreader/task/task_cancelled_exception.dart';

// ————————————————————————— 顶层任务体（isolate 后端要求：顶层 / static） —————————————————————————

/// 回报「我在哪个 isolate」（tag@debugName）。
String _whereTag(int message, TaskContext ctx) =>
    'x@${Isolate.current.debugName}';

/// 逐段回报进度后返回任务总量（**密集回报**：用于验证接收端节流不影响终值）。
Future<int> _countWithProgress(int total, TaskContext ctx) async {
  for (int i = 1; i <= total; i++) {
    ctx.reportProgress(i);
  }
  return total;
}

/// 长跑任务（取消测试用）：持续让出事件循环，直到被 kill。
Future<int> _longLoop(int rounds, TaskContext ctx) async {
  int done = 0;
  for (int i = 0; i < rounds; i++) {
    ctx.reportProgress(i + 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    done = i + 1;
  }
  return done;
}

/// 必抛任务（远端意外失败）。
int _alwaysThrows(int x, TaskContext ctx) => throw StateError('boom $x');

/// 不可跨 isolate 传递的持有者（内含 [ReceivePort]）。
class _NonSendable {
  final ReceivePort port = ReceivePort();
  int value = 7;
  void close() => port.close();
}

/// 测试用任务（任务体是闭包：**`'sync'` 后端允许**，isolate 后端要求顶层函数）。
class _SyncTask<T> implements BackgroundTask<T> {
  _SyncTask({
    required this.label,
    required this.totalUnits,
    required this.body,
  });

  @override
  final String label;

  @override
  final int totalUnits;

  final Future<T> Function(TaskContext ctx) body;

  @override
  Future<T> run(TaskContext ctx) => body(ctx);
}

/// 断言「进度流单调不减」。
void _expectMonotonic(List<double> values) {
  for (int i = 1; i < values.length; i++) {
    expect(
      values[i] >= values[i - 1],
      isTrue,
      reason: '进度必须单调不减（RUST-05 ③）：$values',
    );
  }
}

void main() {
  group('TaskHandle 统一语义（§F 的「两后端必须一致」表）', () {
    test('取消幂等：重复 cancel 只触发一次后端取消动作', () async {
      int cancels = 0;
      final TaskHandle handle = TaskHandle.forRunner(() => cancels++);
      expect(handle.isCancelled, isFalse);
      handle.cancel();
      handle.cancel();
      handle.cancel();
      expect(cancels, 1);
      expect(handle.isCancelled, isTrue);
    });

    test('已收尾后 cancel 不再触发后端动作', () async {
      int cancels = 0;
      final TaskHandle handle = TaskHandle.forRunner(() => cancels++);
      handle.backendSucceed(42);
      expect(await handle.result<int>(), 42);
      handle.cancel();
      expect(cancels, 0);
    });

    test('进度：归一化到 0~1、丢弃倒退值、收尾必补 1.0', () async {
      final TaskHandle handle = TaskHandle.forRunner(() {});
      final List<double> seen = <double>[];
      handle.progress.listen(seen.add);
      expect(handle.progressValue, 0.0);

      handle.backendBegin(10);
      handle.reportProgress(5);
      handle.reportProgress(3); // 倒退 → 丢弃
      handle.reportProgress(10);
      handle.backendSucceed('ok');

      await pumpEventQueue();
      expect(seen, <double>[0.5, 1.0]);
      expect(handle.progressValue, 1.0);
    });

    test('totalUnits=0（未知工作量）：只发收尾终值 1.0', () async {
      final TaskHandle handle = TaskHandle.forRunner(() {});
      final List<double> seen = <double>[];
      handle.progress.listen(seen.add);
      handle.backendBegin(0);
      handle.reportProgress(999);
      handle.backendSucceed(null);
      await pumpEventQueue();
      expect(seen, <double>[1.0]);
    });

    test('失败：result 抛原错误，settled 正常收尾（吞掉失败只表时机）', () async {
      final TaskHandle handle = TaskHandle.forRunner(() {});
      handle.backendBegin(1);
      handle.backendFail(StateError('任务炸了'), StackTrace.current);

      await expectLater(
        handle.result<int>(),
        throwsA(isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          '任务炸了',
        )),
      );
      // 关键假设（`SearchSession._finish` 依赖它）：ignore() 之后的 future 仍能被
      // 后续 listener 拿到错误——否则 settled 会「静默失败」成假绿。
      await handle.settled;
    });

    test('取消：result 抛 TaskCancelledException（带栈），settled 收尾', () async {
      final TaskHandle handle = TaskHandle.forRunner(() {});
      handle.cancel();
      expect(handle.isCancelled, isTrue);
      handle.backendCancelled();
      await expectLater(
        handle.result<void>(),
        throwsA(isA<TaskCancelledException>()),
      );
      await handle.settled;
    });

    test('TaskContext.throwIfCancelled：未取消时不抛，取消后抛且带栈', () {
      final TaskHandle handle = TaskHandle.forRunner(() {});
      final TaskContext ctx =
          TaskContext(cancelSignal: handle, progressSink: handle);
      ctx.throwIfCancelled(); // 未取消 → 不抛
      handle.cancel();
      expect(ctx.isCancelled, isTrue);
      expect(() => ctx.throwIfCancelled(), throwsA(isA<TaskCancelledException>()));
    });
  });

  group("SyncBackgroundRunner / TaskRunnerRegistry（§F 后端契约）", () {
    test("标识与可用性：'sync' 恒可用", () {
      const SyncBackgroundRunner runner = SyncBackgroundRunner();
      expect(runner.id, 'sync');
      expect(runner.isAvailable, isTrue);
    });

    test('注册表：缺省取 defaultRunner；显式注入优先；fallback() 同形制', () {
      const IsolateBackgroundRunner injected = IsolateBackgroundRunner();
      expect(const TaskRunnerRegistry().runner.id, 'sync');
      expect(TaskRunnerRegistry(runner: injected).runner, same(injected));
      expect(TaskRunnerRegistry.fallback().runner.id, 'sync');
    });

    test('成功路径：result 取值，进度单调且终值 1.0', () async {
      const SyncBackgroundRunner runner = SyncBackgroundRunner();
      final List<double> seen = <double>[];
      final TaskHandle handle = runner.start<int>(_SyncTask<int>(
        label: '计数任务',
        totalUnits: 4,
        body: (TaskContext ctx) async {
          for (int i = 1; i <= 4; i++) {
            ctx.reportProgress(i);
          }
          return 4;
        },
      ));
      handle.progress.listen(seen.add);
      expect(await handle.result<int>(), 4);
      await pumpEventQueue();
      _expectMonotonic(seen);
      expect(seen.last, 1.0);
    });

    test('取消路径：检查点抛 → TaskCancelledException，进度不达 1.0', () async {
      const SyncBackgroundRunner runner = SyncBackgroundRunner();
      final TaskHandle handle = runner.start<int>(_SyncTask<int>(
        label: '取消感知任务',
        totalUnits: 100,
        body: (TaskContext ctx) async {
          for (int i = 1; i <= 100; i++) {
            ctx.throwIfCancelled();
            ctx.reportProgress(i);
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          return 100;
        },
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      handle.cancel();
      expect(handle.isCancelled, isTrue);
      await expectLater(
        handle.result<int>(),
        throwsA(isA<TaskCancelledException>()),
      );
      await handle.settled;
      // 取消不是完成：不得补发 100%。
      expect(handle.progressValue, lessThan(1.0));
    });

    test('失败路径：任务体抛错 → result 抛同一错误', () async {
      const SyncBackgroundRunner runner = SyncBackgroundRunner();
      final TaskHandle handle = runner.start<void>(_SyncTask<void>(
        label: '必炸任务',
        totalUnits: 0,
        body: (TaskContext ctx) async => throw StateError('sync boom'),
      ));
      await expectLater(
        handle.result<void>(),
        throwsA(isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          'sync boom',
        )),
      );
    });

    test('任务体**同步**抛错也走正常失败路径（不从 start() 冒出）', () async {
      const SyncBackgroundRunner runner = SyncBackgroundRunner();
      final TaskHandle handle = runner.start<void>(_SyncTask<void>(
        label: '同步抛任务',
        totalUnits: 0,
        body: (TaskContext ctx) => throw StateError('sync-immediate'),
      ));
      expect(handle.isCancelled, isFalse);
      await expectLater(
        handle.result<void>(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('IsolateBackgroundRunner（§F 后端 A）', () {
    test('非 IsolateBackgroundTask → 明确 ArgumentError（不静默降级）', () {
      const IsolateBackgroundRunner runner = IsolateBackgroundRunner();
      expect(
        () => runner.start<int>(_SyncTask<int>(
          label: '闭包任务',
          totalUnits: 0,
          body: (TaskContext ctx) async => 1,
        )),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('任务确实跑在**独立 isolate**（debugName 取证）', () async {
      const IsolateBackgroundRunner runner = IsolateBackgroundRunner();
      final String mainTag = Isolate.current.debugName ?? '';
      final TaskHandle handle = runner.start<String>(
        IsolateBackgroundTask<int, String>(
          label: '取证任务',
          body: _whereTag,
          message: 0,
          debugLabel: 'mreader-task-probe',
        ),
      );
      expect(await handle.result<String>(), 'x@mreader-task-probe');
      expect(mainTag, isNot('mreader-task-probe'));
    });

    test('进度回传：单调不减且收尾补 1.0（密集回报被接收端节流，终值不受影响）', () async {
      const IsolateBackgroundRunner runner = IsolateBackgroundRunner();
      final List<double> seen = <double>[];
      final TaskHandle handle = runner.start<int>(
        IsolateBackgroundTask<int, int>(
          label: '进度任务',
          body: _countWithProgress,
          message: 200,
          totalUnits: 200,
        ),
      );
      handle.progress.listen(seen.add);
      expect(await handle.result<int>(), 200);
      await pumpEventQueue();
      _expectMonotonic(seen);
      expect(seen.last, 1.0);
    });

    test('取消：kill isolate → TaskCancelledException，句柄快速收尾', () async {
      const IsolateBackgroundRunner runner = IsolateBackgroundRunner();
      final TaskHandle handle = runner.start<int>(
        IsolateBackgroundTask<int, int>(
          label: '长跑任务',
          body: _longLoop,
          message: 200,
          totalUnits: 200,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final Stopwatch stopwatch = Stopwatch()..start();
      handle.cancel();
      await expectLater(
        handle.result<int>(),
        throwsA(isA<TaskCancelledException>()),
      );
      stopwatch.stop();
      expect(handle.isCancelled, isTrue);
      // 取消后 CPU 回落（RUST-05 ①）：句柄立即收尾，不等任务自然跑完（200×20ms≈4s）。
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('远端失败 → TaskRemoteFailure 转述文本 + 文本栈（不抛原始对象）', () async {
      const IsolateBackgroundRunner runner = IsolateBackgroundRunner();
      final TaskHandle handle = runner.start<int>(
        IsolateBackgroundTask<int, int>(
          label: '必炸任务',
          body: _alwaysThrows,
          message: 7,
        ),
      );
      await expectLater(
        handle.result<int>(),
        throwsA(isA<TaskRemoteFailure>()
            .having((TaskRemoteFailure e) => e.message, 'message', contains('boom 7'))
            .having((TaskRemoteFailure e) => e.stackTraceText,
                'stackTraceText', isNotNull)),
      );
    });

    test('派发失败（任务体捕获 ReceivePort）→ 同一任务回落本 isolate 现跑', () async {
      const IsolateBackgroundRunner runner = IsolateBackgroundRunner();
      final _NonSendable holder = _NonSendable();
      addTearDown(holder.close);
      final String mainTag = Isolate.current.debugName ?? '';
      // 该闭包捕获不可跨 isolate 传递的 holder → spawn 必失败 → 走 runTaskLocally。
      String body(int message, TaskContext ctx) =>
          '${holder.value + message}@${Isolate.current.debugName}';

      final TaskHandle handle = runner.start<String>(
        IsolateBackgroundTask<int, String>(
          label: '回落任务',
          body: body,
          message: 0,
          debugLabel: 'fallback-probe',
        ),
      );
      // 回落 = 本 isolate 现跑：任务里的 debugName 与测试侧一致（未被改名）。
      expect(await handle.result<String>(), '7@$mainTag');
    });
  });
}
