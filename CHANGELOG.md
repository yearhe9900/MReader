# 更新日志（Changelog）

> 格式：Keep a Changelog 简化式。日期用 `YYYY-MM-DD`，**按日期倒序**排列。
> 书写约定：每条一句话、**不复述过程**（分析、根因链、教训留在 PRD 与 `.workbuddy/memory/`），条目末尾附 commit hash 便于追溯。

## 2026-09-29

### 修复

- **玻璃壳层正文不避让顶栏（真机截图实证：书架筛选栏被顶进状态栏、网格首行封面被顶栏盖住）**：根因是 `GlassNavScaffold` 未传 `extendBody`、吃了玻璃库默认值 `true` → 库 `glass_scaffold.dart:487-489` 走 `Positioned.fill` 让正文铺满整屏从 y=0 起，只有 `extendBody: false` 才走 `:491-494` 的 `top: topPad + effectiveAppBarHeight`，显式传之；**一处改、7 个页面同时修**（书架 / 详情 / 搜索 / 设置 / 文件夹 / 占位 ×2），已核对 7 处调用点无一手工补过顶部故无双重留白，底部不受影响（本项目底栏不走 `GlassScaffold.bottomBar`，`bottomBar == null` → `bottom: 0`，留白仍由各页 `kShellBottomInset` 承担）。连带：`detail_test` 的 META-08 TXT「单书统计」断言因正文下移 44px 被挤出 600px 测试视口（`ListView` 懒构建）——产品行为正确、失效的是「首屏即可见」的隐含前提，只把该测试视口调到 800×1000、断言一字未改。已知代价（拍板取舍）：`:458` 条件不再成立 → 顶栏下方滚动渐隐一并关闭 `ad37f96`

### 变更

- **书架拖拽对齐 anx：落点即建文件夹、删拖拽重排**（负责人报「拖拽生成文件夹没有实现」→ 调研 anx 源码 → 拍板「对齐 anx」「删重排，完全对齐」）：anx 的建组发生在 `book_folder.dart:34-44` `onAcceptBook`——**松手落在散书上即建**（文件夹 id = 目标书 id、组名播种 = 被拖书名），无任何悬停计时，其 `onReorder` 是空实现、文件夹内页无拖拽，即 anx 不存在重排概念。本项目 `shelf_grid.dart` 删 `kFolderMergeHoverDelay` 900ms 悬停计时与 `_hoverTimer`/`_mergeArmed` 整套状态，`onAcceptWithDetails` 落点即调 `onMergeBooks`，悬停反馈改为立即显示「新建文件夹」提示（原「快速放下=重排、悬停=建文件夹」两态作废）；删 `onReorder` 字段链与 `shelf_page._reorder`（含「先落盘 order 再切 manual」逻辑）；**文件夹内页改 `dragEnabled: false`**（对齐 anx 内页无拖拽），长按操作单改由 `BookCard.onLongPress` 在禁拖时触发；**manual 排序模式与旧 `order` 数据保留**（仅失去拖拽写入口，排序菜单不动）。测试：删「L3 拖拽重排」用例、建文件夹用例改断言「松手即建 + 悬停一帧出现提示」，`tool/test.sh ui` **+103 全绿**（原 104 − 1），analyze 0 error / 7 info `c5cdb6a`
- **书架阅读状态筛选改单选**（负责人拍板「已读完、正在读、未开始，且是单选，参考 anx reader」）：`ShelfPrefs.filters`（`Set` 多选）→ **`filter`（单值，`null` = 不筛选）**——`toggleFilter` 对齐 anx `ReadingStatusFilterNotifier.toggle` 语义（`book_filters.dart:12-18`）：点未选中项选中并顶掉原值、点已选中项取消；`fromJson` 对旧版多选文件取**首个合法值**收敛、落盘键名沿用 `filters`（list 恒 0/1 元素，新旧双向兼容免迁移）。筛选栏 chips 顺序与文案照搬 anx（`bookshelf_page.dart:111-141`）：**已读完 / 正在读 / 未开始**（原为 未读/在读/已读完），`_visibleBooks` 的三路「或」判定改单 switch。测试：新增 `test/ui/shelf_prefs_store_test.dart` 10 条（单选顶掉/取消、旧文件收敛、落盘往返）+ `shelf_page_test` 1 条 widget（chips 顺序文案、选中即过滤、切换顶掉、再点取消），`tool/test.sh ui` **+104 全绿** `b03c114` + docs `d8ef8b9`
- **书架几何抽成事实源 + 契约测试**（「直接复用 anx 代码」的落地形态，两项拍板之一）：新增 `lib/ui/shelf_geometry.dart`——所有几何数值只在此定义一次、每条附 anx 出处行号与差异声明（`shelf_grid.dart` 改为引用并 `export`，调用点 import 零改动；`book_card.dart` 三处字面量改常量）；新增 `test/ui/shelf_geometry_contract_test.dart` 5 个用例（常量 golden + 真实渲染契约：392 宽 3 列 / 119 宽 1 列下限兜底 / 卡片高宽比 2.1 / 封面下方合计 60 / 角标在封面右下），**期望值一律硬编码字面量而非常量引用**（引用即同义反复、永远红不了），测真实渲染尺寸故能同时抓「数值抄错」与「参数接错线」两类错。附带核对：当初抄的 5/55 与 anx 源码一致，但书名↔作者间距 2 与信息区水平内边距 2 **是本项目自有值、anx 该处为 0**，已在事实源照实标注 `a6cc900`

## 2026-09-28

### 新增

