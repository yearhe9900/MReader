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
| Dart | 3.12.2（随 Flutter 3.44.9-stable） | 应用与解析全部用 Dart，无 JS/WebView | 工程初始化 | `pubspec.yaml`（`environment.sdk: ^3.12.2`） |
| Flutter | 3.44.9-stable（已锁定，不升级） | 纯自绘 UI（不走 WebView / foliate-js） | 工程初始化 | `pubspec.yaml`、各平台目录 |
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
| `archive` | 3.6.1（**锁 3.x**：4.x 改了 `ArchiveFile` API） | zip 解压 EPUB；测试里用 `Archive` + `ZipEncoder` 现造样本 | 工程初始化 | `lib/epub/epub_parser.dart`、`lib/epub/zip_paths.dart`、`test/widget_test.dart`、`test/format/epub_builder.dart` |
| `xml` | 6.6.1 | 严格解析 `container.xml` / OPF / `toc.ncx` / `encryption.xml` | 工程初始化 | `lib/epub/epub_parser.dart`、`lib/epub/epub_toc.dart`、`lib/epub/xml_util.dart` |
| `html` | 0.15.7 | 宽松解析脏 XHTML（正文抽取 + EPUB3 `nav.xhtml`） | 工程初始化 | `lib/epub/section_extractor.dart`、`lib/epub/epub_toc.dart` |
| `charset` | 2.0.1 | GBK / GB18030 解码兜底 | 工程初始化 | `lib/epub/text_codec.dart` |
| `MReaderFormatException` + `kFormatErrorMessages`（自研） | 内置 | 格式错误码 -> 面向用户中文的**唯一来源**（`RD-05`；为 `RUST-04 ②` 的口径一致铺路） | M1-T02A | `lib/format/error_messages.dart` |
| `BookSource` 统一抽象 + 分发点（自研） | 内置 | §7.1 抽象（`load`/`chapters`/`content`/`capabilities`/`search`/`totalCharCount`）+ `BookRegistry`/`sniffFormat`/`openBook` | M1-T02A | `lib/format/book_source.dart`（纯类型）、`lib/format/book_registry.dart`（分发点）、`lib/format/dart_epub_source.dart`、`lib/model/chapter.dart`、`lib/model/chapter_content.dart` |
| `detectEncodingName` 编码名缝（自研） | 内置 | `NF-C4` / §15.6.2：把「探测编码名」与「按名解码」拆开——Rust 首版只替换探测 | M1-T02B | `lib/epub/text_codec.dart` |
| `DartTxtSource` 纯 Dart TXT 源（自研） | 内置 | 照译参考实现 `TextFile.kt` 分章算法（`RD-02`）：规则择优 / 规则分章 / 10KB 分块兜底 | M1-T02B | `lib/format/dart_txt_source.dart` |
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
| Flutter 工程脚手架 + 五平台目录 | 项目基线 | `pubspec.yaml`、`android/`…`linux/` | `environment.sdk: ^3.12.2` 对齐 Flutter 3.44.9 内置 Dart |
| 依赖版本锁定 | 稳定性 | `pubspec.yaml` / `pubspec.lock` | `archive` 锁 3.x（4.x 改 API）；`file_picker` / `xml` / `html` / `charset` / `path` |
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
| **精确锁定** `liquid_glass_widgets: 1.6.2`（**不带 `^`**） | PRD §11.4 的全部「已知限制与应对」都是针对 1.6.2 **逐条实测**得出 | `pubspec.yaml` | `^1.6.2` 会解析到 1.7.0（2026-09-20 发布），与「针对 1.6.2 实测」**自相矛盾**；`pubspec.lock` 解析值 = `1.6.2`。库自身约束 `flutter >= 3.41.0`（本机 3.44.9 满足），且**零 `flutter/material.dart` 依赖**、**未引入任何额外传递包** |
| `cupertino_icons` 必须保留 | PRD §11.4 列为**强制依赖** | `pubspec.yaml` | 从 pubspec 删掉会让玻璃图标渲染成 `?`（库内部用具名图标） |
| 有效亮度跟随**应用 ThemeMode**（`UI-01` ②） | 否则「应用切深色、系统仍浅色」时玻璃亮度错位 | `lib/theme/app_theme.dart`（纯函数 `resolveBrightness`）、`lib/main.dart` | 三态：`light`/`dark` 恒取自身，`system` 取平台亮度。接线方式是 `LiquidGlassWidgets.wrap(brightnessResolver: Theme.maybeBrightnessOf)`，**包裹位置在 `MReaderApp` 之外**——`lib/app.dart` 里 `MaterialApp.builder` 那层透明 `Material` 一字未动 |
| 档位唯一出口 `GlassKit`（`UI-05` 预留） | P0 固定 `standard`，**不引入 `premium`** | `lib/ui/glass_kit.dart` | `kAppGlassQuality = standard`；固定表面的覆盖值 `fixedSurfaceQualityOverride` **恒为 `null`**（传 `null` 即「不覆盖」）。浮层（`GlassDialog.show` / `GlassSheet.show`）显式传 `standard` |
| 「固定表面自动升 premium」是**库的行为**，不是我们的 | 佐证「本项目从不手传 `premium`」 | 复核来源：`liquid_glass_widgets-1.6.2/lib/widgets/surfaces/glass_scaffold.dart:559 / :584` | `GlassScaffold` 对 `appBar` / `bottomBar` 传 `defaultQuality: GlassQuality.premium`，经 `GlassIsolationScope` 下发为子控件的档位提示。**手写 `premium` 会绕过该隔离策略** |
| `OpaqueContentSurface`＝「不透明」唯一出口（`UI-04`） | 内容层各页统一走它，避免各页自己写 `Container(color:)` 各自失守 | 同上 | 底色经 `fullyOpaque()` 强制 `alpha = 1`；内部用 `Material` 同时补上「玻璃库没有 Material 祖先」的坑；**debug 下 `assert` 拒绝玻璃子控件**（玻璃不可嵌套） |
| `isGlassWidget()` 红线可判定化 | 把「不得嵌套玻璃」从文档约定变成可断言的形式 | 同上 | 覆盖库中 37 个 `Glass*` 表面类型（容器 / 交互 / 输入 / 导航 / 浮层）。**已逐类型核对存在于 1.6.2**（`lib/widgets/**/*.dart` 的类声明） |
| `GlassScope`（`InheritedWidget`） | 有效亮度 / 档位 / 玻璃隔离范围收敛一处，下游不必各自猜 | `lib/ui/glass_scope.dart` | `brightnessOf` 三级回退：本作用域 → `GlassTheme.brightnessOf`（库级联）→ …；`qualityOf` → `GlassAdaptiveScopeData.maybeOf(...)?.effectiveQuality` → `kAppGlassQuality`。**本批只备好，尚未接入业务页**（`GlassScopeProvider` 当前无调用方，属预期） |
| 着色器预热 + 诚实降级（`UI-01` ①） | 避免首帧白闪 | `lib/main.dart`（`_warmUpGlassShaders`） | `await LiquidGlassWidgets.initialize()` 包在 `try/catch` 里：**失败只 `debugPrint`、不抛、不阻塞**。⚠️ **待优化**：当前是在 `settings.load()` **之前**串行 `await`，会给冷启动叠加一段着色器预编译时间（`v2.3` 冷启动是硬指标）——可改为与 `appPaths.dataDir()` / `settings.load()` 并行（`Future.wait`） |
| Windows / Linux 被库**静态封顶 `standard`** | 佐证 `NF-C8`「不得宣称五平台等价」与排期「不在本机 Windows 上反复调视觉」（`Q3` / `R8`） | 复核来源：`liquid_glass_widgets-1.6.2/lib/liquid_glass_setup.dart` 的 `_shouldSkipPremiumPreload()` | 对 `kIsWeb` / `windows` / `linux` 返回 `true` → `initialize()` 跳过 premium 多趟着色器预载，`GlassAdaptiveScope` 把这些平台上限压到 `standard`。**本机（Windows）看到的观感与 Android 不一致是库的既定行为，不是配置错误** |
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


