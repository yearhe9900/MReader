# 更新日志（Changelog）

> 格式：Keep a Changelog 简化式。日期用 `YYYY-MM-DD`，**按日期倒序**排列。
> 书写约定：每条一句话、**不复述过程**（分析、根因链、教训留在 PRD 与 `.workbuddy/memory/`），条目末尾附 commit hash 便于追溯。

## 2026-09-23

### 新增

- M2a-T03 数据层：BookRecord 增 intro 与书名/作者/简介/封面四来源标记（枚举名落盘，旧索引缺失回 none）`4fc5d16`
- M2a-T03 导入带来源：ImportService 构造记录时带入 intro + 四来源（新导入来源天然正确，META-08②）`4fc5d16`
- M2a-T03 仓库更新口：LibraryRepository.updateRecord 整体替换同 bookId 条目（编辑/恢复自动值落盘通道）`4fc5d16`

## 2026-09-22

### 新增

- M1-T04 阅读进度模型：ReadingProgress + 设备本地版面快照 localHint（不参与跨设备同步）`d082c6a`
- M1-T04 进度持久化：ProgressStore 每本一文件 + bookId 白名单防路径穿越 `d082c6a`
- M1-T04 阅读页：章节连续滚动（全章塞一个 ListView）+ GlobalKey 探测当前章 / 章内位置 `f196d39`
- M1-T04 进度恢复：同版面 initialScrollOffset 精确落回，否则按章序估算 + 校正 ≤3 帧 `f196d39`
- M1-T04 目录与副标题：TocSheet 高亮跳章（NAV-01）+「第N章 · X%」去诊断（RD-03）`f196d39`
- M1-T07 内存收敛（PERF-02）：EPUB 结构解析只建条目名索引，正文按需、图片/字体/CSS 不再常驻 `e16da96`
- M1-T07 正文增量加载（PERF-02）：阅读页首帧只等目标章 ±1，后台按距离逐批补齐 + 有界 LRU（30 章）`f84b470`
- M1-T07 隔离执行底座（PERF-01）：`compute()` 薄封装 IsolateRunner（本任务不接线到 `load()`）`9c9ff93`
- M1-T07 性能基线（PERF-02/03）：样本生成器 + BookSource 层首屏测量 + 纯 Dart 懒加载验收 `9be18ed`
- M1-T07 收尾（PERF-01 底座）：`parseEpubStructure(bytes, fileName:)` 产出**无闭包纯数据**结构（sections / toc / metadata / 封面候选 href / 条目名索引），可跨 isolate；`parseEpubResult` 保留签名，内部 = structure + 在**本 isolate** 绑定 `loadBytes` / `readEntry`
- M1-T07 收尾（PERF-02 ①）：`EpubSection.rawBytes` **去掉无界缓存**（每次访问现取）；新增 `zip_paths.dart` `lazyEntryLoader` 从**压缩态**每次现解（STORE 原样 / DEFLATE 走 `inflateBuffer`），绕开 archive `ArchiveFile.content` 的永久 `_content` 缓存
- M1-T06 排版与阅读设置（`TYP-01` ~ `TYP-04`）：`ReaderSettings` 扩展（字号/行距/字体/主题/页边距）+ `resolveTextStyle` 单一出口 + `parseInlineStyles`（`<b>`/`<i>` 白名单）+ 首行缩进 + 标题居中 + `ScrollAnchor` 位置锚定 + 页边距/主题三态切换
- M1-T09 交付验收：§17 逐条判定全 PASS；全量 `flutter test` 279 passed / 1 failed（#4 cover_store_test 不阻塞）；性能基线 §7 归档（供 M2a-T06 before 对照）
- M2a-T01 内嵌图片渲染（`CNT-01`）：`BookSource.readResource(href)` 接口（EPUB 按需解压 / TXT 返回 null）+ `section_extractor` 保留 `<img>` 标记（src 归一化为绝对包内路径）+ `parseContentSpans` 解析为 `WidgetSpan`（异步加载 / 失败占位不崩）+ 阅读页接入
- M2a-T01 图片有界缓存（`NF-M5` / `PERF-02`）：`lib/reader/image_cache.dart` `ImageCacheLRU`（key=href，value=原始字节，上界 50MB，LRU 淘汰，`dispose` 清空）；阅读页 `_resolveImage` 经缓存读取，图片字节不常驻全书
- M2a-T02 `<br>` 行内换行（`CNT-02`）：正文抽取保留 `<br>` 为行内换行，fixture baseline 同步 `55bbb27`
- M2a-T02 表格按行退化渲染（`CNT-03`）：`<table>` 逐行提取单元格文本退化为普通段落，脏表不崩 `16e8508`
- M2a-T02 链接与锚点标记（`CNT-04a`）：正文抽取保留 `<a href>` 与锚点 ID（NUL 包裹标记，渲染不上屏），14 本 fixture 重生成对齐 `b7ff930`
- M2a-T02 链接可点（`CNT-04b`）：typeset 解析链接标记为可点下划线 span（onLinkTap，null 时仅下划线）`97d1919`
- M2a-T02 链接导航器（`CNT-04c-1`）：splitLinkHref / findChapterIndex / findParagraphIndex / LinkBackStack 纯逻辑 + 单测 `7d004db`
- M2a-T02 阅读页链接跳转（`CNT-04c-2`）：点链接章内段落级 / 跨章定位，浮动「返回」按钮经 LinkBackStack 恢复原位置 `c9f1e6f`
- M2a-T02 `linear="no"` 可见并标注（`CNT-05`）：spine 非主线项保留进章节总数并标「（非主线）」，资源过滤照常 `3c16acf`

