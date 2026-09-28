// 后端 A：**isolate**（架构文档 §F「后端 A：纯 Dart」）。
//
// ## 它与既有 `IsolateRunner` 的分工
//
// `lib/task/isolate_runner.dart`（`PERF-01`，M2a-T06）是「把纯函数丢进 isolate 跑一次
// 并回传」的**最小封装**——**无句柄、无进度、不可取消**，服务的是「解析移出主 isolate」
// 这个不需要中途干预的场景。
//
// 本文件是它的**上位形态**：同样派进 isolate，但经统一 [TaskHandle] 暴露
// **进度**（`SendPort` 回传 + 接收端 100ms 节流）与**取消**（`Isolate.kill`），
// 服务的是「全书搜索 / 索引构建」这类长任务（`RUST-05`）。两者**并存**：
// 一次性、无需干预的任务继续用 `IsolateRunner`（更轻，且已被 M2a 全量测试覆盖）。
//
// ## 为什么任务体必须是顶层函数 / `static` 方法
//
// isolate 的入参经 `SendPort` 传递：**闭包只在「不捕获不可发送状态」时可发**，
// `ReceivePort` / 打开的 `Isolate` / `StreamController` **一律不可发**（`M1-T07` 实证）。
// 因此 [IsolateBackgroundTask] **本体留在主 isolate**，只把「顶层函数 + 消息 + 端口」
// 送过去；`run()` 在本 isolate 现跑，正好就是**派发失败时的回落实体**。
//
// ## 已知边界（如实登记，别当成已解决）
//
//   · **进度节流在接收端**：任务体每段都 `reportProgress` 是允许的，主 isolate 侧按
//     [kIsolateProgressThrottle] 丢弃过密的值——被丢的中间值是**故意的**（UI 不需要
//     60fps 的进度事件），终值由 [TaskHandle.backendSucceed] 无条件补发。
//   · **意外退出**：isolate 若在 `_isolateEntry` 之外异常死亡（VM 级），主 isolate 靠
//     `addOnExitListener` 收到退出通知，经 [kIsolateExitGrace] 宽限（给在途的 done 消息
//     一点投递时间）后判「意外退出」并让句柄失败——**不留永远 pending 的句柄**。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`（isolate 不是 io）。
import 'dart:async';
import 'dart:isolate';

import 'background_runner.dart';
import 'task_cancelled_exception.dart';

/// isolate 后端的任务体：**顶层函数或 `static` 方法**，入参可跨 isolate 传递。
///
/// 形状与 `IsolateRunner` 的 `IsolateTask<M, R>` 相比只多一个 [TaskContext]；
/// 有了它，任务体就可以用**与 Rust 后端完全同形**的写法回报进度与查取消
/// ——这正是 §F「避免两套并发模型」想要的结果。
typedef IsolateTaskBody<M, T> = FutureOr<T> Function(
  M message,
  TaskContext ctx,
);

/// 进度节流间隔（§F 表：isolate 侧 100ms）。
const Duration kIsolateProgressThrottle = Duration(milliseconds: 100);

/// isolate 退出后等待「在途 done 消息」的宽限时长。
///
/// 必要性：done 消息**先于**退出发出，但「退出通知」与「done 消息」走**两个不同端口**，
/// 跨端口投递顺序无保证。宽限只是把「正常收尾」与「真意外退出」分开，不参与业务语义。
const Duration kIsolateExitGrace = Duration(milliseconds: 200);

/// isolate 后端的任务描述。
///
/// [body] 必须是**顶层函数 / `static` 方法**（[IsolateTaskBody]）；[message] 必须
/// 可跨 isolate 传递。两者在派发前**不做运行时校验**（Dart 无法反射判定可发送性），
/// 派发失败会被 [IsolateBackgroundRunner] 捕获并**回落本 isolate 重跑**——
/// 与 `IsolateRunner.runWithFallback` 同一分工，因此「误用」的后果是「慢一点」，
/// 不是「崩掉」。
class IsolateBackgroundTask<M, T> implements BackgroundTask<T> {
  const IsolateBackgroundTask({
    required this.label,
    required this.body,
    required this.message,
    this.totalUnits = 0,
    this.debugLabel,
  });

  @override
  final String label;

  @override
  final int totalUnits;

  /// isolate 内的任务体（**顶层函数 / `static` 方法**）。
  final IsolateTaskBody<M, T> body;

  /// 业务入参（可跨 isolate 传递）。
  final M message;

  /// isolate 的 `debugName`（测试用 `Isolate.current.debugName` 取证执行位置）。
  final String? debugLabel;

  /// 在**本 isolate** 跑同一段任务体（派发失败时的回落实体）。
  ///
  /// 与 isolate 内**同一段代码**——这是「回落不产生第二套语义」的保证。
  @override
  Future<T> run(TaskContext ctx) => Future<T>.sync(() => body(message, ctx));