- UI 重做批次①**五 tab 导航壳层 + 书架视觉改版**（负责人需求「当前 UI 设计和交互不是我想要的」，参考 `D:\Projects\anx-reader`）：新增 `lib/ui/home_shell.dart`（书架/统计/AI/笔记/设置五 tab；**外层刻意不用 `Scaffold`** 而是 `Stack`——子页各自持有 `GlassNavScaffold`（含自己顶栏），外层再套 `GlassScaffold` 即构成玻璃嵌套、违反 `UI-04`；`IndexedStack` 保活五页；窄屏 `GlassNavBar` 内建浮动胶囊底栏、宽屏 >600px 切 Material `NavigationRail`——**玻璃库 `lib/widgets/surfaces/` 下无侧栏组件**，与 anx-reader 同选择）；`GlassNavBar` 增 `standalone` 参数——脱离 `GlassScaffold` 祖先时库的 `GlassThemeHelpers.resolveQuality` 落到 `fallback: standard`（`glass_theme_helpers.dart:160`），故高档须显式声明 `premium`，中/低档仍由 `fixedSurfaceQualityOverride` 钉 `standard`/`minimal`；同批**导出 `GlassTab` / `GlassTabBarExtraButton`**（页面不必直接 import 玻璃库）；新增 `lib/ui/placeholder_page.dart` 与统计/AI/笔记三个占位页（统计排 M3-T10~T13、AI 排 M4、笔记依赖阅读页标注能力）；`main.dart` 的 `home` 由 `ShelfPage` 改 `HomeShell`。书架视觉照搬 anx-reader：顶栏标题位改**假搜索框**（点击进新增 `lib/ui/library_search_page.dart`，**只过滤元数据**，与阅读页内 `CNT-06` 正文级 `SearchSheet` 分工不同，结果 `Navigator.pop<BookRecord>` 交回书架页、**不复制开书逻辑**）；背景加右上角 `RadialGradient` 光晕；书卡**去卡片底板**（`Card` 改透明 / `elevation: 0` / `clipBehavior: Clip.none` / 零边距，**手势链路不变**）；网格与导入失败清单留出 `kShellBottomInset = 96`——**浮动胶囊不占布局高度，各页可滚动内容必须自留底部空白**；封面加 `Hero` 共享元素过渡 `06063c8`
- UI 重做批次②**书架筛选/排序偏好 + 长按底部操作单**（L2）：新增 `lib/settings/shelf_prefs_store.dart`（`ShelfPrefs` = 筛选维度集合 + 排序字段/方向，经 `JsonStore` → `AtomicFile` 原子落盘，与 `SettingsStore` / `PerfPrefsStore` 同形制；**独立文件而不并入 `Settings`**——改字号不该把书架筛选状态一起重写）；书架加高 40 筛选栏（未读/在读/已读完**可多选** `FilterChip` + 清除入口），判据 `BookRecord.readProgress` 由 `reader_page.dart` 的 `_overallProgress(index, _chapterPos)` 经 `markRead` **真实回写**（非空字段，故三档筛选成立、**无需改序列化**）；筛选后无命中给**专用空态**（与「书架里一本书都没有」区分）；顶栏加排序按钮（导入时间/最近阅读/书名/作者，当前项右侧显示方向箭头，**再点同项即翻转方向**），筛选与排序在渲染期应用（本地量级、重排成本可忽略）；长按书卡**不再直接弹删除确认**，改弹底部操作单（继续阅读 / 书籍详情 / 移出书架），破坏性动作收进操作单并要求二次确认（`LIB-06` 语义不变，缩短「误触即删」路径） `0991c43`
- UI 重做批次③**L3 第一批：书架拖拽重排 + 文件夹**（负责人三项拍板全选推荐档）：新增 `lib/settings/shelf_layout_store.dart`——布局真值独立存 **`shelf_layout.json`**（`ShelfLayout{order, folders}` + `BookFolder`，`JsonStore → AtomicFile` 原子写入，与 `shelf_prefs.json` 同形制），**`BookRecord` 一行不改 → `index.json` 零兼容风险**；孤儿引用走「渲染期按 bookId 过滤 + 载入 `prune()` 落盘清孤儿/清空文件夹（无变化不写盘）」两道**互不假设**的兜底。新增 `lib/ui/shelf_grid.dart` 自实现拖拽（**不引网格重排包**——「拖到书上建文件夹」需项级 `DragTarget` + 悬停语义，`flutter_reorderable_grid_view` 类只管重排不覆盖）：`LongPressDraggable` + `DragTarget` 三态区分（长按不动抬手=操作单 / 快速放下=重排 / 悬停 `kFolderMergeHoverDelay` 900ms=并入或新建文件夹），判「移动过」用 `onDragUpdate` 标志位而非 `DraggableDetails.offset`、每项带 `ValueKey` 防 `GridView.builder` element 复用错位、`BookCard.onLongPress` 改可空并在网格内传 `null`（否则与拖拽容器在手势竞技场互抢）；重排下标沿用 `ReorderableListView` 约定（`insertAt = from < to ? to-1 : to`）。`ShelfSortField.manual` 加在**枚举末尾**并**忽略升降序**（否则会把用户拖出的顺序整体翻转），`_reorder` **先落盘 order 再切 manual**（反了会用旧 order 重排一次、位置跳变）。新增 `lib/ui/shelf_folder_page.dart` 文件夹内页（**不支持嵌套**，解散/删空自动 `maybePop`），`FolderActionSheet`/`askFolderName`/`confirmDissolveFolder` 提为公开与书架页**共用一份**；文件夹参与筛选（成员 ∩ 可见书非空才显示）。测试：`shelf_layout_store_test` 21 条（含「无变化不写盘」逐字比对）+ 书架 6 条 L3 用例 `3869f52`

- 开书 / 滚动链路耗时日志（真机诊断「打开大书（如绍宋）到深章节非常慢」，先取数后定优化）：`lib/diagnostics/perf_log.dart`（零依赖纯 Dart 打点出口 `step`/`mark`/`watch`，`print` 落 logcat `I/flutter` + 环形内存留档，`--dart-define=MREADER_PERF_LOG=false` 静音，首行 `session product=` 标构建档位——debug 档比 release AOT 慢数倍，读数先看它）；埋点覆盖 `open.*`（书架读字节/嗅探）→ `reader.*`（load/chapters/stores/firstBatch/ready/content/seed 分支）→ `restore.*`（begin/逐帧 step/收敛 end）→ `autofill.*`/`layout.*`（补齐批次与重锚）→ `nav.*`/`scroll.detect`，解析源内部分账 `txt.prepare`（decode/analyze 分列）、`txt.analyze`（规则名+章数）、`epub.parse`/`epub.bind`/`epub.flatTitles`；桌面探针实测真实 7.7MB TXT（762 章）`txt.prepare` 265ms（decode 247ms）而 `content(457)` 0ms——数据面开书成本 ≈ 全书解码+分章一次性成本、与停在哪章无关，深章节慢若有只可能出在恢复校正/占位补齐 UI 链路或 debug 档位 `2cc2fda`

- M2b-T09 交付验收备料（§17 M2 第 1/3/4/5 条 + FMT-01/02 样本）：`tool/gen_real_samples.py`（**纯 stdlib、不联网**）生成「代表性真实结构样本」到 `tmp_book/`（不入库）——真结构 PDF（FlateDecode 内嵌位图 + Helvetica 文字层）/ CBZ（自然序、混大小写扩展名、`ComicInfo.xml` 与 `__MACOSX` 过滤、大图页）/ EPUB3+nav、EPUB2+ncx、无 nav / TXT（UTF-8 卷章、GBK、超长单章）；`test/format/real_samples_smoke_test.dart` 端到端冒烟（`openBook→load→chapters→content(0)→readResource` + 真书正文派生查询词搜索；无 `tmp_book/` 整组 skip；PDF 真渲染默认关、`MREADER_REAL_PDF=1` 开启），实测四类各 ≥3 样本全通过（EPUB 4 / TXT 4 / PDF 3 / CBZ 3，`All tests passed!`）；新增 Windows 构建文档 `docs/build-windows.md`（Developer Mode 闭环 `Q4 ③`）与验收报告 `docs/acceptance-M2b.md`（§17 判定对照 + 五平台冒烟备料） `63afc3b`
- M35-T01 加速层脚手架与回落骨架（`RUST-01`，架构 §A 能力抽象 / §F 统一后台任务，**纯 Dart 零 Rust**）：`lib/highperf/*`（`HighPerfCapability` 五能力枚举 + ABI 版本常量 `kRustAbiVersion`；`HighPerfRegistry` 三态探测 `bool?`、幂等 `warmUp`、`probeTimeout=3s`、探测失败 5 情形（含 ABI 版本哨兵与「首次调用失败不翻转状态、连续 2 次才惰性降级」）、强制纯 Dart 三级开关、`Provider` 注入缝；`NullHighPerfEngine`；`HighPerfException` 分调用期 6 值 / 探测期 4 值且**永不接 UI**）+ `lib/task/*`（`BackgroundRunner`/`BackgroundTask`/`TaskContext`/`TaskHandle`/`TaskRunnerRegistry` + `IsolateBackgroundRunner` 与 `SyncBackgroundRunner` 两后端，后端可换是 T04 的挂载点）；`BookRegistry.capabilityFor` 格式 ↔ 能力**唯一映射点**，`main.dart` 组合根接线 + `kDebugMode` 下 `describe()` 打印；测试 48 条（registry 21 + task 27，含真派发 `debugName` 取证、进度节流与终值、kill 取消 <1s、远端失败转述、派发失败回落本 isolate）`187b5ad`
- M35-T02 门槛基线测量基建（`RUST-06` 先测后引，「阈值先是数字、再是代码」）：`test/perf/threshold_judge.dart`（PRD §15.6.3 阈值表**唯一机读来源**逐字照抄 + §H.4 三段式判定**唯一实现**含 10% 死区 + `BaselineRecord` 留档 schema）、`threshold_judge_test.dart` 19 条（780/830/900 与边界 799/800/880/881、阈值表与 PRD 一致性、schema）、`baseline_harness.dart` 33 条（§H.1 协议：纯解析入口计时、不含 IO、含解压、N=7 中位数、预热不计入；样本 = 生成大文件样本 + `tmp_book/` 真实脏书；脏书容错；`MREADER_PERF_OUT` 落盘信封 JSON；整组默认 skip、单条自带 5 分钟超时）`0caf0d8`
- 六项候选门槛结论留档（`docs/perf-baseline/thresholds.md` + `2026-09-28-windows-dev-sentinel.json` 33 条机读记录）：阈值 2 真实脏书（15.5MB **有目录** EPUB）合计 **1370ms → 1.71× over，且下界 1322ms 自身越死区 = over 与口径无关**；50MB 口径样本 **15144ms**；阈值 4 **7621ms → 5.08× over（仅无 toc 大书，根因 flatTitles 已挂账）**；阈值 3 **821ms → 1.03× borderline**；候选 1/5 与「单帧 > 16ms」如实 `notMeasured`（`0caf0d8`）

