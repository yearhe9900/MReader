# 阅读M（MReader）· 技术使用记录

> **本文件用途**：给项目负责人看的「**这次改动用了什么技术**」速查表——扫一眼就知道某批次引入了哪些技术、写在哪、什么版本。
> **它不是架构文档的替代品**：技术**实现细节**以 `docs/architecture-rust-integration.md` 为准；**功能契约**以 `docs/PRD.md` 为准。
>
> **维护规则**：每完成一个任务批次，在 §2 追加一节，并同步更新 §1 总览表。版本号一律取 `pubspec.lock` / 构建配置里的**实际锁定值**，不写「大概/最新」。

---

## 1. 当前技术栈总览

### 1.1 语言与框架

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| Dart | 3.13.4（随 Flutter 3.47.5-stable） | 应用与解析全部用 Dart，无 JS/WebView | 工程初始化；**2026-09-24 由 3.12.2 升级** | `pubspec.yaml`（`environment.sdk: ^3.13.0`） |
| Flutter | 3.47.5-stable（**2026-09-24 升级**；原「3.44.9 已锁定不升级」随之解除） | 纯自绘 UI（不走 WebView / foliate-js） | 工程初始化；升级缘由见 §2.37 | `pubspec.yaml`、各平台目录 |
| Material 3 | `useMaterial3: true` + `colorSchemeSeed: Colors.indigo` | 主题三态接线（浅色 / 深色） | M1-T01 | `lib/app.dart` |
| flutter_lints | 6.0.0 | 静态检查规则集 | 工程初始化 | `analysis_options.yaml`、`pubspec.yaml` |

### 1.2 状态管理

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| 自研监听回调（**非** `ChangeNotifier`） | 内置 | 跨页面共享设置状态：`List<void Function()>` + `addListener` / `removeListener`，页面在 `initState` 订阅、`dispose` 退订、回调内 `setState` | M1-T01 | `lib/settings/settings_store.dart`、`lib/app.dart` |
| 构造注入（**非**全局单例） | 内置 | 实例在 `main()` 显式创建并注入 `MReaderApp`；`isLoaded` 作为显式初始化标志 | M1-T01 | `lib/main.dart`、`lib/app.dart`、`lib/settings/settings_store.dart` |
| 无第三方状态管理库 | — | 不引 Provider / Riverpod / Freezed，不用 `build_runner`（见 PRD §15.5） | M1-T01 | — |

### 1.3 持久化与存储

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| `AtomicFile` 原子写入 | 自研（`dart:io` + `utf8`） | **全工程落盘唯一入口**：写同目录临时文件 → `flush: true` → 轮转式替换 | M1-T01 | `lib/storage/atomic_file.dart` |
| **轮转式替换**（应对 Windows） | 自研 | 不假设 `rename` 能覆盖已存在目标：旧 `.bak` 先删 → `target` → `.bak` → `tmp` → `target`（两步目标位置都不存在，POSIX / Windows 行为一致），失败时从 `.bak` 还原 | M1-T01 | `lib/storage/atomic_file.dart` |
| 进程内按路径串行化 | 自研（`Map<String, Future>` + `Completer`） | 同一文件并发写不交错；**不引锁库**；跨进程不在保证范围 | M1-T01 | `lib/storage/atomic_file.dart`（`_tails` / `_synchronized`） |
| `JsonStore` 读写与四态回退 | 自研（`jsonEncode` / `jsonDecode`） | ok → 返回；missing 且有 `.bak` → 回退并**自愈**；missing 无 `.bak` → `null`；corrupt → 先另存 `.corrupt`（不静默丢弃）再回退 | M1-T01 | `lib/storage/json_store.dart` |
| `FileSecureStore` 凭据降级实现 | 自研（复用 `JsonStore`） | 明文 JSON 承载凭据，`isSecure = false` + 中文 `securityNotice` 供 UI 提示（对齐 `DATA-02` ③）；**不写任何 print**、异常不带凭据值 | M1-T01 | `lib/platform/secure_store_io.dart` |
| `CoverStore` 封面字节存储 | 自研（复用 `AtomicFile`） | 封面字节落 `covers/`（按 `bookId` 命名）；同目录另生成 `.thumb.png` 缩略图（`dart:ui` 仅能编码 PNG）；孤儿 GC 连带 `.tmp` / `.bak` / `.corrupt` 兄弟文件与 `.thumb.` 一并清理 | M1-T05 | `lib/meta/cover_store.dart` |
| `BookIndex` / `ImportService` 书库索引与导入 | 自研（复用 `JsonStore` / `AtomicFile`；`crypto` 3.0.6） | `library/index.json` **逐条降级**（单条损坏跳过）；导入管道用 SHA-256 前 16 位内容摘要判重后复制副本 | M1-T03 | `lib/library/book_index.dart`、`lib/library/import_service.dart` |
| `ProgressStore` 阅读进度存储 | 自研（复用 `JsonStore` / `AtomicFile`） | **每本书记一个** `progress/<bookId>.json`（bookId 白名单防路径穿越）；bookId 直接作文件名，删书连带清理 | M1-T04 | `lib/reader/progress_store.dart`、`lib/reader/reading_progress.dart` |
| 不引 `shared_preferences` / `sqflite` | — | 自研 JSON + 原子写入已够用（PRD §15.4） | M1-T01 | — |

### 1.4 平台能力

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| `path_provider` | 2.1.6（`path_provider_android` 2.3.1） | 取应用私有数据目录（`getApplicationSupportDirectory()`） | M1-T01 | `lib/platform/app_paths.dart` |
| `AppPaths` 抽象 + `PathProviderAppPaths` 实现 | 自研 | 业务层**只依赖接口**；路径经启动时显式注入；根目录下 `mreader` 子目录，`dataDir()` 幂等缓存 | M1-T01 | `lib/platform/app_paths.dart`、`lib/main.dart` |
| `SecureStore` 抽象 | 自研 | `read` / `write` / `delete`（幂等）/ `containsKey` + `isSecure` / `securityNotice`；系统密钥库实现留 M4 | M1-T01（接口） | `lib/platform/secure_store.dart` |
| `path` | 1.9.1 | 包内路径拼接与 `../` 归一化（posix 语义） | 工程初始化 | `lib/epub/epub_parser.dart` |
| `dart:io` | 内置 | 文件 / 目录读写；**仅限平台层与存储层**，解析链路保持可纯 Dart 单测 | M1-T01 | `lib/storage/*`、`lib/platform/*` |

### 1.5 UI / 玻璃态

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| `MaterialApp.builder` + `Material(type: MaterialType.transparency)` | 内置 | 统一补一层透明 Material 祖先，避免玻璃组件库下文本渲染成黄色双下划线（PRD §11.4 已知限制） | M1-T01（地基） | `lib/app.dart` |
| `liquid_glass_widgets` | 1.7.0（**精确锁定，不带 `^`**） | 玻璃视觉（导航层玻璃 + 浮层）；`main()` 内预热着色器 | M1-T08 | `lib/ui/glass_kit.dart`、`lib/ui/glass_scope.dart`、`lib/main.dart` |
| `cupertino_icons` | 1.0.9 | PRD §11.4 列为**强制依赖**：玻璃图标依赖它，从 pubspec 移除会渲染成 `?` | M1-T08 | `pubspec.yaml`（无代码落点） |
| `GlassKit` 档位出口 + `OpaqueContentSurface`（自研） | 内置 | `UI-04` 内容层不透明的**唯一出口**；`premium` 禁入滚动区；固定表面不手传档位 | M1-T08 | `lib/ui/glass_kit.dart` |
| `GlassScope` 作用域（自研） | 内置 | 有效亮度 / 质量档位 / 玻璃隔离范围收敛为 `InheritedWidget` | M1-T08 | `lib/ui/glass_scope.dart` |

### 1.6 格式解析

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| `archive` | **4.3.0**（精确锁定，不带 `^`） | zip 解压 EPUB；测试里用 `Archive` + `ZipEncoder` 现造样本 | 工程初始化；**2026-09-24 由 3.6.1 迁移**（见 §2.24）。⚠️ **2026-09-28 更正**：原写「3.6.1（**锁 3.x**：4.x 改了 `ArchiveFile` API）」**已作废**——`pdfrx_engine` 硬要求 `archive ^4.x`，不存在「pdfrx 2.6.x + archive 3.x」组合 | `lib/epub/epub_parser.dart`、`lib/epub/zip_paths.dart`、`test/widget_test.dart`、`test/format/epub_builder.dart` |
| `xml` | 6.6.1 | 严格解析 `container.xml` / OPF / `toc.ncx` / `encryption.xml` | 工程初始化 | `lib/epub/epub_parser.dart`、`lib/epub/epub_toc.dart`、`lib/epub/xml_util.dart` |
| `html` | 0.15.7 | 宽松解析脏 XHTML（正文抽取 + EPUB3 `nav.xhtml`） | 工程初始化 | `lib/epub/section_extractor.dart`、`lib/epub/epub_toc.dart` |
| `charset` | 2.0.1 | GBK / GB18030 解码兜底 | 工程初始化 | `lib/epub/text_codec.dart` |
| `MReaderFormatException` + `kFormatErrorMessages`（自研） | 内置 | 格式错误码 -> 面向用户中文的**唯一来源**（`RD-05`；为 `RUST-04 ②` 的口径一致铺路） | M1-T02A | `lib/format/error_messages.dart` |
| `BookSource` 统一抽象 + 分发点（自研） | 内置 | §7.1 抽象（`load`/`chapters`/`content`/`capabilities`/`search`/`totalCharCount`）+ `BookRegistry`/`sniffFormat`/`openBook` | M1-T02A | `lib/format/book_source.dart`（纯类型）、`lib/format/book_registry.dart`（分发点）、`lib/format/dart_epub_source.dart`、`lib/model/chapter.dart`、`lib/model/chapter_content.dart` |
| `detectEncodingName` 编码名缝（自研） | 内置 | `NF-C4` / §15.6.2：把「探测编码名」与「按名解码」拆开——Rust 首版只替换探测 | M1-T02B | `lib/epub/text_codec.dart` |
| `DartTxtSource` 纯 Dart TXT 源（自研） | 内置 | 照译参考实现 `TextFile.kt` 分章算法（`RD-02`）：规则择优 / 规则分章 / 10KB 分块兜底 | M1-T02B | `lib/format/dart_txt_source.dart` |
| `CbzSource` / `CbrSource` 图片页压缩包源（自研） | 内置 | CBZ 每图片页一章（自然序、首页图封面）；CBR 按 Q5 退化「导入即拒绝」+ `RarExtractor` 注入升级缝 | M2b-T02 | `lib/format/cbz_source.dart`、`lib/format/cbr_source.dart`、`lib/format/image_pages.dart`、`lib/format/natural_sort.dart`、`lib/platform/rar_extractor.dart` |
| `file_picker` | 8.3.7 | 选择本地 EPUB / TXT；`withData: true` 走 bytes，避免 `dart:io` 进入解析链路 | M1-T01 | `lib/main.dart` |