### 变更

- M1-T07 EpubSection 增惰性构造 `.lazy`（`rawBytes` 保留为 getter，消费方零改动）；spine 文本性判定改由 `textualVerdict` 仅凭声明完成 `e16da96`
- M1-T07 收尾：封面候选 `readEntry` 改为按 href **现查**（不再急切解压、常驻全部候选字节）；`dart_epub_source.dart` 顶部「整个对象可直接丢进 `compute()`」的错误注释修正为「`parseEpubStructure` 纯数据跨 isolate，`loadBytes` / `readEntry` 闭包在本 isolate 绑定」

### 修复

- 书架「首点无响应」：开书守卫收窄到 push 前准备阶段（关书后首点不再被吞）+ 准备期卡片 loading 覆盖层 + 书卡 GestureDetector 改 InkWell 按压反馈 `3e750b8`

## 2026-09-21

### 新增

- M1-T03 书库数据层：BookRecord + BookIndex 逐条降级索引（LIB-02/03）`5bd1d8b`
- M1-T03 导入管道：ImportService SHA-256 前 16 位判重 + 副本 + 封面物化（LIB-02/05）`f797913`
- M1-T03 书库仓库：LibraryRepository 判重 / 删除连带清理 / 孤儿 GC（LIB-01/05/06）`f797913`
- M1-T03 书架 UI：ShelfPage 网格 + 导入 + 长按删除二次确认（LIB-01~06）`60c5171`
- M1-T05 元数据模型：BookMeta 落 lib/model/book_meta.dart（唯一）+ MetaOrigin/CoverRef/intro/auto `c8d06ca`
- M1-T05 EPUB 元数据：OpfView 四来源封面链（命中即停）+ 多作者整体保留（META-02/03）`f168d1d`
- M1-T05 TXT 元数据：文件名规则链 + 清洗 + 精确化兜底（META-04）`f168d1d`
- M1-T05 封面存储：CoverStore 落盘 covers/ + 缩略图 + 孤儿 GC（META-05/06）`e0d9a4c`
- M1-T05 合成封面：SynthCoverRenderer + CoverTheme 日/夜（META-07）`e0d9a4c`
- M1-T05 封面序列化：CoverRef↔JSON 唯一出口，PendingCover 遇序列化抛 StateError `e0d9a4c`
- M1-T08 依赖接入：`liquid_glass_widgets` 1.6.2 + `cupertino_icons`（玻璃图标强制依赖）`348ce23`
- M1-T08 主题基建：`AppTheme` 浅/深主题 + 有效亮度解析（`UI-01` ②）`08c2b65`
- M1-T08 玻璃基建：`GlassKit` 档位唯一出口 + `OpaqueContentSurface` 内容层不透明唯一出口（`UI-04`）`08c2b65`
- M1-T08 玻璃作用域：`GlassScope` 收敛有效亮度 / 档位 / 玻璃隔离范围 `08c2b65`
- M1-T08 着色器预热：`main()` 内 `LiquidGlassWidgets.initialize()`，失败不阻塞启动 `08c2b65`
- M1-T08 测试：主题三态 / 玻璃档位 / 透明 Material 地基三组单测 `46810eb`
- M1-T02B 测试：dispose 契约用例（两源，释放后空结果 + 竞态不抛）`be1838f`
- M1-T02B TXT 源：DartTxtSource 照译 TextFile.kt 分章算法（RD-02）`bd2466d`
- M1-T02B 编码名缝：text_codec.detectEncodingName（NF-C4，供 Rust 只探测编码名）`f39deb1`
- M1-T02B 应用接线：首页/阅读页改吃 BookSource，支持 EPUB + TXT `0da0c5b`
- M1-T02B 测试：dart_txt_source 单测 + 契约追加 dart-txt 样本 `0da0c5b`
- M1-T02A 格式抽象：BookSource + 分发点 openBook/sniffFormat `c9827fe`
- M1-T02A EPUB 目录：nav/ncx 双路径，level 取真实嵌套深度 `c9827fe`
- M1-T02A 加密拒绝：encryption.xml 判定，字体混淆不误杀（RD-05）`c9827fe`
- M1-T02A 错误文案：MReaderFormatException 唯一中文来源 `c9827fe`
- M1-T02A 纯 Dart EPUB 源：惰性解析 + 搜索 + 字符数（STAT-14）`c9827fe`
- M1-T02A 测试：9 个 fixture 对齐 + 契约骨架 + 文案护栏 `38fcb2f`
- M1-T01 落盘通道：原子写入 + JSON 四态回退（DATA-01）`8ed83f3`
- M1-T01 平台抽象：应用路径、凭据接口与设置持久化 `6a63b59`
- M1-T01 应用骨架：构造注入与透明 Material 地基 `dbf3bfa`

