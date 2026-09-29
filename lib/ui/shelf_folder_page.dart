// 文件夹内页（L3）：展示某个文件夹里的书，支持移出 / 重命名 / 解散。
//
// 与书架页共用 [ShelfGrid]（同一套拖拽重排与书卡视觉），差别在于：
//   · 网格内**只有散书**（`folders: []`）——不支持嵌套文件夹；
//   · 重排结果写进 `BookFolder.bookIds`（而不是全局 `order`）；
//   · 书卡操作单多一项「移出文件夹」。
//
// 文件夹被解散 / 内部书被删空时，本页**自动 pop** 回书架（不留死页面）。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import '../settings/shelf_layout_store.dart';
import 'glass_kit.dart';
import 'shelf_grid.dart';

/// 文件夹内页。
class ShelfFolderPage extends StatefulWidget {
  /// 创建文件夹内页。
  const ShelfFolderPage({
    super.key,
    required this.folderId,
    required this.records,
    required this.coverStore,
    required this.shelfLayout,
    required this.onOpenDetail,
    required this.onOpenBook,
  });

  /// 目标文件夹 id。
  final String folderId;

  /// 全部书目（**含**文件夹内的书）；本页按 `folder.bookIds` 取顺序。
  final List<BookRecord> records;

  /// 封面存储。
  final CoverStore coverStore;

  /// 书架布局（文件夹归属 + 文件夹内顺序的唯一真值）。
  final ShelfLayoutStore shelfLayout;

  /// 点书卡 → 书籍详情页（复用书架页注入的管道）。
  final void Function(BookRecord record) onOpenDetail;

  /// 操作单「继续阅读」→ 复用书架页的开书管道。
  final void Function(BookRecord record) onOpenBook;

  @override
  State<ShelfFolderPage> createState() => _ShelfFolderPageState();
}

class _ShelfFolderPageState extends State<ShelfFolderPage> {
  @override
  void initState() {
    super.initState();
    widget.shelfLayout.addListener(_onLayoutChanged);
  }

  @override
  void dispose() {
    widget.shelfLayout.removeListener(_onLayoutChanged);
    super.dispose();
  }

  /// 布局变更 → 重绘；文件夹已消失则自动退出本页。
  void _onLayoutChanged() {
    if (!mounted) return;
    if (_folder == null) {
      // 被解散 / 书被删空 → 回书架，不停留在一个已不存在的文件夹上。
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  /// 当前文件夹；已不存在时为 `null`。
  BookFolder? get _folder {
    for (final BookFolder folder in widget.shelfLayout.layout.folders) {
      if (folder.id == widget.folderId) {
        return folder;
      }
    }
    return null;
  }

  /// 文件夹内的书（顺序 = `folder.bookIds`；索引缺失者跳过）。
  List<BookRecord> get _books {
    final BookFolder? folder = _folder;
    if (folder == null) return const <BookRecord>[];
    final Map<String, BookRecord> byId = <String, BookRecord>{
      for (final BookRecord record in widget.records) record.bookId: record,
    };
    return <BookRecord>[
      for (final String id in folder.bookIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BookFolder? folder = _folder;
    final List<BookRecord> books = _books;

    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: Text(folder?.name ?? '文件夹'),
        actions: <Widget>[
          if (folder != null)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: '文件夹操作',
              onPressed: () => unawaited(_showFolderActions(folder)),
            ),
        ],
      ),
      body: OpaqueContentSurface(
        child: DecoratedBox(
          decoration: shelfGradientBackground(theme),
          child: books.isEmpty
              ? _buildEmpty(theme)
              : ShelfGrid(
                  folders: const <BookFolder>[],
                  books: books,
                  allBooks: books,
                  coverStore: widget.coverStore,
                  openingBookId: null,
                  onOpenBook: widget.onOpenDetail,
                  onBookActions: (BookRecord record) =>
                      unawaited(_openBookActions(record)),
                  onReorder: (String draggedBookId, int toIndex) =>
                      unawaited(_reorder(draggedBookId, toIndex)),
                  // 文件夹内不再嵌套文件夹：拖到另一本书上就是纯重排。
                  // 几何与书架页同源（anx-reader 口径），防两处漂移。
                  padding: kShelfGridPadding,
                ),
        ),
      ),
    );
  }

  /// 空态：文件夹里的书都被移出 / 删除。
  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.folder_off_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '这个文件夹是空的',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文件夹内重排。
  ///
  /// [toIndex] 采用 `ReorderableListView` 的通行约定——下标以**移除前**的
  /// 列表计，向后移动时内部减一（于是「拖到某本上」= 插到那本之前）。
  Future<void> _reorder(String draggedBookId, int toIndex) async {
    final BookFolder? folder = _folder;
    if (folder == null) return;
    final List<String> ids = <String>[
      for (final BookRecord record in _books) record.bookId,
    ];
    final int from = ids.indexOf(draggedBookId);
    if (from < 0 || from == toIndex) return;
    final String moved = ids.removeAt(from);
    final int insertAt = from < toIndex ? toIndex - 1 : toIndex;
    ids.insert(insertAt.clamp(0, ids.length), moved);
    await widget.shelfLayout.setFolderOrder(folder.id, ids);
  }

  /// 长按书卡 → 操作单（多一项「移出文件夹」）。
  Future<void> _openBookActions(BookRecord record) async {
    final _FolderBookAction? action =
        await GlassOverlays.showSheet<_FolderBookAction>(
      context: context,
      builder: (BuildContext sheetContext) =>
          _FolderBookActionSheet(record: record),
    );
    if (!mounted || action == null) return;
    final BookFolder? folder = _folder;
    if (folder == null) return;

    switch (action) {
      case _FolderBookAction.continueReading:
        widget.onOpenBook(record);
      case _FolderBookAction.detail:
        widget.onOpenDetail(record);
      case _FolderBookAction.remove:
        await widget.shelfLayout.removeFromFolder(
          folder.id,
          <String>[record.bookId],
        );
    }
  }

  /// 文件夹操作单：重命名 / 解散。
  Future<void> _showFolderActions(BookFolder folder) async {
    final FolderAction? action = await GlassOverlays.showSheet<FolderAction>(
      context: context,
      builder: (BuildContext sheetContext) =>
          FolderActionSheet(folder: folder),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case FolderAction.rename:
        await _rename(folder);
      case FolderAction.dissolve:
        await _dissolve(folder);
    }
  }

  /// 重命名。
  Future<void> _rename(BookFolder folder) async {
    final String? name = await askFolderName(context, folder);
    if (name == null) return;
    await widget.shelfLayout.renameFolder(folder.id, name);
  }

  /// 解散（二次确认；书回到书架）。
  Future<void> _dissolve(BookFolder folder) async {
    if (!await confirmDissolveFolder(context, folder)) return;
    await widget.shelfLayout.dissolveFolder(folder.id);
  }
}

/// 询问文件夹新名字（玻璃确认框 + 文本框）。
///
/// 取消 / 关闭返回 `null`；空白名由 `ShelfLayoutStore.renameFolder` 自行拒绝。
/// 书架页与文件夹内页**共用**本函数，勿各写一份。
Future<String?> askFolderName(BuildContext context, BookFolder folder) async {
  final TextEditingController controller =
      TextEditingController(text: folder.name);
  try {
    return await GlassOverlays.showAlert<String>(
      context: context,
      title: '重命名文件夹',
      barrierDismissible: true,
      maxWidth: 320,
      // 玻璃浮层没有 Material 祖先（PRD §11.4），`TextField` 需要一层；
      // `MaterialType.transparency` 不画底色，不破坏玻璃观感。
      content: Material(
        type: MaterialType.transparency,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '文件夹名称'),
          onSubmitted: (String value) =>
              Navigator.of(context).pop<String>(value),
        ),
      ),
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.of(context).pop<String>(),
        ),
        GlassDialogAction(
          label: '确定',
          isPrimary: true,
          onPressed: () => Navigator.of(context).pop<String>(controller.text),
        ),
      ],
    );
  } finally {
    controller.dispose();
  }
}

