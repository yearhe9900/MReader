// `LIB-01`：书架首页（替代 M0 验证台的 `HomePage`）。
//
// 空态：引导文案 + 导入按钮。
// 有书：分组筛选栏（全部 + 各分组）+ 网格展示 [BookCard]
//（封面缩略图 + 书名 + 作者 + 格式标签）。
// 导入：`FilePicker` 多选 → 逐个调 `importFile`，展示进度 + 失败清单。
// 删除：长按书卡 → 操作单 → 确认对话框 → `deleteBook`（`LIB-06` 二次确认）
// + 连带清理阅读进度。
// 点击书卡 → 进入书籍详情页（`F9` / `META-08`）；详情页底部「继续阅读」经**注入的**
// `_openBook` 开书（详情页**不复制**开书管道），详情页 pop 后刷新列表
// （编辑 / 移出 / 分组 / 进度都靠这次刷新同步）。
// 开书守卫 `_opening` **只覆盖 push 前的准备阶段**（修复「首点无响应」：守卫若覆盖
// 整个阅读会话 + 关书刷新，关书后首点会被静默吞掉）；准备期被点卡片显示 loading。
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-09-29 拍板：筛选项由「阅读状态」改为「分组」、移除拖拽归类
// ══════════════════════════════════════════════════════════════════════════════
// · 顶部 chips = **全部 + 各分组名**（分组来自 `ShelfLayoutStore`，顺序即创建序；
//   只列「真有书」的分组——空分组由 `prune` 清掉）；
// · 选中分组 → 网格只显示该分组的书；默认「全部」；再点已选中的 chip 回「全部」；
// · 归类入口 = **书籍详情页的「分组」行**（需求 `P2-02`）。书架不再有拖拽
//   （建文件夹 / 移入 / 重排全部移除）、不再有文件夹卡与文件夹内页
//   （`shelf_folder_page.dart` 已删）；
// · 一本书**只属一个分组**（`ShelfLayoutStore` 保证归属唯一），未分组的书在
//   「全部」里正常展示，也在其他分组筛选下不可见（那是分组语义的必然）。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider）。
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/perf_log.dart';
import '../format/book_registry.dart';
import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../meta/cover_store.dart';
import '../reader/progress_store.dart';
import '../reader/reader_page.dart';
import '../settings/shelf_layout_store.dart';
import '../settings/shelf_prefs_store.dart';
import 'book_detail_page.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'library_search_page.dart';
import 'shelf_grid.dart';

/// 书架首页。
class ShelfPage extends StatefulWidget {
  const ShelfPage({
    super.key,
    required this.repository,
    required this.coverStore,
    required this.progressStore,
    required this.shelfPrefs,
    required this.shelfLayout,
  });

  /// 书库仓库。
  final LibraryRepository repository;

  /// 封面存储（传给 [BookCard] 加载缩略图）。
  final CoverStore coverStore;

  /// 阅读进度存储（`RD-04`）：传给阅读页；删书时连带清理。
  final ProgressStore progressStore;

  /// 书架视图偏好（分组筛选 + 排序），进程内共享实例。
  final ShelfPrefsStore shelfPrefs;

  /// 书架布局（手动顺序 + 分组归属），进程内共享实例。
  final ShelfLayoutStore shelfLayout;

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  List<BookRecord> _books = <BookRecord>[];
  bool _loading = true;
  bool _importing = false;
  List<String> _importErrors = <String>[];

  /// 防重复开书：**只覆盖 push 前的准备阶段**（readBookBytes + openBook）。
  /// 路由一入栈立即释放——阅读会话期间绝不占用（否则关书后首点被静默吞掉，
  /// 表现为「首点无响应、必须再点一次」）。
  bool _opening = false;

  /// 正在准备打开的书（bookId）：对应卡片显示 loading 覆盖层；`null` = 无。
  String? _openingBookId;

  /// 详情页路由在栈上（push 已发起、尚未 pop）：吞掉过渡期 / 会话期的重复点卡，
  /// 防「双击卡片 → 叠两个详情页」。pop 后由 [_openDetail] 的 `finally` 释放。
  bool _detailPushing = false;

  @override
  void initState() {
    super.initState();
    // 筛选 / 排序偏好与书架布局（手动顺序 + 文件夹）一变即重绘
    // （两者都是进程内共享实例，见 [ShelfPrefsStore] / [ShelfLayoutStore]）。
    widget.shelfPrefs.addListener(_onStoreChanged);
    widget.shelfLayout.addListener(_onStoreChanged);
    _loadBooks();
  }