### 变更

- UI 重做批次③**书架布局几何复刻 anx reader**（两项拍板：范围 = **只动布局几何**，字号/颜色/阴影保持本项目现状；格式标签 = **挪到封面上做角标**）：`shelf_grid` 列数算法由「`SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180)`」改为 anx 口径「**容器宽 ~/ 单列目标宽 120**」（`bookshelf_page.dart:453-454`；360dp 手机由 2 列变 3 列，列数随宽度连续自适应），`build` 外包 `LayoutBuilder` 取含 padding 的整宽；比例 `0.5` → **`1/2.1`**、行距/列距 `8/8` → **`30/20`**、padding `(12,12,12,·)` → **`(20,12,20,·)`**（左右 20 / 上 12 照搬 anx，底部 80 换回本项目 `kShellBottomInset`——目的相同但本项目胶囊更高）；新增公开常量 `kShelfCoverTargetWidth` / `kShelfGridPadding`，`shelf_folder_page` 的显式 padding 改用后者（**两页同源防漂移**）并删掉多余 import。书卡：信息区改**固定 55px**（anx `book_item.dart:89-90`，一/两行书名的卡片等高、行距不跳），只留书名两行 + 作者·进度；封面↔文字间距 `6 → 5`；格式标签（PRD `US-06` / `LIB-01` 要求，anx 原版无此物）从信息区**挪到封面右下角作角标**（`ClipRRect` 内 `Positioned(6,6)`，随圆角裁切不溢出），空态「导入书籍」按钮（`LIB-01` ②）同样保留不复刻 anx 的纯颜文字空态 `35254ae`
- **UI 重做批次①②的视觉红线与保真度边界留证**：① 书架的 `RadialGradient` 光晕**不用** anx-reader 的半透明叠底（`primary.withAlpha(5)`），改为 `Color.alphaBlend(半透明色, 底色)` **预先合成为完全不透明**——观感等价而 `UI-04`「内容层不透明」红线不破；② 长按操作单由 `GlassOverlays.showSheet` 承载（`UI-03` 浮层玻璃，「关」档退化为 Material 弹窗），内部**首层包 `Material(type: MaterialType.transparency)`**——玻璃浮层**没有 Material 祖先**（PRD §11.4），`ListTile` 会直接抛 `No Material widget found`（本批实测踩中）；③ 本轮只做 L1（视觉）+ L2（搜索/筛选/排序/长按操作单），**L3（拖拽排序 / 文件夹 / 桌面拖入）未动工**（见任务清单）
- `docs/tech-usage.md` 增 §2.38「UI 重做：五 tab 壳层与书架保真度」（记玻璃库不含侧栏组件、`standalone` 与 `resolveQuality` 的 fallback 关系、`kShellBottomInset` 由来、`alphaBlend` 保红线手法、玻璃浮层无 Material 祖先的坑，以及**本轮已复核与未复核项的边界**）
- `docs/tech-usage.md` 增 §2.39「UI 重做批次③ · L3 第一批：拖拽重排 + 文件夹」（记三项拍板、独立 `shelf_layout.json` 的三条理由、拖拽三态判据表、**「先落盘 order 再切 manual」与「manual 忽略升降序」两个顺序坑**、SnackBar 根因表 + FakeAsync pending Timer 悬案了结、**「`layout.order` 存 bookId 不是书名」的断言错取证**、复核边界与未做项），并给 §2.38 的「L3 一行未写、须先拍板」补**后续闭环指针**（该段「会改动 `BookRecord`」的担忧由独立文件方案化解）
- `docs/tech-usage.md` 增 §2.35「开书 / 滚动链路耗时日志（`[perf]`）」与 §2.36「恢复落点根因与章高模型修复」：前者记埋点分布、logcat 读法、`session product=` 档位口径与桌面参照数字，后者记真机日志逐段读数表 + 根因链 + A/B 修法 + 测试前提变更
- `docs/tech-usage.md` 增 §2.31「真样本目录与端到端冒烟」（含 TXT 分章阈值坑：章体须 >1000 字，否则被当「疑似卷」否决整条规则）
- 进度表刷新：M2b T04~T09 状态对齐（T09 备料完成，全量回归 + 五平台冒烟待负责人下令回填）；总览总体累计约 40%
- `docs/perf-baseline/README.md` 增目录索引（该目录已被 M1-T07 / M2b-T04 / M2b-T05 / M3.5-T02 四批共用，**先看口径再读数字**）+ §8「门槛基线用法与留档模板 + 判定纪律六条」；`docs/tech-usage.md` 增 §2.32 / §2.33（T01 与 T02 的技术使用记录，含两批的坑与如实登记的未做项）
- 进度表刷新（M3.5）：M35-T01 ✅ 100%、M35-T02 🔄 80%（基建与桌面哨兵留档已出，**正式判定待负责人 Android 主力机复跑回填**）、M3.5 小计 🔄 53%（A 线 6.4/12）
- **口径更正（`docs/perf-baseline/thresholds.md` §3）**：此前「2a 含无目录书 `flatTitles` 预取属**中性重叠**、合计不受影响」的说法**是错的**——该预取是**逐章解压 + XHTML 解析（2b 性质）**，跑在 `load()` 里 → 「2a+2b」对无目录书是**重复计数、高估**。实测坐实：有目录真书 2a = 48ms、无目录 `big_bodies` 2a = 7608ms（同一解析器差 158 倍）。处置：判定同时给**无条件下界 = 2b 分层值**（2b 只计 `content(i)` 循环 ⇒ 等于真 2b；真 2a ≥ 0 ⇒ 真合计 ≥ 真 2b），并据此区分「over 与口径无关」与「over 依赖上界口径、须补有目录大样本复核」
- 仓库行尾策略拍板并落地 `.gitattributes`（负责人 2026-09-28 定 **CRLF**，闭环待决策 #1）`a0c7c71`：默认 `* text=auto eol=crlf`——**索引始终存 LF、工作区检出 CRLF**（Git 标准归一化行为，不是规则没生效；权威自查口径 `git ls-files --eol`，期望文本为 `i/lf w/crlf`）；30 png / 15 epub / 1 ico 显式 `binary`（三类合计**正好等于** 46 个 `i/-text`）外加前瞻性二进制声明（pdf/mobi/azw3/cbz/cbr/jar/so/dll/字体…，为 M3.5 Rust 产物与后续夹具预留）；**shebang 脚本强制 LF**（`*.sh` / `*.bash` / `*.py`）——CRLF 会把首行变成 `#!/usr/bin/env bash\r` 导致解析失败（`tool/test.sh` 在 Git Bash 下必然 bad interpreter）；**文档保持 LF**（`*.md` / `*.mermaid` / `docs/**`，对齐既有「文档 UTF-8 无 BOM / LF / 结尾换行」工程约定，含 `docs/perf-baseline/` 留档 JSON）。**本批不翻新现存工作区**（负责人拍板）：197 个文本文件工作区仍为 LF，`git add` 的 "LF will be replaced by CRLF" 警告照旧，规则自下次 clone / checkout 起按 CRLF 落盘
- 行尾规则生效面核查（提交后实测，`git ls-files --eol`）：178 个文本归 `attr/text=auto`（→ CRLF）、46 个归 `attr/-text`（二进制不转换）、**22 个归 `attr/text eol=lf`**（18 个文档/留档 JSON + 4 个脚本）。其中 **2 个 LF 钉定文件当前工作区竟是 CRLF，属既存隐患**——`test/fixtures/make_fixtures.py`（**shebang 脚本处于 CRLF**，直接执行会 bad interpreter）与 `ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md`，二者将在下次检出被规则自动纠正；另确认**索引无需 renormalize**（`core.autocrlf=true` 已归成 LF，故 `git add --renormalize .` 是纯 no-op、不产生提交）
- **文档-现实脱节回填：Flutter `3.44.9` → `3.47.5` / Dart `3.12.2` → `3.13.4` 全量对齐**（触发：核查渲染后端事实时由负责人指出「现版本已经是 Impeller」，顺查本机 SDK 才发现文档与实机差了三个小版本）：5 份文档共 **22 行**（版本字面量 **34 处**：PRD 12 / architecture-rust-integration 8 / tech-usage 7 / schedule 3 / README 4——**程序化点数**，口径见 `tech-usage.md` §2.37），**本次全量回填**；并**补记 2026-09-24 的升级本身**（此前 `CHANGELOG` 零记录，违反「任务书必含同步 CHANGELOG」约定）。连带修正三处**事实性错误**——① PRD §15.4 与 `README` 故障速查的「`archive` **必须锁 3.x**（4.x 的 `ArchiveFile` API 不兼容）」**已作废**：实为 `archive: 4.3.0`（2026-09-24 由 3.x 迁移 `64ae658`，是 `pdfrx_engine` 硬要求 `^4.x` 逼出来的）；② `schedule.md` §0.6 低置信度表的「`FMT-01` PDF（**插件未选型**）」过时（已选型 `pdfrx 2.6.5`，`Q4` 已闭环）→ 改为「**集成成本未实测**」；③ `tech-usage.md` §2.8 的「**37 个** `Glass*` 类型」**不可复现**（判定表在 `08c2b65` / `9519c5f` / `5b96ca6` 三个提交上**始终为 35**；库 `lib/widgets` 下 `class Glass*` 实为 **90**，1.6.2 与 1.7.0 完全相同）→ 勘误为 **35** 并留证，判定为原文计数错误、与版本升级无关。**「本机 Windows 走 Skia 轻量路径」的前提已失效**（该说法源于 3.44.9 不满足「Windows 获 Impeller ANGLE 需 Flutter ≥3.47」；升级后门槛已满足），但**库自身仍把 Windows / Linux 静态封顶 `standard`** → `NF-C8` / §15.3 降级表 / `build-windows.md` §3.2 / `schedule.md` N-5 与 R8 统一改写为**两层原因分开表述**（观感差异**仍在**，只是原因从「没有 Impeller ANGLE」变为「库的既定平台策略」）。`docs/tech-usage.md` 增 §2.37 记本批（含三处脱节分列、连带发现表、**复核边界**：能读源码复核的已逐条复核、依赖运行观感的**不伪造复核记录**） `3c559b8`
- **PRD §16 `Q3` 按「推翻定案」流程完整改写**（原标 🟡「本期不升级，接受 Windows 玻璃走 Skia 轻量路径」已不成立）：真实改判路径 = **被 `Q4` PDF 选型链侧向推翻**，**不是**按 `Q3` 自己立项走的——`pdfrx 2.6.5` 需 Flutter ≥3.47 / Dart ≥3.13，其 `pdfrx_engine`（0.1.0 起全线）**硬要求 `archive ^4.x`**，本机 3.44.9 / 3.12.2 不满足，故 2026-09-24 由负责人拍板升级。改写含四段：① 原定案 v2.6；② 推翻它的决定性论据（来自另一条决策链）；③ **未被推翻的部分**（`Q3` 原文技术前提「Windows 获 Impeller ANGLE 需 ≥3.47」**经核实仍然正确**、`NF-C8`「不得宣称五平台功能等价」及其「按平台分别判定」验收口径**一字不变**）；④ 代价已发生（原估 +3~+6 周，实际作为独立批次完成）。状态 🟡 → ✅ 已闭环
- `schedule.md` §5 风险表 **`R9` 整条关闭**（原 🟢「依赖版本锁定与 Flutter 升级的两难」，处置「本期不升级」）：升级**已实际发生**且**额外成本 ≈ 0**（作为 2026-09-24 独立批次一次做完，**原估的全工程兼容性回归未发生**）→ 概率列改「已关闭」、触发信号列作废；**但「依赖版本锁定」半条仍有效并保留**（`liquid_glass_widgets` 仍精确锁 `1.7.0` 不带 `^`、FRB `2.13.0` 仍须 codegen ≡ runtime）
- `schedule.md` §4.2 `M1-T08` 与 §4.3 `N-5` 同步回填：玻璃库锁定 `1.6.2` → **`1.7.0`**（2026-09-21 升级 `c996106`）、观感约束从「Skia 轻量路径」改为「**被库静态封顶 `standard`**（PRD §11.4，1.7.0 已复核）」

