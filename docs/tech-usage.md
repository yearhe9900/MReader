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



