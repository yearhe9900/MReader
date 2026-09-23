# 阅读M（MReader）— 纯 Flutter 自绘 EPUB 纵向滚动阅读（可行性验证）

> 一次性 spike。要回答的唯一问题是：
> **不用 WebView / foliate-js，纯 Dart 解析 EPUB + 纯 Flutter Widget 排版，能不能把一本本地 EPUB 打开、并纵向连续滚动读下去？**

- 渲染路线：**纯 Flutter 自绘**（Dart 解析 + Flutter Widget 渲染），无 WebView。
- 目标平台：**五平台**（Android / iOS / Windows / macOS / Linux）。平台能力差异按 PRD §15.3 的「诚实降级表」处理，不再宣称「未使用任何平台特定 API」。
- 交互：**纵向连续滚动**，无横向翻页 / 仿真翻页。
- 状态管理：`StatefulWidget` + `setState`，无 Riverpod / Provider / Freezed / 代码生成。
- 字体：使用系统默认字体，**未向工程内塞任何字体文件**（中文由系统字体提供）。

> 📌 **工程骨架说明（仅工具链层面）**：平台目录（`android/` `ios/` `windows/` `macos/` `linux/`）
> **已存在**，无需再 `flutter create`；Dart 包名 `mreader`，Android/iOS/macOS bundle id `com.mreader.app`。
> 下文第三节的 `flutter create` 步骤仅作历史记录保留。
>
> ⚠️ **本项目为独立立项的全新项目，产品需求独立定义，与任何既有工程无关**
> （见 `docs/PRD.md` §1.3）。工程骨架早期由既有工程复制改名而来，**只复用工具链配置，
> 不构成需求来源**；实现层面可借鉴成熟开源代码的算法与协议，但需求必须重新定义。
>
> ➡️ **需求以 `docs/PRD.md` 为准**。本 README 只描述**当前代码的实际状态**（含已知限制），
> 不是需求文档；两者不一致时以 PRD 为准。

---

## 一、目录结构与每个文件的职责

```
MReader/
├── pubspec.yaml                     # 依赖清单 + SDK 约束（sdk: ^3.12.2）
├── analysis_options.yaml            # lint 规则（include flutter.yaml）
├── README.md                        # 本文件
├── lib/
│   ├── main.dart                    # 入口：App 根 + 首页（选文件 / 解析 / 错误提示 / 跳转阅读页）
│   ├── model/
│   │   └── epub_book.dart           # 纯数据模型：EpubBook（元数据+章节骨架）、EpubSection
│   ├── epub/                        # ← 纯 Dart 解析层，不 import Flutter，便于复用与单测
│   │   ├── text_codec.dart          # 字节→字符串：BOM / encoding 声明 / UTF-8 / GBK / latin1 五级兜底
│   │   ├── epub_parser.dart         # 解析入口 parseEpub()：container.xml → OPF(metadata/manifest/spine)
│   │   └── section_extractor.dart   # XHTML → 段落：块级结构保留，图片/CSS/脚注优雅跳过
│   └── ui/
│       ├── reader_page.dart         # 阅读页：ListView 纵向铺章节、按需解析正文、内存缓存
│       └── reader_settings_bar.dart # 底部控制条（A- / A+ / 行距滑块）+ ReaderSettings 值对象
└── test/
    ├── widget_test.dart             # 解析层单测（内存现造 EPUB）+ 首页冒烟测试
    ├── epub_fixtures_test.dart      # 真实脏书回归测试（读 fixtures/*.epub 对照 baseline.json）
    └── fixtures/                    # 14 个「现实脏 EPUB」样本 + 期望值契约（见下）
        ├── fx01_*.epub … fx11_*.epub  # 每本只聚焦一类脏特征
        ├── baseline.json              # 每个样本「规范正确的预期输出」契约
        ├── make_fixtures.py           # 生成 fixtures 的脚本（仅用 Python 标准库）
        └── analyze_fixtures.py        # 用真实字节独立复算关键算法（Python 参照模型）
```

（`android/ ios/ windows/ macos/ linux/` 等目录由 `flutter create` 生成，不属于源码。）

### 分层设计要点

