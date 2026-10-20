// `LIB-01`：书架首页（替代 M0 验证台的 `HomePage`）。
//
// 空态：引导文案 + 导入按钮。
// 有书：浮动头部（全宽玻璃搜索胶囊 + 分组 chips，2026-09-29 参考图批）+
// 网格展示 [BookCard]（封面缩略图 + 书名 + 作者 + 格式标签）；
// 内容 edge-to-edge（`extendBody: true`）从头部下穿过、透出磨砂模糊（`UI-02` ②）。
// 导入：`FilePicker` 多选 → 逐个调 `importFile`，展示进度 + 失败清单。
// 删除：长按书卡 → 操作单 → 确认对话框 → `deleteBook`（`LIB-06` 二次确认）
// + 连带清理阅读进度。
// 点击书卡 = **直接进阅读页**（2026-09-29 v2.9 改道，与 anx-reader 一致）；
// 长按操作单「书籍详情」是详情页**唯一**入口（`META-08`）。详情页底部
// 「继续阅读」经**注入的** `_openBook` 开书（详情页**不复制**开书管道），
// 详情页 pop 后刷新列表（编辑 / 移出 / 分组 / 进度都靠这次刷新同步）。
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
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_client.dart';
import '../ai/provider_store.dart';
import '../ai/rag.dart';
import '../ai/summary_cache.dart';
import '../ai/vocab_store.dart';
import '../diagnostics/open_trace.dart';
import '../diagnostics/perf_log.dart';
import '../format/book_registry.dart';
import '../format/book_source.dart';
import '../format/structure_cache.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../meta/cover_store.dart';
import '../reader/bookmark_store.dart';
import '../reader/progress_store.dart';
import '../reader/reader_open_transition.dart';
import '../reader/reader_page.dart';
import '../reader/reading_prefs_store.dart';
import '../settings/shelf_layout_store.dart';
import '../settings/shelf_prefs_store.dart';
import '../stats/stats_service.dart';
import '../sync/sync_trigger.dart';
import '../tts/online_tts.dart';
import '../tts/tts_settings.dart';
import 'adaptive_pill_tab_bar.dart';
import 'book_card.dart';
import 'book_detail_page.dart';
import 'glass_kit.dart';
import 'glass_nav_host.dart' show navThemeModeOf;
import 'home_shell.dart' show kShellBottomInset;
import 'mi_like_ui/mi_like_ui.dart'
    show
        MiPillTabMetrics,
        MiSearchBar,
        MiSearchCancelButton,
        MiSearchCancelMetrics,
        MiThemeMode,
        MiTopBarMetrics,
        MiTopBarPalette;
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
    this.statsService,
    this.aiStore,
    this.aiClient,
    this.vocabStore,
    this.summaryCache,
    this.ragStore,
    this.ttsSettings,
    this.onlineTts,
    this.bookmarkStore,
    this.readingPrefsStore,
    this.syncTrigger,
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

  /// 统计服务（`STAT-01` 采集落库；`M3-T10b`），透传给阅读页。
  ///
  /// `null` = 尚未接线：阅读页不采集（与其它可选注入同款降级口径）。
  final StatsService? statsService;

  /// AI 配置 / 客户端 / 生词本（划词翻译释义，`AI-02`/`AI-03`），透传阅读页。
  ///
  /// 三者任一为 null → 阅读页划词整体禁用（与 [statsService] 同款降级口径）。
  final ProviderStore? aiStore;
  final AiClient? aiClient;
  final VocabStore? vocabStore;

  /// 摘要缓存（阅读页 `AI-04`/`AI-05`，`M3-T03`）；删书时连带清理。
  ///
  /// `null` = 未接线：阅读页摘要入口隐藏（同款降级口径）。
  final SummaryCache? summaryCache;

  /// 问答索引存储（阅读页 `AI-06`，`M3-T04`）；删书时连带清理。
  ///
  /// `null` = 未接线：阅读页问答入口隐藏（同款降级口径）。
  final RagIndexStore? ragStore;

  /// 朗读设置存储（阅读页 `TTS-04`/`TTS-05`；`M3-T08`），透传阅读页。
  ///
  /// `null` = 未接线：阅读页朗读设置入口隐藏（同款降级口径）。
  final TtsSettingsStore? ttsSettings;

  /// 在线 TTS 配置存储（透传阅读页，`TTS-07`；`M3-T09`）。
  ///
  /// `null` = 未接线：面板引擎选择区隐藏、只用系统引擎（同款降级口径）。
  final OnlineTtsStore? onlineTts;

  /// 书签存储（透传阅读页；`M4-T05` 接上生产链路）。
  final BookmarkStore? bookmarkStore;

  /// 阅读偏好存储（透传阅读页；同 [bookmarkStore]）。
  final ReadingPrefsStore? readingPrefsStore;

  /// 同步触发器（透传阅读页：退出阅读页上报进度，`SYNC-06`）。
  final SyncTrigger? syncTrigger;

  @override
  State<ShelfPage> createState() => ShelfPageState();
}