/// 二次确认「解散文件夹」（书回到书架，不删文件）。确认返回 `true`。
Future<bool> confirmDissolveFolder(
  BuildContext context,
  BookFolder folder,
) async {
  final bool? confirmed = await GlassOverlays.showAlert<bool>(
    context: context,
    title: '解散文件夹',
    message: '「${folder.name}」里的 ${folder.bookIds.length} 本书会回到书架，'
        '文件不会被删除。',
    barrierDismissible: true,
    actions: <GlassDialogAction>[
      GlassDialogAction(
        label: '取消',
        onPressed: () => Navigator.of(context).pop<bool>(false),
      ),
      GlassDialogAction(
        label: '解散',
        isDestructive: true,
        onPressed: () => Navigator.of(context).pop<bool>(true),
      ),
    ],
  );
  return confirmed == true;
}

/// 文件夹内书卡可选的拖拽外动作。
enum _FolderBookAction {
  /// 继续阅读。
  continueReading,

  /// 书籍详情。
  detail,

  /// 移出文件夹（书回到书架的散书区，**不删文件**）。
  remove,
}

/// 文件夹内书卡的操作单。
///
/// 由 [GlassOverlays.showSheet] 承载；`MaterialType.transparency` 是玻璃浮层里
/// 用 `ListTile` 的必要条件（浮层无 Material 祖先，PRD §11.4）。
class _FolderBookActionSheet extends StatelessWidget {
  const _FolderBookActionSheet({required this.record});

  final BookRecord record;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String subtitle = <String>[
      if (record.author.isNotEmpty) record.author,
      record.format.toUpperCase(),
    ].join(' · ');

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    record.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('继续阅读'),
              onTap: () =>
                  Navigator.of(context).pop(_FolderBookAction.continueReading),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('书籍详情'),
              onTap: () => Navigator.of(context).pop(_FolderBookAction.detail),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移出文件夹'),
              subtitle: const Text('书会回到书架，文件不会被删除'),
              onTap: () => Navigator.of(context).pop(_FolderBookAction.remove),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 文件夹自身的操作（书架页与文件夹内页共用）。
enum FolderAction {
  /// 重命名。
  rename,

  /// 解散（书回到书架）。
  dissolve,
}

/// 文件夹操作单。
class FolderActionSheet extends StatelessWidget {
  /// 创建操作单。
  const FolderActionSheet({super.key, required this.folder});

  /// 目标文件夹。
  final BookFolder folder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                '${folder.name} · ${folder.bookIds.length} 本',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.of(context).pop(FolderAction.rename),
            ),
            ListTile(
              leading:
                  Icon(Icons.folder_off_outlined, color: theme.colorScheme.error),
              title: Text(
                '解散文件夹',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text('书会回到书架，文件不会被删除'),
              onTap: () => Navigator.of(context).pop(FolderAction.dissolve),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