### 修复

- **轻提示（SnackBar）在手机布局上必崩：改走 Overlay 浮层 `GlassOverlays.showToast`**（既有潜伏 bug，由 L3 拖拽的 `_toast` 首次触发而暴露）：玻璃壳层 `GlassScaffold` 内层是 `CupertinoPageScaffold`（库 `glass_scaffold.dart:646`）、窄屏浮动底栏布局又是纯 `Stack`（`home_shell.dart:165`）→ **两条主路径都没有 Material `Scaffold`**，`ScaffoldMessenger.showSnackBar` 的 `_scaffolds.isNotEmpty` 断言必失败（debug 崩、release `_scaffolds.last` 抛 `StateError`）；**只有宽屏侧轨布局**（`home_shell.dart:187`）碰巧有 `Scaffold`，且 widget 测试里 `FilePicker` 不可用使 `_pickAndImport` 从未被覆盖——这正是它一直没被发现的原因。修法：新增 `GlassOverlays.showToast`（玻璃档走库 `GlassToast.show` = `OverlayEntry` + 自管定时移除；「关」档 `UI-06 ②` 退化为自写纯色 `_PlainToast`，`dispose` 取消计时器），re-export `GlassToastType`；**全仓 6 处 SnackBar**（书架 `_toast` / `_pickAndImport` + 详情页 3 处）全部换掉。附带了结 FakeAsync 悬案：读 `flutter_test` `binding.dart:1960-1974` 确认测试结束**先卸载整树再查 pending Timer**，故 `OverlayEntry + Timer` 不会报 `A Timer is still pending`（实测 ui 组 85 条无该报错）`d98b80b`
- **「打开大书到深章节非常慢」的根因修复：恢复落点改用章高模型**（真机 perf 日志实证：绍宋 447 章 EPUB 恢复第 417 章时 8 帧全 `kind=estimate`、`converged=false`、遮罩 1248ms 且最终没落到目标章）：根因是目标章未进布局窗口时 `_restoreStep` 退化为 `maxScrollExtent × (index+pos)/total` 比例外推，而懒构建下 `maxScrollExtent` 是「已构建子项均值 × 剩余项数」的**外推估计**，在本工程「少数真实章（数千 px）+ 大量等高占位块（480 px）」的混合布局里于 **214009 / 602772 / 1133858 / 706186** 之间振荡 → 估算落点来回乱跳、8 帧耗尽仍拿不到目标章；`converged=false` 又让 `RC1` 闸门关闭（**进度也不写盘**）。修法两块：**A 章高模型**（`_chapterHeights`：未加载章的高度**就是**占位高、已构建真实章写回实测高；seek 改为累加算目标章首 → 单向逼近，误差上界 = 未知高度章数，首帧批次下 ≤1 章；落到章内即转实测精确校正），**B 补齐时序**（`_open`/`_goToChapter`/`_jumpToLink` 不再抢跑后台补齐，统一由 `_finishRestore` 触发「先落定、后补齐」——消除真机日志里的 9 次 `layout.reanchor anchored=false` 空重锚与恢复期总高突变）。测试：回归② 改写为「深章节恢复必须收敛并写回语义坐标」，新增回归②b「恢复校正未落定即关书 → 一次都不写盘」保住 `RC1` 闸门覆盖 `032489a`
- 基线 harness 三处会产出**假结论**的错误（`0caf0d8`）：①零命中（`firstHitElapsed` 为 null 记 -1）会被三段式判成 `under`「不上 Rust」→ 改为任一样本 < 0 即整条 `notMeasured`；②真实脏书搜索词派生不可靠——首章常是图片页、`extractSection` 对图片产出 `IMG:…` 占位符（首跑把 `IMG:OE` 当成查询词），且 `content(i)` 在 `chapter.locate` 非空时走**片段**抽取而 `search()` 走**整节**抽取 → 改为「只取纯汉字连续段 + 只取 `locate` 为空的章」；③生成样本沿用大书的固定词对 `long_chapter.epub`（正文是「第N段…」）零命中 → 显式词表，表里没有不猜
- `BaselineRecord.coldReadMs` 由「只写在 `notes` 人话里」改为**正式字段**（§H.1 要求额外记录冷读；只写文本则 harness 打印永远是 `null`，机读取不到）`0caf0d8`
- **★GATE★ 判据版本错（4 处，本轮回填中优先级最高）**：`M35-T03`（`schedule.md` §4.2）/ PRD `Q20` / `R2`（`schedule.md` §5）/ 架构 `§L4` 均把 Cargokit 的**验证对象**写成 **Flutter 3.44.9**（升级前的版本），而实机跑的是 **3.47.5**——`M35-T03` 的 gate 语义是「**验证不通过 → 整条 Rust 线回退纯 Dart**」，故该判据此前**建立在错误前提上**。四处全部更正为 **3.47.5**，并注明：Cargokit 已知修复边界为 **Flutter ≥ 3.32**（`irondash/cargokit` PR #118），**3.47.5 比 3.44.9 离边界更远 → 风险性质不变、级别维持 🟡，验证必要性只增不减**（已写入 `R2` 应对栏第 ④ 条）。架构 §G.2.2 标题改为「Cargokit 与 Flutter 3.47.5」并加版本更正块：**官方引用原文一字未改**（append-only 留证），仅更正「本项目适用版本」 `3c559b8`
- `docs/tech-usage.md` §1.1 / §2.0 的 SDK 约束由 `^3.12.2` 更正为 **`^3.13.0`**，并解除「3.44.9 已锁定不升级」的表述；同文件 §2.8 三条依赖 1.6.2 **源码**的断言已在 **1.7.0** 上逐条复核（`glass_scaffold.dart:559 / :584` 的 `defaultQuality: premium`、判定表 35 类型零缺失、`_shouldSkipPremiumPreload()` 对 `windows` 返回 `true` 的 `:148-153`），**行号与判定式逐字一致**
- **`archive` 3.x 残留表述二次清网（4 处，首轮 grep 漏掉）**：这些表述**不含版本号字符串**（写的是「锁 3.x」「固定在 3.x」），故首轮按 `3.44.9`/`3.12.2` 检索时全部漏网 → `README` 依赖表（`^3.6.1`「固定在 3.x」）、`docs/tech-usage.md` §1 技术栈总览（`archive` 3.6.1「锁 3.x」）与 §2.0 初始化表（「`archive` 锁 3.x（4.x 改 API）」）、`docs/architecture-rust-integration.md` §现有依赖声明（「`archive ^3.6.1` 锁 3.x 等」）**全部更正为 `4.3.0`**，并各自注明「随 `pdfrx_engine` 硬要求 `^4.x` 作废」。**留证不改**：`tech-usage.md` §2.6（M1-T02A）与 §2.12（M1-T07 `PERF-02`）里「archive 3.x 的 `ArchiveFile.content` 会把解压结果永久缓存在 `_content`」这类**当时发现的坑**、以及 PRD 的 v2.8 版本历史条目——它们是历史事实快照

