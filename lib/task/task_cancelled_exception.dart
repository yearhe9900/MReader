// 统一后台任务抽象的一部分：**任务被取消的唯一异常种类**（架构文档 §F）。
//
// 为什么单独一个文件（而不是塞进 `background_runner.dart`）：
//   · 只想 catch「取消」的调用方不必连带依赖整个契约层；
//   · 与架构文档 §J.1 的文件清单逐项对应，便于 gate 审查时逐条对表。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`、不 import `dart:isolate`、不 import FRB。

/// 任务被取消。
///
/// 上层**只认这一个取消信号**（§F「两后端统一种类」）：`TaskHandle.cancel()` 之后，
/// 任务体在自己的检查点抛它、后端把它收敛成取消语义——与既有
/// `SearchSession.cancel()`「取消不走 error、当正常收尾」同口径（用户中止不是失败）。
///
/// 契约细节：[TaskHandle.result] 在取消时以本异常完成（**带栈**），因此
/// 「只 await 结果、不听进度」的调用方也能区分「取消」与「真失败」。
class TaskCancelledException implements Exception {
  const TaskCancelledException();

  @override
  String toString() => 'TaskCancelledException（任务已取消）';
}
