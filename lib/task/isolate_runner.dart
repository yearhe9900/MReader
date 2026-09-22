// `PERF-01` 铺路：把「**纯函数 + 可序列化入参**」丢进一个 isolate 跑一次并回传的**最小封装**。
//
// ⚠️ 本任务（M1-T07）**不接线到 `load()`**——`PERF-01`（`compute()` 化解析）已前移到
// `M2a-T06`，届时复用本文件。这里只提供薄封装 + 「不可序列化 / 捕获闭包」的护栏，
// 避免 M2a 踩坑。
//
// 为什么单独成文件：`lib/epub/**` 与 `lib/format/**` 是**纯 Dart**（零 Flutter），
// 可整体丢进 isolate；本封装是对「产生 isolate 入口」这件事的唯一收口点，
// M3.5 若把解压层 Rust 化，替换点也在这里。
import 'dart:async';

import 'package:flutter/foundation.dart' show ComputeCallback, compute;

/// isolate 运行的薄封装（`M2a-T06` / `PERF-01` 会复用）。
///
/// 用法约定（**必须遵守，否则运行期会明确报错、不会静默**）：
///   · [callback] 必须是**顶层函数或 `static` 方法**——不得捕获 `this` 或闭包变量
///     （尤其不得捕获不可跨 isolate 传递的对象，如 `ReceivePort`）；
///   · [message] 与返回值 [R] 必须**可跨 isolate 传递**（`SendPort` 可序列化）。
///
/// 违反上述约定时，底层 isolate 派发会抛出明确错误（`ArgumentError` 等）。
class IsolateRunner {
  const IsolateRunner();

  /// 在一个 isolate 里执行 [callback]，入参 [message]，回传结果 [R]。
  ///
  /// 本方法**只做编排**：真正的 isolate 生命周期由 Flutter 的 [compute] 管理
  /// （其内部走 `Isolate.run`，自动建、跑、收）。本封装存在的意义是给出
  /// **单一入口 + 明确契约**，便于 `PERF-01` 前移时统一接线与测试。
  Future<R> run<M, R>(
    ComputeCallback<M, R> callback,
    M message, {
    String? debugLabel,
  }) {
    return compute<M, R>(callback, message, debugLabel: debugLabel ?? 'mreader');
  }
}
