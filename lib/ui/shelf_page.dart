// `LIB-01`：书架首页（替代 M0 验证台的 `HomePage`）。
//
// 要点：
//   · 空态 = 引导文案 + 导入按钮；有书 = 浮动头部（全宽玻璃搜索胶囊 + 分组 chips）
//     + 网格 [BookCard]（封面缩略图 + 书名 + 作者·进度）；
//   · 内容 edge-to-edge（`extendBody: true`）从头部下穿过、透出磨砂模糊（`UI-02` ②）；
//     首行保护 = 网格 `padding.top` 留出头部高（[shelfGridPadding]）；
//   · 导入 = `FilePicker` 多选 → 逐个 `importFile`（进度 + 失败清单）；删除 = 长按书卡
//     → 长按弹框 → 删除确认框（均 mi_like_ui `MiDialog`）→ `deleteBook`（`LIB-06`
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
import 'dart:io' show Platform;

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
import '../tts/online_tts.dart';
import '../tts/tts_settings.dart';
import 'book_card.dart';
import 'book_detail_page.dart';
import 'glass_kit.dart';
import 'glass_nav_host.dart' show navThemeModeOf;
import 'home_shell.dart' show kShellBottomInset;
import 'mi_like_ui/mi_like_ui.dart'
    show
        MiColors,
        MiDialog,
        MiDialogAction,
        MiDialogActionStyle,
        MiDialogItem,
        MiDialogLayout,
        MiFilterCache,
        MiPillItemWidth,
        MiPillTabBar,
        MiPillTabMetrics,
        MiSearchBar,
        MiSearchCancelButton,
        MiSearchCancelMetrics,
        MiSnackbar,
        MiThemeMode,
        MiTopBar,
        MiTopBarBlurBand,
        MiTopBarMetrics,
        MiTopBarPalette;
import 'scroll_sigma.dart';
import 'shelf_grid.dart';

/// 「添加图书」文件选择器的参数（唯一事实源；`home_shell_test` 直接钉两种平台）。
///
/// ⚠️ **移动端必须 `FileType.any` + `allowedExtensions == null`**：file_picker
/// 的 Android 端把扩展名经 `MimeTypeMap` 转 MIME、iOS 端转 UTType，解析不出
/// 的（`azw3` / `cbz` 等）会被静默跳过或生成 `dyn.*` 动态 UTI ⇒ 文件在系统
/// 选择器里**根本不可选**（真机实录）。桌面三平台是字符串过滤，
/// `kImportExtensions` 有效 ⇒ 保留后缀白名单。
///
/// 移动端放开后格式判定完全交 `sniffFormat`（魔数优先 + 后缀兜底），选错文件
/// 给可读报错，不会静默吞掉。⚠️ `FileType.any` 时**不能**传非空
/// `allowedExtensions`（`file_picker_io.dart` 会直接抛异常）。
///
/// [mobile] 仅供测试注入；不传时按真实平台判定（Web 工程已删，五平台均可用
/// `dart:io`，口径同 `lib/platform/audio_service.dart`）。
({FileType type, List<String>? allowedExtensions}) importPickerOptions({
  bool? mobile,
}) {
  final bool isMobile = mobile ?? (Platform.isAndroid || Platform.isIOS);
  return isMobile
      ? (type: FileType.any, allowedExtensions: null)
      : (type: FileType.custom, allowedExtensions: kImportExtensions);
}

/// 排序字段的中文名（唯一事实源：书架「更多」菜单的排序级联列表用它，
/// 菜单本身在壳层 `home_shell.dart` —— 排序偏好与文案都归书架层）。
String shelfSortLabel(ShelfSortField field) => switch (field) {
      ShelfSortField.importedAt => '导入时间',
      ShelfSortField.lastReadAt => '最近阅读',
      ShelfSortField.title => '书名',
      ShelfSortField.author => '作者',
      ShelfSortField.manual => '手动排序',
    };

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
    this.onSearchActiveChanged,
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

  /// 搜索态进出通知（上游分类页 `onSearchActiveChanged` 同款）：壳层据此
  /// **卸掉浮动底栏 / 侧栏**——搜索态照参考素材是「整屏无 App 级导航」。
  final ValueChanged<bool>? onSearchActiveChanged;

  @override
  State<ShelfPage> createState() => ShelfPageState();
}