### 1.7 构建工具链

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| Android Gradle KTS | AGP **9.0.1** | Android 构建配置（`google()` + `mavenCentral()`） | 工程初始化 | `android/build.gradle.kts` |
| `com.android.build.api.dsl.CommonExtension`（新 DSL） | AGP 9.0.1 | 插件模块 `compileSdk` 提升用；**AGP 9 已移除 `BaseExtension`**，且新 DSL 不再带泛型参数、`compileSdk` 是可读写 `Int?` | Android 构建修复 | `android/build.gradle.kts` |
| `subprojects { afterEvaluate { … } }` | Gradle | 逐个子工程检查，**仅当 `compileSdk < 36`** 时提升到 36（不做无条件覆盖） | Android 构建修复 | `android/build.gradle.kts` |
| Rust 工具链（`rustup` / `cargo` 1.89.0） | 已装，**未接入构建** | 规划中的可选加速层 | 计划 M3.5 | PRD §15.6.5 |
| `flutter_rust_bridge` + `Cargokit` | 计划锁 2.13.0 | 规划中的 Rust 桥接与构建集成 | 计划 M3.5（未引入） | PRD §15.4 / §15.6.5 |

### 1.8 测试与文档工具

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| `flutter_test` | 内置 | `test` / `testWidgets` / `pumpWidget` / `addTearDown`；含首页冒烟测试 | M1-T01 | `test/storage/atomic_file_test.dart`、`test/widget_test.dart` |
| `Directory.systemTemp.createTemp` | 内置 | 每个用例独立的临时目录做真实 IO 断言 | M1-T01 | `test/storage/atomic_file_test.dart` |
| Python fixture 脚本 | 系统 Python | 生成脏 EPUB 样本与基线比对（`make_fixtures.py` / `analyze_fixtures.py`） | 工程初始化 | `test/fixtures/*.py`、`test/fixtures/baseline.json` |
| 程序化点数脚本 | 自研 | PRD 表头计数，正则 `[A-Z][A-Z0-9]*-\d{2}`（不用 `[A-Z]+-`，会漏整张 `P2-*` 表） | 文档批次 | `docs/PRD.md` 表头 |
| 确定性重放改稿 + 命中数断言 | 自研 | 批量改文档时每处替换断言「命中次数 = 1」，防并行编辑互相覆盖 | 文档批次 | 临时脚本（不入库） |
| 交付前格式自检 | 自研 | UTF-8 **无 BOM** / LF 行尾 / 以换行结尾 | 文档批次 | `docs/*.md` |
| Mermaid | `classDiagram` / `sequenceDiagram` | 架构图（Rust 层类图与序列图） | 架构文档批次 | `docs/class-diagram.mermaid`、`docs/sequence-diagram.mermaid` |
| Keep a Changelog（简化式） | — | 根目录更新日志格式 | 文档批次 | `CHANGELOG.md` |

---

## 2. 按批次的技术使用记录

### 2.0 工程初始化与早期原型（历史，代码已删除）

| 项 | 值 |
|---|---|
| 任务 | 工程初始化 / 书源解析原型 |
| 提交 | `daadf7a`（初始化）→ `a8d329b` / `a306293` / `c5fe26c` / `d694440` / `e2ebe1b` / `4ea6d10`（书源原型与修复） |
| 日期 | 2026-09-20 |
| 一句话目标 | 建 Flutter 工程、锁定版本、跑通 EPUB 解析与阅读页 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| Flutter 工程脚手架 + 五平台目录 | 项目基线 | `pubspec.yaml`、`android/`…`linux/` | `environment.sdk: ^3.13.0` 对齐 Flutter 3.47.5 内置 Dart（原 `^3.12.2` / 3.44.9，2026-09-24 升级） |
| 依赖版本锁定 | 稳定性 | `pubspec.yaml` / `pubspec.lock` | `archive` **4.3.0**（2026-09-24 由 3.x 迁移，见 §2.24；原「锁 3.x（4.x 改 API）」已作废）；`file_picker` / `xml` / `html` / `charset` / `path` |
| Dart 包结构（`lib/` 分层） | 解析链路可单测 | `lib/epub/`、`lib/model/`、`lib/ui/` | 业务层不 import `dart:io` 目录 API |

> 该批的**书源原型代码已由 M0-T02 删除**（见 §2.2）；此处仅留技术谱系记录。

### 2.1 M0-T01 — Web 工程清理

| 项 | 值 |
|---|---|
| 任务 | M0-T01（PRD `Q23`） |
| 提交 | `2635571` |
| 日期 | 2026-09-20 |
| 一句话目标 | 平台收敛为五平台，清除 Web 相关工程目录与措辞 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 整目录删除 `web/` | 放弃 Web 平台 | `web/`（7 文件：`index.html` / 图标 / `manifest.json`） | 删目录比逐个删文件更彻底 |
| 依赖注释与平台措辞同步 | 文档一致性 | `pubspec.yaml`、`README.md`、`lib/main.dart` | 只动注释，不改依赖集 |

### 2.2 M0-T02 — 书源原型删除

| 项 | 值 |
|---|---|
| 任务 | M0-T02（PRD `Q24`） |
| 提交 | `236cead` |
| 日期 | 2026-09-21 |
| 一句话目标 | 书源功能已排除出产品范围，删除原型代码与测试 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 大规模删除 + 入口收口 | 减少维护面 | 删 `lib/source/**`（11 文件）、`lib/ui/source/**`、7 个测试；改 `lib/main.dart` | 共 −7496 行；形制知识已固化到架构文档 §A.4，删代码不丢知识 |
| 残留引用核查 | 确认无悬挂引用 | 全仓 `git grep`（`lib/source` / `ui/source` / `dart:html`） | 0 命中才算闭环 |
| 残留样本补删 | 收尾当年漏删的调研样本 | `test/fixtures/shenshi.json` | 该文件是 legado 书源原文（`bookSourceName` / `ruleBookInfo` / `exploreUrl` 全套字段），由 M0 `a8d329b` 引入、`236cead` 删原型时**漏删**（当时的删除清单只列了 `lib/source/**` 与测试文件），且全仓零引用 → 本轮 `git rm` 补上；**教训**：删功能时把 `assets` / `fixtures` / 脚本一起过一遍，别只跟着源码目录走 |

### 2.3 M1-T01 — 工程骨架与平台能力抽象

| 项 | 值 |
|---|---|
| 任务 | M1-T01（PRD `DATA-01` / `DATA-02` / `TYP-03` / §15.1） |
| 提交 | `8ed83f3`（存储）→ `6a63b59`（平台抽象 + 设置）→ `dbf3bfa`（应用骨架） |
| 日期 | 2026-09-21 |
| 一句话目标 | 立起「一切落盘走原子通道、一切平台能力经抽象注入」的地基 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `AtomicFile` 原子写入 | 全工程落盘唯一入口 | `lib/storage/atomic_file.dart` | 临时文件与目标**同目录**（避免跨设备 rename 失败）；`writeAsBytes(flush: true)` 后才替换 |
| **轮转式替换**（Windows 关键坑） | 让替换在 POSIX / Windows 行为一致 | 同上（`_commit`） | Windows 上 `File.rename` **不能覆盖已存在目标**；故先删旧 `.bak` → `target`→`.bak` → `tmp`→`target`；替换失败时从 `.bak` 还原 |
| 进程内按路径串行化 | 同文件并发写不产生半截文件 | 同上（`_tails` + `_synchronized`） | `Map<String, Future>` 链式等待 + `Completer` 放行；**不引锁库** |
| `JsonStore` 四态回退 | 读取失败可回退上一份有效副本 | `lib/storage/json_store.dart` | 损坏文件**先另存 `.corrupt`**（不静默丢弃，便于排障）再回退；回退成功后自愈目标 |
| `path_provider` 封装为 `AppPaths` | 业务层不直接依赖插件 | `lib/platform/app_paths.dart` | `abstract interface class AppPaths` + `PathProviderAppPaths`；`getApplicationSupportDirectory()` 下再建 `mreader/` 子目录，`dataDir()` 幂等缓存 |
| 平台能力**构造注入** | 可替换、可测试 | `lib/main.dart` | `WidgetsFlutterBinding.ensureInitialized()` → 建 `AppPaths` → 取目录 → 建设置服务 → `await load()` → `runApp` |
| `SecureStore` 抽象 + 明文降级 | 先定接口，系统密钥库留 M4 | `lib/platform/secure_store.dart`、`secure_store_io.dart` | 用 `isSecure` / `securityNotice` 把「是否真安全」暴露给 UI；**不写 print、异常不带凭据值** |
| 设置持久化与三态主题 | `TYP-03` | `lib/settings/settings_store.dart` | **自研监听回调**（`List<void Function()>` + 订阅/退订），**不是** `ChangeNotifier`；`Settings.fromJson` 逐项回退默认值并 clamp 到 `TYP-01` 区间 |
| JSON 编解码 + `.bak` / `.corrupt` 语义 | `DATA-01` ①② | `lib/storage/json_store.dart` | 「文件不存在」与「文件损坏」必须区分：前者返回 `null`，后者回退 |
| `MaterialApp.builder` + 透明 `Material` | 玻璃态地基（避免黄色下划线） | `lib/app.dart` | `Material(type: MaterialType.transparency)`；M1-T08 只在此之上接玻璃库，不要再动这层 |
| `flutter_test` 形态 | 真实 IO 断言 | `test/storage/atomic_file_test.dart`、`test/widget_test.dart` | 用例内 `Directory.systemTemp.createTemp` + `tearDown` 递归删；含「50 次并发写」与首页 `pumpWidget` 冒烟 |

