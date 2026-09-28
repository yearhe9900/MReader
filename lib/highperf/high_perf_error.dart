// 加速层的错误分类与异常（架构文档 §D.1；`RUST-04`）。
//
// ## 与 `RD-05` / `lib/format/error_messages.dart` 的关系（写死，防出现第二套用户文案）
//
// [HighPerfException.messageZh] 是**单一、中文、可读**的原因，但它**永不直接展示给用户**
// （§D.1 末段 / `RUST-04` 原文）：`BookSource` 的实现层 catch 后**回落纯 Dart 重试一次**，
// 用户看到的中文**永远来自纯 Dart 契约**（`lib/format/error_messages.dart`）。
// 因此本文件的文案只服务**调试日志与留档**，不构成第二套用户可见文案来源。
// 新增文案前请先读本文开头这段：**不要**把这里的字符串接到 UI 上。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`。
// 因此本文件可被 isolate 任务与纯层（`lib/format/**`）安全引用。

/// 与 Rust 侧 `HighPerfErrorKind`（`rust/src/api/error.rs`）**一一对应**：
/// **类别是契约，文案是表达**——等价性 L5 只比类别（§B.1 / §D.1）。
///
/// 枚举分两组，边界写死：
///   · **调用期**（前 6 个）：Rust 侧 `Result::Err` 与 panic 经桥接层转换而来，
///     与 Rust 枚举逐值对应，**不得增删**（增删即破等价性口径）；
///   · **探测期**（后 4 个）：只在 Dart 探测层出现，Rust 侧**不会、也无法**产出
///     ——它们描述的是「加速层本身能不能用」（架构文档 §A.3 的情形 1~4）。
enum HighPerfErrorKind {
  // ——— 调用期（与 Rust `HighPerfErrorKind` 逐值对应）———

  /// 读文件 / 句柄失败。
  io,

  /// 加密，明确拒绝（`RD-05`：给中文原因，不破解）。
  encrypted,

  /// 不是合法的目标格式。
  formatInvalid,

  /// EPUB 缺 `META-INF/container.xml`。
  missingContainer,

  /// 用户取消（`RUST-05`）。
  cancelled,

  /// panic / 其它内部错误（panic 已被 `catch_unwind` 兜住，绝不跨边界成为进程崩溃）。
  internal,

  // ——— 探测期（仅 Dart 侧，§A.3 情形 1~4）———

  /// 情形 1：动态库不存在（未编译 / 被删 / 被改名）。
  notCompiled,

  /// 情形 2：动态库在，但符号缺失（ABI 不匹配）。
  missingSymbol,

  /// 情形 3：符号在，但 `probe()` 回传的版本串 ≠ [kRustAbiVersion]。
  abiMismatch,

  /// 情形 4：编译期判定该平台不在交付面内（[kRustSupportedPlatform] 为 false）。
  platformUnsupported,
}

/// 加速层异常。
///
/// 形制照搬 [MReaderFormatException]（`lib/format/error_messages.dart`）：
/// **类别 / 错误码决定文案，`detail` 只给调试**，[toString] 不泄漏 Rust 类型名与栈。
class HighPerfException implements Exception {
  const HighPerfException(this.kind, this.messageZh, {this.detail});

  final HighPerfErrorKind kind;

  /// 单一、中文、可读的原因；**不得包含 Rust 类型名 / 栈 / 英文 panic 原文**（§D.1）。
  final String messageZh;

  /// 仅调试用（如 `DynamicLibrary.open` 的原始报错），**不直接展示给用户**。
  final String? detail;

  /// 与 §D.1 原型一致：**只回 `messageZh`**（不把 `detail` 带进日志主线的单行原因里；
  /// 需要细节时读 `describe()` 或显式取 [detail]）。
  @override
  String toString() => messageZh;
}

/// 各失败情形的**唯一中文原因**（探测期专用；调用期文案由 Rust 侧随错误一起给出）。
///
/// 只覆盖 [HighPerfErrorKind] 里 Dart 探测层自己产出的 4 类——调用期 6 类的文案
/// 由 Rust 侧错误随 `HighPerfException` 回传，**不在此表内二次定义**（避免两份文案漂移）。
const Map<HighPerfErrorKind, String> kHighPerfProbeReasonZh =
    <HighPerfErrorKind, String>{
  HighPerfErrorKind.notCompiled: '未编译 Rust 加速层',
  HighPerfErrorKind.missingSymbol: '动态库符号缺失（版本不匹配）',
  HighPerfErrorKind.abiMismatch: '加速层版本不匹配',
  HighPerfErrorKind.platformUnsupported: '当前平台不在 Rust 加速层交付面内',
};