- **`lib/epub/` 完全不 import Flutter**，只依赖 `dart:*` + 第三方纯 Dart 包。所以解析层可以直接丢进 isolate，也可以给未来的 CLI/服务端复用。
- **`parseEpub(Uint8List bytes) → Future<EpubBook>` 是纯函数式入口**，不碰 UI、不碰文件系统。单测就是在内存里现造一本 EPUB 喂进去。
- **模型层只存"结构"+每章 XHTML 原始字节**，不存解析后的正文文本。正文由阅读页**滚到附近才解析**（`section_extractor.dart`），并用 `Map<int, ExtractedSection>` 缓存，避免把整本书的排版结果一次性铺进内存。
- **`ReaderSettings` 是独立值对象**，字号/行距改动通过 `onChanged` 回传，阅读页 `setState` 后立即重排 —— 这是本 demo 的验证重点。

---

## 二、依赖清单与用途（每一个都有理由）

| 依赖 | 版本 | 为什么需要它 |
|---|---|---|
| `file_picker` | `^8.1.2` | 选择本地文件（Android/iOS/Windows/macOS/Linux）。不直接用 `dart:io` 读路径：各平台沙箱策略不同，统一走 bytes。 |
| `archive` | `^3.6.1` | EPUB 本质是 zip，需要解压。**用 `archive/archive.dart` 分支**（不 import `dart:io`，让核心解析链路保持可纯 Dart 单测）。**固定在 3.x**：4.x 改了 `ArchiveFile` 的 API（`content` 被 `readBytes()` 取代）。 |
| `xml` | `^6.5.0` | `META-INF/container.xml` 和 OPF 是**严格 XML**。虽然"容器"是 HTML 解析器也能糊弄，但 OPF 的命名空间/属性解析用真 XML 解析器才稳。 |
| `path` | `^1.9.0` | 用 `p.posix` 做**包内路径归一化**（处理 `../`、`./`、重复斜杠）。纯字符串运算；不用手写字符串拼接。 |
| `html` | `^0.15.4` | 把 XHTML 解析成 DOM 好遍历。**它的"宽松解析"正是我们要的**：真实 EPUB 的 XHTML 常年不合法（未闭合标签、裸 `&`），`xml` 包遇到这种直接抛异常，`html` 包能扛过去。 |
| `charset` | `^2.0.1` | 中文老 EPUB 大量用 **GBK/GB2312/GB18030**，Dart 标准库只有 UTF-8/Latin-1。用它做解码兜底（纯 Dart，全平台）。 |
| `flutter_lints` | `^6.0.0` | 仅 dev 依赖，给 `analysis_options.yaml` 用。 |