### 2.4 Android 构建修复（AGP 9 / compileSdk）

| 项 | 值 |
|---|---|
| 任务 | 构建修复（非需求条目） |
| 提交 | `11c5198` |
| 日期 | 2026-09-21 |
| 一句话目标 | 让引入 `path_provider` 后的 Android 构建通过 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `com.android.build.api.dsl.CommonExtension` | 读写插件模块 `compileSdk` | `android/build.gradle.kts` | **AGP 9.0.1 已移除 `BaseExtension`**；新 DSL 自 AGP 9 起不再带泛型参数，`compileSdk` 是可读写 `Int?` |
| `subprojects { afterEvaluate { … } }` | 逐个子工程按需提升 | 同上 | 只改 `:app` 无效——报错方是插件模块自己的编译目标；**仅当 `< 36` 才提升**，插件将来升到 37 不会被压回；`null` 表示用 AGP 默认值，不动 |
| 依赖根因：`path_provider` → JNI | 说明为何必须 ≥ 36 | 同上注释 | `path_provider` 2.1.6 → `path_provider_android` 2.3.1（改走 JNI）→ `jni` 1.0.3 / `jni_flutter` 1.0.3；`jni` 的 AAR metadata 要求消费者 `compileSdk ≥ 36`，而 `jni_flutter` 自身硬编码 35 |

### 2.5 文档与流程批次（PRD / 架构 / 排期）

| 项 | 值 |
|---|---|
| 任务 | 需求与设计文档（PRD v2.3 → v2.6、架构文档、`schedule.md`、`CHANGELOG.md`） |
| 提交 | `afa499e`…`3c1c535`、`e69f0ff`、`be6f73e`、`ea8ea73`、`9194a89` 等 |
| 日期 | 2026-09-20 ~ 2026-09-21 |
| 一句话目标 | 用可复核的方式维护需求、架构与排期的一致性 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 程序化点数 | 表头计数必须来自脚本 | `docs/PRD.md` 表头 | 正则用 `[A-Z][A-Z0-9]*-\d{2}`；用 `[A-Z]+-\d{2}` 会静默漏掉整张 `P2-*` 表 |
| 确定性重放改稿 + 命中数断言 | 一次改几十处不互相覆盖 | 临时脚本 | 每处替换断言「命中次数 = 1」，串行重放；不用并行编辑 |
| 格式自检 | 交付前统一格式 | `docs/*.md` | UTF-8 无 BOM、LF 行尾、以换行结尾 |
| 编号空位不重编 | 保护跨章节引用 | `docs/PRD.md` §6 | 删除条目保留编号空位（如 `P2-04` / `CNT-07`） |
| Mermaid 图 | 架构可视化 | `docs/class-diagram.mermaid`、`docs/sequence-diagram.mermaid` | `quadrantChart`（竞品）/ `classDiagram` / `sequenceDiagram` |
| 推翻定案必须留证 | 防止团队原地反复 | `docs/PRD.md` §15.6.4、附录 `B.8` | 记录「被推翻的判据 + 未被推翻的部分 + 决定性前提是否失效」 |
| Keep a Changelog（简化式） | 每日更新速查 | `CHANGELOG.md` | 倒序分节、四类小标题、每条 ≤ 40 字并附 commit |

### 2.6 M1-T02A — 格式统一抽象 + EPUB 源（含目录 / 加密拒绝 / RD-05 文案）

| 项 | 值 |
|---|---|
| 任务 | M1-T02A（PRD `RD-01` / `RD-05` / §7.1 / §7.3；架构文档 §A.1） |
| 提交 | `c9827fe`（实现）→ `38fcb2f`（测试） |
| 日期 | 2026-09-21 |
| 一句话目标 | 立起「格式解析统一抽象 + EPUB 纯 Dart 实现」的接口冻结点，T02B 的 TXT 源可平行接入 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `archive` 3.6.1 解 zip（复用，未改行为） | EPUB 解包；工具函数提到独立文件供目录解析复用 | `lib/epub/zip_paths.dart` | **3.x 的 `ArchiveFile.content` 是 `dynamic`**（可能是 `Uint8List` 或 `List<int>`），必须双类型判断；`tryDecodeZip` 把异常收敛成 `null` 再转中文错误 |
| `xml` 6.6.1 严格解析 | `container.xml` / OPF / `toc.ncx` / `encryption.xml` | `lib/epub/epub_parser.dart`、`lib/epub/epub_toc.dart`、`lib/epub/xml_util.dart` | `toc.ncx` 必须走严格 XML；**层级只能按 `childElements` 逐层递归累加**——`findAllByLocalName` 是扁平收集，**拿不到真实嵌套深度** |
| `html` 0.15.7 宽松解析 | 正文抽取（已有）+ EPUB3 `nav.xhtml` | `lib/epub/section_extractor.dart`、`lib/epub/epub_toc.dart` | nav 优先用 `html`（EPUB3 nav 常是脏 XHTML），取不到 `<nav>` 再回落 `xml`；`dom.Element.attributes` 是 `Map<Object, String>`（键可能是 `epub:type`）；`dom.Node` **没有** `nextNode`，取后续兄弟要用 `parent.nodes` + `indexOf` |
| 目录双路径（`RD-01`） | nav（`properties` 含 `nav`）/ ncx（`application/x-dtbncx+xml` 或 `.ncx`） | `lib/epub/epub_toc.dart` | **nav 里的 href 相对 nav 文件自身，不是相对 OPF 目录**（最容易错的一点）；纯 fragment 链接（`<a href="#c1">`）指向**目录文件自身**，href 取 `basename(navPath)`；html 与 xml 两条路径的锚点查找语义必须一致——**都不下钻嵌套 `<ol>` / 嵌套 `navPoint`**（否则父级会凭空多一条错层条目）；两条路径皆空 -> 返回空列表，由调用方降级为平坦目录 |
| 目录项类型 = `Chapter`（合并，不再另立） | 避免「目录条目」与「章节」两份同构类型导致的字段搬运 | `lib/model/chapter.dart`、`lib/epub/epub_toc.dart` | `parseToc` 直接返回 `List<Chapter>`；依赖方向 `lib/epub -> lib/model`；`lib/model/chapter.dart` 是**不 import 任何东西的叶子**，全项目唯一章节类型 |
| 加密检测（`RD-05`） | 读 `META-INF/encryption.xml` 决定是否拒开 | `lib/epub/epub_parser.dart` | 三态判定：① 不存在 -> 不加密；② 算法属**字体混淆**（IDPF embedding / Adobe `enc#RC`）-> 不算加密；③ 目标**是字体**（扩展名或 manifest media-type 为字体）-> 不算加密；其余才拒开。**反例用例防误杀**；检测必须在返回可读章节**之前** |
| `MReaderFormatException` + `kFormatErrorMessages` | 错误码 -> 中文的**唯一来源**（`RUST-04 ②` 口径一致的前提） | `lib/format/error_messages.dart` | 文案表由 `test/format/error_messages_test.dart` 兜底（枚举全覆盖、中文、不重复口径）；`detail` 只进 `toString`，**不进面向用户的 message** |
| `EpubParseException` 退休但不删除 | 兼容既有引用 | `lib/epub/epub_parser.dart` | 降级为 `@Deprecated` 的**子类**（`extends MReaderFormatException`），既有断言只需改类型名，**不必大改 fixture 与 baseline** |
| 纯字节入口 + 惰性解析 | `PERF-01`（解析移出主 isolate）的形状 | `lib/format/dart_epub_source.dart` | 构造**不解析**；`parseEpub` 的 `Future` 缓存一次（避免重复解析）；`lib/format/**` 与 `lib/epub/**` 零 `dart:io`、零 Flutter |
| `totalCharCount()` 显式增补 | `STAT-14` 要「全书字符总数」 | `lib/format/book_source.dart` | 用**带默认实现**的具体方法补入（`async => null`），**不改 §A.1 既有字段/签名**；实现里懒计算 + 缓存，**不在 `load()` 里算**（20MB 书会拖慢打开） |
| 朴素子串搜索 + 进度/取消 | `CNT-06` 的纯 Dart 基线（Rust 阈值被测对象） | `lib/format/dart_epub_source.dart` | **不建索引**（索引是 M2b 的事）；命中给「章索引 + 章内字符偏移 + 命中段」；每章末回报 `0.0~1.0` 进度；`cancel.isCancelled` 即停 |
| fragment 定位（`Chapter.locate`） | nav href 带 `#id` 时只显示该锚点起的内容 | `lib/epub/section_extractor.dart` | best-effort：按 `id`/`name` 找锚点，再按**文档序**（锚点子树 + 逐层后续兄弟）续取；**锚点丢失退回整章**，绝不报错/变空；段落边界按节点逐个 flush（否则相邻 `<p>` 会被并成一段） |
| 测试脚手架：Dart 现场拼 zip | 目录层级 / 加密标记 / 锚点这类**结构**样本 | `test/format/epub_builder.dart` | 与 `make_fixtures.py` 分工：Python 管「脏字节」基线契约（**不动 `baseline.json`**），Dart 管「结构」样本，断言可写在同一处 |
| **先探针、后断言** | 防「想当然的期望值」 | `.scratch/probe_*.dart`（用完即删） | 用 `dart run` 实测 TOC 层级 / fragment / 加密三态 / 9 个 fixture 对齐，全绿后才把实测值写进断言 |
| 契约测试骨架 | 让新增实现自动被同一组断言覆盖 | `test/format/book_source_contract_test.dart` | `registeredSources()` 是唯一注册点；**M1-T02B 追加 `dart-txt` 一行即可**（`RD-01` 的「实现互不感知」靠它守住） |

