// `LIB-01`：书架首页（替代 M0 验证台的 `HomePage`）。
//
// 要点：
//   · 空态 = 引导文案 + 导入按钮；有书 = 浮动头部（全宽玻璃搜索胶囊 + 分组 chips）
//     + 网格 [BookCard]（封面缩略图 + 书名 + 作者 + 格式标签）；
//   · 内容 edge-to-edge（`extendBody: true`）从头部下穿过、透出磨砂模糊（`UI-02` ②）；
//     首行保护 = 网格 `padding.top` 留出头部高（[shelfGridPadding]）；
//   · 导入 = `FilePicker` 多选 → 逐个 `importFile`（进度 + 失败清单）；删除 = 长按书卡
//     → 长按弹框（mi_like_ui `MiDialog`）→ 确认框 → `deleteBook`（`LIB-06`
//     二次确认）+ 连带清理进度；
//   · 点击书卡 = **直接进阅读页**；长按「书籍详情」是详情页**唯一**入口（`META-08`）；
//     详情页「继续阅读」经**注入的** `_openBook` 开书（**不复制**开书管道），pop 后
//     刷新列表（编辑 / 移出 / 分组 / 进度靠这次刷新同步）；
//   · 「点击即开书」：点卡**立即** push 阅读页（骨架屏先上屏），读字节 / 建源的
//     准备改在阅读页骨架屏期间进行（[ReaderPage.sourceFuture]）；开书守卫
//     `_opening` 覆盖 push → 关书（防连点叠页，关书即释放）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 拍板：筛选项由「阅读状态」改为「分组」、移除拖拽归类
// ══════════════════════════════════════════════════════════════════════════════
// · 顶部 chips = **全部 + 各分组名**（分组来自 `ShelfLayoutStore`，顺序即创建序；
//   只列「真有书」的分组——空分组由 `prune` 清掉）；
// · 选中分组 → 网格只显示该分组的书；默认「全部」；再点已选中的 chip 回「全部」；
// · 归类入口 = **书籍详情页的「分组」行**（需求 `P2-02`）；书架不再有拖拽归类
//   （建文件夹 / 移入 / 重排全移除）、不再有文件夹卡与文件夹内页；
// · 一本书**只属一个分组**（`ShelfLayoutStore` 保证归属唯一），未分组的书在
//   「全部」里正常展示、其他分组筛选下不可见。
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
import '../format/book_instance_key.dart';
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
import 'book_card.dart';
import 'book_detail_page.dart';
import 'glass_kit.dart';
import 'glass_nav_host.dart' show navThemeModeOf;
import 'home_shell.dart' show kShellBottomInset;
import 'mi_like_ui/mi_like_ui.dart'
    show
        MiCardPageRoute,
        MiDialog,
        MiDialogItem,
        MiDialogLayout,
        MiPillItemWidth,
        MiPillTabBar,
        MiPillTabMetrics,
        MiSearchBar,
        MiThemeMode,
        MiTopBar,
        MiTopBarBlurBand,
        MiTopBarMetrics,
        MiTopBarPalette;
import 'shelf_grid.dart';
import 'shelf_search_page.dart';

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

  /// 统计服务（`STAT-01` 采集落库）透传阅读页；`null` = 未接线 → 阅读页不采集。
  final StatsService? statsService;

  /// AI 配置 / 客户端 / 生词本（划词翻译释义，`AI-02`/`AI-03`）透传阅读页；
  /// 任一为 null → 阅读页划词整体禁用（同款降级口径）。
  final ProviderStore? aiStore;
  final AiClient? aiClient;
  final VocabStore? vocabStore;

  /// 摘要缓存（阅读页 `AI-04`/`AI-05`）；删书连带清理；`null` = 摘要入口隐藏。
  final SummaryCache? summaryCache;

  /// 问答索引存储（阅读页 `AI-06`）；删书连带清理；`null` = 问答入口隐藏。
  final RagIndexStore? ragStore;

  /// 朗读设置存储（阅读页 `TTS-04`/`TTS-05`）；`null` = 朗读设置入口隐藏。
  final TtsSettingsStore? ttsSettings;

  /// 在线 TTS 配置存储（阅读页 `TTS-07`）；`null` = 引擎选择区隐藏、只用系统引擎。
  final OnlineTtsStore? onlineTts;

  /// 书签存储（透传阅读页）。
  final BookmarkStore? bookmarkStore;

  /// 阅读偏好存储（透传阅读页）。
  final ReadingPrefsStore? readingPrefsStore;

  /// 同步触发器（透传阅读页：退出阅读页上报进度，`SYNC-06`）。
  final SyncTrigger? syncTrigger;

  @override
  State<ShelfPage> createState() => ShelfPageState();
}

