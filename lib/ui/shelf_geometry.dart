// 书架布局几何 —— **事实源单一文件**（拍板「几何抽成事实源 + 契约测试」）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么要有这个文件
// ══════════════════════════════════════════════════════════════════════════════
// 本项目书架几何**对齐 mi_like_ui 首页卡片**（拍板「整体全换 Mi 度量」，2026-10-27）：
// 网格与单卡的间距 / 圆角逐项取自 `MiThemeCard`（HyperOS 主题商店首页
// 「精选主题」卡）的 1:1 实测度量——**不自己写字面量，直接引用框架 token**
// （`MiThemeCardMetrics` / `MiDimens`），框架改值书架自动跟。
// **唯一例外 = 封面比例**：Mi 卡的 259:472 是**锁屏预览图**的手机比例，书卡用
// 它会比真书瘦高一圈；拍板「高度降低一些，视觉上像一本书」（2026-10-27）
// → 书封改用常见实体书比例 **2:3**（[kBookCoverAspectRatio]，本项目自有值）。
//
// 但「值对了不等于接线对了」：一旦散落在多个文件里就变成多份人工转述，转述错
// 一条画面就崩。故：**所有几何数值只在这里定义一次**；`shelf_grid.dart` 与
// `book_card.dart` 一律引用本文件的常量，不再各自写字面量。
//
// 配套的**契约测试** `test/ui/shelf_geometry_contract_test.dart` 锁住关键数值
// （用硬编码期望值断言真实渲染尺寸，而不是回头引用这里的常量——引用常量等于
// 同义反复）。**改本文件任何数值前，先核对：**
//   ① PRD 有没有相应要求（US-06 / LIB-01 / UI-04）
//   ② 引用的 `MiThemeCardMetrics` / `MiDimens` token 值是否仍是当前值
//   ③ **保留项没被换掉**：默认封面、真封面、封面右下角格式角标、底部书名·作者·进度
// ══════════════════════════════════════════════════════════════════════════════
//
// 范围（拍板「只动布局几何」，后追加「封面圆角」）：本文件只管**几何**——列数、
// 比例、间距、padding、卡片分区高度、**封面圆角**。**字号 / 颜色 / 阴影一律不
// 在此列**：封面投影是绘制样式、不是布局量，故定义在 `book_card.dart`
// （`kBookCoverShadow`），本文件只留这条边界说明，免得以后有人以为漏了。
import 'package:flutter/widgets.dart' show EdgeInsets;

import 'home_shell.dart' show kShellBottomInset;
// Mi 首页卡片的实测度量与圆角 token（框架只读引用，本文件不改框架）。
import 'mi_like_ui/mi_like_ui.dart' show MiDimens, MiThemeCardMetrics;

// ---------------------------------------------------------------------------
// 网格度量（`ShelfGrid`）
// ---------------------------------------------------------------------------

/// 单列的目标宽度 —— **列数 = 容器宽 ~/ 本值**。
///
/// anx 出处：`bookshelf_page.dart:453-454`
/// `crossAxisCount: constraints.maxWidth ~/ Prefs().bookCoverWidth`，其
/// `bookCoverWidth` 默认 **120**（设置页可调 80–260 步长 10）。**换 Mi 布局后
/// 这个口径保留**：392dp 手机仍 3 列，单列 114.8 ≈ Mi 参考图实测图宽 115.5
/// （393dp 三列），与 Mi 首页同为三列、几何天然对齐。
///
/// 本项目暂未开放该设置项（要开放只改这里的读取来源）。用它换来的性质：
/// **列数随宽度连续自适应**，而非「最大列宽」式阶梯跳变。
const double kShelfCoverTargetWidth = 120;

/// 网格列数下限。`SliverGridDelegateWithFixedCrossAxisCount` 断言
/// `crossAxisCount > 0`，极窄窗口（<120px）下 `~/` 会算出 0。
const int kShelfMinColumns = 1;

/// 网格列数上限（纯防御，正常视口用不到）。
const int kShelfMaxColumns = 64;

/// 无宽度信息时的回退列数（anx 的手机默认值 3）。
const int kShelfFallbackColumns = 3;

/// 无列宽信息时的**回退**高宽比（宽/高）：按 [kShelfCoverTargetWidth] 套
/// [shelfChildAspectRatio] 的同一公式算出的定值 `120 / (120×3/2 + 8 + 30)`。
///
/// 封面区随列宽等比定高，故正常渲染路径**不用**固定值（见
/// [shelfChildAspectRatio]）；这条只兜 `ShelfGrid` 里 `cellWidth` 算不出来的
/// 分支（宽度非有限）。
const double kShelfChildAspectRatio = kShelfCoverTargetWidth /
    (kShelfCoverTargetWidth / kBookCoverAspectRatio +
        kBookCoverToInfoGap +
        kBookInfoHeight);

