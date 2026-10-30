# rust/vendor —— 移植的 Rust 阅读内核（vendored crates）

这里的 `rrk-*` crate **逐字节移植自** `rust_reader_kernel`（Git 仓库
`https://github.com/yearhe9900/rust_reader_kernel`，本地
`D:/Workspace/personal/rust_reader_kernel`），作为 MReader 的图书解析核心：

| crate | 职责 |
| --- | --- |
| `rrk-model` | 统一书籍数据模型（`BookMeta`/`ChapterEntry`/`ChapterContent`/`TocNode`/`LinkRange`/`flatten_blocks` 唯一降维口径） |
| `rrk-format` | `FormatAdapter`/`BookSource`/`PagedSource` 契约 + 嗅探注册表 + `ContentSource` |
| `rrk-markup` | XHTML/HTML 清洗（标签白名单、锚点 `id→文本偏移`、内链区间） |
| `rrk-zip` | zip 随机读（EPUB/CBZ 共用） |
| `rrk-txt` | TXT：编码检测 + 分章 + 逻辑块切分 |
| `rrk-epub` | EPUB：OPF/NCX + 目录层级/锚点 + 清洗 + 资源管线 + 封面回退 |
| `rrk-mobi` | MOBI/AZW3：自研 PalmDOC LZ77 + HUFF/CDIC 解压 + 封面回退 |
| `rrk-cbz` | CBZ：数字自然序页索引（页级图库；页表口径与宿主基线对齐 = 上游 issue #10） |
| `rrk-image` | 图像工具（尺寸探测 / PNG 编码；上游 issue #8，供 CBZ 封面 / 页图） |
| `rrk-search` | 全书检索（拉模式分块 + 可取消）与 BM25 索引（上游 issue #9） |
| `rrk-cache` | 内容级解析结果缓存（内存 LRU + 磁盘落盘，三要素 key；上游 issue #12） |
| `rrk-pdf` | PDF：L1 文本抽取/重排 + L2 光栅 |
| `rrk-kernel` | 会话编排（句柄表 + 格式注册 + 生命周期；`BookKind` 分流重排/页级） |

**同步点**：上游 `rust_reader_kernel@46a3010`（畸形输入加固第一批：MOBI record0
短头越界 panic 改 `opt32` 缺省读取 + 封面偏移饱和、HUFF/CDIC 偏移表夹紧、解压
炸弹三道闸（单次 32MB / 词典深度 64 层 / 全书 256MB）、PDF 流解码限长（`decode_stream_limited`）+ ObjStm 负 `/N` 夹紧防挂死、MOBI 书名尾 NUL 剔除）。
前一同步点：`fa4b4cf`（issue #14：`search_chapter` 的 `done` 语义修复——真正扫完
为 true、命中被 `max_hits` 截断为 false）。再前一同步点：`d0684b2`（章级/页级缓存持久化：IndexCache
下沉 adapter + 五格式 open 索引落盘，ABI 10 不变、`ContentCacheStats` 增
`open_hits/open_misses`）。再前一同步点：`4856780`（v0.3.0，内核 ABI 10，含 issue
#13 无 TOC 书章标题回填 + 章标题块轻量出口、fuzz 五轮实锤加固（PDF 页面树/
OOM/zip 解压炸弹）、rrk-image thumbnail 转运行期解码（`image` 补 tiff feature，
与上游 workspace 白名单同源））。再前一同步点：`f88d589`（v0.1.2，ABI 8，含 issue
#8 图像 / #9 检索 / #10 CBZ 页表 / #11 稳定错误码 / #12 内容级缓存）。
上游 `rrk-ffi` / `rrk-layout` / `rrk-inspect` 三 crate 不在 vendored 集合
（宿主走 FRB 不走 C ABI；layout / inspect 无宿主消费方），随同步跳过。
随同步一并带入 `rust/fixtures/`（上游 crate 内测试用的 `sample.{txt,epub,cbz,pdf}`，
路径按 `vendor/rrk-*/../../fixtures/` 解析）。

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