## 2026-09-24

### 新增

- M2b-T04 全书搜索（`CNT-06`）：`SearchSession` 双执行路径（可序列化 `searchSpec` 进后台 isolate 重建源流式回传 / PDF 句柄源本 isolate 逐页）+ 协议级取消（取消即 `Isolate.exit()` 不留后台线程）+ 派发失败回落（RUST-01 信封口径，业务错误不回落）；`PdfSource.search` 文本层逐页全计数（`searchable=true`）；`SearchSheet` 面板（进度/实时计数/取消/「章节名+片段」命中列表）+ 阅读页跳转高亮（offset→段落下标换算 → `_jumpToLink` 段落对齐 + `InlineParagraph.highlightQuery`）；阈值 4 基线 `tool/search_bench.dart` 实测：TXT 20.7MB 首屏 0.45s 达标、无 toc 大正文 EPUB 48M 字符 4.2s 超标（根因 flatTitles 全书预解压，优化留挂账）留档 `docs/perf-baseline/search.md`；测试 search 26 条（sheet 8 + jump 2 + session 9 + pdf 8，widget 测试禁 isolate 路径），reader 分组 206 全绿 `09771c2` `e83051f` `2b6f05e`
- M2b-T05 MOBI/AZW3 原型基线（Q25 + PRD §15.6.3 阈值 1）：`tool/mobi_probe.dart` 纯 Dart 直译 567Reader 自研链（PDB/EXTH/Huff·CDIC/LZ77），tmp_book 真实双样本实测——KF8 结构=**同文件尾部 FDST/SKEL/FRAG（INDX）**、入口=**version≥8 直入 / EXTH 121 boundary 跳转**双分支、EXTH 129/131 偏移入口说 NOT SUPPORTED（129 是 `kindle:embed:` 封面 URI）；耗时下界 open(w/ read) 12.7ms、full(w/ read) 23.7~176.5ms，距阈值 1~2 个数量级（Huff/CDIC 无 compression=17480 样本未覆盖，如实记录）；留档 `docs/perf-baseline/mobi.md` `9661ba9`
- M2b-T07 玻璃质量档位与性能降级（`UI-05`/`UI-06`）：`PerfPrefsStore` 档位四态 +「降低视觉特效」持久化（`JsonStore`+`AtomicFile`）；生效链「用户档位 → 强制 minimal → 低端钳制 → 帧预算降档」收口 `GlassRuntime`（`glassTierConfigFor` 唯一映射，`scrollQuality` 拒 `premium`）；`glass_kit`/`glass_scope` 全量接线——高档不覆盖（库自动提升）、中/低档 `GlassIsolationScope` 钉 `standard`/`minimal`、关档退化 Material 纯色（`UI-06` ② 功能完整）；`PerfFrameMonitor` 光栅 >16ms 连续 60 帧触发会话内降档（不持久化）；设置页四档分段 + 降特效开关；测试 29 条（映射/折算/钉档/退化/帧口径），ui 57 + data 157 全绿；含修「到底档不留降档残留」（`noteBudgetDegraded` 到底即短路，防 `_budgetTier` 残留钳死用户切档） `5b96ca6`
- M2b-T06 书签/字体/亮度/全屏（`TYP-06/07/08/09`）：`BookmarkStore` 每本一文件（防路径穿越）+ `BookmarkSheet` 增删实时更新且即时落盘；字体族/字号/行距 + 亮度遮罩/背景色/夜间映射（`TYP-07/08`）+ `ReadingPrefs` 持久化；沉浸全屏 + 常驻进度「第 N/M 章 · P%」随滚动实时（`TYP-09`，显示值 `_liveIndex`/`_livePos` 与存档语义值分离、`RC1` 闸门不动）；`reader_harness` 共享装具，reader 179 全绿 `37090e5`
- M2b-T08 阅读会话采集内核（`STAT-01/02`，无 UI）：`SessionTracker` 空闲 3min（Q12）切会话（前段计「最后活跃 + 3min 宽限」）、跨 0 点按实际秒数拆天（起止坐标取边界前最后活跃）；`SessionStore` 按月分片 `stats/sessions-YYYY-MM.json`（`JsonStore`+`AtomicFile` 原子写入、坏分片隔离 `.corrupt`）、按 id 并集幂等合并（同 id 取较大时长、`duration≤0` 禁写）；`StatsIndex` `day_key`/`book_id` 双索引单遍扫描聚合，`tool/stats_bench.dart` 实测 4 万条 loadIndex 129ms ≤300ms（PASS）；`app_paths` 接口/实现拆分（stats 零平台插件） `377d171`
- M2b-T01 备料：PDF 渲染插件选型对比（Q4 拍板材料，**不实施**）→ `docs/选型-PDF插件.md`——9 候选按双硬指标（渲染指定页为位图 + Android/Windows）筛至 pdfrx 2.6.5（主选推荐：6/6 全平台、文本层、可取消渲染）与 pdfx 2.11.0（备选：bytes 与图片页管线同构；无文本层、无 Linux）；含 FMT-01 伪分章 / META-10 注入式渲染接口 / §7.2 文字层搜索风险影响分析与 4 项拍板点 `8f4c3b4`
- M2b-T03 格式嗅探与魔数纠偏（`FMT-06`）：MOBI/AZW3 以 PalmDB `BOOKMOBI` 魔数（偏移 60..68）识别、压过一切后缀（验收①：AZW3 改名 `.txt` 仍识别为 MOBI 系，tmp_book 真实双样本取证）；`FormatKind.mobi` + `mobiUnsupported` 导入即拒绝（口径区分「MOBI 还没支持」与「不认识的格式」，`M2b-T05` 接入解析器）；纯文本改名 `.epub` 取「明确报错」出口（交 EPUB 解析器 notZip 文案，既有锁不动）；中立判据层 `sniffer.dart` `12879fb`
- M2b-T02 CBZ 支持（`FMT-02`）：`CbzSource`（`dart-cbz`）每图片页一章（`href` = zip 条目路径、title = 第 N 页），进度按页天然成立（③）；页表自然序 `compareNatural`（`META-11` ②）+ `__MACOSX` / 隐藏文件 / 非图片条目过滤；封面 = 自然序首页图（`PendingCover` + 魔数嗅探，`META-11` ① / `META-05`）；书名 / 作者走 META-04 文件名规则链（与 TXT 同源） `a7ff34d`
- M2b-T02 阅读页图片页模式（`FMT-02` ①②，2026-09-24 拍板「点页全屏缩放」）：`ChapterContent.imagePages`（与段落互斥）→ 整页竖向滚动、原始字节解码不降采样（「不糊」）；点页进全屏 `InteractiveViewer` 缩放查看器（maxScale 5）；「单 / 双页」描述面（US-12）未覆盖，如实记录 `a7ff34d`
- M2b-T02 CBR 退化（`FMT-03`，Q5 拍板「导入即拒绝」= 与加密文件处理一致）：`CbrSource`（`dart-cbr`）+ `RarExtractor` 注入缝（默认 `UnavailableRarExtractor` → `load()` 抛 `cbrUnsupported`「转换为 CBZ」、书不入库）；注入可用实现即自动升级为 CBZ 同行为（假实现测试锁定），`META-11` ③ 记「退化模式无封面链路、错误单点」 `a7ff34d`
- M2b-T02 接线与文案：`sniffFormat` 扩展名优先判 `.cbz` / `.cbr`、`ImportService` format 映射、`error_messages`（RD-05 唯一来源）增 `cbrUnsupported` / `noImagePages`，`unsupportedFormat` 文案改「当前支持 EPUB、TXT 与 CBZ」；契约测试注册 `dart-cbz`；parse 155 / data 99 / reader 150 全绿 `a7ff34d`

