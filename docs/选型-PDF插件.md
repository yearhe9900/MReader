# PDF 渲染插件选型对比（Q4 拍板材料）

> **性质**：M2b-T01 备料，**只选型不实施**。产出供负责人拍板（`Q4`：「PDF 插件选型，建议开工前定稿」）。
> **事实截止**：2026-09-24（pub.dev score 页分析于 2026-09-23/24；API 以 pub.dev `latest` 文档与 README 为准）。
> **硬指标**（PRD §7.2 PDF 行 + FMT-01）：① 渲染指定页为位图；② Android + Windows 双平台（P0）。
> **需求锚点**：`FMT-01`（PDF 支持 = 第三方渲染插件 + 按 N 页伪分章 + 连续翻阅 + 双指缩放）、`META-10`（渲染第 0 页为封面，**经平台渲染能力抽象接口注入**，`lib/` 内不直接依赖平台渲染 API）、§7.2 风险注记「插件选型与五平台覆盖；**文字层是否可用于搜索**」。

## 0. 结论先行

| 项 | 结论 |
|---|---|
| **主选（推荐）** | **pdfrx 2.6.5**（espresso3389.jp，MIT，2026-09-18）——6/6 全平台（直接消解 §15.3「iOS/Linux 风险最高」）、自带文本层（`loadText`/`loadStructuredText` 字符 bbox，直接消解 §7.2「文字层是否可用于搜索」风险）、渲染可取消 |
| **备选** | **pdfx 2.11.0**（serge.software，MIT，2026-08-20）——输出 PNG/JPEG bytes 与现有图片页管线**同构**（接线最省），但无文本 API、无 Linux（P2 可按已确认退化「识别+提示」） |
| 拍板点 | ① 主选二选一；② PDF 是否纳入 CNT-06 全书搜索覆盖（影响文本层权重）；③ pdfrx 的 Windows Developer Mode 构建约束是否可接受（发布产物无要求，构建机一次性设置） |

## 1. 硬指标筛选（9 候选 → 2）

| 候选 | ①渲染指定页为位图 | ②Android+Windows | 筛选结果 |
|---|---|---|---|
| **pdfrx 2.6.5** | ✓ `PdfPage.render` | ✓ | **入围** |
| **pdfx 2.11.0** | ✓ `PdfPage.render` | ✓ | **入围** |
| pdf_image_renderer 2.0.0 | ✓ `renderPage`（形态极简） | ✗ 仅 Android/iOS | 出局（硬指标②） |
| pdf2bitmap 0.0.4 | ✓ | ✗ 仅 Android | 出局（硬指标②；0.0.x 新包） |
| flutter_pdfview / flutter_cached_pdfview | ✗ 仅整页 widget | ✗ 仅 Android/iOS | 出局（双指标） |
| native_pdf_renderer 5.0.0+1 | — | — | 出局（已更名 pdfx，4 年未更，pub 页明示 redirect） |
| pdf_render（espresso3389 旧作） | ✓ | ✓ | 出局（维护 Average；作者重心已转 pdfrx） |
| syncfusion_flutter_pdfviewer | ✗ 仅 widget 形态 | 部分 | 出局（商业许可 + widget 不合阅读页架构；自绘伪分章/连续翻阅需 renderer API） |
| pdftron_flutter | ✓ | ✗ 无 Windows（移动 SDK） | 出局（商业授权贵 + 平台） |

## 2. 两强对比总表