### 2.7 M1-T02B — TXT 源 + 编码名缝 + 应用接线

| 项 | 值 |
|---|---|
| 任务 | M1-T02B（PRD `RD-02` / `NF-C4` / §7.1 / §15.6.2；架构文档 §A.1） |
| 提交 | `f39deb1`（编码名缝）→ `bd2466d`（TXT 源 + 注册）→ `0da0c5b`（应用接线 + 测试） |
| 日期 | 2026-09-21 |
| 一句话目标 | 接通 TXT 作为第二种格式，并把「编码探测」抽成 Rust 后续可替换的缝 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `detectEncodingName` 编码名缝 | `NF-C4` / §15.6.2：Rust 首版只「探测编码名」，解码留 Dart | `lib/epub/text_codec.dart` | 把 `decodeText` 拆成「探测 + 按名解码」两步；探测返回 `utf-8` / `utf-16le` / `utf-16be` / `gbk` / `latin1`（**全小写**）。重写后对外行为必须**逐字节不变**——用 9 个 fixture 基线（`合格 9 / 失败 0`）兜底回归 |
| 判定优先级（BOM → 声明 → 严格 UTF-8 → GBK → latin1） | 同一套口径同时服务探测与解码 | 同上 | BOM 定双字节序；`<?xml … encoding>` / 头部声明经「判据投影」再回落；严格 UTF-8 通过即判 `utf-8`；否则 GBK 可解则 `gbk`，兜底 `latin1`。BOM 的**剥离**放在解码侧，探测侧只看标记 |
| 分章算法**照译**参考实现 `TextFile.kt` | `RD-02`：TXT 自动分章 | `lib/format/dart_txt_source.dart` | 规则择优 `getTocRule()`（`:497-535`）、规则分章 `analyze(rr)`（`:159-389`）、无规则分块 `analyze(fileStart,fileEnd)`（`:394-492`）、内置 `txtTocRule.json` 中 `enable==true` 的 12 条 |
| 择优三变量 `csNum` / `numE` / `maxNum` | 卷标题误判过滤（`RD-02` 的要害） | 同上（`_pickRule` 上方注释） | **按源码而非 PRD 转述**：`csNum`=**命中章节数**（首个匹配，或与前次接纳匹配**间距 >1000 字**者）；`numE`=**疑似卷（误判）数**（两次匹配**间距 <100 字**的次数）；`maxNum`=**当前最优规则的 `csNum`**（跨规则比较基准，初值 −1）。接纳条件 `csNum >= numE*3` **且** `csNum > maxNum+2`；选中最优后 `maxNum > 70` 提前终止 |
| 规则择优**只在首个 512KB 块**上跑 | 忠实照译 **且** 性能 | 同上（`_analyze`） | 参考实现只把首个 `bufferSize=512000` 字节交给 `getTocRule()`。若对整本跑 12 条带 lookbehind 的规则，20MB 无标记文本会从「分钟级/挂死」降到**百毫秒级**（实测 20MB 无标记 ≈ 328ms、有章节 ≈ 162ms） |
| **canonical 分章口径（本项目定义，Rust 移植以此为准）** | `RUST-02` L4 命中集合比对的基准 | `lib/format/dart_txt_source.dart` | 本项目把三档阈值定义为**字符**：无规则分块 10KB 字符 / 规则单章上限 100KB 字符 / 择优取样首 512K 字符；`Chapter.href` 亦为**字符偏移**（`txt:<起始字符偏移>`）。参考实现用的是**字节**（`toByteArray(charset)` + `curOffset`）——**Rust 实现不得照抄字节口径**，否则分章边界与命中集合对不上、等价门永远过不了。中文书 100KB 字符 ≈ 2.2–3.3 万字，与参考实现触发点本就不同，属**预期内的口径差异**、非偏差 |
| 已知局限：短章/语录体书的目录不可用 | 1:1 照译参考实现的**固有行为，非 bug** | 同上（`_pickRule` 的 `>1000 字` 门槛） | 算法要求「相邻两次规则命中间距 **>1000 字**」才计为正式章节；**标题间正文 ≤1000 字的书（短章 / 诗话 / 语录体）会整体回落到无规则分块，目录不可用**。故 `RD-02` ① 的验收样本应为**正常章长**（相邻标题间正文 >1000 字），否则会误判为「没分章」|
| dispose 契约（两源一致） | `RUST-01`：上层无感，释放后不崩 | `lib/format/dart_txt_source.dart`、`lib/format/dart_epub_source.dart` | `dispose()` 之后、以及调用与 dispose **竞态**时，所有公开方法**返回优雅空结果、绝不抛**（`load` → 最小 meta title `未命名`；`chapters`/`content` → 空；`search` → 流立即结束；`totalCharCount` → `null`）。实现要点：**每个 `await` 恢复后重查 `_disposed`**，不依赖 `!` 断言——否则「正文还在加载时退出阅读页」会踩空 `_text!`（实测崩溃点 `dart_txt_source.dart:132`）|
| 无规则 10KB 分块 + 超长章二次拆分 | `RD-02` ②：无标记也能读 | 同上（`_splitByLength` / `_splitByRule`） | 无规则：每块 ≤10KB、尽量在换行处断，块名 `第N章(M)`（N=字符块序号）；收尾残块 ≤100 字并入上一章。单章正文 >100KB → 二次拆分，子章名 `章名(N)`；原章**不留空壳**（本项目 `Chapter` 无 `isVolume` 字段） |
| `content(i)` 段落口径 | 与 EPUB 侧 `extractSection` 对齐 | 同上（`content` / `_splitParagraphs`） | 按 `\r\n|\r|\n` 切段、逐行剥行首 BOM + `trim`、丢空行；首段与章名重复时**剥掉**（UI 单独渲染标题） |
| 纯 Dart（零 Flutter / 零 `dart:io`） | `PERF-01`：解析可丢进 `compute()` | `lib/format/dart_txt_source.dart` | 只吃 `Uint8List`；全文**只解码一次**并缓存，分章边界用**字符区间**表示，`content(i)` 用 `substring` 取——峰值量级 ≈ 输入文件的 2 倍（内存收敛交给 M1-T07） |
| UI 只依赖 `BookSource` 抽象 | `RD-01`：实现互不感知 | `lib/main.dart`、`lib/ui/reader_page.dart` | 首页 `allowedExtensions` 改 `[epub, txt]`；`parseEpub` → `openBook`（分发点），并**主动 `await source.load()`** 把格式错误暴露在首页（结果被缓存，阅读页不重复解析）。阅读页改吃 `BookSource`：异步 `chapters()` + `content(i)` 用**同一 Future 按索引去重缓存** + `FutureBuilder` 逐章渲染；诊断行改为格式无关的「`N 章 · <implId>`」 |
| 先探针、后断言 | 防「想当然的期望值」 | `.scratch/probe_verify.dart` 等（用完即删） | 探针**逐条复现** `dart_txt_source_test.dart` 的 48 条断言（GBK 解码 / 卷过滤 / `txt:5` / `txt:1529` / `txt:10247` / 16 章 / 590 章 / 138 命中…），全绿后才定稿；探针当场揪出 1 个真 bug（`.txt` 兜底书名未回落「未命名」）|
| 契约自动覆盖 | 新实现自动被同一组断言覆盖 | `test/format/book_source_contract_test.dart` | `registeredSources()` 追加一条 `dart-txt` 样本（含 `正文` 供 `searchable` 断言），并补 `openBook` 的 txt 分发用例 |

### 2.8 M1-T08 — 玻璃态基础设施与内容层不透明红线

