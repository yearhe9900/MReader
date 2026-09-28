// 统一后台任务抽象（架构文档 §F）——避免「Isolate 一套并发模型 + Rust 一套」。
//
// ## 它解决什么（§F 的问题陈述）
//
// 纯 Dart 路径把重活丢进 Isolate（`PERF-01` / `CNT-06`）；Rust 路径由 FRB 线程池承担。
// 若不做统一，同一件事就会出现「Isolate 一套取消 / 进度、Rust 一套取消 / 进度」，
// 上层要写两套。于是：**`BackgroundRunner` 抽象 + 两个后端 + 统一 `TaskHandle`**。
//
// ## 验收标准（§F 末段，写死）
//
// **上层代码里搜不到 `Isolate` 这个字，也搜不到 `rust` 这个字**——与 `RUST-01 ④`
// 「UI 与业务层搜索不到任何『是否为 Rust』的分支判断」同源。
//
// ## 本文件的内容边界
//
// 只放**契约 + 一个不依赖 isolate / FFI 的后端**：
//   · `BackgroundRunner` / `BackgroundTask` / `TaskContext` / `TaskHandle` /
//     `TaskRunnerRegistry`；
//   · `SyncBackgroundRunner`（后端 `'sync'`：本 isolate 直接跑；小任务、测试、
//     以及真后端的**回落实体**）。
// isolate 后端在 `isolate_background_runner.dart`；Rust 后端在
// `rust_background_runner.dart`（M35-T04）。三者都只实现本文件的契约。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`、不 import `dart:isolate`。
import 'dart:async';

import 'task_cancelled_exception.dart';

/// 取消信号：任务体在**检查点**查询「是否已被要求停止」。
///
/// 抽成接口（而不是让 [TaskContext] 直接持有 [TaskHandle]）的原因只有一个、但很硬：
/// isolate 后端里任务体跑在**另一个 isolate**，而 [TaskHandle] 持 `StreamController`
/// 与取消闭包——**不可跨 isolate 传递**。因此 [TaskContext] 由「取消信号 + 进度出口」
/// 两块**可发送的**协作者组装。
abstract interface class TaskCancelSignal {
  bool get isCancelled;
}

/// 永不取消的取消信号（无状态、可 `const`、可跨 isolate）。
///
/// isolate 后端用它：那边取消 = `Isolate.kill(priority: immediate)`——任务所在 isolate
/// 直接消失，既**不需要**也**无法**查询标志位。
/// **这不是「忽略取消」**：kill 比检查点更硬，只是「任务体读到 false 但已被杀」这件事
/// 在 isolate 侧是正常且无副作用的（资源随 isolate 一起回收，§F 表「资源」行）。
class NeverCancelled implements TaskCancelSignal {
  const NeverCancelled();

  @override
  bool get isCancelled => false;
}

/// 进度出口（**唯一入口**，两后端在此归一化为同一语义）。
abstract interface class TaskProgressSink {
  /// 已完成的工作量（单位由任务自定义，与 [BackgroundTask.totalUnits] 同尺）。
  ///
  /// **必须单调递增**；节流由后端负责（isolate 侧由接收端按 100ms 节流；
  /// Rust 侧由 Rust 自己节流，`TaskHandle` 侧只保证「不倒退、不超 1.0」）。
  void reportProgress(int done);
}

/// 任务上下文：**取消与进度的唯一入口**（§F）。
///
/// 与 §F 原型的唯一结构差异：构造收**两个协作者**而不是一个 `TaskHandle`——
/// 原因见 [TaskCancelSignal]（isolate 内拿不到句柄）。三个方法的语义与 §F 逐条一致。
class TaskContext {
  const TaskContext({
    required this.cancelSignal,
    required this.progressSink,
  });

  /// 取消信号（isolate 内为 [NeverCancelled]——那边取消靠 `Isolate.kill`）。
  final TaskCancelSignal cancelSignal;

  /// 进度出口（主 isolate 侧就是 [TaskHandle] 自己；isolate 内是 `SendPort` 桥）。
  final TaskProgressSink progressSink;

  bool get isCancelled => cancelSignal.isCancelled;

  /// 回报进度（后端负责节流；重复 / 倒退的值会被句柄丢弃，见 [TaskHandle]）。
  void reportProgress(int done) => progressSink.reportProgress(done);