/// [ShelfPage] 的状态类（公开：`HomeShell` 经 [GlobalKey] 把底栏绿圆钮的
/// 「导入书籍」动作接到 [pickAndImport]，2026-10-16 功能迁移批）。
class ShelfPageState extends State<ShelfPage> {
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

  // ── 就地搜索态（2026-10-20 上游搜索栏批）────────────────────────────────
  //
  // 原实现是 push 独立搜索页（`LibrarySearchPage`）：查询与书架状态解耦、
  // 不必在当前子树处理键盘遮挡。改成上游形态的**就地搜索态**后，这两点由
  // 「胶囊行收起 + 结果替换网格」承担——本页只过滤元数据（纯内存、零 IO），
  // 边输入边出结果，比跳页少一次路由与一次列表重建。

  /// 是否处于搜索态（点搜索栏进入，点取消钮退出）。
  bool _searching = false;

  /// 当前查询串（已 trim、已转小写）。
  String _query = '';

  /// 搜索输入控制器 / 焦点：由页面持有，退出搜索态时能主动 `unfocus` 收键盘。
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 搜索态转场时长（上游录屏逐帧实测 480ms：起手静止 48ms + 位移 430ms）。
  static const Duration _searchTransition =
      Duration(milliseconds: MiTopBarMetrics.searchTransitionMs);

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
    _searchController.dispose();
    _searchFocus.dispose();
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

