// 书架布局几何 —— **事实源单一文件**（2026-09-29 拍板「几何抽成事实源 + 契约测试」）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么要有这个文件
// ══════════════════════════════════════════════════════════════════════════════
// 本项目书架几何「复刻 anx-reader」，但 anx 的 widget 长在 Riverpod + freezed +
// sqflite 骨架上（其 `book_item.dart:10-11` 就 import `flutter_riverpod` 并
// `ref.watch(syncStatusProvider)`），**搬不动**，只能照抄数值。而「照抄」一旦散落在
// 多个文件里，就变成多份人工转述——转述错一条，画面就崩（2026-09-28 实证：
// 一次几何批次要动 3 个文件 6 处数值）。
//
// 故：**所有几何数值只在这里定义一次**，每条附 anx 出处行号；`shelf_grid.dart`
// 与 `book_card.dart` 一律引用本文件的常量，不再各自写字面量。
//
// 配套的**契约测试** `test/ui/shelf_geometry_contract_test.dart` 锁住关键数值
// （用硬编码期望值断言真实渲染尺寸，而不是回头引用这里的常量——引用常量等于
// 同义反复，常量改了测试也跟着改就红不了）。**改本文件任何数值前，先核对：
//   ① PRD 有没有相应要求（US-06 / LIB-01 / UI-04）
//   ② 下方标注的 anx 出处行号是否仍是当前值**
// ══════════════════════════════════════════════════════════════════════════════
//
// 范围（2026-09-28 拍板「只动布局几何」；2026-09-29 追加「封面圆角」）：本文件
// 只管**几何**——列数、比例、间距、padding、卡片分区高度、**封面圆角**。
// **字号 / 颜色 / 阴影一律不在此列**：封面投影的数值虽在 2026-09-29 对齐了 anx，
// 但阴影是绘制样式、不是布局量，故定义在 `book_card.dart`（`kBookCoverShadow`），
// 本文件只留这条边界说明，免得以后有人以为漏了。
import 'package:flutter/widgets.dart' show EdgeInsets;

import 'home_shell.dart' show kShellBottomInset;

// ---------------------------------------------------------------------------
// 网格度量（`ShelfGrid`）
// ---------------------------------------------------------------------------

/// 单列的目标宽度 —— **列数 = 容器宽 ~/ 本值**。
///
/// anx 出处：`bookshelf_page.dart:453-454`
/// `crossAxisCount: constraints.maxWidth ~/ Prefs().bookCoverWidth`，其
/// `bookCoverWidth` 默认 **120**（设置页可调 80–260 步长 10）。
///
/// 本项目暂未开放该设置项（要开放只改这里的读取来源）。用它换来的性质：
/// **列数随宽度连续自适应**，而非「最大列宽」式阶梯跳变——392dp 手机 3 列。
const double kShelfCoverTargetWidth = 120;

/// 网格列数下限。`SliverGridDelegateWithFixedCrossAxisCount` 断言
/// `crossAxisCount > 0`，极窄窗口（<120px）下 `~/` 会算出 0。
const int kShelfMinColumns = 1;

/// 网格列数上限（纯防御，正常视口用不到）。
const int kShelfMaxColumns = 64;

/// 无宽度信息时的回退列数（anx 的手机默认值 3）。
const int kShelfFallbackColumns = 3;

/// 单元格高宽比 = 宽/高。anx 出处：`bookshelf_page.dart:455`
/// `childAspectRatio: 1 / 2.1`（比早先的 0.5 更瘦高，封面占比更大）。
const double kShelfChildAspectRatio = 1 / 2.1;

/// 行间距（同一列上下两格之间）。anx 出处：`bookshelf_page.dart:456`
/// `mainAxisSpacing: 30`。
const double kShelfMainAxisSpacing = 30;

/// 列间距。anx 出处：`bookshelf_page.dart:457` `crossAxisSpacing: 20`。
const double kShelfCrossAxisSpacing = 20;

/// 书架网格内边距。
///
/// 左右 20 / 上 12 照搬 anx（`bookshelf_page.dart:449`
/// `EdgeInsets.fromLTRB(20, 12, 20, 80)`）；
/// **底部 80 换成本项目的 [kShellBottomInset]**——两者目的相同（给悬浮胶囊留白），
/// 但本项目胶囊更高，用 anx 的 80 会被压住。
///
/// ⚠️ 本常量是**网格的固有间距**（上 12 = 网格与上方 UI 的间距）。书架页
/// 内容 edge-to-edge 后（2026-09-29 浮动头部批），页面侧还须叠加
/// `状态栏 + [kShelfHeaderHeight]` 的顶部留白——用 [shelfGridPadding] 合成，
/// 不要直接把本常量喂给 `ShelfGrid` 就完事（首行会被浮动头部盖住）。
const EdgeInsets kShelfGridPadding = EdgeInsets.fromLTRB(
  20,
  12,
  20,
  kShellBottomInset,
);

// ---------------------------------------------------------------------------
// 浮动头部（搜索行 + 分组 chips 行；2026-09-29 参考图批）
// ---------------------------------------------------------------------------
// 参考图 = HyperOS 主题商店首页（负责人 2026-09-29 指令「标题栏也参考图片，
// 内容可以 edge to edge」+ 拍板「全浮动头部」）：搜索胶囊与 chips 同属
// 浮动头部、压在 edge-to-edge 的内容上。以下三值是**头部行高分解**，
// [kShelfHeaderHeight] 由它们求和得出（改行高先改分解项）。

