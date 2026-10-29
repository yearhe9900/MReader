// 加速层的**契约类型**：能力枚举 + 引擎抽象（架构文档 §A.1 / §A.4；`RUST-01`）。
//
// ## 为什么形制照搬、代码另立（§A.4 结论，理由不重复，只留指针）
//
// 形制来自已删的 `lib/source/capability/**`（`CapabilityRegistry` /
// `ScriptCapability` / `NullScriptCapability`）——那是一套在本工程内**已被单测覆盖过**
// 的「某平台能不能提供某项重量级能力」协议，与加速层的可用性协议**同构**。
// 照搬的是**形制**（抽象接口 / 注册表 + 静态降级工厂 / 空实现 / 幂等 `warmUp` +
// 三态探测 + `reasonFor`），另立的是**契约类型**：`Capability` 的语义域是
// 书源运行期能力（script/network/webView…），拿它当加速位会污染已固化的书源体检语义。
// 全文理由见架构文档 §A.4。
//
// 纯 Dart：**不 import Flutter、不 import `dart:io`**。
// 因此本目录的类型可被纯层（`lib/format/**`）与 isolate 任务安全引用。
// 触碰 FRB 的只有两处：探测面 `lib/highperf/ffi/high_perf_ffi_engine.dart`
// （加载 + ABI 探针）与解析调用面 `lib/format/rust_kernel_source.dart`（内核书源适配）。
import 'high_perf_error.dart';

/// Dart 侧期望的 Rust 加速层 ABI 版本（§A.3 情形 3 的**唯一可靠哨兵**）。
///
/// 与 `rust/Cargo.toml` 的 `[package] version` **必须一致**：`probe()` 回传的版本串与
/// 本常量不等即判「版本不匹配」、整体回落纯 Dart。
/// **只靠「符号存在」发现不了不兼容**——符号在、约定变了，是最难查的一类问题。
const String kRustAbiVersion = '0.2.0';

/// 目标平台是否在 Rust 层交付面内（`RUST-07`：五平台 = Android / iOS / Windows /
/// macOS / Linux；Web 已整体放弃，故**不存在** Rust→WASM 编译链）。
///
/// 编译期常量（§A.3 情形 4）：五平台均为 `true`；**未来新增平台必须显式打开**，
/// 否则探测直接短路、不尝试加载动态库——不给「加载必然失败」的路径留位置。
const bool kRustSupportedPlatform = true;

/// 加速层候选能力（`RUST-06` 的候选清单，PRD §15.6.2 六项候选的落地形态）。
///
/// **为什么候选是 5 项而不是 6 项**：候选 2 在 v2.5 拆成 2a（EPUB 解压 / zip 层）与
/// 2b（XHTML → 段落 / 正文抽取层），而 **2b 首版明确不纳入**（`package:html` 的
/// 切段行为是特定实现的隐式行为，Rust 几乎不可能逐字节复现 → `RUST-02` 的 L2
/// 等价性不可验收）。因此 2b **不占枚举值**。
///
/// **增补 [cbzPages]**：不属于阈值表候选，而是解析内核统一后 CBZ 解析实现的
/// 择一开关（`thresholdNo` = `null`），枚举总数 5 → 6。
enum HighPerfCapability {
  /// 候选 1 · MOBI / AZW3 解压（PDB 容器 + KF6/KF8 + Huff/CDIC）。
  mobiDecompress,

  /// 候选 2a · EPUB 解压（zip 层）：输出「各章原始字节」，正文抽取仍在 Dart。
  epubDecompress,

  /// 候选 3 · TXT 编码探测与大文件分章（**首版只做编码探测，解码留 Dart**）。
  txtChapterize,

  /// 候选 4 · 全书搜索（`CNT-06`）。
  fullTextSearch,

  /// 候选 5 · RAG / BM25 索引构建（`AI-06`）。
  bm25Index,

  /// CBZ 页级解析（内核 `rrk-cbz`：zip 解压 + 自然序页表）。
  ///
  /// **不占阈值表编号**（[thresholdNo] = `null`）：它不是「先测后引」的加速候选，
  /// 而是解析内核统一后 CBZ 解析实现的择一开关——纯 Dart `CbzSource` 仍为回落。
  cbzPages,
}