| 项 | 值 |
|---|---|
| 任务 | M1-T08（PRD `UI-01` / `UI-04` / §11.1 / §11.3 / §11.4） |
| 提交 | `348ce23`（依赖接入）→ `08c2b65`（主题 + 玻璃基建）→ `46810eb`（单测） |
| 日期 | 2026-09-21 |
| 一句话目标 | 把玻璃态的地基与红线一次接好：档位与「内容层不透明」各留**唯一出口**，业务页面留到 M1-T03/M2a |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| **精确锁定** `liquid_glass_widgets: 1.7.0`（**不带 `^`**） | PRD §11.4 的「已知限制与应对」**原针对 1.6.2 逐条实测**；**2026-09-21 由负责人决定升 1.7.0**（`c996106`）→ 关键断言已在 1.7.0 上复核（见下三行，2026-09-28） | `pubspec.yaml` | 锁定纪律 = 精确版本、不带 `^`。`pubspec.lock` 解析值 = `1.7.0`（`sha256:547fe867…`，源 `pub.flutter-io.cn`）。库自身约束 `flutter >= 3.41.0` / `sdk >=3.5.0 <4.0.0`（本机 3.47.5 满足），且**零 `flutter/material.dart` 依赖**、**未引入任何额外传递包** |
| `cupertino_icons` 必须保留 | PRD §11.4 列为**强制依赖** | `pubspec.yaml` | 从 pubspec 删掉会让玻璃图标渲染成 `?`（库内部用具名图标） |
| 有效亮度跟随**应用 ThemeMode**（`UI-01` ②） | 否则「应用切深色、系统仍浅色」时玻璃亮度错位 | `lib/theme/app_theme.dart`（纯函数 `resolveBrightness`）、`lib/main.dart` | 三态：`light`/`dark` 恒取自身，`system` 取平台亮度。接线方式是 `LiquidGlassWidgets.wrap(brightnessResolver: Theme.maybeBrightnessOf)`，**包裹位置在 `MReaderApp` 之外**——`lib/app.dart` 里 `MaterialApp.builder` 那层透明 `Material` 一字未动 |
| 档位唯一出口 `GlassKit`（`UI-05` 预留） | P0 固定 `standard`，**不引入 `premium`** | `lib/ui/glass_kit.dart` | `kAppGlassQuality = standard`；固定表面的覆盖值 `fixedSurfaceQualityOverride` **恒为 `null`**（传 `null` 即「不覆盖」）。浮层（`GlassDialog.show` / `GlassSheet.show`）显式传 `standard` |
| 「固定表面自动升 premium」是**库的行为**，不是我们的 | 佐证「本项目从不手传 `premium`」 | 复核来源：**1.7.0** `lib/widgets/surfaces/glass_scaffold.dart:559 / :584` | `GlassScaffold` 对 `appBar` / `bottomBar` 传 `defaultQuality: GlassQuality.premium`，经 `GlassIsolationScope` 下发为子控件的档位提示。**手写 `premium` 会绕过该隔离策略**。**1.7.0 复核（2026-09-28）：行号 559 / 584 与 1.6.2 逐字一致** |
| `OpaqueContentSurface`＝「不透明」唯一出口（`UI-04`） | 内容层各页统一走它，避免各页自己写 `Container(color:)` 各自失守 | 同上 | 底色经 `fullyOpaque()` 强制 `alpha = 1`；内部用 `Material` 同时补上「玻璃库没有 Material 祖先」的坑；**debug 下 `assert` 拒绝玻璃子控件**（玻璃不可嵌套） |
| `isGlassWidget()` 红线可判定化 | 把「不得嵌套玻璃」从文档约定变成可断言的形式 | 同上 | 判定表覆盖 **35 个** `Glass*` 表面类型（容器 / 交互 / 输入 / 导航 / 浮层）＝ `lib/ui/glass_kit.dart` 中 `isGlassWidget` 的 `widget is Glass*` 分支数（`sed -n '71,105p' lib/ui/glass_kit.dart`）。**已逐类型核对存在于 1.7.0，零缺失**（2026-09-28）。⚠️ **勘误**：原文写「37 个」**不可复现**——该判定表在 `08c2b65` / `9519c5f` / `5b96ca6` 三个提交上**始终为 35**；而库 `lib/widgets` 下 `class Glass*`（含 `*Scope` / `*Controller` / `*Painter` 等非表面类）实为 **90**（1.6.2 与 1.7.0 完全相同）。「37」与两者均不符，属**原文计数错误**，与版本升级无关 |
| `GlassScope`（`InheritedWidget`） | 有效亮度 / 档位 / 玻璃隔离范围收敛一处，下游不必各自猜 | `lib/ui/glass_scope.dart` | `brightnessOf` 三级回退：本作用域 → `GlassTheme.brightnessOf`（库级联）→ …；`qualityOf` → `GlassAdaptiveScopeData.maybeOf(...)?.effectiveQuality` → `kAppGlassQuality`。**本批只备好，尚未接入业务页**（`GlassScopeProvider` 当前无调用方，属预期） |
| 着色器预热 + 诚实降级（`UI-01` ①） | 避免首帧白闪 | `lib/main.dart`（`_warmUpGlassShaders`） | `await LiquidGlassWidgets.initialize()` 包在 `try/catch` 里：**失败只 `debugPrint`、不抛、不阻塞**。⚠️ **待优化**：当前是在 `settings.load()` **之前**串行 `await`，会给冷启动叠加一段着色器预编译时间（`v2.3` 冷启动是硬指标）——可改为与 `appPaths.dataDir()` / `settings.load()` 并行（`Future.wait`） |
| Windows / Linux 被库**静态封顶 `standard`** | 佐证 `NF-C8`「不得宣称五平台等价」与排期「不在本机 Windows 上反复调视觉」（`Q3` / `R8`） | 复核来源：**1.7.0** `lib/liquid_glass_setup.dart` 的 `_shouldSkipPremiumPreload()`（`:148-153`） | 对 `kIsWeb` / `windows` / `linux` 返回 `true` → `initialize()` 跳过 premium 多趟着色器预载，`GlassAdaptiveScope` 把这些平台上限压到 `standard`。**本机（Windows）看到的观感与 Android 不一致是库的既定行为，不是配置错误**。**1.7.0 复核（2026-09-28）：`:148-153` 判定式与 1.6.2 `:148` 逐行一致** |
| 红线自检形式（测试） | 防「地基被误删 / 档位被偷改」 | `test/ui/glass_kit_test.dart` | 断言：档位恒 `standard`、固定表面覆盖值恒 `null`、`OpaqueContentSurface` 底色 `alpha == 1`、内容层嵌套玻璃触发 `AssertionError` |
| 纯逻辑先于依赖可测 | 主题三态解析不依赖玻璃库，`pub get` 前即可跑 | `test/ui/app_theme_test.dart` | `lib/theme/app_theme.dart` **不 import 任何玻璃库**；`Settings.defaultFontSize`(18) / `defaultLineHeight`(1.6) 以具名常量转出，供 M1-T05（合成封面取主题色）与 M1-T06（排版）复用 |
| 黄色下划线回归护栏 | `UI-04` / PRD §11.4 防护 | `test/ui/app_material_layer_test.dart` | 断言 `app.dart` 那层 `Material(type: MaterialType.transparency)` 仍在，且首屏 `DefaultTextStyle` 不命中 `WidgetsApp` 的 fallback（黄底双下划线） |

### 2.9 M1-T05 — 元数据模型与封面链路

| 项 | 值 |
|---|---|
| 任务 | M1-T05（PRD `META-01~07`；架构 §N 接口冻结） |
| 提交 | `c8d06ca`（模型层 + 兼容桥）→ `f168d1d`（纯 Dart 提取）→ `e0d9a4c`（封面落盘 + 合成封面）→ `8e11ae0`（本节 + CHANGELOG）→ `a153313`（占位 meta 作者回落「未知作者」+ 补不变式断言）→ `d645fea`（合成封面 LRU 有界化 + 并发去重）→ `35ed10f`（本节「缓存上限分工」行） |
| 日期 | 2026-09-21 |
| 一句话目标 | 把元数据模型与封面链路一次接好：纯 Dart 半边（嗅探/优先级链/文件名规则）可进 `compute()`，Flutter 半边（落盘/缩略图/合成）负责像素与文件 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| BookMeta 唯一归属（`META-01`） | 防「结构相同的两份类型 → 字段搬运」复制陷阱（同 `f22891b` 的 `Chapter` 教训） | `lib/model/book_meta.dart`（定义）；`lib/format/book_source.dart`、`lib/meta/book_meta.dart`（只 re-export） | 三处路径指向同一份，**物理上不可能出现第二份**；模型是**叶子**（仅 `dart:typed_data`） |
| `MetaOrigin` 闭合四值（§N.2） | 让「来源标记相等」的可判定性与 `META-08`「置 user 不被覆盖」成立 | 同上 | 细粒度串（OPF/EXTH）**不进契约**；`lib/` 下 grep `coverBytes` / `opf:dc` / `exth:100` = 0 |
| `sealed class CoverRef` 四态（§N.5） | `META-06 ④`「禁魔法字符串」落到类型层 | 同上 | `PendingCover`（解析期原始字节）→ `CoverStore.materialize` → `StoredCover`；`book_source.dart` 不再就地定义 BookMeta |
| `OpfView` 与 `EpubBook` 同一次解压（§N.4 D1） | `META-02/03` 需 OPF 视图，但**不得重复解压** | `lib/epub/epub_parser.dart` | `parseEpubResult` 返回 `{book, opfView}`；`readEntry` 只保留**候选相关少量条目字节**（≤4 图），不钉住整本解压结果 |
| 封面四来源**有序**优先级 + 命中即停（`META-02`） | 结果不依赖遍历顺序，重复解析稳定 | `_buildCoverCandidates`（有序 List + 去重 Set）；`lib/meta/epub_meta.dart` | ①`<meta name=cover content>` ②`properties="cover-image"` ③guide`reference type=cover` ④文件名含 cover 的图片项；嗅探非图片（如 guide 指向 XHTML）→ 跳过 |
| 多作者稳定顺序整体保留（`META-03`/`Q17`） | 中文书 `dc:creator` 常是整合串，切分会制造错误 | `lib/meta/epub_meta.dart` | 多个 `dc:creator` 用 `；` 连接（不切分）；缺失 → 文件名规则链 → 「未知作者」 |
| 文件名规则链（`META-04`） | TXT 唯一的元数据来源 | `lib/meta/txt_meta.dart` | 命中即停：`《书名》…作者：X` → `《书名》` → `作者：X` → `by X` → 清洗兜底；**精确化兜底不比较长度**（等长用例不被误丢弃） |
| 魔数嗅探（`META-05` 上半截） | 「嗅探（纯 Dart、可进 isolate）」与「解码（`dart:ui`）」拆开 | `lib/meta/meta_source.dart` | 只看前几字节：JPEG `FF D8 FF`／PNG 8 字节签名／WebP `RIFF`????`WEBP`／GIF `GIF8`／BMP `BM`；否则 `unknown` |
| 像素上限降采样 + 缩略图（`META-05`/`NF-M5`） | 防「导入大封面 → 逐本解码原图 → 内存尖峰」 | `lib/meta/cover_store.dart` | `kCoverDecodeMaxPixels`=4,194,304；`kCoverThumbMaxEdge`=320；`ImmutableBuffer → ImageDescriptor.encoded → 等比缩 → instantiateCodec`；书架只解缩略图 |
| 真实格式落盘、不重编码（`META-05`） | 透明通道不丢、后缀与内容一致 | 同上 | 原图扩展名由 `CoverFormat` 推（**不看原扩展名**）；⚠️ **缩略图例外用 `png`**：`dart:ui` 只能编码 PNG，用源扩展名会「后缀与内容不符」 |
| 孤儿 GC 的安全规则（`META-06 ③`/§N.7） | 只删「不被任何书籍引用」的孤儿 | 同上 | 只扫 `covers/`；**`.tmp`/`.bak`/`.corrupt` 兄弟与 `.thumb.` 缩略图随其基封面处置**（team-lead 补充，防误删唯一可回退的 `.bak`）；幂等；`covers/` 之外永不触碰 |
| 合成封面（`META-07`） | 无封面时的运行时降级 | `lib/meta/synth_cover.dart` + `lib/theme/app_theme.dart` | `cacheKey = FNV-1a(书名+作者+主题)`（确定性）；命中即复用不重绘；主题经 `app_theme` 的 `CoverTheme`/`coverThemeOf`（主题口径唯一出处）；缓存 **LRU 有界**（`kSynthCoverCacheMaxEntries`=32，逐出即 `ui.Image.dispose()`）+ 并发同 key in-flight 去重（只保一张图） |
| 缓存上限的**分工**（`META-05` ④） | 说清「谁解码、谁缓存、上限谁兜」，不靠人猜 | `lib/meta/cover_store.dart`（只返字节）/ Flutter 内置 `ImageCache` / `lib/meta/synth_cover.dart`（自建 LRU） | **真实封面**：`CoverStore` 只返**字节**、**不做解码缓存**；UI 走 `Image.memory`，解码去重与上限由 Flutter 内置 `ImageCache`（默认 100 MB / 1000 条）承担——这正是 `META-05` ④「书架滚 20 本不重复解码同一封面」的落点。**合成封面无宿主缓存可依附**，是全工程唯一自建位图缓存，故**必须自带上限** |
| 封面引用序列化唯一出口（`META-06 ⑤`） | 全工程搜不到 `'file'`/`'synthetic'`/`'none'` | `lib/meta/cover_ref_codec.dart` | 唯一出现魔法串处，由 round-trip 测试锁死；`PendingCover` 序列化**直接抛 `StateError`**（持久化不变式） |
| 先探针后断言 | 期望值不凭记忆 | `.scratch/probe_meta.dart`（已删） | 实测四来源各一例 / 优先级命中即停 / 非图片候选跳过 / 多作者 / 文件名兜底 / 魔数；再把实测值写进 `test/meta/*` |