/// 搜索行高（= [MiSearchBar] 栏高 44.1 + 两侧动作按钮的行）。
///
/// 2026-10-19 上游搜索栏批：搜索胶囊由 36 高 [GlassButton.custom] 换成
/// [MiSearchBar]（栏高 `MiSearchBarMetrics.barHeight` = 44.1，1:1 实测自
/// 亮/暗分类页截图）。行高必须 ≥ 栏高，否则 Row 垂直溢出 0.1；故取 44.1
/// 而非原 44（原 36 高胶囊 + 上下各 4 留白的口径随材质替换一并退场）。
const double kShelfSearchRowHeight = 44.1;

/// 搜索行与 chips 行的间距（参考图上约为胶囊高度的一半 → 12）。
const double kShelfHeaderRowGap = 12;

/// 分组 chips 行高（原正文筛选栏的行高，随 chips 一并上移进头部）。
const double kShelfChipsRowHeight = 40;

/// 浮动头部总高（**状态栏之下**的部分；GlassAppBar 自带 SafeArea 吃掉状态栏）。
///
/// 同时是 `GlassTopBar.toolbarHeight` 与网格首行顶部留白的组成部分。
/// 44.1 + 12 + 40 = **96.1**（契约测试按字面量锁）。行高/间距是**照参考图估的**
/// 初始值（截图为缩放图，不作精确依据），真机复核后可整体调。
const double kShelfHeaderHeight =
    kShelfSearchRowHeight + kShelfHeaderRowGap + kShelfChipsRowHeight;

/// 合成书架网格的最终内边距：`top = 状态栏 + 浮动头部高 + [kShelfGridPadding.top]`。
///
/// 顶部留白保证**首行不被浮动头部盖住**（拍板验收条目）；行仍会随滚动
/// 从头部下穿过、透出磨砂模糊（`UI-02` ②）。`topInset` 传
/// `MediaQuery.paddingOf(context).top`。
EdgeInsets shelfGridPadding(double topInset) => kShelfGridPadding.copyWith(
      top: topInset + kShelfHeaderHeight + kShelfGridPadding.top,
    );

// ---------------------------------------------------------------------------
// 单卡分区（`BookCard`）
// ---------------------------------------------------------------------------

/// 封面圆角。
///
/// anx 出处：`book_cover.dart:30` 的 `radius ?? 8`——其 `BookCover` 未传 `radius`
/// 时用 **8**。2026-09-29 拍板「对齐 anx 的阴影与圆角」，本项目由 6 改为 8。
///
/// 书卡封面与「无封面」占位色块**共用同一个圆角**（同一处 `ClipRRect`），
/// 故缩略图异步到位前后不会跳变。
///
/// ⚠️ anx 封面还叠了两样本项目**未采纳**的东西（不在本次「阴影 + 圆角」范围内）：
/// `ClipRSuperellipse` 超椭圆裁剪与 `RoundedSuperellipseBorder(width: 0.3,
/// color: Colors.grey)` 描边（其 `book_cover.dart:125-131`）。这两个是 Flutter
/// 自带能力（`widgets/basic.dart:1125` / `painting/rounded_rectangle_border.dart:226`），
/// 要跟随时不需要引依赖，换掉 `ClipRRect` + 补一层 `border` 即可。
const double kBookCoverRadius = 8;

/// 封面与信息区之间的间距。anx 出处：`book_item.dart:88` `SizedBox(height: 5)`。
const double kBookCoverToInfoGap = 5;

/// 信息区（书名 + 作者·进度）的**固定高度**。
///
/// anx 出处：`book_item.dart:89-90` 的 `SizedBox(height: 55)`。
/// 固定而非自适应，是为了让「一行书名」与「两行书名」的卡片等高、网格行距不跳。
///
/// 内部只允许两段：书名（最多 2 行）+ 作者·进度行；**格式标签不在此处**
/// （PRD `US-06`/`LIB-01` 要求格式标签、anx 原版没有，2026-09-28 拍板
/// 「挪到封面上做角标」）。
const double kBookInfoHeight = 55;

/// 书名与「作者 · 进度」行之间的间距。
///
/// ⚠️ **本项目自有值，与 anx 不同**：anx 的 `book_item.dart` 信息区内两个
/// `Row` 之间**没有** `SizedBox`（间距 0），此处的 2 是本项目自己加的微调。
/// 事实源照实记录差异，避免以后有人拿 anx 逐行对照时误判成"抄错了"。
const double kBookTitleToAuthorGap = 2;

/// 信息区左右内边距（书名与作者行都不贴卡片边缘）。
///
/// ⚠️ **本项目自有值**：anx 的 `book_item.dart` 信息区（`:89-90` 的
/// `SizedBox(height: 55)`）内部直接是两个 `Row`，**没有**水平 Padding。
const double kBookInfoHorizontalPadding = 2;

/// 封面右下角**格式标签角标**的内边距（距封面右/下边缘各此值）。
///
/// 角标放在 `ClipRRect` **内**，随封面圆角一起裁切，不会溢出圆角。
const double kBookFormatBadgeInset = 6;
