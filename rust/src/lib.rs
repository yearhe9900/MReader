// `NF-D8` / 架构 §D.3：编译期机械护栏——出现 clippy.toml 里列出的写盘方法即编译失败。
// Rust 只读，写盘一律回 Dart（原子写入）。
#![deny(clippy::disallowed_methods)]

pub mod api;
mod frb_generated;