### 变更

- `liquid_glass_widgets` 升级 1.6.2 → 1.7.0（负责人决定；PRD §11.4 已知限制原针对 1.6.2，升级后需重新验证）`c996106`
- M1-T08 玻璃库精确锁定 1.6.2（不带 `^`）：§11.4 限制均针对 1.6.2 实测，`^1.6.2` 会解析到 1.7.0 `348ce23`
- M1-T08 档位策略：固定表面不手传 `premium`（由库自动提升），浮层与滚动区固定 `standard` `08c2b65`
- M1-T08 亮度口径：玻璃亮度跟随**应用 ThemeMode**（三态），而非仅系统亮度（`UI-01` ②）`08c2b65`
- M1-T02B 分章阈值口径升格为本项目 canonical 定义（字符级；Rust 不得照抄参考实现字节口径）`4c1c849`
- M1-T02B 择优性能：TXT 规则择优只跑首个 512KB 块，20MB 由分钟级降到百毫秒级 `bd2466d`
- M1-T02B 文件名兜底：`.txt` 这类无书名的名字回落「未命名」`bd2466d`
- §15.4 依赖清单补录 path_provider（应用数据目录）`9194a89`
- M1-T02A EpubParseException 退休为 @Deprecated 子类，异常统一收敛 `c9827fe`
- M1-T02A 收尾：目录项并入 Chapter、分发点移入 book_registry `449b135`

### 移除

- M0-T02 删除书源原型代码与测试共 21 个文件（Q24）`236cead`

### 修复

- M1-T04 测试：`shelf_page_test` / `widget_test` 的 FakeAsync 挂死——widget 内真 IO 不推进 + 载入动画致 `pumpAndSettle` 超时，改 `runAsync` + `pump` 交替助手 `f196d39`
- M1-T08 冷启动：着色器预热与 `settings.load()` 改 `Future.wait` 并行（消除串行叠加的预编译延迟）
- M1-T02B dispose 竞态：两源释放后/竞态中返回空结果、不抛（RUST-01）`4c1c849`
- Android 构建：插件模块 compileSdk 统一提升到 36 `11c5198`
- M1-T05 dispose 占位 BookMeta：两源释放态作者统一改用兜底「未知作者」，满足 `author` 非空不变式（并补测试断言；附带修正 TXT dispose 用例把 `MetaOrigin` 误比作字符串 `'none'` 的既有断言）`a153313`
- M1-T05 合成封面缓存有界化：`_cache` 改保序 LRU，上限 `kSynthCoverCacheMaxEntries`=32（≈61 MB 最坏），逐出即 `ui.Image.dispose()`（`META-05` 缓存上限）`d645fea`
- M1-T05 合成封面并发渲染去重：同 key 共享 in-flight future 只保一张图，防「后写覆盖、前者永不释放」`d645fea`

## 2026-09-20

### 新增

- 建立 PRD 并迭代至 v2.3（新增阅读统计与元数据域、移除 UMD）`afa499e`…`c7e0e83`
- 新增 Rust 集成架构文档与全项目开发排期 `e69f0ff`、`be6f73e`

### 变更

- PRD v2.4：引入 Rust 可选加速层，放弃 Web（六平台 → 五平台）`b60cdb7`
- PRD v2.5→v2.6：拆分 2a/2b、阈值合计口径与 MOBI 补录 `ea2f119`、`3c1c535`
- 排期对齐 PRD v2.6（人天与周序零变化）`ea8ea73`

### 移除

- M0-T01 删除 Web 工程目录并清理相关措辞（Q23）`2635571`
