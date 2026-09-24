// `PERF-01`（`M2a-T06` 已接线）：把「**纯函数 + 可序列化入参**」丢进一个后台 isolate
// 跑一次并回传的**最小封装**——「产生 isolate 入口」这件事的**唯一收口点**，
// M3.5 若把解压层 Rust 化，替换点也在这里。
//
// 为什么是 `dart:isolate` 而不是 Flutter 的 `compute()`：`lib/epub/**` 与 `lib/format/**`
// 是**纯 Dart**（零 Flutter、零 `dart:io`），解析任务要从这些层派发（`DartEpubSource` /
// `DartTxtSource`），本文件若引 Flutter 就会把 Flutter 依赖倒灌进纯层、违反各自文件头
// 的铁律。`Isolate.run` 与 `compute()` 在非 web 同构（后者内部就是前者），而
// `dart:isolate` 既不是 Flutter 也不是 `dart:io`，纯层引用本文件不违约。
//
// 派发契约（`M1-T07` 护栏测试见 `test/task/isolate_runner_test.dart`）：
//   · callback 顶层 / `static`、message 与返回值纯数据（**闭包不可传**，`SendPort` 拒绝）。
import 'dart:async';
import 'dart:isolate';

/// isolate 任务签名：**顶层函数或 `static` 方法**，入参与返回值均可跨 isolate 传递。
typedef IsolateTask<M, R> = FutureOr<R> Function(M message);

/// isolate 运行的薄封装（`PERF-01` / `M2a-T06` 已接线到 `DartEpubSource` / `DartTxtSource`）。
///
/// 用法约定（**必须遵守，否则派发期明确报错、不会静默**）：
///   · [task] 必须是**顶层函数或 `static` 方法**——不得捕获 `this` 或闭包变量
///     （尤其不得捕获不可跨 isolate 传递的对象，如 `ReceivePort`）；
///   · [message] 与返回值 [R] 必须**可跨 isolate 传递**（纯数据；含闭包的结果
///     会被 `SendPort` 拒绝——`M1-T07` 实证，`parseEpubResult` 即此类）。
class IsolateRunner {
  const IsolateRunner();

  /// 在一个**新 isolate** 里执行 [task]，入参 [message]，回传结果 [R]。
  ///
  /// 生命周期由 [Isolate.run] 管理（自动建、跑、收）；[debugLabel] 落到该 isolate 的
  /// `debugName`，测试可用 `Isolate.current.debugName` 取证执行位置。
  Future<R> run<M, R>(
    IsolateTask<M, R> task,
    M message, {
    String? debugLabel,
  }) {
    return Isolate.run<R>(
      () => task(message),
      debugName: debugLabel ?? 'mreader',
    );
  }

  /// [run] 的**诚实降级**版（`RUST-01` 式回落）：派发失败或远端意外失败时，把
  /// **同一任务**在本 isolate 现跑——最终结果 / 错误与从未接过 isolate 一致。
  ///
  /// 分工约定：
  ///   · 任务内**可预期的业务错误**（如 `MReaderFormatException`）请经**返回值信封**
  ///     传递、不要 throw（见 `parseEpubStructureTask` / `_txtPrepareTask`）——本方法
  ///     的回落只应见到「派发失败 / 远端意外」，信封让二者不相混淆；
  ///   · 任务直接 throw 的错误会被当作远端意外，回落重跑一次后**仍以原错误抛出**
  ///     （多花一次本 isolate 执行，对外语义不变）。
  Future<R> runWithFallback<M, R>(
    IsolateTask<M, R> task,
    M message, {
    String? debugLabel,
  }) async {
    try {
      return await run<M, R>(task, message, debugLabel: debugLabel);
    } catch (_) {
      return await task(message);
    }
  }
}