  /// 把业务体收成**非泛型入参**的形状，供后端派发使用。
  ///
  /// 为什么必须由**任务自己**提供这个转型（不能让后端写 `task.body(message as M, ctx)`）：
  /// 后端只持有 `BackgroundTask<T>`（拿不到具体 `M`），它在 `is IsolateBackgroundTask<Object?, T>`
  /// 判型之后拿到的是**协变提升**过的静态类型，于是它眼里的 M 是 `Object?`——
  /// 与真实任务体的 `(int, TaskContext)` 运行时类型不符，派发时直接抛
  /// `type '(int, TaskContext) => String' is not a subtype of
  /// '(Object?, TaskContext) => FutureOr ...'`（M35-T01 实测，此处略去尖括号
  /// 以免文档注释把泛型参数当成 HTML 标签）。
  /// 把转型放回**定义处**：这里的 `M` 是本实例真实的类型实参，`message as M` 才对。
  Future<Object?> Function(Object? message, TaskContext ctx) get dispatcher =>
      (Object? message, TaskContext ctx) =>
          Future<Object?>.sync(() => body(message as M, ctx));
}

/// 远端任务失败的**转述**。
///
/// 为什么不原样转述原错误对象：错误对象**不保证可跨 isolate 发送**，发送失败会让
/// 整次派发看起来像崩溃。因此经边界时降级成「文本 + 文本栈」。
///
/// **业务错误不该靠它传递**（`PERF-01` 的信封口径：可预期的业务错误请走返回值字段）。
/// 它只服务「任务体内的意外失败」。
class TaskRemoteFailure implements Exception {
  const TaskRemoteFailure(this.message, {this.stackTraceText});

  /// 远端错误的文本形式（`'$error'`）。
  final String message;

  /// 远端栈的文本形式（`'$stackTrace'`），可经 [StackTrace.fromString] 还原。
  final String? stackTraceText;

  @override
  String toString() => 'TaskRemoteFailure: $message';
}

/// isolate 内的进度出口：只持一个 [SendPort]（可发送、无状态、无资源）。
class IsolateProgressSink implements TaskProgressSink {
  const IsolateProgressSink(this._port);

  final SendPort _port;

  @override
  void reportProgress(int done) => _port.send(done);
}

/// 后端 A 实现（`id = 'isolate'`；`RUST-07`：五平台恒可用，不需要 cargo）。
class IsolateBackgroundRunner implements BackgroundRunner {
  const IsolateBackgroundRunner();

  @override
  String get id => 'isolate';

  @override
  bool get isAvailable => true;

  /// 启动：**当帧返回句柄**，随后异步 spawn（spawn 失败自动回落本 isolate）。
  ///
  /// 传入的 [task] **必须**是 [IsolateBackgroundTask]；否则抛 [ArgumentError]。
  /// 这里刻意**不做静默降级**：把一个「捕获了 `ReceivePort` 的闭包任务」悄悄放到本
  /// isolate 里跑，会掩盖调用方的错误——显式报错比「碰巧能跑」更有价值。
  @override
  TaskHandle start<T>(BackgroundTask<T> task) {
    if (task is! IsolateBackgroundTask<Object?, T>) {
      throw ArgumentError.value(
        task,
        'task',
        'isolate 后端的任务必须是 IsolateBackgroundTask'
            '（任务体须为顶层函数 / static 方法，入参须可跨 isolate 传递）',
      );
    }
    return _start(task);
  }