### 新增

- M2b-T01 PDF 支持（`FMT-01` / `META-10`）：渲染能力经 **`PdfEngine` 注入缝**接入（`lib/` 内零 import pdfrx，全仓唯一适配器 `lib/platform/pdfrx_pdf_engine.dart`；组合根一行 `PdfEngineProvider.current = PdfrxPdfEngine()`）；`PdfSource` 伪分章 **N=10**（`href` = `p{起始页}`、标题 `第 X–Y 页`）、正文 = 按页资源键的图片页序列（连续翻阅 + 点页缩放**复用 CBZ 管线，阅读页零改动**）、进度复用语义坐标 `(chapterHref, chapterPos)`；封面渲染第 0 页（512px）→ `PendingCover(PNG)`，失败回退 `NoCover` 交 `META-07` 合成；手写 BGRA→PNG 编码器（`dart:io` zlib + 自实现 CRC32，零新依赖）；嗅探加 `%PDF` 魔数（**压过后缀**）+ `FormatKind.pdf` + `.pdf` 后缀臂；`encryptedPdf` 文案入 `RD-05` 唯一来源表、`unsupportedFormat` 文案补 PDF `d6e6d86`
- M2b-T01 测试面（parse 212 / data 152）：`test/format/pdf_source_test.dart` 20 条（伪分章 / 页键 / 封面 / 错误码 / dispose 契约 / 能力如实）+ `bgra_png_test.dart` 5 条（**测试侧独立 PNG 解析器**（按位 CRC）先自检既有参考图 `kTinyPng` 再验编码器）+ `pdf_fakes.dart` 假引擎 + 契约清单增 `pdfrx-pdf` 样本 + 导入管道 PDF 用例 `d6e6d86`

