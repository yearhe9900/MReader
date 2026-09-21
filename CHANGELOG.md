# 更新日志（Changelog）

> 格式：Keep a Changelog 简化式。日期用 `YYYY-MM-DD`，**按日期倒序**排列。
> 书写约定：每条一句话、**不复述过程**（分析、根因链、教训留在 PRD 与 `.workbuddy/memory/`），条目末尾附 commit hash 便于追溯。

## 2026-09-21

### 新增

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

- §15.4 依赖清单补录 path_provider（应用数据目录）`9194a89`
- M1-T02A EpubParseException 退休为 @Deprecated 子类，异常统一收敛 `c9827fe`

### 移除

- M0-T02 删除书源原型代码与测试共 21 个文件（Q24）`236cead`

### 修复

- Android 构建：插件模块 compileSdk 统一提升到 36 `11c5198`

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