  /// 检查点：已取消则抛 [TaskCancelledException]。
  ///
  /// **与 §F 原型的差异（刻意，已核对语义）**：原型写作
  /// `static Never throwIfCancelled()`。静态方法读不到**本上下文实例**的取消状态，
  /// 那样它只能无条件抛，与「任务被取消则抛此异常」的文字语义不符（原型笔误）。
  /// 此处按**实例方法**实现，签名收成 `void`——`Never` 无法表达「未取消时什么都不做」。
  void throwIfCancelled() {
    if (isCancelled) throw const TaskCancelledException();
  }
}

/// 统一的句柄：**上层只认它**，不关心后端是 Isolate 还是 Rust（§F）。
///
/// 统一语义（§F 的「两后端必须一致」表，逐行落点）：
///   · **取消** → [cancel] 幂等；[isCancelled] 立即为 `true`；任务体抛
///     [TaskCancelledException]；后端负责「取消后 CPU 回落、不留后台线程」；
///   · **进度** → [progress] 是 `0.0~1.0`、**单调不减**的广播流；
///   · **异常** → 取消是 [TaskCancelledException]，其余失败按原错误（或远端转述）完成。
class TaskHandle implements TaskCancelSignal, TaskProgressSink {
  TaskHandle._(this._cancel);

  /// 后端实现方创建句柄（`_` 生成构造仅本库可见；对外只暴露这一条工厂）。
  factory TaskHandle.forRunner(void Function() cancel) = TaskHandle._;

  final void Function() _cancel;
  final StreamController<double> _progress =
      StreamController<double>.broadcast();
  final Completer<Object?> _result = Completer<Object?>();

  double _progressValue = 0;
  int _totalUnits = 0;

  /// 是否已被要求取消：`cancel()` 后**立即**为 `true`（不等后端确认）。
  ///
  /// 用可变字段而非 `_cancelled` 私有量 + getter：它本身就是 §F 里的公开契约位，
  /// 且实现 [TaskCancelSignal] 需要这个 getter。
  @override
  bool isCancelled = false;

  /// 进度流（广播）：`0.0 ~ 1.0`，单调不减；收尾必发终值（见 [backendSucceed]）。
  ///
  /// **不重放**：订阅之前发出的值不会补发。后端保证「任务体在首个 `await` 之后才回报」
  /// 或「订阅早于任务体开跑」二者之一成立（`'sync'` / 回落路径靠 `start()` 后让出一轮
  /// 微任务；isolate 路径天然异步），因此 `start(); handle.progress.listen(...)` 这种
  /// 紧邻写法能收到**全部**进度。若订阅得更晚，用 [progressValue] 取当前值。
  Stream<double> get progress => _progress.stream;

  /// 最近一次进度值（无回报时为 `0.0`）。
  ///
  /// 给 UI 首帧初始化用——`StreamBuilder` 在首个事件到达前拿不到值，用它可避免
  /// 进度条从 0 跳一下。
  double get progressValue => _progressValue;

  /// 任务结果。
  ///
  /// 取消时以 [TaskCancelledException] 完成（带栈）；失败时以原错误（或远端转述的
  /// [TaskRemoteFailure]）完成。`T` 由调用处指定，与 [BackgroundRunner.start] 的 `T` 一致。
  Future<T> result<T>() async => (await _result.future) as T;

  /// 收尾完成（成功 / 取消 / 失败皆算），用于 `await` 到「可以清理资源」的时机。
  ///
  /// 与 [result] 的分工：[result] 会把失败**抛出**，[settled] **吞掉**失败只表时机。
  Future<void> get settled =>
      _result.future.then<void>((_) {}, onError: (Object _) {});

  /// 请求取消（**幂等**）：已取消或已收尾则**不再**触发后端取消动作。
  ///
  /// 在句柄侧就挡住重复调用的理由：后端取消动作可能不便宜（kill isolate /
  /// 通知 Rust 侧 `CancelFlag`），而 §F 要求 `isCancelled` 幂等。
  void cancel() {
    if (isCancelled || _result.isCompleted) return;
    isCancelled = true;
    _cancel();
  }

  // ————————————— 以下方法**仅供后端实现方**（BackgroundRunner 子类）调用 —————————————
  // 上层只用 progress / progressValue / cancel / isCancelled / result / settled。

  /// 后端开工：设定总工作量（`0` = 未知；此时进度流只会有收尾终值）。
  void backendBegin(int totalUnits) {
    _totalUnits = totalUnits < 0 ? 0 : totalUnits;
  }