/// 单元格高宽比（宽/高）—— **由列宽推导**，取代 anx 的固定 `1 / 2.1`。
///
/// 封面区按 [kBookCoverAspectRatio]（书本比例 2:3）随列宽等比定高，其下叠
/// [kBookCoverToInfoGap] 与固定高的信息区 [kBookInfoHeight]：
/// `cellHeight = cellWidth × 3/2 + 8 + 30`。
///
/// [cellWidth] 非有限或非正时回退 [kShelfChildAspectRatio]（GridView 的可用宽
/// 恒为有限值，这条分支正常渲染拿不到，纯防御）。
double shelfChildAspectRatio(double cellWidth) =>
    cellWidth.isFinite && cellWidth > 0
    ? cellWidth /
          (cellWidth / kBookCoverAspectRatio +
              kBookCoverToInfoGap +
              kBookInfoHeight)
    : kShelfChildAspectRatio;

/// 行间距（同一列上下两格之间）= Mi 卡「标题行盒底 → 次行图顶」的实测 15
/// （`MiThemeCardMetrics.rowGap`；anx 旧值 30）。
const double kShelfMainAxisSpacing = MiThemeCardMetrics.rowGap;

/// 列间距 = Mi 卡实测列距 11.9（`MiThemeCardMetrics.columnGap`；anx 旧值 20）。
const double kShelfCrossAxisSpacing = MiThemeCardMetrics.columnGap;

/// 书架网格的**页面左右边距** = Mi 首页卡片图区的实测页边距 11.9
/// （`MiThemeCardMetrics` 度量表：page edge inset 25~28px × 0.4461）。
///
/// ⚠️ Mi 首页没有现成常量（度量表里只有文字），故本文件自建；与搜索页既有的
/// `_headerInset`（`shelf_search_page.dart`，同为 11.9）天然对齐。
const double kShelfPageInset = 11.9;

/// 书架网格内边距。
///
/// 左右 = [kShelfPageInset]（Mi 首页实测页边距 11.9；anx 旧值 20）；上 12 保持
/// 本项目既有值（网格与上方 UI 的间距，Mi 参考图无浮动头部、无对应实测）；
/// **底部 = [kShellBottomInset]**（给悬浮胶囊留白；anx 旧值 80，本项目胶囊更高）。
///
/// ⚠️ 本常量是**网格的固有间距**（上 12 = 网格与上方 UI 的间距）。书架页
/// 内容 edge-to-edge 后（2026-09-29 浮动头部批），页面侧还须叠加
/// `状态栏 + [kShelfHeaderHeight]` 的顶部留白——用 [shelfGridPadding] 合成，
/// 不要直接把本常量喂给 `ShelfGrid` 就完事（首行会被浮动头部盖住）。
const EdgeInsets kShelfGridPadding = EdgeInsets.fromLTRB(
  kShelfPageInset,
  12,
  kShelfPageInset,
  kShellBottomInset,
);

// ---------------------------------------------------------------------------
// 浮动头部（搜索行 + 分组 chips 行）
// ---------------------------------------------------------------------------
// 参考图 = HyperOS 主题商店首页（拍板「全浮动头部」）：搜索胶囊与 chips 同属
// 浮动头部、压在 edge-to-edge 的内容上。以下三值是**头部行高分解**，
// [kShelfHeaderHeight] 由它们求和得出（改行高先改分解项）。

/// 搜索行高（= [MiSearchBar] 栏高 44.1 + 两侧动作按钮的行）。行高**必须 ≥
/// 栏高**，否则 Row 垂直溢出 0.1，故取 44.1（`MiSearchBarMetrics.barHeight`）。
const double kShelfSearchRowHeight = 44.1;

/// 搜索行与 chips 行的间距（参考图上约为胶囊高度的一半 → 12）。
const double kShelfHeaderRowGap = 12;

/// 分组 chips 行高（原正文筛选栏的行高，随 chips 一并上移进头部）。
const double kShelfChipsRowHeight = 40;

/// 浮动头部总高（**状态栏之下**的部分；GlassAppBar 自带 SafeArea 吃掉状态栏）。
///
/// 同时是 `GlassTopBar.toolbarHeight` 与网格首行顶部留白的组成部分。
/// 44.1 + 12 + 40 = **96.1**（契约测试按字面量锁）。行高/间距是照参考图估的
/// 初始值（截图为缩放图，不作精确依据），真机复核后可整体调。
const double kShelfHeaderHeight =
    kShelfSearchRowHeight + kShelfHeaderRowGap + kShelfChipsRowHeight;