/// 能力的元信息：稳定标识、中文名、**阈值表编号**。
extension HighPerfCapabilityInfo on HighPerfCapability {
  /// 稳定标识：日志、留档 JSON、阈值对照表都用它——**不随中文文案变化**。
  String get wireId => switch (this) {
        HighPerfCapability.mobiDecompress => 'mobi-decompress',
        HighPerfCapability.epubDecompress => 'epub-decompress',
        HighPerfCapability.txtChapterize => 'txt-chapterize',
        HighPerfCapability.fullTextSearch => 'full-text-search',
        HighPerfCapability.bm25Index => 'bm25-index',
        HighPerfCapability.cbzPages => 'cbz-pages',
      };

  /// 中文能力名。**只进调试日志与留档文档，不进用户可见文案**
  /// （用户可见文案的唯一来源是 `lib/format/error_messages.dart`，见 `RD-05`）。
  String get labelZh => switch (this) {
        HighPerfCapability.mobiDecompress => 'MOBI/AZW3 解压',
        HighPerfCapability.epubDecompress => 'EPUB 解压（zip 层）',
        HighPerfCapability.txtChapterize => 'TXT 编码探测与大文件分章',
        HighPerfCapability.fullTextSearch => '全书搜索',
        HighPerfCapability.bm25Index => 'RAG/BM25 索引构建',
        HighPerfCapability.cbzPages => 'CBZ 页级解析',
      };

  /// PRD §15.6.3 阈值表中的**候选编号**（1 / 2 / 3 / 4 / 5）。
  ///
  /// 直接服务 `RUST-06 ⑤`「每个被实施 Rust 的能力，其超过的阈值编号可被逐条指出」：
  /// 留档 JSON 与 `describe()` 都带上它，避免「编号靠人记」。
  ///
  /// **注意**：编号 2 在阈值表里是「2a + 2b 合计判定」，本枚举的 [epubDecompress]
  /// 即 2a；**分层的 400ms 只是归因值，不作独立触发条件**（v2.6 写死，防门槛拆松）。
  ///
  /// `null` = 不在阈值表内（如 [cbzPages]：解析实现择一，非先测后引候选）。
  int? get thresholdNo => switch (this) {
        HighPerfCapability.mobiDecompress => 1,
        HighPerfCapability.epubDecompress => 2,
        HighPerfCapability.txtChapterize => 3,
        HighPerfCapability.fullTextSearch => 4,
        HighPerfCapability.bm25Index => 5,
        HighPerfCapability.cbzPages => null,
      };
}

/// 加速层引擎：**可插拔的实现缝**（`RUST-01 ④`「上层不感知实现来源」的落点）。
///
/// ## 本抽象冻结的范围
///
/// 只冻结**探测 + 能力声明**两件事——它们是「可用性协议」，与具体能力无关，
/// 且两个实现（[NullHighPerfEngine] 与 FFI 引擎）都要满足。
///
/// **各能力的真实方法**（`openSource` / `readChapterChunk` / `searchStart` /
/// `indexBuildStart` …，跨边界类型表见架构文档 §C.1）后续在本抽象上增补、
/// 两个实现**同一提交内**一起补齐。不预置这些方法，是为了避免在 FRB 生成物落地前
/// 凭想象冻结一张可能与真实桥接不匹配的签名表。
abstract interface class HighPerfEngine {
  /// 后端标识：`'null'`（纯 Dart 回落）/ `'rust'`（真实加速层）。
  /// 只进调试日志与 `describe()`。
  String get id;

  /// `probe()` 回传的 ABI 版本串；未探测时为空串。
  String get abiVersion;

  /// 本引擎**声明支持**的能力集合。
  ///
  /// 它是「引擎能力」而非「当前是否可用」——是否可用由 `HighPerfRegistry.has()` 综合
  /// 探测结论与惰性降级状态后给出（§A.3）。
  Set<HighPerfCapability> get capabilities;

  /// 轻量探测：加载动态库 + 解析符号 + 一次版本调用。
  ///
  /// 契约（§A.2）：**不读任何书、不分配大内存**，正常毫秒级；
  /// 失败抛 [HighPerfException]（情形 1/2/3 各自的 kind，见 [HighPerfErrorKind]）。
  /// 平台不支持（情形 4）由注册表在调用本方法**之前**短路，不落到实现里。
  Future<void> probe();

  /// 释放动态库句柄等资源（进程内只调一次；未探测成功时为幂等空操作）。
  Future<void> dispose();
}
