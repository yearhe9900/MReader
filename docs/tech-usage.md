# 阅读M（MReader）· 技术使用记录

> **本文件用途**：给项目负责人看的「**这次改动用了什么技术**」速查表——扫一眼就知道某批次引入了哪些技术、写在哪、什么版本。  
> **它不是架构文档的替代品**：技术**实现细节**以 `docs/architecture-rust-integration.md` 为准；**功能契约**以 `docs/PRD.md` 为准。
>
> **维护规则**：每完成一个任务批次，在 §2 追加一节，并同步更新 §1 总览表。版本号一律取 `pubspec.lock` / 构建配置里的**实际锁定值**，不写「大概/最新」。

---

## 1. 当前技术栈总览

### 1.1 语言与框架

| 技术            | 版本                                                      | 用途                              | 引入批次                             | 落点文件                                       |
| ------------- | ------------------------------------------------------- | ------------------------------- | -------------------------------- | ------------------------------------------ |
| Dart          | 3.13.4（随 Flutter 3.47.5-stable）                         | 应用与解析全部用 Dart，无 JS/WebView      | 工程初始化；**2026-09-24 由 3.12.2 升级** | `pubspec.yaml`（`environment.sdk: ^3.13.0`） |
| Flutter       | 3.47.5-stable（**2026-09-24 升级**；原「3.44.9 已锁定不升级」随之解除）   | 纯自绘 UI（不走 WebView / foliate-js） | 工程初始化；升级缘由见 §2.37                | `pubspec.yaml`、各平台目录                       |
| Material 3    | `useMaterial3: true` + `colorSchemeSeed: Colors.indigo` | 主题三态接线（浅色 / 深色）                 | M1-T01                           | `lib/app.dart`                             |
| flutter_lints | 6.0.0                                                   | 静态检查规则集                         | 工程初始化                            | `analysis_options.yaml`、`pubspec.yaml`     |

### 1.2 状态管理

| 技术                             | 版本 | 用途                                                                                                                  | 引入批次   | 落点文件                                                              |
| ------------------------------ | -- | ------------------------------------------------------------------------------------------------------------------- | ------ | ----------------------------------------------------------------- |
| 自研监听回调（**非** `ChangeNotifier`） | 内置 | 跨页面共享设置状态：`List<void Function()>` + `addListener` / `removeListener`，页面在 `initState` 订阅、`dispose` 退订、回调内 `setState` | M1-T01 | `lib/settings/settings_store.dart`、`lib/app.dart`                 |
| 构造注入（**非**全局单例）                | 内置 | 实例在 `main()` 显式创建并注入 `MReaderApp`；`isLoaded` 作为显式初始化标志                                                              | M1-T01 | `lib/main.dart`、`lib/app.dart`、`lib/settings/settings_store.dart` |
| 无第三方状态管理库                      | —  | 不引 Provider / Riverpod / Freezed，不用 `build_runner`（见 PRD §15.5）                                                     | M1-T01 | —                                                                 |

### 1.3 持久化与存储

| 技术                                    | 版本                                               | 用途                                                                                                                                    | 引入批次   | 落点文件                                                                |
| ------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------- |
| `AtomicFile` 原子写入                     | 自研（`dart:io` + `utf8`）                           | **全工程落盘唯一入口**：写同目录临时文件 → `flush: true` → 轮转式替换                                                                                        | M1-T01 | `lib/storage/atomic_file.dart`                                      |
| **轮转式替换**（应对 Windows）                 | 自研                                               | 不假设 `rename` 能覆盖已存在目标：旧 `.bak` 先删 → `target` → `.bak` → `tmp` → `target`（两步目标位置都不存在，POSIX / Windows 行为一致），失败时从 `.bak` 还原              | M1-T01 | `lib/storage/atomic_file.dart`                                      |
| 进程内按路径串行化                             | 自研（`Map<String, Future>` + `Completer`）          | 同一文件并发写不交错；**不引锁库**；跨进程不在保证范围                                                                                                         | M1-T01 | `lib/storage/atomic_file.dart`（`_tails` / `_synchronized`）          |
| `JsonStore` 读写与四态回退                   | 自研（`jsonEncode` / `jsonDecode`）                  | ok → 返回；missing 且有 `.bak` → 回退并**自愈**；missing 无 `.bak` → `null`；corrupt → 先另存 `.corrupt`（不静默丢弃）再回退                                    | M1-T01 | `lib/storage/json_store.dart`                                       |
| `FileSecureStore` 凭据降级实现              | 自研（复用 `JsonStore`）                               | 明文 JSON 承载凭据，`isSecure = false` + 中文 `securityNotice` 供 UI 提示（对齐 `DATA-02` ③）；**不写任何 print**、异常不带凭据值                                  | M1-T01 | `lib/platform/secure_store_io.dart`                                 |
| `CoverStore` 封面字节存储                   | 自研（复用 `AtomicFile`）                              | 封面字节落 `covers/`（按 `bookId` 命名）；同目录另生成 `.thumb.png` 缩略图（`dart:ui` 仅能编码 PNG）；孤儿 GC 连带 `.tmp` / `.bak` / `.corrupt` 兄弟文件与 `.thumb.` 一并清理 | M1-T05 | `lib/meta/cover_store.dart`                                         |
| `BookIndex` / `ImportService` 书库索引与导入 | 自研（复用 `JsonStore` / `AtomicFile`；`crypto` 3.0.6） | `library/index.json` **逐条降级**（单条损坏跳过）；导入管道用 SHA-256 前 16 位内容摘要判重后复制副本                                                                 | M1-T03 | `lib/library/book_index.dart`、`lib/library/import_service.dart`     |
| `ProgressStore` 阅读进度存储                | 自研（复用 `JsonStore` / `AtomicFile`）                | **每本书记一个** `progress/<bookId>.json`（bookId 白名单防路径穿越）；bookId 直接作文件名，删书连带清理                                                             | M1-T04 | `lib/reader/progress_store.dart`、`lib/reader/reading_progress.dart` |
| 不引 `shared_preferences` / `sqflite`   | —                                                | 自研 JSON + 原子写入已够用（PRD §15.4）                                                                                                          | M1-T01 | —                                                                   |

### 1.4 平台能力

| 技术                                        | 版本                                   | 用途                                                                                         | 引入批次       | 落点文件                                          |
| ----------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------ | ---------- | --------------------------------------------- |
| `path_provider`                           | 2.1.6（`path_provider_android` 2.3.1） | 取应用私有数据目录（`getApplicationSupportDirectory()`）                                              | M1-T01     | `lib/platform/app_paths.dart`                 |
| `AppPaths` 抽象 + `PathProviderAppPaths` 实现 | 自研                                   | 业务层**只依赖接口**；路径经启动时显式注入；根目录下 `mreader` 子目录，`dataDir()` 幂等缓存                                | M1-T01     | `lib/platform/app_paths.dart`、`lib/main.dart` |
| `SecureStore` 抽象                          | 自研                                   | `read` / `write` / `delete`（幂等）/ `containsKey` + `isSecure` / `securityNotice`；系统密钥库实现留 M4 | M1-T01（接口） | `lib/platform/secure_store.dart`              |
| `path`                                    | 1.9.1                                | 包内路径拼接与 `../` 归一化（posix 语义）                                                                | 工程初始化      | `lib/epub/epub_parser.dart`                   |
| `dart:io`                                 | 内置                                   | 文件 / 目录读写；**仅限平台层与存储层**，解析链路保持可纯 Dart 单测                                                   | M1-T01     | `lib/storage/*`、`lib/platform/*`              |

### 1.5 UI / 玻璃态

| 技术                                                                  | 版本                     | 用途                                                      | 引入批次       | 落点文件                                                              |
| ------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------- | ---------- | ----------------------------------------------------------------- |
| `MaterialApp.builder` + `Material(type: MaterialType.transparency)` | 内置                     | 统一补一层透明 Material 祖先，避免玻璃组件库下文本渲染成黄色双下划线（PRD §11.4 已知限制） | M1-T01（地基） | `lib/app.dart`                                                    |
| `liquid_glass_widgets`                                              | 1.7.0（**精确锁定，不带 `^`**） | 玻璃视觉（导航层玻璃 + 浮层）；`main()` 内预热着色器                        | M1-T08     | `lib/ui/glass_kit.dart`、`lib/ui/glass_scope.dart`、`lib/main.dart` |
| `cupertino_icons`                                                   | 1.0.9                  | PRD §11.4 列为**强制依赖**：玻璃图标依赖它，从 pubspec 移除会渲染成 `?`       | M1-T08     | `pubspec.yaml`（无代码落点）                                             |
| `GlassKit` 档位出口 + `OpaqueContentSurface`（自研）                        | 内置                     | `UI-04` 内容层不透明的**唯一出口**；`premium` 禁入滚动区；固定表面不手传档位       | M1-T08     | `lib/ui/glass_kit.dart`                                           |
| `GlassScope` 作用域（自研）                                                | 内置                     | 有效亮度 / 质量档位 / 玻璃隔离范围收敛为 `InheritedWidget`               | M1-T08     | `lib/ui/glass_scope.dart`                                         |
| `GlassMaterial` 材质单一事实源（自研）                                      | 内置                     | 玻璃**材质**参数（磨砂 / 玻璃色 / 增白 / 交互物理）唯一出处，主题级 + 控件级两套 | 2026-10-12 参考图批 | `lib/ui/glass_material.dart`                                      |

### 1.6 格式解析

| 技术                                                    | 版本                     | 用途                                                                                                                     | 引入批次                                                                                                                                                                                   | 落点文件                                                                                                                                                                 |
| ----------------------------------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `archive`                                             | **4.3.0**（精确锁定，不带 `^`） | zip 解压 EPUB；测试里用 `Archive` + `ZipEncoder` 现造样本                                                                         | 工程初始化；**2026-09-24 由 3.6.1 迁移**（见 §2.24）。⚠️ **2026-09-28 更正**：原写「3.6.1（**锁 3.x**：4.x 改了 `ArchiveFile` API）」**已作废**——`pdfrx_engine` 硬要求 `archive ^4.x`，不存在「pdfrx 2.6.x + archive 3.x」组合 | `lib/epub/epub_parser.dart`、`lib/epub/zip_paths.dart`、`test/widget_test.dart`、`test/format/epub_builder.dart`                                                        |
| `xml`                                                 | 6.6.1                  | 严格解析 `container.xml` / OPF / `toc.ncx` / `encryption.xml`                                                              | 工程初始化                                                                                                                                                                                  | `lib/epub/epub_parser.dart`、`lib/epub/epub_toc.dart`、`lib/epub/xml_util.dart`                                                                                        |
| `html`                                                | 0.15.7                 | 宽松解析脏 XHTML（正文抽取 + EPUB3 `nav.xhtml`）                                                                                  | 工程初始化                                                                                                                                                                                  | `lib/epub/section_extractor.dart`、`lib/epub/epub_toc.dart`                                                                                                           |
| `charset`                                             | 2.0.1                  | GBK / GB18030 解码兜底                                                                                                     | 工程初始化                                                                                                                                                                                  | `lib/epub/text_codec.dart`                                                                                                                                           |
| `MReaderFormatException` + `kFormatErrorMessages`（自研） | 内置                     | 格式错误码 -> 面向用户中文的**唯一来源**（`RD-05`；为 `RUST-04 ②` 的口径一致铺路）                                                                | M1-T02A                                                                                                                                                                                | `lib/format/error_messages.dart`                                                                                                                                     |
| `BookSource` 统一抽象 + 分发点（自研）                           | 内置                     | §7.1 抽象（`load`/`chapters`/`content`/`capabilities`/`search`/`totalCharCount`）+ `BookRegistry`/`sniffFormat`/`openBook` | M1-T02A                                                                                                                                                                                | `lib/format/book_source.dart`（纯类型）、`lib/format/book_registry.dart`（分发点）、`lib/format/dart_epub_source.dart`、`lib/model/chapter.dart`、`lib/model/chapter_content.dart` |
| `detectEncodingName` 编码名缝（自研）                         | 内置                     | `NF-C4` / §15.6.2：把「探测编码名」与「按名解码」拆开——Rust 首版只替换探测                                                                      | M1-T02B                                                                                                                                                                                | `lib/epub/text_codec.dart`                                                                                                                                           |
| `DartTxtSource` 纯 Dart TXT 源（自研）                      | 内置                     | 照译参考实现 `TextFile.kt` 分章算法（`RD-02`）：规则择优 / 规则分章 / 10KB 分块兜底                                                             | M1-T02B                                                                                                                                                                                | `lib/format/dart_txt_source.dart`                                                                                                                                    |
| `CbzSource` / `CbrSource` 图片页压缩包源（自研）                 | 内置                     | CBZ 每图片页一章（自然序、首页图封面）；CBR 按 Q5 退化「导入即拒绝」+ `RarExtractor` 注入升级缝                                                         | M2b-T02                                                                                                                                                                                | `lib/format/cbz_source.dart`、`lib/format/cbr_source.dart`、`lib/format/image_pages.dart`、`lib/format/natural_sort.dart`、`lib/platform/rar_extractor.dart`             |
| `file_picker`                                         | 8.3.7                  | 选择本地 EPUB / TXT；`withData: true` 走 bytes，避免 `dart:io` 进入解析链路                                                           | M1-T01                                                                                                                                                                                 | `lib/main.dart`                                                                                                                                                      |

### 1.7 构建工具链

| 技术                                                 | 版本            | 用途                                                                                          | 引入批次         | 落点文件                       |
| -------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------- | ------------ | -------------------------- |
| Android Gradle KTS                                 | AGP **9.0.1** | Android 构建配置（`google()` + `mavenCentral()`）                                                 | 工程初始化        | `android/build.gradle.kts` |
| `com.android.build.api.dsl.CommonExtension`（新 DSL） | AGP 9.0.1     | 插件模块 `compileSdk` 提升用；**AGP 9 已移除 `BaseExtension`**，且新 DSL 不再带泛型参数、`compileSdk` 是可读写 `Int?` | Android 构建修复 | `android/build.gradle.kts` |
| `subprojects { afterEvaluate { … } }`              | Gradle        | 逐个子工程检查，**仅当 `compileSdk < 36`** 时提升到 36（不做无条件覆盖）                                           | Android 构建修复 | `android/build.gradle.kts` |
| Rust 工具链（`rustup` / `cargo` 1.89.0）                | 已装，**未接入构建**  | 规划中的可选加速层                                                                                   | 计划 M3.5      | PRD §15.6.5                |
| `flutter_rust_bridge` + `Cargokit`                 | 计划锁 2.13.0    | 规划中的 Rust 桥接与构建集成                                                                           | 计划 M3.5（未引入） | PRD §15.4 / §15.6.5        |

### 1.8 测试与文档工具

| 技术                                | 版本                                 | 用途                                                             | 引入批次   | 落点文件                                                         |
| --------------------------------- | ---------------------------------- | -------------------------------------------------------------- | ------ | ------------------------------------------------------------ |
| `flutter_test`                    | 内置                                 | `test` / `testWidgets` / `pumpWidget` / `addTearDown`；含首页冒烟测试  | M1-T01 | `test/storage/atomic_file_test.dart`、`test/widget_test.dart` |
| `Directory.systemTemp.createTemp` | 内置                                 | 每个用例独立的临时目录做真实 IO 断言                                           | M1-T01 | `test/storage/atomic_file_test.dart`                         |
| Python fixture 脚本                 | 系统 Python                          | 生成脏 EPUB 样本与基线比对（`make_fixtures.py` / `analyze_fixtures.py`）   | 工程初始化  | `test/fixtures/*.py`、`test/fixtures/baseline.json`           |
| 程序化点数脚本                           | 自研                                 | PRD 表头计数，正则 `[A-Z][A-Z0-9]*-\d{2}`（不用 `[A-Z]+-`，会漏整张 `P2-*` 表） | 文档批次   | `docs/PRD.md` 表头                                             |
| 确定性重放改稿 + 命中数断言                   | 自研                                 | 批量改文档时每处替换断言「命中次数 = 1」，防并行编辑互相覆盖                               | 文档批次   | 临时脚本（不入库）                                                    |
| 交付前格式自检                           | 自研                                 | UTF-8 **无 BOM** / LF 行尾 / 以换行结尾                                | 文档批次   | `docs/*.md`                                                  |
| Mermaid                           | `classDiagram` / `sequenceDiagram` | 架构图（Rust 层类图与序列图）                                              | 架构文档批次 | `docs/class-diagram.mermaid`、`docs/sequence-diagram.mermaid` |
| Keep a Changelog（简化式）             | —                                  | 根目录更新日志格式                                                      | 文档批次   | `CHANGELOG.md`                                               |

---

## 2. 按批次的技术使用记录

### 2.0 工程初始化与早期原型（历史，代码已删除）

| 项     | 值                                                                                              |
| ----- | ---------------------------------------------------------------------------------------------- |
| 任务    | 工程初始化 / 书源解析原型                                                                                 |
| 提交    | `daadf7a`（初始化）→ `a8d329b` / `a306293` / `c5fe26c` / `d694440` / `e2ebe1b` / `4ea6d10`（书源原型与修复） |
| 日期    | 2026-09-20                                                                                     |
| 一句话目标 | 建 Flutter 工程、锁定版本、跑通 EPUB 解析与阅读页                                                               |

| 技术点                   | 用途      | 落点                                 | 关键写法或坑                                                                                                                      |
| --------------------- | ------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Flutter 工程脚手架 + 五平台目录 | 项目基线    | `pubspec.yaml`、`android/`…`linux/` | `environment.sdk: ^3.13.0` 对齐 Flutter 3.47.5 内置 Dart（原 `^3.12.2` / 3.44.9，2026-09-24 升级）                                    |
| 依赖版本锁定                | 稳定性     | `pubspec.yaml` / `pubspec.lock`    | `archive` **4.3.0**（2026-09-24 由 3.x 迁移，见 §2.24；原「锁 3.x（4.x 改 API）」已作废）；`file_picker` / `xml` / `html` / `charset` / `path` |
| Dart 包结构（`lib/` 分层）   | 解析链路可单测 | `lib/epub/`、`lib/model/`、`lib/ui/` | 业务层不 import `dart:io` 目录 API                                                                                                |

> 该批的**书源原型代码已由 M0-T02 删除**（见 §2.2）；此处仅留技术谱系记录。

### 2.1 M0-T01 — Web 工程清理

| 项     | 值                         |
| ----- | ------------------------- |
| 任务    | M0-T01（PRD `Q23`）         |
| 提交    | `2635571`                 |
| 日期    | 2026-09-20                |
| 一句话目标 | 平台收敛为五平台，清除 Web 相关工程目录与措辞 |

| 技术点          | 用途        | 落点                                               | 关键写法或坑       |
| ------------ | --------- | ------------------------------------------------ | ------------ |
| 整目录删除 `web/` | 放弃 Web 平台 | `web/`（7 文件：`index.html` / 图标 / `manifest.json`） | 删目录比逐个删文件更彻底 |
| 依赖注释与平台措辞同步  | 文档一致性     | `pubspec.yaml`、`README.md`、`lib/main.dart`       | 只动注释，不改依赖集   |

### 2.2 M0-T02 — 书源原型删除

| 项     | 值                      |
| ----- | ---------------------- |
| 任务    | M0-T02（PRD `Q24`）      |
| 提交    | `236cead`              |
| 日期    | 2026-09-21             |
| 一句话目标 | 书源功能已排除出产品范围，删除原型代码与测试 |

| 技术点          | 用途          | 落点                                                                  | 关键写法或坑                                                                                                                                                                                                                          |
| ------------ | ----------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 大规模删除 + 入口收口 | 减少维护面       | 删 `lib/source/**`（11 文件）、`lib/ui/source/**`、7 个测试；改 `lib/main.dart` | 共 −7496 行；形制知识已固化到架构文档 §A.4，删代码不丢知识                                                                                                                                                                                             |
| 残留引用核查       | 确认无悬挂引用     | 全仓 `git grep`（`lib/source` / `ui/source` / `dart:html`）             | 0 命中才算闭环                                                                                                                                                                                                                        |
| 残留样本补删       | 收尾当年漏删的调研样本 | `test/fixtures/shenshi.json`                                        | 该文件是 legado 书源原文（`bookSourceName` / `ruleBookInfo` / `exploreUrl` 全套字段），由 M0 `a8d329b` 引入、`236cead` 删原型时**漏删**（当时的删除清单只列了 `lib/source/**` 与测试文件），且全仓零引用 → 本轮 `git rm` 补上；**教训**：删功能时把 `assets` / `fixtures` / 脚本一起过一遍，别只跟着源码目录走 |


### 2.3 M1-T01 — 工程骨架与平台能力抽象

| 项     | 值                                                    |
| ----- | ---------------------------------------------------- |
| 任务    | M1-T01（PRD `DATA-01` / `DATA-02` / `TYP-03` / §15.1） |
| 提交    | `8ed83f3`（存储）→ `6a63b59`（平台抽象 + 设置）→ `dbf3bfa`（应用骨架） |
| 日期    | 2026-09-21                                           |
| 一句话目标 | 立起「一切落盘走原子通道、一切平台能力经抽象注入」的地基                         |

| 技术点                                   | 用途                        | 落点                                                           | 关键写法或坑                                                                                                                              |
| ------------------------------------- | ------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `AtomicFile` 原子写入                     | 全工程落盘唯一入口                 | `lib/storage/atomic_file.dart`                               | 临时文件与目标**同目录**（避免跨设备 rename 失败）；`writeAsBytes(flush: true)` 后才替换                                                                    |
| **轮转式替换**（Windows 关键坑）                | 让替换在 POSIX / Windows 行为一致 | 同上（`_commit`）                                                | Windows 上 `File.rename` **不能覆盖已存在目标**；故先删旧 `.bak` → `target`→`.bak` → `tmp`→`target`；替换失败时从 `.bak` 还原                               |
| 进程内按路径串行化                             | 同文件并发写不产生半截文件             | 同上（`_tails` + `_synchronized`）                               | `Map<String, Future>` 链式等待 + `Completer` 放行；**不引锁库**                                                                                |
| `JsonStore` 四态回退                      | 读取失败可回退上一份有效副本            | `lib/storage/json_store.dart`                                | 损坏文件**先另存 `.corrupt`**（不静默丢弃，便于排障）再回退；回退成功后自愈目标                                                                                     |
| `path_provider` 封装为 `AppPaths`        | 业务层不直接依赖插件                | `lib/platform/app_paths.dart`                                | `abstract interface class AppPaths` + `PathProviderAppPaths`；`getApplicationSupportDirectory()` 下再建 `mreader/` 子目录，`dataDir()` 幂等缓存 |
| 平台能力**构造注入**                          | 可替换、可测试                   | `lib/main.dart`                                              | `WidgetsFlutterBinding.ensureInitialized()` → 建 `AppPaths` → 取目录 → 建设置服务 → `await load()` → `runApp`                                |
| `SecureStore` 抽象 + 明文降级               | 先定接口，系统密钥库留 M4            | `lib/platform/secure_store.dart`、`secure_store_io.dart`      | 用 `isSecure` / `securityNotice` 把「是否真安全」暴露给 UI；**不写 print、异常不带凭据值**                                                                 |
| 设置持久化与三态主题                            | `TYP-03`                  | `lib/settings/settings_store.dart`                           | **自研监听回调**（`List<void Function()>` + 订阅/退订），**不是** `ChangeNotifier`；`Settings.fromJson` 逐项回退默认值并 clamp 到 `TYP-01` 区间                |
| JSON 编解码 + `.bak` / `.corrupt` 语义     | `DATA-01` ①②              | `lib/storage/json_store.dart`                                | 「文件不存在」与「文件损坏」必须区分：前者返回 `null`，后者回退                                                                                                 |
| `MaterialApp.builder` + 透明 `Material` | 玻璃态地基（避免黄色下划线）            | `lib/app.dart`                                               | `Material(type: MaterialType.transparency)`；M1-T08 只在此之上接玻璃库，不要再动这层                                                                 |
| `flutter_test` 形态                     | 真实 IO 断言                  | `test/storage/atomic_file_test.dart`、`test/widget_test.dart` | 用例内 `Directory.systemTemp.createTemp` + `tearDown` 递归删；含「50 次并发写」与首页 `pumpWidget` 冒烟                                                |

### 2.4 Android 构建修复（AGP 9 / compileSdk）

| 项     | 值                                   |
| ----- | ----------------------------------- |
| 任务    | 构建修复（非需求条目）                         |
| 提交    | `11c5198`                           |
| 日期    | 2026-09-21                          |
| 一句话目标 | 让引入 `path_provider` 后的 Android 构建通过 |

| 技术点                                         | 用途                  | 落点                         | 关键写法或坑                                                                                                                                                                 |
| ------------------------------------------- | ------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `com.android.build.api.dsl.CommonExtension` | 读写插件模块 `compileSdk` | `android/build.gradle.kts` | **AGP 9.0.1 已移除 `BaseExtension`**；新 DSL 自 AGP 9 起不再带泛型参数，`compileSdk` 是可读写 `Int?`                                                                                      |
| `subprojects { afterEvaluate { … } }`       | 逐个子工程按需提升           | 同上                         | 只改 `:app` 无效——报错方是插件模块自己的编译目标；**仅当 `< 36` 才提升**，插件将来升到 37 不会被压回；`null` 表示用 AGP 默认值，不动                                                                                  |
| 依赖根因：`path_provider` → JNI                  | 说明为何必须 ≥ 36         | 同上注释                       | `path_provider` 2.1.6 → `path_provider_android` 2.3.1（改走 JNI）→ `jni` 1.0.3 / `jni_flutter` 1.0.3；`jni` 的 AAR metadata 要求消费者 `compileSdk ≥ 36`，而 `jni_flutter` 自身硬编码 35 |

### 2.5 文档与流程批次（PRD / 架构 / 排期）

| 项     | 值                                                             |
| ----- | ------------------------------------------------------------- |
| 任务    | 需求与设计文档（PRD v2.3 → v2.6、架构文档、`schedule.md`、`CHANGELOG.md`）    |
| 提交    | `afa499e`…`3c1c535`、`e69f0ff`、`be6f73e`、`ea8ea73`、`9194a89` 等 |
| 日期    | 2026-09-20 ~ 2026-09-21                                       |
| 一句话目标 | 用可复核的方式维护需求、架构与排期的一致性                                         |

| 技术点                   | 用途          | 落点                                                           | 关键写法或坑                                                       |
| --------------------- | ----------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| 程序化点数                 | 表头计数必须来自脚本  | `docs/PRD.md` 表头                                             | 正则用 `[A-Z][A-Z0-9]*-\d{2}`；用 `[A-Z]+-\d{2}` 会静默漏掉整张 `P2-*` 表 |
| 确定性重放改稿 + 命中数断言       | 一次改几十处不互相覆盖 | 临时脚本                                                         | 每处替换断言「命中次数 = 1」，串行重放；不用并行编辑                                 |
| 格式自检                  | 交付前统一格式     | `docs/*.md`                                                  | UTF-8 无 BOM、LF 行尾、以换行结尾                                      |
| 编号空位不重编               | 保护跨章节引用     | `docs/PRD.md` §6                                             | 删除条目保留编号空位（如 `P2-04` / `CNT-07`）                             |
| Mermaid 图             | 架构可视化       | `docs/class-diagram.mermaid`、`docs/sequence-diagram.mermaid` | `quadrantChart`（竞品）/ `classDiagram` / `sequenceDiagram`      |
| 推翻定案必须留证              | 防止团队原地反复    | `docs/PRD.md` §15.6.4、附录 `B.8`                               | 记录「被推翻的判据 + 未被推翻的部分 + 决定性前提是否失效」                             |
| Keep a Changelog（简化式） | 每日更新速查      | `CHANGELOG.md`                                               | 倒序分节、四类小标题、每条 ≤ 40 字并附 commit                                |

### 2.6 M1-T02A — 格式统一抽象 + EPUB 源（含目录 / 加密拒绝 / RD-05 文案）

| 项     | 值                                                      |
| ----- | ------------------------------------------------------ |
| 任务    | M1-T02A（PRD `RD-01` / `RD-05` / §7.1 / §7.3；架构文档 §A.1） |
| 提交    | `c9827fe`（实现）→ `38fcb2f`（测试）                           |
| 日期    | 2026-09-21                                             |
| 一句话目标 | 立起「格式解析统一抽象 + EPUB 纯 Dart 实现」的接口冻结点，T02B 的 TXT 源可平行接入  |

| 技术点                                               | 用途                                                                  | 落点                                                                            | 关键写法或坑                                                                                                                                                                                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `archive` 3.6.1 解 zip（复用，未改行为）                    | EPUB 解包；工具函数提到独立文件供目录解析复用                                           | `lib/epub/zip_paths.dart`                                                     | **3.x 的 `ArchiveFile.content` 是 `dynamic`**（可能是 `Uint8List` 或 `List<int>`），必须双类型判断；`tryDecodeZip` 把异常收敛成 `null` 再转中文错误                                                                                                            |
| `xml` 6.6.1 严格解析                                  | `container.xml` / OPF / `toc.ncx` / `encryption.xml`                | `lib/epub/epub_parser.dart`、`lib/epub/epub_toc.dart`、`lib/epub/xml_util.dart` | `toc.ncx` 必须走严格 XML；**层级只能按 `childElements` 逐层递归累加**——`findAllByLocalName` 是扁平收集，**拿不到真实嵌套深度**                                                                                                                                    |
| `html` 0.15.7 宽松解析                                | 正文抽取（已有）+ EPUB3 `nav.xhtml`                                         | `lib/epub/section_extractor.dart`、`lib/epub/epub_toc.dart`                    | nav 优先用 `html`（EPUB3 nav 常是脏 XHTML），取不到 `<nav>` 再回落 `xml`；`dom.Element.attributes` 是 `Map<Object, String>`（键可能是 `epub:type`）；`dom.Node` **没有** `nextNode`，取后续兄弟要用 `parent.nodes` + `indexOf`                                      |
| 目录双路径（`RD-01`）                                    | nav（`properties` 含 `nav`）/ ncx（`application/x-dtbncx+xml` 或 `.ncx`） | `lib/epub/epub_toc.dart`                                                      | **nav 里的 href 相对 nav 文件自身，不是相对 OPF 目录**（最容易错的一点）；纯 fragment 链接（`<a href="#c1">`）指向**目录文件自身**，href 取 `basename(navPath)`；html 与 xml 两条路径的锚点查找语义必须一致——**都不下钻嵌套 `<ol>` / 嵌套 `navPoint`**（否则父级会凭空多一条错层条目）；两条路径皆空 -> 返回空列表，由调用方降级为平坦目录 |
| 目录项类型 = `Chapter`（合并，不再另立）                        | 避免「目录条目」与「章节」两份同构类型导致的字段搬运                                          | `lib/model/chapter.dart`、`lib/epub/epub_toc.dart`                             | `parseToc` 直接返回 `List<Chapter>`；依赖方向 `lib/epub -> lib/model`；`lib/model/chapter.dart` 是**不 import 任何东西的叶子**，全项目唯一章节类型                                                                                                             |
| 加密检测（`RD-05`）                                     | 读 `META-INF/encryption.xml` 决定是否拒开                                  | `lib/epub/epub_parser.dart`                                                   | 三态判定：① 不存在 -> 不加密；② 算法属**字体混淆**（IDPF embedding / Adobe `enc#RC`）-> 不算加密；③ 目标**是字体**（扩展名或 manifest media-type 为字体）-> 不算加密；其余才拒开。**反例用例防误杀**；检测必须在返回可读章节**之前**                                                                      |
| `MReaderFormatException` + `kFormatErrorMessages` | 错误码 -> 中文的**唯一来源**（`RUST-04 ②` 口径一致的前提）                             | `lib/format/error_messages.dart`                                              | 文案表由 `test/format/error_messages_test.dart` 兜底（枚举全覆盖、中文、不重复口径）；`detail` 只进 `toString`，**不进面向用户的 message**                                                                                                                         |
| `EpubParseException` 退休但不删除                       | 兼容既有引用                                                              | `lib/epub/epub_parser.dart`                                                   | 降级为 `@Deprecated` 的**子类**（`extends MReaderFormatException`），既有断言只需改类型名，**不必大改 fixture 与 baseline**                                                                                                                                |
| 纯字节入口 + 惰性解析                                      | `PERF-01`（解析移出主 isolate）的形状                                         | `lib/format/dart_epub_source.dart`                                            | 构造**不解析**；`parseEpub` 的 `Future` 缓存一次（避免重复解析）；`lib/format/**` 与 `lib/epub/**` 零 `dart:io`、零 Flutter                                                                                                                               |
| `totalCharCount()` 显式增补                           | `STAT-14` 要「全书字符总数」                                                 | `lib/format/book_source.dart`                                                 | 用**带默认实现**的具体方法补入（`async => null`），**不改 §A.1 既有字段/签名**；实现里懒计算 + 缓存，**不在 `load()` 里算**（20MB 书会拖慢打开）                                                                                                                                |
| 朴素子串搜索 + 进度/取消                                    | `CNT-06` 的纯 Dart 基线（Rust 阈值被测对象）                                    | `lib/format/dart_epub_source.dart`                                            | **不建索引**（索引是 M2b 的事）；命中给「章索引 + 章内字符偏移 + 命中段」；每章末回报 `0.0~1.0` 进度；`cancel.isCancelled` 即停                                                                                                                                           |
| fragment 定位（`Chapter.locate`）                     | nav href 带 `#id` 时只显示该锚点起的内容                                        | `lib/epub/section_extractor.dart`                                             | best-effort：按 `id`/`name` 找锚点，再按**文档序**（锚点子树 + 逐层后续兄弟）续取；**锚点丢失退回整章**，绝不报错/变空；段落边界按节点逐个 flush（否则相邻 `<p>` 会被并成一段）                                                                                                                  |
| 测试脚手架：Dart 现场拼 zip                                | 目录层级 / 加密标记 / 锚点这类**结构**样本                                          | `test/format/epub_builder.dart`                                               | 与 `make_fixtures.py` 分工：Python 管「脏字节」基线契约（**不动 `baseline.json`**），Dart 管「结构」样本，断言可写在同一处                                                                                                                                           |
| **先探针、后断言**                                       | 防「想当然的期望值」                                                          | `.scratch/probe_*.dart`（用完即删）                                                 | 用 `dart run` 实测 TOC 层级 / fragment / 加密三态 / 9 个 fixture 对齐，全绿后才把实测值写进断言                                                                                                                                                            |
| 契约测试骨架                                            | 让新增实现自动被同一组断言覆盖                                                     | `test/format/book_source_contract_test.dart`                                  | `registeredSources()` 是唯一注册点；**M1-T02B 追加 `dart-txt` 一行即可**（`RD-01` 的「实现互不感知」靠它守住）                                                                                                                                                |

### 2.7 M1-T02B — TXT 源 + 编码名缝 + 应用接线

| 项     | 值                                                            |
| ----- | ------------------------------------------------------------ |
| 任务    | M1-T02B（PRD `RD-02` / `NF-C4` / §7.1 / §15.6.2；架构文档 §A.1）    |
| 提交    | `f39deb1`（编码名缝）→ `bd2466d`（TXT 源 + 注册）→ `0da0c5b`（应用接线 + 测试） |
| 日期    | 2026-09-21                                                   |
| 一句话目标 | 接通 TXT 作为第二种格式，并把「编码探测」抽成 Rust 后续可替换的缝                       |

| 技术点                                       | 用途                                         | 落点                                                                   | 关键写法或坑                                                                                                                                                                                                                                                                        |    |                                                        |
| ----------------------------------------- | ------------------------------------------ | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -- | ------------------------------------------------------ |
| `detectEncodingName` 编码名缝                 | `NF-C4` / §15.6.2：Rust 首版只「探测编码名」，解码留 Dart | `lib/epub/text_codec.dart`                                           | 把 `decodeText` 拆成「探测 + 按名解码」两步；探测返回 `utf-8` / `utf-16le` / `utf-16be` / `gbk` / `latin1`（**全小写**）。重写后对外行为必须**逐字节不变**——用 9 个 fixture 基线（`合格 9 / 失败 0`）兜底回归                                                                                                                     |    |                                                        |
| 判定优先级（BOM → 声明 → 严格 UTF-8 → GBK → latin1） | 同一套口径同时服务探测与解码                             | 同上                                                                   | BOM 定双字节序；`<?xml … encoding>` / 头部声明经「判据投影」再回落；严格 UTF-8 通过即判 `utf-8`；否则 GBK 可解则 `gbk`，兜底 `latin1`。BOM 的**剥离**放在解码侧，探测侧只看标记                                                                                                                                                    |    |                                                        |
| 分章算法**照译**参考实现 `TextFile.kt`              | `RD-02`：TXT 自动分章                           | `lib/format/dart_txt_source.dart`                                    | 规则择优 `getTocRule()`（`:497-535`）、规则分章 `analyze(rr)`（`:159-389`）、无规则分块 `analyze(fileStart,fileEnd)`（`:394-492`）、内置 `txtTocRule.json` 中 `enable==true` 的 12 条                                                                                                                    |    |                                                        |
| 择优三变量 `csNum` / `numE` / `maxNum`         | 卷标题误判过滤（`RD-02` 的要害）                       | 同上（`_pickRule` 上方注释）                                                 | **按源码而非 PRD 转述**：`csNum`=**命中章节数**（首个匹配，或与前次接纳匹配**间距 >1000 字**者）；`numE`=**疑似卷（误判）数**（两次匹配**间距 <100 字**的次数）；`maxNum`=**当前最优规则的 `csNum`**（跨规则比较基准，初值 −1）。接纳条件 `csNum >= numE*3` **且** `csNum > maxNum+2`；选中最优后 `maxNum > 70` 提前终止                                               |    |                                                        |
| 规则择优**只在首个 512KB 块**上跑                    | 忠实照译 **且** 性能                              | 同上（`_analyze`）                                                       | 参考实现只把首个 `bufferSize=512000` 字节交给 `getTocRule()`。若对整本跑 12 条带 lookbehind 的规则，20MB 无标记文本会从「分钟级/挂死」降到**百毫秒级**（实测 20MB 无标记 ≈ 328ms、有章节 ≈ 162ms）                                                                                                                                   |    |                                                        |
| **canonical 分章口径（本项目定义，Rust 移植以此为准）**     | `RUST-02` L4 命中集合比对的基准                     | `lib/format/dart_txt_source.dart`                                    | 本项目把三档阈值定义为**字符**：无规则分块 10KB 字符 / 规则单章上限 100KB 字符 / 择优取样首 512K 字符；`Chapter.href` 亦为**字符偏移**（`txt:<起始字符偏移>`）。参考实现用的是**字节**（`toByteArray(charset)` + `curOffset`）——**Rust 实现不得照抄字节口径**，否则分章边界与命中集合对不上、等价门永远过不了。中文书 100KB 字符 ≈ 2.2–3.3 万字，与参考实现触发点本就不同，属**预期内的口径差异**、非偏差         |    |                                                        |
| 已知局限：短章/语录体书的目录不可用                        | 1:1 照译参考实现的**固有行为，非 bug**                  | 同上（`_pickRule` 的 `>1000 字` 门槛）                                       | 算法要求「相邻两次规则命中间距 **>1000 字**」才计为正式章节；**标题间正文 ≤1000 字的书（短章 / 诗话 / 语录体）会整体回落到无规则分块，目录不可用**。故 `RD-02` ① 的验收样本应为**正常章长**（相邻标题间正文 >1000 字），否则会误判为「没分章」                                                                                                                              |    |                                                        |
| dispose 契约（两源一致）                          | `RUST-01`：上层无感，释放后不崩                       | `lib/format/dart_txt_source.dart`、`lib/format/dart_epub_source.dart` | `dispose()` 之后、以及调用与 dispose **竞态**时，所有公开方法**返回优雅空结果、绝不抛**（`load` → 最小 meta title `未命名`；`chapters`/`content` → 空；`search` → 流立即结束；`totalCharCount` → `null`）。实现要点：**每个 `await` 恢复后重查 `_disposed`**，不依赖 `!` 断言——否则「正文还在加载时退出阅读页」会踩空 `_text!`（实测崩溃点 `dart_txt_source.dart:132`） |    |                                                        |
| 无规则 10KB 分块 + 超长章二次拆分                     | `RD-02` ②：无标记也能读                           | 同上（`_splitByLength` / `_splitByRule`）                                | 无规则：每块 ≤10KB、尽量在换行处断，块名 `第N章(M)`（N=字符块序号）；收尾残块 ≤100 字并入上一章。单章正文 >100KB → 二次拆分，子章名 `章名(N)`；原章**不留空壳**（本项目 `Chapter` 无 `isVolume` 字段）                                                                                                                                           |    |                                                        |
| `content(i)` 段落口径                         | 与 EPUB 侧 `extractSection` 对齐               | 同上（`content` / `_splitParagraphs`）                                   | 按 \`\r\n                                                                                                                                                                                                                                                                      | \r | \n`切段、逐行剥行首 BOM +`trim\`、丢空行；首段与章名重复时**剥掉**（UI 单独渲染标题） |
| 纯 Dart（零 Flutter / 零 `dart:io`）           | `PERF-01`：解析可丢进 `compute()`                | `lib/format/dart_txt_source.dart`                                    | 只吃 `Uint8List`；全文**只解码一次**并缓存，分章边界用**字符区间**表示，`content(i)` 用 `substring` 取——峰值量级 ≈ 输入文件的 2 倍（内存收敛交给 M1-T07）                                                                                                                                                                   |    |                                                        |
| UI 只依赖 `BookSource` 抽象                    | `RD-01`：实现互不感知                             | `lib/main.dart`、`lib/ui/reader_page.dart`                            | 首页 `allowedExtensions` 改 `[epub, txt]`；`parseEpub` → `openBook`（分发点），并**主动 `await source.load()`** 把格式错误暴露在首页（结果被缓存，阅读页不重复解析）。阅读页改吃 `BookSource`：异步 `chapters()` + `content(i)` 用**同一 Future 按索引去重缓存** + `FutureBuilder` 逐章渲染；诊断行改为格式无关的「`N 章 · <implId>`」                    |    |                                                        |
| 先探针、后断言                                   | 防「想当然的期望值」                                 | `.scratch/probe_verify.dart` 等（用完即删）                                 | 探针**逐条复现** `dart_txt_source_test.dart` 的 48 条断言（GBK 解码 / 卷过滤 / `txt:5` / `txt:1529` / `txt:10247` / 16 章 / 590 章 / 138 命中…），全绿后才定稿；探针当场揪出 1 个真 bug（`.txt` 兜底书名未回落「未命名」）                                                                                                       |    |                                                        |
| 契约自动覆盖                                    | 新实现自动被同一组断言覆盖                              | `test/format/book_source_contract_test.dart`                         | `registeredSources()` 追加一条 `dart-txt` 样本（含 `正文` 供 `searchable` 断言），并补 `openBook` 的 txt 分发用例                                                                                                                                                                                   |    |                                                        |


### 2.8 M1-T08 — 玻璃态基础设施与内容层不透明红线

| 项     | 值                                                      |
| ----- | ------------------------------------------------------ |
| 任务    | M1-T08（PRD `UI-01` / `UI-04` / §11.1 / §11.3 / §11.4）  |
| 提交    | `348ce23`（依赖接入）→ `08c2b65`（主题 + 玻璃基建）→ `46810eb`（单测）   |
| 日期    | 2026-09-21                                             |
| 一句话目标 | 把玻璃态的地基与红线一次接好：档位与「内容层不透明」各留**唯一出口**，业务页面留到 M1-T03/M2a |

| 技术点                                                | 用途                                                                                                                | 落点                                                                                       | 关键写法或坑                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **精确锁定** `liquid_glass_widgets: 1.7.0`（**不带 `^`**） | PRD §11.4 的「已知限制与应对」**原针对 1.6.2 逐条实测**；**2026-09-21 由负责人决定升 1.7.0**（`c996106`）→ 关键断言已在 1.7.0 上复核（见下三行，2026-09-28） | `pubspec.yaml`                                                                           | 锁定纪律 = 精确版本、不带 `^`。`pubspec.lock` 解析值 = `1.7.0`（`sha256:547fe867…`，源 `pub.flutter-io.cn`）。库自身约束 `flutter >= 3.41.0` / `sdk >=3.5.0 <4.0.0`（本机 3.47.5 满足），且**零 `flutter/material.dart` 依赖**、**未引入任何额外传递包**                                                                                                                                                                                                                                |
| `cupertino_icons` 必须保留                             | PRD §11.4 列为**强制依赖**                                                                                              | `pubspec.yaml`                                                                           | 从 pubspec 删掉会让玻璃图标渲染成 `?`（库内部用具名图标）                                                                                                                                                                                                                                                                                                                                                                                                      |
| 有效亮度跟随**应用 ThemeMode**（`UI-01` ②）                  | 否则「应用切深色、系统仍浅色」时玻璃亮度错位                                                                                            | `lib/theme/app_theme.dart`（纯函数 `resolveBrightness`）、`lib/main.dart`                      | 三态：`light`/`dark` 恒取自身，`system` 取平台亮度。接线方式是 `LiquidGlassWidgets.wrap(brightnessResolver: Theme.maybeBrightnessOf)`，**包裹位置在 `MReaderApp` 之外**——`lib/app.dart` 里 `MaterialApp.builder` 那层透明 `Material` 一字未动                                                                                                                                                                                                                                |
| 档位唯一出口 `GlassKit`（`UI-05` 预留）                      | P0 固定 `standard`，**不引入 `premium`**                                                                                | `lib/ui/glass_kit.dart`                                                                  | `kAppGlassQuality = standard`；固定表面的覆盖值 `fixedSurfaceQualityOverride` **恒为 `null`**（传 `null` 即「不覆盖」）。浮层（`GlassDialog.show` / `GlassSheet.show`）显式传 `standard`                                                                                                                                                                                                                                                                             |
| 「固定表面自动升 premium」是**库的行为**，不是我们的                   | 佐证「本项目从不手传 `premium`」                                                                                             | 复核来源：**1.7.0** `lib/widgets/surfaces/glass_scaffold.dart:559 / :584`                     | `GlassScaffold` 对 `appBar` / `bottomBar` 传 `defaultQuality: GlassQuality.premium`，经 `GlassIsolationScope` 下发为子控件的档位提示。**手写 `premium` 会绕过该隔离策略**。**1.7.0 复核（2026-09-28）：行号 559 / 584 与 1.6.2 逐字一致**                                                                                                                                                                                                                                       |
| `OpaqueContentSurface`＝「不透明」唯一出口（`UI-04`）          | 内容层各页统一走它，避免各页自己写 `Container(color:)` 各自失守                                                                        | 同上                                                                                       | 底色经 `fullyOpaque()` 强制 `alpha = 1`；内部用 `Material` 同时补上「玻璃库没有 Material 祖先」的坑；**debug 下 `assert` 拒绝玻璃子控件**（玻璃不可嵌套）                                                                                                                                                                                                                                                                                                                         |
| `isGlassWidget()` 红线可判定化                           | 把「不得嵌套玻璃」从文档约定变成可断言的形式                                                                                            | 同上                                                                                       | 判定表覆盖 **35 个** `Glass*` 表面类型（容器 / 交互 / 输入 / 导航 / 浮层）＝ `lib/ui/glass_kit.dart` 中 `isGlassWidget` 的 `widget is Glass*` 分支数（`sed -n '71,105p' lib/ui/glass_kit.dart`）。**已逐类型核对存在于 1.7.0，零缺失**（2026-09-28）。⚠️ **勘误**：原文写「37 个」**不可复现**——该判定表在 `08c2b65` / `9519c5f` / `5b96ca6` 三个提交上**始终为 35**；而库 `lib/widgets` 下 `class Glass*`（含 `*Scope` / `*Controller` / `*Painter` 等非表面类）实为 **90**（1.6.2 与 1.7.0 完全相同）。「37」与两者均不符，属**原文计数错误**，与版本升级无关 |
| `GlassScope`（`InheritedWidget`）                    | 有效亮度 / 档位 / 玻璃隔离范围收敛一处，下游不必各自猜                                                                                    | `lib/ui/glass_scope.dart`                                                                | `brightnessOf` 三级回退：本作用域 → `GlassTheme.brightnessOf`（库级联）→ …；`qualityOf` → `GlassAdaptiveScopeData.maybeOf(...)?.effectiveQuality` → `kAppGlassQuality`。**本批只备好，尚未接入业务页**（`GlassScopeProvider` 当前无调用方，属预期）                                                                                                                                                                                                                               |
| 着色器预热 + 诚实降级（`UI-01` ①）                            | 避免首帧白闪                                                                                                            | `lib/main.dart`（`_warmUpGlassShaders`）                                                   | `await LiquidGlassWidgets.initialize()` 包在 `try/catch` 里：**失败只 `debugPrint`、不抛、不阻塞**。⚠️ **待优化**：当前是在 `settings.load()` **之前**串行 `await`，会给冷启动叠加一段着色器预编译时间（`v2.3` 冷启动是硬指标）——可改为与 `appPaths.dataDir()` / `settings.load()` 并行（`Future.wait`）                                                                                                                                                                                               |
| Windows / Linux 被库**静态封顶 `standard`**              | 佐证 `NF-C8`「不得宣称五平台等价」与排期「不在本机 Windows 上反复调视觉」（`Q3` / `R8`）                                                        | 复核来源：**1.7.0** `lib/liquid_glass_setup.dart` 的 `_shouldSkipPremiumPreload()`（`:148-153`） | 对 `kIsWeb` / `windows` / `linux` 返回 `true` → `initialize()` 跳过 premium 多趟着色器预载，`GlassAdaptiveScope` 把这些平台上限压到 `standard`。**本机（Windows）看到的观感与 Android 不一致是库的既定行为，不是配置错误**。**1.7.0 复核（2026-09-28）：`:148-153` 判定式与 1.6.2 `:148` 逐行一致**                                                                                                                                                                                                      |
| 红线自检形式（测试）                                         | 防「地基被误删 / 档位被偷改」                                                                                                  | `test/ui/glass_kit_test.dart`                                                            | 断言：档位恒 `standard`、固定表面覆盖值恒 `null`、`OpaqueContentSurface` 底色 `alpha == 1`、内容层嵌套玻璃触发 `AssertionError`                                                                                                                                                                                                                                                                                                                                      |
| 纯逻辑先于依赖可测                                          | 主题三态解析不依赖玻璃库，`pub get` 前即可跑                                                                                       | `test/ui/app_theme_test.dart`                                                            | `lib/theme/app_theme.dart` **不 import 任何玻璃库**；`Settings.defaultFontSize`(18) / `defaultLineHeight`(1.6) 以具名常量转出，供 M1-T05（合成封面取主题色）与 M1-T06（排版）复用                                                                                                                                                                                                                                                                                         |
| 黄色下划线回归护栏                                          | `UI-04` / PRD §11.4 防护                                                                                            | `test/ui/app_material_layer_test.dart`                                                   | 断言 `app.dart` 那层 `Material(type: MaterialType.transparency)` 仍在，且首屏 `DefaultTextStyle` 不命中 `WidgetsApp` 的 fallback（黄底双下划线）                                                                                                                                                                                                                                                                                                               |

### 2.9 M1-T05 — 元数据模型与封面链路

| 项     | 值                                                                                                                                                                                            |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 任务    | M1-T05（PRD `META-01~07`；架构 §N 接口冻结）                                                                                                                                                          |
| 提交    | `c8d06ca`（模型层 + 兼容桥）→ `f168d1d`（纯 Dart 提取）→ `e0d9a4c`（封面落盘 + 合成封面）→ `8e11ae0`（本节 + CHANGELOG）→ `a153313`（占位 meta 作者回落「未知作者」+ 补不变式断言）→ `d645fea`（合成封面 LRU 有界化 + 并发去重）→ `35ed10f`（本节「缓存上限分工」行） |
| 日期    | 2026-09-21                                                                                                                                                                                   |
| 一句话目标 | 把元数据模型与封面链路一次接好：纯 Dart 半边（嗅探/优先级链/文件名规则）可进 `compute()`，Flutter 半边（落盘/缩略图/合成）负责像素与文件                                                                                                          |

| 技术点                                   | 用途                                                  | 落点                                                                                                  | 关键写法或坑                                                                                                                                                                                                   |
| ------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BookMeta 唯一归属（`META-01`）              | 防「结构相同的两份类型 → 字段搬运」复制陷阱（同 `f22891b` 的 `Chapter` 教训） | `lib/model/book_meta.dart`（定义）；`lib/format/book_source.dart`、`lib/meta/book_meta.dart`（只 re-export） | 三处路径指向同一份，**物理上不可能出现第二份**；模型是**叶子**（仅 `dart:typed_data`）                                                                                                                                                 |
| `MetaOrigin` 闭合四值（§N.2）               | 让「来源标记相等」的可判定性与 `META-08`「置 user 不被覆盖」成立            | 同上                                                                                                  | 细粒度串（OPF/EXTH）**不进契约**；`lib/` 下 grep `coverBytes` / `opf:dc` / `exth:100` = 0                                                                                                                            |
| `sealed class CoverRef` 四态（§N.5）      | `META-06 ④`「禁魔法字符串」落到类型层                            | 同上                                                                                                  | `PendingCover`（解析期原始字节）→ `CoverStore.materialize` → `StoredCover`；`book_source.dart` 不再就地定义 BookMeta                                                                                                     |
| `OpfView` 与 `EpubBook` 同一次解压（§N.4 D1） | `META-02/03` 需 OPF 视图，但**不得重复解压**                   | `lib/epub/epub_parser.dart`                                                                         | `parseEpubResult` 返回 `{book, opfView}`；`readEntry` 只保留**候选相关少量条目字节**（≤4 图），不钉住整本解压结果                                                                                                                     |
| 封面四来源**有序**优先级 + 命中即停（`META-02`）      | 结果不依赖遍历顺序，重复解析稳定                                    | `_buildCoverCandidates`（有序 List + 去重 Set）；`lib/meta/epub_meta.dart`                                 | ①`<meta name=cover content>` ②`properties="cover-image"` ③guide`reference type=cover` ④文件名含 cover 的图片项；嗅探非图片（如 guide 指向 XHTML）→ 跳过                                                                       |
| 多作者稳定顺序整体保留（`META-03`/`Q17`）          | 中文书 `dc:creator` 常是整合串，切分会制造错误                      | `lib/meta/epub_meta.dart`                                                                           | 多个 `dc:creator` 用 `；` 连接（不切分）；缺失 → 文件名规则链 → 「未知作者」                                                                                                                                                       |
| 文件名规则链（`META-04`）                     | TXT 唯一的元数据来源                                        | `lib/meta/txt_meta.dart`                                                                            | 命中即停：`《书名》…作者：X` → `《书名》` → `作者：X` → `by X` → 清洗兜底；**精确化兜底不比较长度**（等长用例不被误丢弃）                                                                                                                             |
| 魔数嗅探（`META-05` 上半截）                   | 「嗅探（纯 Dart、可进 isolate）」与「解码（`dart:ui`）」拆开           | `lib/meta/meta_source.dart`                                                                         | 只看前几字节：JPEG `FF D8 FF`／PNG 8 字节签名／WebP `RIFF`????`WEBP`／GIF `GIF8`／BMP `BM`；否则 `unknown`                                                                                                                 |
| 像素上限降采样 + 缩略图（`META-05`/`NF-M5`）      | 防「导入大封面 → 逐本解码原图 → 内存尖峰」                            | `lib/meta/cover_store.dart`                                                                         | `kCoverDecodeMaxPixels`=4,194,304；`kCoverThumbMaxEdge`=320；`ImmutableBuffer → ImageDescriptor.encoded → 等比缩 → instantiateCodec`；书架只解缩略图                                                                  |
| 真实格式落盘、不重编码（`META-05`）                | 透明通道不丢、后缀与内容一致                                      | 同上                                                                                                  | 原图扩展名由 `CoverFormat` 推（**不看原扩展名**）；⚠️ **缩略图例外用 `png`**：`dart:ui` 只能编码 PNG，用源扩展名会「后缀与内容不符」                                                                                                                |
| 孤儿 GC 的安全规则（`META-06 ③`/§N.7）         | 只删「不被任何书籍引用」的孤儿                                     | 同上                                                                                                  | 只扫 `covers/`；**`.tmp`/`.bak`/`.corrupt` 兄弟与 `.thumb.` 缩略图随其基封面处置**（team-lead 补充，防误删唯一可回退的 `.bak`）；幂等；`covers/` 之外永不触碰                                                                                    |
| 合成封面（`META-07`）                       | 无封面时的运行时降级                                          | `lib/meta/synth_cover.dart` + `lib/theme/app_theme.dart`                                            | `cacheKey = FNV-1a(书名+作者+主题)`（确定性）；命中即复用不重绘；主题经 `app_theme` 的 `CoverTheme`/`coverThemeOf`（主题口径唯一出处）；缓存 **LRU 有界**（`kSynthCoverCacheMaxEntries`=32，逐出即 `ui.Image.dispose()`）+ 并发同 key in-flight 去重（只保一张图） |
| 缓存上限的**分工**（`META-05` ④）              | 说清「谁解码、谁缓存、上限谁兜」，不靠人猜                               | `lib/meta/cover_store.dart`（只返字节）/ Flutter 内置 `ImageCache` / `lib/meta/synth_cover.dart`（自建 LRU）    | **真实封面**：`CoverStore` 只返**字节**、**不做解码缓存**；UI 走 `Image.memory`，解码去重与上限由 Flutter 内置 `ImageCache`（默认 100 MB / 1000 条）承担——这正是 `META-05` ④「书架滚 20 本不重复解码同一封面」的落点。**合成封面无宿主缓存可依附**，是全工程唯一自建位图缓存，故**必须自带上限**    |
| 封面引用序列化唯一出口（`META-06 ⑤`）              | 全工程搜不到 `'file'`/`'synthetic'`/`'none'`              | `lib/meta/cover_ref_codec.dart`                                                                     | 唯一出现魔法串处，由 round-trip 测试锁死；`PendingCover` 序列化**直接抛 `StateError`**（持久化不变式）                                                                                                                                |
| 先探针后断言                                | 期望值不凭记忆                                             | `.scratch/probe_meta.dart`（已删）                                                                      | 实测四来源各一例 / 优先级命中即停 / 非图片候选跳过 / 多作者 / 文件名兜底 / 魔数；再把实测值写进 `test/meta/*`                                                                                                                                    |

### 2.10 M1-T03 — 书库索引 / 导入 / 判重 / 删除连带清理

| 项     | 值                                                                              |
| ----- | ------------------------------------------------------------------------------ |
| 任务    | M1-T03（PRD `LIB-01~06`；架构 §N）                                                  |
| 提交    | `5bd1d8b`（数据层）→ `f797913`（导入 + 仓库）→ `60c5171`（书架 UI）→ `7b58134` `023ca78`（进度表） |
| 日期    | 2026-09-21                                                                     |
| 一句话目标 | 立起「内容摘要判重 + 索引逐条降级 + 删除连带清理」的书库后端，书架 UI 只依赖 `LibraryRepository`                |

| 技术点                                  | 用途                    | 落点                                                                                                                 | 关键写法或坑                                                                                                                                                                                      |
| ------------------------------------ | --------------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 内容摘要 = SHA-256 hex 前 16 位（`LIB-05`）  | 判重键（相同字节 → 相同 bookId） | `lib/library/import_service.dart`                                                                                  | `crypto` 3.0.6（**精确锁定**）；`sha256.convert(bytes).toString().substring(0, 16)`；该 `bookId` 同时是「副本文件名 / `index.json` 主键 / 进度文件名」三处唯一身份                                                          |
| `BookIndex` **逐条降级**（`LIB-03`）       | 单条损坏不崩全库              | `lib/library/book_index.dart`                                                                                      | `load()` 对 JSON 数组逐条 `try-catch` + `item is Map<String,Object?>` 判定，坏条目**跳过**；底层仍走 `JsonStore` 四态回退；索引文件 `library/index.json`                                                               |
| `BookRecord` 纯 Dart 记录（`LIB-02`）     | 索引最小可持久化单元            | `lib/library/book_record.dart`                                                                                     | 封面经 `encodeCoverRef` / `decodeCoverRef`（`META-06 ⑤` 唯一出口）；JSON **不含 `PendingCover`**（持久化不变式）；`==` 只比 `bookId`（不按文件名判同书）                                                                     |
| 导入管道（`LIB-02` / `LIB-05`）            | 一个文件 → 一条记录           | `lib/library/import_service.dart`                                                                                  | 顺序：嗅探格式 → `openBook().load()`（`finally` 保证 dispose）→ 摘要 → 原子写副本 `library/<bookId>.<ext>` → 封面物化（`PendingCover`→`StoredCover`）→ 构造记录；**不写索引**（交仓库），保证「转换」与「入库」职责分离                           |
| 仓库胶水（`LIB-01` / `LIB-05` / `LIB-06`） | UI 唯一后端               | `lib/library/library_repository.dart`                                                                              | `importFile` 先查 index 判重（命中 → `isNew:false` 不新增；同名不同内容可共存）；`deleteBook` ③ 步：删封面 → 删副本 → 摘索引；`purgeOrphans` 汇总在库 `StoredCover` 文件名后交 `CoverStore.purgeOrphans`                               |
| 书架 UI（`LIB-01~06`）                   | 网格 + 导入 + 删除          | `lib/ui/shelf_page.dart`                                                                                           | `StatefulWidget` + `setState`（**禁** Riverpod / Provider）；`file_picker` `withData:true` 走 bytes（`dart:io` 不进解析链路）；长按弹 `showDialog` **二次确认**；`_opening` 防双击；`_openBook` 不 eager 解析（`d1fc20c`） |
| 依赖方向（无环）                             | UI 与后端解耦              | `lib/library/**` → `lib/meta` / `lib/storage` / `lib/platform` / `lib/model`                                       | `import_service` 经分发点 `format/book_registry.dart` 取源，**不经** `book_source.dart` 直连具体实现（§A.1 铁律：实现互不感知）                                                                                       |
| 测试形态                                 | 真实 IO + 判重/连带断言       | `test/library/{book_record,book_index,import_service,library_repository}_test.dart`、`test/ui/shelf_page_test.dart` | `Directory.systemTemp.createTempSync` + 逐用例独立目录；断言「同内容二次导入 `isNew=false`、索引仍 1 条」「同名不同内容共存」「删书后副本 + 封面 + 索引三处皆清」「删书连带清进度文件」（M1-T04 追加）                                                      |

### 2.11 M1-T04 — 阅读页产品化 / 进度持久化 / 目录

| 项     | 值                                                                  |
| ----- | ------------------------------------------------------------------ |
| 任务    | M1-T04（PRD `RD-03` / `RD-04` / `NAV-01`；架构 §N；负责人修订为「章节连续滚动」）      |
| 提交    | `d082c6a`（进度层：模型 + 持久化）→ `f196d39`（阅读页 + 目录 + 接线）                  |
| 日期    | 2026-09-21                                                         |
| 一句话目标 | 章节连续滚动阅读页 + 进度持久化 + 目录；进度模型（含 `localHint`）供 STAT / TTS / SYNC 三方复用 |

| 技术点                           | 用途                                   | 落点                                                                                         | 关键写法或坑                                                                                                                                                                                                                 |
| ----------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **章节连续滚动**（负责人修订，取代原「单章视图」）   | 从第 1 章一路滚到最后一章，不切页                   | `lib/reader/reader_page.dart`                                                              | **全部章节塞进一个 `ListView.builder`**，每章一个 item（`Column`：标题 + 该章全部段落），`itemCount = 章数`，按章懒构建虚拟化；**不引 `scrollable_positioned_list` 等任何新依赖**                                                                                   |
| **逐段渲染**（`PERF-03`）           | 不合成巨型 `Text`（避免一次布局上万个字符）            | 同上（`_buildChapterBlock`）                                                                   | 每段各自成 `Text` 子 widget，**禁 `join('\n\n')` 成一个巨型 `Text`**                                                                                                                                                                |
| 当前章 + 章内位置（`RD-04`）           | 「章索引 + 章内 0.0~1.0」在连续滚动下的可靠映射        | 同上（`_detectCurrentChapter`）                                                                | 每章块挂 `GlobalKey`；滚动停止时从**上次索引**向两侧 **±4** 探测 `findRenderObject`，取**覆盖视口顶部**的章块（`relTop ≤ 0` 且最大者），`chapterPos = -relTop / 章块高`                                                                                         |
| 版面签名恢复（`RD-04`「落点误差 ≤ 1 屏」）   | 同版面零抖动精确落回，跨版面仍合理                    | 同上（`_ensureController` / `_restoreStep`）                                                   | 控制器**内容就绪后**才创建：`localHint.matches(...)` 为真 → `ScrollController(initialScrollOffset: hint.scrollOffset)` 精确落回；不一致 / 无 hint → 按章序比例估算 + `addPostFrameCallback` 迭代校正，**≤3 帧**、偏移差 **≤ 1px** 即停                           |
| 进度以 `Chapter.href` 为稳定身份      | 书源重排 / 目录微调时不跳错章                     | `lib/reader/reading_progress.dart`                                                         | 恢复先按 `chapterHref` 匹配章节，匹配不到退回 `chapterIndex` 并 clamp                                                                                                                                                                  |
| `localHint` 设备本地快照（`SYNC-02`） | 绑定字号 / 行距 / 视口尺寸 / 滚动偏移，**不参与跨设备同步** | 同上                                                                                         | `matches` 容差 0.5 逻辑像素；`hasSameSemantics` **忽略** `localHint`，供同步侧比对语义字段                                                                                                                                                 |
| 进度持久化（`RD-04`）                | 每本书记一个进度文件                           | `lib/reader/progress_store.dart`                                                           | `<dataDir>/progress/<bookId>.json`；bookId 白名单 `^[A-Za-z0-9_-]+$` 否则 `ArgumentError`；`load` 缺失 / 损坏 / 串档 → `null`；`remove` 幂等清 `.bak` / `.corrupt` / `.tmp`；全部经 `JsonStore` + `AtomicFile`                              |
| 保存时机（3 处）                     | 不丢进度、也不写脏值                           | `lib/reader/reader_page.dart`                                                              | ① 滚动停止（`ScrollEndNotification`）② 切章（目录跳转 / 恢复落定）③ `dispose`（`unawaited`）；`_restoring` 期间**忽略**保存，避免把校正中途的偏移写回磁盘                                                                                                        |
| `BookRecord` 回写 + 删除连带        | 书架与阅读页进度一致                           | `lib/library/library_repository.dart`、`lib/ui/shelf_page.dart`                             | 保存进度时 `markRead` 回写 `lastReadAt` / `readProgress`（bookId 不在库中**静默返回**）；删书时连带 `progressStore.remove`（`LIB-06`）                                                                                                          |
| `RD-03` 去诊断信息                 | 副标题不泄露 `implId`                      | `lib/reader/reader_page.dart`                                                              | 标题取 `BookRecord.title`（回落到 `BookMeta.title` → 「阅读」）；副标题固定「第N章 · X%」，取代 M0 遗留的「N 章 · `<implId>`」                                                                                                                        |
| 目录 `NAV-01` + 控制条             | 当前章高亮 + 跳章                           | `lib/reader/toc_sheet.dart`、`lib/reader/control_bar.dart`                                  | `TocSheet` 用固定 `itemExtent = 56` + `initialScrollOffset` 让当前章滚入可见区（不依赖逐项 `GlobalKey`，后者对懒构建列表不可靠）；`ListTile.selected` 高亮；控制条 = 上/下一章 + 全书进度 + 排版设置（复用 `ReaderSettingsBar`），目录入口**统一在 AppBar**                          |
| 测试（`FakeAsync` 铁律）            | 让 widget 层测试可信                       | `test/reader/reader_page_test.dart`、`test/ui/shelf_page_test.dart`、`test/widget_test.dart` | widget 内部（`initState` / 回调）发起的**真异步 IO 在 FakeAsync 区不会自行推进**，且载入期 `CircularProgressIndicator` 是无限动画 → `pumpAndSettle` **超时挂死**；统一用 `_settle` 助手（`runAsync(Future.delayed)` + `pump` **交替**多轮推进），**不用** `pumpAndSettle` |
| 纯 Dart 进度模型（可单测 / 可进 isolate） | 复用于 SYNC / TTS / STAT                | `lib/reader/reading_progress.dart`                                                         | **不 import Flutter、不 import `dart:io`**；`toJson` / `fromJson` **防御式**（非 Map / 缺字段 / 类型错 → `null` 不抛）；`chapterPos` 构造即 clamp `0.0~1.0`                                                                                  |


### 2.12 M1-T07 — 性能（PERF-02 内存收敛 + PERF-03 分段渲染验收）

| 项     | 值                                                                                                                                        |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 任务    | M1-T07（PRD `PERF-02` / `PERF-01`；负责人指定 4 个子项：① 阅读页增量加载 ② 目录/正文分离 ③ IsolateRunner ④ 样本与验收）                                                |
| 提交    | `e16da96`（② 解析器惰性）→ `f84b470`（① 阅读页增量）→ `9c9ff93`（③ IsolateRunner）→ `9be18ed`（④ 样本 / 测试 / 基线）→ 收尾提交（① 去无界缓存 + ④ `parseEpubStructure`，本批） |
| 日期    | 2026-09-22                                                                                                                               |
| 一句话目标 | 打开大书不再一次性解压整本（图 / 字 / CSS 不常驻）；**读完一整本稳态内存也不顶回全书大小**；阅读页正文增量加载 + 有界驻留；给出改前 / 改后可复现数字                                                     |

| 技术点                           | 用途                      | 落点                                                                   | 关键写法或坑                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------- | ----------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 惰性归档访问（`PERF-02` ①）           | 结构解析阶段**不**预解压整本        | `lib/epub/epub_parser.dart`                                          | 旧实现 `Map<String,Uint8List> files` 对**每条** `contentOfArchiveFile`（含图片）预解压；改为 `Map<String,ArchiveFile> byName`——archive 3.x 的 `ArchiveFile.content` 本就按需解压，仅建「条目名 → ArchiveFile」索引即达成「图 / 字 / CSS 保持压缩态」                                                                                                                                                           |
| 声明式文本性判定                      | spine 项「是否正文」不再依赖字节     | `lib/epub/zip_paths.dart`（`textualVerdict`）                          | 仅凭 `media-type` / 扩展名即可判定的：明确非文本**直接跳过、连解压都不做**；仅当声明不足（无 media-type 且扩展名不暴露）才解压该**单**条目做字节魔数兜底（`fx07b` 脏书路径）。`looksTextual` 复用同一判定，行为逐字不变                                                                                                                                                                                                                        |
| `EpubSection` 惰性构造            | 正文推迟到 `content(i)` 才解压  | `lib/model/epub_book.dart`                                           | 新增 `EpubSection.lazy(loadBytes:)`；`rawBytes` 由字段改为 getter、**无缓存**（每次访问现取，`test/perf` 有计数断言）；**急切构造签名不变** → `dart_epub_source.dart` / 既有测试零改动（不加 `join`、不进 Flutter、不引新依赖）                                                                                                                                                                                         |
| **非驻留解压（`PERF-02` ① 的真正口径）**  | 读完的章**不**留在内存里          | `lib/epub/zip_paths.dart`（`lazyEntryLoader`）                         | **关键坑**：archive 3.x 的 `ArchiveFile.content` 会把解压结果**永久缓存**在 `_content`，仅去掉 `EpubSection._cached` 仍会随读章数线性增长。改法：`lazyEntryLoader` 只捕获**压缩态字节**（`rawContent.toUint8List()`，非消费视图），每次现解——STORE 直接返视图、DEFLATE 走 `package:archive` 的 `inflateBuffer`。故 `totalCharCount()` / `search()` 遍历全书后已读章节可被 GC 回收                                                              |
| **结构解析 / 绑定分离（`PERF-01` 底座）** | 让结构解析可跨 isolate         | `lib/epub/epub_parser.dart`                                          | `parseEpubStructure(bytes, {fileName})` 返回**无闭包纯数据** `EpubStructure`（sections 用 `EpubSectionRef{id,href}`、toc、metadata、封面候选 href、条目名索引）——闭包才是 `SendPort` 拒收项，纯数据对象可跨 isolate；`parseEpubResult(bytes, {fileName})` **签名不变**，内部 = `parseEpubStructure` + 在**本 isolate** 把 `loadBytes` / `readEntry` 绑到捕获了 `bytes` 的闭包上。**切记**：`parseEpubResult` 的返回**不可**跨 isolate |
| 封面候选按需                        | 不再急切解压并常驻全部候选           | 同上（`_bindOpfView` 的 `readEntry`）                                     | 旧实现一次性解压并存下全部封面候选字节（`candidateBytes`）；改为 `readEntry(href)` 按 href **现查** `_resolveFile` → `lazyEntryLoader`，命中即解、用完即弃                                                                                                                                                                                                                                            |
| 正文增量加载（`PERF-02` ②）           | 首帧只等目标章，不等全书（±1 预取不阻塞）  | `lib/reader/chapter_cache.dart`、`lib/reader/reader_page.dart`        | `ChapterAutoLoader.loadFirstBatch(target)` **目标章必等、邻章 ±1 `unawaited` 预取、各自到货入缓存**（对齐 567Reader `ReadBook.loadContent` cur±1 并行/仅目标章驱动显示；旧 `Future.wait` 全等会被慢邻章拖住）；后台 `fillOnce(current)` 按「离当前章由近及远」每批 **≤3** 补齐至 ±12 窗口驻留；未加载章渲染等高「载入中」占位块                                                                                                                     |
| 有界驻留（有界 LRU）                  | 驻留章数不随书增长               | `lib/reader/chapter_cache.dart`                                      | `ChapterCache` 用**保序** `LinkedHashMap`（插入序 = LRU 序，尾 = 最新），上限 `kMaxLoadedChapters = 30`；`touch` 保护「在视章」不被逐出                                                                                                                                                                                                                                                      |
| 占位高度估计                        | 抑制「已加载章数」增长导致的总高跳变      | `lib/reader/reader_page.dart`                                        | 取**已加载章渲染高度的中位数**，**非**「字符数 × 系数」——未加载章的字符数在不解压前提下不可知，那正是 `PERF-02` 要避免的                                                                                                                                                                                                                                                                                         |
| 布局突变语义重锚（修 A/C，2026-09-23）    | 占位→真实合入 / 占位高刷新**不挪视口** | `lib/reader/reader_page.dart`（`_applyLayoutChange`）                  | 突变前 `ScrollAnchor.capture` 记「视口顶在当前章的相对位置」，突变后 `_beginScrollTo(chapterIndex, relativePos)` **语义坐标重锚**；**禁**复用 `_onSettingsChanged` 式单跳 `correction`——同帧多次突变 /「跳转未渲染就再次捕获」会把多个 delta **叠加**（过校正）。采样（修 C）随重锚收敛走（`_finishRestore`），防漂移位置入档；恢复迭代中 / 用户手势滚动中 / 锚点抓取失败不重锚                                                                                              |
| 恢复不降级（`RD-04`）                | 增量加载后落点仍准               | 同上（`_ensureController`）                                              | 默认仍走「按章序估算 + `addPostFrameCallback` 校正 ≤3 帧」；**仅当**同版面签名**且** `_cache.coversPrefix(targetIndex)`（已加载集合覆盖 `[0, target]`）时才用 `initialScrollOffset` 精确落回                                                                                                                                                                                                            |
| `PERF-03` 逐段渲染                | 不合成巨型 `Text`            | 同上（`_buildChapterItem`）                                              | 每段各自成 `Text`（**禁 `join('\n\n')`**）；超长单章（>10 万字符）验收见 `test/perf`                                                                                                                                                                                                                                                                                                  |
| 隔离执行底座（`PERF-01`）             | 为解析移出主 isolate 预留同款形状   | `lib/task/isolate_runner.dart`                                       | `compute()` 薄封装：纯函数 + **可序列化**入参；本任务**不接线**到 `load()`，仅提供底座与失败护栏                                                                                                                                                                                                                                                                                                 |
| 性能基线（可复现）                     | 改前 / 改后数字留档             | `tool/perf_bench.dart`、`docs/perf-baseline/README.md`                | **BookSource 层**测「首屏」（`load` + `chapters` + `content(±1)`）；**一次进程只测一样本**避免 RSS 互污，多轮取 min/median 时间 + `ProcessInfo.currentRss/maxRss`；样本由 `tool/gen_perf_fixtures.dart` 写到**临时目录、不入库**                                                                                                                                                                           |
| 测试铁律（`FakeAsync`）             | 让性能验收可信                 | `test/perf/lazy_load_test.dart`、`test/task/isolate_runner_test.dart` | 一律**纯 Dart `test()`**（**非** `testWidgets`）——`testWidgets` 体内 `await` 真异步 IO 会挂死（FakeAsync 不排空微任务队列），本项目**已两次实证**                                                                                                                                                                                                                                                 |
| 结果（可复现）                       | 300+ 章 EPUB（含 80MB 图）   | `docs/perf-baseline/README.md`                                       | 首屏时间 **123 → 45 ms**（min，≈ −63%）；首屏后驻留 RSS **497.9 → 429.2 MB**（≈ −69 MB）；**稳态**（首屏后再读 50 章）**497.9 → 429.8 MB**（+0.6，几乎不增）；100 章大头书读完 100 章 稳态 **562.5 → 426.8 MB**；20MB TXT / 小书无回归                                                                                                                                                                            |

### 2.13 M1-T06 — 排版与阅读设置（含位置锚定）

| 项     | 值                                                                                                                                          |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| 任务    | M1-T06（PRD `TYP-01` ~ `TYP-04`；6 子项：① ReaderSettings 扩展 ② resolveTextStyle ③ parseInlineStyles ④ ScrollAnchor ⑤ ReaderSettingsBar 扩展 ⑥ 测试） |
| 日期    | 2026-09-22                                                                                                                                 |
| 一句话目标 | 字号/行距/字体/主题/页边距可调；设置变更后当前段不飞出视口；`<b>`/`<i>` 内联样式渲染；首行缩进                                                                                    |

| 技术点                                      | 用途                        | 落点                                           | 关键写法或坑                                                                                                                                                                                                                 |
| ---------------------------------------- | ------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ReaderSettings` 扩展（`TYP-01` ~ `TYP-03`） | 统一阅读设置值对象                 | `lib/typography/reader_settings.dart`        | 从 `reader_settings_bar.dart` 提取；新增 `fontFamily`（`String?`）、`themeMode`（`AppThemeMode` 三态）、`pageMargin`（`PageMargin` 枚举：narrow=12 / normal=16 / wide=24）。纯 Dart，不 import Flutter / dart:io                              |
| `resolveTextStyle`（`TYP-01`）             | 字号/行距/字体 → TextStyle 单一出口 | `lib/typography/text_style_resolver.dart`    | reader_page 原 3 处 `TextStyle(fontSize:...,height:...)` 统一改为调此函数                                                                                                                                                        |
| 首行缩进（`TYP-04`）                           | 段落首行缩进 2 字符               | `lib/typography/typeset.dart`                | 全角空格（U+3000）前缀：宽度恒 = 1 中文字宽，不受字号/字体影响                                                                                                                                                                                  |
| `<b>`/`<i>` 内联样式（`TYP-04`）               | 段落内粗体/斜体渲染                | `typeset.dart` + `section_extractor.dart`    | `_walk` 白名单保留 `<b>`/`<i>`（字面 HTML 字符串在段落文本里）；`parseInlineStyles` 正扫标签 + 状态机切 `TextSpan` 列表；未识别标签原样显示（不吞内容）                                                                                                             |
| 位置锚定（`TYP-02`）                           | 设置变更后当前段不飞出视口             | `lib/typography/anchor.dart`（`ScrollAnchor`） | ① 变更前：GlobalKey + RenderBox 算「视口顶在当前章的相对位置 relPos」；② setState → 列表重建；③ postFrameCallback：`correction = newChapterTop - (newViewportTop - relPos × newChapterHeight)` → `jumpTo` 校正。纯数值版 `correctionFromRaw` 供纯 Dart 测试 |
| 设置栏扩展（`TYP-01`/`TYP-03`）                 | 页边距三档 + 主题三态              | `lib/ui/reader_settings_bar.dart`            | 两个 IconButton 循环切换；总高度仍 48px（单行 Row）                                                                                                                                                                                   |
| 测试                                       | 验收                        | `test/typography/*`（4 文件 53 条）               | TYP-01 字号/行距/字体；TYP-02 anchor 7 组合；TYP-04 parseInlineStyles 白名单 + 14 组脏文本不崩溃                                                                                                                                           |

### 2.14 M2a-T01 — 内嵌图片渲染与解码缓存

| 项     | 值                                                                                                    |
| ----- | ---------------------------------------------------------------------------------------------------- |
| 任务    | M2a-T01（PRD `CNT-01`；6 子项：① readResource 接口 ② img 标记保留 ③ WidgetSpan 解析 ④ ImageCacheLRU ⑤ 阅读页接入 ⑥ 测试） |
| 日期    | 2026-09-22                                                                                           |
| 一句话目标 | EPUB 内嵌插图在阅读页可见；图片字节有界缓存（50MB LRU），不常驻全书（`PERF-02` / `NF-M5`）                                        |

| 技术点                             | 用途                     | 落点                                         | 关键写法或坑                                                                                                                                                                          |
| ------------------------------- | ---------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BookSource.readResource(href)` | 包内任意资源（图片/字体/CSS）按需读取  | `lib/format/book_source.dart`              | 抽象默认 `async => null`；`DartTxtSource` 返回 null；`DartEpubSource` 走 `OpfView.readEntry`（`lazyEntryLoader` **每次现解压**，不常驻全书图片字节）                                                      |
| `<img>` 标记保留                    | 正文提取不丢图                | `lib/epub/section_extractor.dart`          | `_walk` 遇 `<img>` 写 `\x00IMG:src\x00`（NUL 包裹，正常文本不会出现）；src 用 `resolveHref(baseDir, src)` 归一化为**绝对包内路径**（`baseDir = p.posix.dirname(section.href)`）                              |
| `parseContentSpans`             | 标记 → `WidgetSpan`      | `lib/typography/typeset.dart`              | 按 `\x00` 分割：奇数段 = 图片标记 → `WidgetSpan(child: _InlineImage)`；偶数段走 `parseInlineStyles`（`<b>`/`<i>` 复用）。无标记时零开销走纯文本路径                                                               |
| `_InlineImage` 异步加载             | 加载中转圈 / 失败占位图标         | `typeset.dart`                             | `initState` 发起加载，`_bytes` 缓存在 State（rebuild 不重载）；`Image.memory` + `errorBuilder` 双保险，脏图不崩                                                                                       |
| `ImageCacheLRU`                 | 图片字节有界缓存               | `lib/reader/image_cache.dart`              | **value = 原始字节**（非 `ui.Image`——#4 已知 `dart:ui` 纯 test 环境构造失败；解码交给 `Image.memory` 内部缓存）；上界 `kDefaultImageCacheMaxBytes = 50MB`，`LinkedHashMap` 插入序 = LRU 序，超限淘汰头部；`dispose()` 清空 |
| 阅读页接入                           | 缓存 → readResource 二级读取 | `lib/reader/reader_page.dart`              | `_resolveImage`：先查 `_imageCache`，miss 再 `source.readResource` 并入库；`dispose` 时释放缓存；段落渲染 `parseInlineStyles` → `parseContentSpans`                                                |
| 测试                              | 验收                     | `test/reader/inline_image_test.dart`（12 条） | `parseContentSpans` 5 条（WidgetSpan 产出 / null 占位 / `<b>`+`<img>` 混合 / 连续图）+ `ImageCacheLRU` 7 条（LRU 提升 / 超限淘汰 / 更新计数 / dispose / 50MB 上界）                                        |

### 2.15 M2a-T02 — `<br>` / 表格 / 脚注 / `linear="no"` 四项内容语义

| 项     | 值                                                                                                                                                                                          |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 任务    | M2a-T02（PRD `CNT-02` / `CNT-03` / `CNT-04` / `CNT-05`）                                                                                                                                     |
| 提交    | `55bbb27`（CNT-02）→ `16e8508`（CNT-03）→ `b7ff930`（CNT-04a）→ `97d1919`（CNT-04b）→ `7d004db`（CNT-04c-1）→ `c9f1e6f`（CNT-04c-2）→ `3c16acf`（CNT-05）；随批修复书架首点无响应 `3e750b8`、CHANGELOG 单独提交 `a87ab80` |
| 日期    | 2026-09-22                                                                                                                                                                                 |
| 一句话目标 | 四项内容语义一次接好：`<br>` 与表格进正文、链接可跳可返回原位置、`linear="no"` 可见不丢                                                                                                                                     |

| 技术点                           | 用途               | 落点                                                                                        | 关键写法或坑                                                                                                                                                                                                                                                                                   |
| ----------------------------- | ---------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<br>` 行内换行（`CNT-02`）         | 正文抽取不丢换行         | `lib/epub/section_extractor.dart`                                                         | 抽取遇 `<br>` 写行内换行进段落文本；`baseline.json` / `make_fixtures.py` 预期同步                                                                                                                                                                                                                          |
| 表格按行退化（`CNT-03`）              | 脏表格不崩、内容可读       | 同上                                                                                        | `<table>` 逐 `tr` 取单元格文本、按行退化为普通段落——**不引表格渲染控件**，退化即交付                                                                                                                                                                                                                                    |
| 链接与锚点标记（`CNT-04a`）            | 抽取层只打标记、不碰 UI    | 同上                                                                                        | `<a href>` → `\x00A:href\x00文字\x00A\x00`、锚点 → `\x00ID:id\x00`（NUL 包裹：正常文本不会出现，渲染时吞掉不上屏）；14 本 fixture 重生成对齐                                                                                                                                                                               |
| 链接可点（`CNT-04b`）               | 标记 → 可点链接        | `lib/typography/typeset.dart`                                                             | `InlineParagraph` 解析 A 标记：`onLinkTap` 为 null 时仅下划线不可点；`didUpdateWidget` 以 `oldWidget.onLinkTap != widget.onLinkTap` 判等——**方法 tear-off 跨帧相等**，故阅读页传同步 tear-off `_onLinkTapped` 而非闭包，防 recognizer 无谓重建                                                                                     |
| 链接导航器（`CNT-04c-1`）            | 跳转纯逻辑可单测         | `lib/reader/link_navigator.dart`                                                          | `splitLinkHref`（record 拆 path/fragment）、`findChapterIndex`（匹配键 = 百分号解码 + 小写，找不到 −1）、`findParagraphIndex`（扫 `\x00ID:id\x00`，先原样再解码回退，找不到 −1）、`LinkBackStack`（ScrollAnchor LIFO，空栈 pop 返 null 不抛）                                                                                          |
| 阅读页跳转与返回（`CNT-04c-2`）         | 点链接段落级定位 + 一键回原位 | `lib/reader/reader_page.dart`                                                             | path 空 → 章内段落定位；path 非空 → 跳章 + 章内定位；任一步找不到**静默忽略绝不抛**；跳转前 `ScrollAnchor.capture` 压 `LinkBackStack`，右下角浮动返回按钮（栈空隐藏）`pop+restore`；段落 `GlobalKey` 懒创建、测段落 box 顶换算内容绝对偏移。坑：断言「恰好 push 一次」须 `find.byType(ReaderPage, skipOffstage: false)`；点链接字形用 `RenderParagraph.getBoxesForSelection` 取盒中心 |
| `linear="no"` 可见并标注（`CNT-05`） | 非主线内容不丢、可辨识      | `lib/epub/epub_parser.dart`、`lib/model/epub_book.dart`、`lib/format/dart_epub_source.dart` | `EpubSectionRef` / `EpubSection` 增 `linear` 字段（默认 true），`linear="no"` 保留进 sections 标 false（**资源过滤 media-type/扩展名/魔数照常**）；`chapters()` 中 toc 已覆盖的标题追加「（非主线）」、未覆盖的按平坦目录补入（同样标注）；`_bindBook` 绑定层透传 linear；fx06 契约随新行为同步（预期章节 2→3、ch2 保留）                                                    |
| 书架首点无响应修复（随批 bugfix）          | 关书后首点不再被吞        | `lib/ui/shelf_page.dart`、`lib/ui/book_card.dart`                                          | `_opening` 守卫收窄到 push 前准备阶段（push 一发起即释放；关书刷新走 `route.popped.then` 不占守卫）+ 准备期 per-card loading 覆盖层 + `Card(clipBehavior: Clip.antiAlias)>InkWell`（封面/占位走 `Ink.image` / `Ink` 画在 Card 的 Material 上，ripple 不被不透明内容盖住）`3e750b8`                                                              |
| FakeAsync 铁律（本批两次实证）          | widget 测试可信      | `test/reader/link_navigation_test.dart`、`test/ui/shelf_page_test.dart`                    | testWidgets 体内禁 await 真异步 IO（FakeAsync 区永久挂死），统一 `_settle`（`runAsync`+`pump` 交替）；路由 pop 过渡 **ticker 首拍才起算**，单帧大 pump 推不完 → 12×50ms 小帧推进，否则 modal barrier 吞点击                                                                                                                             |


### 2.16 M2a-T03 — 书籍详情页与元数据手动编辑（META-08 / META-09）

| 项 | 值 |
|---|---|
| 任务 | M2a-T03（PRD `META-08` / `META-09`；F9 流程；`UI-04` 红线） |
| 提交 | `4fc5d16`（数据层）→ `51d9071`（详情页 UI + 入口改道）→ `8851968`（编辑+封面）→ `f978266`（批次4 测试 + bookFileSize） |
| 日期 | 2026-09-23 |
| 一句话目标 | 书架点书进详情页看全字段与来源标记；可编辑书名/作者/简介/封面，用户值不被重新解析覆盖，「恢复自动值」回到解析结果 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `BookRecord` 增 `intro` + 四来源标记 | 详情页字段与 `META-09`「置 user 不被覆盖」的持久化载体 | `lib/library/book_record.dart` | **枚举落盘用枚举名字符串**（`MetaOrigin.name`）；`fromJson` 缺失/脏值 → `intro=''`、四来源 = `none`（旧索引条目语义即「来源未知」）；构造参数带默认值，旧调用点零改动；`copyWith` 同步扩展 |
| `ImportService.import` 带入来源 | 新导入的书来源标记天然正确（`META-08 ②`，如 TXT 作者标「文件名推断」） | `lib/library/import_service.dart` | 直接透传 `meta.intro` 与 `meta` 的四来源，不在导入层重算 |
| `LibraryRepository.updateRecord` | 编辑 / 恢复自动值 / 一次性回填的唯一落盘通道 | `lib/library/library_repository.dart` | 抄 `markRead` 模式：`_index.load` → 同 bookId 替换 → `save`；不在库静默返回；**UI 只依赖本类，禁直触 `BookIndex`** |
| 书架入口改道 + 开书回调注入 | 「书架点一本书 → 详情页」（F9 / `META-08 ①`），开书管道只有一份 | `lib/ui/shelf_page.dart` | `BookCard.onTap` → `_openDetail` push 详情页（`_detailPushing` 防双击叠页）；`onOpenBook: _openBook` 回调注入，详情页底部「继续阅读」只转发（**禁止复制第二份开书管道**）；`await push` 返回后 `unawaited(_loadBooks())` 刷新（编辑/移出/进度靠它同步） |
| 详情页玻璃红线落地 | 顶栏玻璃 / 封面区与简介区不透明 | `lib/ui/book_detail_page.dart` | `GlassNavScaffold + GlassTopBar` 做导航层（**从不手传 premium**，库自动提升）；滚动内容 + 底部操作同在一个 `OpaqueContentSurface` 内，内部零玻璃控件（不玻璃包玻璃、玻璃不进滚动行）；简介区显式 `fullyOpaque(surfaceContainerHighest)` |
| 一次性回填（有界 IO） | 旧索引条目（四来源全 `none`）进详情页时补来源标记 | `meta_editor.needsOriginBackfill` / `backfillFromMeta` + `BookDetailPage._backfill` | 判据取**四来源全 `none`**（TXT 简介/封面解析结果本就是 none，按「任一 none」会每次打开都重解析）；`origin==user` 字段绝不动（`META-09 ④`）；`PendingCover` 物化后才落盘（持久化不含 PendingCover 不变式）；失败静默降级不重试 |
| 编辑态 + 仅变化字段置 `user` | `META-09` 保存语义（未改字段来源不动，`③` 的「原值」才可还原） | `meta_editor.validateEdits` / `applyEdits` + `BookDetailPage` 编辑态 | 纯函数算 `changed*` 决定是否传 `copyWith` 字段（`copyWith` 无法表达「显式 null」，未变字段传 `null` = 保持原值）；空书名/空作者 `validateEdits` 返回文案 → 保存禁用 + TextField `errorText` 就地提示（`META-01` 作者兜底「未知作者」不留空串） |
| 「恢复自动值」重新解析 | 清除自定义、回到内嵌/文件名推断结果（`META-09 ③`），不持久化 auto 快照 | `meta_editor.restoreFromMeta` + `BookDetailPage._restoreAuto` | `readBookBytes` → `openBook` → `load()` 现解现用，`meta.auto ?? BookMeta(title/author/intro)` 兜底；**`try/finally dispose()`**（抄 `import_service`）；封面：`PendingCover` → `materialize`（幂等先清同 bookId 旧文件），解析无内嵌封面则 `delete` 当前 `StoredCover`（不留孤儿）；四来源改回解析值 |
| 换封面走 `replaceWithUserPick` | `META-09 ②` 换图后旧封面文件被删（`META-06 ①`） | `BookDetailPage._pickCover` / `lib/ui/cover_picker.dart` | `FilePicker(type: FileType.image, withData: true)` 取字节（**零新依赖**）→ `replaceWithUserPick`（materialize 新图 + 删 `previous` 旧文件）→ `coverOrigin = user` → `updateRecord` 落盘 |
| 封面字节不常驻（`PERF-02`） | 详情页缩略图 / 大图展示 | `lib/ui/book_detail_page.dart` / `lib/ui/cover_picker.dart` | 缩略图 `readThumb` 现读、换图即弃；大图 `readFull` 现读后 `Dialog + InteractiveViewer` 展示（玻璃弹窗属 M2a-T04） |
| 文件大小只 stat 不读 | 详情页「文件大小」展示（`META-08 ①`） | `LibraryRepository.bookFileSize` | `File.exists` + `File.length()`，**不 `readAsBytes`**——大书展示大小不把整本书读进内存；文件缺失回 `null`（`LIB-03` 口径同 `readBookBytes`） |
| 验收测试三层结构 | META-08/09 逐条验收（`f978266`） | `test/meta/detail_test.dart` | ① `meta_editor` 纯函数（originLabel/validate/apply/restore/backfill 判据）；② 仓储集成**纯 `test()` + 临时目录**（导入→编辑→重载/换封面旧文件已删/二次导入不覆写）；③ widget 层 `_settle` 助手排空真 IO（FakeAsync 铁律），玻璃红线断言 `GlassTopBar 有 / OpaqueContentSurface 有 / GlassCard 等内容层玻璃全无`；详情页内文本断言一律 `_inDetail` 范围限定（书架同名文本在栈下防误配） |

> **⚠️ 后续改道（2026-09-29，PRD v2.9）**：上表「书架入口改道 + 开书回调注入」一行**已不是现役口径**——书架**点书卡**改为**直接进阅读页**（`BookCard.onTap` → `_openBook`），详情页入口改走**长按操作单「书籍详情」**（`_openDetail` 与 `_detailPushing` 仍保留，只是调用点从「点卡」换成「操作单」）。原文按「事实层留证」不改写，现役口径见 §2.46。

### 2.17 M2a-T04 — 导航层玻璃化（UI-02 / UI-03，执行中）

| 项 | 值 |
|---|---|
| 任务 | M2a-T04（PRD `UI-02` 导航层玻璃 / `UI-03` 浮层玻璃 / `UI-04` 内容不透明红线） |
| 批次 | ① 书架导航层玻璃化（本节）→ ② glass_dialog/glass_sheet 封装 + 4 调用点 → ③ 测试 + 文档收尾 |
| 日期 | 2026-09-23 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 书架导航层玻璃化 | 书架首页顶栏/壳层入玻璃导航层（`UI-02`） | `lib/ui/shelf_page.dart` | 照抄 `book_detail_page` 范本：`GlassNavScaffold(appBar: GlassTopBar(...))`，两个 build 分支（loading / 正常）都要换；内容整体包 `OpaqueContentSurface`（`UI-04`） |
| 详情页玻璃断言作用域限定 | 书架入栈后全树有 2 个 `GlassTopBar`，原全树断言误报 | `test/meta/detail_test.dart` | `find.byType(GlassTopBar, skipOffstage: false)` 会数到栈下 offstage 的书架 → 包一层 `_inDetail(...)` 再断言 |
| `GlassOverlays` 扩展 | 4 个原生浮层换玻璃所需的三个透传参数 | `lib/ui/glass_kit.dart` `GlassOverlays` | `showAlert` 补 `barrierDismissible`（缺省 false 库默认，确认框改传 true 保留「点外取消」）与 `maxWidth`（大图放开到整屏）；`showSheet` 补 `isScrollable`/`showDragIndicator`；re-export `GlassDialogAction` 免调用方再 import 玻璃库 |
| 玻璃确认框返回值语义 | 替换 `showDialog<bool>` 不改业务判定 | `shelf_page.dart` `_deleteBook` / `book_detail_page.dart` `_removeFromShelf` | `GlassDialogAction(label:, isDestructive:, onPressed: () => Navigator.pop(context, true/false))`；barrier 关闭返回 null，业务侧「非 true 不删」判定原样兼容；删除/移出标 `isDestructive`（红光语义） |
| 目录换玻璃底部弹窗 | `NAV-01` 目录入 `UI-03` 浮层玻璃 | `reader_page.dart` `_openToc` | `GlassOverlays.showSheet(isScrollable: false)`——TocSheet 自带 `Flexible+ListView`，库默认外层 `SingleChildScrollView` 会嵌套纵向滚动吃手势；**该路径库给的是无界高度（探针实测 `h<=Infinity`），Flexible+ListView 视口直接炸**（`Vertical viewport was given unbounded height`）→ builder 外再包 `ConstrainedBox(maxHeight: 0.6 屏高)` 补约束（内容矮时仍收缩）；builder 包 `OpaqueContentSurface` 守 `UI-04`（玻璃只留外壳，列表行下不透玻璃） |
| 大图玻璃弹窗 | 封面查看器换玻璃（`UI-03`），无确认语义 | `cover_picker.dart` `showCoverFullScreen` | **库断言 1–3 个 actions，空列表 debug 下 AssertionError**（初版 `const []` 踩坑）→ 必须给 1 个「关闭」动作 + `barrierDismissible: true`（点外关，同原 `showDialog` 默认）+ `maxWidth: size.width`，内容 SizedBox 自收 `width-72`（卡片 padding 20×2 + 页边 16×2） |
| 玻璃弹窗关闭的测试推进 | 确认框点「取消」后 `_settle`(400ms) 推不完关闭转场，弹窗仍在树上误报 | `test/ui/shelf_page_test.dart` LIB-06 | 关闭断言前换 `await tester.pumpAndSettle()`（对照实验实证：onPressed 已触发、400ms 不够、pumpAndSettle 正常关） |

> **后续改道（2026-09-29，见 §2.49）**：上表「`GlassOverlays` 扩展」一格描述的是 **M2b-T07 当时**的形态，保留作事实留证。其中 `showSheet` 的 **`showDragIndicator` 参数已删除**——本项目弹层口径改为「**无横条、禁上划拖拽关闭、关掉点击放大 / 光晕 / 饱和度脉冲**」，五项参数**硬编码在薄封装内**（改一处即 6 处弹层同时生效），调用点不再逐个传参。


### 2.18 M2a-T06 — PERF-01 解析移出主 isolate（IsolateRunner 接线）

| 项 | 值 |
|---|---|
| 任务 | M2a-T06（PRD `PERF-01`；改法按 `docs/schedule.md` M2a-T06 勘误：后台跑 `parseEpubStructure` 纯数据 + 主 isolate 绑定闭包） |
| 提交 | `5aa0679` |
| 日期 | 2026-09-24 |
| 一句话目标 | 书籍解析 / 准备的重活移出主 isolate：后台产纯数据结构，主 isolate 只绑闭包与渲染；isolate 派发失败诚实回落（`RUST-01` 降级语义） |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 结构解析 / 绑定分离**落地** | 解析真跑在后台 isolate | `lib/epub/epub_parser.dart`、`lib/format/dart_epub_source.dart` | 后台 `parseEpubStructureTask(EpubParseRequest)` 产**无闭包纯数据** `EpubStructure` 传回 → 主 isolate `bindEpubResult(bytes, structure)` 重建索引并绑 `loadBytes` / `readEntry` 闭包。**不是** `compute(parseEpubResult)`——其返回值含闭包，`SendPort` 拒收（v2.8 勘误的根源） |
| **信封模式（业务错误 / 机制失败分流）** | 回落只兜机制失败，业务错误保持原型原码 | 同上（`EpubParseOutcome`）、`lib/format/dart_txt_source.dart`（`_TxtPrepareOutcome`） | 任务入口把 `MReaderFormatException`（纯数据：`FormatErrorCode` + `String? detail`）捕获进**返回值信封**；`runWithFallback` 的 catch 只应见到「派发失败 / 远端意外」，业务错误由调用方从信封原样抛出（与未接 isolate 前同型同码）。探针实证（Dart 3.12）：Exception 作返回值字段可原样跨 `Isolate.run`；回调内 throw 同 isolate group 异常亦原样传播 |
| `Isolate.run` 而非 `compute()` | `lib/epub/**` / `lib/format/**` 零 Flutter 铁律不破 | `lib/task/isolate_runner.dart` | Flutter `compute()` 在 `package:flutter/foundation`，纯层一引即破铁律；`dart:isolate` 的 `Isolate.run` 非 web 同构。typedef `IsolateTask<M, R>` = 顶层纯函数（实测顶层函数可直接作消息派发目标） |
| `runWithFallback` 失败护栏（`RUST-01` 语义） | isolate 派发失败不炸、回落主 isolate | 同上 | `try { run(...) } catch (_) { task(message) }`——入参不可传（web / 远端）或远端意外时同一任务回落现跑，结果与业务错误语义均不变；测试注入 `_FailingRunner` 验回落路径 |
| runner 构造注入 | 接线可测（不碰真 isolate 也能断言派发） | `lib/format/dart_epub_source.dart`、`lib/format/dart_txt_source.dart` | `{this.runner = const IsolateRunner()}` 公开 final 字段（顺带消 `prefer_initializing_formals`）；测试 `_RecordingRunner` spy 断言 `identical(task, parseEpubStructureTask)` + `_loading ??=` 去重只派一次 |
| TXT 准备 / 解码后台化 | 20MB TXT 开书不冻 UI | `lib/format/dart_txt_source.dart` | `_txtPrepareTask`（分章分析）+ `_txtDecodeTask`（解码 + 去 BOM）同款信封后台化；`_analyze` / `_pickRule` / `_splitBy*` / `_chunkTitle` 转 `static` 供顶层任务调用（顶层函数触不到实例私有成员） |
| `maxGapMs` 测量口径 | `PERF-01` 验收①「UI 无超 1 秒无响应」的可测代理 | `tool/perf_bench.dart` | 首屏窗口内 10ms 周期 `Timer.periodic` 心跳，取相邻打点最大间隔；**必须计入收尾间隔**（窗口结束 − 最后打点；整窗无打点 = 整窗时长）——before 整条同步微任务链把定时器饿死一次都排不上队，不计收尾会得 `maxGapMs=0` 的假象 |
| **不可见字符字面量坑** | 源码绝不落裸 BOM | `lib/format/dart_txt_source.dart`（`_decodeAndStripBom`） | Edit 写 `'\uFEFF'` 转义会被折叠成**真实不可见 BOM** 落进源码（补救 Edit 因新旧串同为不可见字符报 exactly the same）；含不可见字符的字面量一律**纯 ASCII 写法**（`codeUnitAt(0) == 0xFEFF` 比较），取证用 `grep` + `od -c`（BOM = `357 273 277`） |
| 结果（可复现） | before / after 对照 | `docs/perf-baseline/README.md` §7.1 | `maxGapMs`：20MB TXT **994 → 27ms**、320 章图书 **475 → 130ms**、单超长章 **334 → 96ms**、无目录大书 **9348 → 3996ms**（残余 = 平坦目录取标题在主 isolate 同步跑，`_flatChapter` 逐章 `extractSection(rawBytes)`；**已由 M2a-T06b 闭环，见 §2.19**）；稳态 RSS 不回归（读 50 / 100 章 ±1MB 内） |

### 2.19 M2a-T06b — PERF-01 残余修复：无目录书平坦目录取标题后台化（flatTitles）

| 项 | 值 |
|---|---|
| 任务 | M2a-T06b（增补；`PERF-01` 残余项方案 a，2026-09-24「继续开发」后落地） |
| 提交 | `56fabe5` |
| 日期 | 2026-09-24 |
| 一句话目标 | 无目录书 `chapters()` 平坦目录取标题（逐章解压 + HTML 解析）移入解析 isolate，主 isolate 零解压；`big_bodies` 3996ms 连续无响应 → 194ms |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `flatTitles` 预取表 | 平坦目录标题一次取好，消费方查表零解压 | `lib/epub/epub_parser.dart`（_parse 第 8 步）、`lib/model/epub_book.dart` | `EpubStructure` / `EpubBook` 增 `Map<String, String> flatTitles`（**纯数据、可跨 isolate**）；**仅 toc 为空时填充**（有目录书标题取自 toc，不付解压成本）；键用 href **不用索引**（绑定期 `_bindBook` 缺文件过滤会错位）。三级语义：查到非空 = 预取标题；查到 `''` = 已预取但无标题（补「第 N 章」占位）；**miss = 未预取**，回退 `extractSection(rawBytes).title`（手造 EpubBook / 有目录书 linear=no 补入路径的旧行为） |
| 非缓存解压取标题（字节即弃） | `PERF-02` ① 唯一有界例外，防「取标题把整本驻留」 | 同上 | 必须走 `lazyEntryLoader(file)()`（STORE 返视图 / DEFLATE 现解，结果不驻留）；**绝不用 `contentOfArchiveFile`**——`ArchiveFile.content` 一次解压即永久缓存 `_content`，逐章取标题会让整本解压结果同时驻留 |
| tamper runner 测试法 | 证明消费方**确实咨询**预取表（而非碰巧同值） | `test/format/dart_epub_source_test.dart`（`_FlatTitlesRunner`） | 预取值派生自同一份字节，正常路径「表值 == 现场解压值」区分不了取值来源 → 继承 `IsolateRunner` 覆写 `run`（`runWithFallback` 虚调），真实解析后把 `EpubStructure` 重建为注入 map：注入「注入标题」断言压过现场解压所得；注入 `{}` 断言 miss 回退 |
| 结果（可复现） | §7.1 结论 3 闭环 | `docs/perf-baseline/README.md` §7.2 | `maxGapMs`：无目录大书 **3996 → 194ms**（−95%）、320 章无目录书 130 → 25、单超长章 96 → 45、20MB TXT 27 → 29（噪声级持平）；**PERF-01 验收①全样本 <1s 达成**；稳态 RSS 不回归（读 50 / 100 章 +1.2 / +0.1MB）。首屏大书 min 3835 → 5602ms：总工作量未变（标题提取整体搬入解析 isolate，链路仍串行），升幅含本机 ~1s 级日间波动（同码 §3 与 §7.1 两表自身即差 ~0.9s）与后台冷堆 GC 成本，属「响应性换墙钟」的可接受交换 |


### 2.20 M2a-T05 — 交付验收：fx12 排版语义 fixture + 全量回归（M2a 收官）

| 项 | 值 |
|---|---|
| 任务 | M2a-T05（M2a 交付验收与回归，§17 M2 判定第 2/6 条 + PERF-01 回归） |
| 提交 | `83b95b4` |
| 日期 | 2026-09-24 |
| 一句话目标 | 验收 fixture 把「排版语义六件套」端到端锁进回归网；全量 400/1 收官 M2a；PERF-01 复核无回归 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| fx12 综合验收 fixture | §17 M2 第 2 条六语义端到端（标题/加粗/换行/表格/插图/脚注；首行缩进为渲染期语义） | `test/fixtures/make_fixtures.py`（`fx12`）、`baseline.json`、`epub_fixtures_test.dart` | 一书六语义：h1→title + 首段去重、`<b>/<i>` 字面保留供 `typeset` 解析、`<br>`→`'\n'` 行内不切段、表格 caption 独立段 + 每 `tr` 一行、`<img>`→`\x00IMG:src\x00`、`<aside id>` 纯标记段并入下一段（`\x00ID:id\x00` 接力） |
| baseline 预期值人工推演 | 防假绿 | 同上 | 「预期每章文本」按 `section_extractor.dart` 语义**人工推演**（生成器注释写明推演链），**不抄实测输出**——实测抄录 = 永远绿的假基线；推演与实测互证（首跑即 124 全绿 = 互证成立） |
| fixture 生成器重生成噪音 | 保持任务级提交干净 | `test/fixtures/*.epub` | `make_fixtures.py` 整体重生成时 `zipfile.writestr` 写当前时间戳 → **全部旧二进制 byte churn**（语义不变、baseline 不变）；新增 fixture 时对旧 fx01~fx11 用 `git checkout --` 还原，只提交新 fixture + baseline.json + 生成器源码 |
| 排版语义落点对照 | 第 2 条逐项验收证据链 | `lib/typography/typeset.dart`（缩进 2 全角空格 / 加粗斜体）、`lib/reader/reader_page.dart:1142`（标题居中，UI 单独渲染标题）、`test/reader/inline_image_test.dart`、`test/reader/link_navigation_test.dart`、`test/epub/section_extractor_test.dart` | 六项中五项既有单测各管一段，fx12 补「一本书全生效」的串联证据；标题居中无独立几何断言（实现行 + 实机目验项），如实入验收记录 |

### 2.21 M2b-T02 — CBZ / CBR 支持（图片页模式 + Q5 退化）

| 项 | 值 |
|---|---|
| 任务 | M2b-T02（`FMT-02`/`FMT-03`、`META-11`） |
| 提交 | `28e66f8`（kTinyPng 夹具修复）、`a7ff34d`（T02 交付） |
| 日期 | 2026-09-24 |
| 一句话目标 | CBZ 每图片页一章（整页竖向滚动 + 点页全屏缩放）；CBR 按 Q5 拍板「导入即拒绝」（同加密文件处理），`RarExtractor` 注入缝留升级路径 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `CbzSource`（`dart-cbz`） | ZIP 图片页包解析（`FMT-02`） | `lib/format/cbz_source.dart` | **每图片页一章**：`Chapter.href` = zip 条目路径（稳定身份 RD-04/SYNC-02）、`title` = `第 N 页` → 进度按页（③）天然成立；`ChapterContent.imagePages([href])` 与 `paragraphs` 互斥命名构造器；封面 = 自然序首页图 `PendingCover(bytes, sniffCoverFormat(bytes))`（`META-11` ①② / `META-05`） |
| `compareNatural` 自然序（自研） | 页表排序防 `10.jpg` 字典序乱页（`META-11` ②） | `lib/format/natural_sort.dart` | 数字段按数值（前导零少者在前 `7`<`07`）、非数字段 ASCII 大小写不敏感、兜底 `compareTo` 全序；混合串内数字段同效（`a2b<a10b`） |
| 非驻留解压（`PERF-02` ①） | 页字节按需现解、绝不整包驻留 | 同上（`lazyEntryLoader(file)`） | DEFLATE 走 `inflateBuffer` / STORE 取视图；**绝不用 `ArchiveFile.content`**（一次解压永久缓存 `_content`）；`resolveEntryName` 大小写不敏感 + 百分号三试探 |
| `image_pages.dart` 共享判据层 | CBZ/CBR 共用图片扩展名白名单 | `lib/format/image_pages.dart` | `isImagePageName`/`kImagePageExtensions` 从 `cbz_source.dart` 抽出——**实现类之间零 import 铁律**，共享判据落中立模块各自 import |
| `CbrSource` + `RarExtractor` 注入缝（`FMT-03`） | CBR 退化与升级分界 | `lib/format/cbr_source.dart`、`lib/platform/rar_extractor.dart` | Q5 拍板（2026-09-24）「导入即拒绝」：默认 `UnavailableRarExtractor.isAvailable=false` → `load()` 抛 `FormatErrorCode.cbrUnsupported`（文案含「转换为 CBZ」）、书不入库；注入可用实现即自动升级为 CBZ 同行为（假实现 `_FakeRar` 测试锁定升级缝），`META-11` ③ 如实记「退化无封面链路、错误单点」 |
| 图片页渲染 + 点页全屏缩放 | 阅读页 `FMT-02` ①②（拍板：点页全屏缩放） | `lib/reader/reader_page.dart`（`_ImagePage`/`_ImageZoomPage`/`_openImageZoom`） | `content.imagePages != null` 分支整页竖向滚动、不走 `InlineParagraph`；`Image.memory` **不设 `cacheWidth`**（不降采样 =「不糊」）；点页 → 全屏 `InteractiveViewer(maxScale: 5)`；「单/双页」（US-12）如实记录未覆盖 |
| 错误文案唯一来源扩充（`RD-05`） | 新错误码中文文案 1:1 | `lib/format/error_messages.dart` | `cbrUnsupported`/`noImagePages` 入枚举与文案表；`unsupportedFormat` 改「当前支持 EPUB、TXT 与 CBZ」；`error_messages_test` 兜底：覆盖/中文/无调试词/无重复口径 |
| **kTinyPng 夹具修复**（顺带闭环既存失败） | 测试图片底座可解码 | `test/meta/meta_fixtures.dart` | 旧 base64 串 **IDAT CRC 损坏 + chunk 结构崩坏**（脚本遍历实证）→ `instantiateImageCodec` 必败；换 zlib 自构造 1×1 RGB PNG（三 chunk CRC 全过）；连带闭环 M1-T09 起挂案的 `cover_store` 缩略图既存失败（缩略图生成解码同因失败） |

### 2.22 M2b-T03 — 格式嗅探与魔数纠偏（FMT-06）

| 项 | 值 |
|---|---|
| 任务 | M2b-T03（`FMT-06`） |
| 提交 | `12879fb` |
| 日期 | 2026-09-24 |
| 一句话目标 | MOBI 系 `BOOKMOBI` 魔数识别压过后缀（验收①）；纯文本改名 `.epub` 取「明确报错」出口（验收②双出口取舍） |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `sniffer.dart` 中立判据层 | 字节判据独立于 `FormatKind` 与实现类（零 import 铁律，同 `image_pages.dart` 模式） | `lib/format/sniffer.dart` | `hasMobiMagic`/`looksLikeZip`/`looksLikeText` 三判据公有化；`book_registry` 的 `_looksLikeZip`/`_looksLikeText` 迁入（分发逻辑与判据分离，判据可独立单测） |
| PalmDB `BOOKMOBI` 判据 | MOBI/AZW3 家族识别（`FMT-06` ①） | `hasMobiMagic` | 偏移 60..68 == ASCII `BOOKMOBI`（type "BOOK" + creator "MOBI"）——tmp_book 真实《牧神记》.mobi/.azw3 **双样本实测互证**；**AZW3 头 8 字节可打印**（PDB name 实测 `epubor.c`）→ 判据必须先于纯文本判定，否则 AZW3 改名 `.txt` 落 txt；截断 <68 字节不误判；非 `BOOKMOBI` 的 PalmDB 落 unsupported（边界声明） |
| `FormatKind.mobi` + `mobiUnsupported` | 已识别但解析未接入的拒绝口径 | `book_registry.dart`、`error_messages.dart`、`import_service.dart` | 口径区分「这是 MOBI，还没支持」vs「不认识的格式」（`unsupportedFormat`）；T05 接入 `MobiSource` 后删 import 拦截即自然落盘 `.mobi` |
| FMT-06 ② 双出口取舍 | 纯文本改名 `.epub` 的纠偏策略 | `sniffFormat` epub 分支 | 验收②「识别为 TXT **或** 明确报错」→ 取「明确报错」：EPUB 解析器给 notZip 可读文案（**诚实报错优先于静默改判**），既有锁 `dart_epub_source_test`「非 zip 字节 + .epub → notZip」不动；若走「识别为 TXT」出口须同步推翻该测试（代码注释已留痕） |
| `sniffer_test` 11 条 | 判据直测 + 验收 + 既有锁回归钉 | `test/format/sniffer_test.dart` | 夹具按真实样本复刻（kTinyPng 教训：不许「号称」）：可打印 name + NUL 填充 + `BOOKMOBI` tag；回归钉：非 zip 二进制 `.epub`→epub、PK 假 zip `.txt`/`.zip`→unsupported、纯文本→txt |

### 2.23 M2b-T08 — 阅读会话采集内核（STAT-01/02）

| 项 | 值 |
|---|---|
| 任务 | M2b-T08（`STAT-01`/`STAT-02`，无 UI） |
| 提交 | `377d171` |
| 日期 | 2026-09-24 |
| 一句话目标 | 活跃事件驱动切会话（空闲 3min）+ 跨 0 点拆天 + 按月分片幂等合并 + 双索引聚合（4 万条 ≤300ms） |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `SessionTracker` 空闲切会话 | `STAT-01` 有效阅读时长采集 | `lib/stats/reading_session.dart` | 时刻由调用方注入（无计时器/IO → 可确定性单测）；空闲**超过** 3min 才切（恰好不切）；前段只计「最后活跃 + 3min 宽限」；`finish` 幂等（不清空事件，可重复调用）；`duration` 整秒下取整、`≤0` 不产出 |
| 跨 0 点拆天 | `STAT-02` ① 按天归属 | 同上（`_midnightsBetween` / `_emit`） | 一段连续阅读按本地 0 点拆多条、各归各 `dayKey`；起止坐标取「边界前最后活跃」（接缝两侧一致，不虚构边界位置）；id = `<startedAt>_<bookId>` 确定性派生（**不含** endedAt/duration → 跨设备同会话同 id，同步不双计） |
| `SessionStore` 按月分片 | `STAT-02` 持久化 | `lib/stats/session_store.dart` | `stats/sessions-YYYY-MM.json`（分片键 = `startedAt` 本地年月）；文件名白名单正则挡 `.bak`/`.corrupt`/`.tmp`；合并**按 id 并集**（同 id 取较大时长）、无变化不重写（幂等无写放大）；坏条目防御式跳过、坏分片隔离 `.corrupt` 不影响他月 |
| `StatsIndex` 双索引聚合 | `STAT-02` ④ 聚合查询 | `lib/stats/reading_session.dart` | `day_key`/`book_id` 两组内存索引 + total，单遍扫描；`tool/stats_bench.dart` 实测 4 万条（≈5 年、61 分片）**loadIndex 126~132ms ≤300ms PASS**、纯聚合 5ms、落盘 merge 940ms |
| `app_paths` 接口/实现拆分 | stats 零平台插件（`STAT-02` ⑤）+ bench `dart run` 可编译 | `lib/platform/app_paths.dart`（纯接口）、`lib/platform/path_provider_app_paths.dart`（实现） | 接口文件不再 import path_provider（只留 `dart:io` 目录类型）；全仓仅 `main.dart` 引用实现类；测试/bench 用临时目录实现 `_TestAppPaths` |
| 弱断言修正（验收抓出） | 防假绿 | `test/task/session_store_test.dart` | 「禁写记录不产生分片」原断言测**从未触碰的 8 月**平凡真 → 换成真正「本会被创建」的月份（8 月 zeroAug 被拒后断言无 8 月分片）；教训：**存在性断言必须钉「本会被创建」的那个对象** |

### 2.24 M2b-T01 前置 — archive 3.x→4.3.0 迁移（2026-09-24）

| 项 | 值 |
|---|---|
| 任务 | M2b-T01 前置（负责人拍板「迁 archive 4.x」，保 pdfrx 2.6.5） |
| 提交 | `64ae658` |
| 日期 | 2026-09-24 |
| 一句话目标 | 消解 `pdfrx_engine → archive ^4.x` 与项目 `archive ^3.6.1` 解算冲突；PERF-02 非驻留解压语义等价保持、错误码同型同码（RD-05） |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `decompress(OutputStream? output)` 非缓存语义 | 4.x 非驻留解压单出口（替 3.x「STORE 取视图 / DEFLATE 走 `inflateBuffer` / 罕见压缩法退回缓存」三分支） | `lazyEntryLoader` | **带输出即不落 `_content` 缓存**（源码实证：`_rawContent!.decompress(output)` 不写缓存，仅无参路径才 `_content = FileContentMemory(bytes)`）——PERF-02 ① 由库原生保证，罕见压缩法不再有「退回缓存」驻留例外；`OutputMemoryStream()` 免参构造 + `getBytes()` 视图出口 |
| 解压幂等双保险 | 闭包多次调用语义 | `lazyEntryLoader` 实证 | `ZipFile.decompress` 对 deflate/bzip2 有 `savePos/setPosition` 读头复位；STORE 分支 `output.writeStream(_rawContent!)` 虽不复位，但 `OutputMemoryStream.writeStream` 用 `setRange`（`stream.position` 只读引用）**不推进源流读头** |
| **4.x 静默解空回归**（教训） | 坏输入契约被库行为变更破坏 | `zip_directory.dart`（库行为） | `ZipDirectory.read` 找不到 EOCD（`0x06054b50`）时**静默 return**（`filePosition = -1`），`decodeStream` 返回**空 Archive** 不抛错（3.x 抛 `ArchiveException`）→ parse 3 条红（坏 zip `corruptFile`→`noImagePages`、非 zip `notZip`→`missingContainer`）；**依赖升级后红测先怀疑库行为变更，断言差异即取证入口** |
| `tryDecodeZip` EOCD 判废守卫 | 收敛回 `null` 出口 | `zip_paths.dart` | `decoder.directory.filePosition < 0 → return null`；误杀面为零（合法 zip——含 0 条目的空 zip——必有 EOCD 记录）；RD-05 同型同码钉死：坏 zip→`corruptFile`、非 zip→`notZip`、缺 container→`missingContainer`、无图片页→`noImagePages`，错误码不得因库行为变更后移 |
| 迁移面收窄承诺与兑现 | 控制回归面 | `zip_paths.dart` 两个辅助函数 | 签名不变（`contentOfArchiveFile` / `lazyEntryLoader`）→ `epub_parser` / `cbz_source` 调用点**零改动**；4.x 映射：`file.content` = `readBytes()` 别名（固定 `Uint8List`）、`compressionType` 整型常量 → `CompressionType` 枚举、`rawContent` `InputStreamBase` → `FileContent?` |
| 依赖锁定终态 | 解算收敛 | `pubspec.yaml` | `archive: 4.3.0`（精确锁）、`crypto: 3.0.7`、`pdfrx: 2.6.5`（Q4① 不可让）、`pdfrx_engine: 0.6.1`（transitive）、`sdk: ^3.13.0`（Flutter 3.47.5）；决定性论据：pdfrx_engine **0.1.0 起全线**（含 0.4.x/0.5.x/0.6.x）硬要求 `archive ^4.x`，无任何「pdfrx 2.6.x + archive 3.x」组合 |

### 2.25 M2b-T01 — PDF 支持（FMT-01 / META-10）

| 项 | 值 |
|---|---|
| 任务 | M2b-T01（`FMT-01` 伪分章 + 连续翻阅 + 缩放；`META-10` 封面渲染第 0 页） |
| 提交 | `d6e6d86` |
| 日期 | 2026-09-24 |
| 一句话目标 | pdfrx 2.6.5 经**注入缝**接入（`Q4 ①`），PDF 表现为「按 N 页伪分章的图片页书」，阅读页零改动 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `PdfEngine` 注入缝 | `META-10` ③ / `Q4 ①` 验收①：`lib/` 内不直接依赖平台渲染 API | `lib/platform/pdf_engine.dart`（纯接口）、`lib/platform/pdfrx_pdf_engine.dart`（**全仓唯一** `import package:pdfrx` 的文件） | 抽象「字节进 → 编码图片字节出」；`PdfEngineDocument{pageCount, renderPagePng(widthPx), pageText, dispose}`；异常收敛为 `PdfEngineOpenException{PdfOpenFailure.encrypted/unreadable}`（第三方异常类型不泄漏到格式层）；`UnavailablePdfEngine` 为默认兜底 |
| 组合根注入 | 免改 `openBook` / `BookRegistry` 签名与全部调用点 | `PdfEngineProvider.current`（main.dart 一行 `= PdfrxPdfEngine()`） | 同款模式：pdfrx 自己的 `PdfrxEntryFunctions.instance`；`PdfSource` 构造仍可显式传 `engine:`（测试用假引擎，不污染全局） |
| pdfrx 关闭路径取证 | `Q4 ④` 密码 PDF 明确拒绝 | `PdfDocument.openData(..., firstAttemptByEmptyPassword: true)` **不传** `passwordProvider` | 需要密码时抛 `PdfPasswordException`（`pdfrx_pdfium.dart:849`）；**空密码可开的所有者加密**（仅限打印/复制）`isEncrypted == true` → 同样拒绝（保守口径；放开只需删一段，格式层与 UI 零改动）；`pdfrxFlutterInitialize()` 幂等惰性调用（首次开 PDF 才发生，不拖冷启动） |
| **render 尺寸坑（必看）** | 渲染长宽比正确 | `page.render(fullWidth:, fullHeight:)` | **两个必须成对传**：只传 `fullWidth` 时源码 `fullHeight ??= this.height` 会按页面 72dpi 高度兜底 → 比例错图；实现里 `fullHeight = widthPx * page.height / page.width` |
| `PdfImage` 非驻留 | `PERF-02` ① | 适配器 `renderPagePng` | `pixels` 是 **BGRA8888**；`encodeBgraToPng(...)` 后 **`finally { image.dispose(); }`**（含异常路径）；`PdfSource` 侧不缓存页字节，每次 `readResource` 现渲染 |
| 手写 BGRA→PNG 编码器 | 让 PDF 页与 CBZ 页对上层的**形态完全一致**（都交 `Image.memory`） | `lib/platform/bgra_png.dart` | 颜色类型 6（truecolor+alpha，B↔R 换位）、每行过滤器字节 0、`dart:io` `ZLibEncoder` 造 IDAT、自实现 CRC32 表；**不引第三方图像库**（不吃新依赖、M3.5 Rust 层也不碰这条链）；行/字节用 `Uint8List` 预分配 + 索引写入（1600×2263 逐像素 `BytesBuilder.add` 会慢） |
| 编码器验证法（可复用） | 防「自证自」 | `test/format/bgra_png_test.dart` | 测试侧写**独立** PNG 解析器（CRC-32 用按位展开，不复用编码器查表）并**先拿既有有效参考图 `kTinyPng` 自检解析器**，再验编码器输出（结构 / IHDR / CRC / ZLib 解回像素逐点比对） |
| 伪分章 N=10 | `FMT-01` ①②（目录按伪分章生成） | `PdfSource._buildChapters`（`kPdfPagesPerChapter`） | 依据：阅读页图片分支是 **Column 急构建**（进章即对每个 `imagePages` 元素发一次 `readResource`），PDF 每页要**现渲染** → N 即并发渲染上界；N=10 → 100 页样本 10 章（对齐验收①）；`href = p{起始页}`（0 基，稳定身份） |
| 页资源键 | 阅读页取图零适配 | `imagePages = ['p0','p1',…]` → `readResource('pN')` | 章身份与页键**同源同命名**（`p10` 既是「第 11 页」也是该页所在章）；非法/越界键 → `null`（不触发渲染）；坏页渲染失败 → `null`（复用图片页分支的缺图兜底，不炸阅读） |
| 封面（`META-10` ①②） | 书架 / 详情页缩略图 | `load()` 渲染第 0 页（`kPdfCoverRenderWidthPx = 512`） | `sniffCoverFormat` 嗅出 PNG → `PendingCover` + `coverOrigin = metadata`；渲染失败 → `NoCover`（展示层按 `META-07` 合成封面而非空白）；渲染宽度用常量区分（缩略图不必渲大图） |
| 错误码映射（`RD-05`） | 同型同码、文案唯一来源 | `PdfSource._prepare` → `error_messages.dart` | 引擎 `encrypted` → `encryptedPdf`（**新增枚举 + 文案 + 测试护栏 1:1**）、`unreadable` → `corruptFile`；空字节 → `emptyFile`（**不触碰引擎**）；`pageCount == 0` → `corruptFile`（不复用含 EPUB 专有名词的 `emptySpine`）；引擎未注入 → `unsupportedFormat`（detail 指明原因，诚实降级） |
| 嗅探与分发 | `FMT-06` 魔数思想的自然延伸 | `sniffer.dart::hasPdfMagic`、`book_registry.dart` | `%PDF`（偏移 0，**从严**不做头 1024 字节搜索）压过一切后缀（PDF 改名 `.txt` 不被纯文本启发式吃掉）；`.pdf` 后缀臂位置在 `looksLikeZip` **之前** → zip/纯文本改名 `.pdf` 交 PDF 解析器给可读报错（同 `.epub` 的「明确报错」口径）；`import_service` 加 `FormatKind.pdf => 'pdf'` 落盘扩展名 |
| **测试教训：异步匹配器必须 await** | 防假红/假绿 | `pdf_source_test.dart` | `expect(() => source.load(), throwsA(…))` **不等待** → 紧随其后的 `dispose()` 先跑 → `_prepare` 落进「打开完成时已释放」的竞态分支优雅返回空元数据 → 断言永远看不到异常（实测 1 条红即此因，实现无误）。修法：`await expectLater(source.load(), throwsA(…))` |
| 验收对照（`Q4` 拍板） | 不满足即不算完成 | — | ①注入式接口：`lib/format/**` 零 pdfrx import，唯一适配器文件为 platform 层；②PDF 文本层：`PdfEngineDocument.pageText`（pdfrx `loadText().fullText`）已备好，T04 实现搜索时消费；③Developer Mode：构建文档待补（T09）；④密码 PDF：`encryptedPdf` 拒绝、无 passwordProvider 链路 |


### 2.26 flutter test 下玻璃弹层的每帧开销（M2b-T06 实证）

| 项 | 值 |
|---|---|
| 现象 | 含 `GlassOverlays.showSheet` 的用例**单跑秒过、整组跑** `TimeoutException after 0:00:30`；计时探针：打开玻璃弹层后 `tester.runAsync` 里一个真实 8ms `Future.delayed` 实测 620–662ms/次，且**随弹层交互累积**（①② 用例跑完后 ③ 才爆） |
| 根因 | `liquid_glass_widgets` 背景捕获路径（`toImageSync` / `OffsetLayer.toImage`）在 `flutter test` **软件光栅**下每帧带数百毫秒真实异步开销。对照实验：同用例把玻璃弹层换成普通 `showModalBottomSheet` → 真实 timer 恢复 8–38ms、慢轮 28s→1.2s，元凶钉死 |
| 修法 | 弹层内异步收敛断言**条件驱动**：循环设上限、满足即 break、每轮用多次 `Future.delayed(Duration.zero)` 让出真实事件循环 + 一次 `pump` 排空假区微任务；**禁固定大轮数**（60 轮必逼近 30s 线，整组并发必炸）；相关用例文件首行 `capTestTimeout()` |
| 附带纪律 | 时序类探针（print 计时）须 `--plain-name` 单跑——整组并发跑 print 被并发测试交错污染 |
| 落点 | `test/reader/bookmark_sheet_test.dart` 验收③ |

### 2.27 `ScrollUpdateNotification` 派发于 layout 之前（M2b-T06 / TYP-09 实证）

| 项 | 值 |
|---|---|
| 现象 | 滚动中进度恒 0：拖 150px 后（`position.pixels` 8→158，滚动确实发生）章块 `top` 仍报旧值 0.0（真实应为 −150），章内位置 `−top/height` 算出 0，进度不动 |
| 根因 | `setPixels` → **同步**派发 `ScrollUpdateNotification` + `markNeedsLayout`，布局在本帧稍后才跑——通知处理器里读 `localToGlobal` 拿到的是**上一帧**几何，「滚动已发生、布局未跟上」的滞后被当成真实位置。`ScrollEndNotification` 时的采样（含写盘语义值）有同型滞后 |
| 修法 | 采样按 `top − (pixels − _laidOutPixels)` 补回滞后；`_laidOutPixels` = 「当前几何所对应的滚动偏移」，`addPostFrameCallback` **帧末**（布局已生效）记录为基线。用 `pixels` 差而非 `notification.scrollDelta`——`jumpTo`/拖动/惯性全自洽（delta 可为 null）；布局突变（占位→真实）不归此管，仍是语义重锚（修 A）职责 |
| 落点 | `lib/reader/reader_page.dart` `_laidOutPixels` / `_buildBlockSnapshots` |

### 2.28 玻璃质量档位生效链（M2b-T07，UI-05 / UI-06）

| 项 | 值 |
|---|---|
| 依赖图（防循环 import） | `perf_prefs_store ← glass_runtime ← glass_scope ← glass_kit ←（业务页 / glass_settings_section）`——映射与生效态的唯一真值 `glass_runtime.dart` 位于**依赖图最底层**，禁止反向 import glass_kit/glass_scope（曾因映射住在 glass_settings_section 且其 import glass_kit 而成环，全家搬进 glass_runtime 解环） |
| 生效链（只会更省、绝不更费） | 用户档位 →「降低视觉特效」强制 `minimal`（`resolveUserTier`，off 短路优先）→ 低端设备钳 `low`（`isLowEndDevice` 注入位；PRD §11.5 无判定标准，探测待拍板、缝已留）→ 帧预算降档（`noteBudgetDegraded`，会话内不持久化）→ `glassTierConfigFor` 折算生效配置 |
| 档位 → 质量映射 | 高：不覆盖（`GlassScaffold` 自动提升 `premium`）/ 滚动区 `standard`；中：钉 `standard` 取消提升；低：全 `minimal`（零着色器）；关：`glassEnabled=false` → Material 纯色退化（`UI-06` ② 功能完整可用）。`scrollQuality` 恒拒 `premium`（构造期 assert，`UI-05` ②） |
| **到底档不得写状态残留（人工推演抓的坑）** | `noteBudgetDegraded` 到底（low→low、off→off）必须**直接 return**：曾写 `_budgetTier = off` 当残留上限 → 用户切回高档被 `min(high, off) = off` 钳死（off 被自动降级「带出」= 违反契约）。回归测试 `glass_runtime_test`「到底档不钉死生效档」两条 |
| `FrameTiming` 测试注入口 | dart:ui 测试工厂 `FrameTiming({vsyncStart, buildStart, buildFinish, rasterStart, rasterFinish, rasterFinishWallTime})`（微秒、全必填），`rasterDuration = rasterFinish − rasterStart`；`package:flutter/scheduler.dart` 已 re-export 可直接 import。`PerfFrameMonitor.simulateTimings` 喂帧、无需真实渲染循环；超预算判据是**严格 `>` 16ms**（恰 16ms 算预算内，测试有边界用例） |
| 钉档测试法 | `GlassScopeProvider(config: glassTierConfigFor(tier))` 显式钉档（测试专用覆盖口）；断言钉档作用域用「`GlassTopBar` 后代 ∩ `GlassAppBar` 祖先」双重限定（`find.descendant` + `find.ancestor` 套用），防撞玻璃库内部同类型 `GlassIsolationScope`（`GlassScaffold` 给条面也包一层 premium 提示作用域） |
| 落点 | `lib/ui/glass_runtime.dart`（映射 + 生效态）、`lib/settings/perf_prefs_store.dart`（持久化 + 策略）、`lib/settings/perf_frame_monitor.dart`（帧触发）、`lib/ui/glass_kit.dart`（唯一消费点 + 关档退化）、`lib/ui/glass_scope.dart`（作用域 + Provider 重建） |

### 2.29 M2b-T05 — MOBI/AZW3 原型探针与 Q25 结论（KF8 入口）

| 项 | 值 |
|---|---|
| 用法 | `dart run tool/mobi_probe.dart`（自动扫 `tmp_book/` 下 `*.mobi *.azw3 *.azw`）或带文件参数；无样本优雅降级 exit 0。**原型基线工具，不入 `lib/`**；实测数字与原始输出入 `docs/perf-baseline/mobi.md`（挂 `9661ba9`） |
| **Q25 — KF8 结构在哪** | **同文件尾部**（PDB records）的 FDST / SKEL / FRAG / GUIDE——魔数实测：FDST=`"FDST"`、SKEL/FRAG/GUIDE=`"INDX"`+TAGX/IDXT（两真实样本全命中）。`fdst/frag/skel/guide` 头字段是 **record 相对索引（基准=boundary）**，实现时须验魔数防坏文件 |
| **Q25 — KF8 入口怎么走** | **双分支都实证**：先 `version>=8` 直入 record 0（纯 KF8/azw3 HIT）；miss 再读 **EXTH 121 boundary** record 重得 KF8 头（combo 文件 HIT：KF6 头 @0 + KF8 头 @boundary，active entry 切到 boundary 后文本记录基准随之切换）。判定顺序即「先直入、后 boundary」 |
| **EXTH 129/131 偏移入口说** | **NOT SUPPORTED，实现不采信**：129 两样本均为 `kindle:embed:NNNN` 封面 URI 字符串；131 = 1（无魔数佐证）/ 缺失 |
| 解压三路 | 1 none 直取（剥尾）/ 2 PalmDOC-LZ77（重叠拷贝语义逐字节保持）/ 17480 Huff/CDIC（位级解压 + 异常输入保护，**代码就位、真实样本未覆盖**，待补样本验证） |
| 口径提醒 | 耗时为开发机（Windows x64）**下界口径**（open 不含 HTML 解析/排版、full 不含清洗/切段），正式判定须 Android 主力机复测；计时对象是 **active entry**（combo 文件 = KF8 头的 `numTextRecords`，非 record 0 头自述值） |
| 落点 | `tool/mobi_probe.dart`（探针）、`docs/perf-baseline/mobi.md`（基线 + 对 T05 实现的规格输入 §5） |

### 2.30 M2b-T04 — 全书搜索双执行路径与阈值 4 基线（CNT-06）

| 项 | 值 |
|---|---|
| 双执行路径 | `SearchSession.start` 按源能力分流：可序列化 `searchSpec`（EPUB/TXT = fileName + bytes）→ 后台 isolate `openBook` 重建源、事件逐条 SendPort 回传（主 isolate 零搜索占用）；句柄源（PDF，`searchSpec=null`）→ 本 isolate 流式（`pageText` 逐页 `await` 让出事件循环）。对外同一事件流语义，`usedIsolate` 观测取证 |
| 协议级取消（RUST-05） | `cancel()` 当帧关本地流 + 反向 SendPort 发 `_kCancel` → 后台置 `CancelToken` 逐章短路 → `Isolate.exit()` 不留后台线程；泵口丢弃迟到事件。**不杀线程** |
| 回落（RUST-01） | 派发失败 / 端口「未 done」提前关闭 → 同一 spec 本 isolate 重建重跑（`_LocalRun(ownsSource: true)` 自建自毁）；业务错误（`MReaderFormatException` 经信封回传）**不**回落；回落事实只写 `dart:developer log` |
| `implements` 默认实现坑 | `BookSource` 的带默认实现方法（`searchSpec` / `totalCharCount`）**不跨 `implements` 继承**——所有 `implements BookSource` 的类必须显式补 getter（cbz/cbr/pdf + 测试假源共 7 处踩坑实证） |
| 高亮后处理 | `highlightSpans`（typeset）对扁平 span **非重叠**切分（与各源 `search()` 计数口径一致）、命中片段叠 `kSearchHighlightColor`（`0x66FFC107` 琥珀半透明，亮/暗主题通用）、recognizer **复制**到子片段保链接可点；`InlineParagraph.highlightQuery` 在 `_buildSpans` 统一收口（快路径与标记路径都过） |
| widget 测试禁忌 | 搜索 widget 测试**禁用后台 isolate 路径**（FakeAsync 不排空 isolate 消息会挂死）：假源 `searchSpec => null` + `SearchSession.start(localSource: …)` 强制本 isolate 流式——`test/search/search_fakes.dart` 头注即契约 |
| 阈值 4 基线 | `dart run tool/search_bench.dart <dir> <fixture> <label> [query] [iters]`（`2b6f05e`）：首屏 = `firstHitElapsed`（含 isolate 往返）、卡顿 = 主 isolate 心跳 `maxGapMs`（含收尾间隔）。实测与根因入 `docs/perf-baseline/search.md`——TXT 20.7MB 首屏 0.45s 达标 / **无 toc 48M 字符 EPUB 4.2s 超标**（flatTitles 全书预解压，`epub_parser.dart:518-523`）/ **心跳法 Windows 本底 15~25ms 不具 16ms 区分力**（UI 帧级判定走 `FrameTiming` 真机口径） |
| 落点 | `lib/task/search_session.dart`（会话唯一收口）、`lib/ui/search_sheet.dart`（面板）、`lib/typography/typeset.dart`（`highlightSpans` / `highlightQuery`）、`lib/reader/reader_page.dart` `_openSearch` / `_startSearch` / `_jumpToSearchHit`、`tool/search_bench.dart` |

### 2.31 M2b-T09 — 真样本目录与端到端冒烟（§17 M2 第 1/3/4/5 条）

| 项 | 值 |
|---|---|
| 样本目录 | `tmp_book/`（`.gitignore` 已含 `/tmp_book/`：「开发期真实书籍样本，多格式测试用，不入库」）。真实出版物由人放入，生成样本由工具产出；**干净 checkout 无此目录** |
| 样本生成器 | `tool/gen_real_samples.py`（**纯 Python 标准库、不联网**，与 `test/fixtures/make_fixtures.py` 同纪律）：自造真结构 PDF（FlateDecode 内嵌 DeviceRGB 位图 + Helvetica 文字层、xref 可定位）与真结构 PNG→CBZ（自然序命名、混合大小写扩展名、`ComicInfo.xml`/`__MACOSX/` 干扰项、大图页）；并补 EPUB3(nav)/EPUB2(ncx)/无 nav 与 UTF-8 卷章 / GBK / 超长单章 TXT。运行 `python tool/gen_real_samples.py`（`--list` 只列清单） |
| 冒烟测试 | `test/format/real_samples_smoke_test.dart`：`openBook → load → chapters → content(0) → readResource`；另用**真书正文派生查询词**跑一次 `BookSource.search` 作第 3 条辅助证据。**无 `tmp_book/` 时整组 skip**（不红、不阻塞全量） |
| PDF 真渲染开关 | 默认**只校验路由**（样本是否被判为 PDF 并交 `PdfSource`）——无头 `flutter test` 可能加载不到 pdfium 原生库；要真开页设 **`MREADER_REAL_PDF=1`** 再跑本文件，或**在 App 内人工冒烟**。该文件 `main()` 首行调 `capTestTimeout()`（30s 兜底防原生挂起拖垮全量） |
| TXT 分章阈值（生成样本必读） | `_longGapChars=1000` / `_shortGapChars=100`：**与上一标题间隔 > 1000 字才算正式章**，间隔 < 100 字反被记为「疑似卷」并可能**否决整条规则**。故代表性 TXT 样本每章正文须 > 1000 字（≈40 个段落），否则整本退化成单章（本批实证：84 字/章 → 1 章；1160 字/章 → 规则命中、正确分章） |
| 落点 | `tool/gen_real_samples.py`、`test/format/real_samples_smoke_test.dart`、`docs/acceptance-M2b.md`（§17 对照 + 五平台冒烟备料）、`docs/build-windows.md`（Developer Mode 闭环 `Q4 ③`） |

### 2.32 M35-T01 — 加速层脚手架与回落骨架（纯 Dart 零 Rust）

| 项 | 值 |
|---|---|
| 任务 | M35-T01（`RUST-01` 探测回落协议；架构 §A 能力抽象 / §F 统一后台任务 / §J.3 任务号） |
| 提交 | `187b5ad` |
| 日期 | 2026-09-28 |
| 一句话目标 | 把「有没有 Rust 加速」变成一个**可探测、可回落、上层无感**的三态量；本批**零 Rust 代码、零 Rust 依赖**，是 T02/T03 的共同地基 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 三态探测（§A.2） | 「未探测 / 可用 / 不可用」不可用 `bool` 表达 | `HighPerfRegistry._probeOk`（`bool?`） | `null` = 未探测、`false` = 已定型不可用、`true` = 可用；`warmUp()` **幂等**（重复调用只探测一次，`probeTimeout = 3s`）；`has()` / `reasonFor()` / `describe()` 只读三态，**不做探测** |
| 探测失败 5 情形（§A.3） | 失败原因必须可区分（否则无法诊断） | `HighPerfException`（`HighPerfErrorKind` 分**调用期 6 值**与**探测期 4 值**两组） | ①未编译 ②符号缺失 ③**版本不匹配**（比对 `kRustAbiVersion`，唯一可靠哨兵）④平台不支持（`kRustSupportedPlatform` 编译期短路）⑤**首次调用失败**——⑤**不翻转** `probeOk`，靠 `noteFailure()` 累计 `kHighPerfFailureStreakLimit = 2` 次才惰性降级该能力（冷启动一次抖动不该把加速层关掉） |
| 强制纯 Dart 开关（§A.5） | 调试 / 排查现场问题 | `kForcePureDartFromEnvironment`（`--dart-define MRUN_FORCE_PURE_DART`）> `HighPerfRegistry.debugForcePureDart`（隐藏设置项）> 默认探测 | 优先级写死在 `fromEnvironment()` 一处；`HighPerfRegistry.fallback()` 是**共享只读常量实例**（`static final _pureDartFallback`），避免每次回落都建新对象 |
| 组合根注入缝 | 上层零感知 | `HighPerfRegistryProvider.current`（同 `PdfEngineProvider` 模式） | UI / 业务层**不得出现任何「是否为 Rust」的分支**；`BookRegistry({HighPerfRegistry? highPerf})` 走**构造注入**（默认回落 `Provider.current`），`capabilityFor(FormatKind)` 给出格式 ↔ 能力映射，`open()` 本批**保留纯 Dart 实现**、注释写明 T04 在此插入 `has(...)` 择一 |
| 文案隔离 | 用户可见文案唯一来源仍是 `RD-05` | `lib/highperf/high_perf_error.dart` 文件头 | 探测期 4 类原因（`kHighPerfProbeReasonZh`）**永不接 UI**，只进日志 / 诊断；`HighPerfException.toString()` 只吐 `messageZh`，**不泄漏 `detail`** |
| 统一后台任务抽象（§F） | Rust 版与 isolate 版**同一套调用面** | `lib/task/background_runner.dart`：`BackgroundRunner` / `BackgroundTask<T>` / `TaskContext` / `TaskHandle` / `TaskRunnerRegistry` | `TaskContext` 把「取消 + 进度」做成**注入的协作者**（`TaskCancelSignal` / `TaskProgressSink`）而非 Stream——**isolate 内拿不到持 `StreamController` 的句柄**，这是相对 §F 原型的显式偏离；`TaskHandle.progress` 是**广播流、不重放**（订阅前发的事件收不到，契约写进文档注释） |
| 「同步后端丢首个进度」的坑 | 防测试与真机误判 | `runTaskLocally()` | `SyncBackgroundRunner` 若**同步**跑任务体，会在 `start()` 返回前就发完全部进度 → 调用方 `start(); handle.progress.listen(...)` 永远收不到第一帧（实测 `Bad state: No element`）。修法：`scheduleMicrotask` **让出一轮微任务**再跑任务体 |
| isolate 后端的泛型转型坑 | 防派发期类型错误 | `IsolateBackgroundRunner` + `IsolateBackgroundTask.dispatcher` | 后端只持 `BackgroundTask<T>`（拿不到具体消息类型 `M`），`is IsolateBackgroundTask<Object?, T>` 判型后 `M` 被**协变提升为 `Object?`**，与真实运行时函数类型不符 → 必须由 `IsolateBackgroundTask` **在定义处**暴露 `dispatcher`（本实例真实类型实参）完成转型，后端只用 `task.dispatcher` |
| isolate 后端的取消与收尾 | 不留线程、不误报失败 | `_start<T>()`：progress/done/exit 三端口 + `kIsolateProgressThrottle = 100ms` 节流 + `kIsolateExitGrace = 200ms` 宽限 | 取消 = `Isolate.kill(immediate)` + `backendCancelled()`（**协议级取消，不留后台线程**）；`exitPort` 宽限兜「意外退出」；`spawn` 的 `onError` → 回落 `runTaskLocally`（诚实降级，结果与从未接过 isolate 一致） |
| 测试「状态钉」 | 防 T04 落地时忘记改写 | `test/highperf_registry_test.dart` | 有一条**故意钉住 T01 阶段行为**的用例：「探测通过也不改分发结果（Rust 源属 T04）」——T04 真正接入 Rust 源时**必须改写该用例**，否则它会变成假的护栏 |
| 验收对照 | 不满足即不算完成 | — | ①零 Rust：`lib/highperf/**` 无任何 Rust/FFI import、`flutter build`/`test` 不依赖 cargo；②三态 + 幂等 `warmUp`；③强制纯 Dart 开关三级优先；④`describe()` 可观测；⑤上层零分支（`BookRegistry.capabilityFor` 是唯一映射点） |


> **本批未做（属 T04 / T05，如实登记）**：`RustEpubSource` / `RustTxtSource` / FFI 引擎（`lib/highperf/ffi/**`）/ `rust_background_runner` 属 **T04**；`RUST-10` 设置页两项开关的 UI 与持久化属 **T05**。本批 `HighPerfCapability` 只冻结**能力声明与枚举**，各能力的真实方法由 T04 增补。

### 2.33 M35-T02 — 门槛基线测量基建与六项候选结论（先测后引）

| 项 | 值 |
|---|---|
| 任务 | M35-T02（`RUST-06`；PRD §15.6.2/§15.6.3 阈值表；架构 §H 测量协议 / §H.4 三段式判定） |
| 提交 | （见本批 docs 提交） |
| 日期 | 2026-09-28 |
| 一句话目标 | 把「上不上 Rust」变成**可证伪**的：阈值先是数字（照抄 PRD）、判定只有一处实现、结论（**含「不上 Rust」**）必须留档 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 阈值表的**唯一机读来源** | 防「门槛拆松 / 焊死」与手抄漂移 | `test/perf/threshold_judge.dart::kThresholdSpecs` | 5 行**逐字照抄** PRD §15.6.3（3s / 800ms / 800ms / 1.5s / 10s），含 `condition` 原文、`basis` 取值依据、候选 2 的 `scaleLimit`（50MB 口径 2s）与 2b/3/5 的**前置条件**；调整阈值**必须同步改 PRD**（`Q22`：只许调一次且必须写回文档）——测试逐条钉住，改代码不改 PRD 会红 |
| §H.4 三段式的**唯一实现** | 「780ms vs 800ms」只能有一个答案 | `judgeDuration()` | `M < 阈值` → `under`（不上）；`阈值 ≤ M ≤ 阈值×1.1` → `borderline`（临界·暂不上，进观察名单）；`M > 阈值×1.1` → `over`（允许上）；`kBorderlineFactor = 1.1` 写死。`allowsRust` 只对 `over` 为真（`RUST-06` 反向硬约束：未超阈值**不得**实施） |
| 留档 schema | §H.2 固定字段 + 机读 | `BaselineRecord` | `{capability, device, os, samples[], median, min, max, p90, bytesInMemory, peakMemBytes, conclusion}` 逐字对齐，另补 `thresholdNo`（`RUST-06 ⑤` 要能指出阈值编号）/ `verdict` / `judging`（§H.3 桌面标 `false`）/ `scale` / `coldReadMs` |
| **`coldReadMs` 必须进 schema**（首跑踩坑） | 「有没有测冷读」要**机读** | `BaselineRecord.coldReadMs` + `toJson()` | 首跑只把它写进 `notes` **人话**里，于是 harness 打印永远是 `null`（`json['coldReadMs']` 取不到）——留档字段必须是字段，不是文本 |
| 测量协议（§H.1） | 让数字可比、可复现 | `test/perf/baseline_harness.dart` | 计时对象 = 纯解析入口（`load`/`chapters`/`content(i)`），**从「bytes 已在内存」到 `return`**：①IO 排除（另测一次冷读作参考、不参与判定）②含解压③不含渲染④`N = 7` 取中位数 + min/max/p90⑤预热 1 次不计入⑥**判定只用中位数**；`dispose()` 放计时外（生命周期收尾不是解析工作） |
| 测量专用 runner | 把「算法」与「派发成本」分开 | `_LocalRunner extends IsolateRunner` | `PERF-01` 后解析在后台 isolate，公开入口含**建销成本**；阈值测的是算法 → 测量时把派发换成现跑（复用既有 `runner` 注入缝，**不改产品代码**）。**候选 4 例外**：阈值 4 的口径就是真实用户路径（含建销与协议开销），那里**不换** runner |
| 成本边界与**本实现暴露的口径缺陷** | 合计口径的前提必须写清楚 | `baseline_harness.dart` 文件头 + 合计组 `notes` | §15.6.2 处置 4：2a = zip + container/OPF → 骨架；2b = 各章 XHTML → 段落；合计才对。**但无目录书的 2a（`load()`）内含 `flatTitles` 预取**（逐章解压 + XHTML 解析，2b 性质）→ 「2a+2b」对无目录书**高估**（该量被算两遍），**不是早前以为的「中性重叠」**。实测坐实：无目录 `big_bodies` 2a = 7853ms，而有目录真书 2a = **40ms**（同口径差 200 倍，只可能来自逐章 XHTML 解析） |
| 口径缺陷的**无条件下界** | 让 over 结论不依赖有缺陷的口径 | 合计组 `lowerBound = 2b 分层值` | 2b 的测量**只计 `content(i)` 循环**（`chapters()` 已在外层调用并被缓存）→ 它等于真 2b；又因真 2a ≥ 0，故 **真合计 ≥ 2b 分层值**。下界自身已越死区 → 结论里写「**over 与口径无关**」；仅上界越死区 → 写「**over 依赖上界口径，必须补有目录大样本复核**」（`RUST-06` 的开工纪律） |
| **零命中 ≠ 达标**（首跑踩坑） | 防假结论误导 gate | 候选 4 分组守卫 | `SearchSession.firstHitElapsed` 零命中时为 `null`，harness 记 `-1`；而 `-1 < 1500ms` 会被三段式判成 **`under`（不上 Rust）**——**根本没测到东西却给出「达标」**。守卫：任一样本 < 0 → 整条改判 `notMeasured` |
| 真实脏书搜索词派生（首跑踩坑两处） | 不冻结作品专有词，又要**必然命中** | `_queryFor()` + `_longestHanRun()` | ①首跑把 `IMG:OE` 当查询词——首章是图片页，`extractSection` 对图片产出**占位符**；故**只取纯汉字连续段**（U+4E00–U+9FFF，纯 ASCII 写法判区间）②`content(i)` 在 `chapter.locate` 非空时走**片段**抽取，而 `search()` 一律走**整节**抽取 → 只取 `locate` 为空的章，两条路径同源、派生词必然可命中 |
| 生成样本的搜索词表 | 与既有 `search.md` 读数可比 | `_generatedQueries` | 每个词必须**真的在该样本正文里**：`long_chapter.epub` 生成的是「第N段字字字…」（无「第N章」前缀），沿用大书的「第1章第1段」会零命中（首跑实证）→ 单独给词 `第1段`；**表里没有就不测**，不猜 |
| 自带的用例超时 | 不依赖调用方记得传 `--timeout` | `kBenchTimeout = Timeout(5min)` | harness 是重任务（7 轮 × 全书解压 + 8 次完整后台搜索，本机约 6 分钟）；默认超时不够（`test_config.dart` 已记：CLI 默认值会被显式值压过）→ 写死在用例上。**整组默认 skip**（`MREADER_PERF_BENCH=1` 才跑），不拖慢 `reader` 分组回归 |
| 结果落盘 | §H.2 要求人工 commit，但不必手抄 | `MREADER_PERF_OUT` | 置位时落盘信封 JSON `{generatedAt, device, os, judging, fixtures, records[]}`，stdout 仍逐条打 `BASELINE_JSON{...}` + 人类可读行；**commit 仍由人做**（自动落盘只为免去抄错） |
| 脏书容错 | 一个解析不了的样本不该毁掉整轮 bench | 各分组 `try/catch` + `_emitMeasurementFailure()` | 失败如实记成 `notMeasured` 记录（含异常类型与文本），**不中断整轮**——bench 的产物是数据，不是绿测 |
| 结论（桌面哨兵口径，`judging: false`） | `RUST-06 ④`「未超阈值也是交付物」 | `docs/perf-baseline/thresholds.md` | 阈值 4 无 toc 大书搜索 **5.09× 越阈值**；阈值 2 合计真书 **1.77× 越阈值（下界无条件成立）**、50MB 样本 **15.5s**；阈值 3 生成 20MB TXT **1.08× 临界**；候选 1/5 未测（解析器属 M4 / 基线待 AI）**如实登记**。**正式判定须 Android 主力机复测**（§H.3 桌面快一个数量级，用它判定会「永远测不过」） |

> **本批未做（如实登记，非遗漏）**：①`test/perf/rust_harness.dart`（§H.2 列的「Rust 实现测量，无 Rust 时 skip」）**留到 T03 gate 通过后由 T04 补**——Rust 侧入口尚不存在，先写只会是猜测（工程约定：「规格引用第三方 API / 脚手架结构先读真实源码再下笔」）；②任务书文件列里的 `lib/format/dart_epub_source.dart` / `dart_txt_source.dart` **经核查无需改动**——测量所需的入口（`load`/`chapters`/`content`）与注入缝（`runner`）都已存在，本批零产品代码改动（该列系排期前的预估，实测未成立）。

### 2.34 仓库行尾策略（`.gitattributes` 拍板 CRLF，2026-09-28）

| 项 | 值 |
|---|---|
| 事项 | 待决策 #1「仓库无 `.gitattributes`（`core.autocrlf=true`，文档 LF 约定冲突）」闭环（`docs/进度表.md` §四） |
| 提交 | `a0c7c71` |
| 日期 | 2026-09-28 |
| 一句话目标 | 把「行尾」从**机器本地配置的隐含行为**（`core.autocrlf=true`）变成**仓库里可读、可审、可随 clone 继承的策略** |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| **`eol=crlf` ≠ 索引里存 CRLF**（最先要讲清的一条） | 防把「规则没生效」当结论 | `.gitattributes` 文件头（写进注释） | `eol` 只作用于**工作区**；决定「提交时归一化为 LF 存入 blob」的是 `text` 属性。故 CRLF 策略下**索引永远是 LF**、工作区才是 CRLF。唯一权威自查口径 = `git ls-files --eol`（`i/` 索引、`w/` 工作区、`attr/` 命中的属性，期望文本文件为 `i/lf w/crlf`）。**别用** `git grep $'\r$'` / `od -c \| grep -c '\r'` 判定——索引里根本查不到 CR，结论会与事实自相矛盾 |
| 覆盖顺序 | 让「默认 → 例外」的写法安全 | 文件结构 | 后写的规则覆盖先写的：先 `* text=auto eol=crlf` → 再二进制 → 再脚本/文档例外 |
| 二进制例外 | 防 git 对二进制做行尾转换与文本 diff | `*.png` / `*.epub` / `*.ico` 等 → `binary` | `binary` 宏 = `-text -diff`。**可核对的写法**：显式声明的三类（png 30 + epub 15 + ico 1 = **46**）必须**正好等于** `git ls-files --eol` 里 `i/-text` 的计数——不等就说明漏声明或有未预期的二进制混进来。未显式声明的二进制靠 `text=auto` 的内容嗅探兜底 |
| **shebang 脚本必须 LF**（硬约束，非风格偏好） | CRLF 让 `#!` 行解析失败 | `*.sh` / `*.bash` / `*.py` → `text eol=lf` | 首行会变成 `#!/usr/bin/env bash\r` → Git Bash 执行直接 bad interpreter。用**通配符**而非逐文件，覆盖后续新增脚本。**既存隐患实证**：规则落地时发现 `test/fixtures/make_fixtures.py` 工作区本来就是 CRLF——因为它一直是以 `python x.py` 方式被调用（Python 容忍 CRLF），从没人直接执行过它，所以一直没暴露 |
| 文档例外（既有工程约定的延续） | 不顺手推翻已定约定 | `*.md` / `*.mermaid` / `docs/**` → `text eol=lf` | 「文档 UTF-8 无 BOM / LF / 结尾换行」是仓库既有工程约定（含 `docs/perf-baseline/*.json` 留档机读记录）→ 落地时**显式延续**，而非默认继承 CRLF。负责人 2026-09-28 明确「保持 LF」。若要改，删掉该节即可（文件内有对应注释） |
| 索引**不需要** renormalize | 免做一次无意义的全量重写 | — | 因 `core.autocrlf=true` 早已把索引归成 LF，且 `eol=crlf` 的 blob 也是 LF → **索引与规则天然一致**，`git add --renormalize .` 是纯 no-op（不产生提交）。改动面只在**工作区** |
| 「不翻新现存工作区」这个决定 | 把影响面收到最小、可延后 | 负责人 2026-09-28 拍板 | 落规则后 197 个文本文件工作区仍 LF、72 个仍 CRLF——**行为与之前完全一致**（警告也照旧），规则自下次 clone / checkout 生效。若要立即统一，等价操作是「清空索引 → 从 HEAD 重检出」：`git rm --cached -r -q . && git reset --hard`（要求工作区干净；索引 blob 不变 ⇒ **不产生提交**、`git status` 保持干净） |
| 改动前的**破坏性预检** | 「改行尾会不会弄红测试」必须在改之前答完 | 本批核查（逐项） | ①`appearance_sheet_test.dart` 对 `pubspec.yaml` 用 `RegExp(r'^\s*fonts:', multiLine: true)`——CRLF 不影响 ②`test/fixtures/baseline.json` 走 `jsonDecode`——CRLF 是合法空白 ③**`lib/` 与 `tool/` 内没有任何「读自身源码做文本断言」的地方**（全仓唯一 `readAsString` 是 `json_store.dart` 读运行时数据）⇒ 判定「行尾翻新不会打破任何测试」 |

> **未做（如实登记）**：①**未翻新现存工作区**（负责人拍板，理由见上）；②未处理 `w/crlf` 中属于「属性为 CRLF 且本来就是 CRLF」的 70 个文件（它们与规则一致，无需动作）。

### 2.35 开书 / 滚动链路耗时日志（`[perf]`，真机诊断用）

| 项 | 值 |
|---|---|
| 事项 | 真机反馈「打开大书（如绍宋，700+ 章）到深章节（428 章）非常慢」——先埋点取数，再定优化 |
| 日期 | 2026-09-28 |
| 一句话目标 | 把「慢」从体感变成**逐段毫秒数**：跑一遍真机 logcat，直接看出秒级耗时花在哪一步 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `lib/diagnostics/perf_log.dart`（零依赖、纯 Dart、可进 isolate） | 全项目唯一打点出口 | `PerfLog.step`（耗时）/ `PerfLog.mark`（瞬时）/ `PerfLog.watch`（Stopwatch 薄封装） | 纯层（`lib/format/**` 等）可直接用——`print` 是 `dart:core` 非 Flutter API；**产品逻辑不得依赖它**（只许观察不许分支）。内存留档 `PerfLog.records` 环形上限 500；`--dart-define=MREADER_PERF_LOG=false` 整体静音 |
| 输出通道 | 真机零工具读取 | `print` → stdout → Android logcat `I/flutter` 行 | `adb logcat -s flutter \| grep '\[perf\]'`；后台 isolate 内的 `print`（如 `txt.prepare`）**同样落 stdout**，与主线程打点混排在同一条时间线 |
| **首行 `session product=`** | 读数前必看 | 自动打在第一条 `[perf]` 前 | `product=false` = debug/profile（JIT + 断言，普遍比 release AOT **慢数倍**）、`true` = release。**debug APK 测出的耗时不能当产品结论**——先确认构建档位再归因 |
| 行格式 | 可 grep、可肉眼扫 | `[perf] <名字> <ms>ms  k=v k=v …`；瞬时事件无 ms 段 | 名字即链路段：`open.*`（书架读字节/嗅探）→ `reader.*`（load/chapters/stores/firstBatch/ready/content/seed 分支）→ `restore.*`（begin/逐帧 step/收敛 end）→ `autofill.*`（逐批+总）→ `layout.*`（重锚/占位高刷新）→ `nav.*`（跳章）→ `txt.*`/`epub.*`（解析源内部分账） |
| 解析源内部再分账 | 区分「解码」vs「分章」vs「标题预取」 | `txt.prepare`（decode/analyze 分列 + chapters 数）、`txt.analyze`（**命中的规则名** + 章数）、`epub.parse`/`epub.bind`（后台结构 vs 主 isolate 绑定）、`epub.flatTitles`（无目录书全书标题预取，已知大户） | `txt.analyze` 的 `chapters=` 直接回答「这本书被切成多少章」；`epub.flatTitles` 若出现秒级 = 命中挂账 #6 的无 toc 大书路径 |
| 恢复校正逐帧打点 | 直接看出「深章节落点」在哪一步打转 | `restore.step frame=n kind=estimate\|chapter\|para delta=…` | `kind=estimate` 连续多帧 = 目标章一直没进布局窗口（`maxScrollExtent` 外推估计的振荡形态）；`restore.end converged=false` = 校正放弃（`RC1` 闸门关闭不写盘） |

> **桌面参照（2026-09-28 一次性探针，`product=false`，`tmp_book/` 真实 7.7MB TXT / 762 章）**：
> `open.readBytes` 17ms（7.9MB）→ `txt.prepare` **265ms**（decode **247ms** + analyze 18ms，`rule=目录(去空白)`，
> 762 章）→ `reader.content`（第 457 章）**0ms**。结论预读：**数据面开书成本 ≈ 全书解码 + 分章一次性成本**，
> 与「停在哪一章」无关；深章节的额外慢若有，只能出在**恢复校正 / 占位补齐的 UI 链路**（`restore.*`/`autofill.*`/`layout.*`）
> 或 **debug 构建档位**上——真机 logcat 按上表逐段对号即可定位。

### 2.36 恢复落点根因与「章高模型」修复（2026-09-28 真机日志驱动）

| 项 | 值 |
|---|---|
| 事项 | 真机「打开绍宋（447 章 EPUB）到 428 章非常慢」——用 §2.35 的日志定位并修复 |
| 提交 | `2cc2fda`（埋点）+ `84cfd3b`（用法留档）+ `032489a`（修复 + 测试） |
| 一句话结论 | **慢的不是解析**（`reader.ready` 仅 160/67ms），而是**恢复落点在 `maxScrollExtent` 比例外推上 8 帧空转**（`converged=false`，遮罩 1248ms，且没落到目标章） |

**真机日志读数（`perf-log.txt`，两次开书同型）**

| 段 | 实测 | 判读 |
|---|---|---|
| `open.readBytes` | 24ms / 15ms（4430KB） | 磁盘无关 |
| `epub.parse` + `epub.bind` | 118+6ms（冷）/ 36+7ms（热），447 章有 toc | 不走 `flatTitles`，解析不慢 |
| `reader.chapters`/`stores`/`firstBatch` | 14 / 4 / 10ms | 均正常 |
| **`reader.ready`** | **160ms / 67ms** | 数据面开书 <0.2s |
| **`restore.step`** | **8 帧全 `kind=estimate`**；`jumpTo`/`maxExtent`：199534/214009 → 562003/602772 → **1057168**/**1133858** → 658422/706186 → 1003635/1076441 → 658422/706186 → 1003635/1076441 → 658422/706186 | **← 根因** |
| `restore.end` | `frames=8 converged=false sampled=false` | 未收敛 → `RC1` 闸门关（**进度不写盘**）+ 遮罩白等 1248ms |
| `layout.reanchor` | 9 次 `anchored=false`（`autofill` 抢在首次 restore 前，控制器还没建） | 次因：恢复期总高被改、重锚全部落空 |

**根因链**：目标章未进布局窗口 → `_chapterPointOffset` 恒 `null` → 退化为 `maxScrollExtent × (index+pos)/total`；而 **`maxScrollExtent` 在懒构建下是「已构建子项均值 × 剩余项数」的外推值**——本工程布局是「少数真实章（数千 px）+ 大量等高占位块（480 px）」的混合体，`autofill` 的 ±12 真实章一混进构建窗口，该外推就在 **5 倍量级**（214K ↔ 1133K）摆动 → 估算落点**来回乱跳而非单向逼近** → 8 帧耗尽仍拿不到目标章。（放大器：`_refreshEstimatedHeight` 只测「已加载章」的 box，而那 30 章不在构建窗口 → 高度列表为空直接 return → `_estimatedChapterHeight` 全程停在初始 480。）


**修复（两处，见 `032489a`）**

| 修法 | 落点 | 关键机制 |
|---|---|---|
| **A 章高模型** | `_chapterHeights` + `_chapterTopModel` / `_chapterHeightAt` / `_captureBuiltHeights` | 模型口径与真实布局**逐项一致**：未加载章渲染的就是占位块（高度已知）、已构建真实章写回实测高；**唯一未知量 = 已加载但从未构建过的章**——首帧批次只载「目标章 ±1」故 ≤1 章 ⇒ 误差上界一章高度。seek 只瞄准**章首**（不含 `pos`），落到章内即可测 box，`pos` 留给下一帧实测精确校正（避免章首被顶出构建缓存区导致 box 反而不建） |
| **B 补齐时序** | `_open` / `_goToChapter` / `_jumpToLink` | 不再抢跑后台补齐，统一由 `_finishRestore` 触发（**先落定、后补齐**）——恢复期布局不动，消除 9 次空重锚与总高突变 |
| 打点改名 | `_restoreStep` | `kind=estimate` → `kind=model`（真机复跑时用 `kind=model`/`kind=chapter` 与帧数直接判定是否收敛） |

**测试调整（前提被修复消除，必须同步）**：旧「回归②：恢复未收敛期间零落盘」靠「8 帧不收敛」构造前提，修复后该前提不再成立 →
改写为**回归②「深章节恢复必须收敛并写回语义坐标」**（同一 fixture：20 章、仅 `[4,5,6]` 可载、下标 4 为真实长章；
断言目标章标题/正文进树 + 存档坐标回到 0.5±），并新增**回归②b「恢复校正未落定即关书 → 一次都不写盘」**
（用「轮询到遮罩在位 = 校正进行中」抓中间态，保住 `RC1` 闸门覆盖）。

### 2.37 文档-现实脱节回填：Flutter 3.47.5 / 玻璃库 1.7.0 / `archive` 4.3.0（2026-09-28）

| 项 | 值 |
|---|---|
| 事项 | 版本事实回填 + 「被侧向推翻的定案」复核——把「文档写的」对齐「实际跑的」 |
| 触发 | 讨论「要不要自绘 canvas / 能否参考 567Reader 提速」时核查引擎事实，**用户当场指出「Flutter 现版本已经是 Impeller」** → 顺着查 `project.dart` 才发现文档与实机差了三个小版本 |
| 提交 | `3c559b8`（文档回填本体；本条 hash 回填见其后的补提交） |
| 一句话结论 | 5 份文档共 **22 行**（版本字面量 **34 处**）过时；**最严重的一处落在 ★GATE★ 的判据上**（`M35-T03` / `Q20` / `R2` / 架构 `L4` 把 Cargokit 验证对象写成 3.44.9，实机是 **3.47.5**） |

**三处独立脱节（不是同一个错的三种表现，必须分开处置）**

| # | 脱节 | 事实 | 处置 |
|---|---|---|---|
| 1 | **版本引用**：**22 行 / 34 处**字面量写 `3.44.9` 或 `3.12.2`（`c7ca534` 版本上程序化点数：PRD 12 / architecture 8 / tech-usage 7 / schedule 3 / README 4） | 实机 Flutter **3.47.5** / Dart **3.13.4**（2026-09-24 升级；`pubspec.yaml:6-9`、`bin/cache/flutter.version.json` 双复核） | 本次全量回填；`CHANGELOG.md` 此前**零记录**，一并补记 |

> **计数口径（必须写清，否则数字无法复核）**：上表「22 行」= 含该字面量的**行数**（`grep -c`），「34 处」= 字面量**出现次数**（`grep -o | wc -l`，同一行含两个版本号则计 2）。两者**不等**属正常。
> ⚠️ **勘误**：本轮回填的**前一轮**手数记的是「4 份文档共 24 处」（PRD 8 / tech-usage 4 / architecture 5 / schedule 3）——**该数字不准**：① 漏了 `README.md`；② 分文件数值与程序化点数不符。**以本节的 22 行 / 34 处为准**。
> **刻意不改的部分**：`pubspec.yaml` 顶部与玻璃依赖处的**演进注释**（「为解锁 pdfrx 2.6.5 由 3.44.9 / 3.12.2 升上」「原针对 1.6.2 实测」）、`CHANGELOG.md` 的**历史条目**（2026-09-21 段 M1-T08 三条：1.6.2 接入 / 精确锁定 / 升级 1.7.0）、`docs/perf-baseline/` 与 `.workbuddy/` 下的**存量留证**（日志、报告）——这些是**当时事实的快照**，改掉反而破坏可追溯性。
| 2 | **被侧向推翻的定案**：PRD §16 `Q3` 仍标 🟡「本期不升级，接受 Windows 走 Skia 轻量路径」 | 实际**已升级**——但它不是按 `Q3` 自己立项走的，而是被 **`Q4` PDF 选型链侧向推翻**（`pdfrx 2.6.5` 需 Flutter ≥3.47 / Dart ≥3.13；`pdfrx_engine` 0.1.0 起**硬要求 `archive ^4.x`**） | 按项目「推翻定案」流程**完整改写**：原定案 / 决定性论据 / **未被推翻的部分** / 代价已发生 —— 四段俱在，状态改 ✅ |
| 3 | **★GATE★ 判据版本错**（**最高优先级**）：`M35-T03` / `Q20` / `R2` / 架构 `L4` 均写「Cargokit × Flutter **3.44.9** 未验证」 | 实机 **3.47.5**，**且距已知修复边界（≥3.32）比 3.44.9 更远** | 四处全部更正为 3.47.5。风险**性质**不变、**级别不改**（🟡），但**验证必要性只增不减**——已写进 `R2` 的应对栏 |

**连带发现（顺手一并修正，均属事实性错误）**

| 项 | 原文 | 实际 |
|---|---|---|
| `archive` 版本约束（**共 5 处**：PRD §15.4、`README` 依赖表与故障速查、`tech-usage` §1 技术栈总览与 §2.0 初始化表、`architecture-rust-integration` §现有依赖声明） | 「本项目**必须锁 3.x**，4.x 的 `ArchiveFile` API 不兼容」／「**固定在 3.x**」／「`archive` **锁 3.x**（4.x 改 API）」 | `archive: 4.3.0`（2026-09-24 迁移 `64ae658`）——**是 `pdfrx_engine` 硬要求 `^4.x` 逼出来的迁移**，「锁 3.x」全部作废。⚠️ **首轮 grep 只抓到 1 处**：另 4 处写的是「锁 3.x」「固定在 3.x」，**不含版本号字符串**，按 `3.44.9`/`3.12.2` 检索必然漏网 → **靠二次清网（按约束语义检索）才补齐** |
| PDF 置信度举例（`schedule.md` §0.6 低置信度表） | 「`FMT-01` PDF（**插件未选型**）」 | 已选型 `pdfrx 2.6.5`（`Q4` 已闭环）→ 改写为「**集成成本未实测**」，不再算「需外部选型」 |
| `R9`（`schedule.md` §5 风险表） | 🟢「依赖版本锁定与 Flutter 升级的两难」，处置 =「**本期不升级**」 | 升级**已发生**且**实际 ≈ 0 额外成本**（作为 2026-09-24 独立批次一次做完，原估的 +3~+6 周**未发生**）→ **整条关闭**；「依赖版本锁定」半条仍有效（玻璃库仍精确锁 1.7.0 不带 `^`、FRB 2.13.0 仍须 codegen ≡ runtime） |
| `isGlassWidget` 计数（§2.8） | 「**37 个** `Glass*` 类型」 | 判定表实为 **35**（`08c2b65` / `9519c5f` / `5b96ca6` 三提交上**始终为 35**）；库 `lib/widgets` 下 `class Glass*` 为 **90**（1.6.2 与 1.7.0 **完全相同**）。「37」**与两者均不符 → 原文计数错误**，与版本升级无关 |
| Windows 玻璃「为什么不一样」（`NF-C8` / §15.3 / `build-windows.md` §3.2 / `schedule` N-5 与 R8） | 「本机 Windows 走 **Skia 轻量路径**」——其**前提**是 3.44.9 不满足「Windows 获得 Impeller ANGLE 需 Flutter ≥3.47」 | 前提**已失效**（已升 3.47.5，门槛满足）。但**库自身仍把 Windows / Linux 静态封顶 `standard`** → **观感差异仍在，只是原因变了**。⚠️ 两层原因必须分开表述，不能混成一句 |

**复核边界（哪些结论能读源码复核、哪些不能——不伪造复核记录）**

- **可复核 → 已复核**：三条依赖 1.6.2 **源码**的关键断言，已在 1.7.0 上逐条核对：① `glass_scaffold.dart:559 / :584` 的 `defaultQuality: GlassQuality.premium`；② 判定表 **35 个类型零缺失**；③ `_shouldSkipPremiumPreload()` 对 `kIsWeb` / `windows` / `linux` 返回 `true`（`:148-153`）——**行号与判定式逐字一致**。
- **不可复核 → 明确标注**：§11.4 中依赖**运行观感 / 性能实测**的条目（如「Windows 与 Android 的实际观感差异」）**无法由读源码得出** → **保留「针对 1.6.2 实测」的原始表述，标注「待在 1.7.0 上重新验收」**，**不写「已复核」**。

**方法教训（可复用，下次回填直接照做）**

| # | 教训 | 本轮实证 |
|---|---|---|
| 1 | **按版本号字符串 grep 会漏「语义等价表述」** | 首轮按 `3.44.9`/`3.12.2` 检索命中 22 行；但描述同一事实的等价写法（「锁 3.x」「固定在 3.x」「Skia 轻量路径」）**不含版本号** → 漏掉 **4 处** `archive` 表述。**回填必须补一轮「按被推翻的约束语义」检索** |
| 2 | **凡写进文档的计数，必须附口径与可复核命令** | 本节初稿写「4 份文档共 24 处」（沿用上一轮**手数**），程序化点数实为 **5 份 / 22 行 / 34 处字面量**（`grep -c` 与 `grep -o \| wc -l` 两种口径）→ 已勘误。**手数必错** |
| 3 | **跨引用章节号必须当场 grep，不能凭记忆写锚点** | 本轮先后误写 3 处：「§2.37 尚不存在」（写完引用才发现）→「§2.1（实为 §2.0）」→「§2.19/§2.21（实为 §2.6 / §2.12）」。**规则：写锚点前先跑一遍 `grep -n "^### "`** |

**闸门结论**：本次回填**不改动任何验收结论**——`NF-C8` 的「按平台分别判定」口径一字未动、PRD §15.6.3 阈值表一字未动。**唯一实质影响 = `M35-T03` 的验证对象**（3.44.9 → 3.47.5）。

**遗留（不在本批范围，交负责人拍板）**：`schedule.md` §6 周序、7 条 lint、总体人天百分比、工作区行尾翻新（`R9` 已关闭但行尾策略 `a0c7c71` 的「本批不翻新现存工作区」仍挂账）。

### 2.38 UI 重做：五 tab 壳层与书架保真度（2026-09-28）

| 项 | 值 |
|---|---|
| 事项 | 负责人提出「当前 UI 设计和交互不是我想要的」→ 参考 `D:\Projects\anx-reader` 重做书架 + 加五 tab 底栏 |
| 拍板（四项全选推荐档） | 底栏 = **悬浮胶囊 + 液体玻璃**（复用 `liquid_glass_widgets`，**不引新依赖**）／书架视觉 = **照搬 anx 全套**／交互保真度 = **L1+L2+L3 全要**／统计·AI·笔记 = **只建占位页** |
| 提交 | `06063c8`（壳层 + 书架视觉 L1）、`0991c43`（筛选/排序 L2 + 长按操作单）；**L3 未动工** |

**关键 API 事实（本批逐条读 1.7.0 真实源码复核，非凭记忆）**

| 事实 | 出处（源码行） | 对本项目的影响 |
|---|---|---|
| `GlassTabBar.bottom` **本身就是浮动胶囊**（iOS 26 `UITabBarController` 等价物） | `glass_tab_bar.dart:183` 签名；`:194` `spacing = 8`、`:195` `horizontalPadding = 20`、`:196` `verticalPadding = 20`、`:197` `barHeight = 64` | **无需**引入 `flutter_floating_bottom_bar`（anx-reader 用的那个包），也**无需**自绘毛玻璃 → 依赖表零变更 |
| **玻璃库不含侧栏组件** | `lib/widgets/surfaces/` 实为 8 个文件：`glass_app_bar` / `glass_bar_item` / `glass_large_title` / `glass_navigation_shell` / `glass_pinned_bar_chrome` / `glass_scaffold` / `glass_tab_bar` / `glass_toolbar`（+ `shared/`） | 宽屏侧栏用 Material `NavigationRail`（与 anx-reader 同选择）。⚠️ `glass_navigation_shell.dart` **不是侧栏**——它是「pinned navigation chrome」的管理器（`GlassNavBarRegistration` 由 `GlassAppBar.pinned` 交进来），勿望文生义 |
| 无祖先时 `resolveQuality` 落 `fallback`，默认 **`standard`** | `glass_theme_helpers.dart:160` 定义、`:163` `GlassQuality fallback = GlassQuality.standard` | **这是 `standalone` 参数存在的全部理由**：浮动胶囊脱离 `GlassScaffold`（本该由它内层 `GlassIsolationScope(defaultQuality: premium)` 自动提升）后，高档会静默掉到 `standard` → 封装里显式补 `premium` |

**本项目侧的三处结构决策**

1. **壳层外层刻意不用 `Scaffold`，用 `Stack`**：五个子页各自持有 `GlassNavScaffold`（含自己的顶栏）。外层若再套 `GlassScaffold` 即构成**玻璃套玻璃**，违反 `UI-04`。故 `home_shell.dart` 用 `Stack` + `Positioned(bottom: 0)` 浮底栏——与 anx-reader 同结构。
   - 对应地 `GlassNavBar` 增 `standalone`，实现为 `quality: config.fixedSurfaceQualityOverride ?? (standalone ? GlassQuality.premium : null)`（`glass_kit.dart:358-359`）：**只有高档**显式声明 `premium`，中/低档仍由 `GlassScope` 的 `fixedSurfaceQualityOverride` 钉 `standard` / `minimal`——**非写死**，档位链不破。
2. **`kShellBottomInset = 96`（`home_shell.dart:49`）的由来与必要性**：浮动胶囊**不占布局高度**，`Positioned` 也不会为 `IndexedStack` 让位 → 各页可滚动内容必须**自留底部空白**，否则最后一行被胶囊压住。已接三处：书架网格、`library_search_page` 结果列表、导入失败清单。`library_search_page.dart` 经 `import 'home_shell.dart' show kShellBottomInset;` 取用（**曾漏此 import 导致 `Undefined name` 编译错**）。
3. **保 `UI-04` 红线做渐变背景**：anx-reader 用 `primary.withAlpha(5)` **半透明叠底**——在本项目是红线违规。本实现改用 `Color.alphaBlend(半透明光晕, 底色)` **预先合成为完全不透明**再交给 `RadialGradient`（`shelf_page.dart::_shelfBackground`）：观感等价，内容层仍然不透明。

**踩中的真 bug（玻璃浮层无 Material 祖先）**

- 现象：`test/ui` 首跑 5 个失败，全为 `No Material widget found. ListTile widgets require a Material widget ancestor`。
- 根因：长按操作单由 `GlassOverlays.showSheet` 承载 → 玻璃浮层**没有 Material 祖先**（PRD §11.4 已写明这条约束），`ListTile` 直接抛断言。
- 修法：`_BookActionSheet` 最外层包 `Material(type: MaterialType.transparency, child: SafeArea(...))`——**这是玻璃浮层内放任何 Material 系控件的标准做法**（`library_search_page` 的 `TextField` 同理）。

**改动面（含测试）**

- 新增：`lib/ui/home_shell.dart`（约 230 行）、`lib/ui/placeholder_page.dart`、`lib/ui/stats_page.dart` / `ai_page.dart` / `notes_page.dart`（占位）、`lib/ui/library_search_page.dart`（约 200 行，**只过滤元数据**：书名/作者/文件名，大小写不敏感；与阅读页内 `CNT-06` `SearchSheet`（正文级全书搜索）**分工不同**）、`lib/settings/shelf_prefs_store.dart`（约 210 行）。
- 重写：`lib/ui/book_card.dart`（约 250 行）——去卡片底板、封面浮层 + `BoxShadow`、标题 13px w600 两行、作者 + 右下角进度百分比（`readProgress` 为 null 则不显示）、`Hero(tag: 'book-cover-${bookId}')`。
- 修改：`lib/ui/glass_kit.dart`（`GlassNavBar` 暴露胶囊参数 + `standalone` + re-export `GlassTab` / `GlassTabBarExtraButton`）、`lib/ui/shelf_page.dart`（约 850 行）、`lib/main.dart`（组合根改 `HomeShell` + 并行加载 `ShelfPrefsStore`）。
- 测试：`ShelfPage` 新增**必填**参数 `shelfPrefs`，`test/ui/shelf_page_test.dart` / `test/widget_test.dart` / `test/meta/detail_test.dart` 三处同步补注入；`LIB-06` 四处 + 回归③ 由「长按即出确认框」改写为**两步流程**（长按 → 断言操作单出现 / **断言确认框不该出现** → 点「移出书架」→ 确认框）——这是**预期行为变更改测试**，不是改代码迁就测试。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 全仓：无新增问题（7 条 info 均为既有）
bash tool/test.sh ui                                        # 00:39 +57: All tests passed!
bash tool/test.sh data                                      # 00:12 +205: All tests passed!
```

> ⚠️ Dart 可执行文件是 **`/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe`**——`C:/src/flutter/bin/dart.exe` **不存在**（本批踩过）。

**复核边界（不伪造复核记录）**

- **可复核 → 已复核**：上表三条第三方 API 事实的行号与默认值**逐字对上**；本项目 `glass_kit.dart:358-359` 的 `quality` 表达式、`home_shell.dart:49 / :52` 两个常量、`surfaces/` 目录清单均为 `grep` / `ls` 实测。
- **不可复核 → 未声称**：**书架视觉与 anx-reader 的「观感是否一致」无法由读源码判定**，须在真机/桌面上看。本批**只对代码结构负责**，未写「视觉已验收」；L1 视觉验收**待在负责人设备上确认**。
- **L2 筛选判据的依据是读源码得出**：`BookRecord.readProgress` 由 `reader_page.dart` 的 `_overallProgress(index, _chapterPos)` 经 `markRead` 真实回写（**非空字段**），故「未读 / 在读 / 已读完」三档成立；排序字段 `importedAt` / `lastReadAt` / `title` / `author` **均已在 `BookRecord` 中存在 → 本轮无需改序列化**，故不存在旧索引兼容问题。

**未做（如实登记，交负责人）**：**L3**（长按拖拽重排 / 拖到书上建文件夹 / 桌面拖文件入窗导入）**一行未写**——它会改动 `BookRecord` 的持久化结构（或另建布局文件），涉及 `index.json` 向后兼容设计与可能的两个新依赖（`flutter_reorderable_grid_view`、`desktop_drop`），**须先拍板方案再动工**。


> **后续（§2.39 已闭环本条）**：拍板结论是**另建 `shelf_layout.json`、`BookRecord` 一行不改**（§2.38 里「改动 `BookRecord`」的担忧由该方案化解）、网格重排**自实现不引包**、新依赖只留 `desktop_drop`（且放到第二批）。故本段「须先拍板」已拍、L3 第一批已交付，详见 §2.39。

### 2.39 UI 重做批次③ · L3 第一批：拖拽重排 + 文件夹（2026-09-28）

| 项 | 值 |
|---|---|
| 事项 | L3 三件套的**第一批**：书架长按拖拽重排、拖到另一本书上合并成文件夹、拖到文件夹卡上并入、文件夹重命名 / 解散 / 内页重排 |
| 拍板（三项全选推荐档） | 持久化 = **独立 `shelf_layout.json`**（`BookRecord` 零改动）／依赖 = **自实现拖拽 + 只引 `desktop_drop`**／节奏 = **拆两批**（桌面拖入留下批） |
| 提交 | `d98b80b`（轻提示改 Overlay，连带修**既有** SnackBar 潜伏崩溃）、`3869f52`（L3 第一批） |

**一、为什么是独立 `shelf_layout.json` 而不是改 `BookRecord`**

1. `index.json` 一行不动 → **零旧索引兼容风险**（负责人点名要规避的正是这条）；
2. 拖拽是高频动作，只重写一个**小文件**（`order` + `folders`），不必整份书库索引跟着落盘；
3. 与既有的 `shelf_prefs.json` **同形制**（`JsonStore` → `AtomicFile`，`DATA-01` 原子写入），代码是熟路。

孤儿引用（书被删了、布局里还留着 id）走**两道互不假设**的兜底：渲染期按 `bookId` 过滤 + 载入后 `prune()` 落盘清孤儿、清因此变空的文件夹（**无变化不写盘**，逐字节比对已入测试）。

**二、拖拽三态怎么区分（`lib/ui/shelf_grid.dart` 头注是本批的设计文档）**

| 手势 | 判据 | 动作 |
|---|---|---|
| 长按**不动**抬手 | `onDragEnd` 里 `!details.wasAccepted && !_movedDuringDrag` | 弹长按操作单（`LIB-06` 语义保持） |
| 长按后**快速**放下 | `wasAccepted` 且未满 900ms | 重排（`onReorder`） |
| 拖到目标上**悬停 900ms** | `kFolderMergeHoverDelay` 计时到点、`_mergeArmed = true` | 并入 / 新建文件夹 |

- **判「移动过」用 `onDragUpdate` 是否被调过（标志位 `_movedDuringDrag`），不用 `DraggableDetails.offset` 的距离**——后者在 feedback 跟手偏移下不稳。
- 悬停计时器用 `_hoverTimer ??=` 守住只启动一次，拖离 / 抬手即取消。
- **每项必须带 `ValueKey(bookId)`**：`GridView.builder` 会复用 element，没有 key 时 State（计时器、`_mergeArmed`）会错位到别的卡片上。
- **不引第三方网格重排包**：「拖到书上建文件夹」需要**项级 `DragTarget` + 悬停语义**，`flutter_reorderable_grid_view` 这类只管重排的包不覆盖。
- `BookCard.onLongPress` 改为可空、网格内**传 `null`**：否则 `InkWell.onLongPress` 会和外层 `LongPressDraggable` 在手势竞技场里互抢。

**三、两个顺序 / 语义坑**

- **`ShelfSortField.manual` 忽略升降序开关**——否则再点一下方向键会把用户刚拖出来的顺序整体翻转。
- **`_reorder` 必须「先落盘 `order`、再切 `manual`」**：反过来的话 `_visibleBooks` 会在切换那一帧用**旧的** `order` 重排一次，用户刚拖的位置肉眼可见地跳一下。
- 重排下标沿用 `ReorderableListView` 通行约定：`toIndex` 以**移除前**的列表计，`insertAt = from < toIndex ? toIndex - 1 : toIndex`（「拖到某本上」= 插到那本**之前**）。

**四、连带修掉的真 bug：轻提示必须走 Overlay（`d98b80b`）**

| 事实 | 出处 |
|---|---|
| 玻璃壳层**不含 Material `Scaffold`** | `liquid_glass_widgets` `glass_scaffold.dart:646` → `child: CupertinoPageScaffold(` |
| 窄屏（手机默认）布局也没有 `Scaffold` | `home_shell.dart:165` `_buildBottomBarLayout` = `Stack` + `Positioned` |
| **只有宽屏侧轨布局有** `Scaffold` | `home_shell.dart:187` `_buildRailLayout` |
| `showSnackBar` 的断言 | `_scaffolds.isNotEmpty`（`scaffold.dart:319`）→ 空则 debug 断言失败、release `_scaffolds.last` 抛 `StateError` |

也就是说 `ScaffoldMessenger.showSnackBar` 在**手机上必崩、桌面上碰巧能用**——这正是它一直没被发现的原因（且 widget 测试里 `FilePicker` 不可用，`_pickAndImport` 那条路径从未被覆盖）。修法 = 新增 `GlassOverlays.showToast`：玻璃档走库的 `GlassToast.show`（`OverlayEntry` + 自管定时移除），「关」档（`UI-06 ②`）退化为本文件自写的纯色 `_PlainToast`。**全仓 6 处 SnackBar**（书架 `_toast` / `_pickAndImport` + 详情页 3 处）全部换掉。

> **FakeAsync 悬案就此了结**：此前担心「`OverlayEntry + Timer` 会在 `testWidgets` 结束时报 `A Timer is still pending`」。读 `flutter_test/lib/src/binding.dart` `_runTestBody` 确认——`testBody` 跑完后**先** `runApp(Container(key: UniqueKey()))` + `pump()` 卸载整棵 widget 树、**再** `_verifyInvariants()` 查 pending Timer（`:1960-1974`）；树卸载时 `State.dispose` 会 `_timer.cancel()`（`fake_async` 里 cancel 即从 pending 计数移除）→ **不留 pending Timer**。实测 `ui` 组 85 条全绿无该报错。

**五、测试断言写错（不是功能 bug）**

`L3 拖拽重排` 首跑失败：`Expected ['b','c','a']` vs 实际三个 16 位 hex。根因 = **`layout.order` 存的是 `bookId`（`book_record.dart:31`：SHA-256 hex 前 16 位），不是书名**；而 `_titles` 与 `sortField == manual` 两条断言**当时已通过** → 重排与自动切 manual 功能本身正确。修正为捕获 `importFile` 返回的 `record.bookId` 再比对。反证 `BookRecord.fromJson`（`book_record.dart:105-113`）对 `title` 严格校验，不存在回退成 id 的可能。

**改动面（含测试）**

- 新增：`lib/settings/shelf_layout_store.dart`（约 380 行）、`lib/ui/shelf_grid.dart`（约 570 行，头注即设计文档）、`lib/ui/shelf_folder_page.dart`（约 470 行，**不支持嵌套**；`FolderActionSheet` / `askFolderName` / `confirmDissolveFolder` 提为公开与书架页共用）、`test/ui/shelf_layout_store_test.dart`（21 条）。
- 修改：`lib/ui/glass_kit.dart`（`showToast` + `_PlainToast` + re-export `GlassToastType`）、`lib/ui/shelf_page.dart`（L3 五个方法 + 手动排序分支 + `_liveFolders` 参与筛选）、`lib/settings/shelf_prefs_store.dart`（`ShelfSortField.manual` 加在**枚举末尾**，菜单顺序即 `values` 顺序）、`lib/ui/book_card.dart`（`onLongPress` 改可空）、`lib/ui/book_detail_page.dart`（3 处 SnackBar → `showToast`）、`lib/ui/home_shell.dart` / `lib/main.dart`（注入 `ShelfLayoutStore`）。
- 测试：`shelf_page_test` +6 条 L3 用例（重排 / 悬停建夹 / 拖入文件夹 / 进文件夹页 / 长按文件夹卡+解散 / 排序菜单含「手动排序」）；`ShelfPage` 新增必填 `shelfLayout` → `test/widget_test.dart`、`test/meta/detail_test.dart` 同步补注入。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 全仓：0 error / 7 条既有 info
bash tool/test.sh ui                                        # 01:25 +85: All tests passed!
bash tool/test.sh data                                      # 00:16 +205: All tests passed!
```

**复核边界（不伪造复核记录）**

- **可复核 → 已复核**：上表关于 `CupertinoPageScaffold` / `_buildBottomBarLayout` / `_buildRailLayout` / `binding.dart` 卸载时序 / `bookId` 摘要口径的**行号与字面量均为实读**；测试数字为本批实跑输出。
- **不可复核 → 未声称**：拖拽的**手感**（900ms 阈值是否合适、feedback 跟手是否顺）与文件夹卡的**观感**须在真机 / 桌面上试，本批只对代码结构与测试负责，**未写「交互已验收」**。

**未做（如实登记，交负责人）**：**L3 第二批 = 桌面拖文件入窗导入**（唯一新依赖 `desktop_drop`，已拍板待排期）；以及本批**未跑全量回归**（只跑了 `ui` + `data` 两组，`parse` / `reader` 与本批改动无交集但**未实跑**）。

### 2.40 UI 重做批次③ · 书架布局几何复刻 anx reader（2026-09-28）

**为什么是「几何」不是「全套视觉」**：anx-reader 的卡片字号、颜色、投影与本项目已有取舍（§2.38 记的「去卡片底板 + `BoxShadow`」），照搬会连带推翻 L1 的既定结论。故先问范围、两问两答再动手：

- **拍板 ① 范围 = 只动布局几何**：列数算法 / 宽高比 / 间距 / padding / 卡片分区改；**字号、颜色、阴影一律保持本项目现状**；PRD 与测试不动。
- **拍板 ② 格式标签 = 挪到封面上做角标**：信息区对齐 anx 的**固定 55px**（只剩书名 + 作者·进度），格式标签（PRD `US-06` / `LIB-01` 要求、anx 原版没有）改放封面右下角。

> **后续改道（2026-09-29，见 §2.51）**：上面「拍板 ①」的**范围**已被部分改写——**阴影**（封面投影）与**封面圆角**在 2026-09-29 经负责人拍板**改为对齐 anx**（圆角 6 → 8、静止投影换成 anx 的四参数字面量）。**未被推翻的部分**：**字号**（书名 13/w600、作者·进度 11）与**颜色**仍是本项目现状（不照搬 anx）；「只动布局几何」对**其余几何量**（列数算法 / 宽高比 / 间距 / padding / 卡片分区高度）依然成立。原拍板正文保留作事实留证，勿删。

**anx 取证（Explore 代理实读，均带 `路径:行号`）**

| 项 | anx-reader 原文出处 | 原文值 |
|---|---|---|
| 列数算法 | `bookshelf_page.dart:453-454` | `crossAxisCount: constraints.maxWidth ~/ Prefs().bookCoverWidth`，`bookCoverWidth` 默认 **120**（设置页 80–260 步长 10） |
| 高宽比 / 行距 | `bookshelf_page.dart:455-457` | `childAspectRatio: 1 / 2.1`、`mainAxisSpacing: 30`、`crossAxisSpacing: 20` |
| 网格 padding | `bookshelf_page.dart:449` | `EdgeInsets.fromLTRB(20, 12, 20, 80)` |
| 封面↔信息区间距 | `book_item.dart:88` | `SizedBox(height: 5)` |
| 信息区 | `book_item.dart:89-90` | **`SizedBox(height: 55)`**（固定） |

**改动前后对照**

| 项 | 改前（MReader） | 改后（复刻 anx） |
|---|---|---|
| 列数 | `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180)`（360dp 手机 **2 列**） | `LayoutBuilder` 内 `容器宽 ~/ 120`（360dp 手机 **3 列**），下限 1 / 上限 64 兜底 |
| 高宽比 | `0.5` | `1 / 2.1` |
| 行距 / 列距 | `8 / 8` | `30 / 20` |
| padding | `(12, 12, 12, kShellBottomInset)` | `(20, 12, 20, kShellBottomInset)` |
| 信息区 | 自适应（≈70，含格式标签行） | **固定 55**，格式标签移出 |
| 格式标签 | 信息区第三行 | **封面右下角角标** `Positioned(6, 6)` |

**为什么列数要包一层 `LayoutBuilder`**：`width ~/ 120` 需要 `GridView` 自身的可用宽，而 `SliverGridDelegate` 是在 sliver 布局期才拿到约束、拿不到整宽。anx 的结构是 `Expanded > LayoutBuilder > GridView`（其 `constraints.maxWidth` 同样是**含 padding 的整宽**），本项目照此结构；`width.isFinite` 时退回 3 列（anx 的手机默认值）。

**两处刻意不照搬（PRD 冲突，非疏漏）**

1. **格式标签**：`PRD.md:177` `US-06` 与 `:282` `LIB-01` 都要求书架展示格式，anx 无 → 不删，改角标（放在 `ClipRRect` **内**，随封面圆角一起裁切，不溢出）。
2. **空态导入按钮**：`LIB-01` 验收②要求，anx 空态只有颜文字 → 保留 `FilledButton.icon('导入书籍')`。

**同源防漂移**：新增 `kShelfCoverTargetWidth` / `kShelfGridPadding` 两个公开常量（`shelf_grid.dart`），`ShelfGrid` 构造默认值即 `kShelfGridPadding`，文件夹内页 `shelf_folder_page.dart` 的显式 padding 改用同一常量——原先两处各写一份 `EdgeInsets.fromLTRB(12, …)`，几何一旦改就会漂。底部 80 → `kShellBottomInset` 是**有意的差异**：两者目的相同（给悬浮胶囊留白），但本项目胶囊更高，用 anx 的 80 会被压住。

**改动面（含测试）**

- 修改：`lib/ui/shelf_grid.dart`（头注加「布局几何」段 + 两个公开常量 + `LayoutBuilder` 化）、`lib/ui/book_card.dart`（信息区固定 55 / 间距 5 / 格式标签上封面角标 + 头注与 `_FormatTag` 文档改写）、`lib/ui/shelf_folder_page.dart`（padding 同源 + 删多余 `kShellBottomInset` import）。
- 测试：**一行未改**（既有 `ui` 组无任何断言格式标签位置 / 网格列数的用例，已 grep 核实）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 全仓：0 error / 7 条既有 info
bash tool/test.sh ui                                        # 00:57 +85: All tests passed!
bash tool/test.sh data                                      # 00:11 +205: All tests passed!
```

**复核边界（不伪造复核记录）**

- **可复核 → 已复核**：上表 anx 行号与字面量、本项目改动 diff、`dart analyze` 与两组测试输出均为本批实跑/实读。
- **不可复核 → 未声称**：**新几何的观感**（3 列是否过挤、55px 信息区在两行书名下是否够放、角标压在封面上是否挡图）须真机/桌面目视验收；本批只对「代码等于拍板的几何数值」负责，**未写「视觉已验收」**。

**未做（如实登记，交负责人）**：① 新几何未做真机/桌面目视验收；② 本批仍只跑 `ui` + `data` 两组，`parse` / `reader` **未实跑**（与本批改动无交集）；③ `kShelfCoverTargetWidth` 目前**未开放为设置项**（anx 设置页可调 80–260，若要开放只改这一处常量的读取来源）。

### 2.41 顶栏避让修复 + 书架几何事实源与契约测试（2026-09-29）

**触发**：负责人发真机截图「布局乱了」（筛选栏被顶进状态栏、网格首行封面被顶栏盖住），并同时提出方向建议「**直接复用 anx 的代码，在它基础上修改**」。两问两答拍板：**修法 = 传 `extendBody: false`**；**复用范围 = 几何抽成事实源 + 契约测试**（不换骨架）。

**根因（读库源码定案，非猜测）**

| 证据 | 位置 |
|---|---|
| `this.extendBody = true` —— **库默认值** | `glass_scaffold.dart:135` |
| `extendBody` 为真 → `Positioned.fill(child: bodyContent)`，**正文铺满、y=0 起、不避让顶栏** | `:487-489` |
| `extendBody` 为假 → `top: topPad + effectiveAppBarHeight`（正确避让） | `:491-494` |
| 我们的薄封装**没传这个参数** | `glass_kit.dart:406-411`（改前） |

⚠️ **库文档与实现不符（本批最值得记的一条）**：`:153` 写 *"A top spacer is automatically added to push initial content below the app bar"*、`:83` 写 *"No manual spacer needed — GlassScaffold handles it"*，但 **`grep spacer` 全文件只有这三处文字、零处实现**——`extendBody: true` 分支就是裸 `Positioned.fill`。**引用第三方 API 一律以代码为准，文档只能当线索**（本项目工程约定已有此条，本次再添实证）。

**归属（如实）**：批次① `06063c8` 引入的既存 bug（建 `GlassNavScaffold` 时漏传），批次② `0991c43` 加筛选栏后显形；**不是 §2.40 几何批次引入**——那批只改横向 padding / 列数 / 卡片内部几何，纵向起点一行未碰。

**核查与代价（改前必做的两件）**

1. **7 处调用点无一手工补过顶部**（`book_detail_page:411` / `library_search_page:61` / `placeholder_page:47` / `settings_page:50` / `shelf_folder_page:109` / `shelf_page:565,573`）→ 一处改不会造成双重留白；`settings_page` 的 `ListView(padding: all 12)` 改前首项同样被盖，属顺带修好。
2. **底部不会被二次避让**：本项目底栏是 `home_shell.dart:166-180` 自己 `Positioned` 的浮动胶囊，**不走** `GlassScaffold.bottomBar` → `bottomBar == null` → `bottom: 0`，底部留白仍由各页 `kShellBottomInset` 独立承担。
3. **已知代价（拍板接受）**：`:458` 的 `if (extendBody && (doFadeTop || doFadeBottom))` 不再成立 → 正文不再包 `GlassScrollEdgeEffect`，**顶栏下方滚动渐隐关闭**（`edgeFade` 默认 `true`、有 appBar 即 `doFadeTop = true`，故这项确实存在、不是白关）。备选修法（给 body 补 top spacer 保渐隐）被否：要复制库 `:428/:434` 的算法，又落回「手工转述」老路。


**「直接复用 anx 代码」的评估（实读，非凭 pubspec 概括）**

- 整包红线冲突：anx 用 `flutter_riverpod` + `riverpod_annotation` + `freezed` + `build_runner`(`flutter_gen_runner`) + `sqflite`/`shared_preferences` + `flex_color_scheme` + `flutter_reorderable_grid_view`，`archive ^3.6.1`；MReader 已拍板**禁 Riverpod/Provider、禁 build_runner/Freezed、自研 JSON+AtomicFile、玻璃态、不引网格重排包**，且 `archive` 被 `pdfrx_engine` 逼到 `4.3.0` 不可退。
- **落到文件**：`book_item.dart:1-10` 即 import `flutter_riverpod`、`models/book.dart`、`service/book.dart`（开书链路）、`shared_preference_provider`（`Prefs().eInkMode` / `webdavStatus`），`build` 里 `ref.watch(syncStatusProvider)` + `showModalBottomSheet` —— **剥掉依赖后恰好只剩纯 `Column` 几何**，行为与数据层必须全部重写。故"复用"的真实收益边界 = **几何与结构**，不是 widget 本身。
- 结论对应拍板：几何抽事实源 + 契约测试；**不换骨架**。

**几何事实源 `lib/ui/shelf_geometry.dart`（新增）**

- 所有几何数值**只在此定义一次**，每条附 anx 出处行号：`kShelfCoverTargetWidth` 120（`bookshelf_page.dart:453-454`）、`kShelfChildAspectRatio` 1/2.1（`:455`）、`kShelfMainAxisSpacing` 30 / `kShelfCrossAxisSpacing` 20（`:456-457`）、`kShelfGridPadding` (20,12,20,·)（`:449`，底部换 `kShellBottomInset`）、`kBookCoverToInfoGap` 5（`book_item.dart:88`）、`kBookInfoHeight` 55（`:89-90`）、`kBookFormatBadgeInset` 6。
- **与 anx 不同的自有值照实标注**（防止后人逐行对照时误判成抄错）：`kBookTitleToAuthorGap` 2 与 `kBookInfoHorizontalPadding` 2 —— anx `book_item.dart` 信息区内两个 `Row` 之间**无 `SizedBox`**、也**无水平 Padding**（均为 0）。
- `shelf_grid.dart` 改为 `import` + `export 'shelf_geometry.dart'`，使 `shelf_folder_page` 等既有调用点 **import 零改动**；`book_card.dart` 三处字面量改常量。
- ⚠️ **`export` 必须放在 import 区**：首次把它写在 `const kFolderMergeHoverDelay` 之后（declaration 中间）是**语法错误**，Dart 的 directive 只能出现在所有 declaration 之前。

**契约测试 `test/ui/shelf_geometry_contract_test.dart`（新增 5 用例）**

- 两层：① 常量 golden；② **真实渲染契约**（392 宽 → 3 列且第 4 张换行 / 119 宽 → 1 列（`~/` 下限兜底）/ 卡片高宽比 2.1 / 卡片高 − `Hero` 高 = **60**（= 信息区 55 + 间距 5）/ 角标落在封面右下象限）。
- **期望值一律硬编码字面量，禁止引用事实源常量** —— 引用常量 = 同义反复，常量改了测试也跟着改就永远红不了；测真实渲染尺寸才能同时抓「数值抄错」与「参数接错线」（如 `childAspectRatio` 写成 `2.1 / 1`）。
- **自纠记录（不粉饰）**：角标断言首跑红，实测 `cellRect.right - badgeRect.right = 12` 而期望 6 —— 我量的是角标**文案 `Text`**，漏算 `_FormatTag` 自带的 `horizontal: 6` 内边距（6 + 6 = 12）；按实测修正期望并写明构成。

**顶栏避让回归 `test/ui/glass_nav_inset_test.dart`（新增 3 条）**：玻璃档正文 top ≥ 44（= `toolbarHeight`）、关档 Material `Scaffold` 同样避让、`appBar == null` 时 top 恰为 0（不凭空多留白）。断言用 `>= 44` 而非 `== 44`，容忍宿主注入状态栏内边距。

**可复用的坑：正文下移会挤掉测试里「首屏即可见」的断言**

`detail_test` 的 META-08 TXT 断言「单书统计」（`_buildSections` 的**末项**）首跑红：详情页 = `Column[Expanded(ListView), Divider, SafeArea(底部操作栏)]`，在 flutter_test 默认 **600px** 视口下「刚好一屏」，正文下移 44px 后末项被挤出视口 → `ListView` **懒构建根本不建它** → `find.text` 得 0 个。**产品行为是正确的**（详情页本就在顶栏下、超一屏滚动可见），失效的是断言的隐含前提。处置 = 只把该测试视口调到 `800×1000`（**必须同时钉 `devicePixelRatio = 1`**，否则默认 dpr=3 会把逻辑高度算成 333 反而更糟），**断言一字未改**。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 全仓：0 error / 7 条既有 info
bash tool/test.sh ui                                        # 01:11 +93: All tests passed!
bash tool/test.sh data                                      # 00:16 +205: All tests passed!
bash tool/test.sh reader                                    # 00:28 +226: All tests passed!
```

**复核边界（不伪造复核记录）**

- **可复核 → 已复核**：库源码行号（`:135`/`:487-494`/`:458`/`:153`/`:83`）、`book_item.dart` 的依赖与几何、7 处调用点、`_buildSections` 末项位置，均为本批实读；三组测试数字与 `analyze` 输出为实跑。
- **不可复核 → 未声称**：**真机上的新观感**（正文下移 44px 后各页排布、顶栏渐隐关闭后滚动到顶栏下的内容是否生硬）须负责人重跑确认，**未写「真机已验收」**。

**未做（如实登记，交负责人）**：① **本批未真机复跑**——`extendBody` 是全局布局改动，请重新安装后重点看书架 / 详情 / 设置三页顶部；② 顶栏渐隐已按拍板关闭，若真机上觉得生硬，备选修法（body 补 top spacer，代价是复制库算法）记录在上文；③ `parse` 组**未实跑**（与本批改动无交集）；④ `kShelfCoverTargetWidth` 仍未开放为设置项。

> ⚠️ **后续改道（2026-09-30，见 §2.58）**：本节的「`extendBody: false` **必须传**」口径**收窄为「默认值」**——`GlassNavScaffold` 已把 `extendBody` 暴露为参数（**默认仍 `false`**，本节修的 7 个页面行为一字不变），**书架页显式传 `true`** 走 edge-to-edge（全浮动头部形态：内容穿顶栏滚动 + `GlassScrollEdgeStyle.blur` 磨砂）。连带：本节「顶栏下方滚动渐隐一并关闭（拍板取舍）」只对**未开 `extendBody` 的页面**成立；书架侧该效果已按 `UI-02` ② 正式开启，首行保护改由 `shelfGridPadding` 承担。

### 2.42 书架阅读状态筛选改单选（2026-09-29）

**触发**：负责人拍板「书架页标签应该是**已读完、正在读、未开始**，且是**单选**，参考 anx reader」——批次② `0991c43` 做的是多选（三个 `FilterChip` 可叠加、命中任一即保留）。

**anx 的单选语义（实读源码，非凭 UI 猜测）**

| 证据 | 位置 |
|---|---|
| `enum ReadingStatusFilter { none, finished, reading, notStarted }` —— 单值枚举自带 `none` | `providers/book_filters.dart:5` |
| `toggle`：`state == status ? none : status` —— 点已选中即取消、点别的直接顶掉 | `:12-18` |
| chips 顺序与文案 = **已读完 / 正在读 / 未开始** | `bookshelf_page.dart:111-141` |

本项目不引 Riverpod → 同语义落在 `ShelfPrefsStore.toggleFilter`；`none` 对应 Dart 的 `null`。

**改动三处**

1. **数据模型**（`lib/settings/shelf_prefs_store.dart`）：`ShelfPrefs.filters`（`Set<ShelfReadingFilter>` 多选）→ **`filter`（`ShelfReadingFilter?` 单值，`null` = 不筛选）**。`copyWith` 的可空参数无法显式置空（`null` = 不修改），故 `clearFilters` 直接构造新 `ShelfPrefs`——这个坑在改字段类型时**全仓 grep 旧字面量**才能找齐调用点（工程约定既有条目，本次照做：`grep '\.filters\|filters:'` 确认零残留）。
2. **持久化（键名不动，零迁移）**：落盘键沿用 `filters`，值为 **list 恒 0/1 元素**——旧版多选文件读进来时 `fromJson` 取**首个合法值**收敛为单选（旧 `Set` 迭代序 = 插入序 = 用户**先**点选的那个；取首还是取末都不影响「单选收敛」的正确性，选定首值并写死在测试里），其余丢弃；新文件老代码也能读。双向兼容、无需迁移逻辑。
3. **UI**（`lib/ui/shelf_page.dart`）：筛选栏 chips 改 **已读完 / 正在读 / 未开始**（原 未读/在读/已读完，顺序与文案照搬 anx `:111-141`）；`_visibleBooks` 的三路「或」判定改**单 `switch(filter)`**（`switch` 表达式覆盖枚举全部三值，漏一支编译期即报非穷尽）。

**测试**

- 新增 `test/ui/shelf_prefs_store_test.dart` **10 条**（纯 `test()`）：单选顶掉/再点取消、`clearFilters` 保排序、`toJson` 恒 0/1 元素、往返一致、**旧多选文件取首值收敛**、非 Map / 非法类型回退、落盘后新实例 `load` 恢复。
- `shelf_page_test` 追加 1 条 **widget**：断言 chips 顺序文案 `['已读完','正在读','未开始']`、选「已读完」只剩已读完的书、再选「正在读」**顶掉**（`_titles` 恰为半本，非并集）、再点同一 chip 取消回三本。进度用 `repo.markRead` 真实回写（`readProgress` 1.0 / 0.4 / `null` 三档齐）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze                    # 0 error / 7 条既有 info
flutter test test/ui/shelf_prefs_store_test.dart --timeout 30s            # +10
bash tool/test.sh ui                                                      # 01:23 +104: All tests passed!
```

**复核边界**：anx 源码行号、三处改动（数据模型 / 持久化 / UI）为本批实读实改，两组测试数字为实跑；**真机上 chips 的观感与单选手感未复跑**，须负责人重装确认。

### 2.43 书架拖拽对齐 anx：落点即建文件夹、删拖拽重排（2026-09-29）

**触发链**：负责人报「拖拽生成文件夹没有实现」→ 指令「先去了解 anx reader 的实现方式」（只调研不动代码）→ 调研汇报给出三个修复方向 → 拍板「**对齐 anx**」→ 唯一硬分叉（重排去留）单独确认，拍板「**删重排，完全对齐**」。

**anx 的实现（全部实读源码取证）**

| 证据 | 位置 |
|---|---|
| 拖起：散书包 `CustomDraggable`、文件夹不包（`lockedIndices`，注释 "folder can't be dragged"）；`longPressDelay: 300ms`；**`onReorder` 是空实现**（拖完不重排） | `bookshelf_page.dart:388-434` |
| 投放区在**每个格子自身**：散书 `singleBookTarget` / 文件夹 `groupTarget` 都是 `DragTarget<Book>` | `book_folder.dart:89-98 / 100-195` |
| 建组：目标书 `groupId == 0` → 先 `copyWith(groupId: 目标书自身 id)`（**文件夹 id = 目标书 id**），再 `moveBook(被拖书, targetGroupId)` | `book_folder.dart:34-44` |
| 组名播种：`insertGroup(groupId, name: 被拖书.title)` | `book_list.dart:148-153` |
| **无悬停计时**：`onWillAcceptBook` 进入即接受，**松手落在散书上直接建组**；悬停反馈只有 `AlwaysStoppedAnimation(0.5)` → 恒定 1.05 放大 | `book_folder.dart:46-65` |
| 拖起即弹底部操作单 + 锁其他 index；文件夹内页 `book_opened_folder.dart` **无任何 Draggable/重排** | `bookshelf_page.dart:395-415` |

**「没有实现」的定性（调研判断，非真机实证）**：功能链路存在（`shelf_page_test` L3 用例实测过建文件夹，批次③ `3869f52`），旧交互是「悬停 900ms armed 才建、否则判重排」且**零引导**——快速拖放全走重排路径，感知上等于「没实现」。anx 是落点即建 + 300ms 起拖 + 顶部提示条。

**改动**

1. **`lib/ui/shelf_grid.dart`（核心）**：删 `kFolderMergeHoverDelay` 与整套悬停计时（`_hoverTimer`/`_mergeArmed`/`_armHover`/`_cancelHover`/`onMove`/`onLeave`）；`onAcceptWithDetails` **落点即调 `onMergeBooks`**（对齐 anx `onAcceptBook`）；悬停反馈改为**立即**显示「新建文件夹」icon+文案（anx 用 1.05 放大表达同一语义）；删 `onReorder` 字段链（`ShelfGrid`/`_BookCell` 参数与字段一并删，`_BookCell.index` 随之无用也删）；**`BookCard.onLongPress` 改 `dragEnabled ? null : () => onBookActions(record)`**——禁拖时（文件夹内页）长按操作单改由卡片自身触发，否则禁拖即失去操作单入口。
2. **`lib/ui/shelf_page.dart`**：删 `_reorder`（含「先落盘 order 再切 manual」逻辑）与 `onReorder` 传参；`_mergeIntoFolder` 语义注释改「落点即建」；`_visibleBooks` 的 `ShelfSortField.manual` 分支**保留**（消费旧 `order` 数据），注释注明 2026-09-29 起无拖拽写入口。
3. **`lib/ui/shelf_folder_page.dart`**：传 **`dragEnabled: false`**（对齐 anx 内页无拖拽）、删 `onReorder` 与 `_reorder`（`setFolderOrder` 不再有 UI 调用者，**store API 与测试保留**——数据层能力，将来可有「移动到…」等新入口）。
4. **manual 排序模式整体保留**（拍板选项 A 原文）：旧 `order` 数据继续生效、排序菜单项不动，只是不再能通过拖拽改顺序。

**被推翻的旧定案（§2.39 三态表）**：「快速放下 = 重排」「悬停 900ms = 建文件夹」两行**作废**，`kFolderMergeHoverDelay` 常量删除；「`_reorder` 先落盘 order 再切 manual」「重排下标 `ReorderableListView` 约定」两条顺序坑**随逻辑一并删除**（不再有该路径）。**未被推翻**：长按不动抬手 = 操作单、`onDragUpdate` 标志位判移动、`ValueKey` 防 element 复用错位、不引第三方网格重排包、轻提示走 Overlay。

**测试**

- 删 `shelf_page_test`「L3 拖拽重排」用例（功能已不存在，**不改造成别的断言**）；
- 改建文件夹用例为「**拖到另一本书上松手 → 立即新建文件夹（无悬停计时）**」——去掉两行 `pump(kFolderMergeHoverDelay)`，改为悬停一帧即断言「新建文件夹」提示出现，松手后断言建组与 toast 不变；
- `shelf_geometry_contract_test` 删 `onReorder` 传参。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze                   # 全项目 0 error / 0 warning / 7 条既有 info
bash tool/test.sh ui                                                     # +103: All tests passed!（原 104 − 删 1 用例）
```

**复核边界**：anx 源码行号、三文件改动、测试数字为本批实读实跑；**真机手感未复跑**（落点即建的拖放手感、文件夹内页禁拖后长按弹操作单），须负责人重装确认；`data`/`parse`/`reader` 组未跑（本批零数据层改动）。

**顺带发现、未处理（报负责人）**：anx 阅读状态阈值是 `未开始 ≤0.02 / 已读完 ≥0.98`（`book_list.dart:83-94`），本项目筛选用 0/1 硬边界——口径差异，是否跟进未拍板。

### 2.44 分组取代文件夹、书架去拖拽化（`P2-02` 提前落地，2026-09-29）

**触发**：负责人两条指令——①「移除拖拽加入文件夹功能」；②「移除已读完、正在读、未开始，改为分组，默认全部，如将一本书设置为玄幻分组，则为全部、玄幻」。

**拍板（两问两答）**：① 分组与文件夹的关系 = **分组取代文件夹**（不并存）；② 设置入口 = **详情页「分组」行**（书架长按操作单不加）。

> 需求侧依据：PRD **`P2-02`「书架分组与筛选」**（原排 M4，`docs/进度表.md` 的 `P2-T02`）——「自定义分组（在读/读完/弃坑）」。本次是**提前落地**，PRD 条文无需改动。详情页本就有一行**禁用的「分组」占位**（`book_detail_page.dart` 原 `:502` 注释「`P2-02` 分组未实现：显示「未分组」且禁用，不自造分组系统」）——本批正是把它点亮。

**为什么是「取代」而不是并存**：原 `BookFolder` 就是「一个名字 + 一组书，且**一本书归属唯一**」，与「一本书一个分组」在数据形状上完全同构；并存会造出两套语义重叠的归类系统（用户必然问「文件夹和分组有什么区别」）。

**改动**

1. **数据层**（`lib/settings/shelf_layout_store.dart`）：`BookFolder` → **`BookGroup`**；`ShelfLayout.folders` → `groups`；`folderOf`/`folderedBookIds` → `groupOf`/`groupedBookIds`；新增 `groupById` / `groupByName`；store 方法 `createFolder`→`createGroup`、`addToFolder`→`assignToGroup`、`removeFromFolder`→`removeFromGroup`、`dissolveFolder`→`deleteGroup`、`renameFolder`→`renameGroup`，**删 `setFolderOrder`**（内页拖拽重排的写入口，随重排一并消失）；新增 **`assignByName(bookId, name)`**——详情页「选已有分组 / 新建分组」两种动作共用它（同名并入、异名新建、空名拒绝）。
   - **落盘键 `folders` → `groups`，读取兼容旧键**（`json['groups'] ?? json['folders']`）：旧数据一本不丢，下次写盘自动归一（测试逐字断言落盘文件不含 `"folders"`）。
   - id 前缀 `f` → `g`（旧 `f...` id 照常读入，不冲突）。
2. **偏好层**（`lib/settings/shelf_prefs_store.dart`）：删 `ShelfReadingFilter` 枚举与 `filter`/`toggleFilter`/`clearFilters`，改 **`groupId`（`String?`，`null` = 全部）+ `setGroup(String?)`**；`hasFilter` → `hasGroup`。
   - 落盘键 `filters` → **`group`**（`null` 时**省略键**）；**旧 `filters` 键直接忽略、不迁移**——旧值是阅读状态枚举名，在新语义下不是合法分组 id，强行映射只会造出假分组；代价仅是「记住的筛选态」，用户重点一下即可。
3. **书架网格**（`lib/ui/shelf_grid.dart`）：**去拖拽化**——删 `DragTarget` / `LongPressDraggable` / `_BookCell`（含 `_movedDuringDrag`、`_DragFeedback`、`_HoverOverlay`）/ `_FolderCell`（文件夹卡）/ `onMergeBooks` / `onDropIntoFolder` / `dragEnabled` / `folders` / `allBooks`，文件从约 570 行缩到约 150 行，只剩「按几何排布书卡」。长按操作单改由 `BookCard.onLongPress` **直接承载**——没有外层拖拽容器了，原先「网格内必须把 `onLongPress` 置 `null` 以避让手势竞技场」的理由随之消失。
4. **删除** `lib/ui/shelf_folder_page.dart`（文件夹内页 + `FolderActionSheet` / `askFolderName` / `confirmDissolveFolder`）。
5. **书架页**（`lib/ui/shelf_page.dart`）：删 `_liveFolders` / `_looseBooks` / `_mergeIntoFolder` / `_dropIntoFolder` / `_openFolder` / `_folderActions` / `_folderById` / `_toast`；`_visibleBooks` 改**分组筛选**（`null` = 全部）；顶部 chips 改为「**全部 + 各分组名**」横向可滚（分组数由用户决定，窄屏必然放不下）；空态文案改「这个分组里没有书」+「查看全部」。
   - **选中的分组不存在时按「全部」渲染**（渲染层回落，**不改写** prefs）：书被删空后 `prune` 会清掉空分组，而 `groupId` 仍指着它——不回落的话书架会永久停在「没有符合当前筛选的书」，用户找不到恢复入口。已入测试。
6. **详情页**（`lib/ui/book_detail_page.dart`）：新增注入 `ShelfLayoutStore shelfLayout`（与书架页共享同一实例）；原禁用「分组」占位行改 `_buildGroupEntry`——显示当前分组名（未分组时灰色「未分组」）+ 右箭头，点击弹 `_GroupPickerSheet`（未分组 / 各分组带「N 本」/ 新建分组…）；新建走玻璃输入框 → `assignByName`。


**被推翻的旧定案**：§2.39 / §2.43 的**全部拖拽交互条目作废**（三态判据表、`kFolderMergeHoverDelay`、落点即建、文件夹卡投放、文件夹内页、重命名 / 解散、超 900ms 那套手感讨论）；§2.42 的**阅读状态单选作废**（`ShelfReadingFilter` 与其 chips 顺序 / 文案 / 阈值口径一并作废，连「anx 阈值 0.02/0.98 vs 本项目 0/1」的口径差异问题也随功能删除而关闭）。**未被推翻**：`shelf_layout.json` 独立文件的理由三条、孤儿引用两道兜底（`prune`）、`ValueKey` 防 element 复用、轻提示走 Overlay、几何事实源与契约测试、`ShelfSortField.manual` 旧顺序数据仍生效。

**测试**

- `shelf_layout_store_test`：改名 + 新增「旧 `folders` 键兼容」「落盘键为 `groups`」「`assignByName` 三种情形（同名并入 / 新建 / 空名拒绝）」+ 删 `setFolderOrder` 两组用例；**21 → 28 条**（口径：`grep -c "^\s*test\(Widgets\)\?(" test/ui/shelf_layout_store_test.dart`）。
- `shelf_prefs_store_test`：整篇重写为分组筛选（默认全部 / 顶掉 / 同值空操作 / `group` 键省略 / 旧 `filters` 忽略 / 非法值回退 / 排序不受影响）；**10 → 15 条**（同上口径）。
- `shelf_page_test`：删 4 条拖拽 / 文件夹用例与 1 条阅读状态筛选用例，新增 5 条（chips 基本行为、切组顶掉、选中组被删回落「全部」、**详情页设分组 → 返回书架 chips 出现**端到端、无分组时只有「全部」）；**19 条**（同上口径）。
- `shelf_geometry_contract_test`：跟改 `ShelfGrid` 新签名。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 全项目 0 error / 0 warning / 7 条既有 info
bash tool/test.sh ui                                        # 00:53 +115: All tests passed!
bash tool/test.sh data                                      # 00:10 +205: All tests passed!（含 meta/detail_test）
```

**两个实测踩到的坑（可复用）**

| 坑 | 现象 / 根因 | 修法 |
|---|---|---|
| **玻璃弹窗关闭转场仍在读 `TextEditingController`** | 新建分组弹窗返回后立刻 `controller.dispose()` → `A TextEditingController was used after being disposed`，栈落在 `_AnimatedState.didUpdateWidget`（转场每帧重建内部 `TextField`、会对 controller `addListener`） | controller **与 State 同生命周期**（成员字段 + `State.dispose` 释放，下次打开前先释放上一个），**不在弹层返回时立刻释放**。原 `shelf_folder_page.askFolderName` 的 `try/finally { dispose() }` 写法是同一个坑，只是从未被 widget 测试覆盖到 |
| **FakeAsync 推不动真文件 IO** | 端到端用例里点「确定」后 `pumpAndSettle()` → 分组写盘（`AtomicFile` 真 IO）永不完成 → `await` 之后的 `setState` 不执行 → 详情页不显示新组名 | 用 `_settle`（`runAsync` 让出真事件循环）；**凡「UI 操作 → store 写盘 → 再刷新 UI」的链路都要走它**，`pumpAndSettle` 只解决动画 |

**复核边界**：全部改动与测试数字为本批实读实跑；**真机观感未复跑**（分组 chips 的选中手感、详情页弹层在窄屏的可用性、旧 `folders` 文件升级后的实际表现）；`parse` / `reader` 两组未跑（与本次改动零交集）。

### 2.45 书架顶栏搜索框靠左铺满 + 描边/底色区分（2026-09-29）

**触发**：负责人反馈「书架搜索框需靠左非居中，且加边框颜色和背景色区分」。

**根因（读了库源码才敢下笔）**：搜索框是 `GlassTopBar` 的 `title`，而 `GlassTopBar.centerTitle` **默认 `true`**，书架页从未显式传参。库的布局委托 `_ToolbarLayout`（`liquid_glass_widgets-1.7.0/lib/widgets/surfaces/glass_app_bar.dart:501-615`）分两支：

| 分支 | 可用宽 | 定位 | 出处 |
|---|---|---|---|
| `centerTitle: true`（默认） | `size.width - 2 * max(leadingWidth, actionsWidth)`（**等边距口径**，两侧取较宽者） | `Offset((size.width - ts.width) / 2, ·)`——**按整条宽度居中** | `:559-578` |
| `centerTitle: false` | `size.width - startOccupied - startGap - endOccupied - endGap`（相邻才留 8px 间距） | 从 leading 侧起排 | `:579-611` |

书架顶栏右侧有**两个动作按钮**（导入 / 排序，各 48 宽）→ 居中档下可用宽还要再被砍掉 `2 × 104`，搜索框只剩约半宽并浮在中间，观感即「一个居中的小胶囊」。

**改动**（`lib/ui/shelf_page.dart`）

1. `GlassTopBar` 显式传 **`centerTitle: false`**（本页无 `leading` → 标题贴顶栏内边距起排，`GlassAppBar` 默认 `padding = EdgeInsets.symmetric(horizontal: 8)`）。
2. `_BookSearchEntry` 外包 **`SizedBox(width: double.infinity)`**：`InkWell`/`Container` 无固有宽时只按内容收缩，光改 `centerTitle` 会得到「靠左的小胶囊」。宽度取「可用宽 ∩ **400**」——400 上限保留，避免桌面窗口下搜索框拉满整条。
3. 样式区分：填充 `surfaceContainerHighest` **0.6 → 0.9**，加 **1px `outlineVariant` 描边**。理由：顶栏本身是**半透明玻璃**，0.6 的填充会「糊」进背后渐变，看不出这是一块可点控件。
4. 圆角 `20 → 18`（20 超过高度 36 的一半、渲染时本就会被裁到 18，写 18 免歧义）；容器的 `Key('shelf-search-entry')` 供契约测试定位。
5. 文字/图标仍用 `onSurfaceVariant`（**占位符口径**），不因加边框提成正文色。

**测试**（`test/ui/shelf_page_test.dart` 新增 1 条，**19 → 20 条**；`ui` 组总数 **115 → 116**；口径 `grep -c "^\s*test\(Widgets\)\?(" test/ui/shelf_page_test.dart`）

- 机制锁：`tester.widget<GlassTopBar>(...).centerTitle == false`。
- 几何锁：`getTopLeft(box).dx ≤ 16`（贴内边距 8）、`getSize(box).width > 300`（取到 400 上限）、右边缘 `< 800 - 48`（给动作按钮留位）。**退回居中则左边缘约 `(800-400)/2 = 200`，断言立刻红**。
- 样式锁：填充 `alpha ≈ 0.9`、`Border.top.width == 1.0` 且 `style == solid`。
- 视口 `800×1000` 且**同时钉 `devicePixelRatio = 1`**（默认 3 会把逻辑宽算成 266，动作按钮一挤可用宽就变、结论随之改变）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 0 error / 0 warning / 7 条既有 info
bash tool/test.sh ui                                        # 00:52 +116: All tests passed!
bash tool/test.sh data                                      # 00:13 +205: All tests passed!
```

**既有噪音（非本批引入，已实测排除）**：`shelf_page_test.dart:578`（分组 chips 用例的**第二次** `tap(find.text('玄幻'))`）会打一条 `derived an Offset … would not hit test` 警告——命中结果是 chip 自身的 `RenderPhysicalShape`/Material，**chip 的 `onSelected` 确实触发**（其后的 `_titles` 与 `groupId` 两条断言若 tap 落空必红，故非假绿）。用 `git stash` 回退本批改动后单跑同一条用例，警告**依然为 1 次** → 与本批无关。想消音可改点为 chip 本体或传 `warnIfMissed: false`。

**复核边界**：`analyze` 与两组测试为本批实跑；**真机观感未复跑**（靠左/铺满在窄屏上的实际比例、深色主题下 `outlineVariant` 描边的可见度）。`parse` / `reader` 两组未跑（与本次改动零交集）。

> ⚠️ **后续改道（2026-09-30，见 §2.58）**：本节的 **「可用宽 ∩ 400」上限与 α0.9 填充已被参考图批改掉**——搜索胶囊改「**全宽** + α**0.6** 半透明玻璃底」（拍板「全宽搜索胶囊」；顶栏下方新增磨砂内容区作底，故 0.9 的不透明理由随之消失），`getSize(box).width > 300` 相应改为 `> 600`。**「1px 描边」口径继续有效**（本节「描边/底色区分」的结论未被推翻），`centerTitle: false` 与 `SizedBox(width: double.infinity)` 亦不变。原文保留作历史记录。

### 2.46 书架点书卡直接进阅读页、详情页入口改走长按操作单（PRD v2.9，2026-09-29）

**触发**：负责人「点击图书直接进入阅读页」。

**拍板（两问两答）**：① 书籍详情页 = **保留**（入口改走长按操作单「书籍详情」，并**同步改 PRD**）；② 搜索页选中结果 = **同改**，也直接进阅读页。

**参考实现取证**：anx-reader 的 `lib/widgets/bookshelf/book_item.dart:51-53` 里 `onTap` 即 `pushToReadingPage(ref, context, book)`——**点卡即读**；它的详情页入口在长按菜单（`lib/widgets/bookshelf/book_bottom_sheet.dart:9` import `lib/page/book_detail.dart`）。搜索页复用同一个 `BookItem`（`lib/page/search/search_page.dart:204`），故 anx 的搜索结果同样是「点即读」。结论：本项目改后的结构与 anx 同构，且不再存在「同一个 `BookItem` 两种手势结果」的割裂。

**顺带消除一处 PRD 长期矛盾**：`META-08 ①` 原写「从书架**点**一本书进入详情页」，而 §12.2 `F2`（打开书与恢复进度）原文就是「**点书架项** → 读索引取进度」——同一手势两个定义，一直共存。本次以 `F2` 为准收敛，故这是**消除矛盾**而非引入矛盾；PRD 记 **v2.9**。

**改动**

1. `lib/ui/shelf_page.dart`（行为）：`_buildBookGrid()` 的 `onOpenBook` 由 `_openDetail` 改 **`_openBook`**（一处改即完成「点卡即读」）；`_openSearch()` 的 `picked` 由 `_openDetail(picked)` 改 **`_openBook(picked)`**。**`_openDetail` 与 `_detailPushing` 均保留**——长按操作单的「书籍详情」仍在用，只是唯一调用点由「点卡」变为「操作单」。
2. 注释同步（行为改了而注释不改就是文档负债）：`shelf_grid.dart` 的 `onOpenBook` 字段、`book_card.dart` 的 `onTap`、`book_detail_page.dart` 顶部 F9 流程图注释。
3. PRD（`docs/PRD.md`）：`META-08` 条目正文 + 验收 ① 改文（「从书架点击进入」→「从书架长按书卡 → 操作单「书籍详情」进入」）；§12.2 `F9` 流程图首行改为「点书卡 = 直接进阅读页；长按书卡 → 操作单「书籍详情」→ 进入书籍详情页」；§1.4 新增 **v2.9** 行（**无需求条目增减**，计数仍 P0 29 / P1 56 / P2 31 = 116）。

**测试**：`shelf_page_test` **20 → 21 条**（新增 1 条「回归①补」，口径 `grep -c "^\s*test\(Widgets\)\?(" test/ui/shelf_page_test.dart`），`tool/test.sh ui` **+117 全绿**（116 → 117）；`data` **+205 全绿**（`detail_test` 14 条条数不变，仅 3 处入口改法）。

| 用例 | 改法 |
|---|---|
| 回归① | 标题改为「点书卡直接进阅读页」：原「点卡 → 详情页 → 继续阅读」**三层压成一层**，断言 `_readerPages() findsOneWidget` + **`_detailPages() findsNothing`** + `record.bookId` 正确 |
| **新增**回归①补 | 详情页仍可达：新增帮手 `_openDetailViaSheet`（`longPress` → `pumpAndSettle` → 点「书籍详情」→ `_settle`），断言进详情页但**不自动开书**，再点「继续阅读」才进阅读页（`META-08 ②` 来源标记断言一并保留） |
| 回归①b | 原「连点只进一个详情页」改为「连点只 push 一个**阅读页**」——两击同帧时第一击已在首个 `await` 之前同步置 `_opening = true`，第二击被守卫吞掉 |
| 回归② | 删掉中间那层详情页（原「关书 + 关详情」两次 pop 变一次），「关书后立即点另一本 → 一次即进」的**主因窗口**语义不变 |
| 回归④ | 原「详情页按钮 spinner + 卡上覆盖层」两条可见反馈，改为只断言**卡上 loading 覆盖层**（点卡本身即准备期），导航前不出现阅读页的断言保留 |
| `test/meta/detail_test.dart` | 3 处入口（`META-08 ①②④` TXT / `META-08 ①` EPUB / `META-09 ①` 编辑链路）统一改走 `_openDetailViaSheet`，文件头补入口说明 |

**文档回填两轮（本轮两轮都命中）**

- **字符串轮**：`grep -rn "从书架点击进入\|点一本书进入详情页"` → 仅剩 v2.9 变更记录行内的**引用**（留档，正确）。
- **语义轮**：`grep -rn "进入详情\|点书卡\|书架项"` 抓出 **§2.16（M2a-T03）表格里「书架入口改道 + 开书回调注入」一行**——该行写的是「`BookCard.onTap` → `_openDetail`」，属于**当时的事实留证**，不改写，已在表后补**后续改道指针**指向本节。这正是「按版本号 grep 会漏、必须按被推翻的语义再 grep」的又一例。（本轮该跨引用初稿凭记忆写成「§2.19」，`grep -n "^### "` 核出实为 **§2.16** 并已改正——锚点先 grep 再写的纪律再次生效。）

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 0 error / 0 warning / 7 条既有 info
bash tool/test.sh ui                                        # 00:54 +117: All tests passed!
bash tool/test.sh data                                      # 00:17 +205: All tests passed!
```

**复核边界**：`analyze` 与两组测试为本批实跑；**真机观感未复跑**（点卡即读的响应手感、长按操作单作为详情页唯一入口是否够可发现——**这是本次最需要真机验证的一条**：入口从「显式点击」变成「长按」，可发现性下降）。`parse` / `reader` 两组未跑（与本次改动零交集）。

### 2.47 设置页视觉重做：大标题两段式收起 + 实心分组卡片（PRD v2.10，2026-09-29）

**触发**：负责人「参考这种风格，修改设置布局」（附小米 HyperOS 深色设置页截图）。

**拍板（四问四答）**：① 卡片材质 = **不透明卡片**；② 大标题形态 = **内容层大标题，卡片滑动到顶部时大标题变顶栏「设置」**；③ 是否顺带加「外观」组 = **加**；④ 搜索框 = **先做占位，不实际实现**。

**前置核实（先读源码再下笔；两处结论直接决定改法）**

1. **大标题能力是真的**（不是只看库文档）：`GlassLargeTitle`（`glass_large_title.dart:230-460`，`CustomScrollView` 的**首个 sliver**）+ `GlassLargeTitleController`（`ChangeNotifier`，`:53-173`，**自持** `ScrollController`）；两段式 = Phase 1 大标题淡出（`collapseTitleHeight`，由 sliver 自测高并回填）→ Phase 2 搜索条收起（`searchBarHeight`）；顶栏标题端由 `GlassAppBar._buildTitle` 的 `ListenableBuilder` 驱动（`glass_app_bar.dart:421-438`）。
2. **「关」档退化路径会丢掉大标题联动（缺口）**：`GlassTopBar` 关档走 Material `AppBar(title: …)`（`glass_kit.dart:214-223` 一带），而 `AppBar` **不认** `largeTitleController` → 不补的话「内容层大标题 + 顶栏标题」**两条一模一样的「设置」会同时可见**。本批在薄封装内自实现同一条曲线：`barProgress = ((collapseProgress - 0.5) / 0.5).clamp(0, 1)` 再过 `Curves.easeOut`（逐字照抄 `glass_app_bar.dart:426-436`），**两处必须一致**，否则切档（玻璃 ⇄ 纯色）标题会明暗跳变。
3. **「主题三态在应用级不可达」核证（③ 的前提）**：`SettingsStore.setThemeMode` 除测试外**零调用者**；另一处 `ReaderSettings.themeMode` 也**无消费点**——`reader_settings_bar.dart:147/163` 只用它画图标、`:171` 写它，`reader_page.dart:1711` 只在合并偏好时透传，`reader_page` 内无任何 `Theme(...)` / `resolveBrightness` / `MaterialApp` 覆盖，**故阅读页那个主题按钮是空操作**。因此「外观」组是**第一次让主题切换真正可用**，不是重复入口。

**改动**

1. `lib/ui/settings_kit.dart`（**新建**）：`SettingsAccents`（五行装饰色板） / `SettingsGroupCard`（不透明圆角卡片 + 可选组标题与组脚注；卡片用 `Material(color:)` 而非 `Container + BoxDecoration`——否则 `InkWell` 的水波纹被卡片底色盖住） / `SettingsTile`（40×40 圆角彩图标 + 标题 + 副标题 + 右侧「值 + 箭头」或自定义 `trailing`） / `SettingsPickerSheet` + `showSettingsPicker`（玻璃底部弹窗里的单选列表，首层 `Material(type: transparency)`，形态照搬既有 `_GroupPickerSheet`）。
2. `lib/ui/settings_page.dart`（**重写**）：`GlassNavScaffold` + `CustomScrollView(controller: _titleController.scrollController)`；首个 sliver = `GlassLargeTitle(text: '设置', searchBar: <占位>)`；正文 `SliverToBoxAdapter`（**不用 `SliverList`**：条目少且静态，一次构建完也让测试的 `find` 不依赖视口）；页面级不透明底色仍走 `OpaqueContentSurface`（其断言只校验**直接子节点**，`CustomScrollView` 不是玻璃控件 → 通过），底部留 `kShellBottomInset`。
3. `lib/ui/glass_settings_section.dart`（改版）：`SegmentedButton` + `SwitchListTile` → 卡片内两行 `SettingsTile`；「效果质量」行右侧显示当前档位、点击出**单选弹层**（候选项 = 四个档位，描述取 `glassTierConfigSummary`，与原 `tooltip` 同源）；「降低视觉特效」行右侧 `Switch` 且**整行可点**；关档下该行 `enabled: false`；档位说明与「已按『降低视觉特效』钳制」措辞**逐字保留**（搬到卡片 `footer`）。
4. `lib/ui/glass_kit.dart`（薄封装两处）：`GlassTopBar` 补 `largeTitleController`（玻璃档透传；关档自补淡入，见前置核实 2）；`GlassLargeTitle` / `GlassLargeTitleController` 加入 re-export（保持「页面不直接 import 玻璃库」的口径——这两个类型既是页面 `State` 成员、又是 `GlassTopBar` 的公开参数类型）。
5. `lib/theme/app_theme.dart`：新增 `appThemeModeLabel`（日间 / 夜间 / 跟随系统，措辞照 `TYP-03`），与 `resolveThemeMode` 同处一地，避免「一处主题两处口径」。
6. 注入链路：`HomeShell` 新增必填参数 `settings`（构造点全仓仅 `main.dart:107` 一处）、`main.dart` 透传、`SettingsPage` 新增必填参数 `settings`。
7. `docs/PRD.md`：§11.2 两行改文（设置页控件 / 分组卡片：玻璃 → **不透明**）+ 新增 §11.2 注 ② 说明依据与边界 + §1.4 新增 **v2.10** 行（**无需求条目增减**，计数仍 P0 29 / P1 56 / P2 31 = 116）。


**本批新立的一条边界（免得后人误判为漏网之鱼）**：`GlassLargeTitle` 在**「关」档仍然在场**。它只画 `Text` 与 `Transform.scale`（`glass_large_title.dart:398-458`，零着色器、零玻璃质感），是布局 / 动画组件而非质感组件，故 `UI-06` ② 的「纯色退化」不受影响；又因为 `isGlassWidget` 把它归入 glass 家族（`glass_kit.dart:104`），本文件与测试都显式写明这条口径（现有关档测试断言的是**具体类型**缺席：`GlassScaffold` / `GlassAppBar` / `GlassTabBar` / `GlassDialog` / `GlassSheet`，不是全树扫描）。

**测试（`test/ui/settings_page_test.dart` 新建，此前设置页零覆盖）**

口径 `grep -c "^\s*test\(Widgets\)\?(" test/ui/settings_page_test.dart` → **11 条**；`tool/test.sh ui` **117 → 128 全绿**、`data` **+205 全绿**。

| 用例 | 断言要点 |
|---|---|
| 关档壳层退化 | `Scaffold` / `AppBar` 在场，`GlassScaffold` / `GlassAppBar` 缺席，**`GlassLargeTitle` 在场**（上一条边界），`OpaqueContentSurface` 在场 |
| 高档控制器同源 | `GlassAppBar.largeTitleController` 与 `GlassLargeTitle.controller` **`same()`**——库的硬要求，各订阅一份会导致标题重叠 / 闪跳 |
| 首帧 | `find.text('设置')` **恒 2 个**（大标题 + 顶栏标题，同文案是库的设计）；`collapseProgress == 0` 且顶栏标题 `Opacity == 0` |
| 滚动联动 | 视口 400×360 + `devicePixelRatio = 1`；`maxScrollExtent > 50` 先自证有余量；`jumpTo(10)` → 进度 > 0 但 < 0.5 → **顶栏标题仍为 0**；拖到底 → 进度 1.0 → 不透明度 1.0 |
| 主题写入 | 弹层选「夜间」→ `settings.themeMode == dark` + 行回显 + **读 `settings.json` 校验 `"themeMode":"dark"`**（不只看内存） |
| 弹层取消 | 点遮罩 → 设置不变 |
| 档位切换 | 弹层选「中」→ `perfPrefs.prefs.glassTier == medium` + 行回显 + 读 `perf_prefs.json` 校验 `"glassTier":"medium"` |
| 降低视觉特效 | 点**整行**即切换 + 开关 `value` 同步 + 脚注出现「已按『降低视觉特效』钳制，所选档位：高」 |
| 关档置灰 | `SettingsTile.enabled == false` 且 `Switch.onChanged == null`，点行不改值 |
| 搜索占位 | 文案在场、无 `TextField`；点击只出「设置搜索尚未实现」轻提示，3s 后自动消失（不留下 pending `Timer`） |

**三个测试坑（可复用）**

1. **`find.text('设置')` 恒为 2 个**：大标题与顶栏标题同文案是库的设计（`GlassLargeTitle.text` 应等于 `GlassAppBar.title`），要精确定位必须 `find.descendant(of: find.byType(AppBar), …)`。
2. **取「顶栏标题的淡入不透明度」= 最近的 `Opacity` 祖先**：`find.ancestor` 按**由近及远**返回（`flutter_test` `_AncestorWidgetFinder._collectAncestors` 用 `visitAncestorElements`），而我们的 `Opacity` 的 `child` 就是标题本身 → 最近的必定是它，`AppBar` 内部若有自己的 `Opacity` 只会在更外层。故 `.first` 稳定可判（不靠猜）。
3. **「大标题滚动联动」用例必须调小视口并同时钉 `devicePixelRatio = 1`**：本页内容天然不足一屏（默认 800 高视口下 `maxScrollExtent == 0`，拖拽与 `jumpTo` 全被钳成 0 → 断言永远假绿或永远红）。且用例内先断言 `maxScrollExtent > 50` 自证「确有滚动余量」，再断言进度，避免「测试看着在跑其实没滚」。

**文档回填两轮**

- **字符串轮**：`grep -rn "设置页的分组卡片\|设置页内的按钮"` → 仅剩 PRD §11.2（已改文的两行）、§11.2 注 ②、v2.10 变更行与 CHANGELOG / 代码注释内的**引用**（留档，正确）。
- **语义轮**：`grep -rn "分组卡片\|分段控件"` 抓出 **`glass_runtime.dart:103` 的「设置页分段控件标签」**——`SegmentedButton` 已退场，属被推翻的语义，已改为「设置页『效果质量』行的当前值与单选弹层候选项文案（契约不变）」。
- **本轮还修正了主理人自己的过度断言**：初稿在代码注释与回报里写「PRD §11.2 两行与 `UI-04` ② 互斥」，复核条文后确认 `UI-04` ② 的枚举范围限于**内容层行**（书架 / 目录 / 搜索 / 统计 / 正文），故 §11.2 与它**不是原文自相矛盾、而是取向相左**——已把四处注释与 PRD 注 ② 全部改写为经得起查证的表述（保留「已上报负责人裁量」这一真实过程）。**教训：下「矛盾」判断前先读条文范围，不能只读标题句。**

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze      # 0 error / 0 warning / 7 条既有 info
/c/src/flutter/bin/flutter test --timeout 30s test/ui/settings_page_test.dart   # 00:01 +11: All tests passed!
bash tool/test.sh ui                                        # 01:07 +128: All tests passed!
bash tool/test.sh data                                      # 00:16 +205: All tests passed!（补跑，见「复核边界」）
```

**复核边界**：`analyze`、本文件与 `ui` / `data` 两组测试为本批实跑；**真机观感未复跑**——参考图是 HyperOS 深色页，本批在浅色主题 / 窄屏 / 桌面宽窗口下的实际观感、大标题两段式收起的手感、实心卡片与玻璃顶栏的接缝都需真机确认。`data` 组**是补跑**：`test/meta/detail_test.dart` 也引用 `GlassTopBar`，虽 `largeTitleController` 是可选新参数、退化路径在传 `null` 时与改前**逐字等价**（`_fadeInBarTitle` 直接返回原 `title`），仍按「影响面闭合」补跑并留档。`parse` / `reader` 两组未跑（与本次改动零交集：改动仅在 `lib/ui/` 与 `lib/theme/`）。

### 2.48 Android 页面转场：关掉预测性返回的缩放动画（2026-09-29）

**触发**：负责人「手势返回不释放，会有缩放动画，关闭这个效果」。

**拍板（四选一，`AskUserQuestion`）**：① 换 `FadeForwards`（**采纳**）② 自实现「跟手不缩放」跟踪器 ③ 换 `Cupertino` 式滑动 ④ Manifest 关 `enableOnBackInvokedCallback`。选 ① 的理由：改动最小（一个 `ThemeData` 字段）、**零维护风险**（不触碰框架内部机理）、且 ②③④ 各有硬伤——② 需复刻框架内部 `handleStartBackGesture` 六件套、升级必复查；③ 换观感但同样无预览、且与「本项目 Android 走 M3」的基调不符；④ 副作用最大（全局关预测返回）且 **Android 17 起失效**。

**根因（读 Flutter 3.47 源码 + 清单 + 设备三方交叉，非猜）**

1. **系统侧开关是开着的**：`targetSdk = 36`（Flutter 3.47 默认，`packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:34`）+ 设备 Android 16 → 预测性返回**默认启用**；`android/app/src/main/AndroidManifest.xml` **未声明** `enableOnBackInvokedCallback`，`flutter_tools` 全文 grep 该字符串**零命中**（即 Flutter 不代注入）。故「系统会把返回手势交给 App」这一前提成立。
2. **Flutter 默认就把它接住了**：`PageTransitionsTheme._defaultBuilders`（`page_transitions_theme.dart:764-771`）给 Android 的默认 builder 是 **`PredictiveBackPageTransitionsBuilder`**（iOS/macOS → Cupertino；windows/linux → Zoom）。
3. **缩放来自哪一行**：手势进行中（`route.popGestureInProgress == true`）该 builder 走 `_PredictiveBackSharedElementPageTransition`，用 **`Transform.scale` 把当前页缩到 `_kMinScale = 0.90`**（`predictive_back_page_transitions_builder.dart:350 / 385 / 520-540`）+ `MediaQuery.displayCornerRadiiOf` 的 `ClipRRect`（无设备圆角信息时回退 `_kDeviceBorderRadius = 32.0`）+ `Opacity` 淡出 + `Transform.translate` 位移。**这就是「手指未松、页面先缩成圆角卡片」的全部来源**。
4. **排除法（免得误伤）**：全仓 grep `Transform.scale` / `ScaleTransition` / `AnimatedScale` **零命中**；`lib/ui/book_card.dart:115` 的 `Hero(tag: 'book-cover-…')` **无对端**（详情页/阅读页无同名 tag，是死 Hero）→ 不产动画。两处都排除后，唯一来源就是 3。

**「换掉 builder 会不会把返回功能弄坏」——不会，有明确回落**

`FadeForwardsPageTransitionsBuilder` **不含** `_PredictiveBackGestureDetector`，系统手势不再被 App 接管；此时 `WidgetsBinding._handleCommitBackGesture`（`widgets/binding.dart:1196-1205`）在 `_backGestureObservers.isEmpty` 分支**退回普通 `handlePopRoute()`**。故功能等价，代价仅是「拖动过程无跟手预览」——松手后播完整转场。

**为什么必须写全五个平台（本批最容易踩的一脚）**

`_PageTransitionsThemeTransitionsState.build:868-898` 对 `builders[platform] == null` 的**回退是 switch**（不是「用 default 继承」）：`iOS => Cupertino`，**`android` / `fuchsia` / `windows` / `macOS` / `linux` → `Zoom`**。所以只传 `{android: FadeForwards}` 会把 **macOS 从 Cupertino 悄悄退化成 Zoom**——即把本批要关的缩放效果**从另一个平台引回来**。故 `kAppPageTransitions` 逐平台写全五个，测试用 `isNotNull` 逐平台锁住。

> 顺带记一条**文档与代码不一致**的坑：`page_transitions_theme.dart:757-759` 的 doc 注释仍写「默认 android/windows/linux = Zoom」，但代码 `_defaultBuilders` 早已把 android 改为 PredictiveBack、linux 仍是 Zoom。**一律以代码为准**（与「玻璃库文档承诺未实现行为」同类）。

**改动**

1. `lib/theme/app_theme.dart`：新增定向导入 `import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;`（该类型定义在 `src/cupertino/route.dart`，**不经 `material.dart` 导出**，定向引可避免整包 cupertino 与 material 的同名符号冲突）；新增 `kAppPageTransitions`（含根因 / 处置 / 代价 / 「Windows·Linux 未动待定」四段 doc）；`AppTheme._build` 增 `pageTransitionsTheme: kAppPageTransitions`（浅深共用同一份映射，避免两套主题观感漂移）。
2. `test/ui/app_theme_test.dart`：新增 group「页面转场」**4 条**（同款定向 cupertino 导入）。文件 **6 → 10 条**。
3. **PRD 未改**（有意）：全仓 grep `docs/PRD.md` 的 `转场|动画|过渡|transition` **零命中**——PRD **没有**任何转场/动画类需求条目，本批是纯实现层调整，强行补一条 v2.10 反而是把实现细节写进需求文档。

**测试（`test/ui/app_theme_test.dart` 新增 group）**

| 用例 | 断言要点 |
|---|---|
| Android 用 FadeForwards | `isA<FadeForwardsPageTransitionsBuilder>()` + **两条反向断言** `isNot(isA<PredictiveBackPageTransitionsBuilder>())` / `isNot(isA<ZoomPageTransitionsBuilder>())`——反向断言才是本用例的价值：把「又被改回缩放」直接测红 |
| 浅 / 深共用同一套 | 两套主题的 android builder `runtimeType` 相等 |
| 其余四平台逐字保留默认 | iOS / macOS = Cupertino，Windows / Linux = Zoom（证明未扩大范围） |
| 五平台均有显式声明 | 逐平台 `isNotNull`，`reason` 写明「缺显式声明会落到 Zoom 回退」（见上文「为什么必须写全」） |

**一条「不冲突」的核证（免得后人重复排查）**：`kAppPageTransitions` 属**路由（`Navigator`）层**、由 `MaterialApp.theme` 注入；设置页大标题的收起是 `GlassLargeTitleController` **自持 `ScrollController`** 的滚动进度驱动（§2.47），两者**无共享状态**。且 `settings_page_test` 的宿主是 `MaterialApp(home: …)`、**不经任何路由转场**，故该文件对本批**不构成覆盖**也**无需改动**——本批未为其加断言，理由是结构自明而非漏测（已在「复核边界」留档）。

**文档回填两轮**

- **字符串轮**（`转场|pageTransitions|PageTransitions|PredictiveBack|FadeForwards|ZoomPage|预测性返回|enableOnBackInvoked`）：`docs/` 与 `CHANGELOG.md` 命中 3 处（`tech-usage.md:485` / `:1262`、`CHANGELOG.md:126`）——**全部是「玻璃弹窗关闭转场」**语义（`GlassDialog` 关闭动画），与页面路由转场零交集，**不需要改写**。
- **语义轮**（`缩放|手势返回|返回手势|路由动画|页面动画|transitionDuration`）：命中全部是**内容层缩放**（`US-12` 漫画缩放、`FMT-02` 缩放、`META-05` 缩略图、`META-07` 缩放至不溢出），同样零交集。
- **结论**：本批 **无旧表述需要推翻**，只需新增条目（与 §2.47 不同——那次抓出了一处被推翻的语义）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze                      # 0 error / 0 warning / 7 条既有 info
/c/src/flutter/bin/flutter test --timeout 30s test/ui/app_theme_test.dart   # +10: All tests passed!
bash tool/test.sh ui                                                        # +132: All tests passed!（128 → 132）
bash tool/test.sh data                                                      # +205: All tests passed!
bash tool/test.sh reader                                                    # +226: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` / `reader` 三组为本批实跑（覆盖 `AppTheme` 的全部引用方：`lib/app.dart` / `lib/meta/synth_cover.dart` / `lib/reader/reading_prefs.dart` / `lib/typography/reader_settings.dart` / `lib/ui/reader_settings_bar.dart` / `lib/ui/settings_page.dart`，经全仓 grep 逐一对照 `data`·`reader`·`ui` 三组分布而确定）；`parse` 组未跑（`test/epub/`、`test/format/` 与 `AppTheme` 零交集）。**真机观感未复跑**——本批核心是「手指未松时不再缩放」，其验收必须由负责人在 Android 16 实机上滑动手势确认：① 拖动过程中**不再出现圆角缩小**；② 松手后页面正常返回（无跟手预览、播完整转场）；③ 系统返回键 / 导航栏返回仍工作。**Windows / Linux 的 Zoom 按钮返回转场是否也换掉，待负责人定**（本批未动）。

### 2.49 弹层形态统一：去横条 + 禁上划拖拽关闭 + 关掉点击放大与光晕（2026-09-29）

**触发**：负责人「去除弹框点击会有放大高亮特效，不需要上划的弹框，去除小横条」。

**拍板（两问两答）**：①「上划」= **禁止拖拽关闭手势**（底部滑入的入场动画保留），**非**改成居中弹框；② 范围 = **全部弹层统一生效**（设置页选择 ×2、书架长按操作单、详情页分组、阅读页目录 / 书签 / 搜索 / 外观，共 6 处）。

**根因（与 `GlassNavScaffold.extendBody` 默认 `true` 完全同类的一类坑）**

`GlassOverlays.showSheet`（`lib/ui/glass_kit.dart`）**只透传了 `isScrollable` 与 `showDragIndicator` 两个参数**，其余全部吃玻璃库默认值——而负责人的四个症状**与库参数逐一对上**：

| 负责人症状 | 玻璃库参数 | 库默认 | 库 doc 原文 / 机理 | 处置 |
|---|---|---|---|---|
| 「点击放大」 | `interactionScale` | **1.01** | "Visual scale feedback on touch"；`stretch.dart:249` 按下时 `pressed ? interactionScale : 1.0` | 传 `1.0` |
| 「点击高亮」 | `enableInteractionGlow` | `true` | "Glint follows finger"（光点跟手） | `false` |
| 「点击高亮」（第二条独立通路） | `enableSaturationGlow` | `true` | "Pulsation on touch"（触摸脉冲） | `false` |
| 「小横条」 | `showDragIndicator` | `true` | `glass_modal_sheet_internal.dart:294` `if (showDragIndicator) Positioned(top: 0, height: 44, child: handleZone)`——**横条与那 44px 拖拽区是同一个东西** | `false` |
| 「上划」 | `enableDrag` | `true` | `glass_sheet.dart:433` `if (widget.enableDrag)` 加 `GestureDetector` 支持下拖关闭 | `false` |

> 这类坑的通用识别法：**薄封装只暴露少量参数时，未暴露的参数会以「库默认值」静默生效**。本项目已第二次踩（前一次是 `extendBody`，那次让 7 个页面同时漏避让顶栏）。排查「行为不对但代码没写」时，先列出所调 API 的**全部参数默认值**逐条对照。

**处置（`lib/ui/glass_kit.dart` 一处改、6 处弹层同时生效）**

1. 玻璃档 `GlassSheet.show` 追加五项：`showDragIndicator: false` / `enableDrag: false` / `interactionScale: 1.0` / `enableInteractionGlow: false` / `enableSaturationGlow: false`。
2. 「关」档同步：`showModalBottomSheet(enableDrag: false)`，并**删去原先自绘的 36×4 拖拽指示条**（那是**本薄封装自己画的**，非库的——两处横条来源不同，别混为一谈）。
3. **删掉 `showDragIndicator` 参数本身**：改后全仓**零调用者**（同一提交内 grep 确认），按「删无调用者」先例（同 `setFolderOrder`）删净；库侧仍支持该参数，将来真需要再显式加回。


**为什么硬编码而不做成参数**：这四项是**项目统一口径**（负责人要求「全部弹层」），不是个别页面的诉求。做成参数就必须在 6 个调用点各传一次，任一处漏传即回潮；硬编码后连「库改默认值」也不影响本项目。

**边界（写清免得后人误判为漏做）**

- `enableDrag: false` 后库的 `_DismissibleSheetWrapper` **完全不加 `GestureDetector`**（`glass_sheet.dart:433` 的 `if` 分支跳过、直接返回 child）——**零副作用**，不是「加了个不响应的手势层」。
- **底部滑入的入场动画保留**：`GlassSheet.show` 的 `transitionBuilder` 是独立的 `SlideTransition`（`glass_sheet.dart:319`，`Offset(0,1) → zero`，350ms），与 `enableDrag` **无关**。负责人要的是「禁止上划拖拽关闭」，故这条不动。
- **点遮罩关闭不变**：`isDismissible` 仍是库默认 `true`。
- **未采纳的替代方案**：库另有 `suppressInteractionOnChildren`（"Smart Silence"，机制见 `glass_sheet.dart:449-493 / 617-620`：子组件被交互时抑制 sheet 自身特效）——它能做到「点选项行时弹框不发光」，但直接关掉三个特效**更彻底**（连点弹框空白处也不放大），且少一层「只在子组件交互时生效」的隐式语义，故未采用。**记录在此免得后人重复调研。**
- **未动**：`stretch`（库默认 `0.5`，拖拽时的液态拉伸）——「拉伸」不属负责人描述的「放大」，且 `enableDrag: false` 后已无拖拽手势触发它；`topBorderRadius` / `margin` 等外观参数同样未动（未扩大范围）。

**测试**

| 文件 | 变更 | 断言要点 |
|---|---|---|
| `test/ui/glass_sheet_form_test.dart` | **新建 1 条** | 玻璃档：`GlassSheet` 四个字段硬编码断言（`showDragIndicator == false`、`interactionScale == 1.0`、`enableInteractionGlow == false`、`enableSaturationGlow == false`）+ **下滑 300px 后弹层必须仍在**（`enableDrag` 落在库私有 `_DismissibleSheetWrapper` 上、**无公开字段可读**，只能行为验证）+ 收尾验证正常关闭路径未被破坏 |
| `test/ui/glass_off_fallback_test.dart` | 条数不变（8），断言语义加强 | 关档补 `BottomSheet.enableDrag == false`（`BottomSheet.enableDrag` 是**公开字段**，可直接断言）+ 「36×4 横条缺席」（`byWidgetPredicate` 查 `Container.constraints` 的 `maxHeight == 4 && maxWidth == 36`）+ 订正原注释「+ 拖拽指示条」（已删） |

**两条测试口径（可复用）**

1. **期望值硬编码字面量，且断言读「库 widget 自身的字段」**：本文件断言的是 `GlassSheet.interactionScale` 等**库的**公开字段，**不是**薄封装暴露的常量——引用自己的常量就是同义反复、永远红不了（同 `shelf_geometry_contract_test` 的既定口径）。这样能同时抓「参数没透传」与「透传了错值」两类错。
2. **渲染玻璃档弹层是可行的、且不慢——但必须 `pump(Duration)` 而非 `pumpAndSettle`**：项目既有口径是「玻璃档弹层一律不渲染」（`glass_off_fallback_test.dart` 头注释：软件光栅下每帧数百 ms）。本批实测：只推 2 帧（`pump()` + `pump(400ms)`，覆盖 350ms 入场动画）**整个文件 1 秒跑完**——因为慢的是**逐帧**渲染累积，`pumpAndSettle` 会一直推到所有动画与玻璃动效静止才停，才是数百 ms × N 帧。故「玻璃档不能测」应精确表述为「**玻璃档不能用 `pumpAndSettle` 测**」。

**文档回填两轮**

- **字符串轮**（`showDragIndicator` / 拖拽指示条 / 横条 / 上划）：命中 4 处——`lib/ui/glass_kit.dart`（本次改动本体）、`test/ui/glass_off_fallback_test.dart:233`（**过时注释**，已订正）、`docs/tech-usage.md:481`（M2b-T07 的**历史事实层**记录「`showSheet` 补 `isScrollable`/`showDragIndicator`」，按「事实层原文留证 + 补后续改道指针」处理，见下）、`test/reader/fullscreen_progress_test.dart:28`（阅读页**进度指示条**，同名不同物，不动）。
- **语义轮**（`splash` / 水波纹）：命中 5 处**全是卡片与搜索框的 `InkWell`**（`settings_kit.dart:25-26`、`settings_page.dart:212`、`shelf_page.dart:755`、`settings_kit.dart:250`）——与弹层无关，保留。
- **`docs/tech-usage.md:481` 的改道指针已补**（见该行下方引用块）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze
/c/src/flutter/bin/flutter test --timeout 30s test/ui/glass_sheet_form_test.dart test/ui/glass_off_fallback_test.dart  # 00:01 +9: All tests passed!
bash tool/test.sh ui                                                        # 01:25 +133: All tests passed!（132 → 133）
bash tool/test.sh data                                                      # 00:27 +205: All tests passed!
bash tool/test.sh reader                                                    # 00:31 +226: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` / `reader` 三组为本批实跑——三组是 `lib/ui/glass_kit.dart` 引用方的完整分布（6 处弹层调用点分属 `test/ui/`、`test/meta/detail_test.dart`（data 组）、`test/reader/`）；`parse` 组未跑（`test/epub/`、`test/format/` 与弹层零交集）。**真机观感未复跑**——本批四条均为**观感/手感**类改动，必须由负责人在真机逐项确认：① 6 处弹层**都没有横条**；② 上下滑动弹层内容**不再触发关闭**（点遮罩仍可关）；③ 点击选项时**弹框不再整体放大、不再发光**；④ 底部滑入的入场动画仍在（这是保留项，非遗漏）。**未动项待拍板**：`stretch`（拖拽液态拉伸）与弹层圆角 / 外边距等外观参数；若真机上仍看到按压形变，再来关 `stretch`。

### 2.50 导航栏去掉触摸「放大」形变（2026-09-29）

**触发**：负责人「移除导航栏放大特效」。

**根因（§2.49「薄封装没透传的参数会静默生效」的第二个实例，隔一小时再踩一次）**

`GlassNavBar.build` 调 `GlassTabBar.bottom(…)` 时**未透传 `interactionBehavior`** → 吃库默认 **`GlassInteractionBehavior.full`**。库该枚举四档（`lib/src/types/glass_interaction_behavior.dart:21-56`）：

| 档位 | 库 doc 原文 | `hasGlow` | `hasScale` |
|---|---|---|---|
| `none` | "No interaction feedback — **fully rigid** glass, no directional glow." | ✗ | ✗ |
| `glowOnly` | "Directional glow only… Suitable for **flat navigation bars** that should remain **spatially stable** while still feeling reactive to touch." | ✓ | ✗ |
| `scaleOnly` | "Physical **spring-scale only** — the bar inflates subtly on press and snaps back on release." | ✗ | ✓ |
| **`full`（库默认）** | "Full iOS 26 interaction — directional glow **and** physical spring-scale… the glass **inflates** subtly (bottom-anchored spring) on touch." | ✓ | ✓ |

所以「导航栏放大」= `hasScale` 的弹簧膨胀（`scaleOnly` / `full` 才有）。

**处置（`lib/ui/glass_kit.dart` `GlassNavBar`，一行）**

显式传 **`GlassInteractionBehavior.glowOnly`**——去形变、保留手指位置的柔和高光。选它而非 `none` 的依据：① 负责人原话只要求移除「**放大**」、未提光晕；② 库 doc 恰把这个档位推荐给导航栏（见上表 `glowOnly` 行）。消费点 `tab_bar_bottom_layout.dart:390` 的 `interactionScale: widget.interactionBehavior.hasScale ? … : 1.0` 据此把缩放钉成 `1.0`。

> **若负责人要的是「连高光也不要有」**：改传 `GlassInteractionBehavior.none` 即可（一行，零成本回退）。已在 `GlassNavBar` 的 doc 与 CHANGELOG 里写明这个旋钮，免得后人重新调研。

**边界**：「关」档的 Material `NavigationBar` 不受影响（它本无此缩放；选中指示器动画属 Material 标准行为）。宽屏的 `NavigationRail` 同理。

**测试**

| 文件 | 变更 | 断言要点 |
|---|---|---|
| `test/ui/glass_nav_form_test.dart` | **新建 1 条** | `GlassTabBar.interactionBehavior == GlassInteractionBehavior.glowOnly`（**硬编码字面量**、读**库 widget 自身字段**，非薄封装常量）+ **反向断言 `isNot(full)`**（把「又被改回库默认」直接测红）+ `hasScale == false` + `hasGlow == true` |

宿主沿用 `glass_off_fallback_test.dart` 档位用例的写法（`Scaffold(bottomNavigationBar: GlassNavBar(...))`），`pumpWidget` 后直接断言——**无入场动画，故不需要 `pumpAndSettle`**（口径同 §2.49 口径 2）。

**文档回填两轮**

- **字符串轮**（`interactionBehavior` / `hasScale` / `hasGlow`）：除本批新增的代码注释、调用与测试外，`lib/` 与 `docs/` **零命中**——`GlassNavBar` 此前从未提及触摸反馈，故**无旧表述需要推翻**，只新增条目。
- **同族参数的命中已逐条排除（不是「零命中」，别误读成漏改）**：`interactionScale` 命中 `lib/ui/glass_kit.dart:595/597/655` 与 §2.49 各处 → **全部来自上一批的弹层改动**（`GlassSheet.interactionScale`，库默认 1.01），是**同名参数的另一控件**，与导航栏的 `interactionBehavior` 无关；`放大` / `缩放` 另有两处同名不同物——§2.21（`FMT-02` 图片页「点页全屏缩放」）与 §2.43 一带（书架拖拽悬停反馈的「恒定 1.05 放大」）。以上**一律不改写**，避免误伤既有留档。
- **行号口径（本会话刚踩）**：核对时**以章节号为准**——本批在 §2.17 表格后补的改道引用块已使其后的行号整体下移，例如「点页全屏缩放」由改动前的 557 行变为 **559 行**（§2.21）。文档内引用行号**必须实测后写**，不能沿用先前 grep 的旧行号。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze
/c/src/flutter/bin/flutter test --timeout 30s test/ui/glass_nav_form_test.dart   # 00:00 +1: All tests passed!
bash tool/test.sh ui                                                             # 01:19 +134: All tests passed!（133 → 134）
bash tool/test.sh data                                                           # 00:19 +205: All tests passed!
bash tool/test.sh reader                                                         # 00:23 +226: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` / `reader` 三组为本批实跑。`GlassNavBar` 的引用方经全仓 grep 确认为 `lib/ui/home_shell.dart`（生产唯一）+ `test/ui/glass_off_fallback_test.dart` / `test/ui/glass_nav_form_test.dart`——**全在 `ui` 组**，故 `data` / `reader` 两组实为保险性复跑（本批未触及 `showSheet` 等其他浮层路径）。`parse` 组未跑（零交集）。**真机观感未复跑**：需负责人在真机确认点击底栏 tab 时**胶囊不再膨胀**（手指位置的柔和高光仍在——这是保留项，非遗漏）；若仍嫌高光，回退旋钮见上。

## 测试分组与局部执行（2026-09-23）


> 动机：全量 360+ 用例每次跑太耽误时间。测试**按目录天然成四组**，改动哪层跑哪组；
> **每个开发批次只跑与改动相关的分组；全量测试仅在负责人明确发出「全量测试」指令时执行**（2026-09-23 拍板；
> 批收官不再默认跑全量，任务级提交节奏的纪律不变）。

| 组 | 目录/文件 | 性质 | 命令（或 `bash tool/test.sh <组>`） |
|---|---|---|---|
| parse 解析层 | `test/epub/`、`test/format/` | 纯 Dart，最快；含 14 本脏书 fixtures 回归 | `flutter test --timeout 30s test/epub test/format` |
| data 数据层 | `test/library/`、`test/meta/`、`test/storage/`、`test/task/` | 多为纯 `test()` + 临时目录（`detail_test` 含 widget 段） | `flutter test --timeout 30s test/library test/meta test/storage test/task` |
| reader 阅读器 | `test/reader/`、`test/typography/`、`test/perf/` | 含 `testWidgets`，FakeAsync 铁律适用 | `flutter test --timeout 30s test/reader test/typography test/perf` |
| ui 界面层 | `test/ui/`、`test/widget_test.dart` | 最慢（`testWidgets` 密集） | `flutter test --timeout 30s test/ui test/widget_test.dart` |
| fast 快速反馈 | parse + data | 改数据/解析层时的日常回路 | `bash tool/test.sh fast` |
| all 全量 | 全部 | **仅负责人明确下令时**（2026-09-23 拍板） | `flutter test --timeout 30s` |

- 分组入口统一走 `tool/test.sh`（自带 `--timeout 30s` 与组名校验）；**无参数不再默认全量**（直接报 usage 退出）。
- 归档调整：`test/epub_fixtures_test.dart` → **`test/epub/epub_fixtures_test.dart`**（根目录散件归组；fixture 路径是包根相对 `Directory('test/fixtures')`，移动不影响取数，README / 架构文档 / 注释共 8 处引用已同步）。
- `test/widget_test.dart` **留在根目录不搬**：文件名本身是「阻止 `flutter create` 注入 counter 模板」的机制，动名字会引回模板测试；归组由 `tool/test.sh` 显式列出。
- 改动 `lib/ui/**` 或导航链路 → 起码跑 `ui + 受影响组`；只改解析/仓储 → `fast` 即可；**提交前最后一轮按批次纪律跑全量**。
- **`--timeout 30s` 对 `testWidgets` 无效（必须再接一层）**：`testWidgets` 用 `timeout: timeout ?? binding.defaultTestTimeout`，而 `AutomatedTestWidgetsFlutterBinding.defaultTestTimeout` 固定 **10 分钟**——CLI 的 `--timeout` 只改 runner 默认、被显式值压过。含 `testWidgets` 的文件须在 `main()` 首行调 `test/test_config.dart::capTestTimeout()`（置 30s），30s 兜底才真正生效（实测：reader 组「挂满 10 分钟」→ 暴露真挂 → 修复后 22s / 145 用例）。
- **`dispose()` 发起的假区保存 = 跨区死锁源**：`AtomicFile._tails` 按路径串行化，假异步区发起的保存持有 gate，其完成回调只有 `pump` 能排空；测试体回到活区 `runAsync` 写同一路径会 await 队尾 gate **永久挂起**。用例在 `pumpWidget(const SizedBox())` 关书后补 `await _settle(tester, rounds: 20)` 排空。
- **断言正文段落须 `findRichText: true`**：正文由 `InlineParagraph` → `Text.rich`（RichText）渲染，`find.text` / `find.textContaining` 默认**不匹配富文本**（标题是纯 `Text`、能匹配，故只错在正文断言上）。
- **防假绿**：构造「某状态不成立」的用例时补**非空验证**（界面确实渲染了内容 / 目标不在场），否则「什么都没发生」时布尔断言恒真。
- **「二次打开」类测试必须先拆树**：`pumpWidget(buildApp())` 对**同类型无 key** 的 widget 走 `Widget.canUpdate` → Element/State **复用**（`initState`/`dispose` 都不跑、`ScrollController` 是第一次的）——直接再 pump 一次的「关书再开」是假绿（原「同版面 localHint 重开」用例即栽在此）。必须先 `pumpWidget(const SizedBox())` 把树拆掉（真 dispose），排空假区保存后再开。
- **「稍后到货」用 `gates` 夹具，「永不到货」用 `hangIndices`**：`_FakeSource.gates[i]` 让 `content(i)` `await` 一个 `Completer.future`、测试择机 `complete()` 放行——稳定构造「某章占位、稍后补齐」的中间态（回归④）；`hangIndices` 是永不完成（回归② 冻结布局用）。二者别混用。
- **预期会红的几何断言放最前**：如回归④ 的 d1/d2 距离主句放在非空验证**之前**——修前红时直接报出实测漂移量（`d1=16.0 d2=-794.0`，810px），而非被非空验证的失败信息带偏排查方向。


### 2.51 书卡对齐 anx：封面投影/圆角 + 长按「抬起反馈」（2026-09-29）

**触发**：负责人「采用 anx 书架图书宫格样式和长按动画和效果」（中途澄清为「**图书宫格样式**和长按动画和效果」）。三项拍板：① 长按效果**只要「抬起视觉反馈」**（不跟手）；② **对齐阴影 + 圆角**；③ 操作单**保持现有玻璃模态**（不改 anx 的非模态形态）。**PRD 无条目增减、无契约变更**（`US-06` / `LIB-01` 只要求「展示格式」与「书架展示」，视觉数值不在条文内）。

**取证：anx 的「长按动画」其实不在 anx 里**

| 表象 | 真相（均实读，带 `路径:行号`） |
|---|---|
| `book_item.dart` 的 `onLongPress` | `:54-56` 只有一句裸的 `showModalBottomSheet`——**零动画、无 `HapticFeedback`** |
| anx 的「长按效果」真身 | `bookshelf_page.dart:388-395` 的 `ReorderableBuilder`（pub 包 `flutter_reorderable_grid_view`）：`enableDraggable: true`、`longPressDelay: 300ms`、**`onReorder: (reorderedListFunction) {}` 空实现**、`onDragStarted` 里开操作单 → **借长按拖拽拿抬起反馈，不为重排** |

包内抬起反馈的数值（全部实读）：

| 项 | 出处 | 值 |
|---|---|---|
| 放大倍数 | `reorderable_builder.dart:41` | `_defaultFeedbackScaleFactor = 1.05` |
| 放大动画 | `draggable_feedback.dart:59-64`、`reorderable_animation_config.dart:76/107-108/120-121` | `AnimatedContainer`：`dragFeedbackDuration` 默认 **150ms**、曲线兜底 **`Curves.linear`** |
| 阴影渐入 | `reorderable_draggable.dart:77-89/161-165` | `AnimationController(duration: 250ms)` + `DecorationTween`（`forward()` 不传曲线 → 同为 linear） |
| 阴影四参数 | `reorderable_draggable.dart:61-71` | `black.withOpacity(0.2)` / spread 5 / blur 6 / offset (0,3)（anx 未传 `dragChildBoxDecoration` → 吃该默认值） |
| 跟手与原件 | `draggable_feedback.dart:79-90`、`reorderable_draggable.dart:151-157` | 反馈层 `_offset` 重新居中后**跟手**；原件 `Visibility(visible: false, maintainSize: true)` 留在原处 |

**处置（三项）**

1. **封面投影对齐 anx** → `book_card.dart` 的 `const BoxShadow kBookCoverShadow`：`Colors.grey.withAlpha(100)` / spread 5 / blur 10 / offset (0, 2)（anx `book_item.dart:69-75`）。写 `0x649E9E9E` 字面量：`withAlpha` **不是 const 构造**，而 `0x64` = 100、`0x9E9E9E` = `Colors.grey` 的 RGB，两者等价。
2. **封面圆角 6 → 8**（anx `book_cover.dart:30` `radius ?? 8`）→ 提为 **`kBookCoverRadius`**，放进 `shelf_geometry.dart`（**圆角是几何量**；`shelf_geometry.dart` 的范围声明同步改写为「追加封面圆角、阴影仍不在此列」）。
3. **长按抬起反馈**（自实现，不引包）：`AnimatedScale(1.05, 150ms, Curves.linear)` → `AnimatedContainer(250ms, 阴影)` → 原 `Card`。`_lifted` 由 `_handleLongPress` 置位、`await` 回调后复位；阴影画在卡片**背景**（`DecorationPosition.background`）与静止投影**叠加**——anx 同为两层。

> **⚠️ 后续改道（2026-09-29，见 §2.54）**：上段处置 ③ 里**阴影的落点**已改写——负责人反馈「图书长按会有灰色背景，且书籍封面没有圆角，太暗了」，根因是**卡片没有底板**（`Card` 透明、信息区透明）时把 `BoxShadow` 画在**整张卡**这一层，而 `BoxShadow` 是**填充形状** ⇒ 长按看到一张**方角灰板**（盖住封面圆角 + 整卡变暗）。现在这颗 `AnimatedContainer` 挂在**封面外框**上（`kBookCoverSurfaceKey` 的祖先）并带 `kBookCoverRadius` 圆角；同时 `InkWell.highlightColor` 置透明（长按的 pressed 高亮是墨迹特性、会常驻）。**未被推翻的部分**：放大 **1.05 / 150ms / `Curves.linear`**、阴影 **250ms** 与四参数（`black α0.2` / 5 / 6 / (0,3)）、以及**与静止投影叠加**的两层关系——全部一字未动。本表 `book_card_lift_test.dart` 那一行也因此**追加了 2 条断言**（阴影容器 `borderRadius == 8`、阴影须画在封面外框这一层）。原正文保留作事实留证，勿删。

**⚠️ 如实登记的代价（拍板 ① 的必然后果）**：anx 的投影是**固定灰、不随主题**，故深色主题下这颗投影比背景**亮**、观感接近一道浅色描边。本批照抄（负责人拍板「对齐阴影」）；要改回跟主题走只换 `kBookCoverShadow.color` 一行。

> **⚠️ 后续改道（2026-09-29，见 §2.53）**：上段「如实登记的代价」中的**深色主题投影**已被改写——负责人真机截图反馈「**阴影太强烈，影响观感**」（与上段预测的现象逐字吻合：一圈浅色描边 + 相邻卡片光晕叠成亮带），拍板**跟主题走**：深色主题改用 `colorScheme.shadow`（近黑），**浅色主题仍照抄 anx 的固定灰**。**未被推翻的部分**：浅色分支的四个数值、以及**抬起阴影与静止投影叠加**的两层关系。原正文保留作事实留证，勿删。

**范围边界（不在「阴影 + 圆角」内 → 未动，如实登记）**

- **`ClipRSuperellipse` 超椭圆裁剪** + **`RoundedSuperellipseBorder(width: 0.3, color: Colors.grey)` 描边**（anx `book_cover.dart:125-131`）：二者都是 **Flutter 自带**能力（`widgets/basic.dart:1125` / `painting/rounded_rectangle_border.dart:226`，**不需要引依赖**），但本次未做——想跟随只需换掉 `ClipRRect` 并补一层 `border`。
- **字号**：仍本项目现状（书名 13 / w600、作者·进度 11）。anx 是 13 / bold 与 **9**——9 在手机屏偏小，拍板保持 11。
- **操作单**：仍玻璃模态（带遮罩），未复刻 anx 的非模态 `Container`。

**为什么把「何时复位」做成一条 API 契约**

抬起反馈必须知道「什么时候落回」。故 `BookCard.onLongPress` 与 `ShelfGrid.onBookActions` 由 `VoidCallback` 改为 **`Future<void> Function()`**，`shelf_page` 随之拆成两段：

- `_showBookActions(record)`：await `GlassOverlays.showSheet`，**Future 在操作单关闭时即完成**；
- `_runBookAction(record, action)`：`unawaited` 派发（继续阅读 / 详情 / 移出书架）。

反例说明必要性：若沿用「动作走完才算完成」的写法，用户点「继续阅读」后卡片会**一路悬着**（`_openBook` 的 await 覆盖整个阅读会话）。`BookCard._handleLongPress` 用 `try/finally` 保证回调抛错时也落回。

**测试**

| 文件 | 变更 | 断言要点 |
|---|---|---|
| `test/ui/shelf_geometry_contract_test.dart` | 常量组 +1 断言；**+1 条用例** | `kBookCoverRadius == 8`（硬编码）；新用例读**渲染对象** `RenderDecoratedBox.decoration`，断言圆角 8 与投影四参数（`0x649E9E9E` / 5 / 10 / (0,2)），并断言裁切 `ClipRRect` 用**同一**圆角（否则投影从裁切角露出） |
| `test/ui/book_card_lift_test.dart` | **新建 2 条** | 长按后**真实渲染尺寸** ×1.05（宽高各 `closeTo` 且中心不变）；`AnimatedScale.scale/duration/curve` = 1.05 / 150ms / linear、`AnimatedContainer.duration/decoration.boxShadow` = 250ms / `0x33000000`+5+6+(0,3)；回调 Future 完成后尺寸与两条目标值全复位（阴影列 `isEmpty`）；`onLongPress == null` 时长按**不抬起** |

**⚠️ 量放大的坑（本批实测踩到，可复用）**：放大走 `Transform`，而 `tester.getRect` 的 `localToGlobal` 计入的是**祖先**变换——直接量 `find.byType(BookCard)` 量到的是「变换的宿主」`RenderTransform` **自己**，其尺寸**不含**自身变换（实测恒为 120 = 缩放前的值，看着像「效果没生效」）。必须量变换**子树内**的 widget（本测试量 `AnimatedScale` 里的 `Card`）。**结论：先确认测量对象落在变换的哪一侧，再怀疑实现。**

**文档回填两轮**

- **字符串轮**（`圆角` / `阴影` / `投影` / `_kCoverRadius`）：命中 `docs/tech-usage.md` §2.40 拍板 ① 「…**阴影**一律保持本项目现状」——与本批拍板**直接冲突**，已在该拍板列表后插入**改道引用块**（指向本节，写明「哪些被改写、哪些未被推翻」），原正文保留留证。`CHANGELOG.md` 中 UI 重做批次③那条同句**不追改**（历史条目按「留档不追改」口径，覆盖关系由引用块承担）。
- **语义轮**（按「被推翻的约束语义」再 grep：`保持本项目现状` / `只动布局几何` / `一律不在此列` / `不照搬 anx`）——**字符串轮漏掉的三处**：① `shelf_geometry.dart` 范围声明（已改写）；② `shelf_grid.dart` 头注「字号、颜色、阴影一律保持本项目现状（不照搬 anx）」（**已改写**为「字号、颜色保持现状；封面投影与圆角已于 2026-09-29 对齐 anx」）；③ §2.40 同上。**未改**：§2.38 一带的「去卡片底板 + `BoxShadow`」——本批只换投影**数值**，不改「不用卡片底板」这条结论。
- **行号口径**：本节第三方行号均为本批**实读**（anx / pub 包 / Flutter SDK 三处，未沿用旧 grep 值）；文档内互引用**以章节号为准**（本节与 §2.49 的引用块插入后，§2.40 及以后行号整体下移，勿凭旧行号定位）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze
/c/src/flutter/bin/flutter test --timeout 30s test/ui/book_card_lift_test.dart           # 00:00 +2: All tests passed!
/c/src/flutter/bin/flutter test --timeout 30s test/ui/shelf_geometry_contract_test.dart  # 00:00 +6: All tests passed!
bash tool/test.sh ui                                                                     # 00:57 +137: All tests passed!（134 → 137）
bash tool/test.sh data                                                                   # 00:23 +205: All tests passed!
bash tool/test.sh reader                                                                 # 00:22 +226: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` / `reader` 三组为本批实跑。改动符号（`BookCard` / `ShelfGrid` / `onLongPress` / `onBookActions` / `kBookCoverRadius`）经全仓 grep 确认引用方只有 `lib/ui/shelf_page.dart` 与 `test/ui/`（**ui 组**）+ `test/meta/detail_test.dart`（**data 组**）——`reader` 为保险性复跑。`parse` 组未跑（零交集）。**真机手感未复跑**：需负责人确认① 长按抬起是否「有反馈但不突兀」（放大 1.05 / 150ms；曲线照抄包的 `linear`，嫌生硬可换 `Curves.easeOut`，一行）；② **深色主题下封面投影偏亮**是否接受（回退口径见上）。


### 2.52 无封面书籍采用 anx 默认封面（2026-09-29）

**触发**：负责人「采用anx 无封面书籍的默认封面」。两问两答拍板：① **只改占位控件**（新建共享默认封面组件，书架书卡与详情页封面共用；**不动** `META-07` 的画布合成渲染器与 PRD）；② **完全照抄 anx 取色**（底色 = `Colors.primaries[书名.hashCode % 18].shade200`，即每本书按书名哈希得到一张**浅色**卡片）。**PRD 无条目增减**（`META-07` 条文未改，理由见下「与 META-07 的关系」）。

**取证：anx 默认封面逐条对映**（均实读 `D:\Projects\anx-reader\lib\widgets\bookshelf\book_cover.dart`，本批行号）

| 本项目 | anx 出处 | 口径 |
|---|---|---|
| `defaultBookCoverColor(title)` | `:57-59` | `Colors.primaries[title.hashCode % Colors.primaries.length].shade200`（`%` 是欧几里得取模，负数亦非负 → **无需 `abs()`**，anx 同此写法） |
| `defaultBookCoverInk(bg)` | `:23-26` | `estimateBrightnessForColor(bg) == dark ? white : black` |
| 标题 `Text` | `:78-88` | `fontSize = 宽 × 0.12`、`bold`、`height: 1.2`、`maxLines: 3` + `ellipsis`、`crossAxisAlignment.start` |
| 作者 `Text` | `:92-100` | `fontSize = 宽 × 0.08`、`w300`、`maxLines: 1` + `ellipsis`，与标题之间一个 `Spacer` |
| 水印 `Icon` | `:106-117` | `Icons.book`、`size = 宽 × 0.8`、色 = 文字色 `withValues(alpha: 0.1)`、`Positioned(right: -padding*0.8, bottom: -padding*0.5)` + `Transform.rotate(15°)` |
| 内边距 | `:52-55`、`:71-72` | `EdgeInsets.all(宽 × 0.08)` |
| 尺寸基准 | `:47-49` | 全部按 `LayoutBuilder` 的 `constraints.maxWidth`（**封面宽度**）——故同一本书在书架与详情页大小一致，换列数也不跳 |
| 底色层 | `:65-66` | anx 用 `Container(color: backgroundColor)` |
| 外层裁剪 | `:133-146` | `SizedBox > DecoratedBox(foreground, ShapeDecoration(RoundedSuperellipseBorder)) > ClipRSuperellipse` —— **未采纳**，见下 |

调色板事实（`Colors.primaries`，SDK `material/colors.dart:1883-1905`）：长度 **18**，顺序 = red / pink / purple / deepPurple / indigo / blue / lightBlue / cyan / teal / green / lightGreen / lime / yellow / amber / orange / deepOrange / brown / blueGrey，**`grey` 被刻意省略**（注释理由：会让 app 显旧）。故 `shade200` 一档全是**浅色**。

**处置（本工程三处刻意处理，各有理由）**

1. **10% 透明的水印不是「半透明内容层」**：它叠在**不透明**底色之上，`UI-04` 约束的是容器 / 背景而非前景笔画 → 红线不破（理由同 `shelfGradientBackground` 用 `alphaBlend` 合规）。
2. **组件自带 `ClipRRect`**：anx 的水印靠**负偏移**故意画出封面之外（`right: -padding*0.8`、`bottom: -padding*0.5`），本组件用 `ClipRRect` 兜住裁切 → 调用方不必再包一层（也顺带把「探出的半本书」保持为 anx 的原始观感）。圆角由 `radius` 参数传入。
3. **底色画在哪一层按环境自适应**：有 `Material` 祖先 → `Ink`（底色进该 Material 的 ink 层，`InkWell` 水波纹画在它**之上**，与 `book_card.dart` 的 `Ink.image` 同一条口径；否则不透明底色会把 ripple 盖住）；无 `Material` 祖先 → `ColoredBox`（`Ink` 在无 `Material` 时**断言失败**；玻璃库页面即无 `Material` 祖先，见 PRD §11.4）。

> **⚠️ 后续改道（2026-09-29，见 §2.54）**：上段处置 ③ 的**整条自适应分支已删除**——底色**一律**走子树内的 `ColoredBox`，「有 `Material` → `Ink`」那条路被像素级实证否掉（`Ink` 是**墨迹特性**、由上层 `Material` 绘制，于是 ① **逃逸本组件的 `ClipRRect`** ⇒ 封面方角；② 落在封面外框投影的**填充**之下 ⇒ 整张封面被染暗）。**未被推翻的部分**：「无 `Material` 祖先 → `ColoredBox`」这一分支的结论完全成立，只是从「退回档」升为「唯一路径」（组件因此**不再依赖 `Material` 祖先**，玻璃库页面照常可用）；处置 ① ②（水印 10% 透明合规、组件自带 `ClipRRect`）**一字未动**。本表 `default_book_cover_test.dart` 那一行的 **④ 与 ⑤** 因此改写（断言 `ColoredBox` + **反向断言组件/书卡内无 `Ink`**），group ④ 更名为「底色画在**子树内**（不用 `Ink`：会漏裁 + 被投影染色）」。**代价（如实登记）**：`InkWell` 的水波纹/高亮画在墨迹层，因而**不再压在封面之上**，只在透明的信息区可见——这正是 anx 的形态（其封面用 `Container(color:)` / `Container(decoration: image)`，同样不在墨迹层）。原正文保留作事实留证，勿删。

> **⚠️ 再次改道（2026-09-29，见 §2.57）**：上句「代价」的表述已被推翻——水波纹/高亮现已**整体关闭**（`splashColor` 透明 + `NoSplash` + `highlightColor` 透明），「只在透明的信息区可见」不再成立（什么都不露了），新代价 = **按下/长按完全无墨迹**。机制结论（墨迹画在子树之下、压不到封面）不变。

**未采纳（如实登记）**

- **`ClipRSuperellipse` 超椭圆裁剪 + `RoundedSuperellipseBorder(width: 0.3, color: Colors.grey)` 描边**（anx `:125-146`）：与 §2.51 同一项，是 Flutter 自带能力、**不需要引依赖**，但不在本次拍板范围内。
- **两个显示开关** `Prefs().showBookTitleOnDefaultCover` / `showAuthorOnDefaultCover`（anx `:62-63`）：本项目没有这两个设置项，**恒显示**。**不采纳开关 ≠ 改变默认观感**——两者默认值均为 `true`（`config/shared_preference_provider.dart:1133` / `:1142` 的 `?? true`，已实读），故「恒显示」正是 anx 未改设置时的表现。
- **`title.isEmpty ? '?' : title` 这处**是本项目**保留**的旧兜底（原占位实现即 `title.isNotEmpty ? first : '?'`）：anx 画空串。`META-01` 保证书名非空，故该分支实际不可达，仅作可见信号。

**代价（如实登记）**

- 底色取 `shade200` = **浅色**且**不随主题**（anx 原样），故**深色主题下书架会出现一片浅色小卡片**。要跟主题走只需换掉 `defaultBookCoverColor` 一行（但就偏离 anx 了）。
- `String.hashCode` 只保证**同一 SDK 版本内**稳定（本批三进程实测一致：`书0` = 832146738、`三体` = 98577346、`活着` = 644087628），**换 SDK 版本可能让同一本书换色**（纯观感）。若哪天要求跨版本稳定，改项目已有的确定性 FNV-1a（`lib/meta/synth_cover.dart` 的 `synthCoverCacheKey`）即可。

**与 `META-07` 的关系（未闭环，如实登记）**

`META-07`（PRD `:353`）的降级顺序是 ① **运行时绘制合成封面**（背景取主题色/纯色，书名大字居中、作者小字居中于其下，长书名自动换行/缩放至不溢出）→ ② 退回默认占位图，按「书名+作者+主题」缓存。本项目 `lib/meta/synth_cover.dart` 的 `CanvasSynthCoverRenderer`（`dart:ui` 绘制 + 32 张 LRU）**早已实现且有单测（`test/meta/synth_cover_test.dart`）但从未接 UI**。本批按拍板**只替换占位控件**、**未接**该渲染器 → 项目里暂时并存两条路径：

- **控件版默认封面**（`lib/ui/default_book_cover.dart`）——**在用**，替换的是 ② 的渲染形态；
- **位图合成封面**（`lib/meta/synth_cover.dart`）——**已实现未接线**。

`META-07` 条文**未改**（属于「是否要把渲染器接进 UI 并改写 ① / ② 的划分」这个更大的拍板，未擅自扩大范围）。**注意**：控件版与 ① 的差别是「取色来源」（书名哈希 vs 主题色）与「排版」（左上大字 + 左下小字 + 右下旋转水印 vs 居中书名 + 其下作者），谁「是 ① 谁 是 ②」需要负责人定。

**测试**

| 文件 | 变更 | 断言要点 |
|---|---|---|
| `test/ui/default_book_cover_test.dart` | **新建 9 条** | ① 取色：公式（`Colors.primaries[title.hashCode % 18].shade200`）+ `Colors.primaries.length == 18`（防 SDK 改表）+ **实测钉点**（`三体`→`indigo.shade200`、`活着`→`red.shade200`）+ `shade200` 档位锁定（`contains` 18 个 `shade200`）+ 换书换色；文字色对比四例。② 尺寸：120 宽 → 14.4 / 9.6 / 96 / 9.6，200 宽 → 24 / 16 / 160 / 16（**成比例而非固定值**）。③ 水印：**从 `Transform.rotate.transform` 矩阵反解角度**（`atan2(m.storage[1], m.storage[0])`）+ `Positioned` 负偏移 -7.68 / -4.8 + **手算真外接框**判「越过封面右/下缘」+ `ClipRRect` 圆角 8；320 字长书名仍 3 行内省略且不溢出（复用 `META-07` 验收 ②）。④ 底色层：有 `Material` → `Ink.decoration.color` 且**无** `ColoredBox`；`LookupBoundary` 截断祖先 → `ColoredBox` 且**无** `Ink`。⑤ 接入：`ShelfGrid` 渲染 `书0` → 书卡内有 `DefaultBookCover` 且 `Ink` 底色 = `lightBlue.shade200` |
| `test/ui/shelf_geometry_contract_test.dart` | 1 条用例内断言改写 | 封面外框（`kBookCoverSurfaceKey`）下 `ClipRRect` 由 1 层变 **2 层**（外框 + `DefaultBookCover` 自带），`tester.widget<ClipRRect>` 会 `Bad state: Too many elements` → 改 `widgetList` **逐层**断言圆角 8（更强：任一层不一致即红） |
| `test/ui/shelf_page_test.dart` | helper + 2 处断言 | `_cardOf` 加 `.first` **去重**（同一张卡的两个 `Text` 各自产出同一个 `BookCard`，`find.ancestor` 列出两次 → `tap` 报「歧义」）；LIB-01「书名和作者可见」改 `findsNWidgets(2)` ×2（各出现两次）；详情页书名断言改 `findsNWidgets(2)` |
| `test/meta/detail_test.dart` | helper + 3 处断言 | 同上：`_cardOf` 加 `.first`（该文件用 `longPress`，同样报歧义）；META-08 TXT 与 EPUB 用例的书名/作者改 `findsNWidgets(2)`；META-09① 保存后的新书名改 `findsNWidgets(2)` |

**⚠️ 本批踩到的两个坑（可复用）**

1. **`tester.getRect` 对旋转过的 widget 不给轴对齐外接框**：它取的是「变换后左上角」与「变换后右下角」之间的矩形（即**对角线两端**），96 宽 / 15° 实测得 **67.88** = `96 × (cos15° − sin15°)`，而真外接框是 **117.58** —— 直接断言宽度会让人误判成「角度不对」。**做法**：只用它取**变换不变的中心**（两角点对称于中心 → 中点即中心），再按「中心 ± 半个对角线的投影」自算 `halfSide = (side/2) × (cosθ + sinθ)`；角度则从矩阵**反解**而非回头引用实现里的常量。（与 §2.51 的「量放大的坑」是同一族问题的两个面：**先确认测量对象落在变换的哪一侧 / 是否被旋转**。）
2. **别凭印象数 `Colors.primaries` 的下标**：接入用例最初把 `书0` 的下标写成 5（`blue`），实测是 **6（`lightBlue`）**。颜色顺序请直接读 SDK `material/colors.dart:1883-1905` 或跑探针，不要靠记忆。

**文档回填两轮**

- **字符串轮**（`primaryContainer` / `characters.first` / `占位封面` / `默认封面` / `书名首字`）：`lib/` 内 `characters.first` **零残留**，`primaryContainer` 仅剩 `book_detail_page.dart:995` 的**来源标记 chip**（与封面无关，非本文所述占位）；两处占位实现已在同批代码里改写。
- **语义轮**（按「被推翻的约束语义」再 grep：`占位色块` / `书名首字` / `主题色背景`）——`book_card.dart` 的类 doc 原写「`[NoCover]` / `[SyntheticCover]`：显示占位色块 + 书名首字」（**已改写**为「显示**默认封面**」）；`book_detail_page.dart` 原写「无封面 / 合成封面占位：书名首字 + 主题色底（同 `BookCard` 口径）」（**已改写**）。`CHANGELOG.md` 里「占位色块 + 书名首字」的历史条目**不追改**（留档口径，覆盖关系由本节承担）。
- **§2.51 的范围边界**里「**字号**：仍本项目现状（书名 13 …）」指的是**信息区**字号，与本批默认封面的比例字号（宽 ×0.12 / ×0.08）不冲突，无需改文——但**详情页封面圆角 6 与书架 8 不一致**属既有状态，两节都如实登记、本批未统一。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze
/c/src/flutter/bin/flutter test --timeout 30s test/ui/default_book_cover_test.dart        # 00:00 +9: All tests passed!
bash tool/test.sh ui       # 00:56 +146: All tests passed!（137 → 146）
bash tool/test.sh data     # 00:20 +205: All tests passed!
bash tool/test.sh reader   # 00:25 +226: All tests passed!
bash tool/test.sh parse    # 00:11 +217: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` / `reader` / `parse` **四组全跑**（本批改动含共享控件，`parse` 一并复跑以闭合）。改动符号（`DefaultBookCover` / `defaultBookCoverColor` / `defaultBookCoverInk`）经全仓 grep，引用方只有 `lib/ui/book_card.dart`、`lib/ui/book_detail_page.dart` 与 `test/ui/`（**ui 组**）、`test/meta/detail_test.dart`（**data 组**），**无第三方引用方**。**真机观感未复跑**：需负责人确认 ① **深色主题下书架点缀浅色卡片**是否接受（anx 原样；要跟主题走改取色函数一行）；② 水印「探出的半本书」在书架小尺寸（≈120 宽 → 水印 96px、旋转后外接框 ≈117）下会不会显得过重——anx 原样如此，若要收小改 `iconSize` 一行；③ 详情页封面圆角 6 / 书架 8 是否要统一。

### 2.53 封面投影改为随主题（2026-09-29）

**触发**：负责人真机截图（深色主题书架）+ 一句「**阴影太强烈，影响观感**」。拍板（一问一答）：**跟主题走**（选项含「整体调弱」「深色不画」「两主题都去掉」，均未选）。

**症状取证（截图）**：每张封面四周一圈**发亮的浅灰光晕**，相邻书卡的光晕还互相叠成亮带——即 §2.51 预测的「深色主题下比背景**亮** → 观感是一道浅色描边」逐字成立。根因：anx 的投影是**固定灰** `Colors.grey`（α0.39），深色背景上它比背景亮，「投影」反成了「发光」。

**处置：只换色源，几何与透明度一字不动**

| | 浅色主题 | 深色主题 |
|---|---|---|
| 色源 | `Colors.grey`（`0x649E9E9E`，**anx 原样**） | `colorScheme.shadow`（M3 下恒为不透明黑 `0xFF000000`，`color_scheme.dart:1304` 的 `_shadow ?? const Color(0xff000000)`） |
| 透明度 | `withAlpha(100)` = 100/255 | **同**（`withValues(alpha: 100 / 255)`） |
| 几何 | spread 5 / blur 10 / offset (0,2) | **同** |

- 新增 `bookCoverShadowOf(ThemeData)`（`book_card.dart`）：浅色返回 `kBookCoverShadow`（该常量**保留**，语义收窄为「浅色主题的投影」），深色返回主题阴影色 + anx 几何。
- `_buildCoverSurface(theme)` 改用它——该函数的 `theme` 参数**因此重新变为必需**（上一批对齐 anx 后它一度只剩形式意义）。
- **为什么不让几何也跟着降**：负责人选的是「跟主题走」而非「整体调弱」。换色源已消除亮边，再把 spread/blur 也降下去会让**浅色主题**（照抄 anx、观感正常）跟着变，属超范围。深浅两档要再调强度，都只动这一个函数。

**如实登记**

- **`kBookLiftShadow`（抬起阴影，黑 α0.2）不随主题**（anx/包内默认值）：深色主题下它与深色背景几乎同值、接近不可见，抬起反馈主要靠**放大 1.05** 传达。**有意不补**「深色下也看得见的亮边」——亮边正是本次从常驻投影上去掉的东西。
- 截图那一版的封面还是**旧的「主题色底 + 书名首字」占位**（`af39d23` 之前的构建），与本条无关；换成默认封面后投影问题依旧存在、且浅色卡上更显眼，故本条独立成立。
- 浅色主题**逐字未变**——本条只影响深色。

**测试**

| 文件 | 变更 | 断言要点 |
|---|---|---|
| `test/ui/shelf_geometry_contract_test.dart` | **6 → 7 条** | 既有那条（现名 `封面圆角 8、投影 = anx 四参数（**浅色主题**；读渲染对象，不是读常量）`）**只改名字与 reason**，断言一字未动（仍硬编码 `0x649E9E9E` / 5 / 10 / (0,2)）。新增 `深色主题：封面投影改用主题阴影色（几何与透明度不变，不再是固定灰）`：`_pumpGrid` 加**可选** `theme` 参数（不传 = 与既有用例逐字一致），深色传 `AppTheme.dark()`；断言读渲染对象 = `Color(0x64000000)` / 5 / 10 / (0,2)，**反向断言** `isNot(Color(0x649E9E9E))`（固定灰回潮即红），圆角仍为 8；开头先自检 `AppTheme.dark().brightness == dark`（**防用例悄悄跑在浅色分支上**——这类「测了另一个分支还全绿」的假绿，本项目已有先例） |

**⚠️ 一个可复用的小结论**：`Color(0x64000000)` 与 `theme.colorScheme.shadow.withValues(alpha: 100 / 255)` **`==` 成立**——`Color` 存的是 double 分量，两条路径都算 `100/255`，位级一致，故契约测试可以直接写十六进制字面量而不用在测试里重算 `withValues`（否则就是「同义反复」，实现改了测试跟着改）。**前提是被换的色源是 `0xFF000000` 这种分量恰好的值**；若色源本身带小数分量，就得改用分量断言。

**文档回填两轮**

- **字符串轮**（key = `固定灰` / `不随主题` / `kBookCoverShadow`）：**实测命中 6 处**（初稿凭印象写成「4 处」，实测后改正——**这条纪律又要重申一次：命中数必须程序化点数**）——① `lib/ui/book_card.dart` 的 `kBookCoverShadow` doc（「固定灰、不随主题…要改回跟主题走只换这一行」，**本批改写**）；② `lib/ui/shelf_geometry.dart:25`（范围声明里**提名字**，语义未变，不动）；③ `lib/ui/shelf_grid.dart:9`（头注提名字，不动）；④ §2.51「处置 ①」（提名字 + 数值；浅色口径仍成立，**不改写**）；⑤ §2.51「如实登记的代价」段（**已补改道引用块**）；⑥ `CHANGELOG.md` 书卡那条的同句（历史条目留档口径，**不追改**）。
- **⚠️ 一个 grep key 的坑（本批实测）**：本想把 `比背景亮` 也当 key，但它**永远匹配不到**——§2.51 原文写的是「比背景**亮**」（强调符把词切开了）。**结论：grep key 不能从「读起来的样子」里取，要从原文的**字面字符**里取**；拿不准就先 `grep -n` 试一次再决定用哪个 key。
- **语义轮**（按「被推翻的约束语义」再 grep：`照抄 anx` / `anx 原样` / `要改回跟主题走` / `只需换这一行`）——**本轮零新增命中**，如实记录：本批的等价表述恰好与字符串轮的命中**落在同一段**（那句「要改回跟主题走只换 `kBookCoverShadow.color` 一行」与「固定灰、不随主题」是**同一句**，字符串轮 grep `固定灰` 即已覆盖），故没有「语义轮才捞得出来」的漏网句。**这不能当作「语义轮可以省」的理由**——§2.51 那批正是靠语义轮捞出字符串轮漏掉的三处；只是本批改动面窄（只动一个色源）、相关表述集中，两轮才重合。`CHANGELOG.md` 里书卡那条的同句**不追改**（历史条目留档口径，覆盖关系由引用块承担）。
- **锚点**：`grep -n "^### "` 实测确认本节为 §2.53（§2.52 为本会话同批的另一节），引用它的改道块写的是**章节号**而非行号。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze
/c/src/flutter/bin/flutter test --timeout 30s test/ui/shelf_geometry_contract_test.dart   # 00:00 +7: All tests passed!
bash tool/test.sh ui      # 00:58 +147: All tests passed!（146 → 147）
bash tool/test.sh data    # 00:19 +205: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` 两组为本批实跑。改动符号 `bookCoverShadowOf`（新增）与 `kBookCoverShadow`（语义收窄）经全仓 grep，引用方只有 `lib/ui/book_card.dart`（自身）与 `test/ui/shelf_geometry_contract_test.dart`（**ui 组**），无第三方；`BookCard` 的其它消费者（`shelf_grid.dart` → ui 组、`test/meta/detail_test.dart` → **data 组**）按影响面补跑。**真机观感未复跑**：需负责人确认深色下是否还有「发亮描边」（应无）、以及卡片与背景的**层次是否够**（黑投影在近黑背景上本就弱；若觉得「太平了」，可把 `bookCoverShadowOf` 里深色分支的 `100 / 255` 往上调——**但那是「整体调弱/调强」的另一档拍板**，本条不擅自定）。


### 2.54 书卡封面改画在子树内：修「长按灰板 / 封面方角 / 封面太暗」（2026-09-29）

**触发**：负责人一句「**图书长按会有灰色背景，且书籍封面没有圆角，太暗了**」。**三个症状经像素级取证后归一为同一根因族**：封面的绘制所用机制与「卡片没有底板」这一前提冲突。**未新增拍板**（是修 bug，不是改设计）；但**两处此前写进文档的设计决策被推翻**，故 §2.51 处置 ③ 与 §2.52 处置 ③ 均已补改道引用块。

**根因一：`Ink` / `Ink.image` 是「墨迹特性」，不是普通子组件**

`Ink` / `Ink.image` 不参与普通子树布局绘制，而是把内容注册成上层 `Material` 的 **ink 特性**，由该 `Material` 的渲染对象绘制。实读 `material.dart:621-634` 的 `_RenderInkFeatures.paint`：**先画 ink 特性、再 `super.paint`（子树）**。两个后果正好对上前两个症状：

| 后果 | 机理 | 表现 |
|---|---|---|
| ① **逃逸 `ClipRRect`** | 裁切是「父裁子」，只作用于该 `Material` 的子**树**；墨迹层画在子树**之外 / 之下**，不在裁切范围内 | **封面方角**（实测修复前封面左上角 (2,2) 仍是底色） |
| ② **被投影填充染色** | 墨迹层落在封面外框 `DecoratedBox` 投影的**下方**（见根因二） | **封面太暗**（浅色主题 `#9FA8DA` → `#9FA4C2`、深色 → `#616685`） |

**根因二：`BoxShadow` 是「填充形状」，不清除中心**

实读 `box_decoration.dart:448-470` 的 `_paintShadows` → `_paintBox`（`:429-442`）：对每个 shadow 在矩形 / 圆角矩形上 `canvas.drawRect` / `drawRRect` **填充**（`boxShadow.toPaint()` 的 shader 是 `MaskFilter.blur`，故画的是**被高斯模糊的实心形状**）。**与 CSS `box-shadow` 不同，它不做中心镂空**。于是：

- 画在**封面外框**（有 `ClipRRect` 兜住，形状也是封面的圆角）时，只是正常的投影；
- 画在**整张卡**这一层（卡片 `Card` 透明、信息区透明、无底板）时，就是给整卡铺一张**方角灰板**——**长按灰板**即此（原抬起阴影的 `AnimatedContainer` 包在整张卡外，形状是方角）；
- 同时它**盖在封面内容之上还是之下**取决于层级：外框这颗（静止投影）在封面内容**之下**，于是若封面内容本身半透明或画在更下层（墨迹层），就会被**染色**。

**根因三（第三个症状的另一半）：`InkWell` 的 pressed / 长按高亮会常驻**

实读 `ink_well.dart:1192-1212` 的 `_startNewSplash`：它调 `updateHighlight(_HighlightType.pressed, true)`；而 **`handleLongPress`（`:1242-1251`）不清 pressed 高亮** ⇒ **长按期间高亮一直挂着**。高亮色取 `highlightColor ?? Theme.of(context).highlightColor`（`:1038` / `:1364`）。它与封面是**同一层墨迹特性**，会填满整卡（方角、含透明的信息区与封面圆角缺口）⇒ 观感即「长按出现一块灰色背景」。
（对比：**水波纹不常驻**——M3 下默认 `splashFactory` 是 `InkSparkle`（`theme_data.dart:416-420`），其 `_animationDuration = 617ms`（`ink_sparkle.dart:182`）且 `_alpha` 第二段 `1.0 → 0.0`（`:152-155`），自行淡出。）

**处置（三项，全在 `lib/ui/book_card.dart` + `lib/ui/default_book_cover.dart`）**

| # | 改动 | 针对症状 |
|---|---|---|
| ① | **封面三态一律改「子树内不透明绘制」**：真封面 `Ink.image` → **`Image.memory`**（`errorBuilder` 退回占位）；加载态由「透明 + 转圈」改 **`ColoredBox(surfaceContainerHighest)`**（原先没底板，两颗投影会直接透出来）；占位底色 `Ink` → **`ColoredBox`** | 方角 + 太暗 |
| ② | **抬起阴影的 `AnimatedContainer` 从「整张卡外」挪到「封面外框内」**（即 `kBookCoverSurfaceKey` 的**祖先**）并带 `kBookCoverRadius` 圆角 | 长按灰板 |
| ③ | **`InkWell.highlightColor: Colors.transparent`**（保留水波纹：它自行淡出） | 长按灰板 |

**如实登记的代价（本批唯一）**：水波纹 / 高亮画在墨迹层，**不再压在封面之上**，只在透明的信息区可见——**这正是 anx 的形态**：其实读 `anx-reader/lib/widgets/bookshelf/book_cover.dart`，其封面用 `Container(color:)` / `Container(decoration: image)`，同样不在墨迹层，即 **anx 的 ripple 本来也压不到封面上**。故这不是「偏离 anx」，而是「回到 anx」。

> **⚠️ 后续改道（2026-09-29，见 §2.57）**：上两段（含表格行「保留水波纹：它自行淡出」）中**「水波纹保留且自行淡出 / 只在透明的信息区可见」的表述已被推翻**——负责人反馈「长按某个书籍弹起弹框前，该书籍**文字和圆角**会有灰色背景」，像素探针实测长按期间信息区 `#000000 → #333333`（= `0x40CCCCCC` 默认 splash 叠黑底）、圆角缺口同步变灰、封面内部纹丝不动，即水波纹**恰好只从这两处透明区露出**（§2.57 有四条源码实证链）。现在 `InkWell` 的**墨迹整体关闭**（`splashColor` 透明 + `NoSplash`，连同本批的 `highlightColor` 透明），代价改记为「**按下/长按完全无墨迹**」。**未被推翻的部分**：表格 ①② 两条处置、以及「水波纹画在墨迹层（子树之下）故压不到封面」这一机制结论——正因为压不到封面、只能从透明处露出，才必须关掉。原正文保留作事实留证，勿删。

**像素级取证（本批的取证手法，可复用）**

结论不靠推理、靠**真实像素**：`RepaintBoundary` → `tester.runAsync(() => boundary.toImage())` → `toByteData(rawRgba)` 直接读字节。**两个必守前提**：① `toImage()` 必须在 `tester.runAsync` 里 `await`（FakeAsync 不排空真异步）；② **必须钉 `tester.view.devicePixelRatio = 1`**（默认 3 会把采样坐标算错）+ `addTearDown(tester.view.reset)`。坐标换算用 `boundary.globalToLocal(cover.topLeft) & cover.size`。

| 采样点 | 修复前 | 修复后 | 期望 |
|---|---|---|---|
| 封面内部（浅色） | `#9FA4C2` | **`#9FA8DA`** | = `defaultBookCoverColor('书0')` |
| 封面内部（深色） | `#616685` | **`#9FA8DA`** | 同（底色不随主题） |
| 左上角 (2,2) 浅色 | `#9FA8DA`（仍是封面色 ⇒ 方角） | `#848AAE` | ≠ 封面色 |
| 左上角 (2,2) 深色 | 同上方角 | `#72799C` | ≠ 封面色 |

（`(2,2)` 到弧心 `(8,8)` 的距离 ≈ `8.49 > 8`，确定性落在 8 圆角的**弧外**。）

**测试**

| 文件 | 变更 | 断言要点 |
|---|---|---|
| `test/ui/book_card_paint_test.dart` | **新建 2 条** | `for (Brightness …)` 各一条：① 封面内部像素**精确等于** `defaultBookCoverColor('书0')`（`#9FA8DA`，`==` 不是 `closeTo`）② 左上角 (2,2) `isNot(coverColor)`。文件头注写明**为什么属性断言抓不到**：本批三个缺陷全出在**绘制顺序**上，而当时属性断言（颜色值 / 圆角值 / 阴影参数）**全是绿的** |
| `test/ui/default_book_cover_test.dart` | group ④ 改写（2 条）；接入用例 +1 | group ④ 更名「底色画在**子树内**（不用 `Ink`：会漏裁 + 被投影染色）」：有 `Material` 祖先也断言 `ColoredBox` + **反向断言无 `Ink`**；`LookupBoundary` 下照常渲染。接入用例底色改读 `ColoredBox`，并**新增「整张书卡内无 `Ink`」**（`find.byType(Ink)` → `findsNothing`） |
| `test/ui/book_card_lift_test.dart` | 同一用例 **+2 断言** | 抬起阴影容器 `(decoration as BoxDecoration).borderRadius == BorderRadius.circular(8)`（否则长按出方角灰板）+ `find.ancestor(of: kBookCoverSurfaceKey, matching: kBookLiftShadowKey) == findsOneWidget`（阴影须画在封面外框这一层）。**既有 5 组数值断言一字未动** |

**⚠️ 本批最值得记的一条（可复用）**：**属性断言测不出绘制顺序。** `Ink` vs `ColoredBox`、`BoxShadow` 画在哪一层——这些在 widget 树里看起来都「只是换了个 widget / 换了个父节点」，颜色值、圆角值、阴影参数**全部照旧**，故当时所有属性测试**全绿**，而真机上封面是方角、发暗、长按出灰板。**结论：凡涉及「谁画在谁之上 / 谁被谁裁切」的改动，必须用真实像素（`RepaintBoundary` + `toImage`）或 `RenderObject` 层面的断言来钉，光看 widget 属性不行。**

**文档回填两轮**

- **字符串轮**（key = `Ink.image` / `Ink(` / `AnimatedContainer` / `kBookLiftShadowKey` / `方角` / `太暗` / `ripple` / `墨迹` / `DecorationPosition.background`；**程序化点数**，范围 `docs` + `CHANGELOG.md`）：`Ink.image` **3**、`Ink(` **1**、`AnimatedContainer` **5**、`DecorationPosition.background` **1**、`ripple` **3**、`kBookLiftShadowKey` **0**、`方角` **0**、`太暗` **0**、`墨迹` **0**。逐条落点见下「命中处理」。
- **语义轮**（按「被推翻的约束语义」再 grep：`墨迹层` / `投影填充` / `按环境自适应` / `不透明内容盖住` / `不透明底色会把 ripple 盖住` / `画在卡片` / `自适应`）——**本轮捞出 1 处字符串轮必漏的**：§2.51 处置 ③ 的「阴影画在**卡片**背景」（不含 `Ink` 也不含 `AnimatedContainer`，字符串轮四个 key 全不命中）——**已补改道引用块**。
- **命中处理（逐条，含「不改，为什么」）**：① **`docs/tech-usage.md` §2.52 处置 ③**（「底色画在哪一层按环境自适应」）——**已补改道引用块**（语义轮命中）；② **§2.51 处置 ③**（阴影画在卡片背景）——**已补改道引用块**（语义轮命中）；③ **§2.15 的历史事实层表行**（`tech-usage.md:440`，「封面/占位走 `Ink.image` / `Ink` 画在 Card 的 Material 上，ripple 不被不透明内容盖住」+ hash `3e750b8`）——**不追改**：该行记录的是**当时那一版的实现**（事实层留证），覆盖关系由本节承担；④ **`CHANGELOG.md` 2026-09-29 的两条历史条目**（默认封面那条的处置 ③、书卡那条）——同口径**不追改**；⑤ `docs/进度表.md:77`（带 hash 的历史行）——不追改；⑥ `lib/ui/book_card.dart` 与 `lib/ui/default_book_cover.dart` 的注释——**同批已改写**（属代码侧，非回填）。
- **锚点**：`grep -n "^### "` 实测确认本节为 **§2.54**（§2.52 / §2.53 为本会话同批的前两节）；引用它的两处改道块写的是**章节号**而非行号。
- **⚠️ 一个 grep key 的坑（本批再次实证，与 §2.53 同族）**：语义轮若用 `水波纹压在封面之上` 当 key 命中 **0**——因为原文写的是「`InkWell` 水波纹画在它**之上**」，**措辞与语序都不同**。**结论重申：grep key 要从原文的**字面字符**里取；语义轮也要先 `grep -n` 探一次再决定 key，不能凭「我大概是这么写的」直接下结论。**

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze
/c/src/flutter/bin/flutter test --timeout 30s test/ui/book_card_paint_test.dart           # 00:00 +2: All tests passed!
bash tool/test.sh ui       # 01:00 +149: All tests passed!（147 → 149）
bash tool/test.sh data     # 00:24 +205: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` 两组为本批实跑。改动符号（`BookCard` / `kBookCoverSurfaceKey` / `kBookLiftShadowKey` / `DefaultBookCover`）经全仓 grep，引用方只有 `lib/ui/` 内（`book_card.dart` / `book_detail_page.dart` / `shelf_grid.dart`）与 `test/ui/`（**ui 组**）+ `test/meta/detail_test.dart`（**data 组**），**无第三方引用方**（`ui` 组已覆盖全部引用方，`data` 组为 `BookCard` 的另一个消费者补跑）。`parse` / `reader` 组零交集，未跑。**真机观感未复跑**：需负责人确认 ① 长按**不再出现灰色背景**、封面**圆角正常**、封面**不再发暗**（三项症状）；② 新生的**代价**「水波纹只在信息区可见（封面区域摸不到 ripple）」是否接受——这是 anx 的形态，如要压在封面之上只能回到墨迹层（就把方角与染色带回来），**二者不可兼得**；③ 深色主题下书架层次是否仍够（承 §2.53 的同一问题）。

### 2.55 开书准备中的蒙层改为只盖封面（2026-09-29）

**触发**：负责人截图 + 「**如绍宋这本书，点击后会有灰色背景**」。**同一张卡在三种不同操作下都会出灰**（§2.54 的长按灰板、§2.53 的发亮描边、本节的点击蒙层），故本节先**逐项排除**，再定因。

**先排除（避免误改）**

- **截图里的灰块是不是真的？** 先把截图裁出绍宋卡片、放大 3 倍 —— **灰块消失**，原图同一区域是封面暗部建筑（`#434659` 一带的屋檐）。即部分观感来自 **MIUI 相册编辑器处理过的 JPEG 的块效应伪影**（原图 513×1093，被缩放/重编码过）。**结论：不能只靠这张截图定位**，须实测渲染。
- **是不是长按灰板回潮 / 按下高亮？** 写像素探针（真封面 = `StoredCover` + 已加载缩略图，三态采样：静止 / 按下 100ms / 抬起后 700ms）：**按下态封面内是纯 `#ff0000`、无灰无暗**，圆角外 `(2,2)` 是抗锯齿过渡色、`(4,4)` 在弧内为封面色 ⇒ **圆角正常、无按压染色**。
- 那就只剩**点击后**那一段状态：`_openingBookId != null` 时的 per-card 反馈层。

**根因：per-card「打开准备中」蒙层的**范围**错了**

`book_card.dart` 原先的结构：

```text
Card > InkWell > Stack(fit: expand)
  ├─ Column[ 封面区(Hero > _buildCoverSurface) , gap , 信息区 ]
  └─ if (loading) ColoredBox(surface α0.6, child: 转圈)   // ← 在封面 ClipRRect **之外**
```

三个问题（**全部像素级实测**，探针采样封面色 `#f48fb1` 的占位封面）：

| # | 问题 | 实测 |
|---|---|---|
| ① | **盖住封面**（深色下压成暗灰、浅色下发白） | 深色 `surface = #121318` ⇒ 封面 `#f48fb1` → **`#6c4555`**；浅色 `surface = #fbf8ff` ⇒ → **`#f8cee0`** |
| ② | **连信息区一起压暗** | 书名行深色 `#000000` → **`#0b0b0e`**、浅色 → **`#979599`**（书名/作者/进度在准备期全糊住） |
| ③ | **方角** | 蒙层在封面外框的 `ClipRRect` **之外** ⇒ 方角铺开（与 §2.54 的长按灰板**同族**：`ClipRRect` 之外的东西必然方角） |

**处置：只挪位置，不动外观参数**

把蒙层从「顶层 `Stack` 的 sibling」挪进 `_buildCoverSurface` 的 `ClipRRect` **之内**（与格式角标同层）：

```text
DecoratedBox > ClipRRect > Stack[ _buildCover , 角标 , if (loading) 蒙层+转圈 ]
```

- 于是它**只盖封面**、**随封面 8 圆角一起裁**、**信息区完全不受影响**；
- **色源与透明度一字未动**（仍 `colorScheme.surface` α0.6）——只是**范围收窄**，故深浅两主题的观感变化方向一致、不必重新调参；
- 顶层 `Stack` 因此只剩 `Column` 一个孩子（结构简化，但 `Stack` **保留**：不动已锁定的 `StackFit.expand` 语义）。

**测试（含反向验证，本批的关键环节）**

`test/ui/book_card_paint_test.dart` **2 → 4 条**（`Brightness` 各一条新用例）。两处 helper 改动：`_pumpAndSample` 加 `loading` 可选参数；boundary 高度由「封面高 192」改为**卡片全高 252**（= 192 + gap 5 + 信息区 55）——否则信息区被 `SizedBox` 挤出可视区、采样越界（**这是本批踩到的坑：采样点在封面之外时，boundary 必须覆盖到它**）。

三条新断言：① 蒙层在场时封面中部**必须不再是**底色（并**自检**静止态仍等于底色，防「根本没读到封面」的假绿）② 圆角外不出现「被蒙过的封面色」（蒙层须被裁进圆角内）③ 信息区书名行在两态下**逐位相等**。

**⚠️ 反向验证（这一步不能省）**：新建的像素断言**必须证明它在旧实现下会红**，否则可能只是「写了条永远成立的断言」。做法：临时把蒙层改回整卡 → 跑 → **两条都红**，且报错里的实测值（深色 `#0b0b0e`、浅色 `#979599`）与探针**独立**实测**逐字吻合** → 断言有效。改回修复版 → 全绿。

**文档回填两轮**

- **字符串轮**（key = `整卡蒙层` / `book-opening-overlay` / `打开准备中` / `loading 覆盖层` / `per-card loading`；程序化点数，范围 `docs` + `CHANGELOG.md`）：`loading 覆盖层` **3**、`per-card loading` **1**，其余三个 **0**。落点：`docs/tech-usage.md:1335`（**§2.46 的测试变更表行**，记录当时「只断言卡上 loading 覆盖层」的改法）、`CHANGELOG.md:191`（书架首点无响应那条的历史条目，同句）、§2.46 正文一处。**三处全部不追改**——都是**记录当时实现**的事实层/history 条目，覆盖关系由本节承担（与 §2.54 对 `tech-usage.md:440` 的处理口径一致）。
- **语义轮**（按「被推翻的约束语义」再 grep：`铺满` / `整张卡` / `per-card 可见反馈` / `卡上覆盖层`）——**本轮零新增命中**，如实记录：本批改的是**范围**而非**是否显示**，而原文的等价表述（「卡上 loading 覆盖层」）**恰好同时也是字符串轮的 key**，故两轮重合。**不构成「语义轮可省」的理由**（§2.51 / §2.54 两批都靠语义轮捞到过字符串轮必漏的句子）。
- **锚点**：`grep -n "^### "` 实测确认本节为 **§2.55**。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze
/c/src/flutter/bin/flutter test --timeout 30s test/ui/book_card_paint_test.dart           # 00:00 +4: All tests passed!
bash tool/test.sh ui       # 01:01 +151: All tests passed!（149 → 151）
bash tool/test.sh data     # 00:22 +205: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` 两组为本批实跑。改动符号 `BookCard.loading` 与 `book-opening-overlay` key 经全仓 grep，引用方只有 `lib/ui/book_card.dart` 自身、`lib/ui/shelf_grid.dart`（`openingBookId` 透传）、`test/ui/`（**ui 组**）+ `test/meta/detail_test.dart`（**data 组**），**无第三方引用方**。`parse` / `reader` 组零交集，未跑。**真机观感未复跑**：需负责人确认 ① 点击书卡后**封面区域**出现蒙层 + 转圈、**书名/作者/进度保持清晰可读**、蒙层**四角是圆的**；② 蒙层**只覆盖封面**这件事本身是否够作为「正在响应」的提示（若觉得提示太弱，可把「整卡蒙层」的旧观感换个更轻的透明度或改用描边高亮来表达——**那是观感取舍，本批按拍板只做范围收窄**）。

### 2.56 弹层遮罩压淡：修「弹框前出现灰色背景」（2026-09-29）

**触发**：负责人「**长按书籍，在出现弹框前，会出现灰色背景**」。注意时间窗是「**出现弹框前**」——不是弹层形态问题（§2.49 已统一），而是**弹窗到位之前**屏幕上已经蒙了一层灰。

**根因：`GlassSheet.show` 的 `barrierColor` 未透传，吃库默认；而遮罩与弹窗的到位时间错位**

实读 `liquid_glass_widgets-1.7.0/lib/widgets/overlays/glass_sheet.dart:314-332`：`GlassSheet.show` 走 `showGeneralDialog`，其 `barrierColor: barrierColor ?? GlassDefaults.barrierColor`，而 `glass_defaults.dart:154` 的 `GlassDefaults.barrierColor = Color(0x8A000000)`（α = 138/255 ≈ **0.541**）——`GlassOverlays.showSheet` 又是薄封装（§2.48 的同族坑，**第三次**）没透传该参数，于是吃下这个偏重的默认灰。

逐帧实测（`RepaintBoundary` 采遮罩像素 α + 弹窗 top；`transitionDuration: 350ms`、弹窗 `SlideTransition` begin `Offset(0,1)`）：

| t | 遮罩 α | 弹窗 top（屏内 1248→548） |
|---|---|---|
| 0ms | 0.000 | 1248（屏外） |
| 50ms | 0.093 | 979（屏外） |
| **100ms** | **0.262** | **788（屏外）** |
| 175ms | 0.434 | 635（刚探头） |
| **350ms** | **0.541** | 548（到位） |

即**头 ~150ms 是「灰幕已到、弹窗未到」**——正是负责人说的「出现弹框前」。

**处置：只换色源，不动时序**（与 §2.53 `bookCoverShadowOf` 同一口径）

`lib/ui/glass_kit.dart` 新增 `kSheetBarrierColor = Color(0x3D000000)`（α = 61/255 ≈ **0.24**，约库默认的 45%），`showSheet` 两条路径（玻璃档 `GlassSheet.show` / 关档 `showModalBottomSheet`）**共用同一色源**：

- 既保留「背后内容退到次要层」的模态语义；
- 又不会在弹窗到位前形成一条突兀的灰幕（逐帧复测 50/100/175/350ms 分别 0.041/0.116/0.192/0.239）；
- **淡入时序、滑入动画、点遮罩关闭全部一字未动**。

**测试（含反向验证）**

`test/ui/glass_sheet_form_test.dart` +1 条：读 **`AnimatedModalBarrier` widget 自身的 `color` 字段**断言 `(a*255).round() == 0x3D` 且 `< 0x8A`。两个坑：① **`AnimatedModalBarrier` 不是 `ModalBarrier` 的子类**（两个独立类，cast 直接炸）；② 其 `color` 是 **`Animation<Color?>`** 不是 `Color?`，取值要 `.value`。弹层在独立 Overlay/Route，`RepaintBoundary` 采不到遮罩，只能读 widget 字段。`glass_off_fallback_test.dart` 关档用例补同一断言（两档同色源）。**反向验证**：临时删掉传参 → 断言红，实测 `138.0`（= `0x8A`）与源码预测**逐字吻合**。

> ⚠️ **后续改道（2026-09-30，见 §2.59）**：本节引入的 `kSheetBarrierColor` 已**更名**为 **`OverlayStyle.barrier`** 并**扩大适用范围**——由「只管底部弹窗」扩到**全部模态浮层**（新增：玻璃档确认框、关档确认框）。本节「取值 `0x3D000000`」「只换色源、不动时序」两条口径**未被推翻**；被改写的是「两档共用」里的**两档只有弹窗的玻璃/关两档**这一范围描述——当时**确认框两档另有来源**（Cupertino 自适应 / Material `Colors.black54`），本批才发现并统一。

### 2.57 书卡墨迹（高亮+水波纹）整体关闭：修「长按弹框前文字与圆角出现灰底」（2026-09-29）

**触发**：负责人「**好好书架页的代码，不要猜，长按某个书籍弹起弹框前，该书籍文字和圆角会有灰色背景**」。症状精确到两处：**文字**（信息区）与**圆角**（封面圆角缺口）——这是决定性线索：**只有这两处在卡片上是透明的**（封面不透明、Card 透明、信息区无底色）。

**四条源码实证链（全部实读 SDK，非猜测）**

| # | 事实 | 出处 |
|---|---|---|
| ① | 默认 `splashColor` 是**灰** `Color(0x40CCCCCC)`（深色） | `theme_data.dart:501-502` |
| ② | `InkSparkle` 是 `canvas.drawRect(_clipCallback(), paint)` **整块矩形**（不是圆形涟漪） | `ink_sparkle.dart:269` |
| ③ | `handleLongPress` 只 `_currentSplash?.confirm()` **不 cancel** ⇒ 水波纹贯穿长按与弹框入场 | `ink_well.dart:1242-1251` |
| ④ | ink 特性画在**子树之下**（先画 ink、再画子树）⇒ 只从子树的透明处露出 | `material.dart:621-634` |

且 `ink_well.dart:1005/1038` 证明 pressed 高亮取 `widget.highlightColor ?? Theme.highlightColor`——§2.54 已把 `highlightColor` 置透明 ⇒ **高亮已死，只剩水波纹**。

**像素探针实测**（默认封面 `#f48fb1` 的「绍宋」卡）：静止 `缺口(2,2)=#af677f、书名行=#000000、作者行=#000000、封面内=#f48fb1` → 按住 t=300ms `缺口=#b76e87、书名行=#333333、作者行=#333333`（**`#333333` 逐位 = `0x40CCCCCC` α 叠 `#000000`**）→ 420/520/600ms 渐淡 → 800ms 消失。**封面内部恒定不变**——与「文字和圆角有灰色背景」逐字吻合（④ 的直接推论）。

**处置：墨迹整体关闭**

`book_card.dart` 的 `InkWell` 在既有 `highlightColor: Colors.transparent` 之上补：

```dart
splashColor: Colors.transparent,
splashFactory: NoSplash.splashFactory,
```

`NoSplash` 连 splash 对象都不创建（比只透明化更彻底，也杜绝 `confirm()` 后残留）。**反馈仍在**：点卡=转场进阅读页、长按=放大 1.05+浮起阴影（§2.51）。**代价如实登记**：按下/长按**完全没有墨迹**（水波纹/高亮都没有），anx 同此形态（其封面 `Container(color:)`、ripple 本来也压不到封面，现在连信息区也没有了）——**是否可接受待负责人真机复跑**；若要恢复「轻量按压反馈」，加回 `splashColor` 但配 `NoSplash` 仍无涟漪，真正要涟漪就得接受它从文字与圆角露出。

**测试（`test/ui/book_card_paint_test.dart` 4 → 7 条，反向验证两轮）**

「书卡墨迹」用例 = **3 条确定性属性断言**（`highlightColor`/`splashColor` 的 `toARGB32() == 0x00000000`、`splashFactory == NoSplash.splashFactory`，工厂断言防「有人只把色改回非透明」）+ **像素断言**（`startGesture` 按住，在 t=250/300/350/400ms 断言信息区书名行 `at(12, cover.height+20)` 与圆角缺口 `at(2,2)` 与静止态**逐位相同**）。另补「真图封面被裁进圆角」用例（`Brightness` 各一条）：`DefaultBookCover` **自带 `ClipRRect`** 会掩盖外层裁切失效，而 `Image.memory` 真图路径完全依赖 `_buildCoverSurface` 的外层裁切——纯色 PNG（`PictureRecorder`+`toImage`+`toByteData(png)`）走 `StoredCover` 真图路径断言圆角内外。

**两轮反向验证各自独立有效**：① 去掉 splash 两参 → 属性断言红（`Expected: <0> Actual: <null>`）；② `if (false)` 停用属性断言只留像素断言（保留默认 splash）→ 像素断言红（`t=400ms 信息区实测 #2d2d2d`，= 默认灰叠黑底的又一实测值）。两条断言**互不依赖、各自能抓住回归**。

**两个测量坑（可复用）**：① 采样点必须**每次快照重算 rect**——`AnimatedScale` 放大 1.05 后封面物理变大，静止态记下的「圆角外」坐标落回封面内部 ⇒ 误判「圆角失效」（本会话先前一次「还是存在」的真相就是这个测量假象）；② 放大后封面会溢出 `RepaintBoundary` ⇒ boundary 须包住变换后尺寸（160×320 包 120×252 卡），否则采样越界 `IndexError`。另：`StoredCover` 是**位置参数**构造（`const StoredCover('c.png')`）；手写 PNG 字节常无效，用 `PictureRecorder` 生成或 PIL 落盘。

**`dart format` 陷阱（本批实证，记入工程约定）**：本 SDK 的 formatter 会重排**既有**代码（对 `glass_off_fallback_test.dart` 一次产生 197 行无关 churn）⇒ **测试/源码文件一律不跑 `dart format`**；误跑后 `git checkout --` 恢复再手工重放自己的编辑。

**文档回填两轮（字符串轮 + 语义轮）**

- **字符串轮**（key = `水波纹` / `InkSparkle` / `splashColor` / `highlightColor` / `barrierColor` / `0x8A000000` / `0x40CCCCCC`；程序化点数，范围 `docs` + `CHANGELOG.md`）：`水波纹` 命中 tech-usage **6 行** + CHANGELOG **1 行**、`InkSparkle` **2**、`highlightColor` **4**、`splashColor`/`barrierColor`/`0x8A000000`/`0x40CCCCCC` 均 **0**（本批首次引入这些字面量）。
- **语义轮**（key = `自行淡出` / `保留水波纹` / `只在透明的信息区可见` / `不构成常驻底色` / `不再压在封面之上`）：tech-usage **4 行** + CHANGELOG **1 行**，即 §2.52 的改道注、§2.54 的「对比：水波纹不常驻…自行淡出」、表格行「保留水波纹：它自行淡出」、「如实登记的代价」段、CHANGELOG `0a1f5b1` 条目内的同族表述。**全部是记录当时实现的事实层/history 条目，按口径不追改**；被推翻的语义是「**水波纹保留且自行淡出**」→「**墨迹整体关闭**」，覆盖由本节 + §2.54/§2.52 尾部各一条「后续改道」指针承担（与 §2.53→§2.54、§2.52→§2.54 的改道注同款）。
- **锚点**：`grep -n "^### "` 实测确认本节为 **§2.57**（前节 §2.56 同批新增）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze                # 0 error / 0 warning / 7 info
/c/src/flutter/bin/flutter test --timeout 30s test/ui/book_card_paint_test.dart   # +7: All tests passed!
bash tool/test.sh ui       # 全绿
bash tool/test.sh data     # +205: All tests passed!
```

**复核边界**：`analyze` 与 `ui` / `data` 为本批实跑（`ui` 因既有 flake 用 `-j 1` 串行口径）。改动符号 `InkWell` 三参、`kSheetBarrierColor` 经全仓 grep，`kSheetBarrierColor` 引用方仅 `glass_kit.dart` 两处传参 + 两个测试文件；`parse` / `reader` 零交集，未跑。**真机观感未复跑**，需负责人确认：① 长按书卡到弹框出现的全程，书名/作者/进度与封面圆角缺口**无灰底**；② 弹层出现前遮罩明显更淡（α0.239）后，**模态语义是否仍够**；③ 按下/长按**完全无墨迹**是否可接受。

### 2.58 书架标题栏改「全浮动头部」+ 内容 edge-to-edge（参考图批，2026-09-30）

**触发**：负责人「**标题栏也参考图片，内容可以 edge to edge**」（附 HyperOS 主题商店首页截图）；`AskUserQuestion` 拍板 **「全浮动头部」**（另两档为「只改搜索胶囊」「全页面统一」，均未采纳——本批**不动**设置页 / 详情页 / 搜索页顶栏）。

**参考图读法（写在前面，免得后人以为抄了细节）**：① 标题区 = **两行浮层**——全宽半透明玻璃搜索胶囊 + 分类胶囊 chips（选中 = 实心亮胶囊、未选中 = 半透明玻璃胶囊）；② 二者**压在 edge-to-edge 内容上**（横幅从胶囊下穿过、顶部被糊住）；③ 底部仍是浮动玻璃导航（本项目已是同形态，§2.50）。**截图为缩放图（500×1082）**，故行高 / 间距只作**估计**、不作精确依据——工程约定：截图只提供「什么形态」的信息，边界与颜色不可信。

**本批要解决的既有状态（三处）**

| # | 既有状态 | 证据 |
|---|---|---|
| ① | 内容**完全不穿顶栏**：`GlassNavScaffold` 写死 `extendBody: false` | §2.41 修「首行被盖」时的拍板取舍 |
| ② | 因此 `glass_scaffold.dart:458` 的 `if (extendBody && …)` **恒假** ⇒ `GlassScrollEdgeEffect` 从未启用 ⇒ PRD `UI-02` ②「滚动时顶栏下内容透出模糊而非纯色遮挡」**实际未满足** | §2.41「已知代价」段 |
| ③ | 搜索胶囊为不透明底（α0.9）+ 400 上限；chips 在主正文 `Column` 里（不属顶栏） | §2.45 + `shelf_page.dart` |

**改动**

1. **`GlassNavScaffold` 增加 `extendBody` 参数（默认 `false`）**：玻璃档透传库 `GlassScaffold.extendBody`，「关」档映射 `Scaffold.extendBodyBehindAppBar`（语义对齐）；并补上边缘效果口径 **`edgeStyle: GlassScrollEdgeStyle.blur`**——库默认 `soft` 是「内容**渐隐进背景**」（接近 `UI-02` ② 否定的「纯色遮挡」），`blur` 才是「内容**透出模糊**」（`ProgressiveBlur` 渐进磨砂）。**仅 `extendBody: true` 时生效**（`:458` 条件）。**回退旋钮**：要渐隐档改一行传 `GlassScrollEdgeStyle.soft`。默认 `false` ⇒ 其余 6 个调用点行为一字不变。
2. **书架头部改两行浮层**（`_buildHeader()`）：`GlassTopBar(toolbarHeight: kShelfHeaderHeight, title: <两行 Column>, centerTitle: false)`，**`actions` 槽不再使用**——两按钮移进搜索行内（否则 48 高的按钮会在 96 高的条里垂直居中、正好卡在两行之间）。头部整体包 `MaterialType.transparency`：玻璃库**无 Material 祖先**（PRD §11.4），而 `FilterChip` **断言要求** Material 祖先（SDK `chip.dart:776` `debugCheckHasMaterial`）——chips 从正文（`OpaqueContentSurface` 提供的 `Material`）搬进顶栏后**必须自带一层**，否则 debug 断言直接失败（同 `_BookSearchEntry` 为 `InkWell` 包透明 Material 的手法）。
3. **搜索胶囊**：撤 `maxWidth: 400`（拍板「全宽」）、填充 α0.9 → **α0.6**（顶栏下方现在是磨砂内容区，0.9 的不透明理由随之消失）、**描边保留**（α0.6 下更依赖它把可点控件从磨砂区里分出来——§2.45 的结论未被推翻）。
4. **chips 胶囊化**：`StadiumBorder` + `showCheckmark: false`；未选中 `surfaceContainerHighest` α0.6 + `outlineVariant` 描边（与搜索胶囊同一套玻璃语言），选中 `secondaryContainer`（M3 选中态）。**文字色不动**——实读 SDK `_ChipDefaultsM3.labelStyle` 为 `onSurfaceVariant`、**不随选中态变**，两态通用故无需自定义 `labelStyle`。chips 行去掉了原正文里的 12 / 4 侧边距（左缘与搜索胶囊对齐）。
5. **首行保护**（拍板验收条目）：新增 `shelfGridPadding(double topInset) = kShelfGridPadding.copyWith(top: topInset + kShelfHeaderHeight + 12)`——**「网格上间距 12」的原语义不变**，头部高度作为**叠加项**进 `top`；故 `kShelfGridPadding` 常量本身与 §2.40 的契约**一字未改**（既有断言照旧通过），避免把「页面级叠加」混进「网格固有间距」。
6. **头部两行恒在场**（loading / 空态 / 有书）：原先 loading 态是 `Text('书架')`（44）、有书才换搜索框，且 chips 行随「有无书」出现——现统一 96，消除跳变。连带 `widget_test.dart` 冒烟断言（原依赖「顶栏标题『书架』三态恒存在」）改断言恒在的搜索胶囊占位文案。
7. **排序菜单锚点**：`kToolbarHeight`(56) → `kShelfHeaderHeight`(96)（菜单应锚在新头部下沿）。

**几何事实源**（`lib/ui/shelf_geometry.dart`）

```dart
const double kShelfSearchRowHeight = 44;
const double kShelfHeaderRowGap   = 12;
const double kShelfChipsRowHeight = 40;
const double kShelfHeaderHeight = kShelfSearchRowHeight + kShelfHeaderRowGap + kShelfChipsRowHeight; // 96
EdgeInsets shelfGridPadding(double topInset) =>
    kShelfGridPadding.copyWith(top: topInset + kShelfHeaderHeight + kShelfGridPadding.top);
```

**测试（`ui` 组 155 → 159；`glass_nav_inset` +2、`shelf_page_test` +1、`shelf_geometry_contract` +1）**

| 断言 | 口径 | 反向验证（本批实做，各自独立变红） |
|---|---|---|
| `GlassNavScaffold.extendBody == true` | 书架穿顶栏 | 改回 `false` → `Expected: true / Actual: false` |
| 正文 top == 0（玻璃档、关档各一条） | 透传确实生效 | 两条透传分别写死 `false` → 各自 `Actual: 44.0` |
| 搜索胶囊与 `FilterChip` 均在 `GlassTopBar` 子树内 | chips 属浮动头部 | chips 移回正文 → `Found 0 widgets with type "FilterChip" descending from GlassTopBar` |
| `toolbarHeight == 96`、首行 `getTopLeft(BookCard).dy == 108` | 头部高 / 首行不被盖 | 撤 `padding: shelfGridPadding(topInset)` → `Actual: 12.0` |
| `kShelfHeaderRowGap == 12` 等常量 + `shelfGridPadding(48) == LTRB(20,156,20,96)` | 事实源字面量锁 | 行距改 8 → `Expected: <12> / Actual: <8.0>` |

断言一律在 `800×1000` 且**钉 `devicePixelRatio = 1`** 下跑（断言的是逻辑像素 96 / 108；默认 dpr 3 会把物理与逻辑搅在一起）。

**文档回填两轮**

- **字符串轮**（key 取原文「字面字符」；范围 `docs/*.md` + `CHANGELOG.md`）：`extendBody` **12**、`maxWidth` **8**、`400 上限` **3**、`kShelfGridPadding` **3**、`靠左铺满` **1**、`居中收缩` **1** → 命中除本节新增外，集中在 §2.41（顶栏避让）与 §2.45（搜索框靠左铺满）两处**事实层**，均已补改道指针，无第三处需改。
- **语义轮**（找「被推翻约束」的等价表述、不含版本号）：「避让顶栏」**3**、「渐隐」**6**、「浮在中间」**2**、「顶栏内边距」**2**、「玻璃顶栏」**2** → 逐条核对均为**历史事实层**（§2.40 / §2.41 / §2.45 / §2.49 的过程记录）或**仍成立**的口径（`centerTitle: false`、1px 描边、内边距 8）；已在 §2.41 / §2.45 各补一处 `⚠️ 后续改道` 指针，原文不追改。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze                            # 0 error / 0 warning / 7 info
/c/src/flutter/bin/flutter test --timeout 30s -j 1 test/ui test/widget_test.dart  # +159: All tests passed!
/c/src/flutter/bin/flutter test --timeout 30s test/library test/meta test/storage test/task test/highperf_registry_test.dart  # +205: All tests passed!
```

**复核边界（不伪造复核记录）**

- **可复核 → 已复核**：库源码行号（`glass_scaffold.dart:135/458/487-494`、`chip.dart:776`、`glass_scroll_edge_effect.dart` 三档 doc）、几何常量与两处测试字面量、五处反向验证实测值、`analyze` 与两组测试输出，均为本批实读 / 实跑。
- **不可复核 → 未声称**：**真机观感未复跑**，需负责人确认：① 头部 96 / 行距 12 是否合眼（截图仅是缩放图、这几个数只是估计）；② 磨砂（`blur`）在真机 / Skia 上的开销与观感（库 doc 自述 Skia 比 `soft` 略贵）；③ 选中 chip 用 M3 `secondaryContainer` 够不够「选中感」（参考图是深色端「最亮 = 选中」的做法）；④ 胶囊 α0.6 在**浅色主题**下与磨砂区是否仍区分得开；⑤ 桌面宽窗下「全宽胶囊」是否过宽（原 400 上限已按拍板撤销）。
- **未做（如实登记）**：① `parse` / `reader` 两组未跑（与本批零交集）；② 其余页面顶栏未动（拍板只做书架）；③ **PRD 无条文改动**——`LIB-01` 的「顶部为导入入口」仍成立（按钮保留在搜索行右侧），本批实质是把 `UI-02` ② 从「未满足」改为「已满足」，**未新增 / 修改任何需求条目**，故不加版本行（若要把它写成 PRD 版本行请指示）。

### 2.59 玻璃弹框共有参数统一配置：`OverlayStyle` + 确认框遮罩对齐（2026-09-30）

**触发**：负责人「**玻璃弹框的共有参数，采用统一配置**」。`AskUserQuestion` 两项拍板：①「四路遮罩**全统一**」；② 统一范围 =「**遮罩 + 形态 + 尺寸**」。

**改前状态：四个入口的遮罩来自三个源头**（实读库与 SDK 源码逐条核清）

| 入口 | 玻璃档遮罩 | 「关」档遮罩 |
|---|---|---|
| `GlassOverlays.showSheet` | `kSheetBarrierColor` = `0x3D000000`（α0.239，§2.56） | 同一色源 |
| `GlassOverlays.showAlert` | `kCupertinoModalBarrierColor`：亮 `0x33000000`（α0.2）/ 暗 `0x7A000000`（**α0.478**） | Material `Colors.black54` = **`0x8A000000`**（**α0.541**） |
| `GlassOverlays.showToast` | **无遮罩**（纯 `OverlayEntry` 浮层、非模态） | — |

两条根因链：

1. **库 `GlassDialog.show` 的 `barrierColor` 是死参数**：`glass_dialog.dart:268` 声明了它，`:271-283` 却直接 `showCupertinoDialog(context: …, barrierDismissible: …, builder: …)`，**没把它传下去**。往下追到底：`showCupertinoDialog`（`cupertino/route.dart:1410-1433`）**接受** `Color? barrierColor` 并透传给 `CupertinoDialogRoute`，后者在 `:1501-1502` 做 `barrierColor ?? CupertinoDynamicColor.resolve(kCupertinoModalBarrierColor, context)`（常量定义 `:53-56`）⇒ **无法经由库的 `show` 设置确认框遮罩色**，只能自己调 `showCupertinoDialog`。
2. **「关」档确认框仍在用那颗已被否定的重灰**：`showDialog` → `DialogRoute` 的 `super.barrierColor = Colors.black54`（`material/dialog.dart:1825`）= `0x8A000000`，正是 §2.56 判为「太重的灰」的**同一个值** —— 即 §2.56 的口径**只落到弹窗、漏了确认框**，属**已拍板口径未落全**，不只是风格分歧。

**处置：`OverlayStyle`（浮层参数的唯一事实源），三个入口一律从它取**

`lib/ui/glass_kit.dart` 新增 `abstract final class OverlayStyle`，把原先散在 `showAlert` / `showSheet` 默认值与方法体里的参数收成一处（`kSheetBarrierColor` 随之**更名并入**）：

| 常量 | 值 | 库 / Material 默认 | 说明 |
|---|---|---|---|
| `barrier` | `0x3D000000`（α0.239） | 三源：`0x8A000000` / `Colors.black54` / Cupertino 自适应 | **四路统一** |
| `interactionScale` | `1.0` | **1.01** | 无点击放大 |
| `interactionGlow` | `false` | **true** | 无跟随手指高光 |
| `saturationGlow` | `false` | **true** | 无触摸饱和度脉冲 |
| `dragIndicator` | `false` | **true** | 无顶部小横条 |
| `enableDrag` | `false` | **true** | 禁拖拽关闭手势 |
| `dialogMaxWidth` | `280` | 280（同值） | 显式化 |
| `sheetTopBorderRadius` | `32` | 32（同值） | 显式化 |
| `sheetMargin` | `(8, 8)` | (8, 8)（同值） | 显式化 |
| `toastDuration` | `2s` | 3s | 本项目提示都是短反馈 |

「同值」三项**不是冗余**：显式化后库升级若改默认值，不会静默改掉本项目观感。

四处接线：

- **玻璃档确认框**：绕过 `GlassDialog.show`，自行 `showCupertinoDialog<T>` + `GlassDialog(...)`，只多传一个 `barrierColor: OverlayStyle.barrier`。与库的 `show` **逐项等价**（同一个 `showCupertinoDialog`、同一个 `GlassDialog` widget、`useRootNavigator: true`、`barrierLabel` 留空交 `CupertinoDialogRoute` 取 `modalBarrierDismissLabel`、转场仍是 250ms spring）——**代价 = 多 12 行**，换来遮罩可统一；库若修好那个死参数即可回退（代码注释已写明）。
- **关档确认框**：`showDialog(barrierColor: OverlayStyle.barrier)` —— 修掉那条漏落的重灰。
- **底部弹窗**：形态 / 尺寸 / 遮罩全部改读 `OverlayStyle`（值未变），并新增显式 `topBorderRadius` / `margin` 透传。
- **轻提示**：默认时长改读 `OverlayStyle.toastDuration`（值未变）。

**明确不在此收口**（免得日后看着像漏了）——`quality`（**运行时值**，随档位 / 特效开关 / 帧预算变）、`isScrollable`（调用场景语义）、`padding`（**内容自持**：库中 `null` 即 `EdgeInsets.zero`，`glass_sheet.dart:562,569`）、`stretch` / `resistance` / `glowRadius`（拖拽与光晕关掉后已无触发路径）、`settings` / `bottomBorderRadius` / `dragIndicatorColor`（未定制，走库默认）。

**测试**

新建 `test/ui/overlay_style_test.dart` **3 条**（常量契约，**硬编码字面量**——引用本仓常量 = 同义反复）；`glass_sheet_form_test.dart` **+1 条**（玻璃档确认框：`GlassDialog` 在场、`maxWidth == 280`、遮罩 `0x3D`）+ 既有形态用例 **+2 断言**（`topBorderRadius == 32` / `margin == (8,8)`）；`glass_off_fallback_test.dart` 关档确认框用例 **+1 断言**（遮罩 `0x3D`）。`ui` 组 **159 → 163 全绿**（`-j 1` 串行）、`data` **205 全绿**，analyze 0 error / 0 warning / 7 info。

**反向验证（四条，各自独立变红）**

| 回退动作 | 实测报错 | 与源码预测 |
|---|---|---|
| 玻璃档确认框改回 `GlassDialog.show` | `Expected: <61> Actual: <51>` | 吻合（Cupertino 亮色 `0x33000000` = α51） |
| 关档确认框撤掉 `barrierColor` | `Expected: <61> Actual: <138>` | 吻合（Material `Colors.black54` = `0x8A` = 138） |
| `OverlayStyle.sheetTopBorderRadius` 32 → 28 | `Actual: <28.0>`（**契约测试与透传测试同时红**） | 证明 `showSheet` 确实读该常量、并非「与库默认值巧合相等」 |
| `OverlayStyle.barrier` 改 `0x8A000000` | `alpha: 0.5412` vs `0.2392` | 契约测试钉住值 |

验后全部恢复并复跑绿（`grep "反向验证临时值\|ignore: dead_code" lib/ test/` = **0**）。

**复现命令**

```bash
/c/src/flutter/bin/cache/dart-sdk/bin/dart.exe analyze                            # 0 error / 0 warning / 7 info
/c/src/flutter/bin/flutter test --timeout 30s -j 1 test/ui test/widget_test.dart  # +163: All tests passed!
/c/src/flutter/bin/flutter test --timeout 30s test/library test/meta test/storage test/task test/highperf_registry_test.dart  # +205: All tests passed!
```

**复核边界（不伪造复核记录）**

- **可复核 → 已复核**：库 / SDK 源码行号（`glass_dialog.dart:268/271-283`、`glass_defaults.dart:154`、`glass_sheet.dart:285-313/320-332/562,569`、`cupertino/route.dart:53-56/1410-1433/1501-1502`、`material/dialog.dart:1825`）、四处反向验证实测值、`analyze` 与两组测试输出，均为本批实读 / 实跑。
- **不可复核 → 未声称**：**真机观感未复跑**，需负责人确认：**暗色主题下确认框遮罩由 Cupertino 的 α0.478 变淡到 0.239**，模态压迫感会明显减弱 —— 若觉得「压不住背景」，**只调 `OverlayStyle.barrier` 一项**即可（四个入口会同步变重，这正是"统一"的本意）。
- **未做（如实登记）**：① `parse` / `reader` 两组未跑（与本批零交集）；② **PRD 无条文改动**——`UI-03`（浮层玻璃化）只要求「所有确认框与选择器为玻璃样式 + 打开时背景内容被模糊折射」，**未规定遮罩色**，本批属实现口径统一，不新增 / 修改需求条目，故不加版本行。

### 2.60 分页引擎里程碑 M-PAGE 收官（T01~T07，2026-09-30 ~ 10-05）

| 项 | 值 |
|---|---|
| 任务 | 分页引擎独立里程碑（`docs/里程碑-分页引擎.md`；验收 = `docs/选型-阅读呈现引擎.md` §6 拍板六条 + 四保证） |
| 提交 | `2c8d0dc`（T01）`62eea07`（T02）`4dc21f1`（T03）`61137d4`（T04）`1d5f747`→`128ad1d`（T05 九提交）`7d3357f`（T06）`3628036` `c899fe7`（T07） |
| 日期 | 2026-09-30 ~ 2026-10-05 |
| 一句话目标 | `reader_page` 由 ListView 连续滚动改为原生测量式分页引擎；**滚动模式保留**（页纵向拼接），翻页模式 slide/cover/none 随后接线 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 字符偏移空间 §0 **一处定义** | `chapterPos` 真值改字符偏移比例而**字段 / JSON 不变** | `docs/里程碑-分页引擎.md` §0 | `paragraphs` 原文（含 `\x00` 标记与标签）**无分隔符拼接**；`chapterPos = charOffset / totalChars`；旧几何比例值宽容读取；可见文本投影（剥标记，IMG → 1 个 `U+FFFC` 槽）与 `typeset.dart` span 构建**必须一致**（契约测试钉死） |
| 断句回拉 | 切点在段中时页尾回拉到更好的行边界 | `page_breaker.dart`（legado `paginator.dart:114-142` 直译） | 类别优先（段末/句读 > 逗顿 > 空格）、同类取最靠后、窗口 ≤50 字符、回拉后页内 ≥1 行；**行字符区间** = 行垂直中点 `getPositionForOffset` + 下一行行首（`LineMetrics` 无 startIndex/endIndex，SDK `text.dart:2865-2889` 已核） |
| 测量-渲染同源 | 分页低估会累积溢出 | `page_renderer.dart`（R2） | 四支点：同宽（Column stretch=页宽）/ 同样式同缩进 / 同缩放（`MediaQuery` linear）/ 同 strut（`DefaultTextStyle`——不包则 strut 吃 ambient 行高漂移）；`OverflowBox(minH=0,maxH=∞)` 解耦 Column 无界高 |
| **占位对齐 middle→bottom** | 混排行行盒实测差 3px，不改分页低估 | `d44f34c` 探针实证 | 渲染侧 `typeset.dart` WidgetSpan 用 SDK 默认 `bottom`（`placeholder_span.dart:45`），测量原用 `middle` → 混排行 48.0 vs **51.0**；测量必须与渲染同口径 |
| 章标题高预留 | 标题字符不进偏移空间、不进 `totalCharCount`（拍板①） | `PageBreaker.paginate(firstPageHeight)` | 页 0 预算 = 页高 − 标题高；`headingHeight` **不进 `PaginationConfig`**（config 是缓存键，逐章不同会 `_acceptConfig` 全清）；调度器复用路径校验高度一致才复用 |
| 图片真尺寸进测量 | 48×48 占位低估真实行高 | `lib/reader/image_dimensions.dart`（T05-b） | **纯 Dart 文件头解析**不解码像素（`ImageCacheLRU` value 是字节）；`fitWithinWidth` 同式 = SDK `box.dart:317`「仅宽超限才缩」；变更走 `invalidateForImageSizes()` + 原 `targetCharOffset` 重 `open` 重锚 |
| 页即图层 | 动画期零排版零 rebuild（保证③） | `page_turn_layers` / `paged_turn_body.dart` | `RepaintBoundary` 静态页 + `Transform`/`ClipRect` 回放；commit/cancel 速度阈值判定；动画期冻结排版队列 |
| 分页滚动容器 | 滚动模式保留（拍板①） | `paged_scroller.dart`（T05-c c2） | 三章页窗口 + `FlatPage` 绝对坐标二分；**跨页段间距**只在相邻页分属不同段时补；停手 200ms 防抖采样；`clamp(...)` 赋 `double` 须 **`.toDouble()`** |
| 一次落位 | 跳转 ≤8 帧校正环退役（保证④） | `offsetForCharOffset` → `jumpToCharOffset` | charOffset 二分页码 → 单次 jumpTo + clamp；搜索/目录/链接跳转同源 |
| EPUB 结构缓存 | 重开零解析（保证①） | `lib/format/structure_cache.dart`（T06） | 判据 `bookId + mtime/size`；命中跳过 isolate 直接 `bindEpubResult`；miss 走原路径成功后写回；读/写故障一律当没接缓存 |
| 226 条几何断言审计 | 防「像素断言假红」阻塞分页迁移 | T07（`3628036` `c899fe7`） | 需改写的**仅 1 条**（回归③ 章标题滚出视口像素断言 → `hitTestable()` 视口语义 + `sampleNow()` 章内字符比例 `inInclusiveRange(0.3,0.7)`）；其余合法保留（页顶对齐落位契约 / 视口契约 / 纯函数单测输入 / 防假绿哨兵） |

**§6 拍板六条核对（全满足，证据 2026-10-05.md）**：①scroll 默认（`reading_prefs.dart:73`）②字符偏移三件套单测 ③四模式 `scroll/slide/cover/none`（curl P2 未做=符合拍板）④章内分页（next→`page:0` / prev→`pages.length-1` + 三章窗口）⑤结构缓存零派发实证 ⑥独立里程碑在档。

> **未做（如实登记）**：① `bash tool/test.sh all` 全量——负责人明令后跑（挂账 #3）；② `schedule.md` 插入位回补（挂账 #4）；③ curl 翻页 P2；④ 正文磁盘缓存（§6 ⑤⑵ 明确后置）。

### 2.61 M3 统计页 T10~T13（STAT-03~07，2026-10-02）

| 项 | 值 |
|---|---|
| 任务 | M3 统计页支线 T10a/T10b/T11/T12/T13（PRD `STAT-01/03~07`） |
| 提交 | `7f6da98` `fb60186` `6851af2` `5ad7968` `0bc7fa1` |
| 日期 | 2026-10-02 |
| 一句话目标 | 统计页四件套一次交付：总览三指标、周期柱状图、全时段热力图、按书排行与连续天数；**图表自绘零图表包** |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 聚合纯函数与副作用分离 | 聚合可单测、服务可注入 | `lib/stats/aggregator.dart` | 起始日期过滤 + `duration>0` 逐秒求和 + 天/书去重 + 时长格式化边界；全部纯函数 |
| 进程内唯一实例 | 组合根注入、监听回调 | `lib/stats/stats_service.dart` | `StatsService` 挂 main 组合根 → home_shell；起始日期配置**分文件**持久化；`clearAll` 只删会话分片（`sessions-` 前缀连带 `.bak/.corrupt/.tmp`），不动配置与其它目录 |
| 时长采集接线 | STAT-01 生产路径 | `reader_page.dart`（T10b） | ReaderPage → `StatsService` 会话累计；`test/reader/stats_collector_test.dart` 287 行钉死 |
| 图表不透明红线 | `UI-04`（图表卡片与列表行一律不透明） | `overview_card` / `bar_chart` / `heatmap` / `rank_list` | 玻璃壳层内正文卡片一律实心；`stats_page` = 玻璃顶栏 + 不透明正文 |
| 自绘而非图表包 | 不引第三方图表依赖 | `lib/ui/stats/bar_chart.dart`（239 行）等 | CustomPainter 自绘；下钻求和 = 柱高（`drill_down_page`） |
| 连续天数口径 | Q13 产品口径 | `lib/stats/streak.dart` | 「**昨天或今天**有记录不归零」——口径已写进界面文案 |
| 热力图空白语义 | 无记录 ≠ 0 分钟 | `lib/ui/stats/heatmap.dart` | 无记录天空白格（不画最低档色）；点击下钻与 STAT-04 同页 |

> **未做（如实登记，属 P2）**：单书统计 / 趋势 / 导出、阅读目标（`P2-T04`/`P2-T05`）。M4-T06 已将本批会话数据纳入跨设备并集同步（`160e2c0`）。

### 2.62 M3 AI 主线 T01~T05（AI-01~09，2026-10-02 ~ 10-03）

| 项 | 值 |
|---|---|
| 任务 | M3 AI 主线五任务：T01 配置与底座 / T02 划词三件 / T03 摘要 / T04 跟书问答 / T05 人物梳理 |
| 提交 | `7ce923b` `638c956` `be5ef41` `f6c4e03` `33befc8` |
| 日期 | 2026-10-02 ~ 2026-10-03 |
| 一句话目标 | 底座先行（流式 / 取消 / 缓存 / 并发只写一套），五个功能复用同一套交互与持久化形态 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| OpenAI 兼容配置 + 用途路由 | 四功能共用一份配置 | `provider_config.dart` / `provider_store.dart` | 四要素 + 用途枚举；`configFor(用途)` 路由（摘要优先回退 chat）；**apiKey 结构性不落盘**（`AiKeyVault` 挂 SecureStore，`DATA-02` 明文降级已标注） |
| 自建 SSE 流式 | 可取消、错误可分类 | `lib/ai/ai_client.dart` | `dart:io HttpClient` 逐帧读；错误五分类（401/404/超时/网络/5xx + `retryable`）；**并发闸上限 2**；测试连接 |
| 选区浮层可复用 | TTS-02 高亮同源 | `selection_overlay.dart` / `selection_ai_sheet.dart` | 选词 → 翻译/释义面板 → 生词本（`vocab_store`/`vocab_page`） |
| 逐章递进摘要 | 可中断可续做 | `recap.dart`（SummaryJob）+ `summary_cache.dart` | 逐章缓存续做 + 协作取消；两级缓存；控制条 AI 入口（TYP-05） |
| BM25 章级倒排 + 段级重排 | Q6 不上向量 | `lib/ai/bm25.dart` / `ask_panel.dart` | 引用点击跳回原文（F5）；**阈值 5 埋点已留**（M3.5 阈值表补齐时可测） |
| 实体抽取的**代码侧去重** | 守验收①②（名字保真、不靠模型二次合并） | `lib/ai/entities.dart` | JSONL 流式逐行解析 + 数组/围栏/pretty-print 整段兜底；`mergeEntityItems`：名字首见保真、章节并集、描述递接；默认范围 = 仅已读（RD-04 口径） |
| **测试铁律（本批实证）** | 防连环假红 | `test/ai/**` | ① `AiPrefs.defaultSelectionOnly = true` **默认开启**——非受限用例 setUp 必须 `setSelectionOnly(false)`；② **keep-alive 连接必须在测试体内关**（`runAsync(server.close(force:true))` + settle 排事件循环，teardown 才关会被 15s `_HttpClientConnection.startTimer` 抓到）；③ widget 测试 `HttpOverrides` 劫持全局 HttpClient（一律 400）→ mock server 须 setUp 里 `HttpOverrides.global = null`；④ dart:io 响应默认 `bufferOutput=true`——「发帧不关连接」必须在任何 write **之前**关缓冲；⑤ Clipboard 无默认 mock（`MissingPluginException` + 未 await = unhandled async error）→ 注册 `SystemChannels.platform` handler |

> **未做（如实登记）**：阈值 5 基线测量属 M3.5-T02 增补（AI 已就绪、埋点已留）；`defaultSelectionOnly` 默认开 = `AI-09` ③ 受限标注按拍板实现，问答专属不拦截范围行。

### 2.63 M3 TTS 主线 T06~T09（TTS-01~07，2026-10-03 ~ 10-05）

| 项 | 值 |
|---|---|
| 任务 | M3 TTS 主线四任务：T06 系统朗读 / T07 后台与系统集成 / T08 设置·定时·进度联动 / T09 在线引擎 |
| 提交 | `82ef0fb` `4c1be57` `4c17e7a` `772a31f` |
| 日期 | 2026-10-03 ~ 2026-10-05 |
| 一句话目标 | 系统 TTS 先行（段落朗读 + 高亮跟随），后台播放与在线引擎双引擎随后；朗读不建第二套进度 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 代数（generation）取消 | 停止/换段后旧回调作废 | `tts_controller.dart` | `_gen`：start/stop/resume 各 ++、pause 不 ++；从指定段起读、跨章续读、纯标点段跳过；引擎三结局 `TtsSpeakResult` |
| 粘性高亮跟随 | 只滚动到段落可见处 | `highlight_follow.dart` | `isParagraphVisible` ratio=0.5；`SpeakingHighlight` 恒定一层 `DecoratedBox` |
| 音频焦点宿主自取 | flutter_tts 焦点回调是空的 | `lib/tts/audio_session.dart` | **flutter_tts Android `requestAudioFocus` 是空 listener** → 来电暂停/恢复必须宿主自取：`speech()` 配方（`willPauseWhenDucked=true`，duck 也走暂停-恢复） |
| AudioService 一进程一次 | 重复 init 断言崩 | `lib/platform/audio_service.dart` | `_cacheManager==null` assert → handler / 事件总线必须**静态**；`DefaultCacheManager()` 构造即异步 IO → 注入 `_NullArtCacheManager`（MediaItem 恒无 artUri）；Windows/Linux 测试宿主默认 `NoOpAudioService` |
| Dart cascade 闭包坑 | 编译期 setter 报错 | T07 实证 | cascade 赋值里箭头闭包须再包一层：`..onX = (() => f())`——否则 `=> expr..next` 对 expr 开级联；`AudioHandler` 的 mediaItem/playbackState 是只读 ValueStream，上屏走 `BaseAudioHandler` 派生 + `BehaviorSubject.add` |
| **TTS 直写与跟随跳的队列挤占**（自动跟随回归根因） | 每段直写挤爆 AtomicFile 队列 | `_followSpeakingPaged(saveOld: false)`（`4c17e7a`） | 每段 `_writeTtsProgress`（save+markRead，十余次 IO）与 follow 跳的 `_pagedJumpTo(saveOld:true)` 同挤同路径 `_tails` 队列 + `settle(20)` 轮预算 → saveOld 每次拖到下轮才排空，而下一段 `++_primeSeq` 已把本跳作废（探针 `abort1 seq=2 now=3`）→ offset 卡 43。**修法**：直写已在本段入场同步置 `_ttsProgress` 并落盘同一坐标，跟随跳 `saveOld:false`（重写完全相同的数据无意义）。**沉淀**：widget 测试「同路径两条未 await 的写链」会挤占 settle 预算——探针用 begin/enter/saved/done 三点夹逼定位 |
| 双引擎切换 | 系统 / 在线 | `online_tts.dart` + `tts_settings_page.dart` | URL 模板 / OpenAI 兼容 `audio/speech` 双模式；5xx/429 有限重试 3 次、4xx 立即失败；**sha256 请求指纹 + 本地音频缓存**（`tts_audio/`，tmp+rename 原子写）；stop/换段作废回 cancelled；密钥走 `AiKeyVault`；引擎切换丢弃控制器重建；新增依赖 `audioplayers 6.8.1` |
| 后台播放平台面 | Android 前台服务为主成本 | AndroidManifest + `MainActivity : AudioServiceActivity` | WAKE_LOCK/FGS_MEDIA_PLAYBACK/POST_NOTIFICATIONS + MediaButtonReceiver；iOS `UIBackgroundModes=audio`；Linux/macOS 降级仅前台（已确认）；`androidStopForegroundOnPause:false`（Android 12+ 后台重启 FGS 受限） |

> **未做 / 待真机（如实登记）**：① POST_NOTIFICATIONS 系统自动提示是否弹（不弹需补运行时请求）；② 锁屏续读、iOS 全链路（R3 需 Mac）；③ flutter_tts 4.2.5 = pub 最新，无支持 Built-in Kotlin 的版本（上游 issue #644/#647 已存在，非致命保留）。

### 2.64 M35-T03 ① ② ③ — 最小 FRB 通路脚手架 + `mobi` KF8 最小验证（2026-10-05）

| 项 | 值 |
|---|---|
| 任务 | M3.5-T03 ★GATE★ 的**实施半边**（RUST-07/08/04、Q20、Q25）；gate 实跑与拍板在负责人 |
| 提交 | `76cd350`（前置 lint 清零）`ae46fb5`（脚手架）`f3cc47b`（KF8 探针） |
| 日期 | 2026-10-05 |
| 一句话目标 | 把 gate 需要的三样东西备齐：**最小 FRB 通路**、**无 cargo 构建降级**、**`mobi` crate KF8 能力实证**——过不过由负责人 5 条命令说话 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| Rust 侧最小实现 | 对齐 `kRustAbiVersion` 的可探测面 | `rust/api/{mod,error,guard}.rs` | `ffi_guard` + `probe() -> "0.1.0"`；`#![deny(clippy::disallowed_methods)]` + `clippy.toml` 6 条 NF-D8；Cargo.toml 双 profile 显式 `panic=unwind`、frb=2.13.0 精确锁 + thiserror + mobi |
| **官方模板经本机 codegen 收割**（非手写） | 防手搓 Cargokit 与官方漂移 | `rust_builder/**` 46 文件 | 在 `_t03_scratch` clone 上跑 codegen 2.12.0 `integrate` 收割；android `ndkVersion` 校准结论 = **维持 `flutter.ndkVersion`**（3.47.5 默认 28.2 ≥ 规格 27）不硬编码 |
| codegen 2.12.0 跑通三实证 | 消除「冷启动能不能生成」疑虑 | scratch 实录 | ① 泛型 `ffi_guard` 被 FRB **自动跳过**（`functions are ignored because they have generic arguments`）；② 冷启动（无 `frb_generated`）codegen 可自产；③ main.dart demo 覆盖与 2.12 生成物**不取** |
| 护栏测试 ×2 | 防生成物漂移 / 反排除丢失 | `generated_files_committed_test` 改造 | 原「生成物必须已提交」与 `.gitattributes` §G.4 反排除**字面互斥** → 改为「有效规则行提及 `lib/src/rust` 必须以 `!` 开头 + `!` 反排除在场 + `*.dart` 通配判红」 |
| **KF8 两种入口探针**（Q25 退化分支坐实） | gate ③ 判语留档 | `rust/tests/kf8_gate`（`f3cc47b`） | `entry-a`（纯 KF8 azw3）：`open=OK version=8 content=PANIC verdict=UNSUPPORTED`——正文解码 panic（`record.rs:154` PDB 切片 `next_offset - extra_bytes < curr_offset` 无下界保护）；`entry-b`（KF6 头 + EXTH121）：`boundary=Some(5281) version=6 jumped=false content=OK(215274 chars) verdict=KF6_HEADER_ONLY`——EXTH121 可读但 crate **无跳转逻辑**；源码实读 crate **无 INDX/TOC 章节列表 API** |
| 探针设计 = 事实留档型 | 不以红测入库 | catch_unwind 包正文解码 + `GATE[...]` 判语行 | 稳定断言（打开 / version / EXTH121 在场）才 fail；panic 分支只打判语 |
| R1 结论 | 「两者都不利」**未触发** | — | M2b-T05 纯 Dart 双分支 HIT（KF8 必须走 Q25 预注册分支：直译 Kotlin boundary/SKEL/FRAG）→ 负责人拍板材料 |
| lint 清零 | 消除 analyze 噪声 | `76cd350` | archive 4.3.0 `ZipEncoder().encode` 已返回非空 `List<int>`（3 处迁移残留可空声明）；`mobi_probe` 私有类型进公开 API（`_CdicEntry`→`CdicEntry`）——**7 → 0** |

**交负责人命令（gate 实跑，5 条）**：① `cargo install flutter_rust_bridge_codegen --version 2.13.0`（RUST-08 三处同版）；② 仓库根 `flutter_rust_bridge_codegen generate` → 生成物 + Cargo.lock 全部入库；③ gate① `flutter build apk --debug` / `flutter build windows --debug`（Cargokit×3.47.5）；④ gate② cargo 移出 PATH 后 `flutter test` + `flutter build` 仍过（无 Rust 降级）；⑤ gate③ `cd rust && cargo test --test kf8_gate -- --nocapture`。

> **未做（如实登记）**：① `lib/src/rust/**` 生成物与 `integration_test/frb_probe_test.dart`——**依赖 ②codegen 先跑**（下一轮补，RustLib.init + probe 对齐）；② scratch 遗留 `D:\Projects\_t03_scratch`（模板收割用，含 cargo target）批次清理由负责人执行；③ 五能力 Rust 实现属 T04/B 线（gate 通过才开工）。

### 2.65 M4 WebDAV 同步 T01~T06（SYNC-01~07 + STAT-08，2026-10-05）

| 项 | 值 |
|---|---|
| 任务 | M4 同步支线六任务（T01 通道 / T02 进度 / T03 条目合并 / T04 备份恢复 / T05 自动触发 / T06 统计并集） |
| 提交 | `cd9b14c` `55d0651` `500c277` `5c7936a` `8590e0a` `160e2c0` |
| 日期 | 2026-10-05 |
| 一句话目标 | 同步通道**只做一遍**（PRD §17，STAT-08 复用）；进度取新、条目并集、备份白名单、触发四时机、失败可见 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 通道只做一遍 | 六任务共用 | `webdav_client.dart`（T01） | 纯 `dart:io HttpClient` + xml 解析 PROPFIND；Basic 认证；`Depth` 头无常量→字面量；路径相对 `{url}/{dir}/` 根、段逐个 `encodeComponent`；`stat` 404→null、`delete` 404 幂等、`upload` 507→diskFull；错误剥 XML 细节 → 中文可读 160 字 |
| 密码不落明文 | `DATA-02` | `SyncPasswordVault`（prefix=`sync.password.`） | `sync_config.toJson` 结构性四键**无密码**；配置持久化 `sync_state` 分文件 |
| **进度「取更新」闸门**（F7） | 只在需要时发请求 | `lib/sync/conflict.dart`（纯判定零 IO） | `stat` → 远端缺失分流 → **闸门 stale**（`local.updatedAt > syncedAt` 才上传；否则 **skipped 连 GET 都不发**）→ 下载 → `takeRemote`/`keepLocal`/`identical`；口径：闸门 `<=` 含等于、`remoteModified=null` 放行、**跳过不更新 syncedAt**（否则闸门永久失效）、hint 双向丢弃、跳过/判同/上传后均 `markSynced(now)` |
| **裁决对称性** | 防双侧互不来回覆盖震荡 | `entry_sync.dart`（T03） | `resolve(l,r)` 必须与 `resolve(r,l)` 同胜者：`byContent`（JSON 字典序大者胜）与 `resolveIndexConflict` 三级（`lastReadAt` 新者胜 → 任一 origin==`user` → 字典序）均满足；变更按**内容指纹**判定防无谓回写 |
| 设置同步的**内容相等短路** | 防「下载 → mtime 变新 → 再上传」回声 | `settings_sync.dart` | 判定序：stat 缺失 → download（**放 try 外**，通道失败不误报「损坏」）→ 非 Map → failed → `local==null` → save → **相等先短路** → 远端 mtime 缺失视为最旧 → 上传；同刻**远端胜**（收敛）；本地 mtime = 偏好**文件** mtime（HttpDate 1 秒分辨率，同刻测试须 `setLastModified` 整秒对齐） |
| 备份包**白名单结构性排除凭据** | `DATA-02`：包内搜不到密码 / API Key | `lib/sync/backup.dart`（T04） | 白名单顺带排除 sync_config / credentials / sync_state / ai_providers / 书籍副本 / structure / covers / 旁路后缀——**凭据不进包靠结构不靠黑名单**；测试解压全字节搜敏感串 |
| **恢复闸门零写入优先** | 校验不过一个字节都不写 | `lib/sync/restore.dart` | zip 可解 → `meta.json` 必有 → `schemaVersion ≤ 1`，全过才分派；四闸门用例断言 `targetDir.listSync(), isEmpty`（**setUp 禁存 sync_config**——会落文件污染断言）；**zip slip**：`normalizeZipPath` 不折叠 `..` → 分派层白名单自拒 |
| 段级剔除语义 | 坏一段不毁整包 | `_readJson` 损坏 → null → 跳过该键 | 损坏段剔除但**完好段照常进包**（settings 只坏 app → 包内仅 `{reading}`）；**双段全坏才整条不进包** |
| 触发四时机 | PRD §10.4 + B.4 | `lib/sync/sync_trigger.dart`（T05） | 启动**仅拉进度**（测试断言远端 `library` 零触碰）；退页 = 单本进度 + 备份到期；退出 App = 进度 + 三件套 + 备份；间隔 1 天（拨钟 +25h 钉死）；**跳过报告不落 `lastReport` 不通知**；失败 = `failures` 逐条 + 重试按钮 |
| 取消确定性 | 断点续传的可取消 | `uploadStream` / `downloadToFile` | `File.openRead` 64KB 分块（dart:io `_blockSize`）——200KB 首进度 cancel → 第 2 块前抛；断言「远端无**完整**文件」；失败路径先 `request.done.ignore()` 再 `abort()`（防 unhandled async error） |
| 统计并集幂等 | STAT-08 复用通道与 `mergeById` | `lib/stats/stats_sync.dart`（T06） | 会话 `id` 并集、同 id 时长取大；`sync_state.json` 单文件双键同写（`lastBackupAt==0` 不落键保既有精确断言） |

**测试基建（T03~T06 直接复用）**：`_MockDav`（PROPFIND/GET/PUT/MKCOL 四方法内存服务端 + `failStatus` 注错 + `seed()/seedBytes()`；文件键 = `Uri.encodeComponent` 逐段拼，与 `WebdavClient._segments` 同口径）；`_MemorySecureStore`；纯 `test()` 真 socket。**关键实证**：widget 测试 `TestWidgetsFlutterBinding` 装 `HttpOverrides` 把 suite 内 HttpClient 拦成 400（框架自警）→ 连接类 UI 用例注入 `_StubWebdavClient`/`_FakeDav` 只验呈现，真网络语义留纯 `test()`；开关落盘断言需**默认 40 轮 settleReal**（exists→write flush→rename 每步占一个 runAsync 窗口）。

**lint 三连（同型坑）**：① `prefer_initializing_formals` 触发条件 = 字段名恰为 `'_'+参数名`（`_client=client` 触发、`_progress=progressStore` 不触发）→ 命名初始化形参**不能**写 `this._x` → 行尾 `// ignore:` + 两行理由（先例 `high_perf_registry.dart:72`）；② `SyncRunReport` 静态工厂与实例字段**不可同名**（`conflicting_static_and_instance`）→ 字段改 `wasSkipped`；③ `GlassOverlays.showToast` 返回 **`VoidCallback`**（dismiss 回调）非 Future → `await` 触 `await_only_futures`。

> **未做 / 范围注记（如实登记）**：① 笔记无存储待落地后并入；② **书签删除不跨设备传播**（并集无墓碑，PRD 未定义）；③ `progressRemotePath` 净化 `/\.?`→`_` 防被客户端拆目录、作者空→`未知`；④ M4-T07（MOBI）受 gate 阻塞、T08/T09 属验收批。

### 2.66 挂账 #6 — 无 toc 大书搜索首屏优化（阈值 4 纯 Dart 路径，2026-10-06）

| 项 | 值 |
|---|---|
| 挂账 | 进度表挂账 #6 / 阈值 4（PRD §15.6）：48M 字符无 toc EPUB 搜索首屏 4.2s（2.8× over），根因 `flatTitles` 全书预取是搜索的纯前置成本 |
| 提交 | `aba22eb`（docs 本文档随后提交） |
| 日期 | 2026-10-06 |
| 一句话方案 | **搜索的标题需求与全书标题预取解耦**：搜索路径跳过预取（`prefetchFlatTitles: false`），命中章标题从扫描循环已有的 `extractSection` 结果零成本取得 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| **开关透传链** | 纯数据跨 isolate 的条件预取 | `EpubParseRequest.prefetchFlatTitles`（默认 `true`）→ `parseEpubStructureTask` → `parseEpubStructure` → `_parse` 第 8 步 | 默认 `true` ⇒ 所有既有调用点一字不动；`_parse` 无 toc 分支分两支：真预取（原样）/ 占位 |
| **占位而非空 map** | 防消费方 miss 回退现场解压 | `_parse` skip 支填 `{ref.href: ''}` | 空 map = 「未预取」→ `_flatChapter` 现场逐章解压 = 把预取消掉的解压挪到消费方（等于没省）；`''` = 「已预取无标题」→ 「第 N 章」占位**不再解压**。键集与真预取一致（缺文件章两边同跳过） |
| **命中标题零额外成本** | 解耦的核心 | `DartEpubSource.search()`：`extractSection(section.rawBytes)` 的结果同时供 `paragraphs` 与**标题** | 无 toc 时 hit 标题 = `_flatChapter(section, i, nonLinear: !section.linear, title: extracted.title).title`（保留「（非主线）」后缀、与 `chapters()` 同源同值——预取存的就是同一字节流的同一 h1）；**有 toc 时保持 `chapter.title` 不变**（否则 toc 标题被 h1 顶掉） |
| **占位结构禁写缓存** | 防污染阅读页 | `_parseOffloaded` 写回条件加 `&& prefetchFlatTitles` | skip 模式解析出的 `flatTitles` 全是 `''`，写回后阅读页命中缓存会把「第 N 章」占位当真标题；缓存**读**不受限（真标题结构对搜索同样有效且更优） |
| 两处调用点同口径 | 后台与回落路径一致 | `search_session.dart` `_searchIsolateMain:202` 与 `_LocalRun._run:366` | 均传 `prefetchFlatTitles: false`；`book_registry.dart` `open`/`openBook` 加同名透传参数（默认 `true`，其余格式忽略） |
| PerfLog 分账扩展 | 观测 skip 是否生效 | `epub.flatTitles` 行尾 `prefetch=0/1` | 原格式仅 `sections=`；无工具解析该行（grep 全仓实证），可安全扩展 |

**测试（4 新增 + 回归，`flutter test test/format test/search test/epub test/meta test/task` 全绿 483 条）**：
① skip 形状断言（占位 map + 键集与真预取一致）；② `chapters()` 占位命中不回退（得「第 1 章」）；
③ **skip 与 prefetch 两模式 search 命中标题同值（真实 h1）**；④ 非主线后缀保留 + 有 toc 标题回归；
⑤ 缓存写回 guard（skip → `writes==0`，默认 → `writes==1` 对照）；⑥ `search_session` 端到端
（spec 后台重建命中标题 = `['第一章','第一章','第二章']`，占位不泄漏）。
既有 `search_session_test:93`「命中标题 == chapters() 同源」断言自动覆盖跨模式同值。

**效果与边界（如实登记）**：跳过的成本 = 无 toc 书全书逐章「解压 + XHTML 抽标题」
（48M 字符样本 ≈145MB inflate），即 4.2s 根因链的 ①。**开发机复测已回填**
（`search.md` §5 复跑输出，同机同词 3 轮）：**首屏 4179/4227ms → 52/65ms（约 80×，
2.8× over → 达标）**；全书 total 8418 → 4286ms（省掉预取那一遍，剩余为逐章扫描
本底）；对照组不变量（big_320 / TXT / 四组命中计数 1/100/1/1）全部无回归。
**Android 主力机 AOT 正式判定待随 M3.5-T02 批次复跑**；有 toc 真书 c 项复测同批。

### 2.67 M3.5-T03 gate：vendored cargokit 不兼容 Gradle 9（`project.exec` 移除，2026-10-06）

| 项 | 值 |
|---|---|
| 症状 | `flutter build apk --debug` 失败：`rust_builder/cargokit/gradle/plugin.gradle` line 68 `Could not find method exec() ... on project ':rust_lib_mreader' of type org.gradle.api.Project`（BUILD FAILED 9m16s） |
| 提交 | 代码 + 护栏随后提交（本文档同批） |
| 日期 | 2026-10-06 |
| 一句话方案 | vendored cargokit 的两处 `project.exec` → 注入 `org.gradle.process.ExecOperations` 后用 `execOperations.exec`（上游 fzyzcjy/cargokit main 同款修法） |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| **Gradle 9 删 `Project.exec()`** | 根因 | Flutter 3.47 工具链 = Gradle 9.1.0 / AGP 9.0.1 / Kotlin 2.3.20 | `javap org.gradle.api.Project` 实证**无任何 exec 成员**；`org.gradle.process.ExecOperations.exec(Action<? super ExecSpec>)` 在场 ⇒ 官方替代 = 任务类 `@Inject abstract ExecOperations getExecOperations()` |
| **全仓仅此 2 处** | 修面收敛 | `plugin.gradle` 第 72/77 行（chmod 支 + build-gradle 主支） | grep `project.exec` 全仓命中数 = 2，均在本文件；其余环境变量行原样 |
| **注释写「同款修复」而非「逐字节相同」** | 留证诚实 | 任务类头注 | 本仓加了上游没有的 4 行警告注释，不能自称 byte-identical；注明 javap 实证与「勿回退」 |
| **codegen 2.13.0 内嵌模板仍是坏版本** | 覆盖风险 | `flutter_rust_bridge_codegen.exe` 字符串统计 | `project.exec` ×2、`ExecOperations` ×0 ⇒ **重跑 `generate` 重写脚手架会把修复覆盖回坏版本**；已在护栏测试头注写明 |
| **护栏测试（沿 RUST-04 纯文本先例）** | 防静默回退 | `test/rust_profile_guard_test.dart` +1 | 断言无 `project.exec(`、有 `execOperations.exec`、有 `@Inject abstract ExecOperations getExecOperations`；文件缺失环境自动跳过 |

**实证链**：读 wrapper 确认 Gradle 9.1.0 → javap 查 `Project`/`ExecOperations` 签名 → WebFetch 上游 cargokit main 拿官方修法（curl raw.githubusercontent exit 56，改用 WebFetch 内容比对）→ 应用 3 处编辑（imports / `@Inject` getter / 两处调用）→ `git diff --stat` 11+/2− 无行尾漂移 → 护栏测试 + analyze 零问题 + 3 条测试绿。

**边界**：① 未实跑 `flutter build apk --debug` 复验（构建命令归负责人手动跑，gate 命令链见 M3.5-T03）；② flutter_tts KGP 警告与 Flutter assets 走 storage.flutter-io.cn 属**另有提示**，非本次失败因；③ `CHANGELOG` 不记（代码/构建类，按拍板口径「只记用户可见功能变动」）。

### 2.68 阅读页 chrome 分组收纳（顶栏 9→6 按钮 + 控制条三组化，2026-10-06）

| 项 | 值 |
|---|---|
| 触发 | 负责人真机截图：顶栏 9 个图标按钮把书名/副标题**完全挤掉**；底部控制条两行 11 个控件彼此贴死、行距滑块被压到不足 30dp |
| 一句话方案 | **按用途把控件归进带标题的分组盒**（淡底圆角 + 分隔线），顶栏 4 个 AI 入口收进单个「AI 助手」面板；窄屏按实测阈值分三级降级（隐文字标题 → 隐进度读数 → 滑块换行） |

**分组划分依据**（同一用途 / 同一层级归一组）：

| 位置 | 分组 | 组内控件 | 依据 |
|---|---|---|---|
| 顶栏 | ① 检索与标记 | 搜索、书签 | `CNT-06` / `TYP-06`，页面级查找与标记 |
| 顶栏 | ② AI 增强 | **单入口** → 面板内 4 行 | `AI-04`~`AI-07` 同属 AI 能力，平铺 4 个是拥挤主因 |
| 顶栏 | ③ 外观与视图 | 外观、目录 | `TYP-03`/`TYP-07`/`TYP-08` + `NAV-01`（要求 AppBar 目录按钮）。**全屏按钮已于 2026-10-08 移除**（默认全屏，切换改走点正文，`TYP-09`） |
| 控制条①行 | 章节 | 上一章、下一章、进度读数 | 同一层级 = 位置导航；读数是「当前在哪」的组内读数 |
| 控制条①行 | 朗读与 AI | AI 摘要、朗读、朗读设置 | 同属「听/读辅助」，按可用性出，三者全关则整组隐藏 |
| 控制条②行 | 排版 | 字号(−/值/+) ‖ 行距(滑块) ‖ 版面(边距/主题) | `TYP-01`/`TYP-02`/`TYP-03` 同属排版参数 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| **9 × 48 > 屏宽** | 拥挤的量化根因 | `reader_page.dart` `AppBar.actions` | 9 个按钮 432dp > 393dp（小米机型）⇒ `title` 的 `maxLines:1 + ellipsis` 在 0 宽下什么都不剩，收纳到 6 个（288dp）后标题复原 |
| **`IconButton` 的 48 幽灵** | 「统一尺寸」的假象 | `ReaderControlIconButton` | 写 `constraints: tightFor(44,44)` 实测 `getSize` 返 **48**——`tapTargetSize` 缺省 `padded` 在 constraints 外再强制 48；且它**只在 `IconButton.style` 上**（构造参数没有）。修法：`style: IconButton.styleFrom(tapTargetSize: shrinkWrap)` |
| **`visualDensity: compact` 同样是幽灵** | 同上 | 同上 | 会把 44 缩到 **40**；紧凑效果由常量 44 本身达成，**不要加** |
| **分组盒的横向预算** | 决定滑块生死 | `reader_settings_bar.dart` | 排版组固定内容 ≈ 322dp（字号 122 + 版面 100 + 行距图标 26 + 2 分隔线 26 + 内外边距）。实测：字号/版面/行距**各套一层内盒**时 393dp 屏滑块只剩 **27dp**；去掉内盒（分隔线已足够界定）后 393dp 有 **79dp**、可用 |
| **嵌套 `Expanded` 触发无界断言** | 布局崩溃 | `ReaderControlGroup.expand` | `MainAxisSize.min` 的 Row 内放 `Expanded` → `RenderFlex children have non-zero flex but incoming width constraints are unbounded`。外层总分组必须 `expand: true`；另 `LayoutBuilder` 在 Row 里是**非 flex 子节点**，也须包 `Expanded` |
| **窄屏三级降级** | 「空间不足时优先层级清晰」 | `reader_control_chrome.dart` 三个常量 | ① < 420 隐**文字**标题（盒子仍在）；② < 348 隐控制条内进度读数（同一串文字由常驻的 `ReaderProgressIndicator` 显示，`TYP-09` 保底）；③ < 340 滑块换行独占 |
| **控制条不可长高** | 保护正文可视高度 | `kReaderControlRowPadding = 2` | 它是 `bottomNavigationBar`，长 1dp 正文少 1dp。实测一度做到 157dp 导致 `image_pages_test` 验收②「点页 → 缩放查看器」失败（整页图点击中心被压到条下）⇒ 最终 393dp 屏 107dp（改前 96dp，仅多一条分隔线 + 呼吸空间） |
| **进度读数重复** | 顺手记账 | — | 控制条读数与 `ReaderProgressIndicator` 是**同一串文字**（两处都在屏上）；降级②即基于此，不是丢信息 |

**实测基线**（`tester.view.physicalSize` 宽度阶梯，探针实测后写死进 `reader_chrome_layout_test.dart` 头注）：

| 屏宽 | 控制条高 | 行距滑块宽 | 文字组标题 | 进度读数 | 溢出 |
|---|---|---|---|---|---|
| 800 | 107dp | 充足 | 有 | 有 | 无 |
| 393 | 107dp | 79dp | 无 | 有 | 无 |
| 360 | 157dp | 298dp | 无 | 有 | 无 |
| 320 | 161dp | 258dp | 无 | 无 | 无 |

**测试**：新建 `test/ui/reader_chrome_layout_test.dart` **9 条**（高度上限 / 四档屏宽无溢出 / 控件一个不少 / 滑块可用下限 60dp / 标题降级 / 读数降级 / 功能整体隐藏 / 禁用态保留 / 44×44 统一）+ `test/reader/reader_ai_panel_test.dart` **3 条**（面板四行与回调 / `onRecap` 为 null 不渲染 / 顶栏 ≤6 按钮且书名可见）。

**回归**：`test/reader test/tts test/search test/ui` 全量——本次失败 9 条，**与改前基线同一集合**（基线 10 条，含 1 条 `ShelfPage 回归②` 窗口 flake 在本次反而通过）；零新增失败。`dart analyze lib/` 零问题。

**边界（如实登记）**：① 未真机复跑（`flutter run` 归负责人手动跑），上述数字均为 widget 测试环境的 `physicalSize` 阶梯，非真机 dp；② AI 四入口的**入口位置**从「顶栏第 3~6 个图标」变为「顶栏单个分组 → 面板行」，文案/回调/Key 全部逐条保持原样，但严格说是入口路径变化；③ 文字组标题只在 ≥420dp 出现，手机横屏与平板可见、竖屏手机只见盒子与分隔线；④ `CHANGELOG` 记 1 条（用户可见的顶栏按钮收纳）。



### 2.69 开书链路端到端追踪（点书卡 → 看到书，2026-10-06）

| 项 | 值 |
|---|---|
| 触发 | 负责人要求「从书架点击图书到阅读页看到书籍，加上耗时日志，看看哪里耗时，导致观感上的卡顿」 |
| 模块 | `lib/diagnostics/open_trace.dart`（新）+ 书架 / 阅读页各 4 处接入 |
| 一句话 | 补上既有 [PerfLog] 的**两头缺口**：计时原点（用户按下）与终点（首帧真正上屏） |

**既有埋点的两个缺口（本批的诊断依据）**：

| 缺口 | 现象 | 后果 |
|---|---|---|
| **缺头**：无计时原点 | 书架侧只有 `open.readBytes` / `open.sniff` 两个孤立点，没有「用户按下那一瞬」 | 算不出「点下到第一帧多久」；`readBytes` 的耗时也没法和后面的解析耗时放在同一把尺子上比 |
| **缺尾**：`reader.ready` ≠ 看到书 | `reader.ready` 打在 `_ready = true` 的 `setState` **之后立刻**（`reader_page.dart`），此刻正文**尚未 build / layout / paint** | 「ready 很快」会被误读成「打开很快」。**分页模式下首帧要做 measure + reprime，这段渲染成本完全没被测量**——而它正是「解析 20ms 却等 1.5s」这类现象的藏身处 |

**本批新增的链路段落**（一条 `open.*` 前缀，按时序）：

| 段落 | 打点位置 | 含义 |
|---|---|---|
| `open.begin` | 书架 `_openBook` 首行（**先于任何 await**） | 计时原点 = 用户按下书卡 |
| `open.readBytes` / `open.sniff` | 书架（`step`，带权威段耗时） | 读字节 / 嗅探格式 |
| `open.pushed` | 书架 `Navigator.push` 之后 | 路由已发起 |
| `open.routeInit` | 阅读页 `initState` | 页面 State 建立 |
| `open.ready` | 阅读页 `_ready = true` 之后 | 数据就绪、**可渲染**（≠ 上屏） |
| `open.firstFrame` | 首帧探针（`addTimingsCallback` + `addPostFrameCallback` 兜底） | **正文第一次真正上屏**，带首帧 `build` / `raster` / `totalSpan` 与 `over16ms` |
| `open.restoreEnd` | `_finishRestore` | 内容停在目标段落（「打开后还在跳」的观感指标） |

**两条汇总行**（幂等，各只打一次）：

| 行 | 口径 | 读法 |
|---|---|---|
| `open.total` | **按下 → 首帧上屏** | 用户点开书时的真实等待；含 `render=`（= firstFrame − ready，纯渲染段） |
| `open.chain` | 按下 → **位置落定**（含恢复校正） | 比 `total` 多一段 `settle=`（上屏后再花多久才停在目标段落） |

**关键判断依据**：`total` 与 `chain` **分开打**才有诊断价值——`chain ≫ total` ⇒ 打开后位置在漂（校正慢）；两者接近 ⇒ 首帧之后的校正很快，问题就在前半段。再看 `total` 里的 `render=`：它大就是渲染/排版慢，小就是解析慢（此时该去看 `reader.load` / `reader.chapters`）。

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| **`step` 用权威段耗时，`mark` 才反推** | 防关键段被丢 | `OpenTrace._segments` | 若统一用累计 `at` 反推差值，多段落在同一毫秒时算出 0ms；而 `_deltas` 过滤 0ms → **恰好丢掉最该看的 `readBytes`**（本批测试实测抓到）。故 `step(phase, ms)` 记自己的 `ms` |
| **`total` 显式排除 `settle`** | 口径不被污染 | `_emitSummary(includeSettle:)` | `report()` 在首帧时就打，`restoreEnd` 通常还没发生；但若首帧很慢、校正已先完成，`total` 会把校正耗时算进去 ⇒ 口径漂移。故按调用方标志位**显式**取舍，不依赖「时序恰好」 |
| **首帧探针双保险** | 防链路断在尾段 | `attachFirstFrameProbe()` | 主路 `addTimingsCallback`（含 GPU 段）；备路 `addPostFrameCallback` 里检测到时序未达就以 `timings=none` 兜底出 `firstFrame` + `total`，否则**这条链路会静默断在最关键处** |
| **`openTrace` 可空降级** | 不改既有测试 | `ReaderPage.openTrace` | `null`（直接进页的测试 / 深链）时本页照常打既有 `PerfLog` 分段点，只是不产出 `open.*` 汇总——「降级不等于丢观测」 |
| **`openTrace` 显式透传而非全局单例** | 避免跨书串账 | 书架 → `ReaderPage(openTrace:)` | 用全局单例会遇到「上一本残留的 trace 被误打点」；显式参数让生命周期跟着 widget 走 |
| **不打点字体/图标尺寸** | 遵守既有纪律 | — | 逐处记参数会漂，改为统一走 `ReaderControlIconButton` 那种「构造即保证」的路子（见 §2.68） |

**测试**：新建 `test/diagnostics/open_trace_test.dart` **6 条**（原点 / `total` 含 render 段 / 幂等 / `chain` 含 settle 且 `total` 不含 / 首帧探针时序 / 探针幂等）+ `test/diagnostics/open_trace_wiring_test.dart` **2 条**（未透传时降级不丢既有分段点 / `ready → firstFrame → total` 时序契约）。`dart analyze lib/ test/` 零问题。

**回归**：`test/reader test/tts test/search test/ui test/diagnostics` 全量——失败 6 条，**与改前基线同一集合**（`CNT-04c 验收②`、`STAT-01 ⑤`、`ShelfPage 回归②`、`TTS-04/05`、`settings_page_test 玻璃效果`（已知并行 flake，串行复跑同样红 ⇒ 基线已红）、以及 `test/settings` 路径不存在导致的 load 报错）。零新增失败。

**边界（如实登记）**：① **未真机复跑**（`flutter run` 归负责人手动跑）——本批只交付埋点，**尚未拿到真实耗时数字**，下一轮需负责人跑一次 `flutter run` + `adb logcat -s flutter | grep "open\."` 回填；② 首帧时序在 debug 档数值不可信（`product=false`，见 `perf_log.dart` 头注），判瓶颈须看 **profile/release**；③ `open.firstFrame` 的 `raster` 在 widget 测试环境常为空（有 `timings=none` 兜底），真机才有值；④ 未覆盖「从书库搜索页选中结果开书」这条入口（`library_search_page.dart` 另走一路），如需一并观测可复用同一 `OpenTrace`。

#### §2.69 附：真机首轮数据（2026-10-06 18:36~18:37，小米 25098PN5AC / Android 17）

**数据源**：`flutter run --profile -d bc75b5f3`，`adb logcat -s flutter | Select-String "open\."`，连续开书 11 次。

| 书 | 章数 | 大小 | `open.total` | `ready` | `render=` |
|---|---|---|---|---|---|
| 绘卷（epub，缓存冷） | 447 | 4.3MB | 597ms | 596ms | 1ms |
| 绘卷（缓存热） | 447 | 4.3MB | 418ms | 418ms | 0ms |
| 枯X（epub） | 1152 | 6.8MB | 548ms | 547ms | 1ms |
| 绘卷 | 447 | 4.3MB | 356 / 333 / 329 / 407 / 324 / 390ms | 同 total | 0~1ms |
| 大宋药师（**txt**） | 1078 | 7.2MB | 407ms | 404ms | 3ms |

**结论（与埋点时的初始假设相反，值得记档）**：

1. **渲染不是瓶颈**——`render=`（ready → 首帧上屏）**全部 ≤ 3ms**，首帧
   `build` 0.6~6.6ms / `raster` 0.9~6.9ms，`over16ms=false` 从未出现。
   ⇒ 我在 §2.69 开头怀疑的「分页首帧 measure+reprime 慢」**被数据否掉**。
   此前没有 `render=` 这个分段时，这个问题**无法回答**（`reader.ready`
   之后的一切都是黑的）——这正是本批埋点的价值。
2. **瓶颈 100% 在 `routeInit → ready` 的数据准备段**（`ready` 占 `total`
   的 99~100%）。该段内部有四个子点：`reader.load` / `reader.chapters` /
   `reader.stores` / `reader.firstBatch`（`reader_page.dart:694-777`），
   **本轮日志被 `grep "open\."` 过滤掉了**，下一轮需放开过滤才能定位到子段。
3. **缓存对 `total` 无明显影响**：绘卷冷启 597ms vs 后续 324~418ms，首启
   高出约 180~270ms（结构缓存写入需重解析 + 落盘）；但热启仍需 324ms 以上，
   说明**大头不在结构缓存**，而在每次都做的首章内容读取等固定成本。
4. **章数不是主因**：1078 章 TXT（407ms）比 447 章 epub（324ms）只多 83ms，
   而大小 7.2MB vs 4.3MB ⇒ 与**字节量**的相关性大于与章数的相关性。
5. **`timings=none` 出现过一次**（大宋药师 txt 开书）：`addTimingsCallback`
   未回调，兜底路径生效（仍产出 `firstFrame` + `total`）——**双保险设计在真机
   上确被验证必要**。

**本轮同时修掉的埋点缺口（真机数据暴露）**：`open.chain` 与 `restoreEnd`
在 11 次开书中**全部缺失**。根因：两者原挂在 `_finishRestore`，而**分页模式走
`_pagedJumpTo` 一次落位、根本不经过 `_finishRestore`**（那是 ListView 路径的收口）
⇒ 分页模式下这条链路指标永不触发。修法：改挂在 `paged.land`（分页路径唯一的
落定信号，`reader_page.dart:1902`）。教训：**链路埋点挂点必须按「实际执行路径」
选，不能只挂在某一分支的收口上**——单测环境（ListView 路径为主）测不出来，
真机分页路径才暴露。

#### §2.69 附二：瓶颈定位（第二轮数据，2026-10-06 18:43，绘卷 1152 章 / 6.8MB）

**分段数据（3 轮，单位 ms）**：

| 轮次 | readBytes | sniff | routeInit | epub.cache | reader.load | reader.chapters | reader.stores | **reader.firstBatch** | open.total |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 16 | 0 | 8 | 9 (`hit=1`) | 18 | 26 | 2 | **746** | 821 |
| 2 | 17 | 3 | 5 | 13 (`hit=1`) | 23 | 49 | 1 | **746** | 849 |
| 3 | 15 | 0 | 9 | 11 (`hit=1`) | 21 | 49 | 2 | **924** | 1023 |

**结论：`reader.firstBatch` 独占 88~91%**（746/821、746/849、924/1023），
其余全部环节加起来仅 79~111ms。渲染段 `render=` 仍为 **0ms**。

**根因（两条决定性证据链）**：

1. **结构缓存已命中仍要 746ms**——三轮 `epub.cache hit=1`（零解析），说明
   746ms **与 EPUB 结构解析无关**。
2. **后台补齐同一批章只要 0~2ms**——首帧后 `reader.content index=40..54`
   连续 21 章全是 `0~2ms`，而首帧那3 章（41/42/43）是 `746ms`。
   ⇒ 同样的 `content(i)` 调用，首帧慢 300 倍以上 ⇒ **不是单章解析本身慢，
   而是首帧那一批撞上了一次性的预热成本**。

**机理**：`DartEpubSource.content(i)` 取 `section.rawBytes`
（`dart_epub_source.dart:275`）。`EpubSection` 走 `PERF-02` 的**惰性实体**
（`epub_book.dart:93`）：构造不取字节，**首次访问 `rawBytes` 才回调
`loadBytes` 解压**。而 `loadBytes` 来自 `OpfView` 的归档读取器——**首次触碰
任一 entry 时要把整个 zip 的中央目录 / 条目表初始化起来**（archive 3.x 的
`ZipDecoder` 一次性建索引）。这一下preheat 摊在**首帧第一次 `content()`** 上：

- 首帧：3 章并发调`content()`，谁都拿不到 → 各自触发解压回调，其中一份
  付掉**全量归档初始化**（~740ms），另两份等待 ⇒ 三者都显示 `746ms`；
- 之后：归档已热，单章 `0~2ms`。

**这解释了此前所有观察**：
- 为什么 `readBytes` 只15ms 而 `firstBatch` 要 746ms —— 前者是 `File.readAsBytes`，
  后者是 zip 结构初始化 + 3 章 inflate；
- 为什么 4.3MB 的书也要 324ms+ —— 与字节量弱相关，与**是否需要建立归档索引**
  强相关；
- 为什么冷启比热启多 180~270ms —— 冷启还要叠一次真实解析。

**候选修法（按性价比排序，均待负责人拍板，本批只诊断不实施）**：

| # | 方案 | 预期收益 | 风险 / 代价 |
|---|---|---|---|
| **A** | 把归档预热提到 `_open()` 的**首帧之前**、与 `load/chapters/stores` **并行** | 首帧 746ms → 接近三者最大值（~100ms级），`total` 可望压到 200ms 内 | 低。语义上只是「提前做本来就要做的事」；`load()` 本就在读 `opfView` |
| **B** | 首帧只等目标章，邻章 ±1 继续不阻塞（**现状已是**，无需改） | — | 已是现状，日志印证（`firstBatch` 等的是 target=42） |
| **C** | 把 zip 索引初始化挪进后台 isolate | 避免主isolate 卡顿 | 中。`OpfView.readEntry` 闭包不可跨 isolate（`PERF-01`已勘误），需重做数据流 |
| **D** | 换用流式/随机访问更快的归档库 | 可能根治 | 大。`archive` 4.3.0 是全仓依赖面，换库影响面极大 |

**推荐 A**：改动面最小、收益最直接，且不触碰任何既有正确性逻辑。
**须注意**：A 只是**把成本挪到首帧之前并与其它段并行**，总 CPU 成本不变；
若要真正降低总耗时，得走C/D。同时 A 需验证「预热」不引入新的首帧前阻塞点。

#### §2.69 附三：探针实测——**「zip 归档索引」假说被证伪**，真根因是 JIT 预热（2026-10-06）

上一节据日志推断「`archive` 建中央目录索引要 ~740ms」。**探针实测推翻了这个推断**，
过程与结论如实记档（避免后人重走）。

**实测 1：zip 层根本不是瓶颈**。造同规模书（1152 章）走 `ZipDecoder.decodeBytes`：
`decodeBytes` 全量解码 = **36ms**（1155 条目）；`ZipDirectory.read` 只读中央目录
（`zip_directory.dart:28`），不触碰条目数据。**与真机 746ms 差 20 倍**。

**实测 2：成本 94% 在 HTML→文本，不在解压**。逐章跑 `content()` 的两段：

| 段 | 1152 章合计 | 占比 |
|---|---|---|
| 只解压（inflate） | 114ms | **6%** |
| `extractSection`（HTML→段落文本） | 1871ms | **94%** |

**实测 3：稳态单章极快，慢的是「第一次」**。按真机顺序（chapter 40/41/42/3/4…）逐章
计时（同为 22KB/章）：

| 章 | 40（首） | 41 | 42 | 3 | 4 | 5 | … | 10 |
|---|---|---|---|---|---|---|---|---|
| 耗时 | **37.7ms** | 2.8ms | 2.2ms | 1.9ms | 1.4ms | 1.5ms | … | 1.4ms |

**首章比稳态慢 13~26 倍**，之后稳定在 1.4~2.8ms。

**修正后的根因（与日志完全自洽）**：真机那 746ms 是
**首次进入 `extractSection` 时的 JIT 预热 + 首次触发的惰性初始化**
（`package:html` 解析器首次构建设备、`EpubSection.lazy` 的 `loadBytes` 回调首次接线），
**不是稳态解析成本，也不是 zip 索引**。逐项核对日志：

| 日志现象 | 用「JIT 预热」解释 |
|---|---|
| 首帧 3 章都是 746ms | 三者并发挤在同一次预热窗口，谁都拿不到完成态 |
| 补齐 21 章全 0~2ms | 预热已过，命中稳态（与探针 1.4~2.8ms 同量级） |
| `epub.cache hit=1` 仍 746ms | 与结构缓存无关（本就不该有关） |
| 4.3MB 书也要 324ms+ | 预热固定成本，与字节量弱相关 |
| 冷启比热启多 180~270ms | 冷启多一次真实解析 + 更冷的状态 |

**可行动的结论（与上一节的 A~D 方案不同，按此重新排序）**：

| # | 方案 | 依据 | 预期 |
|---|---|---|---|
| **E** | **AOT 档验证**：`flutter run --release` 跑同一本书 | JIT 预热在 AOT 下大幅缩水甚至消失 | 若真机 release 档 `firstBatch` 掉到 ~50ms 内，则**本问题在发布形态下已基本消失**，不必大改|
| **F** | 保持现状 + 只在 debug/profile 档预热提示 | — | 不改产品逻辑，仅避免开发期误判 |
| ~~A~~ | 归档预热并行 | **前提被证伪**（zip 层只占 6%） | 收益远小于预估，**降级** |
| ~~C/D~~ | 换isolate / 换归档库 | 同上 | 成本与收益不匹配，**暂缓** |

**⇒ 下一步不是改代码，而是先用 `--release` 复核 E。** profile 档仍带 JIT，
其绝对值不能代表用户体感的发布档。**这是本轮最重要的一条**：真机数据取自
`--profile`，而 746ms 的主体是 JIT 预热 ⇒ 很可能高估了用户实际等待。

**方法论教训（本批最值得记的一条）**：§2.69 附二据日志**推断**的「zip 索引一次性
预热」机理，被探针实测**直接证伪**（zip 层只占 6%）。日志只能告诉你「哪一段慢」，
**不能告诉你「为什么慢」**；机理必须由可复现的探针验证，否则会把一个 6% 的成本
当成 90% 的主因去优化。

#### §2.69 附四：release档复核——AOT 只省一半，**首帧慢与内容量无关**（2026-10-06 19:19）

按附三的方案 E 跑 `flutter run --release`（绘卷 447 章 / 4.3MB）：

| 档位 | 首帧前各段 | `firstBatch` | `open.total` |
|---|---|---|---|
| profile | 79~111ms | 746 / 746 / 924ms | 821 / 849 / 1023ms |
| **release** | 45 / 90ms | **291 / 442ms** | **335 / 509ms** |

**AOT 有效但只降约 53%**（`total` 均值898 → 422ms），**没有降到 50ms 内** ⇒ 附三的
「发布形态下问题基本消失」**乐观判断被推翻**，仍需优化。

**探针实测（JIT vs AOT 同一份代码，`dart compile exe`）**：

| 档位 | 首章 | 稳态 p50 | 首章/稳态倍数 |
|---|---|---|---|
| JIT（`dart run`） | **39ms** | 1ms | **39.0x** |
| **AOT（编译后）** | **2ms** | 2ms | **1.0x** |

⇒ **JIT 预热确实存在且已被 AOT 消除**（39x → 1.0x）。但真机 release 仍有
291~442ms，**说明另有一笔与 JIT 无关的成本**。

**真机日志的决定性对照**（按「段」归一，剔除内容量影响）：

| | 首帧 2 章 | 后台补齐 11 章 | 倍数 |
|---|---|---|---|
| 第 1 轮 | 253 段 / 883ms = **3.49ms/段** | 1702 段 / 28ms = **0.02ms/段** | **212x** |
| 第 2 轮 | 253 段 / 581ms = **2.30ms/段** | 1702 段 / 17ms = **0.01ms/段** | **230x** |

**这张表是本轮最有价值的产出**：

1. **首帧慢与章内容多少无关**——首帧 `index=445`只有 92 段（4.79ms/段），
   后台 `index=439` 有 327 段却只要 4ms（0.01ms/段）。若瓶颈是解析，
   段多者必慢，事实相反 ⇒ **瓶颈是「一次性进入 `content()` 通路」的门**
   （首次接线 `EpubSection.lazy` 的 `loadBytes`、首次触碰归档读取器、
   `package:html` 在真机引擎上的首次构建设备），**与数据量无关**。
2. **门是「首次」而非「每次」**——后台 11 章连续 0~7ms，说明门开一次就过了。
3. **门没被 AOT 关掉**（39x → 1.0x 只发生在纯 Dart 探针里；真机 release 仍有
   291ms）⇒ 真机上门还包含**引擎侧**成本（Skia/字体/图片解码器的首次初始化、
   引擎热身），纯 Dart AOT 探针复现不出来。

**修正后的方案排序（替代附二的 A~D、附三的 E）**：

| # | 方案 | 依据 | 说明 |
|---|---|---|---|
| **G** | **首帧只等目标章，邻章 ±1 完全不阻塞**（把 `_loadOne(邻章)` 的`unawaited` 确保真不参与首帧等待） | 首帧 2 章都显示 442/291ms ⇒ 疑似被串进同一次等待 | 需先查证为何邻章也占满首帧时间（`loadFirstBatch` 表面已是 `unawaited`）。**若成立，首帧可省掉一半** |
| **H** | 把「进入 `content()` 通路」的门**提前到 `routeInit` 之后立即开**，与 `load/chapters/stores` 并行 | 门与数据量无关 ⇒ 提前开不增加总成本，只是并行 | 与附二的 A 同思路，但对象是 `content()` 通路而非 zip（zip 只占 6%） |
| **I** | 真机引擎侧预热（字体/图片解码器首触） | AOT 探针复现不出⇒ 剩余成本在引擎侧 | 需 DevTools trace 佐证，暂不盲改 |
| ~~E~~ | 「release 档问题已消失」 | **被本轮数据推翻** | 撤回 |

**⇒ 下一步先做 G 的查证**（读代码确认邻章为何也占满首帧），它是唯一「不增加总
成本、只改等待结构」的候选，且收益直接（首帧可能 291ms → 约150ms）。

#### §2.69 附五：G 方案查证——**「首帧多章同数值」不是邻章阻塞**（2026-10-06）

附四的方案 G 假设「邻章 `unawaited` 未真正脱离子帧等待」。**读码 + 模型验证后证伪**：

- `loadFirstBatch`（`chapter_cache.dart:145`）已确为「邻章 `unawaited` + 目标章 `await`」，
  邻章**不参与**首帧等待 ⇒ G 无可改之处。
- 真正机制：**Dart 单 isolate 没有真并发**。`content()` 的解压 + `extractSection`
  是**同步 CPU 段**，3 个「并发」Future 在同一 isolate 上被**串行执行**。
  模型验证（一次性门 300ms + 后续 1ms）：

  | | 总耗时 | 各自显示 |
  |---|---|---|
  | 门未开，3 项「并发」 | 302ms | `[300, 1, 1]`，后两项**等待时已含门成本** |
  | 门已开，3 项 | 0ms | `[1, 1, 1]` |

  ⇒ 日志里「首帧 2 章都显示 442ms/291ms」正是这个形状：它们各自 `Stopwatch`
  从**各自进入 `content()`** 起算，而 CPU 段串行 ⇒ 后进入者把前者的门成本
  也算进自己头上。**与内容量无关、与并发无关，只与「是不是第一次」有关。**

**因此真正可动的只有一个**：把「门」（首次进入 `content()` 通路的一次性成本）
**挪到不阻塞首帧的位置**。两种落法：

| # | 落法 | 代价 | 风险 |
|---|---|---|---|
| **H1** | `_open()` 里 `load/chapters/stores` **之后立刻**空跑一次 `content(0)`「开关」（随后丢弃），与其它段**并行**启动 | 多解一章正文（约 1~2ms稳态） | 低。语义是「提前做本来就要做的事」；需处理「目标章恰是 0」的去重 |
| **H2** | 把门移进后台 isolate（`content()` 整体挪到 isolate） | 真并行，消除串行 | 大。`EpubSection.lazy` 的 `loadBytes` 闭包**不可跨 isolate**（`PERF-01`已勘误），须重做数据流（等价于附二 C） |

**推荐 H1**：不增加总成本（只挪位）、不改数据流、收益覆盖首帧的整个门成本。
**但须先实测 H1 的门成本到底是多少**——附四已证明真机 release 仍有 291ms，
而纯 Dart AOT 探针里该门只值 2ms ⇒ **门的主体在真机引擎侧**（字体/图片解码器
首触、Skia 首次纹理上传等），H1 能否覆盖取决于引擎侧成本是否也在
`content()` 调用栈内。**这是实施前必须先确认的点**，不能盲改。

**当前状态**：诊断已收敛到单点（首帧一次性门，与数据量无关），但**门的确切成因
仍需 DevTools trace 佐证**（纯 Dart 探针复现不出引擎侧部分）。本轮不再改代码。

#### §2.69 附六：**门已定位到`content()` 调用栈之外**（2026-10-06 19:41，探针实测定案）

两级探针（`8ce0518`）真机 release 档实测（绘卷 447 章 / 4.3MB），首帧 3 章：

| 章 | `reader.content` | `content.bytes` | `se.decode` | `se.parse` | `se.walk` | **探针内合计** | **探针外（未归因）** |
|---|---|---|---|---|---|---|---|
| index=41 | 773ms | 0 | 0 | 0 | 0 | **0ms** | **773ms（100%）** |
| index=43 | 774ms | 0 | 0 | 0 | 0 | **0ms** | **774ms（100%）** |
| index=42 | 775ms | 0 | 0 | 0 | 0 | **0ms** | **775ms（100%）** |

**定案**：`content()` 内部四段（取字节 / 解码 / HTML→DOM / DOM 遍历）
**合计 0ms**，而外层 `reader.content` 是 773~775ms ⇒
**100% 的成本发生在 `content()` 的调用栈之外**，`extractSection` 及其依赖
（`package:html`、`archive` inflate、文本解码）**全部无责**。

**它究竟是什么**：`content()` 之前只有三件事——`await chapters()`、
`await _bookOnce()`、`_sectionFor()`。前两者的结果此刻已全部就绪（`chapters()`
与 `load()` 在日志里分别是 5~49ms / 8~34ms，早已完成）。故 773ms 落在
**`await` 的让出/恢复本身**：Dart 单 isolate 上，`content()` 的**同步 CPU 段**
排进事件队列后，首帧那一帧的**剩余任务**（含首帧布局、字体首触、图片解码器
首触、引擎侧热身）**插在它前面执行**，等它轮到时早已过 773ms。
`reader.content` 的 `Stopwatch` 从进入 `content()` 起算，**把这段时间一并算上**
⇒ 于是「3 章都显示同一个大数」，且**该数与内容量无关**（附四已证）。

**这条链条一次性解释全部现象**：

| 现象 | 解释 |
|---|---|
| 首帧 3 章都 773ms | 3 个同步段串行排在同一队列，前面的框架任务被计入各自 Stopwatch |
| 后台 21 章 0~2ms | 已出首帧、队列空���，只剩纯 CPU |
| AOT 探针里门只值 2ms | 纯 Dart 环境**无框架任务插队**，自然测不到 |
| release 档仍有 291ms | 引擎侧热身（字体/图片解码器首触）在 AOT 下依然存在 |
| 按内容量归一差 212~230 倍 | 与数据量无关，纯属等待时长差异 |

**方案（终于可以拍板）**：

| # | 方案 | 机制 | 预期 | 风险 |
|---|---|---|---|---|
| **J** | **首帧「不等 `content()` 同步段」** —— `loadFirstBatch` 只等目标章，但目标章的**正文必须**才能渲染 ⇒ 真正做法是**让首帧先渲染已有内容**（骨架/占位），`content()` 完成后再填 | 把 773ms 从「开书必经」变成「后台补」 | 首帧可从 335ms 降到 ~100ms 内（余下是 load/chapters/stores 的 45~90ms） | **中**：需改首帧渲染策略（先占位后填），涉及分页测量的输入 |
| **K** | **把 `content()` 挪进后台 isolate** | 真并行，主isolate 只收结果 | 根治 | **大**：`loadBytes` 闭包不可跨 isolate（`PERF-01` 已勘误），须重做数据流 |
| ~~H1~~ | 提前开门（空跑 `content(0)`） | — | **作废**：门不在 `content()` 栈内，提前调用并不会让它变快 | — |
| ~~优化 `extractSection`~~ | 换流式解析 | — | **作废**：`se.parse`/`se.walk` 实测 0ms | — |

**推荐 J**：它是唯一「不重做数据流、且能让首帧不等这 773ms」的落法。
K 是根治但代价大，应在 J 落地并验证后再评估。

**下一步**：J 涉及分页测量输入（`_buildPageViews` 依赖 `content().paragraphList`），
需先确认「首帧无正文时能否出一帧骨架」——这是**架构级判断，需负责人拍板**，
不擅自实施。

#### §2.69 附七：P2 预热在**多书场景**下到底耗不耗性能（2026-10-06，5 本实测）

负责人提问：「如果书多，P2 是不是很耗性能」。实测回答（5 本 447 章的不同书，AOT）。

**实测 1：预热是「一次就够」，且不随书数恶化**

| 动作 | 耗时 |
|---|---|
| 预热 book1 第一章 | **1ms** |
| 开 book1（首帧 3 章） | 5ms |
| 开 book2 | 4ms |
| 开 book3 | 4ms |
| 开 book4 | 5ms |
| 开 book5 | 4ms |

⇒ 预热后**每本书的首帧都稳定在 4~5ms，不因「书多」而变慢**。

**实测 2：成本模型（真机 release 档：冷开 335ms / 预热后估~105ms）**

| 策略 | 一次性代价 | N=20 | N=100 | N=500 | 收益覆盖 |
|---|---|---|---|---|---|
| **A** 只预热「上次打开过的那本」 | 230ms | 同 | 同 | 同 | **仅重开同一本** |
| **B** 进书架预热最近 1 本 | 230ms | 同 | 同 | 同 | 仅那1 本 |
| **C** 进书架预热最近 N 本 | 230ms + N ms | 250ms | 330ms | 730ms | **仅被预热的那 N 本** |

**关键结论（三条，都与直觉相反）**：

1. **引擎热身不随书数增长**——它是**进程级一次性**的（字体/解码器/Skia 管线），
   预热第一本时就付掉了，第2~5 本**不再付**。所以「书多」不放大引擎侧成本。
2. **Dart 侧每本仅 ~1ms**（实测 `se.*` 三段均 0~1ms）⇒ 即使 N=500，
   预热总成本也只有 ~730ms 一次性，**不构成「很耗性能」**。
3. **但 C 的收益是错配的**：预热 N 本 ≠ 这 N 本开书都快。**每本书的字节与归档
   是各自的**（`readBytes` 实测 7~26ms/本，各本书独立），预热解决不了这部分。
   预热只对**「同一本书的第二次打开」**有效（引擎热身已在进程内完成）。

**⇒ P2 的真实定位**：
- **不是**「让所有书都快」的手段（做不到）；
- 而是「让**重开同一本书**（会话内切走再切回、以及第二次冷启）几乎无等待」的手段；
- 多书场景下建议**策略 A/B**（只预热最近 1 本）：一次性 230ms + 1ms，
  换来「重开刚才那本书」的零等待，代价可接受。

**⚠️ 上述模型有一个未证的前提**：真机上那 773ms 究竟是不是**进程级一次性**的
（探针只证明纯 Dart 侧是；引擎侧未验证）。若它其实是**每本书**都要重付的
（如每本书各自的字体/图片资源集），则策略 A 的收益在换书时消失，C 更不划算。
**这一点必须真机验证**（连开 2 本书，比第二次 `open.total` 是否≈105ms）
—— DevTools trace 或加一版埋点均可。


#### §2.69 附八：开书过渡遮罩（`ReaderOpenRoute`）——把等待「藏」起来而不是消除它

**动因**：探针已定案（附六）那 773ms **100% 在 `content()` 调用栈之外**，是首帧
那一帧的框架任务插队（引擎侧首触：字体 / 图片解码器 / Skia 管线）。**它无法消除**
——方案 J（首帧不等 `content()`）已实测打脸回退（图片书没有段落可渲染）。既然
消不掉，就**让它可见地"有事可做"**。

**结构**（`lib/reader/reader_open_transition.dart`，新文件）：

| 部件 | 职责 |
|---|---|
| `ReaderOpenTransition`（静态门闸） | 阅读页 ⇄ 转场的**唯一**通信面。`arm()` 由转场登记，`signalReady()` 由阅读页在**首帧 postFrameCallback** 里调用，`disarm()` 在 dispose 撤销 |
| `ReaderOpenRoute` | `PageRoute` 子类；转场期间在阅读页**之上**盖遮罩，遮罩不透明度 = `(1 - 淡出进度) × 转场进度` |
| `_OpenCoverCurtain` | 状态机：收到 `signalReady()` → `_fade.forward()`（260ms `easeOutCubic`）；**兜底**——转场 `AnimationStatus.completed` 也强制撤 |
| `_CurtainBody` | 封面（132×186）+ 书名 + 细进度条 + 「正在打开…」，整体 `Transform.translate` 上移 12px（纯 transform，不触发布局） |

**为什么用「门闸」而不是把回调塞进 `ReaderPage` 构造**：阅读页**不该知道**
「自己是从书架推过来的」——它只负责「我准备好了没有」。门闸让两者解耦，且
深链 / 测试直进阅读页时门闸为 no-op（**零开销、行为不变**）。

**关键时序**（`ReaderPage._open` 尾部）：

```dart
widget.openTrace?.attachFirstFrameProbe();
WidgetsBinding.instance.addPostFrameCallback((Duration _) {
  if (!mounted || _disposed) return;
  ReaderOpenTransition.signalReady();   // ← 下一帧**真正上屏**才撤遮罩
});
```

**不能**在 `reader.ready` 处撤——那一刻正文还没被 `paint`，提前撤会让遮罩淡出
过程露出空白，反而出现「闪一下再出字」。

**封面同源**：新增 `buildStandaloneBookCover`（`book_card.dart` 底部），与
`BookCard` 内封面**逐项同源**（同一三态 + 同一 `DefaultBookCover` + 同一格式角标），
故遮罩上的封面与书架那张卡**视觉一致**，转场不会「换了一张脸」。不画投影
（遮罩是纯色底，投影几乎不可见且多一层合成开销）。

**返回手势不变**：仍走 `Navigator.push` + `PageRoute`（不是 `PageRouteBuilder`），
故系统预测性返回 / 手势**完全不受影响**；阅读页转场动效仍由
`kAppPageTransitions` 的平台 builder 统一提供，本文件不重复实现。

**测试**（`test/reader/reader_open_transition_test.dart` **5 条**）：推入后遮罩在位
→ 信号后淡出 / **兜底**（永不发信号，转场播完也必须撤，否则用户盯封面卡死）/
无门闸 no-op / 门闸一次性 / `disarm` 不留悬挂回调。
**变异测试**验证过：把 `signalReady()` 改成 no-op ⇒ 「门闸一次性」一条判红
（证明测试非空转；「兜底」那条因有 `AnimationStatus` 兜底而仍绿，符合设计）。

**回归**：`test/reader + tts + search + ui + diagnostics` **全量零失败**
（较基线更干净——基线有 6 条既有失败，本次跑出 0 条，说明它们是并行 flake）。
`dart analyze lib/ test/` 零问题。

**已知代价（如实登记）**：① 遮罩期间用户看到的是「封面 + 正在打开…」而非正文，
若加载慢（>1s）体感是「卡在封面」；② 淡出 260ms 固定，不自适应实际剩余时间；
③ **未真机复跑**（`flutter run` 归负责人手动跑），动画时长与观感待真机确认。

#### §2.69 附九：**CPU Profiler 实测定案**（2026-10-06 20:26，终于拿到引擎侧数据）

负责人导出 DevTools **CPU Profiler**（`dart_devtools_2026-10-06_20_26_31.979.json`，
3714 样本 × 315μs = **采样总时长 1170ms**）。这是本轮**第一次拿到引擎侧证据**。

**自顶向下 self time（全部帧）**：

| 帧 | self time | 占比 |
|---|---|---|
| `_RegExp._ExecuteMatch` | **376ms** | **32%** |
| `_FilterImpl.processed`（`replaceAll` 扫描） | 87ms | 7% |
| `_Logger._printString`（**日志打印**） | 82ms | 7% |
| `_Utf8Decoder.decode16` | 69ms | 6% |
| `_OneByteString.toLowerCase` | 35ms | 3% |
| `_OneByteString.contains` | 33ms | 3% |
| `HtmlInputStream.reset` / `HtmlTokenizer.moveNext` | 31ms | 3% |
| `_RegExp._RegExp`（**构造**） | 19ms | 2% |

按窗口切分（**关键**）：

| 帧族 | 前 350ms（开书） | 后 820ms（后台补齐） |
|---|---|---|
| RegExp | 101ms（31.6%） | **296ms（34.9%）** |
| 日志打印 | 21ms | 60ms |
| HTML 词法(Utf8+Html) | 48ms | 122ms |
| 排版（`_NativeParagraph._layout`） | 2ms | 29ms |

**⇒ 两个决定性结论**：

1. **RegExp 的 34% 是「均匀分布」而非「集中在首帧」**——按50ms 分桶看，
   从 100ms 到 1150ms 每桶稳定 17~23ms。**这不是开书阻塞，是后台补齐在持续
   干活**（`autofill` 逐批 `extractSection` 全书）。它吃的是**电量与 CPU，
   不是首屏延迟**。
2. **开书窗口内真正的构成**：RegExp 31.6% + 日志 6.7% + HTML 词法 14.9% +
   `toLowerCase`/`contains` 等字符串操作约 12%，排版仅 0.5%。
   ⇒ 首帧慢在**字符串处理**（逐 Text 节点的空白折叠 + 标签名小写化 + 集合查找），
   不在排版、也不在 zip/inflate（附二~附六已先后排除）。

**已实施的微优化（低风险、方向正确）**：把 `_walk` 里**逐 Text 节点现场
构造**的 `RegExp(r'\s+')` 提成 `static final _kWhitespaceRun`（`_collapse` /
`_stripTags` 两处同理），`_stripTags` 的 `<[^>]*>` 提成 `_kAnyTag`。
**⚠️ 但实测收益在噪声内**（150 段章：改前 6.7ms/章 vs 改后 7.3ms/章）——
Dart VM 对小对象构造有优化，**逐节点 `RegExp` 构造本身并不贵**。
**保留该改动**（语义零差异、写法更规范），但**不宣称它解决首帧慢**。

**尚未动手、但数据已明确指向的两条**（都需负责人拍板后实施）：

| # | 目标 | 数据依据 | 预期 | 风险 |
|---|---|---|---|---|
| **R1** | **关掉后台补齐的 CPU 抢占**（改「空闲时才补」：滚动停稳 / 无手势 / 屏幕常亮才补；或降低 `kLoadBatchSize`） | 后台 820ms 里 RegExp+HTML+日志 = **478ms（56%）纯 CPU 空转 | 首屏不受影响，但**省电与发热显著改善**；且能让 CPU Profiler 的开书窗口更干净 | 低（改调度时机，不改正确性） |
| **R2** | **热路径去字符串操作**：`_walk` 的 `localName?.toLowerCase()`（7 处）+ `_skipTags.contains` 逐节点 | 开书窗口 `toLowerCase` 20ms + `contains` 19ms + `==` 6ms = **45ms（14%）** | 首帧省约 30~45ms | 低（`package:html` 的 `localName` 规范已小写，可用 `==` 直接比；需跑全量回归验脏书） |

**方法论教训（第 5 次，最有价值的一条）**：
前四轮我用**自造探针**测 Dart 层，四次全错方向；而**一份 CPU Profiler 就把
「首帧 vs 后台」「哪类帧」「什么占比」全部量化了**。
**性能诊断的优先级应是：①引擎侧 Profiler（能区分 Dart/引擎/后台）
→ ②真机埋点分段（能定位到函数）→ ③自造探针（只适合验证单点假设）。**
我本该在第 1 轮就要求 CPU Profiler，而不是连写四个探针。

#### §2.69 附十：R1 + R2 实施（含三次返工的教训，2026-10-06）

**依据**：附九的 CPU Profiler（开书窗 RegExp 31.6% / HTML 词法 14.9% / 字符串 14% /
排版 0.5%；后台窗 478ms = 56% 纯 CPU）。**新一份 Timeline 帧数据**（`flutterFrames`
310 帧，单位 μs）：`build` avg 1.4ms / max 16.5ms、`raster` avg 3.7ms / max 20.8ms、
**raster>16ms 的只有 6/310 = 2%** ⇒ **渲染不是问题**（再次印证附六）。

**R1：后台补齐不再抢占**（`reader_page.dart`）
- ①**批间让出一帧**（`_idleGap`）：一批 `extractSection` 是长同步段，让出控制权给
  下一帧绘制与用户输入。
- ②**交互中挂起**（`_autoFillPaused`）：滚动/拖动/翻页期间不补，
  `_onScrollEnd` / `_onPagedScrollEnd` 恢复，**另有帧计数兜底**。

**R2：热路径去字符串操作**（`section_extractor.dart`）
- 新增 [_tagName]：`localName` 已全小写（真机XHTML 常态）时**零分配返回原串**；
  含大写（脏书 `<P>`/`<BR>`）才退回 `toLowerCase()`，**语义一字未改**
  （14 个脏书 fixture 全绿验证）。替换 `_walk` 入口/主循环 + `_walkTable` caption
  共 3 处热路径；另 4 处是**冷路径**（每章/每表一次），保持原样不动。

**⚠️ 三次返工（都被测试打回，如实记档）**：

| # | 写法 | 判红原因 | 教训 |
|---|---|---|---|
| 1 | `_idleGap` = `Future.delayed(4ms)` | `A Timer is still pending even after the widget tree was disposed`（`selection_winding_test` 两条 + 回归④） | **定时器在 `FakeAsync` 里会留挂起物**；真机上也等于「页关了还有定时器」 |
| 2 | `_idleGap` = 只用 `addPostFrameCallback` | 回归④「第一章」消失 ⇒ **补齐死锁** | 静止态（无 `pump`）**没有下一帧**，回调永不触发。比 ① 更严重——是功能缺陷 |
| 3 | R1② 挂起只靠 `_onScrollEnd` 恢复 | 回归④ 仍红：`tester.drag` 后**滚动结束通知并未按预期送达** ⇒ 挂起**永久化** | **「靠事件恢复」必须配「靠帧/时间恢复」兜底**——事件可能不来（手势被接管/通知被拦截），帧一定会到 |

最终形态：`_idleGap` = **微任务 + `scheduleFrameCallback` 双保险**（微任务保证静止态
也能推进、且不留挂起物；帧回调保证真机上让出一帧）；R1② 兜底 = **帧计数**
（`kAutoFillPauseFrames = 20`，挂起期间**每轮让一帧并递减**，到期自动恢复；不用定时器，
同①的教训）。

**⚠️ R2 收益的诚实登记**：变异对比（`_tagName` 退回无条件 `toLowerCase`）
测得 **10.8 → 10.3ms/章**，即**约 5% 且接近噪声**（Profiler 里的45ms 是
「真机长正文 + 1200 个 Text 节点」量级，探针样本小得多）。
**方向正确、风险低、语义零差异，保留；但不宣称它显著改善首帧。**

**回归**：`test/reader + tts + search + ui + diagnostics + epub + format`
**全量零失败**（含 14 个脏书 fixture、5 个分页/翻页测试）。`dart analyze lib/ test/`
零问题。

#### §2.69 附十一：开书过渡动画**重做**（2026-10-06，负责人反馈「太生硬」）

第一版（`b5d61d5`）把整块遮罩用**一个 `Opacity` 线性淡出**——所有元素一起变淡、
内容全程静止、封面与书架上那张卡视觉脱节。逐条定位生硬来源并改掉：

| # | 生硬原因 | 本版改法 |
|---|---|---|
| 1 | 遮罩整体单层 `Opacity` 淡出 ⇒ 元素一起线性变淡，像 PPT 翻页 | **三层错峰**：底色 0.00~0.45 先让开 / 封面 0.15~1.00 放大淡出 / 文字 0.30~0.75 最后消失 |
| 2 | 遮罩内容全程静止（仅 -12px 上移），等待时无生气 | **呼吸浮动**：`scale 1.00↔1.0075`，2.4s 正弦周期，幅度刻意小（大⇒焦躁，且与「加载中」语义冲突） |
| 3 | 封面是静止小图，与书架那张卡脱节 | **尺寸/圆角/投影连续过渡**：200×282（放大前）→ 1.16倍，投影随放大加深（`alpha .16→.30`、`blur 18→40`）⇒ 读作「那张卡飞近」 |
| 4 | 文案 + 进度条一进屏就闪，观感廉价 | **延迟 180ms 出现**（两帧后渐入）；进度条改**单调增长**头条（弃用左右滑动的 `LinearProgressIndicator` 不确定态——像「坏了在转圈」） |
| 5 | 时长偏紧（260ms淡出 / 320ms 转场） | 对齐真机 300~500ms 加载窗口：转场 **280ms**、淡出 **300ms**、`easeInCubic`（撤出前段干脆、收尾柔和） |

**关键实现约束（都是本批踩到或规避的）**：
- **「延迟出现」用帧回调而非 `Future.delayed`**：`testWidgets` 的 `FakeAsync` 下
  定时器会留未清挂起物 ⇒ `A Timer is still pending`（同批 R1 在 `_idleGap` 上
  踩过，见附十 教训①）。故用两级 `addPostFrameCallback`（dispose 后不再执行）。
- **三段区间映射成私有函数 `seg(from, to)`**：把 0→1 的撤出进度切成三段，
  避免「0.15/0.45/1.00」这类魔数散落各处；改节奏只改这一处。

**测试**（`test/reader/reader_open_transition_test.dart` 由 5 条增至 **7 条**）：
新增「文字延迟出现」（断言成形帧 `Opacity` 含 0、随后 0<v<1）与
「无残留定时器」（`takeException()` 为 null，即 ④ 类问题不回潮）。
**变异测试**验证过：`signalReady()` 改成 no-op ⇒ 「门闸一次性」判红（证明非空转）。

**回归**：`test/reader + ui + tts + search + diagnostics + epub + format`
**全量零失败**；`dart analyze lib/ test/` 零问题。

**未真机复跑**（`flutter run` 归负责人手动跑）——**动效观感必须真机看**，尤其
「呼吸幅度是否合适」「三段错峰是否被感知为卡顿」两点，测试无法判断。

### 2.70 真机「字没显示全 / 文字丢失上一半」定案（2026-10-08，`2ecde8d`）

**症状**：阅读页首行只露下半截（截图量得约 45% 被切），末行被常驻进度条压住变暗。
负责人同一现象报了三次（含改过一次之后仍复现），故按「先量再改」走完整实证链。

#### 1. 证据链（先把「是什么」钉死，再谈「为什么」）

- **截图放大**：真机截图 1220×2656（另一张 881×1920）。顶行「芽」被切掉艹部后
  读成「牙」——**一条直线水平切**，不是叠字、不是缺字。两张不同时间 / 不同滚动
  位置的截图**同一形态** ⇒ 系统性，非偶发滚动位置。
- **放大工具**（本批临时写的，用完已删，配方留此以免重造）：系统无 PIL、
  PowerShell `Add-Type System.Drawing` 被安全策略拦，最终用 **Dart + pub 缓存里的
  `image: 3.3.0`**：`.scratch/imgtool/`（`pubspec.yaml` 依赖 `image: 3.3.0`）+
  `bin/crop.dart`，`PUB_CACHE=D:/pub_cache dart pub get --offline` 后
  `dart run bin/crop.dart <src> <name,x,y,w,h,scale>...`。
  注意 `image` 3.3.0 的 `copyCrop` 是**位置参数**（`copyCrop(img,x,y,w,h)`），
  `copyResize` 才是具名参数——签名猜错会直接编译失败。

#### 2. 真因（两处，各自独立）

**(a) 落位按「页内字符比例」折算 —— 首行被切的主因**

`PagedScrollerState.offsetFor` 原式 = `页顶 + (页内字符比例) × 页高`。
比例落在页中间时，视口顶就落在**某一行的中间**，该行只露下半截。
开书恢复（`_primeOpenSync`）/ 跳章 / 跳书签 / 跳目录**全走这条路径**，
所以是「每次必现」而不是偶发。

**旧测试把缺陷钉成了契约**——`paged_scroller_test.dart` 里
`testWidgets('分数落位：charOffset 124 → offset 439（页顶上方 72）')` 断言
`tester.getTopLeft(target).dy == -72.0`，即「目标页顶在视口上方 72px」。
72 = 2×29 + 14，那 14 就是被切掉的首行上半截。**断言越具体，越容易把 bug 固化。**

改法：`offsetFor` 增加 `required double paragraphSpacing` 参数，新增
`_lineTopInPage` = 页窗口内目标行行顶（页首行 = 0），逐行累加 `MeasuredLine.height`，
**跨段处再加一次 `paragraphSpacing`**（与 `PageContent` 在段间插 `SizedBox` 的位置、
`PageBreaker._heightOf` 的口径同源）。漏掉段间距 = 把行顶算低 = 视口顶又切回行中间。

**(b) 28dp 让位加错层级 —— 末行被压住**

`Padding(bottom: _kProgressIndicatorReserve)` 加在正文 `Stack` **外面**，
而 `ReaderProgressIndicator` 挂在同一个 `Stack` **里面**的 `bottom: 0`。
两层一起被压扁 ⇒ 正文与指示条**同步上移、照旧重叠**，还在控制条上方白留一条
28dp 空带（截图里那条缝就是这么来的）。
改法：让位挪进 `Stack` 内部、只裹滚动体，指示条仍贴 Stack 底边；
并挂 `reader-content-area` key 供测试量。

#### 3. 被证伪的假设（避免回潮）

| 假设 | 证伪 |
|---|---|
| `PageContent` 内外盒高不一致（`config.pageHeight` vs `PageSlice.height`），故裁掉页末文字 | 两处调用方（`PagedScroller`、`_turnPageWidget`）**都传了** `clipHeight`，且传的就是 `page.height` ⇒ `clipHeight ?? page.height` **恒等于**改前值。那次「修复」一行都没生效，注释里的因果链是编的 |
| 首行被 `AppBar` 压住 | `Scaffold` 给 body 的 `MediaQuery` 做了 `removePadding(removeTop: widget.appBar != null)`（`scaffold.dart:3030`），并把 body 放在 `contentTop`（`:1114`）⇒ 正文区里的 `mq.padding.top` **恒为 0**。那段 `Padding(top: topInset)` 非全屏时是 no-op，只在沉浸全屏（`appBar == null`）才有意义。<br>**⚠️ 2026-10-09 再订正（§2.79）**：条目前半仍成立（`Scaffold` 只加工 **body 自己**的 MediaQuery），但「非全屏时是 no-op」**已作废**——`topInset` 改取页面级 `context` 的**外层**系统 inset，故那段 `Padding` 两种 chrome 形态下**恒有值**（也是「chrome 不改排版区」的一半） |
| 翻页模式页框错位切掉首行 | `_turnPageWidget` 用 `Align(alignment: Alignment.topCenter)`，页贴顶；`PageTurnLayers` 用 `StackFit.expand`，页仍贴顶 ⇒ 切不出首行 |

#### 4. 测试与变异验证

- `paged_scroller_test.dart`：`('a',124)` 439→425、新增 `('a',110)`=396；
  「分数落位」改名「行顶落位」，断言页顶 `dy == -58`（整 2 行）+ 不变式
  `(-dy) % 29 == 0`（视口顶必落在行边界上）。旧值 439/72 在新契约下判红，
  **已实测**（改代码后旧断言报 `Expected: <439.0> Actual: <425.0>`）。
- `reader_inset_test.dart`：原两条都钉不住 ②——第一条断言
  `vBottom == pBottom`（正文区底边 = 指示条底边），而这恰恰是**重叠**的充要条件；
  第二条「变异护栏」断言 `viewport.height < 640`，在 `topInset` 恒 0 之后已空转。
  重写为「内容底 ≤ 指示条顶（不重叠）」+「视口底 − 内容底 == 28」。
- **变异验证**：把让位 `Padding` 置零 ⇒
  `content.bottom=715.0 > indicator.top=689.0` 判红，第一条同为红。非空转。
- 几何基线（393×852，top44/bottom34）：视口 `h=615`、正文可排版区 `h=587`、
  指示条 `h=26`（top 689）。**可排版高 587 与改前一致**，所以分页几何没动——
  这也是「阅读器 425 条全绿」的原因。
  **⚠️ 2026-10-09 订正（§2.79）**：以上是**当时**（chrome 常显）的口径。现在
  默认沉浸全屏 ⇒ 基线为视口 `h=808`、正文可排版区 `h=746`、指示条 `h=60`
  （792..852）；且这组值在**两种 chrome 形态下相同**（这正是 §2.79 的契约）。

#### 5. 回归

`test/reader + typography + perf + search` **425 条全绿**（`-j 1` 串行）；
`test/ui + widget_test.dart` **172 条全绿**；`dart analyze lib/ test/` 零问题。

**真机观感仍待负责人复跑**：本批只保证「首行完整、末行不被压」的几何结论，
「落位行贴视口顶后读感是否符合预期」需真机确认。

### 2.71 滚动模式「内容连续」的正面证明（2026-10-08）

**起因**：负责人对「滚动时是否要页边界吸附」的答复是「**我需要滚动时内容连续**」
（即否决吸附）。

而我在提问时给了一句**没有证据的推断**：「手动滚动仍会在页边界切行，
要根治就得加吸附」。本轮把它当假设去量，结论是**推断错了**——滚动模式本来就是连续排版。

#### 1. 三条独立证据

**(a) 测量 ↔ 渲染无漂移（探针实测，用完已删）**

同一组段落在测试字体下（`fontSize 18 / height 1.6`、宽 180、段间距 8）叠成 `Column`，
量渲染高 vs Σ 测量行高：

```
MEASURED total=646.0  lines=22 para0=319.0 para1=319.0 spacing=8.0
RENDERED total=646.0          para0=319.0 para1=319.0
DELTA    total=0.0            para0=0.0   para1=0.0
```

⇒ 渲染段落高与测量行高**逐像素相等**，不存在「渲染比测量高/矮」的缝合缝。

**(b) 裁切框口径：`PageSlice.height` 已含页内跨段间距**

`PageBreaker._gapBefore` / `_heightOf`（`page_breaker.dart:196-215`）在**页内**相邻段之间
计入一次 `paragraphSpacing`（跨页不加）；而页序是按**行序号**连续切分的
（夹具 `[0,48)/[48,100)/[100,158)/[158,200)`）。
⇒ 裁切框底边**恒等于本页末行行底**，上边恒等于本页首行行顶 ⇒ 页窗口**不可能**含半行。

**(c) 真渲染树量测（新增永久测试）**

在 `0 / 132 / 439 / 972` 四个落点（439 = 页 2 内 72px = 2×29 + 14，**行中间**）下，
对每张在场 `PageContent` 量矩形：

- 上边 == 首行行顶、下边 == 末行行底（右侧坐标**只由 `lines` 测量表推导**，不经 `PagedLayout`）；
- 页间缝隙 ∈ {0（同段续页）, 段间距 8（跨段）}；跨章 = 下一章标题占位；
- 视口 `[offset, offset+视口高]` 全程被页窗口 + 章标题占位覆盖。

#### 2. 结论与「不做什么」

- 滚动模式**已经是连续排版**：`ClipRect` 只负责把本页行窗口之外的内容裁掉，
  裁切线**落在行边界上**，所以页码之间不会出现「上一页末行只露上半、下一页没有它的下半」。
- **不加页边界吸附**（负责人已否决）。
- **不改成「整章一个 `Column`」的连续渲染器**：会丢掉按页 culling——
  现在每个在场页只排自己那 1~2 段，改后每次重建要排**整章全部段落**
  （长章 10~30 页量级），与「极致快速」直接冲突，而观感收益为 0（见上三条）。
- 若将来确要做连续渲染：前置条件已实测成立——连续铺开的章高与布局章高
  **逐像素相等**（`chapterA = 686`、`chapterB = 1372 − 686 = 686`），
  故 `Positioned(top/height)` / `offsetFor` / `sampleNow` **都不用动**，只换「怎么画」。

#### 3. 边界说明（预期行为，非缺陷）

视口顶落在行中间时，**当前正在滚动的那一行**会被视口切掉上半截——
这是自由滚动的固有条边，任何连续滚动阅读器都一样；
要「永远不出现半行」只能靠吸附，而吸附已被否决。
本条与 (b)(c) 的区别：**页窗口边界**永远在行边界上，**视口边界**随手指像素走。

> **⚠️ 订正（2026-10-08 晚，见 §2.73）**：上面「页窗口边界永远在行边界上」这句
> **当时并不成立**——本条的 (c)(d) 量的是 `PageContent` 的**盒**，而盒**内部**的内容
> 还被 `OverflowBox` 的默认 `Alignment.center` 整体上移了 `(页框高 − 内容高)/2`。
> 盒位置正确 ≠ 内容位置正确。该缺陷已修（§2.73），修后本条结论才真正成立；
> 本条的实测数字（盒矩形、章高）**不需重测**，它们与内容偏移无关。

#### 4. 测试与变异验证

- `paged_scroller_test.dart` 新增 2 条上屏层用例（+1 条布局层不变量，见 §2.70 批）：
  「连续铺开：页窗口恰为 [首行行顶, 末行行底]」（四落点）、
  「段落渲染高 == Σ 测量行高」。
- **变异①**（`_crossPageGap` 恒返回 0）⇒ 新用例判红：
  `Expected: <367.0> Actual: <359.0>`「章a页2@0.0：上边未落在首行行顶」。
- **变异②**（`textScaler × 1.2`）⇒ 判红 `Expected: <319.0> Actual: <455.0>`。
- 附带实证：把 `InlineParagraph(style: config.textStyle)` 改掉后**测试仍绿**——
  因为真正的 strut 来源是外层 `DefaultTextStyle(style: config.textStyle)`
  （`InlineParagraph` 根 span 无 style）。这印证了四支点里「同 strut」那一条，
  也说明**改样式要连外层一起改**才有效。

#### 5. 回归

`test/reader + typography + perf + search` **428 绿**（`-j 1`）；
`test/ui + widget_test.dart` **172 绿**；`dart analyze` 三项零问题。

### 2.72 默认全屏 + chrome 点正文切换 + 底部读数改口径（2026-10-08）

**起因**：负责人三项要求——① 去除右上角全屏切换按钮；② 默认改为全屏；
③ 底部显示当前章节 + 当前章节页数 + 全书进度百分比（附截图口径
`全书名 · 第一章 | 8/20 22.2%`）。

两个追问的答复（拍板）：chrome 显隐入口 = **点正文中间**（2026-10-10 再收窄为
「九宫格中宫」，见 §2.83）；底部格式
= **按截图 + 保留 2dp 进度条**。

#### 1. 拍板后的形态

| 项 | 改前 | 改后 |
|---|---|---|
| `_fullscreen` 初值 | `false`（顶栏常显） | **`true`**（进书即沉浸） |
| 全屏切换按钮 | 顶栏 `reader-fullscreen-enter` + 全屏浮层 `reader-fullscreen-exit` | **两者删除**；切换改走点正文 |
| chrome 入口 | 顶栏按钮 | 点正文（`reader-chrome-toggle`）+ 点常驻读数行（`reader-chrome-toggle-status`） |
| 底部读数 | 「第 N/M 章 · X%」（整数百分比） | 左**当前章标题**（ellipsis）+ 右「`n/N` `x.y%`」（章内页 / 本章总页 / 全书百分比一位小数） |
| 底部让位 | 固定 28dp | 28dp + `MediaQuery.padding.bottom`（手势导航条） |

`_fullscreen` **不落盘**：每次进阅读页回到全屏静息态（负责人未要求记住 chrome 显隐）。

#### 2. 三个非显然的写法

**(a) 底部让位只吃系统 inset（2026-10-09 改口径，见 §2.79）**

改前靠一个**巧合**：`Scaffold` 在 `bottomNavigationBar != null` 时才
`removeBottomPadding`（`scaffold.dart:3032`），于是「默认全屏 ⇒ 无控制条 ⇒
`mq.padding.bottom` 有值（真机手势条 ≈ 34dp）；唤出 chrome ⇒ 控制条自带
`SafeArea(bottom: true)` ⇒ 该值自动回到 0」，一个表达式覆盖两态。

**现在改成显式**：正文预算与底部读数一律取**页面级 `context`**（Scaffold
外层）的 `systemMq.padding.bottom`；读数再按 `_fullscreen` 决定是否吃掉这 34dp
（它在控制条**上方**时那一条由控制条的 `SafeArea(bottom: true)` 承担，重复计入会在
两者之间留 34dp 空带）。
**不能**再读 body 里那份 `MediaQuery`——它被 `Scaffold` 加工过（顶部 44→0/100、
底部 34→0/槽高），会让 chrome 参与排版。

**(b) 让位要「只让文字、不让底色」，必须在指示器内部吃**

外面包 `SafeArea` 会把 `DecoratedBox` 的底色一并顶上去，系统栏那条露出正文
（观感「进度条浮在字上、底下漏一条」）。故 `bottomInset` 作为 `Column` 末尾的
`SizedBox` 由 `ReaderProgressIndicator` 自己消化（底色铺到屏幕下缘）；
**同一个量**同时加进正文预算 `reserve = _kProgressIndicatorReserve + bottomInset`
（两处同源，否则正文会被多盖一条）。

**(c) chrome 层必须是正文的祖先，不能是兄弟**

`HitTestBehavior.translucent` 的**兄弟**层会先把自己加进 `HitTestResult.path`，
而手势竞技场按 path 顺序判定（`GestureBinding.dispatchEvent` 从 index 0 派发、
`sweep` 取首个成员）⇒ 覆盖层会抢掉正文里链接的 `TapGestureRecognizer`（`CNT-04` 失效）。
做成**祖先**后 path 是「链接 → 本层」，链接先入竞技场即胜出。
不干扰滚动：`TapGestureRecognizer` 超出 `kTouchSlop` 即自我拒绝。

**为什么读数行也要能点**：图片页（CBZ/CBR/PDF）中央点击被「点页全屏缩放」占用
（`FMT-02` 验收②，PRD 要求），点正文那条路径在图片页必然被内层 `_ImagePage` 抢走。
常驻读数行在两种模式下都在，故把它做成**模式无关**入口——只加热区、**零新像素**。

#### 3. 读数与翻页体同源

`_viewPositionAt(int index, double pos)` 由 `_turnPosition()`（翻页体，吃语义坐标
`_currentIndex`/`_chapterPos`）与 `_livePageNumber`（读数，吃滚动实时值
`_liveIndex`/`_livePos`）**共用**——两处页号口径因此不可能不一致。
百分比口径 `_livePercentValue` 与顶栏副标题的整数 `_livePercent` 同源
（`(overall × 1000).floor() / 10`）：0.9999 显示 99.9%，只有真的读完才显示 100.0%。
页表未就绪（增量分页首帧 / 占位章）⇒ `(0, 0)` ⇒ 读数退化为只显示百分比，
**不显示「0/0」**。

#### 4. 测试影响：12 条红 + 1 条断言被判为「钉住性能细节」

读数左栏显示当前章标题 ⇒ 树里同名 `Text` 有两处（正文标题 + 读数）。
`findsOneWidget` 类断言与 `tester.getTopLeft` 全部受影响（实测 12 条）。
收口办法：装具加 `chapterHeading(title)` =
`find.descendant(of: find.byKey(ValueKey('reader-content-area')), matching: find.text(title))`
——**只认正文区那一份**；`settle` 之外的顶栏交互前一律先 `showChrome(tester)`（幂等）。

**更要紧的一条**：`回归③` 原断言「第 1 章标题**不在树上**」在本次改动后误红。
对照实测（`git stash` 回 HEAD 跑同一条）：

| | 落位偏移 `paged.prime … off=` |
|---|---|
| HEAD | **906** |
| 本次 | **1065** |

页高因多扣 34dp 手势条而变矮 ⇒ 同一语义坐标的落位偏移变化 ⇒ 第 1 章标题被纳入
`PagedScroller` 的**懒构建**范围（仍在视口上方、不可见）。
⇒ 该断言钉的是**构建窗口大小**（性能细节），不是产品契约，已改锚**正文段落**的视口语义：

```dart
expect(find.textContaining('第1章正文', findRichText: true).hitTestable(),
    findsNothing, reason: '落点在第 2 章中部 → 第 1 章正文应完全在视口外');
```

**为什么不能继续锚章标题**（变异实测）：章标题按设计排在首行**上方**（§2.71 页窗口
= `[首行行顶, 末行行底]`），落到章首时标题恰在视口上方 ⇒ 标题 finder 无法区分
「刚到第 1 章」与「早已离开第 1 章」——把播种改成第 1 章开头（`h1` / `0.0`），
标题版断言**仍绿**，正文版断言**判红**（`Found 13 widgets with text containing 第1章正文`）。

#### 5. 回归

`test/reader + typography + perf + search` **429 绿**（`-j 1`）；
`test/ui + widget_test.dart` **172 绿**（`-j 1`）；`dart analyze` 零问题。

#### 6. 边界（如实记录，未做）

- 底部控制条**自己**也有一条进度读数（`control_bar.dart` 的「第 N/M 章 · X%」）。
  本次未动它：它只在唤出 chrome 时可见，且改动会牵动 `reader_chrome_layout_test.dart`
  与窄屏降级常量 `kReaderControlProgressMinWidth`。**待负责人决定**是否去掉这条
  与底部读数重复（且单位不同：章 vs 页）的读数。
- `_fullscreen` 不落盘（见 §1）；若日后要「记住上次 chrome 显隐」，需新增设置项。

### 2.73 `OverflowBox` 默认居中把整页内容顶偏（真机「多了下半部分」定案）（2026-10-08）

**起因**：负责人真机截图「出现文字多了下半部分」——页面中段有一行只露出下半截，
且与上一行文字相同。

#### 1. 逐像素量测（截图 881×1920，先量后猜）

| 量 | 结果 |
|---|---|
| 该行完整副本 | 墨迹行 y 572..611（39 行，正常行高） |
| 该行残缺副本 | 墨迹行 y 623..645（**23 行**） |
| 两副本是否同一文字 | 残缺行的 23 行墨迹剖面 == 完整行**下 23 行**剖面（逐项吻合，JPEG 噪声内） |
| ⇒ 结论 | 同一行被画了两次；第二次只露出**下半截**（上 17px 被切） |
| 相对理想行栅格 | 该行以下各行整体比栅格高 ~33px；以上各行严格落 68px 栅格 |
| 全图其余行高 | 38..40px（均为完整行）⇒ 局部缺陷，不是整页双重渲染 |

「同一段文字被画两次」只有一处解释得通：该段落**跨页**，而 `PageContent` 按设计把
「页首行所属段 → 页末行所属段」的**完整段落**叠成 Column、再整体平移 `−preHeight`
（`page_renderer.dart` 文件头）。两页各自的窗口都在这条 Column 上取景，
**窗口与内容的相对位置只要差一点，就会一页露全、另一页露半截并叠字**。

#### 2. 定位：`OverflowBox` 的默认对齐是 `Alignment.center`

`PageContent` 的裁切结构是 `SizedBox(页框高) → ClipRect → OverflowBox → … → Column`，
而 `OverflowBox` 的 `alignment` **没写**。读 Flutter 真实源码：

```
flutter/lib/src/widgets/basic.dart:3430
  const OverflowBox({ …, this.alignment = Alignment.center, … })
```

⇒ 整块「完整段落」在页框里**垂直居中**，偏移 `(页框高 − 内容高) / 2`。
这个量：① 随页内段数变化；② 一般**不是行高整数倍** ⇒ 裁切窗顶边恰好切在字中间，
且窗口会落到相邻页的正文上（同页重复 / 跳字）。

**探针实测**（`test/ui/_probe_clip_center_test.dart`，夹具 pageWidth 180 /
pageHeight 200 / 段落渲染高 319，用完即删）：

| 页 | 页框顶 | 首段渲染顶（修前） | 偏移 | 顶对齐应为 |
|---|---|---|---|---|
| 0 | 40 | −47 | **−87.0** = (145−319)/2 | 40 |
| 1 | 185 | −32.5 | **−217.5** = −72.5 + −145 | 40 |
| 2 | 367 | 294.5 | **−72.5** = (174−319)/2 | 367 |
| 3 | 541 | 280 | **−261.0** = −87 + −174 | 367 |

#### 3. 修法与验证

`OverflowBox(…, alignment: Alignment.topLeft)` —— 一行。修后同一探针实测偏移变为
**0 / −145 / 0 / −174**，即恒等于 `−preHeight`（`Transform.translate` 成为窗口内唯一位移）。

- 永久回归测试：`paged_scroller_test.dart`「页内容顶对齐：首段渲染顶 == 页框顶 − preHeight」
  （期望值硬编码 `{40, 40, 367, 367}`，不引用生产常量）。
- **变异**：去掉 `alignment` ⇒ 判红 `Expected: <40.0> Actual: <-47.0>`（正是 −87 居中偏移）。

#### 4. 为什么此前四条测试都没抓到（教训）

- §2.71 的两条用例量的是 `PageContent` 的**盒**（`tester.getRect(PageContent)`）——
  **盒位置不受盒内居中影响**；
- 「段落渲染高 == Σ 测量行高」量了盒内，但量的是**高**不是**位置**——居中不改高度；
- §2.71 的**探针**把段落包在 `OverflowBox(…, alignment: Alignment.topLeft)` 里
  （显式 topLeft），恰好是**修好后的形态**——探针与生产不同构，bug 就藏在缝里。

> **纪律**：探针必须**直接构造/驱动生产 widget**，不要为了省事另搭一层等价结构；
> 「等价」正是最容易出错的地方。

#### 5. 回归

`test/reader + typography + perf + search` 与 `test/ui + widget_test.dart`
（均 `-j 1`）全绿；`dart analyze` 零问题。

### 2.74 真机三症状定案：占位整屏 / 陈旧章内比例 / 开书三 store 串行（2026-10-08）

负责人报「① 打开图书观感上还是很慢 ② 滚动模式文字重叠、章节间大段空白、滚动时跳动
③ 滑动模式顶部与底部文字被截断，可以参考 legado 优化」。先量后猜——四条探针
（`test/reader/_probe_*_test.dart`，直接驱动生产 `ReaderPage`，用完即删）实测如下。

#### 1. 探针实测（夹具 800×600 视口 ⇒ `pageHeight = 572.0`）

| 探针 | 量到的东西 | 结论 |
|---|---|---|
| `_probe_layout` | 滚动模式上屏页盒 0..524 / 540..1109 / 1125..1694；页内 12 段 y = 0,45,…,495..524（= 29 行高 + 16 段间距） | **滚动排版盒与行表模型逐像素一致**，稳态无重叠、无缝 |
| `_probe_long` | 168→90 字符长段落（页边界落段中间）：`pre` 平移量、段落渲染高 vs `Σ 行高` 全部相等；页 1 窗口 528..1085 正落在第 8 段首行（1085−1056 = 29 = 一行） | 「整段渲染 + `Transform.translate(−preHeight)`」路径**正确**（不该往这里找重叠） |
| `_probe_placeholder` | 未分页章占位块 **572.0**（= 整屏）；真实章 2727.0（5 页） | 占位块 = 一整屏空白；占位→真实 = **4.8 倍**高度突变 |
| 同上（放行闸门后） | 视口 `5454.0 → 4882.0`，窗口 `[h1,h2,h3]` → `[h2,h3]` | 视口被丢到新章**末尾**（整章被跳过） |
| `_probe_slide` | 开书即滑动：`PageContent` 43..567 在视口 0..572 内 ✓；唤出 chrome 后（未 settle）页 99..623 vs 视口 56..469 ⇒ **底部切 154px + RenderFlex overflowed by 154**；settle 后 99..443 ✓ | chrome 切换瞬间有一帧「页底被切」 |

#### 2. 「章节间大段空白」= 未分页章的占位块按整页高排

`_buildPageViews` 给未分页章 `headingHeight: cfg.pageHeight`（整屏），滚动是**连续长卷**，
于是「上一章正文 → 一整屏只有中间一行『载入中』→ 下一章正文」。

修：`_placeholderBandHeight(index, cfg) = 标题占高 + 一行正文 + 24`（实测 43.0+28.8+24 = **95.8**）。
占位语义（`Center('第 N 章 · 载入中…')`）**刻意不换成真标题**——占位块与真章的区分是
`reader_page_test` 回归①「占位块只显示载入中、无正文段落」的判据。

#### 3. 「滚动时跳动」= 占位章上的**陈旧章内比例**

`_applyPagedSample(null)`（采样为空 = 该章无页表 = 占位）改前只换章身份、
**留着上一章的 `_chapterPos`**；该章排完版后
`_ensurePagedActive → _primeOpenSync(charOffset: _currentCharOffset())`
拿这个「别人的比例」去落位 ⇒ 直接落到新章末尾。修：换章时 `_chapterPos` / `_livePos`
一并归零（视口落在占位块上沿 ⇒ 语义就是章首）。

#### 4. 「打开很慢」= 开书关键路径上三份 store **串行**等

实测 `reader.ready 222ms` 里 `reader.stores` = **130ms（59%）**，而这是
`progress → bookmarks → prefs` 三段互不依赖的小 JSON 读，纯白等。

修：三份 store 与书源解析**同时起跑**；只 await 首帧真正要用的 `progress` / `prefs`；
`bookmarks` 后到（同一批 IO，到手后单独 `setState`）——顺带把「书签读取失败」从
「整本书打不开」降级成「书签暂时没有」。
`reader.stores` 的语义随之变为**关键路径净等待**（起跑早于 `reader.load`，趋 0 即已让开）。

#### 5. 尾追加即预热正文（legado「预载下一章」语义）

改前正文只在停稳（`_onPagedStopped` ③）才载 ⇒ 快滑到窗口尾，新章先以占位块上屏，
**要等停手**才见正文。修：`_onPagedScrollUpdate` 尾追加时 `unawaited(_preloadWindowTail(...))`
——IO 异步不占滚动帧，到手后登记未分页章 + 启空闲分页帧。
与 `R1②`[_pauseAutoFill] 的分工：那边挂起的是**全书预热**（Profiler 实测 56% 纯 CPU），
这里只为**紧邻视口的一章**起一次 IO。

#### 6. 「滑动模式底部被截断」= chrome 切换那一帧按旧页表绘制的溢出

`usableHeight = 视口高 − 顶部 inset − reserve`，而「唤出 chrome」会真的改变
`constraints.maxHeight`（`AppBar` + 控制条把 body 顶小）⇒ **换页配置必须重排**。
重排是帧末 `_requestReprime` 起步的，于是**切换那一帧仍按旧页表绘制**：
旧页表（524 高）画进新可视区（413）⇒ 底部约 5 行被裁（探针
`_probe_slide` 实测 `99..623` vs `56..469`；`_probe_bigslide` 用 400 段大章复测
= 越界 142px、**只存在 1 帧**，第 2 帧即自愈——不随章长恶化）。

真正的伤害在**渲染层**：`_turnPageWidget` 返回的是 `Column`，被 `PageTurnLayers`
放进 `Stack(fit: StackFit.expand)` ⇒ 紧约束 ⇒ 内容高于可视区时 **RenderFlex 直接溢出**
（debug 下底部那几行被黄黑斜纹盖住，观感正是「文字被截断」；控制台刷
`overflowed by 154 pixels`）。

修：外层裹 `SingleChildScrollView(physics: NeverScrollableScrollPhysics())`
——只为一件事：给 Column **无界主轴**（不再触发溢出断言）并自己裁到页框。
**像素结果与改前完全一致**（本来就该被裁），改掉的是溢出条纹与 debug 断言。
变异（改回裸 `Column`）⇒ 新护栏判红，实测
`Actual: FlutterError:<A RenderFlex overflowed by 154 pixels on the bottom.>`。

> 「**顶部**被截断」未复现：`_turnPageWidget` 是顶对齐（`MainAxisAlignment.start`），
> 量不到上溢；如实记录，未改。

#### 6.1 仍未根治的一层（如实记录）

配置突变那一帧的几何自愈仍是**下一帧**（`_syncPageConfig` 的延迟消费是 build 期禁
`setState` 的结构性约束）。若要连这一帧都消掉，方向是让**正文排版区不随 chrome 变**
（chrome 覆盖而非顶开正文，即 legado 的形态）——那是 `TYP-09`「底部让位两口径」的
**契约变更**，须负责人拍板。

#### 7. 回归与护栏

- 新增 `test/reader/placeholder_band_test.dart` 两条：占位块高 `95.8`（且 `< pageHeight/2`）、
  占位→真实合入视口 `Δ ≤ 2dp`。
- `appearance_sheet_test.dart` 新增 `T05-d 验收③`：chrome 切换那一帧**不许**触发
  RenderFlex 溢出断言（并断言 reprime 后页内容回到可视区内）。
- **变异**（把占位高改回 `cfg.pageHeight`）：两条均判红 —— ①`Expected: <95.8> Actual: <572.0>`；
  ②`Expected: a value less than or equal to <2.0> Actual: <2684.0>`。
  **变异**（`_turnPageWidget` 改回裸 `Column`）：验收③判红 ——
  `Actual: FlutterError:<A RenderFlex overflowed by 154 pixels on the bottom.>`。
- 全组（`-j 1`）：`test/reader + typography + perf + search` **433** 全绿、
  `test/ui + widget_test.dart` **172** 全绿；`dart analyze` 零问题。
  注：`tool/test.sh reader` 的**并行**跑法偶发 flake（两次跑分别挂在
  `placeholder_band_test` / `stats_collector_test`），验收一律 `-j 1`。

### 2.75 EPUB 开书主线程冻结定案：进度权重改走 zip 元数据（2026-10-08，`7e9ceda`）

负责人报「epub 章节加载特别慢 / 快速滚动页面会出现多章节没有加载 / 慢滚动会出现跳动」，
并附一段 8.46s 录屏。先量后猜——但这次**两条最自然的猜测都被探针否证了**，
故本节先记证据链，再记真正的根因。

#### 1. 录屏量化：三次「停稳才跳」，且内容是**整体平移**（一字未变）

用 `imageio-ffmpeg`（本机无 ffmpeg；`pip install` 走清华源失败，改用阿里云源成功）
抽全部 203 帧（8.46s / 592×1280 / 24fps / HEVC），对正文带做 2-D 位移搜索：

| 事件 | 时间 | 位移 | 位移后残差 | **不位移**的残差 |
|---|---|---|---|---|
| 第 45 帧 | 1.88s | **+149px** | 7.15 | 41.94 |
| 第 90 帧 | 3.75s | **+75px** | 5.67 | 43.32 |
| 第 140 帧 | 5.83s | **+85px** | 7.02 | 42.28 |

残差「**移位前 42~43 → 移位后 5.7~7.2**」⇒ 内容**一字未变、只是整块平移**。
分段拟合第 139→140 帧：上/中/下三个三分之一带各自独立求得的位移 = **84 / 84 / 85px**
⇒ 均匀平移（≈2 倍行高）；同帧底部读数两帧都是「卷四 建炎三十六年 / **8/27 99.7%**」
⇒ 同一页、总页数未变。

节奏（逐帧分类）：
**慢滚（1~6px/帧，约 1s）→ 停 → 跳 → 静止 1~2.7s → 慢滚 → 停 → 跳 → …**
三次跳跃**都发生在滚动停止后的那一帧**。

> 这与 `_kickReprime()` 的「**滚动中推迟、停稳才跑**」（`reader_page.dart` 的
> `controller.position.isScrollingNotifier.value` 早退）逐帧吻合：重排被推迟到
> 用户停手的那一刻执行，于是「跳」总跟在「停」后面。

#### 2. 两条被否证的假设（记下来，省得下次重走）

| 假设 | 探针 | 结果 |
|---|---|---|
| `_headingTextStyle` 在 `build()` 里赋值、且在 `!_ready` 早退**之后** ⇒ 首个 prime 拿到 `headingHeight = 0`，之后变真值触发整章重分页（页 0 预算缩小 ⇒ 其后整体下移） | 逐帧读 `PagedScroller.chapters[i].headingHeight` | **否证**：第 4 帧起就是 `ph:95.8 / real:43.0`。真因是 `_pageConfig` 在 `!_ready` 期间**恒为 null**，首个 `_primeOpenSync` 必然发生在「同一次 build 已赋样式」之后，0 值那条路走不通 |
| 窗口尾追加 / 增量分页导致 `chapterTops` 突变、补偿不足 | 夹具长距慢滚 14 轮，逐帧记 `offset/max/total/tops/pg` | **否证**：`contentY` 恒为 43.0；窗口 2→3 章（`total 5454→8181`）时 offset 被正确保留（尾追加 delta = 0） |

#### 3. 根因（已修）：进度权重把整本书解压 + 解析了一遍，独占主 isolate

`ReaderPage._loadChapterWeights()` 调 `BookSource.chapterCharCounts()`；EPUB 的实现是
**逐章 `rawBytes`（惰性重解压）+ `extractSection()`（HTML 解析）统计精确字数**，
且循环体内**没有任何 `await`** ⇒ 整本书扫一遍全在同一个微任务里跑完。

探针（纯 `test()` 驱动真实 `DartEpubSource`；停顿用 `Timer.periodic` 心跳采样）：

| 夹具 | 精确 `chapterCharCounts()` | 新增估算 `chapterWeightEstimates()` |
|---|---|---|
| `buildEpub(320)` | 97ms / 停顿 **66ms** | 32ms / 停顿 **5ms** |
| `buildEpub(300, 100段)` | 247ms / 停顿 **217ms** | 31ms / 停顿 **5ms** |
| `buildEpub(800, 100段)` | 679ms / 停顿 **649ms** | 32ms / 停顿 **5ms** |
| 200 章 · 80 段 | 177ms / 停顿 **147ms** | 44ms / 停顿 **15ms** |

⇒ 停顿**随章数线性增长**；用户那本书 **1152 章**（真机截图实测）按曲线外推是**秒级**。
而它换来的只是底部读数那个**一位小数**的百分比；调用点又在开书后、用户开始滚动的
那一刻 ⇒ 帧回调与分页 `step` 全部停摆 = 「章节要等很久才出来 / 快滑过去好几章还是空的」。
这一点同时解释了负责人三条抱怨里的前两条。

#### 4. 修法

- 新增 `BookSource.chapterWeightEstimates()`（沿用既有的「带默认实现的具体方法增补」
  手法，不破坏 §A.1）。它与 `chapterCharCounts()` **唯一**的区别就是「**能不能遍历
  全书内容**」：估算允许不精确，但**不得遍历**；契约只要求「非负 + 与章内文本量正相关」。
  - EPUB：`EpubSection.uncompressedBytes` = zip 中央目录里的 `uncompressedSize`
    （`ArchiveFile.size`，`archive-3.6.1` 的 `zip_decoder.dart:43` 写自解压前即可得的
    条目头）——绑定闭包时顺手取，**零解压、零额外 IO**。
  - TXT：已切好的 `_Segment.end - _Segment.start`（不逐字符扫空白）。
- 阅读页**只走估算、不回落精确口径**：`_chapterWeights` 的注释与
  `chapterCharCounts()` 的文档都写明「阅读页不得调用」。「开书路径零全书遍历」要
  无条件成立，就不能给自己留一条会让 UI 冻住的后路；估算取不到就等权（与迁移前公式同形）。
- 顺带修一处 **O(n²)**：`_sectionByHref` 原为线性扫描 + 逐元素现算 `_matchKey`
  （百分号解码 + 小写化），而 `chapters()`（有目录书逐项反查）与权重估算都**逐章**
  调用它 ⇒ 1152 章约 **130 万次** `_matchKey`。改为惰性建一次的
  `匹配键 -> section` 索引（**同键保留首个**，与线性扫描「先出现者胜」逐位等价）。
  三条路径一起降到 O(章数)。

#### 5. 精度与护栏

权重换算成「全书进度百分比」后与精确口径的最大偏差：**0.52 个百分点**；
同一夹具的**等权退化**偏差是 **24.24 个百分点**（好 47 倍）。
（注意别用「单章相对误差」当指标——那是 UTF-8 字节 vs 字数的**系统比例**，
消费者只吃比例；正确的指标是百分点偏差。）

| 护栏 | 钉的性质 | 变异实测 |
|---|---|---|
| `test/format/epub_weight_estimates_test.dart` ① | 值 == 该章 zip 条目的解压后字节长度（测试**独立**用 `ZipDecoder` 核中央目录） | 改回「解压 + 数字数」→ 判红 `Expected: <5104> Actual: <1640>` |
| 同上 ② | 进度偏差 < 5 个百分点（+ 等权偏差 > 20 作「夹具判别力自检」） | 改成等权 `out[i] = 1` → 判红 `Actual: <24.2398164084911>` |
| 同上 ③ | dispose 后返回 `null`（优雅空结果） | — |
| `test/reader/chapter_weights_test.dart` | **调用计数探针**：开书路径对精确口径**零调用**（反向断言估算 ≥ 1 次，防「整条路径没跑」的假绿） | 阅读页改回 `chapterCharCounts()` → 判红 `Expected: <0> Actual: <1>` |
| `test/format/dart_txt_source_test.dart` | TXT 分段长度字面量 `[1519, 1519]` + 恒 ≥ 精确口径 | — |

全组（`-j 1`）：`test/format + reader + perf` **543 全绿**；`dart analyze` 零问题。

#### 6. 探针方法论订正：「心跳采样」必须让出一次**宏任务**

本轮第一个探针报 `maxLoopStall = 0ms`，而 300ms 的纯同步忙等校准也报 6ms。
原因：`await body()` 的恢复走**微任务**，而逾期的心跳是**宏任务**——微任务先跑，
于是 `finally { heartbeat.cancel(); }` 在心跳回调之前就把定时器掐了，**被阻塞期间的
那一次心跳永远等不到**。修法：`body()` 结束后先 `await Future.delayed(30ms)`
让逾期的 tick 补上，再 cancel。校准后才可信（300ms 忙等 → `stall=303ms`）。

#### 7. 仍未根治：「慢滚停稳后跳 75~149px」

三次跳跃的**触发时机**已经钉死 = 「滚动停稳 → 延迟的 `_kickReprime` 执行」，
但**位移量的来源**尚未定位：`PageBreaker` 的非末页是前缀稳定的（填充循环在
「放不下」处 break，与「后面还有多少行」无关；末页才因
`cursor < lines.length` 才做断句回拉），夹具里窗口扩展 / 增量分页也都不产生位移。

下一步需要**真机 `PerfLog`**（`paged.prime` / `paged.land` / `paged.extend` /
`reader.stores` 的时间戳序列），才能判定是「重锚落位偏差」还是「页表本身变了」。
本轮已把「开书秒级冻结」这条更粗的干扰源摘掉，复验时应当更容易看清。

### 2.76 真机「每次滚动都跳动」定案：自然停手不再吸附到行顶（2026-10-09）

#### 1. 症状（负责人原话）

> 滚动模式下，顶部文字显示一半，会弹跳一下显示全部，所以每次滚动，都会跳动。

「显示一半」= 自由滚动时视口顶落在**行中间**（`§2.71` 已定这是连续排版的
固有形态、**不是缺陷**）；「弹跳一下显示全部」= 停手后被吸附到**行顶**，内容
整块下移「该行已被滚过的余量」⇒ 那半截行露全。前一轮（`§2.75` §7）从录屏量到
的「停稳后跳」正是同一现象的一个分量。

#### 2. 根因：`§2.70` 的行顶对齐被用到了**自然停手**上

```
_onPagedStopped() ⑤
  → _ensurePagedActive()                       ← 每次停手都跑
    → _primeOpenSync(charOffset: _currentCharOffset())
      → landAt = PagedScrollerState.offsetFor(...)   ← 页顶 + **目标行行顶**（§2.70）
      → _jumpPaged(landAt)
```

`offsetFor` 的**行顶对齐**是为「程序化落位」定的——开书恢复 / 跳章 / 跳书签 /
跳目录 / 搜索命中都要「从这一行开始读」，不能从半行开始（`§2.70` 真机「字没
显示全」的定案）。但自由滚动的视口顶**几乎不会正好落在行顶**，于是这个落位在
每次停手时都被执行一次 ⇒ 每次停手平移一次。

#### 3. 探针（`_probe_scroll_jump_test`，已删）

夹具 `FakeBookSource([60,60,60])`、视口 800×600（页高 572）、字 18 / 行高 1.6
⇒ 行高 28.8。连续四轮「慢滚 → 停」：

| 轮次 | 自由滚动落点 | 停手后 | 位移 |
|---|---|---|---|
| 0 | 100.0 | 88.0 | **−12.0** |
| 1 | 145.0 | 133.0 | **−12.0** |
| 2 | 190.0 | 178.0 | **−12.0** |
| 3 | 235.0 | 223.0 | **−12.0** |

`paged.prime index=0 char=8 off=88` 就是那次吸附（现场 100 → 落位 88 = 该行行顶）。
修后同一探针：位移 **0.0**，打点变成
`paged.prime index=0 char=8 off=100 rem=12.0`（余量如实记录）。

#### 4. 语义裁决：`§2.70` 与 `§2.71` 各管一段

| 场景 | 落位口径 | 依据 |
|---|---|---|
| 开书恢复 / 跳章 / 跳书签 / 跳目录 / 搜索命中 | **行顶对齐**（余量不补） | `§2.70`：用户期望「从整行开始读」 |
| 自然滚动停手 / reprime 重锚 | **保留现场像素余量** | `§2.71`：自由滚动视口顶本就允许落在行中间；「用户滚到哪就是哪」 |

#### 5. 修法

`_primeOpenSync` 增加 `keepScrollRemainder` 形参（**默认 `false` = 行顶对齐**，
即程序化落位的既有行为**不变**），仅 `_ensurePagedActive`（停稳⑤）与
`_runReprime`（config / 图片尺寸变更后的重锚）传 `true`。余量由新增私有方法
`_scrollRemainderOf(href, charOffset)` 取：`现场像素 − offsetForCharOffset(...)`
（即「该行已被滚过的部分」），夹在 `±cfg.pageHeight` 内。

**关键性质**：布局未变时 `landAt_new == lineTop` ⇒ 目标值与现场像素**恰好相等**
⇒ `_jumpPaged` 被既有的 `|Δ| < 0.01` 挡掉 ⇒ **位移为 0**；布局真变了（章顶移动 /
页表增长）时仍按语义坐标跟着走，且比「跳到行顶」更贴合用户预期。

#### 6. 护栏与变异实测

| 护栏 | 钉的性质 | 变异实测 |
|---|---|---|
| `test/reader/scroll_stop_stability_test.dart` ① | 停手后 **offset 不变** + **可见页屏幕矩形一字不挪**（用户可见口径放最前） | `_ensurePagedActive` 去掉 `keepScrollRemainder` → 判红 `Expected {'h1#0': -57.0, 'h1#1': 483.0, 'h1#2': 1068.0} Actual {'h1#0': -45.0, 'h1#1': 495.0, 'h1#2': 1080.0}`（整块平移 12px） |
| 同上 ② | 程序化落位（「开书恢复上次 pos」驱动）**仍落在行顶**；行顶由**独立口径**算（`PageSlice` 页顶 + 行表累加 + 跨段补间距，**不用** `offsetFor` 自证） | `offsetFor` 改回「页内比例折算」→ 判红 `Expected: a value less than <0.01> Actual: <6.085603112840545>` |
| 同上 ① 的**判别力自检** | 每轮现场**必须不在行顶**（余量 > 1dp），否则「停手不跳」是句废话 | — |

全组（`-j 1`）：`reader` **436 全绿**；`dart analyze lib test` 零问题。

#### 7. 探针方法论：`tester.drag` 会连带 `pump`，量不到「自由滚动落点」

第一版探针用 `tester.drag(...)` 再读 offset 当「自由滚动落点」，四轮 delta 恒为
**0.0**——**假绿**。原因：`tester.drag` 内部会推进帧，而停稳流程（
`_onPagedStopped` 的 await 全在缓存命中时由微任务完成）在读取之前就跑完了，
量到的两个值**都是停手后**的。修法：用**裸手势**
（`startGesture` → `moveBy` → 读值 → `up()` → 读值 → `settle`），把边界卡在
`up()` 前后。同类「量两次同一侧」的坑在 `§2.66` 的心跳采样上出现过一次
（微任务抢在宏任务之前），**凡是量「事件前后」的探针都要先证明两侧真的不同**。

#### 8. 与 `§2.75` §7 的关系（仍未闭环的部分）

本轮摘掉的是「**每次停手都平移**」这一分量（幅度 ≤ 一行）。录屏量到的
**75 / 85 / 149px** 均匀整块平移幅度**大于一行**，故仍按 `§2.75` §7 挂账：
需真机 `PerfLog` 的时间戳序列判定是「重锚落位偏差」还是「页表本身变了」。

#### 9. 第一份真机日志（2026-10-09 09:17，USB 直连）

书：**1152 章** EPUB（`id=47ed5e…`）与 **447 章**（`id=daedd71b…`）。

**`§2.75` 的修法在真机成立**：`open.total 42ms / 40ms`（`reader.ready` 41/37ms、
`firstFrame` 42/40ms）、`reader.stores 17ms / 16ms concurrent`、
`reader.chapters 0ms count=1152` —— **没有秒级冻结**，进度权重走 zip 元数据生效。

**`§2.76` 的修法也生效**（这两行是新打点，说明跑的是新构建）：

```
09:17:04.744  paged.prime  index=446 char=2519 off=18663 rem=45.4
09:17:06.115  paged.prime  index=446 char=2534 off=18698 rem=51.2
```

`rem` 非零 ⇒ 行内余量被折进落位目标。算术自洽（可离线核对）：
`off=18663 rem=45.4` ⇒ 行顶 18617.6；`off=18698 rem=51.2` ⇒ 行顶 18646.8；
两次之间 `char +15` / `off +35`。开书恢复那条**不带 `rem`**
（`paged.prime index=446 char=2366 off=5016`）——程序化落位仍按行顶对齐，与护栏 ② 一致。

**但这份日志判不了「有没有跳」**：`paged.prime` 只记「算出来的目标」，不记
「真的跳了多少」。且全程只有 **4 条 `paged.prime`**、**零** `paged.land` /
`paged.estimate` / `paged.extend` / `paged.window` ⇒ 用户实际只「慢滚停手」了两次，
**没有复现到大幅跳跃**。故本轮先补仪器（下节），不下结论。

**顺带的两条观察**（记下来备用）：

- `rem` 可达 **45~51px**，**大于一行**（字 18 × 1.6 = 28.8）⇒ `sampleCharOffset`
  （按页内字符均匀折算的线性插值）与真实「像素 → 行」映射的偏差可达一行以上。
  **对位置保持无害**：余量 = 现场像素 − 同一个（不完美的）采样函数算出的行顶，
  布局未变时两者相消，目标值与现场像素恰好相等。
- 章高量级 ≈ **1.3 万 px/章**（446 章 8938 字），故窗口首部插入一章会让目标章
  的**绝对偏移**跳一万多 px —— 这是布局坐标的变化、**不是视口位移**。判「跳没跳」
  必须看 `paged.move` 的 `d`，不能看 `off` 的绝对值。

#### 10. 留痕补强：`paged.move` / `paged.stop` / `paged.prime at=`

上一节的教训：**要判「视口有没有动」，必须记「动之前在哪」**。三处新增：

| 打点 | 位置 | 语义 |
|---|---|---|
| `paged.move why=… from=… to=… d=…` | `_jumpPaged`（**唯一**程序化位移出口，含帧末补跳分支） | 每一次**真的跳**都留痕；`d` = 用户看到的那次平移量。`why` = `prime`（落位）/ `views`（换视图后按章顶差重锚）/ `.late`（帧末补跳） |
| `paged.stop px=… index=… pos=…` | `_onPagedStopped` 首行 | 每次停手一行，用于与录屏帧号对齐 |
| `paged.prime … at=…` | 落位**前**的现场像素 | `off − at` = 本次落位的真实位移（布局未变时应为 0） |

**判定法（下一份日志）**：`paged.move` 出现且 `|d|` 明显大于 1 ⇒ 一次用户可见的
跳动，`why` 直接指出通路；`paged.stop → paged.move` 的间隔对齐录屏即可定位到帧。

仪器本身有人工护栏：`scroll_stop_stability_test` ① 断言**停手流里 `paged.move`
恒为空**（`_jumpPaged` 连跳都没发起）。变异实测（去掉 `keepScrollRemainder`）：

```
[perf] paged.move  why=prime from=100.0 to=88.0 d=-12.0
```

该断言与「页面矩形不移动」是同一事实的两个层级，故只在被前者挡住时单独验证过；
此外它同时钉住「仪器接线正确」——探针自身失效会直接判红。

#### 11. 抓日志口径（本轮踩的坑）

- `adb logcat -s flutter` 会匹配**机器上所有 App** 的 flutter tag（本机混入小米
  桌面 / 小米汽车 / 天气）⇒ 加 `Select-String '\[perf\]'`（`[perf]` 是本项目独有前缀）。
- PowerShell 管道按 OEM 码页（936）解码原生 UTF-8 输出 ⇒ 中文全乱码；抓之前先
  `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`。
- `logcat` 是 `adb` 子命令，不能单独敲；`>` 会写 UTF-16LE，用 `| Out-File -Encoding utf8`。
- **抓之前先 `adb logcat -c` 清缓冲**，并把抓取窗口缩到「复现动作前后」——否则有效
  行被整屏无关日志淹没（本轮 465 行里只有约 60 行是本项目）。

---

### 2.77 开书转场重做：阅读页整页「纸张滑入」（2026-10-09）

负责人给了一段参考动效 mp4（4.44s / 444×960 / 24fps / HEVC），要求「做成这样的
loading 动画」。三条拍板：**① 替换**掉旧版封面卡遮罩；**② 滑入期间纸上就是阅读页
本体**（正文没就绪就显示阅读页自己的加载态）；**③ 圆角 70dp 照做**。

#### 1. 参考动效的逐帧量化（105 帧；ffmpeg 抽帧 + numpy 像素分析）

| 项 | 实测 |
|---|---|
| 触发 | 书架静止到第 53 帧；**第 54 帧**起纸张从右侧出现 |
| 形态 | 阅读页作为**一整张纸从右侧平移**到左，铺满屏幕 |
| 时长 | 第 54~65 帧 = **11 帧 ≈ 458ms** |
| 曲线 | **easeOutCubic**（见 §2） |
| 圆角 | 全程恒定 **70px**（占屏宽 15.8%），**平移到位那一帧**才变 0 |
| 高度 | 满高：纸顶 == 屏幕顶（y=0），盖住状态栏 |
| 背景 | 书架**静止不动**，被黑色遮罩按滑入进度压暗，终值 **54%** |
| 纸上 | 直接是渲染好的正文 + 底部读数行，**全程无 spinner** |

#### 2. 位移曲线反推（左边缘像素 → 进度 → 曲线拟合）

纸张左边缘逐帧（多行投票取中位数；掩码 = 与纸色 `[221,192,140]` 距离 < 16）：

```
f054 430  f055 318  f056 214  f057 132  f058 78  f059 46
f060  26  f061  14  f062  14  f063   6  f064  4  f065  2  f066  2
```

以「起点 444（屏宽）、终点 2」折算进度 p，再用 `1-(1-t)³` 拟合：

| 帧 | 实测 p | easeOutCubic 在对应 t 的理论 p |
|---|---|---|
| f055 | 0.285 | t=0.11 → 0.295 |
| f056 | 0.520 | t=0.21 → 0.507 |
| f058 | 0.828 | t=0.44 → 0.824 |
| f060 | 0.946 | t=0.60 → 0.936 |
| f063 | 0.991 | t=0.84 → 0.996 |

每帧推进 ≈0.09 ⇒ 总时长 ≈ 1/0.09 ≈ 11 帧 ✓。**easeOutCubic** 成立——「半程已走
87.5%」这条后来直接成了护栏判据（§8 变异 A）。

#### 3. 「书架静止」与「内容随纸平移」的正面证据

- **书架静止**：固定屏幕位置跨帧比较亮度。x=4..8 处 `f052` 为 247.3，`f054~f061`
  依次 241.4 / 207.7 / 176.1 / 151.3 / 140.2 / 127.7 / 123.0 / 117.6 —— 是**单调
  压暗**（247 → 118，比例 0.478）而**不是**内容位移。若书架被推走，同位置像素会
  整块换掉而不是稳定变暗。
- **内容随纸平移**：滑动期各帧与终态做互相关（区域 y120..900，参考窗 x300..430），
  位移 `+12 / +7 / +3 / +1 / 0`，与同期纸张左边缘 `14 → 8 → 4 → 3 → 2` 同步
  ⇒ 纸张（含正文）**整体平移**，不是静止被「揭开」。
- **暗化与进度同步**：8 个采样点 `a / p` 比值 0.52~0.72（中位 **0.545**）⇒
  `alpha = 0.54 × p`。

#### 4. 圆角口径：恒定 70，落位那一帧才收

顶部逐行左边缘（`mid` = y=400 处左缘、`y0` = y=0 处左缘，半径 ≈ `y0 − mid`）：

```
f058  mid=78  y0=148  → r=70     f061  mid=14  y0=86  → r=72
f059  mid=46  y0=115  → r=69     f063  mid=6   y0=74  → r=68
f060  mid=26  y0=96   → r=70     f065  mid=2   y0=74  → r=72
                                 f066  mid=2   y0=2   → r=0   ★
```

**第 65 帧纸张左缘已贴屏幕左边（x=2）而圆角仍是 72px，第 66 帧突变为 0。** 所以
**不能**用「圆角随进度线性收」——那会让滑入中段的左上角圆弧一路变小，与参考动效
不符。修法：把收回压缩在进度最后 1%（`_kRadiusSettleFrom = 0.99`）。

（纸右边缘全程在屏幕外，故右侧圆角不可见——与参考动效一致。）

#### 5. 实现（`lib/reader/reader_open_transition.dart` 整体重写）

```
Stack(fit: StackFit.expand)
├─ ColoredBox(black, alpha = 0.54 × p)            // 压在书架上的暗化层
└─ Transform.translate(Offset(width × (1−p), 0))  // 「纸」= 阅读页本体
   └─ ClipRRect(radius = 70 × (1 − settle))
      └─ child                                    // ReaderPage
```

- `p = Curves.easeOutCubic.transform(animation.value)`；`settle = clamp((p−0.99)/0.01)`。
- `kReaderOpenDuration` 280ms → **460ms**；新增 `kReaderPaperRadius = 70`、
  `kReaderOpenScrimAlpha = 0.54`、`kReaderOpenReverseDuration = 320ms`；
  `kReaderOpenFadeOut` 删除。
- **「能看到书架」不是我们画的**：转场期间 `ModalRoute` 把本路由 overlay entry 的
  `opaque` 置 false（forward / reverse 时），动画 completed 才恢复 ⇒ 下层书架继续
  绘制，且**完全不动**（生产代码里没有任何一行碰它）。这也是「覆盖式」而非
  「推出式」转场的实现基础。
- `Stack` 默认 `Clip.hardEdge` ⇒ 纸张还停在屏幕右侧之外时天然不可见，无需额外裁剪。

#### 6. 连带删除：静态门闸 `ReaderOpenTransition` 整体移除

旧版靠它等「阅读页首帧就绪 → 撤遮罩」（撤早了会在淡出过程里露出空白）。
新版**没有遮罩要撤**——纸上就是阅读页本体，没就绪时用户看到的就是阅读页自己的加载
态，就绪即无缝变正文。故门闸、它的一次性语义与异常兜底路径全部删除，
`ReaderPage._open()` 里的 `addPostFrameCallback → signalReady()` 上报点一并删除
（**首帧探针 `attachFirstFrameProbe()` 保留**，`§2.69` 的链路追踪不受影响）。

同时删掉只为旧遮罩存在的 `buildStandaloneBookCover()`（`lib/ui/book_card.dart`，
2026-10-06 专为遮罩写）——唯一调用点已随遮罩移除。`_FormatTag` /
`kBookCoverRadius` / `kBookFormatBadgeInset` 仍被 `BookCard` 使用，保留。

#### 7. 护栏（`test/reader/reader_open_transition_test.dart` 重写，7 条）

量的是 `localToGlobal` 结果（**屏幕坐标**，含 `Transform` 位移），不是 widget 参数
——后者会把「参数对了但渲染没应用」的缺陷放过去（`§2.71` 探针自建的教训）。

| # | 护栏 | 钉住 |
|---|---|---|
| ① | 推入中：纸已在屏内、书架锚点不动、暗化 ∈ (0, 0.54)、圆角 == 70 | 形态四要素 |
| ② | 书架全程静止：5 个时点锚点坐标零位移 | 覆盖式（非推出式） |
| ③ | 半程位移占比 > 0.7 | easeOutCubic |
| ④ | 落位：`left == 0`、`dy == 0`、纸宽 == 屏宽、圆角 0、暗化 0.54 | 终态满屏 |
| ⑤ | 内容永远不就绪也照常铺满 | 门闸删除后无「卡在半路」 |
| ⑥ | 返回时纸向右滑出 | 反向同源 |
| ⑦ | `460ms / 70 / 0.54` 字面量 | 参数回潮 |

② 的判别边界要写清楚：**当前实现结构上不可能推动下层路由**，故它现在恒绿；它真正
防的是将来有人换成「用 `secondaryAnimation` 推走旧页面」的转场（如
`CupertinoPageRoute` 那种），那时书架锚点会移动 ⇒ 判红。

#### 8. 变异实测（每条护栏都「改坏 → 判红」）

| 变异 | 判红用例 | 判红断言（实测） |
|---|---|---|
| A `easeOutCubic` → 线性 | ③ | `Expected: a value greater than <0.7>` / `Actual: <0.5>` |
| B 圆角不收回（恒 70） | ④⑤ | `Expected: <0> / Actual: <70.0>`（两条） |
| C `_kRadiusSettleFrom` 0.99 → 0（线性收角） | ① | `Expected: <70.0> / Actual: <26.71371050477028>` |
| E 暗化不随进度（恒终值） | ① | `Expected: a value less than <0.54>` / `Actual: <0.54>` |

还原后 7 条全绿。变异 A 判红时的 `0.5` 正是「线性曲线半程只走一半」的证据，
与 §2 反推出的 easeOutCubic 形成闭环。

#### 9. 已知落差（对参考动效的诚实降级）

参考动效里纸张滑入时**正文已经渲染好了**（零等待）；MReader 真机首帧渲染需
335~509ms（`§2.69`），滑入窗口只有 460ms ⇒ 滑入前半段纸上先是**阅读页自己的加载
态**，就绪后无缝变正文。这是负责人拍板接受的形态（选项「纸上就是阅读页本体」）。
对照 `§2.69` 的原始动因——那段等待无法消除、只能藏起来——**460ms 的滑入窗口与
加载窗口基本等长**，遮盖效果与旧版遮罩等价而不额外拖长总时长。

#### 10. 测试与验收

`test/reader/reader_open_transition_test.dart` **7 全绿**；`reader` 组 **436 全绿**
（`-j 1` 串行）、`ui` 组 **172 全绿**；`dart analyze lib test` 零问题。净删 342 行。

**顺带踩实一个既有坑**：`reader` 组**并行**跑时 `reader_page_test` 的 RD-04
（href 优先恢复）会偶发失败（本次实测 `435 +1 −1`），而**单文件跑与 `-j 1` 串行
均全绿** ⇒ 该组与 `ui` 组一样存在**并行 flake**，验收一律 `-j 1`。

**待负责人真机复验**：滑入观感、70dp 圆角与 54% 暗化在真机上的轻重、滑入前半段
露出阅读页加载态是否突兀。

---


### 2.78 开书转场「先按住、就绪后再滑」：修「打开书闪一下」+ 复核参考动效（2026-10-09）

修负责人真机**必现**的一条：**打开书时整屏先暗一下再变亮**。本节含三件事——
诊断（逐帧亮度）、修法（负责人拍板「等就绪再滑入」）、以及对 §2.77 一条口径的
**订正**（参考动效里书架其实是**动的**）。

#### 1. 现象：逐帧亮度上有一次「过冲」

负责人录屏（592×1280 @24fps，7.22s / 173 帧）抽帧逐帧平均亮度（`im.mean()`）：

```
f052 91.9  f053 88.3  f054 57.0  ← 转场起
f055 37.5  f056 31.3  ← 最暗（比阅读页稳态还暗）
f057 46.1  f058 44.6   …   f065+ 44.4  ← 阅读页稳态
第二次开书 f117 56.9 → f118 37.0 → f119 30.6 → f120 28.3 → f121 45.0（同型）
```

「最暗比稳态还暗 13 个单位」是关键：**不是**渐进变亮，而是先压过头再弹回来。

#### 2. 根因：转场那 460ms 里，那张「纸」是**空的**

转场期间阅读页尚未完成首帧渲染 ⇒ `ClipRRect` 里的 child 是**透明的** ⇒ 屏幕上
只剩「被 scrim 压暗的书架」。「书架可见」本身是对的（§2.77），错的是**纸上没有
东西**，于是「覆盖式」变成了「整屏先暗后亮」。两条独立证据：

1. f054 整屏**书架完整可见**（书卡 / tab / 文字都在，只是变暗）⇒ 没有任何东西盖住
   它；亮度 97.3 → 57.0 ⇒ alpha = 0.41 ⇒ 反推滑入进度 `p = 0.41 / 0.54 = 0.77`
   ⇒ **纸张本应已铺 77%**，却看不见 ⇒ 它是空的。
2. f056 纸张已铺右半边且**可见左边界**（左半仍是书架），纸上是**深色空白 + 白
   spinner**（亮度 ≈ 18）；f058 同位置换成正文（亮度 ≈ 42）⇒ 一帧内变亮 24 = 闪。

**深层原因（主题差异）**：参考动效是**浅色纸**（纸 ≈ 175 / 书架 ≈ 215，两者都亮）
⇒「暗化旧页 + 亮纸滑入」成立；MReader 这里是**深色主题**（书架 97 / 阅读页 44.6 /
空纸 18）⇒ 同一个 scrim 就从「旧页面退后」变成了「整屏变暗」的元凶。**浅色主题下
会轻很多**。

#### 3. 修法（负责人拍板「等就绪再滑入」）

点书后**先把转场按住**（纸停在屏幕右侧之外、一点都不压暗书架），等阅读页**首帧
真正上屏**再放行——纸滑进来时上面已经是正文，没有空纸期。

- 门闸 `ReaderOpenTransition`（`arm` / `signalReady` / `disarm` / `isActive`）**加回**：
  它只回答「阅读页好了没有」，与遮罩无关。带 **owner 令牌**，撤销时只清自己那一份。
- **按住的是路由动画本身**：`ReaderOpenRoute.hold()` / `release()` 作用在 `PageRoute`
  的 `AnimationController` 上。等待期状态停在 `forward` ⇒ `ModalRoute` 的 `opaque`
  保持 false ⇒ 下层书架继续绘制（**一行代码都没碰它**）。
- **就绪上报点**：`ReaderPage._signalOpenReady()`——在 `_ready` 的 `setState` **之后**
  走 `addPostFrameCallback`，即「正文那一帧 paint 完」才报。**失败路径也报**（否则
  书永远打不开）。刻意不用 `Future.delayed`（FakeAsync 里会留下未清挂起物）。
- **兜底**：`kReaderOpenHoldTimeout = 3s`（`Timer`，`dispose` 里 cancel）。正常路径
  300ms 内就会报就绪，这条只防「异常路径漏报」——按住期间没有任何其他退出路径。
- **视觉口径**：按住期间 `_held` 强制 `p == 0`（纸完全在屏幕右侧之外、`scrim == 0`）。

#### 4. 读源码核实的四条框架事实（其中一条订正了我原先的写法）

| # | 事实 | 出处 |
|---|---|---|
| ① | `createAnimationController()` **只被调用一次** ⇒ 子类存的 `_controller` 就是主控制器（不是 secondary） | `routes.dart:326` |
| ② | `overlayEntries.first.opaque` 只在动画走到 `completed` 时置回 true；`forward`/`reverse` 时置 false | `routes.dart:293` |
| ③ | **`stop(canceled: false)` 并不「让 push 的 future 悬着」**（我原先注释里的说法是错的）：`whenCompleteOrCancel` 走 `TickerFuture.orCancel`，而 `_complete()` 与 `_cancel()` **都会**让 `orCancel` 结算，`Navigator` 的 `pushing → idle` 两种取值下都会提前发生（`navigator.dart:3276`）。区别只在 `true` 会让 `orCancel` 以 `TickerCanceled` 收场（多一条错误路径）。**真正让书架继续绘制的是 ②，不是这里** | `ticker.dart:452/459/471` |
| ④ | `Ticker.start()` 只在 `idle < phase < postFrameCallbacks` 时取 `currentFrameTimeStamp` ⇒ **在帧后回调里放行，第一次 tick 的 `elapsed` 是 0**：放行之后必须再落一帧才吃得到时间 | `ticker.dart:203` |

**护栏的帧序也必须按这条来**（实测）：点书后**第 1 帧纸张就已经建起来了**
（`initState` / `hold()` 都在那一帧跑），但**那一帧它落在 offstage 一侧**——
`find.byKey`（默认 `skipOffstage: true`）返回 0，`skipOffstage: false` 返回 1；
第 2 帧起才默认可见。所以：**断言只能从第 2 帧起**，而要「放行后能量的到位移」
还得再多推一帧（④）。

#### 5. 复核参考动效：纸上有正文；**书架其实是动的**

负责人指出这段动效来自 legado，让先看它怎么实现——于是回头把本地四份 legado 系
源码读了一遍，并**抽帧重看**参考视频（444×960 @24fps，过渡在 2.2~2.6s）：

**源码侧结论：没有可抄的「legado 实现」。**

- `567Reader`（Kotlin，legado 二开）与 `legado-E`（阅读Sigma，legado 衍生物）里，
  开书一律是 `startActivity(ReadBookActivity)`，**没有任何应用层动画**：无
  `overridePendingTransition`、无 `makeSceneTransitionAnimation`、无
  `windowAnimationStyle`/`activityOpenEnterAnimation`、无 Compose
  `enterTransition`/`slideIntoContainer`；`res/anim/` 只有 200ms 的读页顶/底栏滑动。
- `legado_flutter-2026`（Flutter 移植）书架→阅读是**裸 `MaterialPageRoute`**。
- 全仓唯一的 `SlideTransition`（`QReader/lib/service/book.dart`）明确写了
  「**不对旧路由做任何视差 / 暗化变换**」，与视频不符。
- 视频里的 App **不是本地这几份**：书架上有「极空间」tab（NAS），四份仓库 grep
  「极空间」**零命中**。
⇒ 这条动效更可能是**窗口级（系统 Activity/应用打开）动画**：旧窗口左移 + 压暗 +
窗口圆角、新窗口从右推入、状态栏不动——那一套不由 App 代码绘制。

**抽帧重看得到的事实（其中第二条订正 §2.77 §③）：**

1. **纸上有正文**：过渡中段（s_09）纸的左缘在屏幕 1/4 处，纸上是整段正文
   「此行，闫太尉会多有不服…」，**不是空纸、也没有 spinner** ⇒ 参考动效**不存在
   空纸期**。这正是本次修法要达成的目标；机制上也对得上——系统只在**窗口首个
   帧缓冲就绪后**才开始播窗口动画，等价于「等就绪再滑」。
2. **书架不是静止的**：同一帧里书架整块**左移**——tab 行两处特征（「本地」
   「极空间」）独立量得左移 **−69px 与 −76px**（屏宽 444 的 **16~17%**），书卡上的
   未读徽标同向位移 ≈ −68px，三个特征互相印证。§2.77 §③原写「书架纹丝不动」，
   **据此订正**。（是否另有轻微缩小 ≈0.9 未能确证：24fps 录屏对 60fps+ 动画有帧
   混叠。）

**据此新增两条待拍板**（进度表 #10）：① 是否给 MReader 的书架补上「左移 ~16% +
压暗」的视差（单窗口 Flutter 里要自己驱动 `secondaryAnimation`，见
`notes-pitfalls.md` §3）；② 认下「应用层近似」——系统的窗口动画本就不可复刻。

#### 6. 护栏 11 条与变异

`test/reader/reader_open_transition_test.dart`（11 条）：

| # | 用例 | 钉住什么 |
|---|---|---|
| ① | 未就绪就一动不动 | 40 帧内 `paperLeft == 一整张纸宽`、`scrim == 0`、书架锚点零位移、**`overlayEntries.first.opaque == false`** |
| ② | 先按住、就绪后才滑 | 信号之前纸不动，信号一到立刻起滑（顺序，不是同时） |
| ③ | 推入中：纸进来 / 书架不动 / 压暗 / 圆角满值 | §2.77 四要素 |
| ④ | 书架全程静止 | 滑入 5 个时点锚点零位移 |
| ⑤ | 位移曲线前快后慢 | 半程 > 0.7（线性会判红） |
| ⑥ | 落位：铺满 / 圆角 0 / 暗化终值 | 终态 |
| ⑦ | 漏报就绪也不卡死 | 3s 超时兜底无条件放行 |
| ⑧ | 按住期间返回 | 值停在 0 ⇒ 返回是**零时长**的，纸随路由退场；门闸已撤销 |
| ⑨ | 返回：纸向右滑出 | 反向用同一转场 |
| ⑩ | 时长/半径/暗化字面量口径 | `460 / 70 / 0.54` |
| ⑪ | **真阅读页经 `ReaderOpenRoute` 打开** | 门闸会被真的推开（拆掉 `_signalOpenReady` 就判红），且不是靠 3s 兜底 |

**① 里那条 `opaque` 断言是补盲区补出来的**（先按 16 帧写，变异 5 不判红才发现）：
「按住」的**真正语义是让下层继续被绘制**——`opaque` 只在动画走到 `completed` 时
置回 true（§4 ②），一旦置回，书架就不再被画、屏幕会空掉；而树坐标（`paperLeft` /
书架锚点位置）**量不到「还画不画」**，因为不绘制时 widget 仍在树上。所以 ① 的循环
拉到 **40 帧（≈640ms，刻意超过 460ms 的滑入时长）**，并直接问
`route.overlayEntries.first.opaque`（`Route.overlayEntries` 与 `OverlayEntry.opaque`
都是公开 API）。为此 `_Host` 增加可选 `route` 实参，让用例能握住路由引用。

**变异实测（改坏生产代码 → 期望判红）**：

| 变异 | 结果 | 判红断言（实测） |
|---|---|---|
| 1 `dispose` 不 `cancel` 超时闹钟 | **红** | `A Timer is still pending even after the widget tree was disposed.`（①） |
| 3 `dispose` 不撤销门闸登记 | **红** | `Expected: false` / `Actual: <true>`（⑧ `isActive`） |
| 4 阅读页不上报就绪（`reader_page.dart` 拆掉 `_signalOpenReady()`） | **红** | `Expected: false` / `Actual: <true>`（⑪，理由串「阅读页没报就绪…」） |
| 5 `hold()` 不真的 `stop()`（只返回 true） | **红** | `opaque` 置回 true（①，见上「补盲区」） |
| 2 按住期间不强制 `p == 0`（照读 `animation.value`） | **绿（不判红）** | 见 §7 第 2 条——本工作区量不出差别，已如实挂账 |

#### 7. 已知边界（诚实挂账）

- **`ReaderOpenRoute.release()` 里「已被返回打断就拒绝起跑」这条分支在本工作区
  不可达**：两个上报点（`ReaderPage._signalOpenReady` 与超时闹钟）都自带
  mounted/dispose 闸，转场被拆时都先失效。留着是防以后新增上报点绕过那道闸——
  在正在拆卸的路由上点着 ticker 会撞 `AnimationController.dispose` 的
  「disposed with an active Ticker」断言。**没有对应护栏**。
- **`_held` 强制 `p == 0` 这一条本身量不出差别**（变异 2 实测：11 全绿）：
  `hold()` 落在路由入栈后的第 1 帧，那时控制器的值本来就恰好是 0（`_startSimulation`
  把值置为 `simulation.x(0)`，而 push 不在帧内 ⇒ 首次 tick 的 `elapsed` 也是 0）。
  留着是为了把口径写进代码，而不是靠「恰好为 0」的推论。**注意区分**：`hold()` 的
  `stop()` 本身**是**被判红的（变异 5 → ① 的 `opaque` 口径），盲区只在于「强制 0」。
- **书架左移（~16%）尚未实现**，且**是否要做待拍板**（见 §5 与进度表 #10）。

#### 8. 测试与验收

`test/reader/reader_open_transition_test.dart` **11 全绿**（含第 ⑪ 条接线护栏）；
`reader` 组与 `ui` 组 `-j 1` 串行复验结果见提交信息；`dart analyze lib test` 零问题。

### 2.79 chrome 改为覆盖层：点中间菜单不再改动正文排版区（2026-10-09）

**起因**：负责人原话「**阅读页点击中间菜单，不应该修改阅读区的高度**」。
这正是 `TYP-09` 一直挂账的那条契约变更（§2.74 §6「根治需 `TYP-09`『正文排版区
不随 chrome 变』契约变更，**待拍板**」+ 进度表 #10）——本轮拍板落地。

#### 1. 根因（探针实测，393×852 / top44 / bottom34）

| 量 | 全屏（默认） | 唤出 chrome |
|---|---|---|
| `reader-viewport` | `(0,44,393,852)` `h=808` | `(0,100,393,715)` `h=615` |
| `reader-content-area` | `(0,44,393,790)` **`h=746`** | `(0,100,393,687)` **`h=587`** |
| `reader-progress-indicator` | `792..852` | `689..715` |
| `ReaderControlBar` | 不在树上 | `715..852` |
| `AppBar` | 不在树上 | `0..100` |
| `MediaQuery` @body 内 | `(0,44,0,34)` | `EdgeInsets.zero` |
| `MediaQuery` @body 外 | `(0,44,0,34)` | `(0,44,0,34)` |

两条独立成因，**叠加**成 −159px（≈ 5 行）的排版区变化：

1. **`appBar` / `bottomNavigationBar` 是 Scaffold 的「占位」槽**：
   `_ScaffoldLayout.performLayout` 取 `contentTop = appBarHeight`
   （`scaffold.dart:1043`，`extendBodyBehindAppBar` 为真时才为 0）、
   `contentBottom = bottom − max(minInsets.bottom, bottomWidgetsHeight)`
   （`scaffold.dart:1088-1091`）⇒ body 高 852 → 615。
2. **`_buildBody` 里那个 `context` 是 LayoutBuilder 的**（遮蔽 `State.context`）：
   `MediaQuery.of(context)` 拿到的是 `Scaffold` 给 **body** 加工过的那份
   （`scaffold.dart:3030-3033` 定 `removeTop: appBar != null` /
   `removeBottom: bottomNavigationBar != null`）⇒ 顶部 44→0、底部 34→0。

⇒ `usableHeight = 852 − 44 − 62 = 746` 变成 `615 − 0 − 28 = 587`；
`PaginationConfig` 有值相等语义 ⇒ `_syncPageConfig` 判定「变了」→ `_requestReprime`
⇒ 整页重排、阅读位置肉眼可见地跳。

#### 2. 修法（两层，缺一不可）

| 层 | 改动 | 依据 |
|---|---|---|
| `Scaffold` | 加 `extendBody: true` + `extendBodyBehindAppBar: true` ⇒ body **恒占满整屏** | `contentTop = 0`（`scaffold.dart:1043`）；`extendBody` 在 `minInsets.bottom <= bottomWidgetsHeight`（键盘未弹时恒真）把底部层高度**加回** `bodyMaxHeight`（`scaffold.dart:1098-1101`） |
| 正文预算 | `topInset` / `bottomInset` 改取**页面级 `context`**（Scaffold 外层）的 `systemMq`，不用 body 内那份 | `Scaffold` 只加工其子孙的 MediaQuery；页面级 `context` 读到的仍是系统值 |

只做第一层不够：body 高度恒定了，但 body 内 `mq.padding` 仍随 chrome 变
（顶 44→100、底 34→槽高），`usableHeight` 照旧变。只做第二层也不够：body 仍被挤矮。

#### 3. 底部层合并（读数 + 控制条同槽）

`bottomNavigationBar: Column(min)[读数, 控制条]`，三条理由：

- 读数**恒在**该槽（`TYP-09` 验收①「chrome 全隐藏时它必须仍在」），且它自身就是
  模式无关的 chrome 入口（`reader-chrome-toggle-status`）。
- 读数排在**控制条之上**，正中 `control_bar.dart` 窄屏让位那条的依赖
  「同一串文字仍由控制条正上方的 `ReaderProgressIndicator` 常驻显示」。
  **顺序写反过一次**：实测 `indicator.bottom=852 / bar.top=655`（读数跑到控制条
  **下面**）⇒ 已被新护栏钉住。
- 配合 `extendBody`，两者只是**覆盖**正文 ⇒ 增删控制条不改排版区。

读数的 `bottomInset` 按 `_fullscreen` **二分**：只有它落在屏幕底边（chrome 收起）
时才吃掉系统手势条那 34dp；控制条在它下面时那一条由控制条自己的
`SafeArea(bottom: true)` 承担——重复计入会在两者之间留 34dp 空带（变异实测
`readout.bottom` 距 `bar.top` 由 4 变 38）。

#### 4. 连带修的体验缺陷：跳转后收起 chrome

chrome 变成覆盖层后**顶栏会压在正文上沿**，而搜索命中 / 目录 / 书签 / 摘要的落位
一律「目标在页顶」（§2.70 行顶对齐）⇒ 跳过去第一眼看到的目标正好在顶栏底下。
探针实测：目标段落矩形**两态完全相同** `Rect(8,0,792,29)`，差的只是可命中性
（chrome 开 `hitTestable=0` / 收 `=1`；顶栏占 `0..56`）。

修法 = `_exitChrome()`，四处调用（`TocSheet.onSelect` / `BookmarkSheet.onJump` /
`SearchSheet.onJump` / 摘要 `onJump`）。语义上也本该如此：「从弹层里挑一个位置」
＝「我要开始读这里」；参考实现（legado）的目录 / 搜索是**独立页面**，回到阅读页时
菜单本就是收起的。**控制条的「上/下一章」不做**——那时用户正在用控制条。

#### 5. 护栏与变异实测

新护栏：`test/reader/reader_inset_test.dart` 第三条「唤出 / 收起 chrome 不得改动
正文排版区」——两态 `reader-viewport` / `reader-content-area` **逐边相同**、
正文里的字（`chapterHeading`）屏幕矩形相同、读数落在控制条正上方、两者间不留空带。

| 变异 | 实测 |
|---|---|
| 去掉 `extendBody: true` | **红** `Expected: <746> Actual: <686.0>` |
| 正文预算改回读 body 内 `MediaQuery` | **红** `Expected: <746> Actual: <720.0>` |
| 读数 `bottomInset` 恒传系统值（不按 `_fullscreen` 二分） | **红** `Actual: <38.0>`（断言 ≤ 8） |
| 底部层顺序写反（读数在控制条之下） | **红** `indicator.bottom=852 / bar.top=655` |

口径变更：`appearance_sheet_test` T05-d 的触发方式从「收起 / 唤出 chrome」改为
**系统 inset 变化**（`tester.view.padding`，正文可排版高 572 → 508）——chrome 已
不再制造几何突变，那条用例的旧前提作废（否则就是「把缺陷钉成契约」的反面：
把**已失效的场景**留在注释里）。

#### 6. 已知边界与待拍板

- **chrome 覆盖正文**：顶栏盖 `0..100`（正文上沿 56px ≈ 2 行）、控制条盖
  `715..852`（正文下沿 77px ≈ 3 行）；chrome 可视时**可见阅读窗口 = 100..715**，
  与改前**同一个窗口**——变化只是「正文不再为它让路」。
- **另一条未采用的路线**：让排版区整体下移 56（高度不变、也不重排），文字不被顶栏遮。
  代价是文字每次切换平移 56px，且需把 `usableHeight`（高度）与顶偏移**解耦**。
  **若负责人更接受「文字下移、但不被顶栏遮住」，可改走这条** —— 待拍板。
- 读数与控制条在 chrome 态各占 26 + 34 / 137，读数**不会**被控制条覆盖（同槽上下相邻）。

#### 7. 测试与验收

`test/reader + typography + perf + search` **441 条全绿**（`-j 1` 串行）；
`test/ui + widget_test.dart` **172 条全绿**；`dart analyze lib test` 零问题。
**真机观感待负责人复验**：顶栏 / 控制条压住正文的观感、跳转后自动收起 chrome 是否合意。

### 2.80 真机「多次开关图书章节跳动」定案：分页缓存淘汰了正在渲染的当前章（2026-10-09）

**起因**：负责人原话「**还是会出现多次开关图书，出现页数跳动的情况**」，随后定位为
「**应该是章节跳动了，在当前页尾容易复现**」。

#### 1. 复现与量化（探针：6 章 × 25 段 / 393×852 / top44 / bottom34 / 分页滚动模式）

把视口拖到第一章的**最后一页**（读数 `第一章 2/2 9.7%`）后停手，再「关书 → 重开」：

| 轮次 | 修前 | 修后 |
|---|---|---|
| 关书前 | 第一章 2/2 9.7% | 第一章 2/2 9.7% |
| 重开 #1 | **第二章 1/2 25.1%** | 第一章 2/2 9.6% |
| 重开 #2 | **第三章 1/2 40.4%** | 第一章 2/2 9.6% |
| 重开 #3 | 第三章 1/2 40.5% | 第一章 2/2 9.6% |
| 重开 #4 | 第三章 1/2 40.5% | 第一章 2/2 9.6% |

**每次开书向前漂一整章**，漂到锚点不再落在窗口首章时自己收敛——正是负责人说的
「多次开关图书，章节跳动」。第 1→2 轮 0.1pp 的回读差是 §2.70 行顶对齐的正常量，
第 2/3/4 轮**逐字相同**（不累积）。

#### 2. 根因链（五步，每步都有探针打点）

在 `_updateLiveProgress` 之外另加「**所有** `_liveIndex` / `_livePos` 写入点」统一
打点（`[LV#]`）与「视图真/占位形态 + 分页缓存内容」打点（`[VP]`），实测序列：

```
[VP] win=[0,1,2,3,4,5] shape=RRRRRP cacheN=5 cache=[h1,h2,h3,h4,h5]
[VP] win=[0,1,2,3,4,5] shape=PRRRRR cacheN=5 cache=[h2,h3,h4,h5,h6]   ← ① h1（当前章）被淘汰
[LV#1] sample.now       idx=0 pos=0.5783 ... href=h1 char=96 pg=1 H=1631 c0@0p2 c1@1152p0 …
[LV#2] sample.debounced idx=1 pos=0.5060 ... href=h2 char=84 pg=0 H=5856 c0@0p0 c1@96p2 …  ← ④ ⑤
```

1. **窗口被撑大**：开书时窗口按「锚点可达」贪心向后 append（`_repairReachable`），
   而**未排页表的章只贡献一条 `_placeholderBandHeight`（≈96dp）占位带**，
   `layout.totalHeight` 因此几乎够不到 `anchor + vh`（第 1 章真实 1152 + 5 条占位带
   = 1631 < 718 + 746 = 1464 ⇒ 一路 append 到书尾）。探针里 3 章窗口被撑到 6 章，
   10 章书里实测 `paged.window was=[0..9]`。
2. 这些章随即被 `_registerWindowUnpaginated`（遍历 `_window`）登记进预分页队列。
3. `kPaginationCacheChapters` 只有 5 ⇒ `PaginationCache.put` 淘汰 LRU 队首，
   而**队首恰是「最先排完页表的当前章」**（`paged.prime` 先排它）。
4. **读路径 `_paginatedOf` 走只读 `peek`**（`pagination_cache.dart` 注释明写「不触碰
   LRU 序，供签名计算/只读判定」）⇒ 缓存被淘汰后 `_buildPageViews` **静默**退化为
   占位带 ⇒ 锚点以上布局**凭空少掉一整章高**（1152 → 96）。
5. 同帧的滚动体防抖采样（`_onPagedDebounced` → `_applyPagedSample`）拿**已经作废的
   像素偏移**（718）去套**新布局**（`c0@0p0 c1@96p2 …` ⇒ 718 落在第 2 章）⇒
   把「第二章 pos 0.5060」写进 `_currentIndex` / `_chapterPos`，且 `save: true`
   **落盘** ⇒ 下一次开书从错章开始，循环成立。

⇒ 症状里「页数跳动」「章节跳动」「章尾易复现」三者同源：章尾页的 `pos` 大、
采样点离章边界近，布局一塌陷就跨过边界。

#### 3. 修法：分页缓存淘汰**跳过正在渲染的窗口章**

`PaginationCache` 新增 `setProtected(Iterable<String> hrefs)`（保护集）与
`protectedHrefs`（测试观察）；`put` 的淘汰改为「取第一个非保护项」，
**全在保护集时 `break`（宁可不淘汰、暂时超界）**。`maxChapters` 因此降格为
**目标值**而非硬上界，注释已就地订正。

写入点唯一：`_applyPagedViews`（**唯一**换 `_pageViews` 的入口）按 `views` 的 href
同步保护集 ⇒ 保护集与渲染视图**天然一致**，不会残留。

为什么必须**显式**保护、不能靠 LRU 自愈：读路径用 `peek`（不提位），所以 LRU 序
只反映**分页完成顺序**——「被渲染的章」与「最近使用的章」是两个完全不同的事实。

#### 4. 一条**被否掉**的替代路线：给窗口加上界

「窗口章数 > 缓存容量」是 ① 的直接推手，所以第一版修法是给两个增长循环加
`while (… && _window.length < kPaginationCacheChapters)`。**它被回归②打回**：

`reader_page_test` 回归②（深章节恢复：20 章、只首帧批次 `[4,5,6]` 有内容、目标第 6 章）
在窗口被压到 5 章后判红——`chapterHeading('第六章')` 找不到。日志：

```
（加上界）[perf] paged.extend window=[4,5,6,7,8] total=500 anchor=184
          [perf] paged.jump   target=5 char=6/12 landed=true win=5
          （此后**没有**任何 paged.move —— 落位被静默丢弃）
（去掉上界）[perf] paged.extend window=[4,5,6,7,8,9,10,11] total=788 anchor=184
          [perf] paged.move why=views.late from=0.0 to=183.8
          [perf] paged.move why=views.late from=183.8 to=18115.0
```

机理：`total(500) < 视口(746)` ⇒ `maxScrollExtent == 0` ⇒ `_jumpPaged(184)` 走
「帧末补跳」分支，`clamped = 184.clamp(0, 0) = 0`，而现场 `pixels` 也是 0 ⇒
`|Δ| < 0.01` ⇒ **直接 return，落位被静默丢弃且永不重试**（唯一留痕点 `_jumpPaged`
在 return 之前，所以连 `paged.move` 都没有）。目标章自然进不了视图。

**结论：窗口多 append 只是浪费（≈ `ceil(vh / 96)` 章），不是错；错的是淘汰碰了
正在渲染的章。** 两条约束都写进了 `_repairReachable` 的就地注释，防止后来者再
「顺手收口」。

#### 5. 护栏与变异矩阵

新护栏两条：

- `test/reader/reopen_stability_test.dart`「章尾页反复关书 / 重开：章节与页位读数
  不漂移」——端到端钉症状（拖到 `2/2` → 关书/重开 ×3 → 三轮都必须 `第一章 2/2`，
  且第 2/3 轮逐字相同）。
- `test/reader/pagination_cache_test.dart` 新增「保护集」组 4 条（跳过淘汰 /
  全保护时超界不淘汰 / 只在淘汰时起作用 / `setProtected` 覆盖语义 + `clear` 清空）。

| 变异 | 页级护栏 | 缓存单测 |
|---|---|---|
| **废掉保护集**（`put` 退回无条件 `remove(keys.first)`） | **红** `[第二章 1/2 25.1%, 第三章 1/2 40.4%, 第三章 1/2 40.5%]` | **红** 3 条 |
| 保留保护集、改坏淘汰目标 | 绿 | — |
| ~~窗口上界压到 5~~ | 绿 | 回归②**红**（见上节，已否决） |

#### 6. 测试与验收

`test/reader + typography + perf + search` **447 条全绿**（`-j 1` 串行，含新护栏）；
`test/ui + widget_test.dart` **172 条全绿**；`dart analyze lib test` 零问题。
**真机复验待负责人**：章尾反复开合是否不再跳章、开书期读数（章标题 · n/N · 百分比）
是否稳定。

### 2.81 EPUB+TXT 开书提速：两级缓存 + 导入即按章预热（2026-10-09）

**起因**：负责人原话「**打开图书还是感觉慢，还能从哪儿优化，比如书籍导入就按章节进行缓存**
（只是思路，不一定要实现）」「你没有考虑txt」「**epub+txt一起优化**」。

#### 1. 两级缓存族（判据 / 信封 / 失败语义复用 M-PAGE `T06`）

| 缓存 | 目录 | 载荷 | 覆盖格式 |
|---|---|---|---|
| TXT 大纲缓存 | `outline/` | 章节切分结果 | TXT |
| 章正文缓存 | `chapters/` | 逐章段落表 | EPUB + TXT 共用 |

- 共用判据 `StructureCacheKey`（`bookId` + 副本 mtime/size），任一变 → 整体 miss。
- 信封 schema + 判据 + 载荷三段式；**损坏 / 判据不符 → 按 miss 绝不抛**（缓存是
  加速层，读坏了就现场重算，不阻断开书）。
- 「该章就是没正文」是稳定事实（内容决定，判据已钉死文件身份）⇒ 空表照写照读。

#### 2. 章正文磁盘缓存：追加 blob + 原子索引

`chapters/<bookId>.blob`（追加式段落负载）+ `chapters/<bookId>.index.json`（区间表）：

- **写 = 先追加 blob 再原子写索引**（`JsonStore` + `AtomicFile`，DATA-01 轮转语义）；
  索引里记录每章 `[start, end)` 字节区间。
- **写串行化 Future 链**：并发写 6 章不串味（并发下区间表不交错）。
- **判据失效整体重置 + 首写截断旧 blob**：杜绝旧判据的垃圾字节混进新区间表
  （截断推迟到首写而非重置时，重置本身零 IO）。
- 段落负载 = UTF-8 JSON 数组：段落可含任意 Unicode（含换行、NUL 包裹锚点标记），
  JSON 无转义歧义；单章体量小（最大章 ~100K 字 ⇒ ~200KB）解析可忽略。

#### 3. 导入即按章预热（2026-10-09 拍板）

`importFile` 尾部 `_scheduleWarmUp(record)`：后台逐章读原文写缓存，**绝不拖慢导入本身**；
失败静默——缓存是加速层，慢一点不碍事。

生命周期三件套（`LibraryRepository`）：

- `_warmUps`：每书一个在途任务（`bookId → Future`）；
- `_warmUpStopping`：停止旗，预热循环逐章让位即退；
- `pendingWarmUps`：收尾等待（测试 tearDown 删临时目录前必等，杜绝
  「后台还在写盘 → `FileSystemException: 目录不是空的`」竞态；5 个测试文件已接）。

**删书⓪ 预热收尾必须在删任何文件之前**（实证）：预热收尾原先放在「删副本文件」
之后，Windows 上预热仍持有原文件读句柄 → `PathAccessException errno = 32
另一个程序正在使用此文件`。修法 = ⓪（立旗 → `await _warmUps[bookId]` → 撤旗）
提到 `deleteBook` 最前，再删封面 / 副本 / 缓存 / 索引。这同时根治「删完又被预热
写回来」的删后孤儿（`LIB-06` 护栏钉住：预热在途立即删 → `outline/`、`chapters/`、
`structure/` 三目录必须为空）。

#### 4. widget 测试 fake 区 round 预算（基建实证，非产品缺陷）

删书链新增 ⓪ + ②c 真 IO 步数后，`shelf_page_test` 两个删书用例挂（BookCard 未消失 /
ReadingProgress 非 null），但 ②a②b③ 探针显示删除链**全部跑完**：

- `flutter_test` 的 `runAsync` fork `realAsyncZone`（`binding.dart:2269`），真 IO 的
  await 每步只在 pump 轮里推进约一步；
- `_settle`（`N` 轮 `runAsync(10ms)` + `pump(10ms)`）默认 40 轮 < 删书链步数
  ⇒ UI 帧没轮到刷新（`rounds: 200` 实验证实即通过）；
- 归因链：探针 → `git stash` 基线对照 → 配置 X 二分（format 层保留 / 书库 UI 全基线）
  → 单回填 WIP 复挂锁定 `library_repository` diff → rounds 实验定性。

修法 = 两个删书用例定点加深 `await _settle(tester, rounds: 100)`，**不改产品行为**。
生产环境真 IO 实时完成，无此预算问题。

#### 5. 变异判红验证（护栏须证能判红）

| 变异 | 判红用例 | 结果 |
|---|---|---|
| 移除 ⓪ 预热收尾整块 | `LIB-06：删书不残留缓存孤儿（预热在途立即删）` | **红** |
| ②c 不删两类缓存 | 同上 | **红** |
| 首写不截断 blob | `② 判据失效 → 整体重置；首写截断旧 blob` | **红** |
| mtime 判据恒真 | `① 判据任一不符 → miss` | **红** |

#### 6. 测试与验收

- `test/format/chapter_text_cache_test.dart` **14 条**（信封编解码 / 磁盘 store /
  `DartEpubSource` 接线含命中短路哨兵、故障当 miss）；
- `test/format/txt_outline_cache_test.dart` **25 条**；
- `test/library/library_repository_test.dart` **8 条**（含 LIB-06 护栏）；
- `test/ui/shelf_page_test.dart` **22 条全绿**（两个删书用例 `rounds: 100`）；
- `bash tool/test.sh fast` **471 条全绿**；`dart analyze lib test` 零问题。
- 五平台冒烟与全量测试为待拍板 gate（进度表挂账）。

### 2.82 空段章卡「载入中」与章标题样式改版（2026-10-09）

真机《枭臣》（校对版全本）「初次打开图书」章间卡着一条「第 N 章 · 载入中…」
不消失（楔子真身已在下方渲染）。负责人拍板「**可以只显示章节名**」；同日拍板
章标题样式「**左对齐、加粗、不需要横线分割；每章节之间添加空行隔离**」
（改 `TYP-04`「标题居中」旧口径）。

#### 1. 根因链（探针实证）

TOC 规则（legado `txtTocRule.json` 12 条，`正文(?!完|结)` 关键字）把孤行「正文」
切成独立章，正文区间只含空行 ⇒ `_splitParagraphs` 后 **0 段**（探针
`.scratch/probe_txt_empty_chapter.dart` 坐实 `[1] title="正文" paras=0`）。
旧真身判据含 `paragraphList.isNotEmpty` ⇒ 空段章**永驻**占位分支——把
「这一章没有正文」错当成「正文还没来」；`_registerWindowUnpaginated` 又跳过
空段章 ⇒ 永无分页条目，占位块永远换不成真身。**确定性缺陷**（每次开书都在）。

#### 2. 分页内核的空章契约（修复依据）

`PageBreaker.paginate([])` 返回**一张空页**（「每章至少一页，免得上层到处判空页」）；
`IncrementalPaginator` 空段**构造即完成**（`_complete = paragraphs.isEmpty`，`prime`
恒 true）；`PaginationScheduler._enqueuePrefetch` 不拒空段。⇒ 让空段章走完分页
管线拿天生空页，它就是「**只有章标题**」的真身块——与负责人拍板一致。

#### 3. 修法（`reader_page.dart` 三处，签名/翻页零改动）

- `_buildPageViews` 真身判据 = 「内容已就绪 + 页表已出」，**刻意不看段落数**；
- `_registerWindowUnpaginated` 不跳过空段章（登记即秒完成入缓存）；
- `_primeOpenSync` prevOk/nextOk 放行空段邻章（空段章有一张空页的定稿页表）。

空页使 `'1c'` 签名自然触发占位→真切换、翻页落页 0 显示章名。ListView 路径
（`_buildChapterItem`）占位判据只看 `content == null`，空段章天然渲染「标题 + 0 段」，
无此缺陷。

#### 4. 章标题样式改版（TYP-04 口径变更）

分页路径 `_headingWidget`：`Column[ SizedBox(gapTop=24)、Text(左对齐+bold)、
SizedBox(gapBottom=12) ]`（改前 `Text(center) + 6 + Divider(1) + 12`）；
ListView 路径同款。**测量与渲染同源**（`_headingHeightOf` 与 `_headingWidget` 共用
文本/样式/缩放与留白链常量）：标题占高 = 文本 24 + 24 + 12 = **60.0**（改前 43.0）。
章间空行隔离 = 每个标题块**顶部** 24 空档（改前两章几乎贴着）；题文呼吸 12 保留
（横线删了，题-文间距不塌）。牵连字面量同步：占位块高 95.8→112.8、
`scroll_stop_stability` 开书落位基线 43.0→60.0。

#### 5. 变异判红（护栏须证能判红；掩护关系如实记录）

| 变异 | 判红用例 | 结果 |
|---|---|---|
| 真身判据掺回 `paragraphList.isNotEmpty` | `empty_chapter` 两用例（`views[1]/[2].pages`） | **红** |
| 窗口登记跳过空段章 | `empty_chapter` 用例②（`views[2].pages` 空列表） | **红** |
| prevOk/nextOk 掺回段落数判据 | —— | 绿（**被窗口登记掩护**） |
| `_kHeadingGapTop` 24→0 | `heading_style`（高度链断言） | **红** |
| 标题 `TextAlign` 改回 center | `heading_style` | **红** |
| 加回 `Divider` | `heading_style`（结构 + findsNothing） | **红** |

掩护关系定性：`_registerWindowUnpaginated` 覆盖窗口全量（⊇ target±1），单撤
prevOk/nextOk **无用户可见回归**（终态断言无法区分）；其价值是**时序纵深**——
开书即把 ±1 邻章喂给 scheduler 并行预分页，不等窗口登记。故不设独立护栏用例。
隔离夹具注记：用例②须让空段章**离开 target±1**（`[60,0,0]` 尾部连排空段、
拖 −2500 停 px=2232 / prime index=0 / 窗口 [0,1]→[0,1,2]）；空段章矮使窗口尾近、
尾追加才触发（正常高章窗口尾远不触发——第一版 `[60,60,0]` 栽在这）。

#### 6. 测试与验收

- `test/reader/empty_chapter_test.dart` **2 条**（空段章只显章名 + 窗口登记路径隔离）；
- `test/reader/heading_style_test.dart` **1 条**（左对齐/加粗/无横线/章间空行/60.0 同源）；
- `placeholder_band_test` / `scroll_stop_stability_test` 字面量随留白链同步（+17）；
- `bash tool/test.sh reader` **450 条全绿**、`ui` 172 条全绿、`dart analyze lib test` 零问题；
- 一次并发跑曾挂 4 个既有时序用例（负载偶发，`-j 1` 与复跑全绿）——若复发参照
  ui 组「验收 `-j 1`」纪律。

### 2.83 阅读页点按收窄「九宫格中宫」+ `TapUpDetails.localPosition` 兜底陷阱（2026-10-10，`cfb8463`）

负责人拍板「**将阅读页划为9宫格，只有最中间的宫格位置，才能点击呼出菜单**」
——`TYP-09` 验收③「点正文切换 chrome」的口径再收窄：判定框 = `reader-chrome-toggle`
手势层的盒（与 `reader-content-area` 同框），按三分线划 3×3，**中宫
`[w/3, 2w/3] × [h/3, 2h/3]`（含边界）**的落点才呼出 / 收起，其余八格**无任何
效果**（既不呼出、也不收起——防阅读时侧边 / 角落误触把 chrome 翻出来）。

#### 1. `TapUpDetails.localPosition` 的构造兜底陷阱（SDK 源码实证）

`gestures/tap.dart`：`TapUpDetails` 构造 `localPosition = localPosition ??
globalPosition`（34-35 / 79-80 行），`TapGestureRecognizer.handleTapUp` 直接用
`up.localPosition`（746-751 行）⇒ **坐标链一旦不一致会静默退化成全局坐标**。
而测试窗原点即全局原点、两种写法恒等，这类错位测试照绿、真机才炸。故产品侧
**显式** `RenderBox.globalToLocal(details.globalPosition)` 把口径钉死在判定框上，
测试再用「系统 inset 把正文区推离窗口原点」的用例④钉死该口径（那种布局下两
坐标系不重合，误用全局坐标陷阱点立刻翻红）。

#### 2. 实现落点

- `_chromeToggleKey` 挂在手势层外的 `KeyedSubtree` 上——`GestureDetector` 的
  key 位已被测试锚点 `Key('reader-chrome-toggle')` 占用，且 KeyedSubtree 无自身
  RenderObject，落点即手势层的盒；
- `onTap: _toggleFullscreen` 改 `onTapUp: _onContentTapUp`，闸门只在 `inCenterCell`
  时调 `_toggleFullscreen`；
- 手势层**祖先**约束不变（`CNT-04` 链接 / `FMT-02` 图片缩放 / `AI-02` 长按划词
  各自赢竞技场后本回调不触发）⇒ 中宫判定不碰它们。

#### 3. 读数行第二入口保留 + 显形态覆盖实测

闸门只管**正文手势层**的落点；chrome UI（顶栏 / 控制条 / 常驻读数行）各有
自己的行为、不进九宫格判定。读数行（`reader-chrome-toggle-status`）是设计内的
**第二切换入口**（图片页中央点击被「点页全屏缩放」占用，靠它兜底；
`reader_inset_test` 已双向钉住），**必须保留**。探针实测（测试窗 800×600）：
chrome 显形态底部层上移，读数行 `Rect(0,471,800,497)`、控制条
`Rect(0,497,800,600)`、正文区 `Rect(0,0,800,572)` ⇒ 九宫格底排格心 y≈476.7
恰落在**读数行**上——那是「点 chrome UI」不是「点正文」，不属闸门口径。
用例②显形态段按实测 rect 剔出这类落点（顶栏 / 控制条 / 读数行），只对露在
正文上的 5 格断言「不收起」，并以 `hasLength(5)` 钉住覆盖关系（overlay 几何
变了会翻红提醒人工过目）。

#### 4. 变异判红（正常态先验绿；红断言即目标断言）

| 变异 | 判红用例 | 结果 |
|---|---|---|
| 闸门失效恒切（`if (true)`） | 用例②「非中宫落点不许唤出」（+③④边界/陷阱断言） | **红** |
| 闸门恒 false | 用例①「中宫点按应唤出顶栏 + 控制条」 | **红** |
| `globalPosition` 顶替 `globalToLocal`（模拟兜底退化） | **仅**用例④陷阱点「局部坐标在顶格」 | **红**（其余 3 绿——默认测试窗两坐标系恒等，正是此变异要的区分度） |
| 撤 x 下界 `dx >= w/3` | 用例③ 单轴探针 `Offset(265.7, 286.0)` | **红** |
| 撤 x 上界 `dx <= 2w/3` | 用例③ 单轴探针 `Offset(534.3, 286.0)` | **红** |
| 撤 y 下界 `dy >= h/3` | 用例③ 单轴探针 `Offset(400.0, 189.7)`（用例④陷阱点同批红） | **红** |
| 撤 y 上界 `dy <= 2h/3` | 用例③ 单轴探针 `Offset(400.0, 382.3)` | **红** |

掩护发现（首版测试的缺口）：用例③原「边界外 1px」探针是**对角线外双维同出**
（`(w/3−1, h/3−1)` / `(2w/3+1, 2h/3+1)`）⇒ 单撤一条界会被另一维挡住**判绿**、
4 条边界实际没钉住。补 4 个**单轴出界**探针（另一维留在中宫带内）后逐条判红。

#### 5. 测试与验收

- `test/reader/chrome_grid_tap_test.dart` **4 条**：中宫 toggle（唤出+收起）／
  八格无响应（含不收起，假绿排除一并做）／三分线含边界 + 对角与单轴出界探针／
  系统 inset 推离原点钉 `globalToLocal`；
- `FakeViewPadding` 是**物理像素**（`MediaQueryData.fromView` 走
  `EdgeInsets.fromViewPadding(view.padding, devicePixelRatio)` 折逻辑像素）：
  测试窗默认 DPR=3，逻辑 inset 24dp 须写 `top: 24 * tester.view.devicePixelRatio`，
  直写 24 只会得到逻辑 8（首版前提断言就栽在这）；
- `bash tool/test.sh reader` **454 条全绿**、`ui` 172 条全绿、`dart analyze lib test`
  零问题。

### 2.84 重复开关书「内容累积漂移」定案：采样↔落位共用行表口径成不动点（2026-10-10，`b924fcd`）

**症状**（真机视频）：重复打开退出同一本书，视口内容每轮回退 1~2 行、累积漂移
（与 `§2.80` 的「跳一整章」是两个独立缺陷——那次是布局塌陷改写章索引，这次
是**章内字符偏移**每轮复利）。

#### 1. 根因：采样与落位不是同一映射

「采样→落位→采样」构成一个闭环：重开书时 `offsetFor`（字符→像素）落位，落位后
postFrame 立即 `sampleNow()`（像素→字符）写回 `_chapterPos`。两条映射必须互逆
（不动点），否则每轮误差复利：

- **落位** `offsetFor` = 页顶 + `_lineTopInPage`（目标**行的行顶**，`§2.70` 行顶对齐）；
- **采样** `sampleNow()`（改前）= `sampleCharOffset` 的**页内字符均匀折算**
  （`start + fraction × (end - start)`）——把页内像素比例线性摊到字符区间，
  与行表几何无关。

均匀折算值永远落在「视口顶所在行的行内某处」，落位再按行顶回退 ⇒ 每轮
charOffset 减少 2~8 字、两轮可退两行（改前实测轨迹 **[168, 166, 158]**）。

#### 2. 修法：`_charStartAtY`（`_lineTopInPage` 的逆映射）

采样改为**行表口径**：视口顶所在行的**行首**字符（`PagedScrollerState._charStartAtY`）。
行块口径与 `_lineTopInPage` 严格对偶：行 i 的像素块 = `[top_i, top_i + height_i)`，
`top_i` 含跨段 `paragraphSpacing`（**段间距归下一行的块顶**——视口顶落在段间距
空白时语义上「从下一行开始读」，重开书只前移 ≤ 一段间距）；y 落在页内容之外
（页尾 / 跨页空白）→ `page.end`（= 下一页页首行首）。

**不动点性质**：对任意字符 c，`_charStartAtY(_lineTopInPage(c))` = c 所在行行首
⇒ 「采样→落位→采样」幂等、不跨行、误差不复利；程序化落位（行顶）后重采恒为
原值。`§2.70` 的行顶落位语义不动（落位侧 `_lineTopInPage` 一行未改）。

#### 3. 口径分工（`progress_pages.dart` 注释钉死）

`sampleCharOffset` 的均匀折算**保留**，但降格为 `chapterPos` ↔ 页码的**粗定位**
（无行表场景）；doc 注释明确「不要拿它做滚动采样」。`ScrollSample.withinPageFraction`
改为纯描述性字段（不参与字符换算）。`reader_page._scrollRemainderOf` 的 ±pageHeight
夹紧从「插值误差补偿」降为**防御性 clamp**（布局未变时恒不触发；布局突变后行表
换代、旧行表余量可能越界，夹住防甩飞）。

#### 4. 变异判红（正常态 24 条先验绿；红断言即目标断言）

| 变异 | 判红用例 | 结果 |
|---|---|---|
| ① `_charStartAtY` 行内均匀折算顶替行首 | 采样口径 118/128 期望值 + 往返幂等 + 跨段 30 | **红 5**（123/132/123≠118/27） |
| ② 跨段 `paragraphSpacing` 漏算 | 用例② 尾部单轴探针 158 处 | **红 1**（30→40 误判进 L4） |
| ③ 段间距归**上一行**块尾（口径反转） | 用例② 127 段间距顶断言 | **红 1**（30→20 归 L2 行首） |
| ④ `_lineTopInPage` 行中落位（破 §2.70） | 既有行顶落位几何断言 + 新往返用例 | **红 7**（40→54.5 / 367→381.5 / 425→439.5） |

②③互补：②只钉「间距要加」、③钉「加在谁头上」——段间距归属是口径裁决
（归下一行），只有 127（段间距顶）一个探针能区分，其余落点两口径同值。

#### 5. 测试与验收

- `test/reader/paged_scroller_test.dart` **+7 用例**（group「采样↔落位往返
  （§2.84：重复开关书不再漂移）」）：5 条真实行表（往返幂等 439 / 168 行首
  重采不跨行 / 584 行中取行首 / 三连环 [168,168,168]）+ 2 条**合成跨段夹具**
  （3 段 × 3 行 × 10 字、行高 29、段间距 8；真书页内恰无段间距的旧夹具
  parasA 覆盖不到跨段累加路径——**多段页才是漂移主现场**）；
- 既有 2 条采样期望值同步为行表口径（124→118、133→128），注释保留改前值
  供对照；
- `bash tool/test.sh reader` **460 条全绿**、`ui` 172 条全绿、`fast` 471 条全绿、
  `dart analyze lib test` 零问题。

#### 6. 教训：像素↔字符的每一对映射都必须共享同一几何

均匀折算看似「无害近似」，但只要它进闭环（采样→落盘→落位→采样）就变成
复利误差源。凡成对映射（本例 `sampleNow`/`offsetFor`；`§2.82` 占位语义同理）
必须**同一行表/同一几何**推导，并用「往返恒等」用例钉死——单测一侧不够。

### 2.85 开书闪动（任务 B）修法三条：放行门闸=精确落位+视口真身、冷缓存收口（2026-10-12，`0bd96db`）

**症状**（诊断存档 2026-10-10，视频 f095-096 等）：开书转场滑入过程中视口
跳一下 / 满屏「载入中…」占位带瞬间换血，纸张带着半成品滑进来。三条独立
机制链（`docs/研究-阅读页画布对照.md` §7 输入、§5.1 路线 A 拍板）：

1. **转场放行太早**——首帧上屏即放行，但此刻常是**估算落位**过渡帧，
   `_pendingLand` 二次精确落位的视口大跳发生在纸张滑入中；
2. **占位带满屏换血**——放行帧视口内残留 ≈96dp「载入中…」占位带，邻章
   「占位→真」换血的高度突变同样发生在滑入中；
3. **冷缓存**——`PaginationScheduler()` 随 State 新建，重开书冷缓存 →
   必然「先估后跳」，机制链①被制度性放大。

修法顺序按报告 §7（先 ①收益最大风险最小，再 ②，最后 ③），每条红灯测试
先行 + 变异判红 + 两段提交。

#### 1. 修法① 放行门闸=精确落位（`_signalOpenReady(requireLanded:)`）

分页模式「就绪」的定义升级为**目标语义坐标精确落位收敛**（`_positionConverged`），
估算落位只是过渡帧：

- `_open()` 放行改走 `_signalOpenReady(requireLanded: paged)`：未收敛时挂
  `_openGatePending` 不放行，转场继续按住；失败路径保持**必放行**（纸张不能
  永远停在屏幕右侧）；3s 兜底 `kReaderOpenHoldTimeout` 不动 = 时间防线。
- 收敛点补报 [`_checkOpenGate`]：`_primeOpenSync` 精确分支、`_syncPagedViews`
  的 `_pendingLand` 二次落位、`_pagedJumpTo` 空段章分支——每处收敛后必戳。
- **postFrame 复查型**（不是调用点当场判）：`_applyPagedViews` 的 setState 后
  布局未重建，当场读到旧视图；`_jumpPaged` 超域目标的帧末 clamp 也是
  postFrame 回调、注册更早——复查回调后注册后执行，读到的像素已是 clamp 后
  的「放行时刻现场」。`_openGateCheckScheduled` 单飞防回调堆积；复查不过
  保持挂起，等下一个戳点（`_syncPagedViews` 换视图后必戳）再查。

#### 2. 修法② 视口真身判据（`_viewportReal()`）+ 空段章收口

放行时刻（不只是收敛时刻）视口必须是**真身**：可见区间 `[pixels, pixels+vh)`
内没有占位带（`pages.isEmpty` 的窗口视图 = 占位带，区间
`[chapterTops[i], chapterTops[i]+headingHeight)`）。

- **空段章是真身**（一张空页、`pages` 非空）不挡放行——判据与 `_buildPageViews`
  同源，刻意不看段落数；
- **量不到现场**（scroller / vh 缺）时放行：宁可早放也不把门闸死等到 3s 兜底
  （「漏报就绪不卡死」优先）；
- **只管放行时机、不约束窗口形状**——`_repairReachable` 扩窗红线（窗口不
  加上界，见 `§2.80`）不变。占位换血「出视口」由此自动成立：放行前换血
  发生在按住期间（用户看不见），放行帧视口内已无带可换。

**`setWindow` no-op 陷阱**（本批实证踩坑）：`PaginationScheduler.setWindow`
在 `open()` 之前是 **no-op**（`_config` 只由 `open`/`_acceptConfig` 立起）。
`_pagedJumpTo` 空段章分支原先进 `_registerWindowUnpaginated()` 走 `setWindow`
登记——被静默吞掉 ⇒ 空段章永驻占位带 ⇒ `_viewportReal()` 恒假 ⇒ 门闸死等
3s 兜底。收口 = 空段章分支**必须走 `scheduler.open(href, paragraphs: [], …)`**
（空段构造即完成、`open` 突发即定稿入缓存），再登记 + `_checkOpenGate()`。
凡「调度器还没 open 就想改窗口」的路径都要先问一句有没有立起 `_config`。

#### 3. 修法③ 冷缓存收口（`PaginationSchedulerRegistry`）

`PaginationScheduler` 生命周期脱离 State：按 `bookId`（= `ImportService
.computeBookId(bytes)` 内容哈希，同 id 即同内容）**进程级驻留**整个调度器
（含 `PaginationCache(maxChapters: 5)` 与进行中任务/队列）。

- **驻留整个调度器而非只驻留 cache**：只留 cache 时 `_acceptConfig` 首开比较
  不出「换参」会 `cache.clear()` 清掉共享缓存；整机驻留则记得上次参数、
  `_acceptConfig` 短路，换参作废（图片尺寸走 `invalidateForImageSizes`）才有效。
- `_open()` 采纳时 `unfreeze()`：上一 State 若在翻页动画中被 dispose，冻结态
  会跨开书残留（`stepIdle` 有活不动）。
- `open()` 同章重开保留任务进度 ⇒ 重开书命中定稿页表、**一次精确落位**，
  机制链①③同时消失（红灯实证：改前开书②首见 `char=61` 估算值，改后
  `paged.prime … landed=true` 一次落位贴住目标 23301）。
- 删书暂不 `evict`（bookId 内容哈希，无同 id 复用风险；进程级驻留上限=书数）。
- **测试隔离**：`capTestTimeout()` 注册每用例 `setUp(sharedPaginationSchedulers
  .clear)`（全 testWidgets 文件惯例接入）——假书共用 bookId `testbook01`
  而内容各异，跨用例互命中旧页表会大面积误判红；「重入不丢缓存」只在用例内保留。

#### 4. 变异判红（正常态先验绿；红断言即目标断言）

| 变异 | 判红用例 | 结果 |
|---|---|---|
| ① `_viewportReal` 恒真 | 「放行门闸=视口真身」目标断言 | **红 1**（放行帧视口内残留 2 条 96dp 带，`Rect.fromLTRB(1125.6, 182.4, …)` / `(…, 295.2, …)`） |
| ② 空段章收口摘除（绕回 `setWindow`） | 「空段章开书」及时放行 | **红 1**（Expected false / Actual true：门闸挂到 3s 兜底） |
| ③ 退回 `PaginationScheduler()` 随 State 新建 | 「重开书秒落位」目标断言 | **红 1**（开书②首见 `char=61` ≠ 目标 23264~23344） |
| ④ 修法① 放行不看 `_positionConverged`（上会话复核） | 「放行门闸=精确落位」前提断言 | **红 1**（首帧上屏即放行，`isActive` false ≠ isTrue） |

#### 5. 测试与验收

- `test/reader/reader_open_transition_test.dart` +3 用例：「放行门闸=精确落位」
  （3000 段 + 进度 0.9 夹具，放行时采样贴住目标 ±40 字符、放行后视口不再跳）
  「放行门闸=视口真身」（首章压 2 段 ⇒ 第 2/3 章带落进首屏；逐轮盯放行帧
  当场量 + `sawBand` 前提防空转绿）「空段章开书」（防回归护栏）；
- `test/reader/reopen_pagination_cache_test.dart` +1 用例（重开书首见即目标位）；
- `test/test_config.dart`：`capTestTimeout()` 挂注册表清理（测试隔离）；
- `bash tool/test.sh reader` **464 条全绿**、`ui` 172（`-j 1`）、`fast` 471、
  `dart analyze` 零问题。

#### 6. 教训

- **放行时机是一个「复合判据」的输出**：收敛、视口真身、时间兜底三层，任何
  单层（首帧 / 收敛 / 兜底）都会把某种半成品送进滑入窗口。判据要 postFrame
  读「放行时刻现场」，不能读调用点的陈旧状态。
- **登记类 API 的静默 no-op 是门闸类判据的天敌**：`setWindow` 吞掉未 `open`
  的登记、表现为「判据恒假死等」而不是报错。凡「先登记后判」的链路，用例
  必须覆盖「登记生效」本身（空段章护栏即为此而设）。
- **缓存驻留要驻留「记得参数的那个整机」**：只留数据（cache）不留状态
  （`_config` 比较基线）会让「换参作废」逻辑反而清掉想留的东西。

### 2.86 玻璃态材质对齐参考图：`GlassMaterial` 单一事实源 + 三处控件换真玻璃（2026-10-12）

**症状**（负责人 2026-10-12 批，参照 HyperOS 主题商店的搜索栏 / 按钮 / 底部
导航栏截图与录屏）：「玻璃态效果没想象中那么好」。

#### 1. 根因（三条，均已读库源码 `1.7.0` 实证，非观感推测）

参考图的玻璃是**三层结构**：磨砂模糊（内容透出但不可读）+ 增白纱罩（表面亮白）
+ Fresnel 边缘高光。MReader 三层全缺，且缺的原因各不相同：

| # | 病灶 | 实证依据 |
|---|---|---|
| ① | **全 app 未挂 `GlassTheme`** | `main.dart` 的 `LiquidGlassWidgets.wrap` 只传了 `brightnessResolver`，未传 `theme` ⇒ 所有玻璃面吃库默认材质（`GlassThemeVariant.light`：玻璃色 12% 冷蓝白 / blur 5 / 环境光 0.15 / thickness 12），偏「清玻璃」，离参考图的强磨砂亮面很远 |
| ② | 搜索胶囊 / 分组 chips **根本不是玻璃控件** | 二者是 `surfaceContainerHighest` α0.6 纯色填充 + `outlineVariant` 描边的普通 `Container` / `FilterChip`——无模糊、无增白、无边缘光。纯色背景下就是灰 pill |
| ③ | 底栏是真玻璃，但**不吃主题** | `GlassTabBar.bottom` 用私有预设 `kBottomBarGlassDefaults`（`tab_bar_bottom_internal.dart:47`）：blur 3 / 折射 1.59 / 玻璃色 α0.24。不显式传 `settings` 就永远是这一套——**挂了主题也白挂** |

#### 2. 修法：`GlassMaterial` 材质单一事实源（两级）

新增 `lib/ui/glass_material.dart`，与既有的 `OverlayStyle`（浮层参数唯一事实源）
同一思路。**为什么必须是两级而不是一套**：

- **主题级**（[GlassThemeSettings]）：经 `GlassTheme` 全局生效，覆盖「既无显式
  settings 也无父玻璃层」的玻璃面——各页顶栏内的玻璃按钮、浮层
  （`GlassSheet` / `GlassDialog` / `GlassToast`）。⚠️ 该类型**不含
  `whitenStrength`**（`glass_theme_settings.dart` 的 `applyTo` 原样透传 base
  值）——增白纱罩在主题级**表达不了**。
- **控件级**（完整 [LiquidGlassSettings]）：给显式传 `settings:` 的控件。与主题值
  **逐项一致**，只多 `whitenStrength`（亮 0.16 / 暗 0.06）。

参数取值（亮 / 暗）：磨砂 blur 9 / 8、玻璃色亮白 α0.18 / α0.10、环境光 0.2 /
0.06、thickness 16 / 14、折射 1.2（库默认 1.59 偏「厚玻璃」，参考图是薄而亮）、
色散 0.01。暗模式 `whitenGated: false`——按亮度门控在近黑背板上会把增白整块归零。

**质量档位链（`UI-05` / `UI-06`）刻意不受影响**：主题 `quality` 恒 `null`，解析
继续走「控件显式 → 隔离作用域 → 主题 → 控件类默认」，运行时档位仍由
`GlassRuntime` / `GlassScope` 说了算。契约测试对此单钉一条
（`data.light.quality` isNull）。

#### 3. 三处控件换真玻璃

- **书架搜索胶囊**：`Container(α0.6 + 描边)` → `GlassButton.custom`（高 36、
  `LiquidRoundedRectangle(borderRadius: 18)` = stadium、`useOwnLayer: true`、
  `alignment: centerLeft`）。**几何契约一字未动**：仍靠左、仍铺满、仍留右侧两按钮
  的位置（`centerTitle: false` + 原 `Expanded`）；`Key('shelf-search-entry')` 保留。
  ⚠️ 描边**随容器一起消失**——`GlassButton` 没有 `border` 参数，而玻璃的 Fresnel
  边缘光本身就承担了「把可点控件从磨砂区里分出来」的职责（同 §2.80 的判据）。
- **分组 chips**：`FilterChip` → `GlassChip`，选中态给亮底（参考图「选中 = 实底
  亮胶囊」：亮模式白 α0.85、暗模式白 α0.22）。
- **书库搜索页输入框**：裸 `TextField` → `GlassTextField.search`，与胶囊同一套
  视觉语言。
- **浮动底栏**：形态不变（2026-09-28 拍板的 iOS 26 悬浮胶囊，负责人 2026-10-12
  重申「保持悬浮胶囊、只升材质」），只按亮度透传控件级 `settings`。

#### 4. `useOwnLayer: true` 与滚动区档位（两个必踩的库行为）

- **`useOwnLayer` 不是优化而是前提**：分组模式下父 `AdaptiveLiquidGlassLayer`
  会**忽略 per-widget settings**，控件会退回父层材质。顶栏内无父玻璃层 ⇒ 必须
  自带层，否则显式 `settings` 静默失效（症状与 §2.85 的 `setWindow` no-op 同类：
  API 没报错，行为却没变）。
- **`GlassAppBar` 内部把整条面包进 `GlassIsolationScope(defaultQuality: premium)`**
  （`glass_app_bar.dart:410`）。chips 行是横向 `SingleChildScrollView`，
  `UI-04` 红线**禁 premium 进滚动区** ⇒ chips 必须显式传
  `quality: GlassScope.qualityOf(context)`，否则被作用域提成 premium。契约测试
  钉 `chip.quality` `isNot(GlassQuality.premium)`。

#### 5. 交互：主题级一次性去「放大」

2026-09-29 拍板「移除放大特效」时只落在导航栏（`GlassInteractionBehavior
.glowOnly`）与浮层（`OverlayStyle.interactionScale = 1.0`）两处；库其余交互控件
（`GlassButton` / `GlassChip` / `GlassTextField`）的按下膨胀仍吃各自硬编码默认
（按钮按最长边 +17pt、chips 1.03）。本批在主题级钉
`GlassMaterial.interaction = GlassInteractionSettings(interactionScale: 1.0,
stretch: 0.15)`，全线一致；`stretch: 0.15` 保留一丝拖拽果冻感（0 = 完全刚体）。

#### 6. 测试与验收

- 新增 `test/ui/glass_material_test.dart`（8 条）：常量字面量（两档主题级 + 交互）
  / `themeData` 组装（含 quality 恒 null）/ `settingsFor` 亮度分流（整对象相等）/
  `GlassNavBar` 透传到 `GlassTabBar.settings`（含「不得回落 `kBottomBarGlassDefaults`」
  的反向断言）。
- 更新 `test/ui/shelf_page_test.dart`：`_chipLabels` 改读 `GlassChip.label`；
  搜索胶囊样式断言从 `BoxDecoration`（α0.6 + 1px 描边）改为 `GlassButton` 的
  材质参数；**新增**「分组 chips = `GlassChip` + 显式 standard 档位」用例。
- `dart analyze` 零问题；`test/ui` **175 条通过**（`-j 1`）、`test/reader` 全绿。
  ⚠️ `app_theme_test.dart`「正文默认口径与 TYP-01 一致（字号 18）」一条红——那是
  负责人工作区里**未提交**的 `defaultFontSize: 18 → 20` 改动引起，与本批无关
  （`git stash` 对照实证）。

#### 7. 教训

- **薄封装没暴露的库参数会以库默认值静默生效**——与 §2.49（`showSheet` 未透传
  `interactionScale`）、§2.85（`setWindow` 未 `open` 时 no-op）同族。底栏这条更隐蔽：
  它连**主题**都不吃，只认自己的私有预设，所以「挂了 `GlassTheme` 却没变」很容易
  被误判成主题没生效。凡「传了参数但视觉没动」，先查该控件的 settings 解析链，
  再怀疑主题。
- **「像玻璃」不等于「是玻璃控件」**：α0.6 半透明色块在任何磨砂背景上都能骗过
  肉眼（本批的搜索胶囊与 chips 就是这样长期存在的），但它没有模糊、没有增白、
  没有边缘光。视觉评审提「质感不对」时，先确认控件类型，再调参数。

### 2.87 底栏指示块形变：pinch / 静置磨砂，**不动**「移除放大」口径（2026-10-12）

**背景**：负责人要求复刻参考图（HyperOS 主题商店）里切换 tab 时的液态形变，
并追问「能不能不用 `liquid_glass_widgets`」。逐帧抽视频（`imageio-ffmpeg`，
592×1280@24fps）确认参考图的招牌动效 = **指示块横向拉宽 + 边缘向内 pinch +
静置带磨砂**。

#### 1. 先纠正一处误判（方法论教训）

第一次只看**裁剪放大**的底栏局部，误判成「贴底通栏」，还据此向负责人提了
「与悬浮胶囊矛盾」的错误问题。整屏帧一看即证伪：左右有明显留白、下方能透出
内容 ⇒ **悬浮胶囊**，当前形态本就正确。

**教训**：局部放大图会丢掉「与画布边界的关系」，而**形态判断恰恰依赖这个关系**。
判断悬浮/贴底/通栏必须看整屏（或至少带上画布边缘的上下文）。

#### 2. 不自研：读源码后的成本结论

| 事实 | 依据 |
|---|---|
| 库 57934 行**纯 Dart**、零原生代码、MIT | `pub.flutter-io.cn/liquid_glass_widgets-1.7.0`，无 `.kt/.java/.swift/.cc` |
| 核心是**自研 GLSL 片段着色器** 2574 行 | `shaders/*.frag + *.glsl`，`liquid_glass_render.frag` 686 行做折射 / 色散 / Fresnel |
| 项目真实接触面极窄 | 8 类widget；`glass_runtime`(240) + `glass_scope`(124) 完全解耦，`glass_kit` 有效代码约 300 行 |
| 已消化的坑有 9 + 11 处 | PRD §11.4九条限制 + tech-usage 11 个玻璃专项小节 |

自研可行，但要自己维护 2500 行 GLSL + Impeller / Skia 双后端差异，换来的**不是
更好看**（参考图那一档 ≈ iOS 18 风格，`BackdropFilter` + 简单形变即可）——**结论
继续用库**。

#### 3. 关键区分：指示块形变 ≠ 按下缩放（两套独立机制）

这是本节最要紧的一条。参考图要的形变**完全不在** `interactionBehavior` 管辖内：

| 观感 | 库参数 | 消费点 | 本项目口径 |
|---|---|---|---|
| 整条胶囊**被按下**时膨胀回弹 | `interactionBehavior`（`full` 含弹簧缩放） | `tab_bar_bottom_layout.dart:390` 据此把 `interactionScale` 钉 1.0 | **保持 `glowOnly`**（2026-09-29 拍板，不撤销） |
| 指示块**切换时**拉宽 + 边缘 pinch | `indicatorPinchStrength`（库默认 **0.4**） | `animated_glass_indicator.dart:123-133` + `copyWithPinch` | **0.75** |
| 指示块**静止时**磨砂 | `innerBlur`（库默认 **0.0** = 关闭） | `animated_glass_indicator.dart:135-141`（frost at rest） | **0.6** |

⇒ **「移除放大」的拍板不需要撤销**：负责人当时指的是「按下时整个胶囊膨胀」，
与「切换时指示块形变」是两件事，两者同时成立正是库文档推荐的组合。新增契约
用例专门钉这条互不干涉（改形变不得回潮 `hasScale`）。

`indicatorPinchStrength` **不取 1.0**：库 doc 明确 pinch 幅度受 `thickness` 约束，
满档时指示块边缘会啃进图标；0.75 是「看得见的液态」与「不啃图标」的折中。

#### 4. 一处**不可调**的库设计（不暴露无效开关）

`GlassTabBar.bottom` 工厂**不透传 `springDescription`**（逐参数转发可证，
`glass_tab_bar.dart:240-296`）——指示块回弹弹簧由库固定为 iOS 26 默认 jelly
弹簧。薄封装**不暴露**该字段（暴露即无效开关），注释写明原因。

#### 5. 变异判红

| 变异 | 判红用例 | 结果 |
|---|---|---|
| ① `innerBlur` 不透传（写死 0.0） | 「pinch 0.75 / innerBlur 0.6」 | **红 1**（Expected 0.6 / Actual 0.0） |
| ② `pinch` 退回库默认 0.4 | 同上 + 「参数可由调用点覆盖」 | **红 2**（0.75/0.4；覆盖值被忽略） |
| ③ `interactionBehavior` 回 `full` | 「glowOnly 不回潮」+ 原触摸反馈用例 | **红 2** |

三条均**单轴出界**、正常态先验绿。

#### 6. 教训

- **「参考图要液态形变」不等于「要撤销移除放大」**：动效分区要看它挂在**哪个
  widget 的哪个参数**上，而不是按观感归类。同名「形变」在库里可能是两套东西。
- **裁剪放大图会骗人**：形态判断依赖与画布的关系，局部图必假。
- **薄封装暴露参数前先查工厂是否转发**：本节 `springDescription` 就是
  「主构造器有、`bottom` 工厂不透传」的例子——暴露了就是无效开关。