/// 合成书架网格的最终内边距：`top = 状态栏 + 浮动头部高 + [kShelfGridPadding.top]`。
///
/// 顶部留白保证**首行不被浮动头部盖住**（拍板验收条目）；行仍会随滚动从头部下
/// 穿过、透出磨砂模糊（`UI-02` ②）。`topInset` 传 `MediaQuery.paddingOf(context).top`。
/// [headerHeight] 默认 [kShelfHeaderHeight]（搜索栏 + 胶囊行两行）；**搜索态**下
/// 胶囊行收起、头部只剩搜索行，传 [kShelfSearchRowHeight]——否则结果网格顶部会
/// 多留一整块空白。
EdgeInsets shelfGridPadding(
  double topInset, {
  double headerHeight = kShelfHeaderHeight,
}) =>
    kShelfGridPadding.copyWith(
      top: topInset + headerHeight + kShelfGridPadding.top,
    );

// ---------------------------------------------------------------------------
// 单卡分区（`BookCard`）
// ---------------------------------------------------------------------------

/// 封面（图区）宽高比 = **书本比例 2:3**（宽/高）。
///
/// ⚠️ **本项目自有值，不用 Mi 卡的 259:472**（`MiThemeCardMetrics.imageAspectRatio`
/// ≈ 0.549 是**锁屏预览图**的手机比例）。拍板「高度降低一些，视觉上像一本书」
/// （2026-10-27）：常见实体书封约 2:3，同列宽下封面高度从 ×1.822 降到 ×1.5，
/// 卡片整体矮 ~15%（392 宽三列：封面 209.2 → 172.2 高）。
const double kBookCoverAspectRatio = 2 / 3;

/// 封面圆角 = Mi 卡预览图圆角 [MiDimens.radiusLg]（外缘拟合 R≈19.6 → 20；
/// anx 旧值 8）。书卡封面与「无封面」占位色块**共用同一个圆角**（同一处
/// `ClipRRect`），故缩略图异步到位前后不会跳变；`DefaultBookCover` 的 `radius`
/// 也由调用方传本常量（其组件默认值 8 是详情页等处的既有口径，与书架无关）。
const double kBookCoverRadius = MiDimens.radiusLg;

/// 封面与信息区之间的间距 = Mi 卡「图底 → 标题行盒」实测 8
/// （`MiThemeCardMetrics.titleTopGap`；anx 旧值 5）。
const double kBookCoverToInfoGap = MiThemeCardMetrics.titleTopGap;

/// 信息区（书名 + 作者·进度）的**固定高度** 30（anx 旧值 55）。
///
/// 固定而非自适应，是为了让书名截断与否的卡片都等高、网格行距不跳。推导：
/// 书名行盒 = [MiTypography.cardTitle] 字号 13.85（`height: 1.0`）
/// ＋ [kBookTitleToAuthorGap] 2 ＋ 作者·进度行盒 13（fontSize 11 × `height: 1.18`）
/// = 28.85 ≤ 30（余 1.15 防字形溢出）。**两行文字样式的 `height` 必须显式钉死**
/// （见 `book_card.dart` 的 `_buildInfo`），否则实际渲染高度会随主题字体漂移。
/// 内部只允许两段：书名（单行省略，Mi 卡口径）+ 作者·进度行；**格式标签不在此处**
/// （PRD `US-06`/`LIB-01` 要求格式标签，拍板「挪到封面上做角标」）。
const double kBookInfoHeight = 30;

/// 书名与「作者 · 进度」行之间的间距。
///
/// ⚠️ **本项目自有值**：Mi 卡没有第二行、anx 信息区内两个 `Row` 之间也没有
/// `SizedBox`（间距 0），此处的 2 是本项目自己加的微调——事实源照实记录差异，
/// 避免以后有人逐行对照时误判成「抄错了」。
const double kBookTitleToAuthorGap = 2;

/// 信息区左右内边距 = Mi 卡标题相对图左缘的实测内缩 8.8
/// （`MiThemeCardMetrics.titleIndent`；anx 旧值 2）。内缩后书名与 Mi 首页卡的
/// 标题同列起排；右侧同值，使进度百分比不贴卡片边缘。
const double kBookInfoIndent = MiThemeCardMetrics.titleIndent;

/// 封面右下角**格式标签角标**的内边距（距封面右/下边缘各此值；anx 旧值 6）。
///
/// 角标放在 `ClipRRect` **内**，随封面圆角一起裁切，不会溢出圆角。取 8
/// （= [MiDimens.spaceSm]）：圆角放大到 20 后，内缩 6 时角标外角距角弧只剩
/// 0.2，会被弧擦到。
const double kBookFormatBadgeInset = MiDimens.spaceSm;
