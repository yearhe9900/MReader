// 书架网格（`LIB-01` 的展示层 + L3 拖拽交互）。
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
// 两种拖拽动作如何区分（2026-09-28 定）
// ══════════════════════════════════════════════════════════════════════════════
// 长按书卡后：
//   · **没有移动就抬手** → 底部操作单（沿用 `LIB-06` 语义：长按 = 操作单）；
//   · 拖到另一本书上**快速放下** → 在散书区重排（插入到目标位置）；
//   · 拖到另一本书上**悬停 [kFolderMergeHoverDelay]** → 把被拖的书并入目标书
//     所在文件夹；目标书不在任何文件夹时，新建一个以目标书书名命名的文件夹。
//   · 拖到**文件夹卡**上 → 直接移入该文件夹。
//
// 判定用 `onDragUpdate` 是否被调用过（而不是 `DraggableDetails.offset` 的距离）：
// 「长按未动」时 `onDragUpdate` 根本不会触发，这比比较浮点偏移量稳健。
// 悬停计时用「`onMove` 首次进入即启动、`onLeave` 取消」——`onMove` 会持续触发，
// 故用 `??=` 保证只启动一次。
//
// ⚠️ 每一项都必须带 `ValueKey`：重排后 `GridView.builder` 的 element 复用会让
// 无 key 的 `StatefulWidget` 状态（悬停计时器 / 合并已就绪标志）错位到别的书上。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么自己实现（不引第三方网格重排包）
// ══════════════════════════════════════════════════════════════════════════════
// 「拖到另一本书上建文件夹」需要**项级** `DragTarget` 与悬停语义，第三方
// `ReorderableGridView` 类只解决「重排」一件事，文件夹仍要自己写——两套拖拽
// 机制并存反而容易在手势竞技场里互相打架。用原生 `LongPressDraggable` +
// `DragTarget` 一次打通两者，且**零新依赖**（2026-09-28 拍板）。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import '../model/book_meta.dart';
import '../settings/shelf_layout_store.dart';
import 'book_card.dart';
// 几何数值**只在 `shelf_geometry.dart` 定义一次**（2026-09-29 拍板）：
// import 供本文件使用，export 使既有调用点（如 `shelf_folder_page` 的
// `kShelfGridPadding`）无需改动 import。
import 'shelf_geometry.dart';

export 'shelf_geometry.dart';

/// 拖到另一本书上、停留多久算「并入文件夹」。
///
/// 取值权衡：太短会在正常重排时误判成合并；太长用户会以为没反应。
/// 900ms 与 anx-reader 的 `BookBottomSheet` 手感接近。
const Duration kFolderMergeHoverDelay = Duration(milliseconds: 900);

/// 书架（与文件夹内页共用）的背景渐变。
///
/// anx-reader 用 `colorScheme.primary.withAlpha(5)` **叠在** Scaffold 底色上做
/// 出右上角极淡光晕。本项目 `UI-04` 要求内容层不得半透明，故此处的做法是
/// **先把半透明色与底色合成**（[Color.alphaBlend]，结果 alpha 恒为 1）——
/// 观感与「半透明叠底」等价，红线不破。
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

/// 书架网格：文件夹在前，散书在后。
///
/// 顺序语义：**文件夹固定排在散书之前**（不参与散书区的重排），
/// 这样「拖拽重排」只需处理散书一个线性空间，语义干净。
class ShelfGrid extends StatelessWidget {
  /// 创建书架网格。
  const ShelfGrid({
    super.key,
    required this.folders,
    required this.books,
    required this.allBooks,
    required this.coverStore,
    required this.openingBookId,
    required this.onOpenBook,
    required this.onBookActions,
    required this.onReorder,
    this.onOpenFolder,
    this.onFolderActions,
    this.onMergeBooks,
    this.onDropIntoFolder,
    this.dragEnabled = true,
    this.padding = kShelfGridPadding,
  });

  /// 文件夹（顺序即展示顺序，排在散书之前）。
  final List<BookFolder> folders;

  /// 散书（**不含**已归属文件夹的书，且已在外层完成筛选 / 排序）。
  final List<BookRecord> books;

  /// 全部可见书（**含**文件夹内的书）。
  ///
  /// 仅供文件夹卡按 bookId 找回封面用——文件夹内的书不在 [books] 里，
  /// 若拿 [books] 去查会永远查不到。
  final List<BookRecord> allBooks;

  /// 封面存储（书卡与文件夹卡取缩略图）。
  final CoverStore coverStore;

  /// 正在准备打开的书（bookId）：对应卡显示 loading 覆盖层。
  final String? openingBookId;

  /// 点书卡（进详情页）。
  final void Function(BookRecord record) onOpenBook;

  /// 长按不动抬手（弹底部操作单）。
  final void Function(BookRecord record) onBookActions;

  /// 散书区重排：`(被拖书 id, 目标下标)`。
  ///
  /// 目标下标是**散书列表**内的下标（不含文件夹偏移），由调用方换算回全量顺序。
  final void Function(String draggedBookId, int toIndex) onReorder;