/// [ShelfPage] 的状态类（公开：`HomeShell` 经 [GlobalKey] 把底栏绿圆钮的
/// 「导入书籍」动作接到 [pickAndImport]）。
class ShelfPageState extends State<ShelfPage> {
  List<BookRecord> _books = <BookRecord>[];
  bool _loading = true;
  bool _importing = false;
  List<String> _importErrors = <String>[];

  /// 防重复开书：覆盖 **push → 关书**（`route.popped` 即释放）——防连点叠两个
  /// 阅读页；关书即释放，之后首点不被吞。
  bool _opening = false;

  /// 网格滚动控制器：位移换算成头部零件的内缘亮边进度（见 [_headerRim]）。
  final ScrollController _gridScrollController = ScrollController();

  /// 头部零件（搜索胶囊 / 胶囊行）的内缘亮边进度 0…1 —— 映射同上游
  /// `MiTopBarMetrics.rimFadeDistance`（内容距栏底 ≈20dp 内渐亮；静止不亮、
  /// 滚 20dp 后满亮保持）。用 [ValueNotifier] 而非整页 `setState`：滚动时
  /// 只重建头部两层零件。
  final ValueNotifier<double> _headerRim = ValueNotifier<double>(0);

  /// 详情页路由在栈上（push 已发起、尚未 pop）：吞掉过渡期 / 会话期的重复点卡，
  /// 防「双击卡片 → 叠两个详情页」。pop 后由 [_openDetail] 的 `finally` 释放。
  bool _detailPushing = false;

  // ── 搜索入口 ──
  //
  // 只留「点搜索栏 → 推入 [ShelfSearchPage]」一条路径（转场 [MiCardPageRoute]：
  // 新页从右缘滑入、下层页左移压暗）：参考素材里搜索页是**整屏无 App 级导航**的，
  // 就地展开做不到（浮动底栏还在）。过滤与结果渲染都在搜索页内（查询与书架
  // 状态解耦，键盘遮挡也归那页管）。

  /// 点搜索栏 → 卡片式推入搜索页（转场规格见 [MiCardPageRouteMetrics]）。
  void _enterSearch() {
    final MiThemeMode mode = navThemeModeOf(context);
    Navigator.of(context).push(
      MiCardPageRoute<void>(
        settings: const RouteSettings(name: 'shelf-search'),
        builder: (BuildContext pageContext) => ShelfSearchPage(
          books: _books,
          coverStore: widget.coverStore,
          themeMode: mode,
          onOpenBook: (BookRecord record) {
            // 关搜索页再开书：阅读页压在书架之上，返回时不该回到搜索页。
            //
            // ⚠️ 但**不能在开书瞬间立刻移除本页**：立刻 removeRoute 会让书架在
            // 纸张就绪前闪现（三段跳 = 丢帧感 + 闪动）。正确编排与书架开书一致
            // ——**纸张滑入时背景就是点它的那一页**：本页留作背景，等纸张转场
            // 完成（全覆盖、此刻移除不可见）再摘掉。
            final Route<void> searchRoute = ModalRoute.of(pageContext)!;
            final NavigatorState nav = Navigator.of(pageContext);
            unawaited(_openBook(record, onPushed: (PageRoute<void> readerRoute) {
              _removeUnderWhenCovered(readerRoute, searchRoute, nav);
            }));
          },
          onBookActions: _showBookActions,
        ),
      ),
    );
  }

