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
| `liquid_glass_widgets` | **计划 1.6.2（本批未引入）** | 玻璃视觉；`main()` 内预热 | 计划 M1-T08 | PRD §11.1 |

### 1.6 格式解析

| 技术 | 版本 | 用途 | 引入批次 | 落点文件 |
|---|---|---|---|---|
| `archive` | 3.6.1（**锁 3.x**：4.x 改了 `ArchiveFile` API） | zip 解压 EPUB；测试里用 `Archive` + `ZipEncoder` 现造样本 | 工程初始化 | `lib/epub/epub_parser.dart`、`lib/epub/zip_paths.dart`、`test/widget_test.dart`、`test/format/epub_builder.dart` |
| `xml` | 6.6.1 | 严格解析 `container.xml` / OPF / `toc.ncx` / `encryption.xml` | 工程初始化 | `lib/epub/epub_parser.dart`、`lib/epub/epub_toc.dart`、`lib/epub/xml_util.dart` |
| `html` | 0.15.7 | 宽松解析脏 XHTML（正文抽取 + EPUB3 `nav.xhtml`） | 工程初始化 | `lib/epub/section_extractor.dart`、`lib/epub/epub_toc.dart` |
| `charset` | 2.0.1 | GBK / GB18030 解码兜底 | 工程初始化 | `lib/epub/text_codec.dart` |
| `MReaderFormatException` + `kFormatErrorMessages`（自研） | 内置 | 格式错误码 -> 面向用户中文的**唯一来源**（`RD-05`；为 `RUST-04 ②` 的口径一致铺路） | M1-T02A | `lib/format/error_messages.dart` |
| `BookSource` 统一抽象 + 分发点（自研） | 内置 | §7.1 抽象（`load`/`chapters`/`content`/`capabilities`/`search`/`totalCharCount`）+ `sniffFormat`/`openBook` | M1-T02A | `lib/format/book_source.dart`、`lib/format/dart_epub_source.dart`、`lib/model/chapter.dart`、`lib/model/chapter_content.dart` |
| `file_picker` | 8.3.7 | 选择本地 EPUB；`withData: true` 走 bytes，避免 `dart:io` 进入解析链路 | M1-T01 | `lib/main.dart` |

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
| 目录双路径（`RD-01`） | nav（`properties` 含 `nav`）/ ncx（`application/x-dtbncx+xml` 或 `.ncx`） | `lib/epub/epub_toc.dart` | **nav 里的 href 相对 nav 文件自身，不是相对 OPF 目录**（最容易错的一点，已用「nav 在子目录 + href 带 `../`」用例覆盖）；两条路径皆空 -> 返回空列表，由调用方降级为平坦目录 |
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