  TaskHandle _start<T>(IsolateBackgroundTask<Object?, T> task) {
    final ReceivePort progressPort = ReceivePort();
    final ReceivePort donePort = ReceivePort();
    final ReceivePort exitPort = ReceivePort();
    final Stopwatch sinceLastEmit = Stopwatch();

    Isolate? worker;
    bool finished = false;
    Timer? exitGrace;

    late final TaskHandle handle;
    handle = TaskHandle.forRunner(() {
      // §F 表「取消」行：isolate 侧 = `kill` + 检查点。kill 是硬中止，
      // 「不留后台线程」由此天然满足（isolate 及其全部资源一起回收）。
      worker?.kill(priority: Isolate.immediate);
      handle.backendCancelled();
    });
    handle.backendBegin(task.totalUnits);

    void closePorts() {
      finished = true;
      exitGrace?.cancel();
      progressPort.close();
      donePort.close();
      exitPort.close();
    }

    // 任何收尾路径（成功 / 失败 / 取消）都关端口，不留资源。
    handle.settled.then((_) => closePorts());

    progressPort.listen((Object? event) {
      if (finished || event is! int) return;
      final bool first = !sinceLastEmit.isRunning;
      if (!first && sinceLastEmit.elapsed < kIsolateProgressThrottle) return;
      if (first) {
        sinceLastEmit.start();
      } else {
        sinceLastEmit.reset();
      }
      handle.reportProgress(event);
    });

    donePort.listen((Object? event) {
      if (finished) return;
      switch (event) {
        case _IsolateDone(:final Object? value):
          handle.backendSucceed(value);
        case _IsolateFailure(
            :final bool cancelled,
            :final String message,
            :final String? stackTraceText
          ):
          if (cancelled) {
            handle.backendCancelled();
          } else {
            handle.backendFail(
              // 文本栈一并转述（只进调试），便于把远端失败定位回任务体。
              TaskRemoteFailure(message, stackTraceText: stackTraceText),
              stackTraceText == null
                  ? StackTrace.current
                  : StackTrace.fromString(stackTraceText),
            );
          }
      }
    });

    exitPort.listen((Object? _) {
      if (finished) return;
      // 退出通知到了但结果没到 → 可能是「done 消息仍在途」，也可能真意外退出。
      // 给一小段宽限再判，避免把正常收尾误报成失败。
      exitGrace ??= Timer(kIsolateExitGrace, () {
        if (finished) return;
        handle.backendFail(
          const TaskRemoteFailure('后台任务意外退出（未回传结果）'),
          StackTrace.current,
        );
      });
    });

    // 只捕获**任务体本身**（顶层 tear-off 或调用方给的闭包），不捕获整个 task 对象
    // ——送出去的东西越少，派发失败的面越小。转型由任务自己完成（见 `dispatcher`）。
    final Future<Object?> Function(Object?, TaskContext) body = task.dispatcher;

    Future<Isolate>.sync(
      () => Isolate.spawn<_IsolateBoot>(
        _isolateEntry,
        _IsolateBoot(
          // 直接用 `dispatcher` 的返回类型：`_isolateEntry` 保持顶层非泛型
          // （`Isolate.spawn` 的 entryPoint 要求），业务类型由入参携带。
          body: body,
          message: task.message,
          progressPort: progressPort.sendPort,
          donePort: donePort.sendPort,
          debugLabel: task.debugLabel ?? 'mreader-task',
        ),
        debugName: task.debugLabel ?? 'mreader-task',
      ),
    ).then(
      (Isolate created) {
        worker = created;
        if (handle.isCancelled) {
          // 取消发生在 spawn 完成之前：补一次 kill，别让 isolate 白跑。
          created.kill(priority: Isolate.immediate);
          return;
        }
        created.addOnExitListener(exitPort.sendPort, response: task.label);
      },
      onError: (Object _, StackTrace _) {
        // 派发失败（入参不可发送 / 平台限制）→ 同一任务在本 isolate 现跑。
        // 与 `IsolateRunner.runWithFallback` 同一分工：对外语义与从未接过 isolate 一致。
        runTaskLocally(task, handle);
      },
    );

    return handle;
  }
}

/// spawn 入参（顶层入口是 `_isolateEntry`；本类整体作为**消息**发送）。
class _IsolateBoot {
  const _IsolateBoot({
    required this.body,
    required this.message,
    required this.progressPort,
    required this.donePort,
    required this.debugLabel,
  });

  final Future<Object?> Function(Object? message, TaskContext ctx) body;
  final Object? message;
  final SendPort progressPort;
  final SendPort donePort;
  final String debugLabel;
}

/// 成功信封。
class _IsolateDone {
  const _IsolateDone(this.value);

  final Object? value;
}

/// 失败信封（**只带字符串**：错误对象与本栈都降级成文本，见 [TaskRemoteFailure]）。
class _IsolateFailure {
  const _IsolateFailure({
    required this.cancelled,
    required this.message,
    required this.stackTraceText,
  });

  final bool cancelled;
  final String message;
  final String? stackTraceText;
}

/// isolate 侧入口（**顶层、非泛型**：`Isolate.spawn` 的 entryPoint 必须是顶层 / static
/// 方法；泛型实例化 tear-off 在这里没有必要，业务类型已由入参携带）。
Future<void> _isolateEntry(_IsolateBoot boot) async {
  final TaskContext ctx = TaskContext(
    // isolate 内取消靠 kill（见 `NeverCancelled` 的注释），没有可查的标志位。
    cancelSignal: const NeverCancelled(),
    progressSink: IsolateProgressSink(boot.progressPort),
  );

  Object? value;
  try {
    value = await boot.body(boot.message, ctx);
  } on TaskCancelledException {
    boot.donePort.send(
      const _IsolateFailure(
        cancelled: true,
        message: '任务已取消',
        stackTraceText: null,
      ),
    );
    return;
  } catch (error, stackTrace) {
    boot.donePort.send(
      _IsolateFailure(
        cancelled: false,
        message: '$error',
        stackTraceText: '$stackTrace',
      ),
    );
    return;
  }
  boot.donePort.send(_IsolateDone(value));
}