### 变更

- archive 3.x→4.3.0 迁移（M2b-T01 前置，负责人拍板「迁 archive 4.x」保 pdfrx 2.6.5）：`zip_paths` 两辅助函数适配（`lazyEntryLoader` 收敛单出口 `decompress(output)`，PERF-02 非驻留解压语义等价保持）+ `tryDecodeZip` EOCD 判废守卫（4.x 无 EOCD 静默解空回归，坏 zip / 非 zip 错误码 RD-05 同型同码），`epub_parser`/`cbz_source` 调用点零改动，parse 167 + data 151 全绿 `64ae658`
- Q4 PDF 插件选型拍板（负责人，2026-09-24，原文「1、pdfrx 2.6.5；2、是；3、是；4、拒绝」）：主选 **pdfrx 2.6.5**（经 META-10 ③ 注入式接口接入）；PDF **纳入** CNT-06 全书搜索覆盖面（pdfrx 文本层）；Windows Developer Mode 构建约束**接受**（构建机一次性）；密码 PDF **明确拒绝**（对齐加密文件口径，不走 `passwordProvider`）。落地验收条目见 `docs/选型-PDF插件.md` §4 `f353364`
- M2a-T06 PERF-01 接线：EPUB 解析移出主 isolate——后台 `parseEpubStructureTask`（纯数据 + 信封）跑 `parseEpubStructure`，主 isolate `bindEpubResult` 绑定 `loadBytes`/`readEntry` 闭包；TXT 准备/解码（`_txtPrepareTask`/`_txtDecodeTask`）同款后台化 `5aa0679`
- IsolateRunner 升级：`compute()` 改 `dart:isolate` 的 `Isolate.run`（纯层零 Flutter 铁律不破）+ `runWithFallback` 失败护栏（派发失败/远端意外回落主 isolate 现跑，业务错误经信封原样抛出，对齐 RUST-01 降级语义） `5aa0679`
- 性能基线工具 `tool/perf_bench.dart` 增 `maxGapMs`（主 isolate 心跳最大间隔，含收尾间隔）≈「UI 最长连续无响应时长」；before/after 对照入 `docs/perf-baseline/README.md` §7.1——TXT 994→27ms、320 章图书 475→130ms、无目录大书 9348→3996ms（残余为平坦目录取标题，待拍板） `5aa0679`
- M2a-T06b PERF-01 残余修复：无目录书平坦目录取标题移入解析 isolate（`flatTitles` 预取表仅 toc 空时填充、非缓存解压字节即弃，`chapters()` 零解压）；big_bodies maxGap 3996→194ms，PERF-01 验收①全样本 <1s 达成 `56fabe5`
- flatTitles 预取测试 5 条（`_FlatTitlesRunner` tamper 法验 `chapters()` 咨询预取表优先 / miss 回退现场取），parse 组 117→122 全绿 `56fabe5`
- 进度表重构：阶段/子任务拆分 + 人天加权进度% + 状态/负责人/预计完成时间 `52664ce`
- 执行序再调整（负责人拍板）：M3.5（Rust 加速层含 ★GATE★）优先级提高，提前到 M2b 之后、统计支线之前（新序 M2a→M2b→M3.5→统计→M4→AI/TTS）；依赖不破、gate 阈值 1/4 基线齐备；全局日历重排挂账
- M2a-T05 交付验收（M2a 收官）：全量 `flutter test` **400 passed / 1 failed**（#4 既存不阻塞）；§17 M2 判定第 2 条（排版语义六件套）由 fx12 端到端锁死、第 6 条（详情页）由 detail/meta 测试覆盖；PERF-01 回归四样本 maxGap 30/24/33/186ms 全 <1s 无回归 `83b95b4`
- M2a-T05 补 fixture：`fx12_typography_semantics.epub` 排版语义综合样本（标题/加粗/换行/表格/插图/脚注）+ baseline 人工推演预期 + 语义逐项标注测试 2 条（parse 组 122→124） `83b95b4`

### 修复

- M2b-T06 滚动中进度恒不动：`ScrollUpdateNotification` 派发于 layout 之前，采样读 `localToGlobal` 拿到上一帧几何、章内位置恒算 0——`_laidOutPixels` 帧末基线把「滚动已发生、布局未跟上」的滞后补回块 top（`ScrollEnd` 写盘值的同型滞后一并治），见 tech-usage 2.27 `37090e5`
- M2b-T06 书签删除验收③ 整组跑 30s 超时：`liquid_glass_widgets` 玻璃弹层在 `flutter test` 软件光栅下每帧背景捕获带数百毫秒真实异步开销且累积（对照实验换普通弹层后 28s→1.2s）——落盘收敛断言改条件驱动（满足即 break），见 tech-usage 2.26 `37090e5`
- 测试夹具 `kTinyPng` 是坏 PNG（IDAT CRC 损坏、chunk 结构崩坏）→ Flutter `instantiateImageCodec` 解码必败；换 zlib 自构造 1×1 RGB PNG（三 chunk CRC 全过）——连带闭环 M1-T09 起挂案的 `cover_store` 缩略图既存失败（同一根因：缩略图生成解码失败） `28e66f8`

## 2026-09-23

### 新增

