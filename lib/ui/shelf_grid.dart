// 书架网格（`LIB-01` 的展示层）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 布局几何：复刻 anx-reader（2026-09-28 拍板「只动布局几何」）
// ══════════════════════════════════════════════════════════════════════════════
// 列数 = 容器宽 ~/ 120、比例 1/2.1、行距 30 / 列距 20、内边距 (20, 12, 20, ·)，
// 出处与取值见 [kShelfCoverTargetWidth] / [kShelfGridPadding]；字号、颜色、
// 阴影一律保持本项目现状（不照搬 anx）。
//
// PRD 取舍（anx 没有但必须留的两处）：
//   · 格式标签（US-06 / LIB-01）→ 挪到封面右下角作角标（`book_card.dart`）；
//   · 空态「导入书籍」按钮（LIB-01 ②）→ 保留，不复刻 anx 的纯颜文字空态。
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-09-29 拍板：**去拖拽化**（拖拽归类 → 分组）
// ══════════════════════════════════════════════════════════════════════════════
// 拖拽（建文件夹 / 移入文件夹 / 重排）**整体移除**，本文件只剩「按几何排布书卡」：
//   · 归类改由**书籍详情页的「分组」行**完成（需求 `P2-02`，见 `book_detail_page`）；
//   · 书架按分组筛选（顶部 chips，见 `shelf_page`），网格**平铺**当前可见书，
//     没有文件夹卡、没有文件夹内页；
//   · 长按书卡仍弹操作单（`LIB-06` 语义），改由 `BookCard.onLongPress` 直接承载
//     ——没有外层 `LongPressDraggable` 了，不存在手势竞技场冲突（原先网格内把
//     书卡 `onLongPress` 置 `null` 正是为了避让拖拽容器）。
//   · 2026-09-29 追加：长按的**抬起反馈**（放大 1.05 + 浮起阴影）在 `BookCard`
//     内部实现——照抄 anx 借 `flutter_reorderable_grid_view` 拿到的数值，但
//     **不跟手**，故依旧不引该包（`book_card.dart` 顶部总注记了全部出处）。
//
// 本文件**无状态**：不涉及 `setState`（状态管理红线针对有状态组件）。
import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import 'book_card.dart';
// 几何数值**只在 `shelf_geometry.dart` 定义一次**（2026-09-29 拍板）：
// import 供本文件使用，export 使既有调用点无需改动 import 路径。
import 'shelf_geometry.dart';

export 'shelf_geometry.dart';

/// 书架（与分组筛选后的网格同源）的背景渐变。
///
/// anx-reader 用 `colorScheme.primary.withAlpha(5)` **叠在** Scaffold 底色上做
/// 出右上角极淡光晕。本项目 `UI-04` 要求内容层不得半透明，故此处的做法是
/// **先把半透明色与底色合成**（[Color.alphaBlend]，结果 alpha 恒为 1）——
/// 观感与「半透明叠底」等效，红线不破。
BoxDecoration shelfGradientBackground(ThemeData theme) {
  final Color base = theme.scaffoldBackgroundColor;
  final Color glow = Color.alphaBlend(
    theme.colorScheme.primary.withValues(alpha: 0.02),
    base,
  );
  return BoxDecoration(
    gradient: RadialGradient(
      center: Alignment.topRight,
      radius: 1,
      colors: <Color>[glow, base],
    ),
  );
}

/// 书架网格：按几何排布可见书卡。
class ShelfGrid extends StatelessWidget {
  /// 创建书架网格。
  const ShelfGrid({
    super.key,
    required this.books,
    required this.coverStore,
    required this.openingBookId,
    required this.onOpenBook,
    required this.onBookActions,
    this.padding = kShelfGridPadding,
  });

  /// 要展示的书（**已在外层完成分组筛选 / 排序**，本组件不再过滤）。
  final List<BookRecord> books;

  /// 封面存储（书卡取缩略图）。
  final CoverStore coverStore;

  /// 正在准备打开的书（bookId）：对应卡显示 loading 覆盖层。
  final String? openingBookId;

  /// 点书卡（**直接进阅读页**；2026-09-29 改道，原先进详情页）。
  final void Function(BookRecord record) onOpenBook;

  /// 长按书卡（弹底部操作单，`LIB-06`）。
  ///
  /// 返回的 Future **在操作单关闭时即完成**，不等操作单里选定的动作
  /// （开书 / 详情 / 删除）走完——书卡拿它当**长按抬起反馈的复位时机**
  /// （`book_card.dart` 的 `_handleLongPress`）。若做成「动作走完才完成」，
  /// 用户点「继续阅读」后卡片会一直保持抬起状态。
  final Future<void> Function(BookRecord record) onBookActions;

  /// 网格内边距（默认给壳层浮动胶囊留出底部空白，见 [kShelfGridPadding]）。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // 列数按 anx-reader 的口径算：**容器宽 ~/ 单列目标宽**（不是「最大列宽」式）。
    // 用 LayoutBuilder 拿到 GridView 自身的可用宽——与 anx 的
    // `Expanded > LayoutBuilder > GridView` 结构一致（其 `constraints.maxWidth`
    // 同样是**含 padding 的整宽**）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        // 宽度未定（理论上不会，GridView 在 Expanded 内）时退回 anx 的手机默认列数。
        int columns = width.isFinite
            ? width ~/ kShelfCoverTargetWidth
            : kShelfFallbackColumns;
        // 下限：`SliverGridDelegateWithFixedCrossAxisCount` 断言 crossAxisCount > 0，
        // 极窄窗口（<120px）下 `~/` 会算出 0。上限纯属防御。
        if (columns < kShelfMinColumns) columns = kShelfMinColumns;
        if (columns > kShelfMaxColumns) columns = kShelfMaxColumns;
        return GridView.builder(
          // 浮动胶囊不占布局高度，底部留白由 kShellBottomInset 提供
          // （已随 `kShelfGridPadding` 进入本文件的 padding 默认值）。
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            // 几何数值全部取自 `shelf_geometry.dart`（每条附 anx 出处行号）。
            childAspectRatio: kShelfChildAspectRatio,
            mainAxisSpacing: kShelfMainAxisSpacing,
            crossAxisSpacing: kShelfCrossAxisSpacing,
          ),
          itemCount: books.length,
          itemBuilder: (BuildContext context, int index) {
            final BookRecord record = books[index];
            return BookCard(
              // key 不可省：列表增删后 element 复用会让卡片状态错位到别的书上。
              key: ValueKey<String>('book-${record.bookId}'),
              record: record,
              coverStore: coverStore,
              loading: openingBookId == record.bookId,
              onTap: () => onOpenBook(record),
              // 透传即可：`BookCard` 会 `await` 这个 Future 来做长按抬起 / 复位
              // （见 `ShelfGrid.onBookActions` 的返回值语义）。
              onLongPress: () => onBookActions(record),
            );
          },
        );
      },
    );
  }
}