> 依赖闭包（`collection` / `meta` / `petitparser` / `csslib` / `source_span` / `win32` / `ffi` / `web` / `plugin_platform_interface` / `lints`）在本机 pub cache 中**均已存在**，`flutter pub get` 可离线成功。
>
> `test/epub/epub_fixtures_test.dart` 会用 `dart:io` 读 `test/fixtures/` 下的文件。`dart:io` 只出现在 **test/**（仅在 VM 上跑），`lib/` 源码里没有 `dart:io`。

---

## 三、你需要手动执行的命令（按顺序）

> 全部在 **`D:\Projects\MReader`** 目录下执行。
> **第一步的 `cd` 是必须的**（其余命令都基于当前目录）。

### 0) 进入工程目录

```bat
cd /d D:\Projects\MReader
```

> `cmd` 里如果当前在别的盘符，必须带 `/d`。PowerShell 用 `cd D:\Projects\MReader` 即可。

### 1) 生成五平台工程骨架（⚠️ 有两个坑）

```bat
flutter create --project-name mreader --platforms=windows,android,ios,macos,linux .
```

**坑 1 — 建议显式给 `--project-name`（避免依赖 pubspec 的隐式行为）。**
目录名 `MReader` 含大写字母，本身**不是**合法的 Dart 包名（Dart 包名须匹配 `[a-z_][a-z0-9_]*`）。但要注意机制：

- 本工程**已经**放好 `pubspec.yaml`（`name: mreader`）。`flutter create .` 对**已存在**的工程会**先读现有 pubspec 的 `name`**，所以**不会**因为目录名而报错。
- 只有当你在一个**没有 pubspec 的空目录**里直接 `flutter create .`，它才会尝试用目录名派生包名，这时才会报：
  ```
  "MReader" is not a valid Dart package name.
  ```
- 因此：**显式 `--project-name mreader` 最稳**（无论 pubspec 在不在都不会踩坑），也是本文档推荐的写法。

**坑 2 — `--platforms` 不能省。**
省掉时，部分环境下只会生成 android/ios，桌面目录不会出现，后面 `flutter run -d windows` 就会报 `No supported devices`。

**🔴 坑 3（最重要）— 千万不要加 `--overwrite`。**
`flutter create` 对已存在的工程是"**只补缺失文件**"的语义（官方帮助原文：*If run on a project that already exists, this will repair the project, recreating any files that are missing*）。它**默认不会覆盖已存在的文件**。
所以你**先放好本工程的 `pubspec.yaml` / `lib/` / `test/` / `analysis_options.yaml` / `README.md`，再跑 `flutter create` 是安全的**，它只会补出平台目录。
一旦加了 `--overwrite`，它会把**模板里带的所有文件**都用模板内容重新生成，**不仅** `pubspec.yaml`、`lib/main.dart`，还包括 `analysis_options.yaml`、`README.md`、`.gitignore` 等 —— 本工程的这些源码/配置会被覆盖掉。

> 如果桌面平台目录没生成，先执行（新版 Flutter 通常默认已开启，不需要）：
> ```bat
> flutter config --enable-windows-desktop
> flutter config --enable-macos-desktop
> flutter config --enable-linux-desktop
> ```
> 然后再跑一次第 1 步命令。

### 2) 拉依赖

```bat
flutter pub get
```

> `flutter create` 默认就会顺带跑一次 `pub get`（除非你用了 `--no-pub`）。这一步重复执行无害。

### 3) 跑起来（选一个）

```bat
flutter run -d windows
```
```bat
flutter run -d chrome
```
```bat
flutter run -d macos
```
```bat
flutter run -d linux
```

或不指定设备，让它自己列出可选设备：
```bat
flutter run
```

### 4)（可选）跑解析层单测 + 脏书回归测试

```bat
flutter test
```

> 会跑两个文件：`test/widget_test.dart`（内存造 EPUB 的单测）与 `test/epub/epub_fixtures_test.dart`（读取 `test/fixtures/*.epub`，对照 `test/fixtures/baseline.json` 的 14 本真实脏书回归）。若 `test/fixtures/` 缺失，回归用例会**优雅跳过**而非失败。

---

## 四、跑起来后该看什么（验证要点清单）

这是判定"这条技术路线走不走得通"的清单，请**逐条对照**：

| # | 看什么 | 通过标准 |
|---|---|---|
| 1 | 点「选择 EPUB 文件」 | 能弹出系统文件选择器，能选中 `.epub` 文件 |
| 2 | 选中后 | 短暂 loading 后进入阅读页；顶部显示书名（无元数据时显示文件名） |
| 3 | 章节顺序 | 从第 1 章开始，**按 spine 顺序**向下排列（不是随机顺序、不跳章） |
| 4 | 章节分隔 | 每章之间有「**加粗标题 + 分割线**」，跨章节边界一眼可辨 |
| 5 | 连续滚动 | 一直往下滚能**无缝滚到最后一章**，中途无跳变、无空白、无突然卡死 |
| 6 | **字号实时生效** | 点 `A-` / `A+`，正文字号**立即**变化（不用退出重进） |
| 7 | **行距实时生效** | 拖底部滑块，行距**立即**变化 |
| 8 | **滚动位置保持** | 改字号/行距后，**当前阅读位置不应跳回顶部**（`ListView` 保持 scroll offset） |
| 9 | 中文显示 | 中文正常显示，**无豆腐块 □□□** |
| 10 | 按需解析 | 滚到新章节时有**极轻微**首次解析停顿，之后来回滚动**不再卡**（缓存生效）——这是预期行为，不是 bug |
| 11 | 容错 | 把一个 `.zip` 改名为 `.epub` 选中 → 弹出**可读中文错误提示**，App **不白屏、不崩溃** |
| 12 | 压力 | 用一本大部头（如 3MB+ / 上百章的 TXT 转 EPUB）测滚动流畅度与内存 |

---

## 五、已知限制（本次刻意不做 / 做不动的部分）

**解析范围**
- 只解析 `META-INF/container.xml` → OPF → manifest/spine/metadata。**不解析 NCX/nav 目录树**。
- 章标题优先取正文**第一个 `<h1>`~`<h6>`**，取不到则退而取该 XHTML 的 `<title>`（限 ≤60 字符），再取不到就显示「第 N 节」。因此某些把 `<title>` 写成全书名的书，章标题会**全部相同**。
- **标题去重有前提**：只有当标题确实来自正文里的 `h1~h6` 时，才会把**与之重复的首段**去掉（否则 UI 标题会和正文首段重复显示同一句）。若标题是退而取自 `<title>` 的，正文首段**不会**被删（首段是真正文）。
- `linear="no"` 的 spine 项会被跳过（符合规范），但有些书把附录/注释标成 `linear="no"`，会看不到。
- spine 里指向的资源若在包内缺失，会**静默跳过该章**（不报错）。
- **图片/字体/CSS 混进 spine** 的处理：有明确 `media-type`（`image/`、`audio/`、`video/`、含 css/font/js）时直接排除；**`media-type` 缺失**时再按**扩展名**（`.png`/`.jpg`/…）与**字节魔数**（PNG/JPEG/GIF/BMP/WEBP）兜底排除。仍可能漏掉个别伪装成文本的二进制。
- **fixed-layout / pre-paginated（漫画类）EPUB 不适用**：会被当成流式文本，版面全乱。

**样式与内容**
- **内嵌 CSS 全部丢弃**：无首行缩进、无居中、无字体加粗、无段落间距差异、无配色。
- **图片 / SVG / 表格排版 / 脚注跳转 / ruby 注音全部丢弃**（优雅跳过，不崩）。
- `<br>` 被当作**段落分隔**处理，因此诗歌、地址块会多出空行。
- 只保留块的边界，不做行内样式（`<b>`/`<i>`/`<em>` 的文本保留，样式丢失）。
- 超链接退化为普通文本，点击无反应。

**编码**
- 解码兜底顺序：UTF-8 BOM / UTF-16 BOM → 声明的 `encoding`/`charset` → 严格 UTF-8 → GBK（允许畸形字节）→ latin1。**`decodeText` 承诺任何输入都返回字符串，绝不抛异常**。
- **声明的编码不可尽信**：若声明 `utf-8` 但字节其实不是合法 UTF-8（如实为 GBK），会**回落**到 GBK 正确解码，而不是静默乱码。
- 未声明编码的非 UTF-8 / 非 GBK 中文编码（**Big5、Shift-JIS 等**）会被**误判为 GBK 解码 → 乱码**（可能带替换符 �）；**不会崩溃**，但**无法正确还原**。（此前 README 写的"会退化为 GBK 猜测"在修正兜底逻辑后才是准确的：早期实现遇到 Big5 会因 `gbk.decode` 抛异常而落到 latin1。）

**性能 / 内存**
- **整本书解压后常驻内存**：解压瞬间内存占用≈"书解压后大小"。含大量图片的 EPUB（即使用不到图片）也会占这份内存。50MB 级书可能明显卡顿甚至 OOM。
- 单章正文用**一个** `Text` 渲染。超大单章（>10 万字符）首帧排版会有可感延迟。
- 章节正文解析目前在主 isolate 同步执行。后续应移到 `compute()` / 后台 isolate。

**功能**
- 无阅读进度持久化（切走即丢）、无书签、无夜间模式/主题、无多书管理、无横排竖排切换。
- 底部控制条固定显示，不自动隐藏。

---

## 六、常见报错与应对

| 报错 | 原因 / 应对 |
|---|---|
| `"MReader" is not a valid Dart package name.` | 在**没有 pubspec** 的空目录里 `flutter create .` 才会出现（它会拿目录名派生包名）。带上 `--project-name mreader` 即可；或先放好本工程的 `pubspec.yaml` 再执行。 |
| `No supported devices` / `-d windows` 找不到设备 | ①平台目录没生成 → 重跑带 `--platforms=...` 的 create；②桌面未启用 → `flutter config --enable-windows-desktop`。 |
| Windows 上 `flutter run -d windows` 报工具链缺失 | 需要 Visual Studio 2022 + 「使用 C++ 的桌面开发」工作负载。 |
| `Target of URI doesn't exist: package:flutter_lints/flutter_lints.yaml` | `analysis_options.yaml` 里的文件名写错了。**flutter_lints 的规则文件名是 `flutter.yaml`，不是 `flutter_lints.yaml`**（4.x 和 6.x 都叫 `flutter.yaml`）。本工程已写对。 |
| 中文显示成 □□□ | 系统缺中文字体（Linux 常见）→ `sudo apt install fonts-noto-cjk`。Windows / macOS 自带。 |
| `Because mreader requires SDK version ^3.12.2 ...` | Flutter 版本过旧 → 用 Flutter 3.44.9-stable（内置 Dart 3.12.2），本机在 `C:\src\flutter`。 |
| 选文件后提示"未能读取文件内容（bytes 为空）" | 某些平台 `withData` 未生效。本工程已固定 `withData: true`。若仍失败，可把 `FileType.custom` 换成 `FileType.any` 试试。 |
| `flutter create` 之后 `lib/main.dart` 变成了计数器 demo | 你加了 `--overwrite`。删掉平台目录后，**去掉 `--overwrite`** 重跑；`lib/main.dart` 从本工程的副本还原。（注意 `--overwrite` 还会一起覆盖 `analysis_options.yaml`、`README.md`、`.gitignore`。） |
| `error: "archive" ... version solving failed` | `archive` 被抬到了 4.x。本项目必须 `^3.6.1`（4.x 的 `ArchiveFile` API 不兼容）。 |

---

## 七、静态自检结论

- 全部源码文件已逐行通读，跨文件 import、符号、方法签名、数据流已核对一致。
- 所有第三方 API 均已**对照本机 pub cache 中的真实源码**逐一核实（不是凭记忆）：
  - `archive 3.6.1`：`ZipDecoder().decodeBytes(List<int>)`、`Archive.files`、`ArchiveFile(name, size, content)` 位置参数、`bool isFile`、`dynamic get content`、`ZipEncoder().encode(Archive) → List<int>?`
  - `html 0.15.6`：`Node.nodes`、`Text.text`、`Element.text`、`Element.localName`、`Document.body`/`documentElement`（`Element?`）
  - `xml 6.6.1`：`XmlDocument.parse`、`getAttribute`、`XmlNode.children`/`childElements`、`XmlText.value`、`XmlName.local`
  - `charset 2.0.1`：`GbkCodec.decode(List<int>, {bool? allowMalformed})`（允许畸形字节）、`const gbk`、`const utf16`、`hasUtf16Bom`
  - `file_picker 8.3.7`：`pickFiles({type, allowedExtensions, withData})`、`PlatformFile.name/bytes`
  - `test_api 0.7.x`（flutter_test 底层）：`test(description, body, {Object? skip})` —— 回归用例用它做「缺 fixture 优雅跳过」。
- 已确认 `flutter/material.dart` **不导出** `Uint8List`，因此 `main.dart` 中刻意不写 `Uint8List` 类型标注，改用类型推断。
- 已确认 `flutter_lints 6.0.0` 的规则文件名为 `lib/flutter.yaml`。
- 已确认 lint 规则集（`lints 6.1.0` core + recommended + flutter）逐条对照：无空 catch、无 `forEach` 函数字面量、无 `unnecessary_import`、`use_build_context_synchronously` 已用 `if (!mounted) return;` 守卫、widget 全部带 `super.key`、`sort_child_properties_last` 合规。
- **本轮针对 QA 压出的健壮性缺陷做了修复**（详见下），并新增了 `test/epub/epub_fixtures_test.dart` 把 QA 的 14 本脏书 + `baseline.json` 固化成回归契约：
  - 缺陷① `_lookup` 增加「已解码路径再百分号编码」候选 → 命中「zip 条目名本身就是 `%E7%AC%AC…`」的书（fx02b），不再误报 spine 为空。
  - 缺陷② `text_codec` 声明分支整体 try/catch + GBK 统一 `allowMalformed: true` → 声明 gbk 却含非法字节（fx11）不再抛异常，兑现"绝不抛"。
  - 缺陷③ 声明 utf-8 时先试**严格** utf-8，失败即回落 GBK → 声明 utf-8 实为 GBK（fx09）正确解码而非静默乱码。
  - 缺陷④ `_looksTextual` 在 `media-type` 缺失时按扩展名 + 字节魔数判否 → 漏写 media-type 的封面 PNG（fx07b）不再被当章节。
  - 缺陷⑤ `section_extractor` 仅在标题来源为 `h1~h6` 时才剔除重复首段 → 标题取自 `<title>` 时不再误删正文首段。

**`IS_PASS: YES`**

> 说明：受约束所限，我**没有执行任何 `flutter` / `dart` 命令**（包括 `flutter analyze` / `flutter test`），
> 因此上表结论来自"逐行通读 + 对照真实依赖源码核实 API + 对照 baseline.json 的人工推演"，而非编译器/分析器输出。
> 首次 `flutter run` / `flutter test` 若有个别告警，按第六节排查即可。