  @override
  void dispose() {
    widget.shelfPrefs.removeListener(_onStoreChanged);
    widget.shelfLayout.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// 共享存储变更 → 重绘。
  void _onStoreChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 应用「分组筛选 + 排序」后的可见书目。
  ///
  /// 在渲染期计算（而非加载时缓存）：偏好一变立刻生效；书架是本地量级
  /// （几百本），每次 build 重排的成本可忽略。
  List<BookRecord> get _visibleBooks {
    final ShelfPrefs prefs = widget.shelfPrefs.prefs;
    Iterable<BookRecord> list = _books;

    // 分组筛选（`null` = 全部）。
    //
    // 选中的分组**已不存在**时按「全部」处理：删掉某分组最后一本书后，`prune`
    // 会清掉这个空分组，而 `ShelfPrefs.groupId` 仍指着它——不做回落的话书架
    // 会永久显示「没有符合当前筛选的书」，用户找不到恢复入口。
    final String? selected = prefs.groupId;
    final BookGroup? group =
        selected == null ? null : widget.shelfLayout.layout.groupById(selected);
    if (group != null) {
      final Set<String> members = group.bookIds.toSet();
      list = list.where((BookRecord b) => members.contains(b.bookId));
    }

    final List<BookRecord> sorted = list.toList();

    // 手动顺序单独一条路径：顺序**就是** `order` 本身，不受升降序开关影响
    // （否则「再点同项翻转方向」会把顺序打乱）。`order` 由过去的拖拽重排写入；
    // 2026-09-29 拖拽重排已删（对齐 anx），此分支仅消费旧数据 + 排序菜单入口。
    if (prefs.sortField == ShelfSortField.manual) {
      final List<String> order = widget.shelfLayout.layout.order;
      final Map<String, int> rank = <String, int>{
        for (int i = 0; i < order.length; i++) order[i]: i,
      };
      sorted.sort((BookRecord a, BookRecord b) {
        final int ra = rank[a.bookId] ?? -1;
        final int rb = rank[b.bookId] ?? -1;
        if (ra >= 0 && rb >= 0) return ra.compareTo(rb);
        if (ra >= 0) return -1; // 有显式位置者在前
        if (rb >= 0) return 1;
        // 都没拖拽过（新导入的书）→ 按导入时间降序追加在后。
        return -b.importedAt.compareTo(a.importedAt);
      });
      return sorted;
    }

    sorted.sort((BookRecord a, BookRecord b) {
      final int cmp = switch (prefs.sortField) {
        ShelfSortField.importedAt => a.importedAt.compareTo(b.importedAt),
        ShelfSortField.lastReadAt =>
          _nullableIntCompare(a.lastReadAt, b.lastReadAt),
        ShelfSortField.title => a.title.compareTo(b.title),
        ShelfSortField.author => a.author.compareTo(b.author),
        // 手动顺序已在上方单独返回（此分支不可达，仅为穷尽 switch）。
        ShelfSortField.manual => 0,
      };
      // 缺省降序 = 「新的 / 靠后的在前」。
      return prefs.sortAscending ? cmp : -cmp;
    });
    return sorted;
  }

  /// `null` 视为最小值——降序（默认）时自然落到末尾（「从未读过」排最后）。
  static int _nullableIntCompare(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return a.compareTo(b);
  }

  /// 排序字段的中文名。
  static String _sortLabel(ShelfSortField field) => switch (field) {
        ShelfSortField.importedAt => '导入时间',
        ShelfSortField.lastReadAt => '最近阅读',
        ShelfSortField.title => '书名',
        ShelfSortField.author => '作者',
        ShelfSortField.manual => '手动排序',
      };

  Future<void> _loadBooks() async {
    final List<BookRecord> books = await widget.repository.loadBooks();
    if (mounted) {
      setState(() {
        _books = books;
        _loading = false;
      });
    }
    // 顺手清掉已删书籍在布局里留下的孤儿引用（无变化则不写盘）。
    await widget.shelfLayout.prune(
      books.map((BookRecord b) => b.bookId).toSet(),
    );
  }

  Future<void> _pickAndImport() async {
    setState(() {
      _importErrors = <String>[];
    });

    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['epub', 'txt'],
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    if (!mounted) return;
    setState(() => _importing = true);

    int success = 0;
    final List<String> errors = <String>[];
    for (final PlatformFile file in result.files) {
      final Uint8List? bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        errors.add('${file.name}：未能读取文件内容');
        continue;
      }
      try {
        final ImportResult importResult = await widget.repository.importFile(
          bytes: bytes,
          fileName: file.name,
        );
        if (importResult.isNew) {
          success++;
        } else {
          errors.add('${file.name}：已存在（${importResult.record.title}）');
        }
      } catch (e) {
        errors.add('${file.name}：$e');
      }
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _importErrors = errors;
    });