  /// 点文件夹卡（进文件夹内页）；`null` = 不响应点击（文件夹内页自身用不到）。
  final void Function(BookFolder folder)? onOpenFolder;

  /// 长按文件夹卡（操作单：重命名 / 解散）；`null` = 不响应长按。
  final void Function(BookFolder folder)? onFolderActions;

  /// 悬停后将 `dragged` 并入 `target` 所在（或新建）文件夹；`null` = 不建文件夹。
  final void Function(BookRecord dragged, BookRecord target)? onMergeBooks;

  /// 把书拖进指定文件夹；`null` = 不收。
  final void Function(BookRecord dragged, String folderId)? onDropIntoFolder;

  /// 是否启用拖拽（文件夹内页可关掉重排）。
  final bool dragEnabled;

  /// 网格内边距（默认给壳层浮动胶囊留出底部空白，见 [kShelfGridPadding]）。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final int folderCount = folders.length;
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
          itemCount: folderCount + books.length,
          itemBuilder: (BuildContext context, int index) {
            if (index < folderCount) {
              final BookFolder folder = folders[index];
              return _FolderCell(
                key: ValueKey<String>('folder-${folder.id}'),
                folder: folder,
                coverStore: coverStore,
                allBooks: allBooks,
                onOpen: onOpenFolder == null ? null : () => onOpenFolder!(folder),
                onActions:
                    onFolderActions == null ? null : () => onFolderActions!(folder),
                onDropIntoFolder: dragEnabled ? onDropIntoFolder : null,
              );
            }
            final int bookIndex = index - folderCount;
            final BookRecord record = books[bookIndex];
            return _BookCell(
              // key 不可省：重排后 element 复用会让 State 错位到别的书上。
              key: ValueKey<String>('book-${record.bookId}'),
              record: record,
              index: bookIndex,
              dragEnabled: dragEnabled,
              onReorder: onReorder,
              onMergeBooks: onMergeBooks,
              onLongPressOnly: () => onBookActions(record),
              child: BookCard(
                record: record,
                coverStore: coverStore,
                loading: openingBookId == record.bookId,
                onTap: () => onOpenBook(record),
                // 长按交给外层拖拽容器统一处理（见文件头注）：InkWell 若也认长按，
                // 会与 `LongPressDraggable` 在手势竞技场互抢。
                onLongPress: null,
              ),
            );
          },
        );
      },
    );
  }
}

/// 单本书的拖拽 + 投放容器。
class _BookCell extends StatefulWidget {
  const _BookCell({
    super.key,
    required this.record,
    required this.index,
    required this.child,
    required this.dragEnabled,
    required this.onReorder,
    required this.onLongPressOnly,
    this.onMergeBooks,
  });

  /// 本书记录。
  final BookRecord record;

  /// 在散书列表中的下标。
  final int index;

  /// 书卡本体。
  final Widget child;

  /// 是否允许拖动。
  final bool dragEnabled;

  /// 落到本格（未悬停够时长）→ 重排到本下标。
  final void Function(String draggedBookId, int toIndex) onReorder;

  /// 长按未动就抬手 → 弹操作单。
  final VoidCallback onLongPressOnly;

  /// 悬停够时长 → 并入本格所在（或新建）文件夹。
  final void Function(BookRecord dragged, BookRecord target)? onMergeBooks;

  @override
  State<_BookCell> createState() => _BookCellState();
}

class _BookCellState extends State<_BookCell> {
  Timer? _hoverTimer;
  bool _mergeArmed = false;
  bool _movedDuringDrag = false;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  /// 是否接受这支拖拽（不能拖到自己身上）。
  bool _accepts(BookRecord dragged) =>
      widget.dragEnabled && dragged.bookId != widget.record.bookId;

  /// 进入悬停：只在首次启动计时器。
  ///
  /// `DragTarget.onMove` 会被**持续**调用，故用 `??=` 守住只启动一次。
  void _armHover() {
    if (widget.onMergeBooks == null || _hoverTimer != null) return;
    _hoverTimer = Timer(kFolderMergeHoverDelay, () {
      if (!mounted) return;
      setState(() => _mergeArmed = true);
    });
  }