  /// 导入书籍入口（`FilePicker` 多选 → 逐个 `importFile`）。
  ///
  /// 2026-10-16 起由底栏**绿圆钮**触发（`HomeShell` 经 GlobalKey 调本方法，
  /// 原顶部加号按钮已移除）；空态引导按钮仍调本方法（`LIB-01` ②）。
  Future<void> pickAndImport() async {
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
      // `M3-T03` 连带清理：该书的章级 / 合并级摘要缓存。
      await widget.summaryCache?.removeBook(record.bookId);
      // `M3-T04` 连带清理：该书的问答索引（内存 + 磁盘分文件）。
      await widget.ragStore?.removeBook(record.bookId);
      await _loadBooks();
    }
  }

  /// 长按书卡 → 底部操作单（照搬 anx-reader 的 `BookBottomSheet`）。
  ///
  /// 长按**不再**直接弹删除确认：删除是破坏性动作，收进操作单并要求二次确认
  /// （`LIB-06`），缩短「误触即删」的路径。
  ///
  /// **返回值语义（2026-09-29）**：本 Future 在**操作单关闭时即完成**，不等
  /// 选定的动作走完——书卡用它当长按抬起反馈的复位时机（`BookCard.onLongPress`
  /// 是异步回调）。动作改由 [_runBookAction] 接管（`unawaited`），
  /// 以免「点继续阅读 → 卡片一路悬着直到从阅读页返回」。
  Future<void> _showBookActions(BookRecord record) async {
    final _BookAction? action = await GlassOverlays.showSheet<_BookAction>(
      context: context,
      builder: (BuildContext sheetContext) => _BookActionSheet(record: record),
    );
    if (!mounted || action == null) return;
    unawaited(_runBookAction(record, action));
  }

  /// 操作单选定后的动作派发（[BookCard.onLongPress] 已随操作单关闭而复位，
  /// 故这里不再占用「抬起」窗口）。
  Future<void> _runBookAction(BookRecord record, _BookAction action) async {
    switch (action) {
      case _BookAction.continueReading:
        await _openBook(record);
      case _BookAction.detail:
        await _openDetail(record);
      case _BookAction.delete:
        await _deleteBook(record);
    }
  }

  /// 书卡长按操作单 / 详情页的「书籍详情」→ 书籍详情页（`F9` / `META-08 ①`）。
  ///
  /// **入口只有一个**（2026-09-29 改道）：书架点卡改成直接进阅读页后，
  /// 详情页只能从长按操作单进（与 anx-reader 同构——其 `book_bottom_sheet.dart`
  /// 也是详情页的唯一入口）。PRD `META-08` 的「从书架点击进入」已同步改文。
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
    // 「用户按下书卡」是整条链路的计时原点——必须**先于任何 await**打点，
    // 否则读字节 / 嗅探的耗时会算不进「点下→看到书」的总账里。
    final OpenTrace trace = OpenTrace.begin(
      bookId: record.bookId,
      title: record.title,
    );
    setState(() => _openingBookId = record.bookId); // 该卡显示 loading 覆盖层
    try {
      final PerfWatch readWatch = PerfLog.watch('open.readBytes');
      final Uint8List? bytes = await widget.repository.readBookBytes(record);
      readWatch.done(
          'book=${record.title} sizeKB=${(bytes?.length ?? 0) ~/ 1024}');
      trace.step('readBytes', readWatch.elapsedMs,
          'sizeKB=${(bytes?.length ?? 0) ~/ 1024}');
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件已丢失：${record.fileName}')),
          );
        }
        return;
      }

      final PerfWatch sniffWatch = PerfLog.watch('open.sniff');
      // M-PAGE `T06`：结构缓存判据（副本 mtime/size + bookId）；文件缺失 → null
      // → 缓存对不启用，开书行为与无缓存时一致。
      final StructureCacheKey? cacheKey =
          await widget.repository.structureCacheKey(record);
      final BookSource source = await openBook(
        fileName: record.fileName,
        bytes: bytes,
        structureCache: widget.repository.structureCache,
        cacheKey: cacheKey,
        txtOutlineCache: widget.repository.txtOutlineCache,
        chapterTextCache: widget.repository.chapterTextCache,
      );
      sniffWatch.done('impl=${source.implId}');
      trace.step('sniff', sniffWatch.elapsedMs, 'impl=${source.implId}');
      // 不在导航前 eager 解析：全量 load() 在主 isolate 同步执行会冻结 UI，
      // 导致首击「无响应」、用户补点第二次（PERF）。解析与 loading 交给
      // ReaderPage._open() 承担（其自带 spinner + 错误态，RD-05 仍满足）。

      if (!mounted) return;
      // 开书转场（2026-10-09 重做）：用 [ReaderOpenRoute] 替掉裸 [MaterialPageRoute]——
      // 阅读页作为**一整张纸从右侧滑入**铺满，书架静止在后被压暗
      // （460ms / easeOutCubic / 70dp 圆角，参数来自负责人给的参考动效逐帧量化）。
      //
      // 动因（真机 release 档实测，见 docs/tech-usage.md §2.69 附一~附七）：
      // 点书卡到正文上屏 335~509ms，其中「首帧那一帧的框架任务插队」占 230~290ms
      // （探针已证**不是**解析——`content()` 内部四段合计 0ms）。这段等待属引擎侧
      // 首触（字体 / 图片解码器 / Skia 管线），**无法消除**，但可以被滑入动作盖住：
      // 用户点下即见纸张推进，而非白屏。
      final ReaderOpenRoute route = ReaderOpenRoute(
        builder: (_) => ReaderPage(
          source: source,
          record: record,
          progressStore: widget.progressStore,
          repository: widget.repository,
          statsService: widget.statsService,
          aiStore: widget.aiStore,
          aiClient: widget.aiClient,
          vocabStore: widget.vocabStore,
          summaryCache: widget.summaryCache,
          ragStore: widget.ragStore,
          ttsSettings: widget.ttsSettings,
          onlineTts: widget.onlineTts,
          bookmarkStore: widget.bookmarkStore,
          readingPrefsStore: widget.readingPrefsStore,
          syncTrigger: widget.syncTrigger,
          openTrace: trace,
        ),
      );
      // 不 await push 的 Future（它要等路由 pop 才返回）——push 一发起（路由已
      // 入栈）就往下走，finally 立即释放守卫。关书刷新走 route.popped，不占守卫。
      unawaited(Navigator.of(context).push(route));
      trace.mark('pushed');
      unawaited(route.popped.then((_) {
        // 阅读页关闭后刷新（lastReadAt / readProgress 已在 M1-T04 更新）。
        if (mounted) unawaited(_loadBooks());
      }));
    } finally {
      _opening = false;
      if (mounted) setState(() => _openingBookId = null);
    }
  }

  /// 顶栏假搜索框 → 书库搜索页；选中结果**直接进阅读页**。
  ///
  /// 搜索态：点搜索栏**就地展开**（不再 push 独立搜索页）。
  ///
  /// ══════════════════════════════════════════════════════════════════════════════
  /// 2026-10-20 上游搜索栏批：独立搜索页 → 就地搜索态
  /// ══════════════════════════════════════════════════════════════════════════════
  /// 原实现 `Navigator.push(LibrarySearchPage)`：查询与书架状态解耦，但点一下
  /// 搜索栏就要整页跳转，与参考 App（搜索栏原地变输入框 + 右侧取消钮 + 胶囊行
  /// 淡出、内容让位）差一整层交互。现改为：
  ///
  ///  * 搜索栏换真输入框（`MiSearchBar(editable: true)`：放大镜与占位文字不动、
  ///    光标 + hint 同现），聚焦即弹键盘；
  ///  * 右侧让出 [MiSearchCancelButton]（⌀44.1 = 栏高），转场中段淡入；
  ///  * 胶囊分类行淡出并收高（搜索态不参与排版，头部只剩搜索行）；
  ///  * 结果**直接替换下方网格**（书卡形态不变，点卡即走 [_openBook] 同一管道）。
  ///
  /// 元数据过滤是纯内存操作（书名 / 作者 / 原始文件名），可以边输入边出结果。
  void _enterSearch() {
    if (_searching) return;
    setState(() => _searching = true);
  }

  /// 退出搜索态：先收键盘再清查询（顺序反了会在列表重建后弹一次键盘）。
  void _exitSearch() {
    if (!_searching) return;
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  /// 输入变化：查询串统一 trim + 小写后比较（中文不受影响，英文大小写不敏感）。
  void _onQueryChanged(String raw) {
    final String next = raw.trim().toLowerCase();
    if (next == _query) return;
    setState(() => _query = next);
  }

  /// 命中的书（书名 / 作者 / 原始文件名任一包含查询串）。
  List<BookRecord> get _searchResults {
    if (_query.isEmpty) return const <BookRecord>[];
    final String q = _query;
    return _books
        .where((BookRecord b) =>
            b.title.toLowerCase().contains(q) ||
            b.author.toLowerCase().contains(q) ||
            b.fileName.toLowerCase().contains(q))
        .toList();
  }

  // 拖拽 / 文件夹相关的方法（`_mergeIntoFolder` / `_dropIntoFolder` /
  // `_openFolder` / `_folderActions` / `_folderById` / `_toast`）已随
  // 2026-09-29 拍板整体移除：归类改走详情页「分组」行，书架不再有拖拽与
  // 文件夹卡（本页仅剩导入结果一处轻提示，直接调 `GlassOverlays.showToast`）。

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double topInset = MediaQuery.paddingOf(context).top;

    // `UI-02` 导航层玻璃化：顶栏走 GlassTopBar、壳层走 GlassNavScaffold
    // （照抄 book_detail_page 范本）；内容整体不透明（`UI-04`）。
    //
    // 2026-09-29 浮动头部批（负责人「标题栏也参考图片，内容可以 edge to edge」，
    // 拍板「全浮动头部」）：搜索胶囊 + 分组 chips 组成两行**浮动头部**（参考图 =
    // HyperOS 主题商店首页的「搜索条 + 分类 chips 压在内容上」）；正文
    // `extendBody: true` 铺满全屏、从头部下穿过，顶栏下方内容透出磨砂模糊
    // （`UI-02` ②）。首行保护 = 网格 `padding.top` 留出头部高度（见
    // [shelfGridPadding]）。**头部两行恒在场**（含 loading / 空态），避免
    // 「加载中 → 有书」头部高度跳变。
    return GlassNavScaffold(
      extendBody: true,
      appBar: GlassTopBar(
        title: _buildHeader(),
        // **靠左不居中**：库的 `_ToolbarLayout` 在 `centerTitle: true`（默认）时
        // 按整条宽度居中，并把可用宽压成 `size.width - 2 * max(leading, actions)`
        // （等边距口径，`glass_app_bar.dart:559-578`）——本页标题是两行头部，
        // 居中收缩会破坏「全宽搜索胶囊 + 铺满 chips 行」形态。传 `false` 走
        // `:579-611`：可用宽 = 整宽减去两侧内边距（本页无 leading/actions 槽）。
        centerTitle: false,
        // 高度**恒取两行**：搜索态由头部自己把胶囊行收成 0 高（[AnimatedSize]），
        // 顶栏高度若跟着突变，转场第一帧整条栏会跳一下。
        toolbarHeight: kShelfHeaderHeight,
      ),
      body: OpaqueContentSurface(
        child: DecoratedBox(
          decoration: shelfGradientBackground(theme),
          child: _searching
              ? _buildSearchBody(theme, topInset)
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _books.isEmpty
                      ? _buildEmptyState(theme)
                      : Column(
                          children: <Widget>[
                            Expanded(
                              // 有书、但当前分组里一本都没有（如刚把书都移出了该分组）。
                              child: _visibleBooks.isEmpty
                                  ? _buildNoMatchState(theme)
                                  : _buildBookGrid(topInset),
                            ),
                            if (_importErrors.isNotEmpty)
                              _buildErrorList(theme),
                          ],
                        ),
        ),
      ),
    );
  }

  /// 搜索态正文：未输入 → 引导；无命中 → 提示；有结果 → **同一套书卡网格**。
  ///
  /// 复用 [_buildBookGrid] 而不是另写结果列表：点结果与点书架书卡必须是同一个
  /// 手势结果（2026-09-29 拍板「同一手势一种结果」），复用能天然保证这点。
  Widget _buildSearchBody(ThemeData theme, double topInset) {
    if (_query.isEmpty) {
      return _buildSearchHint(theme);
    }
    final List<BookRecord> results = _searchResults;
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '没有匹配「$_query」的书籍',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return _buildBookGrid(topInset, books: results);
  }

  /// 搜索态未输入时的引导（原独立搜索页的同款文案与图标）。
  Widget _buildSearchHint(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.search,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '输入关键字开始搜索',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 浮动头部（两行，参考图形态）：搜索行（胶囊 + 排序）+ 分组标签行。
  ///
  /// 2026-10-16：导入按钮迁到底栏**绿圆钮**（`HomeShell` 经 GlobalKey 调
  /// [pickAndImport]），搜索行原「+」按钮移除；导入进行中在原槽位显示
  /// 进度圈（非按钮，只是状态指示）。
  ///
  /// 整体包一层透明 [Material]：右侧动作按钮（排序）是 Material
  /// [IconButton]（水波纹与文字样式要求最近处有 Material）；搜索胶囊是玻璃
  /// 控件（[GlassButton]）、分组标签行是 [AdaptivePillTabBar] 纯色胶囊，都不
  /// 需要 Material。`MaterialType.transparency` 不绘制底色，不破坏玻璃观感。
  Widget _buildHeader() {
    final MiThemeMode mode = navThemeModeOf(context);
    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: kShelfSearchRowHeight,
            child: Row(
              children: <Widget>[
                // 搜索胶囊铺满剩余宽（「全宽」形态）；搜索态下由右侧取消钮让位。
                Expanded(
                  child: _BookSearchEntry(
                    onTap: _enterSearch,
                    searching: _searching,
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: _onQueryChanged,
                    mode: mode,
                  ),
                ),
                if (_importing)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                // 2026-10-20 上游搜索栏批：搜索行右侧的**排序按钮移除**（顶部只留
                // 搜索栏 + 胶囊行）。排序逻辑与菜单 [_showSortMenu] 原样保留，
                // 入口暂缺——挂账待定，确定落点后直接接回，不必重写。
                if (_searching)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: MiSearchCancelMetrics.barGap,
                    ),
                    // 取消钮在转场中段淡入（Interval 直接取上游录屏实测段：
                    // 0.35…0.62，既不跟最后一帧一起冒出来，也不是一开始就有）
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: _searchTransition,
                      curve: const Interval(
                        MiTopBarMetrics.searchCancelFadeBegin,
                        MiTopBarMetrics.searchCancelFadeEnd,
                        curve: Curves.easeOut,
                      ),
                      builder: (BuildContext context, double t, Widget? child) =>
                          Opacity(opacity: t, child: child),
                      child: MiSearchCancelButton(
                        onTap: _exitSearch,
                        themeMode: mode,
                        // 头部已有自己的磨砂层（见 [_buildHeaderBlur]），零件
                        // 不再自绘 backdrop；膜照开（书卡从头部下方穿过）
                        frosted: false,
                        overContent: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 胶囊分类行：搜索态淡出并收高（不参与排版，头部只剩搜索行）。
          // 用 AnimatedSize 而不是改 toolbarHeight——顶栏高度突变会让整条栏跳。
          AnimatedOpacity(
            opacity: _searching ? 0 : 1,
            duration: _searchTransition,
            child: AnimatedSize(
              duration: _searchTransition,
              curve: MiTopBarMetrics.searchMotion,
              alignment: Alignment.topCenter,
              child: _searching
                  ? const SizedBox(width: double.infinity, height: 0)
                  : Padding(
                      padding: const EdgeInsets.only(top: kShelfHeaderRowGap),
                      child: SizedBox(
                        height: kShelfChipsRowHeight,
                        child: _buildGroupFilterBar(),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组筛选栏（**单选**：全部 / 各分组）—— 浮动头部第二行（参考图 chips 行）。
  ///
  /// ══════════════════════════════════════════════════════════════════════════════
  /// 2026-10-16 参考项目批：GlassChip 行 → 胶囊分类标签（初版 [MiPillTabBar]
  /// 定宽；同日按拍板换 [AdaptivePillTabBar] 自适应宽：min 87.6 / max 175.2 /
  /// 超出省略号——视觉 token 全复用移植体，宽度规则在移植树外）
  /// ══════════════════════════════════════════════════════════════════════════════
  /// · 标签 = 「全部」+ 各分组名，横向可滚（组件内置滚动容器）；
  /// · 「全部」恒在首位；分组顺序 = `ShelfLayoutStore` 的创建序（`groups` 列表序）；
  ///   只列**真有书**的分组：空分组已由 `prune` 清掉，故此处无需再过滤；
  /// · 交互语义保持书架既有拍板：**单选 + 再点已选中的回「全部」**（组件是纯
  ///   标签行、无「再点取消」语义，由 [onTap] 映射承担）；
  /// · 明暗：[MiThemeMode] 按 `GlassScope` 级联亮度解析（同底栏 [navThemeModeOf]）。
  ///
  /// 对齐：组件自带 [MiPillTabMetrics.edgeInset]（11.9，参考项目页边距口径），
  /// 而本页头部由顶栏槽给 8dp 内边距、左缘须与搜索胶囊对齐（既有形态）——故把
  /// 组件盒**放宽 2×11.9 并居中**（`OverflowBox` + `Alignment.topCenter`）：
  /// 内置内嵌正好抵消到槽边，胶囊左缘 = 槽左缘 = 搜索胶囊左缘；外层 [ClipRect]
  /// 保住「超出视口裁切滚动」的形态。行高仍由 [_buildHeader] 的
  /// `SizedBox(kShelfChipsRowHeight)`（40）给定，胶囊高 39.9 落在行内。
  Widget _buildGroupFilterBar() {
    final String? selected = widget.shelfPrefs.prefs.groupId;
    // 选中分组已消失（书被删空）→ 视作「全部」，高亮随之回到「全部」。
    final List<BookGroup> groups = widget.shelfLayout.layout.groups;
    final bool hasSelection = selected != null &&
        widget.shelfLayout.layout.groupById(selected) != null;
    final int selectedIndex = hasSelection
        ? 1 + groups.indexWhere((BookGroup group) => group.id == selected)
        : 0;
    return ClipRect(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double wide =
              constraints.maxWidth + 2 * MiPillTabMetrics.edgeInset;
          return OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: wide,
            maxWidth: wide,
            minHeight: kShelfChipsRowHeight,
            maxHeight: kShelfChipsRowHeight,
            child: AdaptivePillTabBar(
              labels: <String>[
                '全部',
                for (final BookGroup group in groups) group.name,
              ],
              selectedIndex: selectedIndex,
              themeMode: navThemeModeOf(context),
              // 书卡从头部下方穿过（压在内容上）：未选胶囊要垫那层玻璃膜，
              // 否则在杂乱封面上只剩文字可辨、读不出胶囊形状（上游 2026-10-20）
              overContent: true,
              onTap: (int i) => unawaited(
                widget.shelfPrefs.setGroup(
                  i == 0 || i == selectedIndex ? null : groups[i - 1].id,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 排序菜单（右上角弹出；当前字段右侧显示方向箭头，再点同项即翻转方向）。
  ///
  /// **当前无 UI 入口**（2026-10-20 上游搜索栏批：搜索行右侧的排序按钮移除，
  /// 顶部只留「搜索栏 + 胶囊行」）。排序**功能与偏好照旧完整保留**——排序字段 /
  /// 方向仍在 `ShelfPrefsStore` 里生效，`_visibleBooks` 照旧读它；只是入口
  /// 暂缺、挂账待定落点（候选：胶囊行末尾的排序胶囊 / 设置页书架分组）。
  /// 定案后直接给某个按钮接上 `onPressed: _showSortMenu` 即可，无需重写。
  // ignore: unused_element
  Future<void> _showSortMenu() async {
    final ThemeData theme = Theme.of(context);
    final ShelfPrefs prefs = widget.shelfPrefs.prefs;
    final Size screen = MediaQuery.of(context).size;
    final double top =
        MediaQuery.of(context).padding.top + kShelfHeaderHeight;

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
              onPressed: pickAndImport,
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
  /// 本页只把「点击直接开书」「长按弹操作单」两个回调接上。
  ///
  /// [topInset] = 状态栏高（`MediaQuery.padding.top`）；网格 `padding.top`
  /// 经 [shelfGridPadding] 合成后 = `状态栏 + 浮动头部高 + 12`——**首行不被
  /// 浮动头部盖住**的唯一保证（内容 edge-to-edge 后正文从 y=0 起）。
  ///
  /// [books] 默认 [_visibleBooks]；搜索态传命中结果（同一套书卡网格，保证
  /// 「点结果」与「点书架书卡」是同一手势结果）。
  Widget _buildBookGrid(double topInset, {List<BookRecord>? books}) {
    // 搜索态胶囊行收起 → 头部只剩搜索行，顶部留白与磨砂跟随缩短。
    final double headerHeight =
        _searching ? kShelfSearchRowHeight : kShelfHeaderHeight;
    return Stack(
      children: <Widget>[
        ShelfGrid(
          books: books ?? _visibleBooks,
          coverStore: widget.coverStore,
          openingBookId: _openingBookId,
          padding: shelfGridPadding(topInset, headerHeight: headerHeight),
          // 点书卡 = **直接进阅读页**（2026-09-29 拍板：原「点卡 → 详情页」改道；
          // 与 anx-reader 一致——其 `book_item.dart:51-53` 的 `onTap` 即
          // `pushToReadingPage`）。详情页入口改走长按操作单「书籍详情」。
          onOpenBook: (BookRecord record) => unawaited(_openBook(record)),
          // 不 `unawaited`：这个 Future 的完成时机**就是**长按抬起反馈的复位时机
          // （见 `_showBookActions` 的返回值语义）。
          onBookActions: _showBookActions,
        ),
        // 头部区磨砂（`UI-02` ②）。叠在列表**之后**（同 Stack）才采样得到滚动
        // 内容；`IgnorePointer` 不吃手势，不影响点卡 / 长按。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topInset + headerHeight,
          child: _buildHeaderBlur(),
        ),
      ],
    );
  }

  /// 头部区磨砂：**一整段恒定 σ 铺满头部、到栏底硬切**。
  ///
  /// ══════════════════════════════════════════════════════════════════════════════
  /// 2026-10-20 上游「首页悬浮头部」批：渐进曲线 → 恒定 σ
  /// ══════════════════════════════════════════════════════════════════════════════
  /// 原实现是 [MiGradientBlur]（σ 沿 y 递减、120dp 处归零）。上游拿完整截图
  /// 逐点实测后推翻了这条曲线：搜索栏行、栏与胶囊之间的间隙、胶囊行后方的
  /// 内容**糊得一样重**，胶囊底缘往下立刻锐利 —— 照曲线拉伸到头部底缘时，
  /// 胶囊行所在位置只剩 σ≈2.5，与截图明显不符。
  ///
  /// 于是头部区形态改走 `MiTopBar.uniformBlurBands` 那条规律的一整段恒定
  /// σ（本页是自拼头部、不是 `MiTopBar` 的头部插槽，故这里自己铺同一段）：
  /// 高度 = 状态栏 + 头部高（[shelfGridPadding] 的同一口径），到栏底硬切。
  ///
  /// 只用一段也把全宽高斯从 8 段压到 1 段（滚动时每帧都走这里）。
  Widget _buildHeaderBlur() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: MiTopBarPalette.blurSigma,
          sigmaY: MiTopBarPalette.blurSigma,
        ),
        child: const SizedBox.expand(),
      ),
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

/// 顶栏里的搜索栏——常规态是「假搜索框」（点击进搜索态），搜索态变真输入框。
///
/// **靠左铺满而非居中收缩**：调用方须传 `centerTitle: false`（见 `build`）。
/// 居中档下库会把可用宽压成 `width - 2 * max(两侧)`，搜索态还要让位给取消钮，
/// 搜索框就只剩半宽且浮在中间——「看起来是个居中的小胶囊」，不是搜索框该有的样子。
///
/// ══════════════════════════════════════════════════════════════════════════════
/// 2026-10-19 上游搜索栏批：自绘玻璃胶囊 → 上游 [MiSearchBar]
/// ══════════════════════════════════════════════════════════════════════════════
/// 原实现是 [GlassButton.custom] 手拼「放大镜图标 + 占位文字」的自绘玻璃
/// 胶囊（36 高）。现改为上游 [MiSearchBar]——1:1 实测自小米主题商店分类页
/// 的搜索栏：stadium 高 44.1、图标 17.8 + 图文间距 12 起于左缘 15.4、占位
/// 文字 CJK 16.5dp。材质配方走组件自身的 `search_bar_tokens`，不再由业务页引
/// `GlassMaterial.settingsFor`（同 `UI-07`「材质单一出处」精神）。
/// 几何契约不变：靠左贴顶栏内边距、铺满可用宽（`test/ui/shelf_page_test.dart`
/// 的 `shelf-search-entry` 断言只换样式判据，几何判据原样）。
///
/// ══════════════════════════════════════════════════════════════════════════════
/// 2026-10-20 上游搜索栏批：接**搜索态**与**玻璃膜**
/// ══════════════════════════════════════════════════════════════════════════════
///  * [searching] = true 时同一个组件换成真输入框（`editable`）：几何 / 配色
///    不变，光标 + hint 同现，聚焦即弹键盘。进入靠 `autofocus`，退出由父级
///    `unfocus` + 换回非编辑态两个动作一起收键盘；
///  * [overContent] 恒开：书卡从头部下方穿过（压在高频封面上），只留平底页
///    那档半透明填充时整条栏会糊成一片、边缘读不出来。
///
/// 明暗经 [navThemeModeOf] 显式传入（与底栏 / 胶囊标签同一 `GlassScope` 出处，
/// `UI-01` ② 跟应用主题三态），而非留给组件回落环境 `Theme.of`。
class _BookSearchEntry extends StatelessWidget {
  const _BookSearchEntry({
    required this.onTap,
    required this.searching,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.mode,
  });

  /// 常规态点击回调（进入搜索态）。
  final VoidCallback onTap;

  /// 是否处于搜索态（真输入框）。
  final bool searching;

  /// 搜索态输入控制器。
  final TextEditingController controller;

  /// 搜索态焦点节点（退出时由页面 `unfocus`）。
  final FocusNode focusNode;

  /// 输入变化回调。
  final ValueChanged<String> onChanged;

  /// 明暗配方（父级已解析，避免两次查 `GlassScope`）。
  final MiThemeMode mode;

  @override
  Widget build(BuildContext context) {
    return MiSearchBar(
      // 供契约测试定位（`test/ui/shelf_page_test.dart` 断言「靠左铺满 +
      // MiSearchBar 材质」）。
      key: const Key('shelf-search-entry'),
      hint: '搜索书名、作者',
      onTap: searching ? null : onTap,
      themeMode: mode,
      // 头部已有自己的磨砂层（`_buildHeaderBlur`），零件不再自绘 backdrop：
      // 整条栏只糊一次，否则栏内比周围更糊、且多一份每帧全 QUAD 高斯。
      frosted: false,
      // 压在书卡上：垫玻璃膜（膜取页底色 ⇒ 静止态观感不变）
      overContent: true,
      editable: searching,
      controller: searching ? controller : null,
      focusNode: searching ? focusNode : null,
      autofocus: searching,
      onChanged: searching ? onChanged : null,
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