### 2.10 M1-T03 — 书库索引 / 导入 / 判重 / 删除连带清理

| 项 | 值 |
|---|---|
| 任务 | M1-T03（PRD `LIB-01~06`；架构 §N） |
| 提交 | `5bd1d8b`（数据层）→ `f797913`（导入 + 仓库）→ `60c5171`（书架 UI）→ `7b58134` `023ca78`（进度表） |
| 日期 | 2026-09-21 |
| 一句话目标 | 立起「内容摘要判重 + 索引逐条降级 + 删除连带清理」的书库后端，书架 UI 只依赖 `LibraryRepository` |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 内容摘要 = SHA-256 hex 前 16 位（`LIB-05`） | 判重键（相同字节 → 相同 bookId） | `lib/library/import_service.dart` | `crypto` 3.0.6（**精确锁定**）；`sha256.convert(bytes).toString().substring(0, 16)`；该 `bookId` 同时是「副本文件名 / `index.json` 主键 / 进度文件名」三处唯一身份 |
| `BookIndex` **逐条降级**（`LIB-03`） | 单条损坏不崩全库 | `lib/library/book_index.dart` | `load()` 对 JSON 数组逐条 `try-catch` + `item is Map<String,Object?>` 判定，坏条目**跳过**；底层仍走 `JsonStore` 四态回退；索引文件 `library/index.json` |
| `BookRecord` 纯 Dart 记录（`LIB-02`） | 索引最小可持久化单元 | `lib/library/book_record.dart` | 封面经 `encodeCoverRef` / `decodeCoverRef`（`META-06 ⑤` 唯一出口）；JSON **不含 `PendingCover`**（持久化不变式）；`==` 只比 `bookId`（不按文件名判同书） |
| 导入管道（`LIB-02` / `LIB-05`） | 一个文件 → 一条记录 | `lib/library/import_service.dart` | 顺序：嗅探格式 → `openBook().load()`（`finally` 保证 dispose）→ 摘要 → 原子写副本 `library/<bookId>.<ext>` → 封面物化（`PendingCover`→`StoredCover`）→ 构造记录；**不写索引**（交仓库），保证「转换」与「入库」职责分离 |
| 仓库胶水（`LIB-01` / `LIB-05` / `LIB-06`） | UI 唯一后端 | `lib/library/library_repository.dart` | `importFile` 先查 index 判重（命中 → `isNew:false` 不新增；同名不同内容可共存）；`deleteBook` ③ 步：删封面 → 删副本 → 摘索引；`purgeOrphans` 汇总在库 `StoredCover` 文件名后交 `CoverStore.purgeOrphans` |
| 书架 UI（`LIB-01~06`） | 网格 + 导入 + 删除 | `lib/ui/shelf_page.dart` | `StatefulWidget` + `setState`（**禁** Riverpod / Provider）；`file_picker` `withData:true` 走 bytes（`dart:io` 不进解析链路）；长按弹 `showDialog` **二次确认**；`_opening` 防双击；`_openBook` 不 eager 解析（`d1fc20c`） |
| 依赖方向（无环） | UI 与后端解耦 | `lib/library/**` → `lib/meta` / `lib/storage` / `lib/platform` / `lib/model` | `import_service` 经分发点 `format/book_registry.dart` 取源，**不经** `book_source.dart` 直连具体实现（§A.1 铁律：实现互不感知） |
| 测试形态 | 真实 IO + 判重/连带断言 | `test/library/{book_record,book_index,import_service,library_repository}_test.dart`、`test/ui/shelf_page_test.dart` | `Directory.systemTemp.createTempSync` + 逐用例独立目录；断言「同内容二次导入 `isNew=false`、索引仍 1 条」「同名不同内容共存」「删书后副本 + 封面 + 索引三处皆清」「删书连带清进度文件」（M1-T04 追加） |

### 2.11 M1-T04 — 阅读页产品化 / 进度持久化 / 目录

| 项 | 值 |
|---|---|
| 任务 | M1-T04（PRD `RD-03` / `RD-04` / `NAV-01`；架构 §N；负责人修订为「章节连续滚动」） |
| 提交 | `d082c6a`（进度层：模型 + 持久化）→ `f196d39`（阅读页 + 目录 + 接线） |
| 日期 | 2026-09-21 |
| 一句话目标 | 章节连续滚动阅读页 + 进度持久化 + 目录；进度模型（含 `localHint`）供 STAT / TTS / SYNC 三方复用 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| **章节连续滚动**（负责人修订，取代原「单章视图」） | 从第 1 章一路滚到最后一章，不切页 | `lib/reader/reader_page.dart` | **全部章节塞进一个 `ListView.builder`**，每章一个 item（`Column`：标题 + 该章全部段落），`itemCount = 章数`，按章懒构建虚拟化；**不引 `scrollable_positioned_list` 等任何新依赖** |
| **逐段渲染**（`PERF-03`） | 不合成巨型 `Text`（避免一次布局上万个字符） | 同上（`_buildChapterBlock`） | 每段各自成 `Text` 子 widget，**禁 `join('\n\n')` 成一个巨型 `Text`** |
| 当前章 + 章内位置（`RD-04`） | 「章索引 + 章内 0.0~1.0」在连续滚动下的可靠映射 | 同上（`_detectCurrentChapter`） | 每章块挂 `GlobalKey`；滚动停止时从**上次索引**向两侧 **±4** 探测 `findRenderObject`，取**覆盖视口顶部**的章块（`relTop ≤ 0` 且最大者），`chapterPos = -relTop / 章块高` |
| 版面签名恢复（`RD-04`「落点误差 ≤ 1 屏」） | 同版面零抖动精确落回，跨版面仍合理 | 同上（`_ensureController` / `_restoreStep`） | 控制器**内容就绪后**才创建：`localHint.matches(...)` 为真 → `ScrollController(initialScrollOffset: hint.scrollOffset)` 精确落回；不一致 / 无 hint → 按章序比例估算 + `addPostFrameCallback` 迭代校正，**≤3 帧**、偏移差 **≤ 1px** 即停 |
| 进度以 `Chapter.href` 为稳定身份 | 书源重排 / 目录微调时不跳错章 | `lib/reader/reading_progress.dart` | 恢复先按 `chapterHref` 匹配章节，匹配不到退回 `chapterIndex` 并 clamp |
| `localHint` 设备本地快照（`SYNC-02`） | 绑定字号 / 行距 / 视口尺寸 / 滚动偏移，**不参与跨设备同步** | 同上 | `matches` 容差 0.5 逻辑像素；`hasSameSemantics` **忽略** `localHint`，供同步侧比对语义字段 |
| 进度持久化（`RD-04`） | 每本书记一个进度文件 | `lib/reader/progress_store.dart` | `<dataDir>/progress/<bookId>.json`；bookId 白名单 `^[A-Za-z0-9_-]+$` 否则 `ArgumentError`；`load` 缺失 / 损坏 / 串档 → `null`；`remove` 幂等清 `.bak` / `.corrupt` / `.tmp`；全部经 `JsonStore` + `AtomicFile` |
| 保存时机（3 处） | 不丢进度、也不写脏值 | `lib/reader/reader_page.dart` | ① 滚动停止（`ScrollEndNotification`）② 切章（目录跳转 / 恢复落定）③ `dispose`（`unawaited`）；`_restoring` 期间**忽略**保存，避免把校正中途的偏移写回磁盘 |
| `BookRecord` 回写 + 删除连带 | 书架与阅读页进度一致 | `lib/library/library_repository.dart`、`lib/ui/shelf_page.dart` | 保存进度时 `markRead` 回写 `lastReadAt` / `readProgress`（bookId 不在库中**静默返回**）；删书时连带 `progressStore.remove`（`LIB-06`） |
| `RD-03` 去诊断信息 | 副标题不泄露 `implId` | `lib/reader/reader_page.dart` | 标题取 `BookRecord.title`（回落到 `BookMeta.title` → 「阅读」）；副标题固定「第N章 · X%」，取代 M0 遗留的「N 章 · `<implId>`」 |
| 目录 `NAV-01` + 控制条 | 当前章高亮 + 跳章 | `lib/reader/toc_sheet.dart`、`lib/reader/control_bar.dart` | `TocSheet` 用固定 `itemExtent = 56` + `initialScrollOffset` 让当前章滚入可见区（不依赖逐项 `GlobalKey`，后者对懒构建列表不可靠）；`ListTile.selected` 高亮；控制条 = 上/下一章 + 全书进度 + 排版设置（复用 `ReaderSettingsBar`），目录入口**统一在 AppBar** |
| 测试（`FakeAsync` 铁律） | 让 widget 层测试可信 | `test/reader/reader_page_test.dart`、`test/ui/shelf_page_test.dart`、`test/widget_test.dart` | widget 内部（`initState` / 回调）发起的**真异步 IO 在 FakeAsync 区不会自行推进**，且载入期 `CircularProgressIndicator` 是无限动画 → `pumpAndSettle` **超时挂死**；统一用 `_settle` 助手（`runAsync(Future.delayed)` + `pump` **交替**多轮推进），**不用** `pumpAndSettle` |
| 纯 Dart 进度模型（可单测 / 可进 isolate） | 复用于 SYNC / TTS / STAT | `lib/reader/reading_progress.dart` | **不 import Flutter、不 import `dart:io`**；`toJson` / `fromJson` **防御式**（非 Map / 缺字段 / 类型错 → `null` 不抛）；`chapterPos` 构造即 clamp `0.0~1.0` |

