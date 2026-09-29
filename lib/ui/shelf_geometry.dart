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
// 范围（2026-09-28 拍板「只动布局几何」）：本文件只管**几何**——列数、比例、
// 间距、padding、卡片分区高度。**字号 / 颜色 / 阴影一律不在此列**（保持本项目
// 自己的取舍，不照搬 anx）。
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
const EdgeInsets kShelfGridPadding = EdgeInsets.fromLTRB(
  20,
  12,
  20,
  kShellBottomInset,
);

// ---------------------------------------------------------------------------
// 单卡分区（`BookCard`）
// ---------------------------------------------------------------------------

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