| 维度 | pdfrx 2.6.5（主选推荐） | pdfx 2.11.0（备选） |
|---|---|---|
| 发布 | 2026-09-18（5 天前，极活跃） | 2026-08-20（34 天前） |
| 许可证 | **MIT** | **MIT** |
| pub points / likes / 30 天下载 | 160/160 · 346 · 464K | 160/160 · 528 · 407K |
| publisher | espresso3389.jp（verified） | serge.software（verified） |
| 平台 | **6/6**：Android/iOS/Windows/Linux/macOS/Web | **5/6**：无 Linux（score 页明示不支持） |
| 渲染 API | `PdfPage.render(x, y, width, height, fullWidth, fullHeight, backgroundColor, rotationOverride, annotationRenderingMode, flags, cancellationToken)` → `Future<PdfImage?>` | `page.render(width, height, format, backgroundColor, cropRect)` → `PdfPageImage{bytes, width, height, format}` |
| 渲染输出形态 | **原始像素** `PdfImage`（FFI 缓冲，**用后须 dispose**）→ 接线要 `decodeImageFromPixels` / `RawImage` 适配 | **PNG/JPEG bytes**（`PdfPageImageFormat`）→ 直接 `Image.memory`，与现有 `ChapterContent.imagePages` 管线**同构** |
| 文本层 | **✓** `loadText()`（纯文本）、`loadStructuredText()`（**字符级 bounding box**）、`loadLinks()` | **✗ 无任何文本 API** |
| 渲染取消 | ✓ `PdfPageRenderCancellationToken` | ✗ |
| 旋转 | ✓ `rotatedBy/rotatedTo/…`（渲染期 `rotationOverride`） | 依赖文档内生旋转 |
| 密码 PDF | ✓ `passwordProvider` 交互式（空密码首试可关） | README 未见支持说明（**未确认**） |
| 原生后端 | **全平台 PDFium 一致**（`pdfium_flutter 0.3.1` + `pdfrx_engine 0.6.1`，Dart native assets 分发；Android 侧走 JNI） | **各平台异构**：Android 系统 `PdfRenderer` / iOS·macOS `CGPDFPage` / Windows PDFium / Web PDF.js——渲染一致性风险（同一 PDF 各平台观感可能有差异） |
| 构建约束 | **Windows 构建须开 Developer Mode**（构建用符号链接；发布产物无此要求，构建机一次性设置）；release 建议 `dart run pdfrx:remove_wasm_modules` 剔除 WASM 资产瘦身 | `dart run pdfx:install_windows` 一次性 CMake 注入 PDFIUM_VERSION；无特殊权限要求 |
| 运行约束 | `PdfImage` 须 dispose（PERF-02 非驻留纪律同款）；页状态用 `ensureLoaded/events` 流管理 | **Android 单页串行**：开新页前必须 `page.close()`，否则**可能崩溃**（预取须串行化）；`PdfViewPinch` 在 Windows 不支持（zoom re-render）——**自绘阅读页不受影响** |
| 维护风险注记 | score 页无风险注记；依赖面较宽（`jni`/`image`/`material_ui` 等 transitive） | score 页明示 **legacy Kotlin 配置**（`android/build.gradle`），未来评分/兼容可能受影响 |
| viewer 组件 | `PdfViewer` 全家桶（我们不用，自绘阅读页） | `PdfView`/`PdfViewPinch`（同样不用） |

## 3. 对 M2b-T01 / 相关需求的影响