/// [ShelfPage] 的状态类（公开：`HomeShell` 经 [GlobalKey] 把底栏「更多」菜单
/// 的「添加图书」项接到 [pickAndImport]）。
class ShelfPageState extends State<ShelfPage>
    with SingleTickerProviderStateMixin {
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

  /// 头部磨砂的 σ 缩放（滚动速度 → 0.6…1.0，见 [ScrollSigma]）：运动时降档、
  /// 停稳回满档，避免每帧按满档 9 段铺全宽高斯。
  final ScrollSigma _headerSigma = ScrollSigma();

  /// 详情页路由在栈上（push 已发起、尚未 pop）：吞掉过渡期 / 会话期的重复点卡，
  /// 防「双击卡片 → 叠两个详情页」。pop 后由 [_openDetail] 的 `finally` 释放。
  bool _detailPushing = false;

  // ── 就地搜索态（上游「分类页」路径）────────────────────────────────────
  //
  // 点搜索栏**不换页**：搜索胶囊原地变成真输入框、右缘让位给取消钮、分组
  // 胶囊行淡出并退出排版、书架内容让位给结果；壳层同时卸掉浮动底栏
  // （[ShelfPage.onSearchActiveChanged]）——参考素材里搜索态是整屏无 App 级
  // 导航的，底栏不卸就成了「就地展开 + 底栏还在」的半成品。
  //
  // 转场口径与上游 `MiTopBar` 搜索态同一套（进入 180ms / 退出 150ms，退出走
  // 独立的 `searchExitMotion`——把进入曲线直接反向播会把「快起慢停」翻成
  // 「慢起快停」）。

  /// 是否处于搜索态（点搜索栏进入，点取消钮 / 系统返回退出）。
  bool _searching = false;

  /// 当前查询串（已 trim、已小写）。
  String _query = '';

  /// 搜索输入控制器 / 焦点：由页面持有，退出搜索态时能主动 `unfocus` 收键盘。
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 搜索态进度（0 = 常规态，1 = 搜索态）。
  late final AnimationController _searchAnim;

  /// 是否正在**退出**搜索态——方向决定用哪条曲线（见 [_searchProgress]）。
  bool _exitingSearch = false;

  /// 点搜索结果开书后冻结键盘响应（见 [_openSearchResult]）：
  /// 键盘收起动画期间 body 不得逐帧变高。
  bool _openingFrozen = false;

  /// 进入搜索态：不换页，只切状态。
  void _enterSearch() {
    if (_searching) return;
    _exitingSearch = false;
    setState(() => _searching = true);
    _searchAnim.forward();
    widget.onSearchActiveChanged?.call(true);
  }

  /// 退出搜索态：先收键盘再清查询（顺序反了会在列表重建后弹一次键盘）。
  void _exitSearch() {
    if (!_searching) return;
    _searchFocus.unfocus();
    _searchController.clear();
    _exitingSearch = true;
    setState(() {
      _searching = false;
      _query = '';
    });
    _searchAnim.reverse();
    widget.onSearchActiveChanged?.call(false);
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

  /// 点搜索结果开书：**先收键盘再开书**，并冻结键盘响应。
  ///
  /// 键盘收起动画与开书转场叠加会丢帧：收起期间 body 若继续跟随 `viewInsets`
  /// 逐帧变高，结果网格会逐帧重排（外因改排版区）。冻结只在点书这一刻开始，
  /// 打字时照常随键盘适配。
  void _openSearchResult(BookRecord record) {
    _searchFocus.unfocus();
    setState(() => _openingFrozen = true);
    unawaited(_openBook(record).whenComplete(() {
      if (mounted) setState(() => _openingFrozen = false);
    }));
  }

  /// 当前帧的两条进度，口径同上游 `_MiTopBarState`：
  ///
  ///  * `t` = **几何位移**进度（缓动后）：进入走 [MiTopBarMetrics.searchMotion]
  ///    （前 5% 静止 + easeOutQuint），退出走 [MiTopBarMetrics.searchExitMotion]
  ///    作用于「退出已过时间」并取补 —— 两向都是快起慢停；
  ///  * `visible` = **搜索态**可见度：进入收进前 70%
  ///    （[MiTopBarMetrics.searchFadeInterval]），退出随 `t` 一起走。
  ///    搜索态零件（取消钮）直接用它，常规内容（分组胶囊行）取 `1 - visible`。
  ({double t, double visible}) _searchProgress() {
    final double p = _searchAnim.value.clamp(0.0, 1.0);
    if (_exitingSearch) {
      final double back = MiTopBarMetrics.searchExitMotion
          .transform(1 - p)
          .clamp(0.0, 1.0);
      return (t: 1 - back, visible: 1 - back);
    }
    return (
      t: MiTopBarMetrics.searchMotion.transform(p).clamp(0.0, 1.0),
      visible:
          MiTopBarMetrics.searchFadeInterval.transform(p).clamp(0.0, 1.0),
    );
  }

  @override
  void initState() {
    super.initState();
    // 筛选 / 排序偏好与书架布局（手动顺序 + 文件夹）一变即重绘
    // （两者都是进程内共享实例，见 [ShelfPrefsStore] / [ShelfLayoutStore]）。
    widget.shelfPrefs.addListener(_onStoreChanged);
    widget.shelfLayout.addListener(_onStoreChanged);
    _gridScrollController.addListener(_syncHeaderRim);
    _headerSigma.attach(_gridScrollController);
    _searchAnim = AnimationController(
      vsync: this,
      duration:
          const Duration(milliseconds: MiTopBarMetrics.searchTransitionMs),
      reverseDuration:
          const Duration(milliseconds: MiTopBarMetrics.searchExitMs),
    );
    _loadBooks();
  }

  @override
  void dispose() {
    widget.shelfPrefs.removeListener(_onStoreChanged);
    widget.shelfLayout.removeListener(_onStoreChanged);
    _gridScrollController.removeListener(_syncHeaderRim);
    _headerSigma.dispose();
    _gridScrollController.dispose();
    _headerRim.dispose();
    // 页被换掉（切 tab）时若还在搜索态，要让壳层把底栏装回来。
    if (_searching) widget.onSearchActiveChanged?.call(false);
    _searchAnim.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
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
    // （拖拽重排已删，此分支仅消费旧数据 + 「更多」菜单里的排序入口）。
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

  /// 导入书籍入口（`FilePicker` 多选 → 逐个 `importFile`）。由底栏绿圆钮的
  /// 「更多」菜单「添加图书」项触发（`HomeShell` 经 GlobalKey 调本方法，
  /// 原顶部加号按钮已移除）；空态引导按钮仍调本方法（`LIB-01` ②）。
  Future<void> pickAndImport() async {
    setState(() {
      _importErrors = <String>[];
    });

    final ({FileType type, List<String>? allowedExtensions}) options =
        importPickerOptions();
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: options.type,
      allowedExtensions: options.allowedExtensions,
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
      // 轻提示走 [MiSnackbar]（经壳层 `MiPopupHost` 投放）：壳层无 Material
      // `Scaffold`，`ScaffoldMessenger.showSnackBar` 会断言失败。
      // 导入摘要信息量大，保留 3s 常驻（snackbar 默认 2.5s）。
      MiSnackbar.show(
        context,
        message: msg,
        duration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _deleteBook(BookRecord record) async {
    // 二次确认（`LIB-06`）走 mi_like_ui [MiDialog] 按钮形态，与上一层长按
    // 操作弹框同一套遮罩 / 明暗口径（[navThemeModeOf]）；弹框不是玻璃件，
    // 玻璃开 / 关两档同形。点遮罩 / 系统返回都返回 null ⇒ 非 `true` 一律不删。
    // ⚠️ 路由遮罩必须透明：遮罩由 MiDialog 自绘，两层不可叠加。
    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (BuildContext dialogContext) => MiDialog(
        title: '删除确认',
        message: '确定删除「${record.title}」？\n删除后书架不再列出，封面文件一并清理。',
        themeMode: navThemeModeOf(context),
        actions: <MiDialogAction>[
          MiDialogAction(
            label: '取消',
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          MiDialogAction(
            label: '删除',
            style: MiDialogActionStyle.destructive,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
        onScrimTap: () => Navigator.of(dialogContext).pop(),
      ),
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
    // **一整张纸从右侧滑入**铺满（320ms、easeOutCubic、70dp 圆角），书架静止在后
    // 被压暗。延迟路径下骨架屏首帧即放行（见 `ReaderPage._open`），用户点下即见
    // 纸张滑入，而非在书架上等待。
    final ReaderOpenRoute route = ReaderOpenRoute(
      // 退场起步即释放守卫：纸张右移滑出的 240ms 里书架已可点，守卫晚放到
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
        openTrace: trace,
        coverStore: widget.coverStore, // 骨架幕布显示本书封面（`_CoverSkeleton`）
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
  // 本页仅剩导入结果一处轻提示，直接调 [MiSnackbar.show]。

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double topInset = MediaQuery.paddingOf(context).top;

    // 壳换 mi_like：顶栏走 [MiTopBar] header 槽、页底 Mi 页底色；
    // 内容整体不透明（`UI-04`，[OpaqueContentSurface] 承载渐变正文不变）。
    //
    // 浮动头部（参考图 = HyperOS 主题商店首页「搜索条 + 分类 chips 压在内容上」）：
    // 搜索胶囊 + 分组 chips 两行；正文 `extendBody: true` 铺满全屏、从头部下穿过，
    // 顶栏下方内容透出磨砂模糊（`UI-02` ②）。首行保护 = 网格 `padding.top` 留出
    // 头部高度（见 [shelfGridPadding]）。**头部两行恒在场**（含 loading / 空态），
    // 避免「加载中 → 有书」头部高度跳变。
    //
    // 搜索态走**就地展开**（上游分类页路径）：头部胶囊行退出排版、顶栏高度跟随
    // 收窄，正文换成搜索结果；`extendBody: true` 下正文铺满全屏（不因顶栏变高变矮
    // 重排），故把 [AnimatedBuilder] 放在壳层外面、正文用 `child` 缓存——每帧只重建
    // 顶栏描述，书架网格 / 结果网格的 Element 不重建。
    final Widget content = OpaqueContentSurface(
      child: DecoratedBox(
        decoration: shelfGradientBackground(theme),
        child: _searching
            ? _buildSearchArea(theme, topInset)
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
    );

    // 搜索态吞掉系统返回：先退出搜索态，而不是退出应用（移动端返回手势）。
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _exitSearch();
      },
      child: AnimatedBuilder(
        animation: _searchAnim,
        builder: (BuildContext context, Widget? body) {
          final (:double t, :double visible) = _searchProgress();
          final double toolbarHeight = kShelfSearchRowHeight +
              (1 - t) * (kShelfHeaderRowGap + kShelfChipsRowHeight);
          final MiThemeMode mode = navThemeModeOf(context);
          // 壳换 mi_like（`settings_page` 同款）：页底 Mi 页底色 + 钉顶
          // [MiTopBar]；两行浮动头部走 **header 槽**（「材质 + 头部」形态，
          // 无大标题）。原 `extendBody: true` 的「正文穿顶栏」语义由
          // `Positioned.fill` 承担（正文从 y=0 起、网格 padding 让位不变）。
          return ColoredBox(
            color: MiColors.pageBackgroundFor(mode),
            child: Material(
              type: MaterialType.transparency,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(child: body!),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: MiTopBar(
                      // 高度每帧随搜索态进度插值（原 `toolbarHeight` 等价：
                      // 搜索态胶囊行退出排版 → 顶栏收窄）。
                      header: _ShelfHeaderBar(
                        height: toolbarHeight,
                        child: _buildHeader(t: t, visible: visible),
                      ),
                      // 让位 = 状态栏高（原 AppBar = 状态栏 + toolbarHeight
                      // 同口径；桌面 / 测试 padding=0 → 0，无悬空带）。
                      headerTopInset: MediaQuery.paddingOf(context).top,
                      showBlur: true,
                      showSurface: false, // 头部区不压色（同原玻璃顶栏）
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        child: content,
      ),
    );
  }


  /// 搜索态正文外壳：打字期间照常随键盘适配，点书后冻结（见 [_openingFrozen]）。
  Widget _buildSearchArea(ThemeData theme, double topInset) {
    final Widget body = _buildSearchBody(theme, topInset);
    return _openingFrozen
        ? MediaQuery.removeViewInsets(
            context: context,
            removeBottom: true,
            child: body,
          )
        : body;
  }

  /// 搜索态正文：未输入 → 引导；无命中 → 提示；有结果 → **同一套书卡网格**。
  ///
  /// 复用 [_buildBookGrid] 而不是另写结果列表：点结果与点书架书卡必须是同一个
  /// 手势结果（「同一手势一种结果」），复用能天然保证这点。
  Widget _buildSearchBody(ThemeData theme, double topInset) {
    if (_query.isEmpty) return _buildSearchHint(theme);
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
    return _buildBookGrid(topInset, books: results, onOpenBook: _openSearchResult);
  }

  /// 搜索态未输入时的引导。
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

  /// 浮动头部（两行，参考图形态）：搜索行（胶囊）+ 分组标签行。
  /// 导入 / 排序入口都在底栏**绿圆钮**（竖点「更多」→ `MiMenu`，见
  /// `home_shell.dart`）：搜索行原「+」与排序按钮均已移除；导入进行中在
  /// 原「+」槽位显示进度圈（只是状态指示）。
  /// 整体包一层透明 [Material]：搜索胶囊是玻璃控件（[GlassButton]）、
  /// 分组标签行是 [MiPillTabBar] 纯色胶囊，本不需要 Material；保留这层是给
  /// 后续可能回到头部的 Material 控件留好主题（`MaterialType.transparency`
  /// 不绘制底色，不破坏玻璃观感）。
  /// [t] = 几何位移进度（缓动后），[visible] = **搜索态**可见度（淡出类用；
  /// 常规内容取 `1 - visible`）—— 两条都由 [_searchProgress] 按方向算好传入
  /// （进入走 `searchMotion` / `searchFadeInterval`，退出走 `searchExitMotion`）。
  Widget _buildHeader({required double t, required double visible}) {
    final MiThemeMode mode = navThemeModeOf(context);
    // 取消钮让位宽度：间隙 10.0 + 直径 44.1（上游 `MiSearchCancelMetrics`）。
    const double cancelExtent = MiSearchCancelMetrics.barGap +
        MiSearchCancelMetrics.diameter;
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
                // 搜索胶囊铺满剩余宽（「全宽」形态）；搜索态由右侧取消钮
                // （宽度随 t 展开）挤出让位，右缘因此平滑左移。
                Expanded(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _headerRim,
                    builder: (BuildContext context, double rim, _) =>
                        _BookSearchEntry(
                      onTap: _enterSearch,
                      searching: _searching,
                      controller: _searchController,
                      focusNode: _searchFocus,
                      onChanged: _onQueryChanged,
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
                // 头部不再有排序按钮（排序入口收进底栏「更多」菜单），
                // 搜索行只留「搜索栏 + 取消钮」。
                //
                // 取消钮：占位宽随 t 展开、颜色按 visible 淡入（`fade` 乘进各层
                // alpha —— 圆钮内含 backdrop 磨砂，套 `Opacity` 会让磨砂整段消失）。
                if (t > 0)
                  SizedBox(
                    width: t * cancelExtent,
                    child: OverflowBox(
                      alignment: Alignment.centerRight,
                      minWidth: MiSearchCancelMetrics.diameter,
                      maxWidth: MiSearchCancelMetrics.diameter,
                      minHeight: kShelfSearchRowHeight,
                      maxHeight: kShelfSearchRowHeight,
                      child: MiSearchCancelButton(
                        onTap: _exitSearch,
                        themeMode: mode,
                        // 头部已有自己的磨砂层（见 [_buildHeaderBlur]），零件
                        // 不再自绘 backdrop；膜照开（书卡从头部下方穿过）。
                        frosted: false,
                        overContent: true,
                        fade: visible,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 胶囊分类行：搜索态淡出并**退出排版**（高度随 t 收 0）——顶栏高度
          // 同步收窄（见 `build`），搜索栏因此更靠近状态栏。
          SizedBox(
            height: (1 - t) * (kShelfHeaderRowGap + kShelfChipsRowHeight),
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: kShelfHeaderRowGap + kShelfChipsRowHeight,
                maxHeight: kShelfHeaderRowGap + kShelfChipsRowHeight,
                child: Padding(
                  padding: const EdgeInsets.only(top: kShelfHeaderRowGap),
                  child: SizedBox(
                    height: kShelfChipsRowHeight,
                    child: ValueListenableBuilder<double>(
                      valueListenable: _headerRim,
                      builder: (BuildContext context, double rim, _) =>
                          // ⚠️ `visible` 是**搜索态**可见度：常规内容（胶囊行）要取
                          // `1 - visible`——直接用它会让胶囊行在常规态 alpha 归零
                          // （整条分组胶囊行消失）。
                          _buildGroupFilterBar(
                            rimProgress: rim,
                            fade: 1 - visible,
                          ),
                    ),
                  ),
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
  Widget _buildGroupFilterBar({
    double rimProgress = 1.0,
    double fade = 1.0,
  }) {
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
              // 搜索态淡出（系数乘进各处 alpha，不套 `Opacity`——胶囊行内含
              // backdrop 磨砂，saveLayer 会让磨砂整段消失）。
              fade: fade,
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
  /// （内容 edge-to-edge 后正文从 y=0 起）。[books] 默认 [_visibleBooks]；
  /// 搜索态传命中结果（同一套书卡网格，保证「点结果」与「点书架书卡」是同一
  /// 手势结果）。
  Widget _buildBookGrid(
    double topInset, {
    List<BookRecord>? books,
    ValueChanged<BookRecord>? onOpenBook,
  }) {
    // 搜索态胶囊行退出排版 → 头部只剩搜索行，顶部留白与磨砂跟随缩短。
    final double headerHeight =
        _searching ? kShelfSearchRowHeight : kShelfHeaderHeight;
    return Stack(
      children: <Widget>[
        ShelfGrid(
          books: books ?? _visibleBooks,
          coverStore: widget.coverStore,
          padding: shelfGridPadding(topInset, headerHeight: headerHeight),
          // 滚动位移 → 头部亮边进度（`_syncHeaderRim` → `_headerRim`）。
          controller: _gridScrollController,
          // 点书卡 = **直接进阅读页**；详情页入口走长按弹框「书籍详情」。
          // 搜索态传 [_openSearchResult]（先收键盘 + 冻结布局）。
          onOpenBook: onOpenBook ??
              (BookRecord record) => unawaited(_openBook(record)),
          // 不 `unawaited`：这个 Future 的完成时机**就是**长按抬起反馈的复位时机
          // （见 `_showBookActions` 的返回值语义）。
          onBookActions: _showBookActions,
        ),
        // 头部区磨砂（`UI-02` ②）。叠在列表**之后**（同 Stack）才采样得到滚动
        // 内容；`IgnorePointer` 不吃手势，不影响点卡 / 长按。
        //
        // 只包模糊层：σ 换档时重建它是必要的，但不应连带网格与头部零件。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topInset + headerHeight,
          child: ValueListenableBuilder<double>(
            valueListenable: _headerSigma,
            builder: (BuildContext context, double sigmaScale, _) =>
                _buildHeaderBlur(
              topInset,
              headerHeight,
              navThemeModeOf(context),
              sigmaScale: sigmaScale,
            ),
          ),
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
  /// [MiFilterCache]）。
  ///
  /// ⚠️ 头部 widget 静止**不等于**磨砂静止：backdrop 是下面滚动的网格，每帧
  /// 都要重算这 9 段全宽 `BackdropFilter`。两处护栏缺一不可：
  ///  * 滤镜实例走 [MiFilterCache]（同上游 `MiTopBar._uniformBands` /
  ///    `MiGradientBlur`），否则每次重建都会新建 native filter 对象；
  ///  * [sigmaScale] 由滚动速度下发（[ScrollSigma]）：运动中 σ 压到 0.6、
  ///    `headerBlurBands` 随之合并成 3 段，停稳回满档 9 段 —— 上游首页能跑满
  ///    高刷靠的就是这条，满档常驻会把每帧全宽高斯放大到 3~5 倍。
  Widget _buildHeaderBlur(
    double topInset,
    double headerHeight,
    MiThemeMode mode, {
    double sigmaScale = 1.0,
  }) {
    final double extent = topInset + headerHeight;
    final List<MiTopBarBlurBand> bands = MiTopBar.headerBlurBands(
      MiTopBarPalette.of(mode),
      extent: extent,
      // 头部压在滚动内容上、无叠色实心段可省 → 全段铺出，盒底羽化归零。
      underSurface: false,
      sigmaScale: sigmaScale,
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
                  filter: MiFilterCache.blur(band.sigma),
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
    this.searching = false,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.rimProgress = 1.0,
  });

  /// 常规态点击回调（进入搜索态）。
  final VoidCallback onTap;

  /// 明暗配方（父级已解析，避免两次查 `GlassScope`）。
  final MiThemeMode mode;

  /// 是否处于搜索态（真输入框）。
  final bool searching;

  /// 搜索输入控制器 / 焦点（页面持有，退出时能主动 `unfocus` 收键盘）。
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// 输入变化回调。
  final ValueChanged<String>? onChanged;

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
      // 搜索态：同一几何换成真输入框，聚焦即弹键盘（`autofocus` 同上游）。
      editable: searching,
      controller: controller,
      focusNode: focusNode,
      autofocus: searching,
      onChanged: onChanged,
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

/// 书架浮动头部的 [MiTopBar.header] 槽载体：高度 = 顶栏内容区高
/// （搜索行 + 收拢的 chips 行），随搜索态进度每帧插值
/// （原 `GlassTopBar.toolbarHeight` 等价物）。
class _ShelfHeaderBar extends StatelessWidget implements PreferredSizeWidget {
  const _ShelfHeaderBar({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: height, width: double.infinity, child: child);
}