    // 刷新列表
    await _loadBooks();

    // 显示导入结果摘要
    if (mounted && (success > 0 || errors.isNotEmpty)) {
      final String msg = errors.isEmpty
          ? '成功导入 $success 本'
          : '成功 $success 本，失败 ${errors.length} 本';
      // 轻提示走 Overlay（`GlassOverlays.showToast`）：壳层无 Material `Scaffold`，
      // `ScaffoldMessenger.showSnackBar` 会断言失败。
      GlassOverlays.showToast(
        context: context,
        message: msg,
        type: errors.isEmpty ? GlassToastType.success : GlassToastType.warning,
        duration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _deleteBook(BookRecord record) async {
    // `UI-03` 浮层玻璃：玻璃确认框（`M2a-T04`）。barrier 可关（返回 null = 取消），
    // 语义与原 `showDialog<bool>` 一致：非 `true` 一律不删。
    final bool? confirmed = await GlassOverlays.showAlert<bool>(
      context: context,
      title: '删除确认',
      message: '确定删除「${record.title}」？\n删除后书架不再列出，封面文件一并清理。',
      barrierDismissible: true,
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(context, false),
        ),
        GlassDialogAction(
          label: '删除',
          isDestructive: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed == true) {
      await widget.repository.deleteBook(record);
      // `LIB-06` 连带清理：删除该书阅读进度文件（缺失时静默成功）。
      await widget.progressStore.remove(record.bookId);
      await _loadBooks();
    }
  }

  /// 长按书卡 → 底部操作单（照搬 anx-reader 的 `BookBottomSheet`）。
  ///
  /// 长按**不再**直接弹删除确认：删除是破坏性动作，收进操作单并要求二次确认
  /// （`LIB-06`），缩短「误触即删」的路径。
  Future<void> _openBookActions(BookRecord record) async {
    final _BookAction? action = await GlassOverlays.showSheet<_BookAction>(
      context: context,
      builder: (BuildContext sheetContext) => _BookActionSheet(record: record),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _BookAction.continueReading:
        await _openBook(record);
      case _BookAction.detail:
        await _openDetail(record);
      case _BookAction.delete:
        await _deleteBook(record);
    }
  }

  /// 点书卡 → 书籍详情页（`F9` / `META-08 ①`）。
  ///
  /// pop 后刷新列表——编辑 / 移出书架 / 进度变化都靠这次刷新同步回书架。
  /// 开书管道以 `onOpenBook: _openBook` 回调注入详情页（详情页禁止复制第二份）。
  Future<void> _openDetail(BookRecord record) async {
    if (_detailPushing) return; // 过渡期防双击叠详情页
    _detailPushing = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BookDetailPage(
            record: record,
            repository: widget.repository,
            coverStore: widget.coverStore,
            progressStore: widget.progressStore,
            // 详情页「分组」行（`P2-02`）改的是书架布局，故注入同一个共享实例。
            shelfLayout: widget.shelfLayout,
            onOpenBook: _openBook,
          ),
        ),
      );
    } finally {
      _detailPushing = false;
    }
    // 详情页已关闭：刷新（编辑 / 移出 / 进度都在这里同步）。
    if (mounted) unawaited(_loadBooks());
  }

  /// 打开一本书：准备（读字节 + 建源）→ push 阅读页。
  ///
  /// 守卫 [_opening] **只覆盖 push 前的准备阶段**（防准备期连点重复 push）；
  /// 路由一入栈立即释放——阅读会话期间绝不占用，否则关书后首点被静默吞掉。
  /// 准备期被点的卡片显示 loading 覆盖层（[BookCard.loading]）。
  Future<void> _openBook(BookRecord record) async {
    if (_opening) return; // 准备期防双击重复开书
    _opening = true;
    setState(() => _openingBookId = record.bookId); // 该卡显示 loading 覆盖层
    try {
      final PerfWatch readWatch = PerfLog.watch('open.readBytes');
      final Uint8List? bytes = await widget.repository.readBookBytes(record);
      readWatch.done(
          'book=${record.title} sizeKB=${(bytes?.length ?? 0) ~/ 1024}');
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件已丢失：${record.fileName}')),
          );
        }
        return;
      }

      final PerfWatch sniffWatch = PerfLog.watch('open.sniff');
      final BookSource source = await openBook(
        fileName: record.fileName,
        bytes: bytes,
      );
      sniffWatch.done('impl=${source.implId}');
      // 不在导航前 eager 解析：全量 load() 在主 isolate 同步执行会冻结 UI，
      // 导致首击「无响应」、用户补点第二次（PERF）。解析与 loading 交给
      // ReaderPage._open() 承担（其自带 spinner + 错误态，RD-05 仍满足）。

      if (!mounted) return;
      final MaterialPageRoute<void> route = MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          source: source,
          record: record,
          progressStore: widget.progressStore,
          repository: widget.repository,
        ),
      );
      // 不 await push 的 Future（它要等路由 pop 才返回）——push 一发起（路由已
      // 入栈）就往下走，finally 立即释放守卫。关书刷新走 route.popped，不占守卫。
      unawaited(Navigator.of(context).push(route));
      unawaited(route.popped.then((_) {
        // 阅读页关闭后刷新（lastReadAt / readProgress 已在 M1-T04 更新）。
        if (mounted) unawaited(_loadBooks());
      }));
    } finally {
      _opening = false;
      if (mounted) setState(() => _openingBookId = null);
    }
  }

  /// 顶栏假搜索框 → 书库搜索页；选中结果直接进详情页。
  ///
  /// 搜索做成**独立页面**（而非就地输入）：查询与书架状态解耦，
  /// 也不必在当前子树里处理键盘遮挡。与 anx-reader 的做法一致。
  Future<void> _openSearch() async {
    final BookRecord? picked = await Navigator.of(context).push<BookRecord>(
      MaterialPageRoute<BookRecord>(
        builder: (_) => LibrarySearchPage(books: _books),
      ),
    );
    if (picked != null && mounted) {
      await _openDetail(picked);
    }
  }

  // 拖拽 / 文件夹相关的方法（`_mergeIntoFolder` / `_dropIntoFolder` /
  // `_openFolder` / `_folderActions` / `_folderById` / `_toast`）已随
  // 2026-09-29 拍板整体移除：归类改走详情页「分组」行，书架不再有拖拽与
  // 文件夹卡（本页仅剩导入结果一处轻提示，直接调 `GlassOverlays.showToast`）。

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // `UI-02` 导航层玻璃化：顶栏走 GlassTopBar、壳层走 GlassNavScaffold
    // （照抄 book_detail_page 范本）；内容整体不透明（`UI-04`）。
    if (_loading) {
      return GlassNavScaffold(
        appBar: const GlassTopBar(title: Text('书架')),
        body: const OpaqueContentSurface(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return GlassNavScaffold(
      appBar: GlassTopBar(
        // 标题位放「假搜索框」——外观是搜索框，点击进搜索页（照搬 anx-reader）。
        title: _BookSearchEntry(onTap: _openSearch),
        // **靠左不居中**：库的 `_ToolbarLayout` 在 `centerTitle: true`（默认）时
        // 按整条宽度居中，并把可用宽压成 `size.width - 2 * max(leading, actions)`
        // （等边距口径，`glass_app_bar.dart:559-578`）——本页右侧有两个动作按钮，
        // 搜索框会被压到约半宽、浮在中间。传 `false` 走 `:579-611`：从 leading 侧
        // 起排（本页无 leading → 贴顶栏内边距），可用宽 = 整宽减去两侧与 8px 间距。
        centerTitle: false,
        actions: <Widget>[
          if (_importing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '导入书籍',
              onPressed: _pickAndImport,
            ),
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            onPressed: _showSortMenu,
          ),
        ],
      ),
      body: OpaqueContentSurface(
        child: DecoratedBox(
          decoration: shelfGradientBackground(theme),
          child: _books.isEmpty
              ? _buildEmptyState(theme)
              : Column(
                  children: <Widget>[
                    _buildGroupFilterBar(),
                    Expanded(
                      // 有书、但当前分组里一本都没有（如刚把书都移出了该分组）。
                      child: _visibleBooks.isEmpty
                          ? _buildNoMatchState(theme)
                          : _buildBookGrid(),
                    ),
                    if (_importErrors.isNotEmpty) _buildErrorList(theme),
                  ],
                ),
        ),
      ),
    );
  }

  /// 分组筛选栏（**单选**：全部 / 各分组）。
  ///
  /// 高 40、横向可滚——分组数量由用户决定，窄屏必然放不下，直接给滚动容器。
  /// 「全部」恒在首位；分组顺序 = `ShelfLayoutStore` 的创建序（`groups` 列表序）。
  /// 只列**真有书**的分组：空分组已由 `prune` 清掉，故此处无需再过滤。
  Widget _buildGroupFilterBar() {
    final String? selected = widget.shelfPrefs.prefs.groupId;
    // 选中分组已消失（书被删空）→ 视作「全部」，chip 高亮随之回到「全部」。
    final bool hasSelection = selected != null &&
        widget.shelfLayout.layout.groupById(selected) != null;
    return SizedBox(
      height: 40,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  _buildGroupChip(
                    label: '全部',
                    groupId: null,
                    selected: !hasSelection,
                  ),
                  for (final BookGroup group
                      in widget.shelfLayout.layout.groups)
                    _buildGroupChip(
                      label: group.name,
                      groupId: group.id,
                      selected: hasSelection && selected == group.id,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// 单个分组 chip（**单选**）：选中即筛选，再点**已选中**的回「全部」。
  Widget _buildGroupChip({
    required String label,
    required String? groupId,
    required bool selected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => unawaited(
          widget.shelfPrefs.setGroup(selected ? null : groupId),
        ),
      ),
    );
  }

  /// 排序菜单（右上角弹出；当前字段右侧显示方向箭头，再点同项即翻转方向）。
  Future<void> _showSortMenu() async {
    final ThemeData theme = Theme.of(context);
    final ShelfPrefs prefs = widget.shelfPrefs.prefs;
    final Size screen = MediaQuery.of(context).size;
    final double top = MediaQuery.of(context).padding.top + kToolbarHeight;

    final ShelfSortField? picked = await showMenu<ShelfSortField>(
      context: context,
      // 锚在右上角下方——与顶栏的排序按钮相邻（照搬 anx-reader 的定位方式）。
      position: RelativeRect.fromLTRB(screen.width, top, 0, 0),
      items: <PopupMenuEntry<ShelfSortField>>[
        for (final ShelfSortField field in ShelfSortField.values)
          PopupMenuItem<ShelfSortField>(
            value: field,
            child: Row(
              children: <Widget>[
                if (prefs.sortField == field)
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_sortLabel(field))),
                if (prefs.sortField == field)
                  Icon(
                    prefs.sortAscending
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
      ],
    );
    if (picked == null) return;
    // 同字段再次选中 → `setSortField` 内部翻转方向。
    await widget.shelfPrefs.setSortField(picked);
  }

  /// 当前分组里一本都没有时的空态（区别于「书架里一本书都没有」）。
  Widget _buildNoMatchState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.filter_alt_off_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '这个分组里没有书',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => unawaited(widget.shelfPrefs.setGroup(null)),
              child: const Text('查看全部'),
            ),
          ],
        ),
      ),
    );
  }

  /// 空态（LIB-01 验收要点 ②）。
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.menu_book_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              '书架空空如也',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '导入 EPUB / TXT 文件开始阅读',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickAndImport,
              icon: const Icon(Icons.folder_open),
              label: const Text('导入书籍'),
            ),
            if (_importErrors.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _buildErrorList(theme),
            ],
          ],
        ),
      ),
    );
  }

  /// 有书：网格展示（分组筛选 / 排序已在外层应用）。
  ///
  /// 网格**不再含任何交互**（拖拽 / 文件夹卡随 2026-09-29 拍板移除），
  /// 本页只把「点击进详情」「长按弹操作单」两个回调接上。
  Widget _buildBookGrid() {
    return ShelfGrid(
      books: _visibleBooks,
      coverStore: widget.coverStore,
      openingBookId: _openingBookId,
      onOpenBook: (BookRecord record) => unawaited(_openDetail(record)),
      onBookActions: (BookRecord record) => unawaited(_openBookActions(record)),
    );
  }

  /// 导入失败清单（LIB-04 验收要点 ②）。
  ///
  /// 贴在网格下方，因此也要为壳层浮动胶囊留出底部空白（[kShellBottomInset]），
  /// 否则清单末行会被胶囊盖住。
  Widget _buildErrorList(ThemeData theme) {
    return Container(
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8 + kShellBottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '导入失败 ${_importErrors.length} 项',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          ..._importErrors.map((String e) => Text(
                e,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              )),
        ],
      ),
    );
  }
}

