use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::api::error::{HighPerfError, HighPerfErrorKind};

/// 统一边界：`catch_unwind` → `HighPerfError`。panic 绝不跨边界。
///
/// 位置在**最外层导出函数**（不是底层工具函数）：一次覆盖该次调用的全部代码
/// 路径；放内层会漏掉「内层没包到的 panic」。不依赖 FRB 默认行为——边界契约
/// 不依赖第三方默认值（架构 §D.2）。生效前提 = `Cargo.toml` 两处
/// `panic = "unwind"`（`test/rust_profile_guard_test.dart` 护栏）。
///
/// FRB codegen 会因泛型签名自动跳过本函数（scratch 实测输出
/// `functions are ignored because they have generic arguments`），它只被
/// crate 内部调用，不产生 Dart 绑定。
pub fn ffi_guard<T>(f: impl FnOnce() -> Result<T, HighPerfError>) -> Result<T, HighPerfError> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(_) => {
            // 只取一句中文，不把 panic 原文（含英文/类型名）泄露到边界外。
            // 调试期可 log 记录；release 不输出（`RUST-01`）。
            Err(HighPerfError {
                kind: HighPerfErrorKind::Internal,
                message_zh: "加速层内部错误，已回落纯 Dart 实现。".to_string(),
            })
        }
    }
}

/// ABI 版本探针（`M35-T03` 最小通路）：Dart 侧与 `kRustAbiVersion` 逐字比对，
/// 不一致 = 情形 3「版本不匹配」→ 整体回落纯 Dart（`RUST-01` 探测表）。
/// 返回值 = `0.1.0`，改版本号必须同步改 Dart 常量，否则探测必然失败。
#[flutter_rust_bridge::frb(sync)]
pub fn probe() -> String {
    ffi_guard(|| Ok("0.1.0".to_string())).unwrap_or_default()
}