  /// 离开 / 结束悬停：取消计时器并清掉「已就绪」标志。
  void _cancelHover() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    if (_mergeArmed && mounted) {
      setState(() => _mergeArmed = false);
    } else {
      _mergeArmed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget target = DragTarget<BookRecord>(
          onWillAcceptWithDetails: (DragTargetDetails<BookRecord> details) =>
              _accepts(details.data),
          onMove: (DragTargetDetails<BookRecord> details) => _armHover(),
          onLeave: (BookRecord? _) => _cancelHover(),
          onAcceptWithDetails: (DragTargetDetails<BookRecord> details) {
            final bool armed = _mergeArmed;
            _cancelHover();
            if (armed && widget.onMergeBooks != null) {
              widget.onMergeBooks!(details.data, widget.record);
            } else {
              widget.onReorder(details.data.bookId, widget.index);
            }
          },
          builder: (
            BuildContext context,
            List<BookRecord?> candidates,
            List<Object?> rejected,
          ) {
            Widget content = widget.child;
            if (_mergeArmed) {
              content = _HoverOverlay(
                icon: Icons.create_new_folder_outlined,
                label: '新建文件夹',
                child: content,
              );
            } else if (candidates.isNotEmpty) {
              content = _HoverOverlay(child: content);
            }
            return content;
          },
        );

        if (!widget.dragEnabled) {
          return target;
        }

        return LongPressDraggable<BookRecord>(
          data: widget.record,
          maxSimultaneousDrags: 1,
          onDragStarted: () => _movedDuringDrag = false,
          // 只要动过就会走到这里——比比较 `DraggableDetails.offset` 稳健。
          onDragUpdate: (DragUpdateDetails _) => _movedDuringDrag = true,
          onDragEnd: (DraggableDetails details) {
            _cancelHover();
            // 未落到任何投放区 **且** 全程没动 → 判为「长按」→ 操作单。
            if (!details.wasAccepted && !_movedDuringDrag) {
              widget.onLongPressOnly();
            }
          },
          feedback: _DragFeedback(
            title: widget.record.title,
            width: constraints.maxWidth,
            height: constraints.maxHeight,
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: target),
          child: target,
        );
      },
    );
  }
}

/// 拖拽跟手浮层。
///
/// 只画「书名首字 + 底色 + 投影」而不重复加载缩略图——拖拽期每秒重建数十次，
/// 再起一遍缩略图 IO 不划算，观感上也够用。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({
    required this.title,
    required this.width,
    required this.height,
  });

  final String title;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String initial =
        title.isNotEmpty ? title.characters.first : '?';
    return SizedBox(
      width: width,
      height: height,
      // overlay 里没有 Material 祖先，文字会带默认黄色下划线；给一层透明
      // Material 只为提供文字样式与命中测试的“地基”，不绘制底色。
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: theme.colorScheme.shadow.withValues(alpha: 0.4),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    initial,
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 投放悬停提示（可选图标 + 文案）。
class _HoverOverlay extends StatelessWidget {
  const _HoverOverlay({required this.child, this.icon, this.label});

  final Widget child;
  final IconData? icon;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child,
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.primary,
                width: 2,
              ),
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
            ),
            child: icon == null
                ? null
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(icon, color: theme.colorScheme.primary),
                        if (label != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            label!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// 文件夹卡（封面 + 数量角标 + 名字），同时是「拖入」的投放区。
class _FolderCell extends StatefulWidget {
  const _FolderCell({
    super.key,
    required this.folder,
    required this.coverStore,
    required this.allBooks,
    required this.onOpen,
    required this.onActions,
    this.onDropIntoFolder,
  });

  final BookFolder folder;
  final CoverStore coverStore;

  /// 全部可见书（含文件夹内）——用于按 bookId 找回封面。
  final List<BookRecord> allBooks;

  final VoidCallback? onOpen;
  final VoidCallback? onActions;
  final void Function(BookRecord dragged, String folderId)? onDropIntoFolder;

  @override
  State<_FolderCell> createState() => _FolderCellState();
}

class _FolderCellState extends State<_FolderCell> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    _loadFirstCover();
  }

  /// 加载文件夹内第一本书的封面作主图；取不到就落到占位。
  Future<void> _loadFirstCover() async {
    final List<String> ids = widget.folder.bookIds;
    if (ids.isEmpty) return;
    final int index = widget.allBooks.indexWhere(
      (BookRecord b) => b.bookId == ids.first,
    );
    if (index < 0) return;
    final CoverRef cover = widget.allBooks[index].cover;
    if (cover is! StoredCover) return;
    final Uint8List? bytes = await widget.coverStore.readThumb(cover);
    if (mounted && bytes != null) {
      setState(() => _thumb = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int count = widget.folder.bookIds.length;

    Widget content = Card(
      color: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.none,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: widget.onOpen,
        onLongPress: widget.onActions,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: theme.colorScheme.shadow.withValues(alpha: 0.28),
                          blurRadius: 10,
                          spreadRadius: 1,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _thumb != null
                          ? Ink.image(
                              image: MemoryImage(_thumb!),
                              fit: BoxFit.cover,
                            )
                          : Ink(
                              color: theme.colorScheme.secondaryContainer,
                              child: const Center(
                                child: Icon(Icons.folder, size: 40),
                              ),
                            ),
                    ),
                  ),
                  // 数量角标（照搬 anx-reader 的文件夹卡）。
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Text(
                          '$count',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.folder_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                '$count 本',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.onDropIntoFolder == null) {
      return content;
    }

    return DragTarget<BookRecord>(
      onWillAcceptWithDetails: (DragTargetDetails<BookRecord> details) => true,
      builder: (
        BuildContext context,
        List<BookRecord?> candidates,
        List<Object?> rejected,
      ) {
        if (candidates.isEmpty) return content;
        content = _HoverOverlay(
          icon: Icons.drive_file_move_outline,
          label: '移入',
          child: content,
        );
        return content;
      },
      onAcceptWithDetails: (DragTargetDetails<BookRecord> details) =>
          widget.onDropIntoFolder!(details.data, widget.folder.id),
    );
  }
}