  /// 进度回报（实现 [TaskProgressSink]，因此可直接作 [TaskContext] 的进度出口）。
  ///
  /// 与 §F 的 `_report` 同职责：**归一化 → 单调不减 → 广播**；倒退值与重复值直接丢弃
  /// （`RUST-05 ③`「进度回报单调递增」由这一处兜住，后端不必各自防重）。
  @override
  void reportProgress(int done) {
    if (_result.isCompleted) return;
    final int total = _totalUnits;
    final double fraction =
        total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0).toDouble();
    _emit(fraction);
  }

  /// 后端**成功**收尾。
  ///
  /// 收尾必报（§F：即使任务从不回报进度，也要让 UI 看到 100%）——因此这里无条件补发
  /// `1.0`（`_emit` 的单调性保证重复时不会多发）。
  void backendSucceed(Object? value) {
    if (_result.isCompleted) return;
    _emit(1.0);
    _closeProgress();
    _result.complete(value);
  }

  /// 后端**失败**收尾。
  void backendFail(Object error, StackTrace stackTrace) {
    if (_result.isCompleted) return;
    _closeProgress();
    _result.completeError(error, stackTrace);
    // 调用方可能只听 progress 不听 result：把「未被听取」的错误吞成正常收尾，
    // 避免 unhandled async error（与 `SearchSession._finish` 同一处理）。
    _result.future.ignore();
  }

  /// 后端**确认已取消**（isolate 被 kill / Rust 任务收到 cancel）。
  void backendCancelled() {
    if (_result.isCompleted) return;
    _closeProgress();
    _result.completeError(const TaskCancelledException(), StackTrace.current);
    _result.future.ignore();
  }

  void _emit(double fraction) {
    if (fraction <= _progressValue) return; // 单调不减（RUST-05 ③）
    _progressValue = fraction;
    if (!_progress.isClosed) _progress.add(fraction);
  }

  void _closeProgress() {
    if (!_progress.isClosed) _progress.close();
  }
}

/// 一个可在后台执行、**可取消、可回报进度**的任务（§F）。
///
/// 它是「后端无关」的那一面：任务体只经 [TaskContext] 接触取消与进度，
/// **不知道**自己在 isolate 里还是在 Rust 线程池里。
///
/// isolate 后端另有硬约束（任务体须为顶层函数 / `static` 方法），见
/// `IsolateBackgroundTask`——那个约束属于**后端**，不属于本抽象。
abstract class BackgroundTask<T> {
  /// 人类可读标签（日志 / 进度文案用）。**不进用户可见文案库**（`RD-05`）。
  String get label;

  /// 总工作量（进度百分比的分母）；未知返回 `0`。
  int get totalUnits;

  /// 执行体。[ctx] 提供取消查询与进度回报。
  Future<T> run(TaskContext ctx);
}

/// 后端契约（§F）：标识 + 可用性 + 启动。
abstract class BackgroundRunner {
  /// 后端标识：`'isolate'` | `'rust'` | `'sync'`。
  String get id;

  /// 本后端此刻是否可用。
  ///
  /// 注意它与 `HighPerfRegistry.has(...)` **不是一回事**：后者回答「某个格式能力能不能
  /// 走加速层」，本项回答「这类任务此刻能不能派到后台」。`RUST-07` 下
  /// `'isolate'` 五平台恒可用，不需要 cargo。
  bool get isAvailable;

  /// 启动任务：**当帧返回句柄**（可订阅进度、可取消），结果经 [TaskHandle.result] 取。
  ///
  /// 句柄本身不带泛型（§F 形状），后端内部以 `Object?` 装结果，
  /// 由 [TaskHandle.result] 在调用处转回 `T`。
  TaskHandle start<T>(BackgroundTask<T> task);
}

/// 后端 C：**本 isolate 直接跑**（`id = 'sync'`）。
///
/// 三个正式用途（不是「调试凑数」）：
///   1. **小任务**：开销小于一次 isolate 建销（`Isolate.spawn` 有真实成本）；
///   2. **测试**：进度 / 取消语义的确定性验证，无需真 isolate 的时序；
///   3. **回落后端**：真后端派发失败时在同一任务上现跑——与既有
///      `IsolateRunner.runWithFallback` 的分工完全一致（`RUST-01` 式诚实降级）。
///
/// ## 取消语义（诚实说明，别误读成「不生效」）
///
/// `cancel()` 只把句柄置位，**非阻塞**：真正的中止发生在任务体自己的
/// `ctx.throwIfCancelled()` 检查点。没有检查点的任务，`'sync'` 后端不会强行打断它
/// ——这与 isolate 后端「`kill` 更硬但任务在原生调用里同样收不到」是同一类边界。
class SyncBackgroundRunner implements BackgroundRunner {
  const SyncBackgroundRunner();

