/// 与 Dart 侧 `HighPerfErrorKind` 一一对应。类别是契约，文案是表达。
#[derive(Debug, Clone)]
pub enum HighPerfErrorKind {
    /// 读文件失败。
    Io,
    /// 加密，明确拒绝（`RD-05`：给中文原因，不破解）。
    Encrypted,
    /// 不是合法的目标格式。
    FormatInvalid,
    /// EPUB 缺 container.xml。
    MissingContainer,
    /// 用户取消（`RUST-05`）。
    Cancelled,
    /// panic / 其它。
    Internal,
}

#[derive(Debug, Clone, thiserror::Error)]
#[error("{message_zh}")]
pub struct HighPerfError {
    pub kind: HighPerfErrorKind,
    /// 单一、中文、可读；**不得包含 Rust 类型名 / 栈 / 英文 panic 原文**。
    pub message_zh: String,
}