- M2a-T03 数据层：BookRecord 增 intro 与书名/作者/简介/封面四来源标记（枚举名落盘，旧索引缺失回 none）`4fc5d16`
- M2a-T03 导入带来源：ImportService 构造记录时带入 intro + 四来源（新导入来源天然正确，META-08②）`4fc5d16`
- M2a-T03 仓库更新口：LibraryRepository.updateRecord 整体替换同 bookId 条目（编辑/恢复自动值落盘通道）`4fc5d16`
- M2a-T03 详情页（浏览态）：BookDetailPage 展示封面/书名/作者/四来源标记/格式/大小/进度/分组/简介占位/统计入口，顶栏玻璃、内容整体不透明（UI-04）`51d9071`
- M2a-T03 入口改道：书架点卡片进详情页（F9/META-08①），开书经 onOpenBook 回调复用书架管道，pop 后刷新列表 `51d9071`
- M2a-T03 封面查看与选图：cover_picker 大图 readFull 现读（PERF-02）+ FilePicker 本地选图 `51d9071`
- M2a-T03 元数据编辑（META-09）：详情页编辑态三输入框 + 校验，仅变化字段置 user 落盘 `8851968`
- M2a-T03 换封面：replaceWithUserPick 内建旧文件清理（META-06②）+ coverOrigin 置 user `8851968`
- M2a-T03 恢复自动值：重新解析回填 auto 文本与四来源，EPUB 封面物化覆盖 / 无内嵌封面清旧文件 `8851968`
- M2a-T03 批次4 验收测试：detail_test 覆盖 META-08①~④ / META-09①~④ + meta_editor 纯函数 + 玻璃红线断言 + 详情页编辑/书架同步链路；LibraryRepository.bookFileSize（只 stat 不读内容，PERF-02）`f978266`
- 测试分组：新增 `tool/test.sh`（parse/data/reader/ui/fast/all 六档局部执行，统一 --timeout 30s）；`test/epub_fixtures_test.dart` 归入 `test/epub/`（8 处引用同步）；分组口径入 `docs/tech-usage.md`
- 执行序调整（负责人拍板）：AI 五项 + TTS 四项降级殿后（需求仍 P1），优先阅读功能与体验；新序 M2a→M2b→统计→M3.5 gate→M4→AI/TTS；关键链 169→136 人天 + 殿后 33；gate 首评只用阈值 1/2/4（`docs/PRD.md` §17 M3、`docs/schedule.md` §2.4/§3 同步注记）
- 全量测试须负责人下令（拍板固化）：`tool/test.sh` 无参数不再默认全量（打印 usage 退出），`all` 档标注仅明确指令时执行；开发批次只跑相关分组 `5a90806`
- M2a-T04 批次①书架玻璃化（UI-02）：ShelfPage 导航层 GlassNavScaffold + GlassTopBar（照书架详情页范本），内容包 OpaqueContentSurface（UI-04 不透明红线）；detail_test 玻璃断言限定详情页作用域（书架入栈后全树 2 个顶栏）
- M2a-T04 批次②浮层玻璃化（UI-03）：GlassOverlays.showAlert/showSheet 补 barrierDismissible/maxWidth/isScrollable 透传并导出 GlassDialogAction；4 调用点替换——书架删除确认、详情页移出确认（均玻璃确认框 + isDestructive）、封面大图玻璃弹窗、阅读页目录玻璃底部弹窗（isScrollable:false + OpaqueContentSurface 垫底，TocSheet 行不透明）`9519c5f`
- M2a-T04 批次③ 测试与修复：玻璃断言入 shelf/reader 测试（GlassDialog/GlassSheet/OpaqueContentSurface/isGlassWidget）；修目录弹窗无界高度（isScrollable:false 路径 ConstrainedBox 0.6 屏高）、封面大图空 actions 触库断言（补「关闭」动作）、LIB-06 关闭转场 pumpAndSettle 推进 `9519c5f`+`7b3b76a`

### 变更

- 测试链路提速：新增 `test/test_config.dart::capTestTimeout()`——CLI 的 `--timeout` 对 `testWidgets` **无效**（其显式用 binding 的 10 分钟默认值压过），须在 `main()` 首行把 `defaultTestTimeout` 置 30s；8 个含 `testWidgets` 的文件接入，reader 组从「挂满 10 分钟」降到 22s / 145 用例全绿 `7b3b76a`
- backlog① 开书可见滚动优化（方案 A）：恢复回退分支（冷启动读中段 `coversPrefix` 恒 false）改用同版面 `hint.scrollOffset` 做首帧 seed——目标章大概率首帧即进布局窗口、可精确测量，跳过 `maxScrollExtent` 外推估算（同夹具 26157 ↔ 290816 振荡的乱跳源）；像素仍只作 seed，落点照旧语义坐标校正收敛（`RC2` 不变）`82a3757`
- backlog① 开书可见滚动优化（方案 B）：开书首跳校正全程遮罩正文滚动区（`reader-restore-mask`，opaque 层吞掉恢复期拖动），用户不再看到「前几页 → 当前页」跳动；落定/超帧数放弃统一撤除，目录/链接/上下章主动跳转不遮 `82a3757`
- 首帧批次语义对齐 567Reader：`loadFirstBatch` 改「目标章必等、邻章 ±1 预取不阻塞、各自到货入缓存」（旧 `Future.wait` 全等——任一邻章慢/挂即拖住开书与同批他章）；`_loadOne` 拆分使同批各章互不拖累 `6dc7a21`

### 修复

- 关书保存不得用 null 覆盖 `localHint`：dispose 时 `Scrollable` 子节点先于本 State 卸载、控制器已 detach → `_buildLocalHint()` 返回 null，会把会话中已存的有效像素快照写没（下次开书失去 `RC2` 首帧精确落点）；新增 `_lastLocalHint` 留底，`_saveProgress` 以 `?? _lastLocalHint` 兜底 `7b3b76a`
- 测试跨区死锁：`dispose()` 在 FakeAsync 区发起的保存持有 `AtomicFile._tails` 的路径 gate，其完成回调只有 `pump` 能排空 → 测试体回到活区 `runAsync` 写同路径即永久等待（reader 组整组挂死的真因）；回归用例在 `pumpWidget(SizedBox())` 后补 `_settle` 排空 `7b3b76a`
- 回归②夹具重建：`_FakeSource` 增 `hangIndices`（`content()` 返回永不完成的 future）**冻结布局**以稳定复现「恢复未收敛」，并补非空验证（列表就位 + 有内容渲染 + 目标章标题/正文均不出现）防假绿 `7b3b76a`
- 测试假绿（「同版面 localHint 重开」用例）：「第二次打开」实为 `pumpWidget` 对**同类型无 key** widget 的 State 复用（`initState`/`dispose` 都不跑、controller 是第一次的），断言恒真；补 `pumpWidget(SizedBox())` 拆树真重开，方案 A 的 seed 断言随之落地（`initialScrollOffset == hint.scrollOffset`）`82a3757`
- `_restoreStep` 异常出口（controller 未挂/已卸）改走 `_finishRestore(converged: false)` 统一收口：防方案 B 遮罩永久驻留，`RC1` 闸门语义不变（未收敛照旧不写盘）`82a3757`
- 进书视口漂移（「40 多章跳到 300 多章」）：占位→真实合入 / 占位高估计刷新改总高后像素偏移不动即指向别处，旧 `_resampleAfterLoad` 合入后立即采样还会把漂移位置当真值入档；改为突变前 `ScrollAnchor` 记「视口顶在当前章的相对位置」、突变后 `_beginScrollTo` **语义坐标重锚**（对齐 567Reader「已发布页高不可变、增量刷新不动滚动锚点」；单跳 `correction` 在「跳转未渲染就再次捕获」时叠加 delta 过校正，故走迭代收敛），采样置后到重锚收敛（修 C）`6b21c74`
- 回归④：`_FakeSource` 增 `gates` 夹具（`content()` await `Completer.future`、测试择机放行）稳定构造「上方章稍后到货」，断言合入前后「第 2 章标题顶 − 视口顶」间距不变（修前实测漂移 810px，修后 ≤2px）`6b21c74`

### 移除

- Q24 收尾：删除漏删的 `test/fixtures/shenshi.json`（M0 期 legado 书源原文样本，`236cead` 删原型时漏删、全仓零引用）；测试注释「假书源」改「假内容源」（`BookSource` 是格式解析抽象，易与 legado 网络书源同名混淆）

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
