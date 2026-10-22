# rust/vendor —— 移植的 Rust 阅读内核（vendored crates）

这里的 `rrk-*` crate **逐字节移植自** `rust_reader_kernel`（Git 仓库
`https://github.com/yearhe9900/rust_reader_kernel`，本地
`D:/Workspace/personal/rust_reader_kernel`），作为 MReader 的图书解析核心：

| crate | 职责 |
| --- | --- |
| `rrk-model` | 统一书籍数据模型（`BookMeta`/`ChapterEntry`/`ChapterContent`/`TocNode`） |
| `rrk-format` | `FormatAdapter`/`BookSource` 契约 + 嗅探注册表 + `ContentSource` |
| `rrk-markup` | XHTML/HTML 清洗（标签白名单） |
| `rrk-zip` | zip 随机读（EPUB 共用） |
| `rrk-txt` | TXT：编码检测 + 分章 + 逻辑块切分 |
| `rrk-epub` | EPUB：OPF/NCX + 清洗 + 资源管线 |
| `rrk-mobi` | MOBI/AZW3：自研 PalmDOC LZ77 + HUFF/CDIC 解压 |
| `rrk-kernel` | 会话编排（句柄表 + 格式注册 + 生命周期） |

## 纪律

1. **不在此目录做本地改造**。功能缺口回上游 `rust_reader_kernel` 提交，
   再同步进来——保持 vendored 副本可 diff、可回溯。
2. **同步方式**：整体覆盖对应 crate 目录（`src/` + `Cargo.toml`），
   同步后跑 `cargo test --workspace` 再提交。
3. 依赖白名单同上游：纯 Rust、可审计、可 fork、许可宽松
   （`encoding_rs` / `chardetng` / `flate2`）。
4. 许可：MIT OR Apache-2.0（上游双许可），版权归上游作者。

## 与宿主的接线

内核经 `rust_lib_mreader` 的 FRB API（`rust/src/api/kernel.rs`）暴露给 Dart；
Dart 侧适配层在 `lib/format/rust_kernel_source.dart`（实现 `BookSource` 契约），
由 `BookRegistry` 分发，失败自动回落纯 Dart 实现。