| 需求点 | pdfrx | pdfx | 说明 |
|---|---|---|---|
| FMT-01 伪分章（**按 N 页一个伪章节**，PRD 原文） | ✓ `document.pages.length` | ✓ `pagesCount` | **两强等价**——按 N 页切只须总页数，文本层不参与 |
| FMT-01 连续翻阅 + 双指缩放 | ✓ 自绘（复用 CBZ 图片页模式） | ✓ 同左 | 输出形态差异见 §2（pixels vs bytes），pdfrx 需一层 `PdfImage`→`ui.Image` 适配 |
| FMT-01 ③ 进度可持久化 | ✓ | ✓ | 复用语义坐标 `(chapterHref, chapterPos)`：伪章 href = `p{起始页}` 即可 |
| META-10 封面（渲染第 0 页） | ✓ | ✓ | 两者皆可封装进**注入式渲染接口**（对齐 `RarExtractor` 注入缝模式），满足 META-10 ③「`lib/` 内不直接依赖平台渲染 API」 |
| §7.2 文字层 / CNT-06 全书搜索 | **✓ 直接消解**（`loadStructuredText` 字符 bbox，未来高亮跳转可用） | ✗ 无解（PDF 只能退出搜索覆盖面） | 拍板点 ②：若 PDF 要进 T04 全书搜索，pdfx 基本出局 |
| §15.3 iOS/Linux 风险 | **✓ 免退化**（6/6） | Linux 退化「识别+提示」（M2b-T01 备注已确认可接受）；iOS 覆盖 ✓ | pdfrx 把「五平台覆盖需确认」直接闭环 |
| PERF-02 非驻留纪律 | `PdfImage.dispose()` | `page.close()` 串行 | 两强都要纪律约束；pdfx 的 Android 串行崩溃风险更硬 |
| 包体积 | PDFium native assets 每平台 +5~10MB（**量级估计，实施时实测**）；WASM 资产可剔除 | 各平台原生库同量级 | 都属「随包分发」红线内的正常代价 |

## 4. Q4 拍板问题清单

1. **主选**：pdfrx（推荐：文本层 + 全平台 + 可取消渲染；代价 = Windows 构建开 Developer Mode + `PdfImage` 适配层）还是 pdfx（接线最简 + 无构建特殊要求；代价 = 无文本层、无 Linux、Android 串行 close 雷区）？
2. **PDF 是否纳入 CNT-06 全书搜索覆盖面**？（是 → pdfrx 文本层近乎刚需；否 → 两强差距收窄到接线成本）
3. **Windows Developer Mode 构建约束**（仅 pdfrx）是否可接受？（构建机一次性设置，发布产物与用户无感；CI 需同步配置）
4. **密码 PDF 策略**：加密 PDF 明确拒绝（对齐 `encryptedMobi` 口径）还是走 `passwordProvider` 输密码打开？（pdfx 密码支持未确认，若选 pdfx 建议取「明确拒绝」口径）

## 5. 附录：取证记录（2026-09-24）

| 事实 | 来源 |
|---|---|
| pdfrx 2.6.5 / MIT / 160 分 / 6 平台 / 依赖表（pdfium_flutter 0.3.1、pdfrx_engine 0.6.1、jni…） | `pub.dev/packages/pdfrx/score`（分析于 2026-09-23） |
| pdfrx `PdfPage.render` 完整签名（含 `cancellationToken`/`rotationOverride`/`annotationRenderingMode`）→ `Future<PdfImage?>`；`loadText`/`loadStructuredText`/`loadLinks` | `pub.dev/documentation/pdfrx/latest/pdfrx/PdfPage-class.html` |
| pdfrx Windows Developer Mode 构建约束、`remove_wasm_modules` 瘦身、pdfrx_coregraphics 实验后端 | `pub.dev/documentation/pdfrx/2.3.2/`（安装说明沿用至 2.6.x，实施时以当版 README 复核） |
| pdfx 2.11.0 / MIT / 160 分 / 5 平台（无 Linux）/ legacy Kotlin 注记 | `pub.dev/packages/pdfx/score`（分析于 2026-09-23） |
| pdfx 渲染 API（`PdfDocument.openFile/openData/openAsset` → `getPage` → `render` → `PdfPageImage.bytes`）、Android 单页串行 close 约束、`install_windows` 工具、各平台原生后端 | `pub.dev/packages/pdfx`（README） |
| native_pdf_renderer → pdfx 更名 redirect；pdf_image_renderer 仅 Android/iOS；pdf2bitmap 仅 Android | pub.dev 各包页 / `fluttergems.dev` 生态清单（2026-05/2026-10 快照交叉） |
| 伪分章 = 「按 N 页一个伪章节」；文字层搜索风险注记；META-10 注入式渲染接口约束 | `docs/PRD.md` FMT-01 / §7.2 PDF 行 / META-10 / §15.3 依赖表 |
