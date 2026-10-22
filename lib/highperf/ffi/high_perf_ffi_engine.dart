// Rust 加速层的真实引擎（FRB 通路，`RUST-01` 探测面的实现）。
//
// ## 它做什么
//
// 「加载 `rust_lib_mreader` 动态库 + ABI 版本探针」——即探测期三件事：
// ① 库能不能加载（[RustLib.init]）；② 符号在不在（[probe] 调用不抛）；
// ③ 版本是否匹配（`probe()` 回传值与 `kRustAbiVersion` 逐字比对，由
// [HighPerfRegistry.warmUp] 完成）。失败一律转 [HighPerfException]，
// 由注册表收敛为「回落纯 Dart」，不阻塞主链路（`RUST-01`）。
//
// **真实能力调用**（打开书 / 逐章加载 / 资源读取）不经过本文件——它们在
// `lib/format/rust_kernel_source.dart` 直接调 `lib/src/rust/api/kernel.dart`。
// 本文件只负责「加速层此刻可不可用」这一件事。
//
// `dispose()` 为幂等空操作：FRB 运行时随进程回收，显式 dispose 反而会让
// 仍持有书句柄的调用方踩到半拆状态（`RUST-05`「不留后台线程」由句柄表保证）。
import '../../src/rust/api/guard.dart' as rust_guard;
import '../../src/rust/frb_generated.dart';
import '../high_perf_capability.dart';
import '../high_perf_error.dart';

class HighPerfFfiEngine implements HighPerfEngine {
  HighPerfFfiEngine();

  String _abiVersion = '';

  @override
  String get id => 'rust';

  @override
  String get abiVersion => _abiVersion;

  /// 解析内核已落地的三项（EPUB / TXT / MOBI 全解析走内核）；
  /// 全书搜索与 BM25 索引尚未接入，不声明。
  @override
  Set<HighPerfCapability> get capabilities => const <HighPerfCapability>{
        HighPerfCapability.epubDecompress,
        HighPerfCapability.txtChapterize,
        HighPerfCapability.mobiDecompress,
      };

  @override
  Future<void> probe() async {
    // 情形 1：动态库不存在 / 加载失败（未编译、被删、平台缺运行时）。
    try {
      await RustLib.init();
    } catch (e) {
      throw HighPerfException(
        HighPerfErrorKind.notCompiled,
        kHighPerfProbeReasonZh[HighPerfErrorKind.notCompiled]!,
        detail: '$e',
      );
    }
    // 情形 2：库在但符号缺失（ABI 不匹配）——sync 调用抛符号查找错误。
    try {
      _abiVersion = rust_guard.probe();
    } catch (e) {
      throw HighPerfException(
        HighPerfErrorKind.missingSymbol,
        kHighPerfProbeReasonZh[HighPerfErrorKind.missingSymbol]!,
        detail: '$e',
      );
    }
    if (_abiVersion.isEmpty) {
      throw const HighPerfException(
        HighPerfErrorKind.missingSymbol,
        '加速层探针无响应',
      );
    }
    // 情形 3（版本比对）由 HighPerfRegistry.warmUp 统一判定。
  }

  @override
  Future<void> dispose() async {}
}