  @override
  String get id => 'sync';

  @override
  bool get isAvailable => true;

  @override
  TaskHandle start<T>(BackgroundTask<T> task) {
    final TaskHandle handle = TaskHandle.forRunner(_noop);
    handle.backendBegin(task.totalUnits);
    runTaskLocally(task, handle);
    return handle;
  }

  static void _noop() {}
}

/// 在**本 isolate** 里执行 [task]，把结果并入**已存在**的 [handle]。
///
/// 为什么是自由函数而不是 [SyncBackgroundRunner] 的私有方法：isolate 后端在
/// **派发失败**时也必须把结果并入「它已经返回给调用方的那个句柄」（不能换成新句柄，
/// 否则调用方手里的 handle 永远不收尾）。两条路径共用这一处实现，
/// 保证「回落后端」与「'sync' 后端」语义逐字一致——同 `IsolateRunner.runWithFallback`
/// 的分工（派发失败 → 同一任务在本 isolate 现跑，对外语义不变）。
void runTaskLocally<T>(BackgroundTask<T> task, TaskHandle handle) {
  // **让出一轮微任务再跑任务体**：`Future.sync` 会就地（同步）执行任务体的同步前缀，
  // 若在 `start()` 返回之前就跑，调用方在 `start()` 之后才 `listen` 的进度订阅
  // 一个事件都收不到（广播流不重放）——M35-T01 实测踩到。
  // 延后一轮后，`start(); handle.progress.listen(...)` 这段同步代码先跑完，
  // 订阅一定早于第一个进度事件。
  scheduleMicrotask(() {
    final TaskContext ctx = TaskContext(cancelSignal: handle, progressSink: handle);
    // `Future.sync` 让「任务体同步抛出的错误」也变成正常失败路径，
    // 而不是从 start() 里冒出去（后端契约：start 不抛业务错误）。
    Future<T>.sync(() => task.run(ctx)).then(
      (T value) {
        if (handle.isCancelled) {
          handle.backendCancelled();
        } else {
          handle.backendSucceed(value);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (handle.isCancelled && error is TaskCancelledException) {
          handle.backendCancelled();
        } else {
          handle.backendFail(error, stackTrace);
        }
      },
    );
  });
}

/// 后端选择（§F；与 `HighPerfRegistry` 同形制：构造注入 + 静态缺省）。
///
/// ## 与 §F 原型的差异（刻意，理由两条）
///
/// 原型写 `?? IsolateBackgroundRunner()`，本实现缺省为 [SyncBackgroundRunner]：
///   1. **避免契约文件反向依赖后端文件**：isolate 后端要 import 本文件拿契约，
///      本文件再 import 它就会形成 import 环（Dart 允许，但契约层从此拖进
///      `dart:isolate`，「纯契约」的意义就没了）；
///   2. **isolate 后端有前置条件**：它要求任务体是「顶层函数 / `static` 方法」
///      （`IsolateBackgroundTask`）。把一个**有条件**的后端设为无脑缺省，会让调用方
///      在运行时才吃 `ArgumentError`。
///
/// 因此：**组合根显式给 isolate 后端**（`TaskRunnerRegistry(runner: const
/// IsolateBackgroundRunner())`）。M35-T04 接入 Rust 后端后，此处按
/// `HighPerfRegistry` 择后端的逻辑加在这里，**上层调用点不变**。
class TaskRunnerRegistry {
  const TaskRunnerRegistry({BackgroundRunner? runner})
      : _injectedRunner = runner;

  final BackgroundRunner? _injectedRunner;

  /// 当前后端（未指定时取 [defaultRunner]）。
  BackgroundRunner get runner => _injectedRunner ?? defaultRunner;

  /// 缺省后端：`'sync'`（见类注释的两条理由）。
  static const BackgroundRunner defaultRunner = SyncBackgroundRunner();

  /// 静态降级工厂（与 `HighPerfRegistry.fallback()` 同形制）。
  static TaskRunnerRegistry fallback() => const TaskRunnerRegistry();
}
