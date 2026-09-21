# 更新日志（Changelog）

> 格式：Keep a Changelog 简化式。日期用 `YYYY-MM-DD`，**按日期倒序**排列。
> 书写约定：每条一句话、**不复述过程**（分析、根因链、教训留在 PRD 与 `.workbuddy/memory/`），条目末尾附 commit hash 便于追溯。

## 2026-09-21

### 新增

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

- M1-T02B dispose 竞态：两源释放后/竞态中返回空结果、不抛（RUST-01）`4c1c849`
- Android 构建：插件模块 compileSdk 统一提升到 36 `11c5198`
- M1-T05 dispose 占位 BookMeta：两源释放态作者统一改用兜底「未知作者」，满足 `author` 非空不变式（并补测试断言；附带修正 TXT dispose 用例把 `MetaOrigin` 误比作字符串 `'none'` 的既有断言）`a153313`

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