/// 顶栏里的「假搜索框」——外观是搜索框，点击进搜索页（照搬 anx-reader）。
///
/// 为什么不做成可就地输入：搜索是**独立页面**（[LibrarySearchPage]），
/// 顶栏只做入口。就地输入会把查询状态绑进书架子树，还要在当前布局里
/// 处理键盘遮挡与结果覆盖层，收益不抵复杂度。
///
/// **靠左铺满而非居中收缩**：调用方须传 `centerTitle: false`（见 `build`）。
/// 居中档下库会把可用宽压成 `width - 2 * max(两侧)`，右侧两个动作按钮一占，
/// 搜索框就只剩半宽且浮在中间——「看起来是个居中的小胶囊」，不是搜索框该有的样子。
class _BookSearchEntry extends StatelessWidget {
  const _BookSearchEntry({required this.onTap});

  /// 点击回调（打开搜索页）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 搜索框圆角（比高度 36 的一半 18 大也只会被裁到 18，直接写 18 免歧义）。
    const double radius = 18;
    return ConstrainedBox(
      // 宽屏（桌面）不让搜索框无限拉伸，上限 400。
      // 窄屏由外层（`_ToolbarLayout` 靠左档 / `AppBar`）给的 `maxWidth` 收口。
      constraints: const BoxConstraints(maxWidth: 400),
      child: SizedBox(
        // 撑满「可用宽 ∩ 400」——没有它，`InkWell` 只按内容宽收缩（又是居中即视感）。
        width: double.infinity,
        // 玻璃库无 Material 祖先（PRD §11.4），而 `InkWell` 的水波纹由最近的
        // Material 绘制，故需自带一层。`MaterialType.transparency` 不绘制底色，
        // 不破坏玻璃观感。
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            child: Container(
              // 供契约测试定位（`test/ui/shelf_page_test.dart` 断言「靠左铺满 +
              // 自带描边/底色」）。
              key: const Key('shelf-search-entry'),
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                // 顶栏是**半透明玻璃**：沿用原先 0.6 透明度的填充会「糊」进背后的
                // 渐变里，看不出这是一块可点的控件 → 提高填充不透明度并加一道描边，
                // 把搜索框从玻璃条面上分离出来。
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.search,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '搜索书名、作者',
                      overflow: TextOverflow.ellipsis,
                      // 仍是**占位符**口径（比正文弱一档），不因加边框提成正文色。
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 书卡长按后可选的动作。
enum _BookAction {
  /// 继续阅读（复用书架页的开书管道，不另建）。
  continueReading,

  /// 进书籍详情页。
  detail,

  /// 移出书架并删除文件（仍需二次确认，`LIB-06`）。
  delete,
}

/// 长按书卡弹出的底部操作单。
///
/// 由 [GlassOverlays.showSheet] 承载（`UI-03` 浮层玻璃；「关」档自动退化为
/// Material 底部弹窗）。本组件内**不得**再出现玻璃控件（玻璃不可嵌套），
/// 故清一色由不透明内容构成。
class _BookActionSheet extends StatelessWidget {
  const _BookActionSheet({required this.record});

  /// 目标书目。
  final BookRecord record;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? progress = record.readProgress;
    final String subtitle = <String>[
      if (record.author.isNotEmpty) record.author,
      record.format.toUpperCase(),
      if (progress != null) '已读 ${(progress * 100).round()}%',
    ].join(' · ');

    return Material(
      // 玻璃浮层（`GlassSheet`）**没有 Material 祖先**（PRD §11.4），而 `ListTile`
      // 强制要求最近处存在 Material（涟漪与文字样式）——缺了就抛
      // 「No Material widget found」。透明 Material 不绘制底色，不破坏玻璃观感。
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
                  Navigator.of(context).pop(_BookAction.continueReading),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('书籍详情'),
              onTap: () => Navigator.of(context).pop(_BookAction.detail),
            ),
            ListTile(
              leading:
                  Icon(Icons.delete_outline, color: theme.colorScheme.error),
              title: Text(
                '移出书架',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text('删除后封面文件一并清理'),
              onTap: () => Navigator.of(context).pop(_BookAction.delete),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
