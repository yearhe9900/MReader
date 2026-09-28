// 加速层空实现（架构文档 §A.4「空实现（回落路径，保证可编译可运行）」）。
//
// 它就是「**纯 Dart 回落**」这一事实的载体：不加载任何动态库、一项能力都不声明，
// 因此 `HighPerfRegistry` 对它的判定恒为「全不支持」——上层拿到的永远是纯 Dart 实现。
//
// 它的存在保证了两条硬约束在**没有 Rust 的机器上**也成立（`RUST-07`）：
//   · `flutter test` / `flutter build` 不需要 Rust 工具链；
//   · `RUST-01 ①②`「删掉动态库 / 强制仅纯 Dart，功能完整」。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`、不 import FRB 生成物。
import 'high_perf_capability.dart';

/// 空引擎：**声明「一项能力都不支持」**。
///
/// 与 `capability_registry.dart` 里 `NullScriptCapability` 的地位完全相同：
/// 它是回落路径的**唯一实现**，因此可以 `const` 构造、可以被注册表当作编译期常量兜底。
///
/// [probe] 是**空操作且不抛**：没有动态库要加载，也就没有失败可言——注册表把
/// 「纯 Dart 回落」记为 `probeOk = false`（见 `HighPerfRegistry.fallback()`），
/// 而不是让这里抛异常来制造一个「失败」。
class NullHighPerfEngine implements HighPerfEngine {
  const NullHighPerfEngine();

  @override
  String get id => 'null';

  /// 没有 ABI 可言：回空串（注册表**不会**拿它去比 [kRustAbiVersion]——
  /// 比对只发生在真实探测路径上）。
  @override
  String get abiVersion => '';

  @override
  Set<HighPerfCapability> get capabilities => const <HighPerfCapability>{};

  @override
  Future<void> probe() async {}

  @override
  Future<void> dispose() async {}
}
