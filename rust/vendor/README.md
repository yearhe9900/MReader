# rust/vendor —— 移植的 Rust 阅读内核（vendored crates）

这里的 `rrk-*` crate **逐字节移植自** `rust_reader_kernel`（Git 仓库
`https://github.com/yearhe9900/rust_reader_kernel`，本地
`D:/Workspace/personal/rust_reader_kernel`），作为 MReader 的图书解析核心：

| crate | 职责 |
| --- | --- |
| `rrk-model` | 统一书籍数据模型（`BookMeta`/`ChapterEntry`/`ChapterContent`/`TocNode`/`LinkRange`/`flatten_blocks` 唯一降维口径） |
| `rrk-format` | `FormatAdapter`/`BookSource`/`PagedSource` 契约 + 嗅探注册表 + `ContentSource` |
| `rrk-markup` | XHTML/HTML 清洗（标签白名单、锚点 `id→文本偏移`、内链区间） |
| `rrk-zip` | zip 随机读（EPUB/CBZ 共用；只驻留中央目录、条目按需 inflate） |
| `rrk-source` | 内容源按需读取抽象：`ByteSource` trait + `FileSource` / `MemSource`，流式内容指纹 |
| `rrk-txt` | TXT：编码检测 + 分章 + 逻辑块切分 |
| `rrk-epub` | EPUB：OPF/NCX + 目录层级/锚点 + 清洗 + 资源管线 + 封面回退 |
| `rrk-mobi` | MOBI/AZW3：自研 PalmDOC LZ77 + HUFF/CDIC 解压 + 封面回退 |
| `rrk-cbz` | CBZ：数字自然序页索引（页级图库；页表口径与宿主基线对齐 = 上游 issue #10） |
| `rrk-image` | 图像工具（尺寸探测 / PNG 编码；上游 issue #8，供 CBZ 封面 / 页图） |
| `rrk-search` | 全书检索（拉模式分块 + 可取消）与 BM25 索引（上游 issue #9） |
| `rrk-cache` | 内容级解析结果缓存（内存 LRU + 磁盘落盘，三要素 key；上游 issue #12） |
| `rrk-pdf` | PDF：L1 文本抽取/重排 + L2 光栅 |
| `rrk-kernel` | 会话编排（句柄表 + 格式注册 + 生命周期；`BookKind` 分流重排/页级） |

**同步点**：上游 `rust_reader_kernel@3c61d88`（`281970a..3c61d88` 共 25 提交，
2026-11-04~11-10「独立代码深审」批次 1~5）。要点：

- **批次 5 按需读取**（新增 `rrk-source`）：`ByteSource`（`FileSource` seek+read /
  `MemSource` 零拷贝）+ `ContentSource::to_source()`；zip 只驻留中央目录、条目按需
  inflate；EPUB/CBZ/TXT/MOBI 全迁该 IO 路径，MOBI `MobiContainer` 原始字节不再整包
  驻留。大 CBZ 开书 RSS 增量实测 ≈100% → 0.72%。
- **内容指纹全量化**：`content_hash` 由「只取前 1MB / OPF 前 64KB」改为全量字节 +
  长度前缀，尾部改动必失效缓存（已落盘旧缓存自动重算一次）。
- **段落语义角色**：`Block` / `PlainBlock` / `PartBlock::Paragraph` 的
  `indent: bool` → `ParagraphRole`（7 档）；`flatten_blocks` 口径不变，缩进改由
  `ParagraphRole::indentable()` 判定。⚠️ 宿主 FRB 镜像 `RkBlock.indent` **保留**，
  映射落在 `rust/src/api/kernel.rs::plain_blocks`，Dart 契约与 FRB 生成物不变。
- **正确性与加固**：EPUB/MOBI 正文首行缩进生效（引文/列表/代码不重复缩进）；
  `Inline` / `Block` 增无通配 `variant_name`；全 workspace 取锁统一
  `rrk_model::lock_recover`；`rrk-cache` 增磁盘配额与 open 索引缓存独立开关；
  `rrk-kernel` 增 `configure_open_index_cache`。