### 2.12 M1-T07 — 性能（PERF-02 内存收敛 + PERF-03 分段渲染验收）

| 项 | 值 |
|---|---|
| 任务 | M1-T07（PRD `PERF-02` / `PERF-01`；负责人指定 4 个子项：① 阅读页增量加载 ② 目录/正文分离 ③ IsolateRunner ④ 样本与验收） |
| 提交 | `e16da96`（② 解析器惰性）→ `f84b470`（① 阅读页增量）→ `9c9ff93`（③ IsolateRunner）→ `9be18ed`（④ 样本 / 测试 / 基线）→ 收尾提交（① 去无界缓存 + ④ `parseEpubStructure`，本批） |
| 日期 | 2026-09-22 |
| 一句话目标 | 打开大书不再一次性解压整本（图 / 字 / CSS 不常驻）；**读完一整本稳态内存也不顶回全书大小**；阅读页正文增量加载 + 有界驻留；给出改前 / 改后可复现数字 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| 惰性归档访问（`PERF-02` ①） | 结构解析阶段**不**预解压整本 | `lib/epub/epub_parser.dart` | 旧实现 `Map<String,Uint8List> files` 对**每条** `contentOfArchiveFile`（含图片）预解压；改为 `Map<String,ArchiveFile> byName`——archive 3.x 的 `ArchiveFile.content` 本就按需解压，仅建「条目名 → ArchiveFile」索引即达成「图 / 字 / CSS 保持压缩态」 |
| 声明式文本性判定 | spine 项「是否正文」不再依赖字节 | `lib/epub/zip_paths.dart`（`textualVerdict`） | 仅凭 `media-type` / 扩展名即可判定的：明确非文本**直接跳过、连解压都不做**；仅当声明不足（无 media-type 且扩展名不暴露）才解压该**单**条目做字节魔数兜底（`fx07b` 脏书路径）。`looksTextual` 复用同一判定，行为逐字不变 |
| `EpubSection` 惰性构造 | 正文推迟到 `content(i)` 才解压 | `lib/model/epub_book.dart` | 新增 `EpubSection.lazy(loadBytes:)`；`rawBytes` 由字段改为 getter、**无缓存**（每次访问现取，`test/perf` 有计数断言）；**急切构造签名不变** → `dart_epub_source.dart` / 既有测试零改动（不加 `join`、不进 Flutter、不引新依赖） |
| **非驻留解压（`PERF-02` ① 的真正口径）** | 读完的章**不**留在内存里 | `lib/epub/zip_paths.dart`（`lazyEntryLoader`） | **关键坑**：archive 3.x 的 `ArchiveFile.content` 会把解压结果**永久缓存**在 `_content`，仅去掉 `EpubSection._cached` 仍会随读章数线性增长。改法：`lazyEntryLoader` 只捕获**压缩态字节**（`rawContent.toUint8List()`，非消费视图），每次现解——STORE 直接返视图、DEFLATE 走 `package:archive` 的 `inflateBuffer`。故 `totalCharCount()` / `search()` 遍历全书后已读章节可被 GC 回收 |
| **结构解析 / 绑定分离（`PERF-01` 底座）** | 让结构解析可跨 isolate | `lib/epub/epub_parser.dart` | `parseEpubStructure(bytes, {fileName})` 返回**无闭包纯数据** `EpubStructure`（sections 用 `EpubSectionRef{id,href}`、toc、metadata、封面候选 href、条目名索引）——闭包才是 `SendPort` 拒收项，纯数据对象可跨 isolate；`parseEpubResult(bytes, {fileName})` **签名不变**，内部 = `parseEpubStructure` + 在**本 isolate** 把 `loadBytes` / `readEntry` 绑到捕获了 `bytes` 的闭包上。**切记**：`parseEpubResult` 的返回**不可**跨 isolate |
| 封面候选按需 | 不再急切解压并常驻全部候选 | 同上（`_bindOpfView` 的 `readEntry`） | 旧实现一次性解压并存下全部封面候选字节（`candidateBytes`）；改为 `readEntry(href)` 按 href **现查** `_resolveFile` → `lazyEntryLoader`，命中即解、用完即弃 |
| 正文增量加载（`PERF-02` ②） | 首帧只等目标章，不等全书（±1 预取不阻塞） | `lib/reader/chapter_cache.dart`、`lib/reader/reader_page.dart` | `ChapterAutoLoader.loadFirstBatch(target)` **目标章必等、邻章 ±1 `unawaited` 预取、各自到货入缓存**（对齐 567Reader `ReadBook.loadContent` cur±1 并行/仅目标章驱动显示；旧 `Future.wait` 全等会被慢邻章拖住）；后台 `fillOnce(current)` 按「离当前章由近及远」每批 **≤3** 补齐至 ±12 窗口驻留；未加载章渲染等高「载入中」占位块 |
| 有界驻留（有界 LRU） | 驻留章数不随书增长 | `lib/reader/chapter_cache.dart` | `ChapterCache` 用**保序** `LinkedHashMap`（插入序 = LRU 序，尾 = 最新），上限 `kMaxLoadedChapters = 30`；`touch` 保护「在视章」不被逐出 |
| 占位高度估计 | 抑制「已加载章数」增长导致的总高跳变 | `lib/reader/reader_page.dart` | 取**已加载章渲染高度的中位数**，**非**「字符数 × 系数」——未加载章的字符数在不解压前提下不可知，那正是 `PERF-02` 要避免的 |
| 布局突变语义重锚（修 A/C，2026-09-23） | 占位→真实合入 / 占位高刷新**不挪视口** | `lib/reader/reader_page.dart`（`_applyLayoutChange`） | 突变前 `ScrollAnchor.capture` 记「视口顶在当前章的相对位置」，突变后 `_beginScrollTo(chapterIndex, relativePos)` **语义坐标重锚**；**禁**复用 `_onSettingsChanged` 式单跳 `correction`——同帧多次突变 /「跳转未渲染就再次捕获」会把多个 delta **叠加**（过校正）。采样（修 C）随重锚收敛走（`_finishRestore`），防漂移位置入档；恢复迭代中 / 用户手势滚动中 / 锚点抓取失败不重锚 |
| 恢复不降级（`RD-04`） | 增量加载后落点仍准 | 同上（`_ensureController`） | 默认仍走「按章序估算 + `addPostFrameCallback` 校正 ≤3 帧」；**仅当**同版面签名**且** `_cache.coversPrefix(targetIndex)`（已加载集合覆盖 `[0, target]`）时才用 `initialScrollOffset` 精确落回 |
| `PERF-03` 逐段渲染 | 不合成巨型 `Text` | 同上（`_buildChapterItem`） | 每段各自成 `Text`（**禁 `join('\n\n')`**）；超长单章（>10 万字符）验收见 `test/perf` |
| 隔离执行底座（`PERF-01`） | 为解析移出主 isolate 预留同款形状 | `lib/task/isolate_runner.dart` | `compute()` 薄封装：纯函数 + **可序列化**入参；本任务**不接线**到 `load()`，仅提供底座与失败护栏 |
| 性能基线（可复现） | 改前 / 改后数字留档 | `tool/perf_bench.dart`、`docs/perf-baseline/README.md` | **BookSource 层**测「首屏」（`load` + `chapters` + `content(±1)`）；**一次进程只测一样本**避免 RSS 互污，多轮取 min/median 时间 + `ProcessInfo.currentRss/maxRss`；样本由 `tool/gen_perf_fixtures.dart` 写到**临时目录、不入库** |
| 测试铁律（`FakeAsync`） | 让性能验收可信 | `test/perf/lazy_load_test.dart`、`test/task/isolate_runner_test.dart` | 一律**纯 Dart `test()`**（**非** `testWidgets`）——`testWidgets` 体内 `await` 真异步 IO 会挂死（FakeAsync 不排空微任务队列），本项目**已两次实证** |
| 结果（可复现） | 300+ 章 EPUB（含 80MB 图） | `docs/perf-baseline/README.md` | 首屏时间 **123 → 45 ms**（min，≈ −63%）；首屏后驻留 RSS **497.9 → 429.2 MB**（≈ −69 MB）；**稳态**（首屏后再读 50 章）**497.9 → 429.8 MB**（+0.6，几乎不增）；100 章大头书读完 100 章 稳态 **562.5 → 426.8 MB**；20MB TXT / 小书无回归 |

### 2.13 M1-T06 — 排版与阅读设置（含位置锚定）