  /// 等 [route]（阅读页纸张）转场**完成、完全覆盖屏幕**后移除下层 [under]
  /// （此刻移除对用户不可见）。双保险：状态监听 + 转场时长兜底 Timer——动画
  /// 被跳过 / 提前返回时也绝不把下层路由泄漏在栈上（返回会回到已关掉的搜索页）。
  void _removeUnderWhenCovered(
    PageRoute<void> route,
    Route<void> under,
    NavigatorState nav,
  ) {
    bool done = false;
    void remove() {
      if (done) return;
      done = true;
      if (under.isActive) {
        try {
          nav.removeRoute(under);
        } catch (_) {
          // 已不在栈上（并发摘除）→ 无事可做。
        }
      }
    }

    final Animation<double>? anim = route.animation;
    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        anim?.removeStatusListener(onStatus);
        remove();
      }
    }

    anim?.addStatusListener(onStatus);
    // 兜底：ReaderOpenRoute 按住待就绪的时长不定；动画没走完（中途返回 /
    // 转场被跳过）也必须摘掉下层，否则「返回回到已关搜索页」。
    unawaited(Future<void>.delayed(
      kReaderOpenDuration + const Duration(milliseconds: 800),
    ).then((_) {
      anim?.removeStatusListener(onStatus);
      remove();
    }));
  }

  @override
  void initState() {
    super.initState();
    // 筛选 / 排序偏好与书架布局（手动顺序 + 文件夹）一变即重绘
    // （两者都是进程内共享实例，见 [ShelfPrefsStore] / [ShelfLayoutStore]）。
    widget.shelfPrefs.addListener(_onStoreChanged);
    widget.shelfLayout.addListener(_onStoreChanged);
    _gridScrollController.addListener(_syncHeaderRim);
    _loadBooks();
  }

  @override
  void dispose() {
    widget.shelfPrefs.removeListener(_onStoreChanged);
    widget.shelfLayout.removeListener(_onStoreChanged);
    _gridScrollController.removeListener(_syncHeaderRim);
    _gridScrollController.dispose();
    _headerRim.dispose();
    super.dispose();
  }

  /// 网格滚动 → 头部亮边进度（映射同 `MiTopBarMetrics.rimFadeDistance`：
  /// 素材实测是「内容距栏底 ≈20dp」的接近度阈值，顶栏不知道内容布局，
  /// 按标准布局换算成滚动位移）。
  void _syncHeaderRim() {
    _headerRim.value =
        (_gridScrollController.offset / MiTopBarMetrics.rimFadeDistance)
            .clamp(0.0, 1.0)
            .toDouble();
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
    // 会清掉这个空分组，而 `ShelfPrefs.groupId` 仍指着它——不回落的话书架会永久
    // 显示「没有符合当前筛选的书」，用户找不到恢复入口。
    final String? selected = prefs.groupId;
    final BookGroup? group =
        selected == null ? null : widget.shelfLayout.layout.groupById(selected);
    if (group != null) {
      final Set<String> members = group.bookIds.toSet();
      list = list.where((BookRecord b) => members.contains(b.bookId));
    }

    final List<BookRecord> sorted = list.toList();

    // 手动顺序单独一条路径：顺序**就是** `order` 本身，不受升降序开关影响
    // （否则「再点同项翻转方向」会把顺序打乱）；`order` 由过去的拖拽重排写入
    // （拖拽重排已删，此分支仅消费旧数据 + 排序菜单入口）。
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

  /// 导入书籍入口（`FilePicker` 多选 → 逐个 `importFile`）。由底栏**绿圆钮**
  /// 触发（`HomeShell` 经 GlobalKey 调本方法，原顶部加号按钮已移除）；
  /// 空态引导按钮仍调本方法（`LIB-01` ②）。
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
    // `UI-03` 浮层玻璃：玻璃确认框。barrier 可关（返回 null = 取消）：非 `true`
    // 一律不删。
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
      // 连带清理：该书的章级 / 合并级摘要缓存。
      await widget.summaryCache?.removeBook(record.bookId);
      // 连带清理：该书的问答索引（内存 + 磁盘分文件）。
      await widget.ragStore?.removeBook(record.bookId);
      await _loadBooks();
    }
  }

  /// 长按书卡 → 操作弹框（mi_like_ui [MiDialog]，2026-10-23 换掉原玻璃底部
  /// 操作单；同日上游 `f254f85`（issue #1）补出**纵向操作列表**形态，布局回到
  /// 「图标 + 主文案 + 副标题」的列表语义）。长按**不再**直接弹删除确认：删除
  /// 是破坏性动作，收进弹框并要求二次确认（`LIB-06`），缩短「误触即删」路径。
  ///
  /// **承载**：[MiDialog] 是遮罩 + 卡片一体的**不透明**弹框，自带明暗两档遮罩
  /// （亮 α0.20 / 暗 α0.60，`MiDialogPalette.scrim`），故走 [showDialog] 时把
  /// **路由遮罩设为透明**（`barrierColor: Colors.transparent`）——否则两层遮罩
  /// 叠加、比度量重一档；「点遮罩收起」由 `onScrimTap` 自己 `pop`。明暗不取
  /// `Theme.of(context).brightness`，而取 [navThemeModeOf]（`GlassScope` 级联
  /// 亮度）——与底栏 / 胶囊标签同一出处（`UI-01` ②）。
  ///
  /// **档位**：弹框不是玻璃件，玻璃开 / 关两档同形，也不存在「玻璃嵌套」
  /// （PRD §11.4）问题。
  ///
  /// **形态**：[MiDialogLayout.list]（推导形态，几何事实源 = `MiDialogListMetrics`）——
  /// 标题左对齐最多两行（书名可折行），三项各自带前导图标与副标题，
  /// 「移出书架」走 `destructive` 整行红字；项间分隔线、卡片超高时列表区
  /// 内部滚动（上游 clamp，不顶出屏幕）。无按钮行：关弹框 = 点遮罩 / 系统返回。
  ///
  /// **返回值语义**：本 Future 在**弹框关闭时即完成**、不等选定的动作走完——
  /// 书卡用它当长按抬起反馈的复位时机（`BookCard.onLongPress` 是异步回调）；
  /// 动作由 [_runBookAction] 接管（`unawaited`），以免「点继续阅读 → 卡片一路
  /// 悬着直到从阅读页返回」。
  Future<void> _showBookActions(BookRecord record) async {
    final double? progress = record.readProgress;
    // 副标题沿用原操作单口径：作者 · 格式 · 已读%（缺失项各自跳过）。
    final String subtitle = <String>[
      if (record.author.isNotEmpty) record.author,
      record.format.toUpperCase(),
      if (progress != null) '已读 ${(progress * 100).round()}%',
    ].join(' · ');

    final _BookAction? action = await showDialog<_BookAction>(
      context: context,
      // 路由遮罩透明：遮罩由 MiDialog 自绘（见类注释），两层不可叠加。
      barrierColor: Colors.transparent,
      builder: (BuildContext dialogContext) => MiDialog(
        layout: MiDialogLayout.list,
        title: record.title,
        message: subtitle,
        // 列表形态：正文左对齐（与左对齐标题 / 左对齐列表行同一条边）。
        messageAlign: TextAlign.start,
        themeMode: navThemeModeOf(context),
        // 三项即原操作单的三行：图标 + 主文案 + 副标题；「移出书架」破坏性
        // 红字，副标题「删除后封面文件一并清理」回归列表项（二次确认框
        // `_deleteBook` 仍独立在场，两层不重复）。
        items: <MiDialogItem>[
          MiDialogItem(
            label: '继续阅读',
            icon: const Icon(Icons.play_arrow, size: 22),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_BookAction.continueReading),
          ),
          MiDialogItem(
            label: '书籍详情',
            icon: const Icon(Icons.info_outline, size: 22),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_BookAction.detail),
          ),
          MiDialogItem(
            label: '移出书架',
            subtitle: '删除后封面文件一并清理',
            destructive: true,
            icon: const Icon(Icons.delete_outline, size: 22),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_BookAction.delete),
          ),
        ],
        // 点遮罩（= 系统返回同路）：只关弹框、不派发动作。
        onScrimTap: () => Navigator.of(dialogContext).pop(),
      ),
    );
    if (!mounted || action == null) return;
    unawaited(_runBookAction(record, action));
  }

  /// 弹框选定后的动作派发（[BookCard.onLongPress] 已随弹框关闭而复位，
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

  /// 书卡长按弹框 / 详情页的「书籍详情」→ 书籍详情页（`F9` / `META-08` ①）。
  ///
  /// **入口只有一个**：书架点卡改成直接进阅读页后，详情页只能从长按弹框进
  ///（PRD `META-08` 的「从书架点击进入」已同步改文）。pop 后刷新列表——编辑 /
  /// 移出书架 / 进度变化都靠这次刷新同步回书架。开书管道以 `onOpenBook: _openBook`
  /// 回调注入详情页（详情页**禁止**复制第二份）。
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

  /// 打开一本书：**立即** push 阅读页（骨架屏先上屏），读字节 / 建源的准备改在
  /// 阅读页骨架屏期间进行（[ReaderPage.sourceFuture]）——点下即见纸张滑入，
  /// 不再在书卡上转圈等准备（「点击即开书」）。
  ///
  /// 守卫 [_opening] 覆盖 **push → 关书**（`route.popped` 即释放）：防连点叠两个
  /// 阅读页；关书即释放，之后首点不被吞。
  /// [onPushed]：阅读页路由一入栈即回调（供调用方安排「覆盖后移除下层路由」）。
  Future<void> _openBook(
    BookRecord record, {
    void Function(PageRoute<void> route)? onPushed,
  }) async {
    if (_opening) return; // 防连点重复开书（覆盖到关书为止）
    _opening = true;
    // 「用户按下书卡」是整条链路的计时原点——必须**先于任何 await**打点，
    // 否则读字节 / 嗅探的耗时会算不进「点下→看到书」的总账里。
    final OpenTrace trace = OpenTrace.begin(
      bookId: record.bookId,
      title: record.title,
    );
    // 准备流水线（读字节 + 建源）即刻起跑，但**不等它**：push 与骨架屏先行，
    // 书源所有权随 Future 交给阅读页（它 dispose 时归还仓库复用池）。
    // `ignore()`：push 到阅读页首帧之间若流水线先报错，错误由阅读页 `_open`
    // 的 catch 接住落到错误态；此处只防「暂无监听器」的 unhandled async error。
    final Future<BookSource> sourceFuture = _prepareSource(record, trace);
    sourceFuture.ignore();
    // 开书转场：用 [ReaderOpenRoute] 替掉裸 [MaterialPageRoute]——阅读页作为
    // **一整张纸从右侧滑入**铺满，书架静止在后被压暗（320ms / easeOutCubic /
    // 70dp 圆角）。延迟路径下骨架屏首帧即放行（见 `ReaderPage._open`），
    // 用户点下即见纸张推进，而非在书架上等待。
    final ReaderOpenRoute route = ReaderOpenRoute(
      // 退场起步即释放守卫：纸张滑出的 240ms 里书架已可点，守卫晚放到
      // `popped`（反向动画落定）会吞掉关书后的首击。
      onPopStarted: () => _opening = false,
      builder: (_) => ReaderPage(
        sourceFuture: sourceFuture,
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
    try {
      // 不 await push 的 Future（它要等路由 pop 才返回）——push 一发起（路由已
      // 入栈）就往下走，守卫交由 route.popped 释放。
      unawaited(Navigator.of(context).push(route));
    } catch (_) {
      // push 失败（上下文失效等）：无人消费 → 到手的源归还仓库，守卫就地释放。
      _opening = false;
      unawaited(sourceFuture.then(
        (BookSource source) =>
            widget.repository.recycleBookSource(record, source),
        onError: (Object _) {},
      ));
      rethrow;
    }
    trace.mark('pushed');
    onPushed?.call(route);
    unawaited(route.popped.then((_) {
      _opening = false; // 兜底（正常路径已在 didPop 释放；幂等）
      // 阅读页关闭后刷新（lastReadAt / readProgress）。
      if (mounted) unawaited(_loadBooks());
    }));
  }

  /// 书源准备流水线：先查**复用池**（§2.108，命中就完全跳过「读字节 + 建源」），
  /// 未命中读字节 + 嗅探建源。文件丢失抛 [MReaderFormatException]（阅读页骨架屏
  /// 换错误态直接展示）。
  ///
  /// 池里有 ① 导入即入池的那份、② 上次关书还回来的那份，都自带原始字节 +
  /// 已解析结构 + 章节表缓存 ⇒ 命中时成本只剩一次 `stat`（判据校验）。判据与
  /// 磁盘缓存同口径（`bookId + mtime + size`）：文件被替换过 → 池条目自动作废
  /// 并销毁、走下面的冷路径，绝不会让旧字节冒充新文件。
  Future<BookSource> _prepareSource(BookRecord record, OpenTrace trace) async {
    final PerfWatch statsWatch = PerfLog.watch('open.stat');
    final BookInstanceKey? cacheKey =
        await widget.repository.bookInstanceKey(record);
    statsWatch.done('hit=${cacheKey == null ? 0 : 1}');

    final BookSource? pooled =
        widget.repository.takePooledSource(record, cacheKey);
    if (pooled != null) {
      trace.step('poolHit', statsWatch.elapsedMs,
          'impl=${pooled.implId} sizeKB=${(cacheKey?.size ?? 0) ~/ 1024}');
      PerfLog.step('open.pool', statsWatch.elapsedMs,
          'hit=1 impl=${pooled.implId}');
      return pooled;
    }

    final PerfWatch readWatch = PerfLog.watch('open.readBytes');
    final Uint8List? bytes = await widget.repository.readBookBytes(record);
    readWatch.done(
        'book=${record.title} sizeKB=${(bytes?.length ?? 0) ~/ 1024}');
    trace.step('readBytes', readWatch.elapsedMs,
        'sizeKB=${(bytes?.length ?? 0) ~/ 1024}');
    if (bytes == null || bytes.isEmpty) {
      throw MReaderFormatException(
        FormatErrorCode.fileMissing,
        detail: record.fileName,
      );
    }

    final PerfWatch sniffWatch = PerfLog.watch('open.sniff');
    final BookSource source =
        await openBook(fileName: record.fileName, bytes: bytes);
    sniffWatch.done('impl=${source.implId}');
    trace.step('sniff', sniffWatch.elapsedMs, 'impl=${source.implId}');
    PerfLog.step('open.pool', 0, 'hit=0 impl=${source.implId}');
    return source;
  }

  // 拖拽 / 文件夹相关方法已随「归类改走详情页『分组』行」的拍板整体移除：
  // 本页仅剩导入结果一处轻提示，直接调 `GlassOverlays.showToast`。

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double topInset = MediaQuery.paddingOf(context).top;

    // `UI-02` 导航层玻璃化：顶栏走 GlassTopBar、壳层走 GlassNavScaffold；
    // 内容整体不透明（`UI-04`）。
    //
    // 浮动头部（参考图 = HyperOS 主题商店首页「搜索条 + 分类 chips 压在内容上」）：
    // 搜索胶囊 + 分组 chips 两行；正文 `extendBody: true` 铺满全屏、从头部下穿过，
    // 顶栏下方内容透出磨砂模糊（`UI-02` ②）。首行保护 = 网格 `padding.top` 留出
    // 头部高度（见 [shelfGridPadding]）。**头部两行恒在场**（含 loading / 空态），
    // 避免「加载中 → 有书」头部高度跳变。
    return GlassNavScaffold(
      extendBody: true,
      appBar: GlassTopBar(
        title: _buildHeader(),
        // **靠左不居中**：库的 `_ToolbarLayout` 在 `centerTitle: true`（默认）时
        // 按整条宽度居中、并把可用宽压成 `size.width - 2 * max(leading, actions)`——
        // 本页标题是两行头部，居中收缩会破坏「全宽搜索胶囊 + 铺满 chips 行」形态。
        centerTitle: false,
        // 高度**恒取两行**：搜索态由头部自己把胶囊行收成 0 高（[AnimatedSize]），
        // 顶栏高度若跟着突变，转场第一帧整条栏会跳一下。
        toolbarHeight: kShelfHeaderHeight,
      ),
      body: OpaqueContentSurface(
        child: DecoratedBox(
          decoration: shelfGradientBackground(theme),
          child: _loading
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

  /// 浮动头部（两行，参考图形态）：搜索行（胶囊 + 排序）+ 分组标签行。
  /// 导入按钮在底栏**绿圆钮**（`HomeShell` 经 GlobalKey 调 [pickAndImport]），
  /// 搜索行原「+」按钮移除；导入进行中在原槽位显示进度圈（只是状态指示）。
  /// 整体包一层透明 [Material]：右侧动作按钮（排序）是 Material [IconButton]
  /// （水波纹与文字样式要求最近处有 Material）；搜索胶囊是玻璃控件（[GlassButton]）、
  /// 分组标签行是 [AdaptivePillTabBar] 纯色胶囊，都不需要 Material
  /// （`MaterialType.transparency` 不绘制底色，不破坏玻璃观感）。
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
                // 搜索胶囊铺满剩余宽（「全宽」形态）；亮边进度随滚动下发。
                Expanded(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _headerRim,
                    builder: (BuildContext context, double rim, _) =>
                        _BookSearchEntry(
                      onTap: _enterSearch,
                      mode: mode,
                      rimProgress: rim,
                    ),
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
                // 搜索行右侧的**排序按钮移除**（顶部只留搜索栏 + 胶囊行）。
                // 排序逻辑与菜单 [_showSortMenu] 原样保留，入口暂缺——挂账待定，
                // 确定落点后直接接回，不必重写。
              ],
            ),
          ),
          // 胶囊分类行（浮动头部第二行）：搜索已改为推入独立搜索页，本页不再有
          // 「搜索态收高」这条分支——头部两行恒在场，高度恒定（`kShelfHeaderHeight`）。
          Padding(
            padding: const EdgeInsets.only(top: kShelfHeaderRowGap),
            child: SizedBox(
              height: kShelfChipsRowHeight,
              child: ValueListenableBuilder<double>(
                valueListenable: _headerRim,
                builder: (BuildContext context, double rim, _) =>
                    _buildGroupFilterBar(rimProgress: rim),
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
  /// GlassChip 行 → [MiPillTabBar] **自适应宽档**（`MiPillItemWidth.adaptive`，
  /// min 87.6 / max 175.2 / 超出省略号；上游 issue #3 原生支持后本页克隆组件
  /// `AdaptivePillTabBar` 退场，直接用移植体）
  /// ══════════════════════════════════════════════════════════════════════════════
  /// · 标签 = 「全部」+ 各分组名，横向可滚（组件内置滚动容器）；
  /// · 「全部」恒在首位；分组顺序 = `ShelfLayoutStore` 的创建序（`groups` 列表序）；
  ///   只列**真有书**的分组：空分组已由 `prune` 清掉，故此处无需再过滤；
  /// · 交互语义保持书架既有拍板：**单选 + 再点已选中的回「全部」**（组件是纯
  ///   标签行、无「再点取消」语义，由 [onTap] 映射承担）；
  /// · 明暗：[MiThemeMode] 按 `GlassScope` 级联亮度解析（同底栏 [navThemeModeOf]）。
  ///
  /// 对齐：组件自带 [MiPillTabMetrics.edgeInset]（11.9），而本页头部由顶栏槽给
  /// 8dp 内边距、左缘须与搜索胶囊对齐——故把组件盒**放宽 2×11.9 并居中**
  /// （`OverflowBox` + `Alignment.topCenter`）：内置内嵌正好抵消到槽边，胶囊左缘
  /// = 槽左缘 = 搜索胶囊左缘；外层 [ClipRect] 保住「超出视口裁切滚动」的形态。
  /// 行高由 [_buildHeader] 的 `SizedBox(kShelfChipsRowHeight)`（40）给定。
  Widget _buildGroupFilterBar({double rimProgress = 1.0}) {
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
            child: MiPillTabBar(
              // 自适应宽档（上游 issue #3）：分组名长短不一，定宽档读不全。
              itemWidthMode: MiPillItemWidth.adaptive,
              labels: <String>[
                '全部',
                for (final BookGroup group in groups) group.name,
              ],
              selectedIndex: selectedIndex,
              themeMode: navThemeModeOf(context),
              // 内缘亮边随滚动渐亮（映射同 `MiTopBarMetrics.rimFadeDistance`）。
              rimProgress: rimProgress,
              // 书卡从头部下方穿过（压在内容上）：未选胶囊要垫那层玻璃膜，
              // 否则在杂乱封面上只剩文字可辨、读不出胶囊形状。
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
  /// **当前无 UI 入口**（搜索行右侧的排序按钮移除，顶部只留「搜索栏 + 胶囊行」）。
  /// 排序**功能与偏好照旧完整保留**——字段 / 方向仍在 `ShelfPrefsStore` 生效、
  /// `_visibleBooks` 照旧读它；入口暂缺、挂账待定（候选：胶囊行末尾的排序胶囊 /
  /// 设置页书架分组）。定案后直接给某个按钮接上 `onPressed: _showSortMenu` 即可。
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

  /// 有书：网格展示（分组筛选 / 排序已在外层应用）。网格**不含任何交互**
  /// （拖拽 / 文件夹卡随拍板移除），本页只把「点击直接开书」「长按弹操作弹框」
  /// 两个回调接上。[topInset] = 状态栏高；网格 `padding.top` 经 [shelfGridPadding]
  /// 合成后 = `状态栏 + 浮动头部高 + 12`——**首行不被浮动头部盖住**的唯一保证
  /// （内容 edge-to-edge 后正文从 y=0 起）。[books] 默认 [_visibleBooks]
  /// （搜索在独立页里做，本页恒为全量视图）。
  Widget _buildBookGrid(double topInset, {List<BookRecord>? books}) {
    const double headerHeight = kShelfHeaderHeight;
    return Stack(
      children: <Widget>[
        ShelfGrid(
          books: books ?? _visibleBooks,
          coverStore: widget.coverStore,
          padding: shelfGridPadding(topInset, headerHeight: headerHeight),
          // 滚动位移 → 头部亮边进度（`_syncHeaderRim` → `_headerRim`）。
          controller: _gridScrollController,
          // 点书卡 = **直接进阅读页**；详情页入口走长按弹框「书籍详情」。
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
          child: _buildHeaderBlur(topInset, headerHeight, navThemeModeOf(context)),
        ),
      ],
    );
  }

  /// 头部区磨砂：**头部区实测渐进曲线**（与上游 `81d2f86` 同源，
  /// `MiHeaderBlurProfile`）—— 平台段 8.5dp 线性衰减、胶囊行底后羽化收尾，
  /// 铺满「状态栏 + 头部」、盒底归零（不再是旧的「恒定 σ + 栏底硬切」——
  /// 那出自 884×1920 低清素材，压缩软化下不可分辨渐变；1220×2656 原生素材
  /// 逐深度 erf 拟合给出 7.6…9.0 / 3.2…4.4 / ≈0.4dp）。
  ///
  /// 分段定 σ 阶梯由 `MiTopBar.headerBlurBands` 给出（σ 已量化 0.05 档护
  /// `MiFilterCache`；本页头部静止呈现，直接按满档铺）。
  Widget _buildHeaderBlur(
    double topInset,
    double headerHeight,
    MiThemeMode mode,
  ) {
    final double extent = topInset + headerHeight;
    final List<MiTopBarBlurBand> bands = MiTopBar.headerBlurBands(
      MiTopBarPalette.of(mode),
      extent: extent,
      // 头部压在滚动内容上、无叠色实心段可省 → 全段铺出，盒底羽化归零。
      underSurface: false,
    );
    return ClipRect(
      // 定位键：契约测试按它数分段高斯层数（`shelf_page_test`）。
      key: const ValueKey<String>('shelf-header-blur'),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          for (final MiTopBarBlurBand band in bands)
            Positioned(
              left: 0,
              right: 0,
              top: band.top,
              height: band.height,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: band.sigma,
                    sigmaY: band.sigma,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
        ],
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

/// 顶栏里的搜索栏（上游 [MiSearchBar]，1:1 实测自小米主题商店分类页：stadium
/// 高 44.1、图标 17.8 + 图文间距 12 起于左缘 15.4、占位文字 CJK 16.5dp）。
///
/// **靠左铺满而非居中收缩**：调用方须传 `centerTitle: false`（见 `build`）。
/// 居中档下库会把可用宽压成 `width - 2 * max(两侧)`，搜索态还要让位给取消钮，
/// 搜索框就只剩半宽且浮在中间——不是搜索框该有的样子。材质配方走组件自身的
/// `search_bar_tokens`，不引 `GlassMaterial.settingsFor`（`UI-07`「材质单一出处」
/// 精神）。几何契约不变：靠左贴顶栏内边距、铺满可用宽（`shelf-search-entry` 断言）。
///
/// ══════════════════════════════════════════════════════════════════════════════
/// 接**搜索态**与**玻璃膜**
/// ══════════════════════════════════════════════════════════════════════════════
///  * [searching] = true 时同一个组件换成真输入框（`editable`）：几何 / 配色
///    不变，光标 + hint 同现，聚焦即弹键盘。进入靠 `autofocus`，退出由父级
///    `unfocus` + 换回非编辑态一起收键盘；
///  * [overContent] 恒开：书卡从头部下方穿过（压在高频封面上），只留平底页
///    那档半透明填充时整条栏会糊成一片、边缘读不出来。
///
/// 明暗经 [navThemeModeOf] 显式传入（与底栏 / 胶囊标签同一 `GlassScope` 出处，
/// `UI-01` ② 跟应用主题三态），而非留给组件回落环境 `Theme.of`。
class _BookSearchEntry extends StatelessWidget {
  const _BookSearchEntry({
    required this.onTap,
    required this.mode,
    this.rimProgress = 1.0,
  });

  /// 点击回调（推入搜索页）。
  final VoidCallback onTap;

  /// 明暗配方（父级已解析，避免两次查 `GlassScope`）。
  final MiThemeMode mode;

  /// 内缘亮边进度（0…1，父级按网格滚动位移下发；语义见
  /// `MiTopBarMetrics.rimFadeDistance`）。
  final double rimProgress;

  @override
  Widget build(BuildContext context) {
    return MiSearchBar(
      // 供契约测试定位（`test/ui/shelf_page_test.dart` 断言「靠左铺满 +
      // MiSearchBar 材质」）。
      key: const Key('shelf-search-entry'),
      hint: '搜索书名、作者',
      onTap: onTap,
      themeMode: mode,
      // 零件**始终自绘玻璃**（上游 `81d2f86` 实机反馈口径）：头部那层是随 y
      // 衰减的背景磨砂（`_buildHeaderBlur` 的渐进曲线），零件自己那层才是
      // 它的「透明模糊属性」——旧口径（顶栏画磨砂时关零件 backdrop）会让
      // 胶囊像不透明色块。
      frosted: true,
      // 压在书卡上：垫玻璃膜（膜取页底色 ⇒ 静止态观感不变）
      overContent: true,
      rimProgress: rimProgress,
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