- **内核 PDF 能力暂停、入口关闭**：`shared_registry()` 不再注册 `PdfAdapter`（crate
  代码保留），开 PDF 返回「无法识别的格式」。⚠️ 宿主 `DeveloperOptions.pdfUseRustKernel`
  实验开关随之不可用；默认 pdfrx 固版式 PDF 不受影响。恢复需回上游重新 `register`。
- **ABI 11 → 12 → 13 的出口变化全在 `rrk-ffi` / `rrk-layout` / `bindings`**（内存开书、
  缓存出口、排版参数句柄化），**不在 vendored 集合，宿主 FRB 桥面不变、无需 codegen**。

前一同步点 `281970a`（v0.4.0/ABI 11 发布批）；更早链条 `d40f59f` → `46a3010` →
`fa4b4cf` → `d0684b2` → `4856780` → `f88d589`（细节见上游 CHANGELOG / git log）。
上游 `rrk-ffi` / `rrk-layout` / `rrk-inspect` 三 crate 不在 vendored 集合
（宿主走 FRB 不走 C ABI；layout / inspect 无宿主消费方），随同步跳过。
随同步一并带入 `rust/fixtures/`（上游 crate 内测试用的 `sample.{txt,epub,cbz,pdf}`，
路径按 `vendor/rrk-*/../../fixtures/` 解析）；本次上游 fixtures 无变化。

## 纪律

1. **不在此目录做本地改造**。功能缺口回上游 `rust_reader_kernel` 提交，
   再同步进来——保持 vendored 副本可 diff、可回溯。
2. **同步方式**：整体覆盖对应 crate 目录（`src/` + `Cargo.toml`），
   同步后跑 `cargo test --workspace` 再提交；上游 crate 测试引用的顶层
   `fixtures/` 一并同步。
3. 依赖白名单同上游：纯 Rust、可审计、可 fork、许可宽松
   （`encoding_rs` / `chardetng` / `flate2`）。
4. 许可：MIT OR Apache-2.0（上游双许可），版权归上游作者。

## 与宿主的接线

内核经 `rust_lib_mreader` 的 FRB API（`rust/src/api/kernel.rs`）暴露给 Dart；
Dart 侧适配层在 `lib/format/rust_kernel_source.dart`（实现 `BookSource` 契约），
由 `BookRegistry` 分发（内核为**唯一实现**，失败翻译成 `error_messages.dart` 的中文）。

**内容级缓存已接线**（`rrk-cache`，上游 issue #12）：

- 桥：`kernel_toc` / `kernel_chapters` / `kernel_load_chapter` 内部改走 `*_cached`（未配置时行为不变）；另出 `kernel_cache_configure` / `kernel_cache_stats` / `kernel_cache_invalidate`，FRB 绑定已重新生成。
- 宿主：`main()` 启动时把目录配到 App 私有 `kernel_cache/`（内存上限 32MB）；`LibraryRepository.deleteBook` 用驻留源的内容哈希整本失效（不留删后孤儿条目）；契约用例见 `test/format/rust_kernel_source_test.dart` 的「内容级缓存」组。

**本次同步的宿主接线**：

- `rust/Cargo.toml` 的 `[workspace.dependencies]` 注册 `rrk-source`（`members = ["vendor/*"]` 自动纳入）；`rust/Cargo.lock` 补齐 format / zip / txt / mobi 四条新依赖边。
- `rust/src/api/kernel.rs::plain_blocks` 把 `ParagraphRole` 映射回 `RkBlock.indent`（`role.indentable()`）；FRB 镜像、Dart 适配层与生成物**零改动**，无需重新 codegen。
- 真内核测试前置仍是 `cargo build --release` + `RustLib.init()`；开发者 PDF 开关开启路径待上游恢复注册。