| 项 | 值 |
|---|---|
| 任务 | M1-T06（PRD `TYP-01` ~ `TYP-04`；6 子项：① ReaderSettings 扩展 ② resolveTextStyle ③ parseInlineStyles ④ ScrollAnchor ⑤ ReaderSettingsBar 扩展 ⑥ 测试） |
| 日期 | 2026-09-22 |
| 一句话目标 | 字号/行距/字体/主题/页边距可调；设置变更后当前段不飞出视口；`<b>`/`<i>` 内联样式渲染；首行缩进 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `ReaderSettings` 扩展（`TYP-01` ~ `TYP-03`） | 统一阅读设置值对象 | `lib/typography/reader_settings.dart` | 从 `reader_settings_bar.dart` 提取；新增 `fontFamily`（`String?`）、`themeMode`（`AppThemeMode` 三态）、`pageMargin`（`PageMargin` 枚举：narrow=12 / normal=16 / wide=24）。纯 Dart，不 import Flutter / dart:io |
| `resolveTextStyle`（`TYP-01`） | 字号/行距/字体 → TextStyle 单一出口 | `lib/typography/text_style_resolver.dart` | reader_page 原 3 处 `TextStyle(fontSize:...,height:...)` 统一改为调此函数 |
| 首行缩进（`TYP-04`） | 段落首行缩进 2 字符 | `lib/typography/typeset.dart` | 全角空格（U+3000）前缀：宽度恒 = 1 中文字宽，不受字号/字体影响 |
| `<b>`/`<i>` 内联样式（`TYP-04`） | 段落内粗体/斜体渲染 | `typeset.dart` + `section_extractor.dart` | `_walk` 白名单保留 `<b>`/`<i>`（字面 HTML 字符串在段落文本里）；`parseInlineStyles` 正扫标签 + 状态机切 `TextSpan` 列表；未识别标签原样显示（不吞内容） |
| 位置锚定（`TYP-02`） | 设置变更后当前段不飞出视口 | `lib/typography/anchor.dart`（`ScrollAnchor`） | ① 变更前：GlobalKey + RenderBox 算「视口顶在当前章的相对位置 relPos」；② setState → 列表重建；③ postFrameCallback：`correction = newChapterTop - (newViewportTop - relPos × newChapterHeight)` → `jumpTo` 校正。纯数值版 `correctionFromRaw` 供纯 Dart 测试 |
| 设置栏扩展（`TYP-01`/`TYP-03`） | 页边距三档 + 主题三态 | `lib/ui/reader_settings_bar.dart` | 两个 IconButton 循环切换；总高度仍 48px（单行 Row） |
| 测试 | 验收 | `test/typography/*`（4 文件 53 条） | TYP-01 字号/行距/字体；TYP-02 anchor 7 组合；TYP-04 parseInlineStyles 白名单 + 14 组脏文本不崩溃 |

### 2.14 M2a-T01 — 内嵌图片渲染与解码缓存

| 项 | 值 |
|---|---|
| 任务 | M2a-T01（PRD `CNT-01`；6 子项：① readResource 接口 ② img 标记保留 ③ WidgetSpan 解析 ④ ImageCacheLRU ⑤ 阅读页接入 ⑥ 测试） |
| 日期 | 2026-09-22 |
| 一句话目标 | EPUB 内嵌插图在阅读页可见；图片字节有界缓存（50MB LRU），不常驻全书（`PERF-02` / `NF-M5`） |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `BookSource.readResource(href)` | 包内任意资源（图片/字体/CSS）按需读取 | `lib/format/book_source.dart` | 抽象默认 `async => null`；`DartTxtSource` 返回 null；`DartEpubSource` 走 `OpfView.readEntry`（`lazyEntryLoader` **每次现解压**，不常驻全书图片字节） |
| `<img>` 标记保留 | 正文提取不丢图 | `lib/epub/section_extractor.dart` | `_walk` 遇 `<img>` 写 `\x00IMG:src\x00`（NUL 包裹，正常文本不会出现）；src 用 `resolveHref(baseDir, src)` 归一化为**绝对包内路径**（`baseDir = p.posix.dirname(section.href)`） |
| `parseContentSpans` | 标记 → `WidgetSpan` | `lib/typography/typeset.dart` | 按 `\x00` 分割：奇数段 = 图片标记 → `WidgetSpan(child: _InlineImage)`；偶数段走 `parseInlineStyles`（`<b>`/`<i>` 复用）。无标记时零开销走纯文本路径 |
| `_InlineImage` 异步加载 | 加载中转圈 / 失败占位图标 | `typeset.dart` | `initState` 发起加载，`_bytes` 缓存在 State（rebuild 不重载）；`Image.memory` + `errorBuilder` 双保险，脏图不崩 |
| `ImageCacheLRU` | 图片字节有界缓存 | `lib/reader/image_cache.dart` | **value = 原始字节**（非 `ui.Image`——#4 已知 `dart:ui` 纯 test 环境构造失败；解码交给 `Image.memory` 内部缓存）；上界 `kDefaultImageCacheMaxBytes = 50MB`，`LinkedHashMap` 插入序 = LRU 序，超限淘汰头部；`dispose()` 清空 |
| 阅读页接入 | 缓存 → readResource 二级读取 | `lib/reader/reader_page.dart` | `_resolveImage`：先查 `_imageCache`，miss 再 `source.readResource` 并入库；`dispose` 时释放缓存；段落渲染 `parseInlineStyles` → `parseContentSpans` |
| 测试 | 验收 | `test/reader/inline_image_test.dart`（12 条） | `parseContentSpans` 5 条（WidgetSpan 产出 / null 占位 / `<b>`+`<img>` 混合 / 连续图）+ `ImageCacheLRU` 7 条（LRU 提升 / 超限淘汰 / 更新计数 / dispose / 50MB 上界） |

### 2.15 M2a-T02 — `<br>` / 表格 / 脚注 / `linear="no"` 四项内容语义

| 项 | 值 |
|---|---|
| 任务 | M2a-T02（PRD `CNT-02` / `CNT-03` / `CNT-04` / `CNT-05`） |
| 提交 | `55bbb27`（CNT-02）→ `16e8508`（CNT-03）→ `b7ff930`（CNT-04a）→ `97d1919`（CNT-04b）→ `7d004db`（CNT-04c-1）→ `c9f1e6f`（CNT-04c-2）→ `3c16acf`（CNT-05）；随批修复书架首点无响应 `3e750b8`、CHANGELOG 单独提交 `a87ab80` |
| 日期 | 2026-09-22 |
| 一句话目标 | 四项内容语义一次接好：`<br>` 与表格进正文、链接可跳可返回原位置、`linear="no"` 可见不丢 |

| 技术点 | 用途 | 落点 | 关键写法或坑 |
|---|---|---|---|
| `<br>` 行内换行（`CNT-02`） | 正文抽取不丢换行 | `lib/epub/section_extractor.dart` | 抽取遇 `<br>` 写行内换行进段落文本；`baseline.json` / `make_fixtures.py` 预期同步 |
| 表格按行退化（`CNT-03`） | 脏表格不崩、内容可读 | 同上 | `<table>` 逐 `tr` 取单元格文本、按行退化为普通段落——**不引表格渲染控件**，退化即交付 |
| 链接与锚点标记（`CNT-04a`） | 抽取层只打标记、不碰 UI | 同上 | `<a href>` → `\x00A:href\x00文字\x00A\x00`、锚点 → `\x00ID:id\x00`（NUL 包裹：正常文本不会出现，渲染时吞掉不上屏）；14 本 fixture 重生成对齐 |
| 链接可点（`CNT-04b`） | 标记 → 可点链接 | `lib/typography/typeset.dart` | `InlineParagraph` 解析 A 标记：`onLinkTap` 为 null 时仅下划线不可点；`didUpdateWidget` 以 `oldWidget.onLinkTap != widget.onLinkTap` 判等——**方法 tear-off 跨帧相等**，故阅读页传同步 tear-off `_onLinkTapped` 而非闭包，防 recognizer 无谓重建 |
| 链接导航器（`CNT-04c-1`） | 跳转纯逻辑可单测 | `lib/reader/link_navigator.dart` | `splitLinkHref`（record 拆 path/fragment）、`findChapterIndex`（匹配键 = 百分号解码 + 小写，找不到 −1）、`findParagraphIndex`（扫 `\x00ID:id\x00`，先原样再解码回退，找不到 −1）、`LinkBackStack`（ScrollAnchor LIFO，空栈 pop 返 null 不抛） |
| 阅读页跳转与返回（`CNT-04c-2`） | 点链接段落级定位 + 一键回原位 | `lib/reader/reader_page.dart` | path 空 → 章内段落定位；path 非空 → 跳章 + 章内定位；任一步找不到**静默忽略绝不抛**；跳转前 `ScrollAnchor.capture` 压 `LinkBackStack`，右下角浮动返回按钮（栈空隐藏）`pop+restore`；段落 `GlobalKey` 懒创建、测段落 box 顶换算内容绝对偏移。坑：断言「恰好 push 一次」须 `find.byType(ReaderPage, skipOffstage: false)`；点链接字形用 `RenderParagraph.getBoxesForSelection` 取盒中心 |
| `linear="no"` 可见并标注（`CNT-05`） | 非主线内容不丢、可辨识 | `lib/epub/epub_parser.dart`、`lib/model/epub_book.dart`、`lib/format/dart_epub_source.dart` | `EpubSectionRef` / `EpubSection` 增 `linear` 字段（默认 true），`linear="no"` 保留进 sections 标 false（**资源过滤 media-type/扩展名/魔数照常**）；`chapters()` 中 toc 已覆盖的标题追加「（非主线）」、未覆盖的按平坦目录补入（同样标注）；`_bindBook` 绑定层透传 linear；fx06 契约随新行为同步（预期章节 2→3、ch2 保留） |
| 书架首点无响应修复（随批 bugfix） | 关书后首点不再被吞 | `lib/ui/shelf_page.dart`、`lib/ui/book_card.dart` | `_opening` 守卫收窄到 push 前准备阶段（push 一发起即释放；关书刷新走 `route.popped.then` 不占守卫）+ 准备期 per-card loading 覆盖层 + `Card(clipBehavior: Clip.antiAlias)>InkWell`（封面/占位走 `Ink.image` / `Ink` 画在 Card 的 Material 上，ripple 不被不透明内容盖住）`3e750b8` |
| FakeAsync 铁律（本批两次实证） | widget 测试可信 | `test/reader/link_navigation_test.dart`、`test/ui/shelf_page_test.dart` | testWidgets 体内禁 await 真异步 IO（FakeAsync 区永久挂死），统一 `_settle`（`runAsync`+`pump` 交替）；路由 pop 过渡 **ticker 首拍才起算**，单帧大 pump 推不完 → 12×50ms 小帧推进，否则 modal barrier 吞点击 |

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
