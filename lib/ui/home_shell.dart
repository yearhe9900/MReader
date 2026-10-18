// 应用主壳层：三 tab（书架 / 笔记 / 我的）+ mi_like_ui 玻璃浮动底栏 + 绿色圆钮。
//
// ══════════════════════════════════════════════════════════════════════════════
// 结构（2026-09-28 定；参考 anx-reader 的 `page/home_page.dart`）
// ══════════════════════════════════════════════════════════════════════════════
// 外层**不是** Scaffold，而是 `Stack`：子页与底栏叠放，底栏浮在最上层。
// 子页各自持有 [GlassNavScaffold]（含自己的顶栏）——若外层再套一层 Scaffold，
// 就会形成 `GlassScaffold` 嵌套 `GlassScaffold`，直接违反 `UI-04`
// 「玻璃控件不可嵌套」。底栏（[GlassNavHost]）同样脱离 `GlassScaffold` 祖先
// 浮在 Stack 最上层。
//
// 底栏形态 = **mi_like_ui 玻璃悬浮胶囊**（2026-10-15 整组换参考项目
// `D:\WorkBuddy\FlutterTest\bottom_nav_demo`，代码**一比一移植**入
// `lib/ui/mi_like_ui/`，与上游逐字节一致；几何/材质/动效事实源 =
// `MiGlassNavMetrics` / `MiGlassPalette`）。tab = 书架 / 笔记 / 我的，
// 「设置」改名「我的」（图标用参考项目 `SmileyBeretIconPainter`），
// **「统计」移出底栏**、入口收进「我的」页；右侧绿色圆钮（预留空位圆钮）
// 按参考项目还原视觉（选中「书架」时弹出、切走收起），暂不接功能。
// MReader 侧只做档位退化与明暗映射（见 `glass_nav_host.dart`）。
//
// 旧 [FrostedNavBar] / [NavBarStyle]（自磨砂复刻批）已随本批删除。
//
// ══════════════════════════════════════════════════════════════════════════════
// 底部避让
// ══════════════════════════════════════════════════════════════════════════════
// 胶囊是浮层、**不占布局高度**，所以各页的可滚动内容必须自己留出底部空白
// （书架网格 / 设置列表 / 后续统计图表），额度用 [kShellBottomInset]。
// 这与 anx-reader 给 `GridView` 写 `padding: (20, 12, 20, 80)` 是同一件事。
//
// ══════════════════════════════════════════════════════════════════════════════
// 宽屏自适应（2026-10-19 上游平板模式批）
// ══════════════════════════════════════════════════════════════════════════════
// `maxWidth > 600`（`kShellRailBreakpoint`，与上游 `MiBreakpoints.navRail`
// 严格大于口径逐像素同源）改用**玻璃侧边导航栏** [MiGlassSideNavBar]（上游
// `demo_app.dart` 同款双形态：手机/窄窗 = 浮动胶囊底栏、平板/桌面 = 侧栏）。
// 导航条目只有一份（[_navItems]）：底栏与侧栏吃同一份 items，换形态不换语义。
// 布局照上游 demo：页面列让出 [MiGlassSideNavMetrics.gutterWidth]，侧栏贴左上、
// 距左缘 railMargin、**让开状态栏**（`safeTop + railMargin`——edge-to-edge 后
// 侧栏顶就在状态栏那一带，见 T12）。绿圆钮（导入书籍）两种形态共用同一份声明
// （[_buildFab]）：窄窗挂底栏右侧（栏体左移让位）、宽屏挂侧栏栏尾下方。
// 档位退化（`UI-06` ②「关」档 → Material [NavigationRail]）与明暗映射在
// `glass_nav_host.dart` 的 [GlassSideNavHost]。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/provider_store.dart';
import '../ai/rag.dart';
import '../ai/summary_cache.dart';
import '../ai/vocab_store.dart';
import '../library/library_repository.dart';
import '../meta/cover_store.dart';
import '../reader/bookmark_store.dart';
import '../reader/progress_store.dart';
import '../reader/reading_prefs_store.dart';
import '../settings/perf_prefs_store.dart';
import '../settings/settings_store.dart';
import '../settings/shelf_layout_store.dart';
import '../settings/shelf_prefs_store.dart';
import '../stats/stats_service.dart';
import '../sync/sync_config_store.dart';
import '../sync/sync_trigger.dart';
import '../sync/webdav_client.dart';
import '../tts/online_tts.dart';
import '../tts/tts_settings.dart';
import 'glass_kit.dart';
import 'glass_nav_host.dart';
import 'mi_like_ui/mi_like_ui.dart';
import 'notes_page.dart';
import 'nav_icons.dart';
import 'settings_page.dart';
import 'shelf_page.dart';
import 'stats_page.dart';
import 'vocab_page.dart';

/// 浮动底栏为各页内容预留的底部空白。
///
/// 胶囊高 55.4（`MiGlassNavMetrics.barHeight`）+ 底部外边距 24.2（参考项目
/// 实测浮起）≈ 80，+ 安全区与呼吸余量取 **100**。各页把它并入自己滚动容器的
/// `padding.bottom`。
///
/// 2026-10-15 随「底栏整组换参考项目」批更新口径（62/27 → 55.4/24.2），
/// 余量取整不变：各页底部避让测试的期望值不受影响。
const double kShellBottomInset = 100;

/// 宽屏断点（超过则改用侧边导航轨）；与 anx-reader 取值一致。
const double kShellRailBreakpoint = 600;

/// 底栏胶囊距屏底的浮起高度（`MiGlassNavMetrics` 注释「bar bottom sits
/// 24.2 dp above screen bottom」的参考实测值）。
///
/// 从 [MiGlassNavMetrics.barHeight] 同族的实测读数取，**不再在摆放处硬编码
/// 24.2**——上游 `demo_app.dart` 把它与 barHeight 等 token 并列在一处，这里
/// 同样收口成常量，避免散落字面量（改实测口径只改这一行）。
///
/// ⚠️ 手机模式下底栏**浮起量的完整口径**是 `kShellNavBarBottomLift +
/// safeBottom`：`safeBottom` 是 edge-to-edge 后让开的手势条 inset（真机非 0）。
/// 两者缺一，底栏相对屏底的位置就与上游不一致（2026-10-18 反馈「手机模式
/// 底栏高度变了」即此：只取其一都会偏 ~20dp）。
const double kShellNavBarBottomLift = 24.2;

/// 主壳层（底部导航）。
///
/// 依赖全部由组合根（`main.dart`）注入，本层不构造存储 / 仓库。
class HomeShell extends StatefulWidget {
  /// 创建主壳层。
  const HomeShell({
    super.key,
    required this.repository,
    required this.coverStore,
    required this.progressStore,
    required this.perfPrefs,
    required this.shelfPrefs,
    required this.shelfLayout,
    required this.settings,
    required this.statsService,
    required this.aiStore,
    required this.aiClient,
    this.vocabStore,
    this.summaryCache,
    this.ragStore,
    this.ttsSettings,
    this.onlineTts,
    this.syncStore,
    this.syncClient,
    this.bookmarkStore,
    this.readingPrefsStore,
    this.syncTrigger,
  });

  /// 书库仓库（书架页）。
  final LibraryRepository repository;

  /// 封面存储（书架页）。
  final CoverStore coverStore;

  /// 阅读进度存储（书架页 → 阅读页）。
  final ProgressStore progressStore;

  /// 性能偏好（设置页的玻璃档位）。
  final PerfPrefsStore perfPrefs;

  /// 书架视图偏好（筛选 / 排序）。
  final ShelfPrefsStore shelfPrefs;

  /// 书架布局（分组归属 / 手动顺序）。
  final ShelfLayoutStore shelfLayout;

  /// 设置服务（设置页「外观」组的主题三态；同一实例已注入 `MReaderApp`，
  /// 在此**透传**给设置页——写入即由 `app.dart` 重建 `MaterialApp` 换色）。
  final SettingsStore settings;

  /// 统计服务（统计页；`M3-T10`——组合根创建的进程内唯一实例，注入各页共享）。
  final StatsService statsService;

  /// AI 配置存储（设置页 → AI 设置页）。
  final ProviderStore aiStore;

  /// AI 客户端（AI 设置页的测试连接）。
  final AiClient aiClient;

  /// 生词本存储（笔记页入口计数 + 生词本页；`M3-T02`）。
  ///
  /// `null` = 未接线：笔记页回退占位骨架、书架划词禁用（降级口径不变）。
  final VocabStore? vocabStore;

  /// 摘要缓存（阅读页章节/全书摘要与前情回顾，`AI-04`/`AI-05`；`M3-T03`）。
  ///
  /// `null` = 未接线：阅读页摘要入口隐藏（同款降级口径）。
  final SummaryCache? summaryCache;

  /// 问答索引存储（阅读页跟书问答，`AI-06`；`M3-T04`）。
  ///
  /// `null` = 未接线：阅读页问答入口隐藏（同款降级口径）。
  final RagIndexStore? ragStore;

  /// 朗读设置存储（阅读页 `TTS-04`/`TTS-05`；`M3-T08`）。
  ///
  /// `null` = 未接线：阅读页朗读设置入口隐藏（同款降级口径）。
  final TtsSettingsStore? ttsSettings;

  /// 在线 TTS 配置存储（阅读页 `TTS-07`；`M3-T09`）。
  ///
  /// `null` = 未接线：朗读设置面板引擎选择区隐藏、只用系统引擎（同款降级口径）。
  final OnlineTtsStore? onlineTts;

  /// 同步配置存储（设置页「同步备份」组；`M4-T01` `SYNC-01`）。
  ///
  /// `null` = 未接线：设置页同步组整体隐藏（同款降级口径）。
  final SyncConfigStore? syncStore;

  /// WebDAV 客户端（同步设置页测试连接；`M4-T01`）。
  ///
  /// `null` = 未接线（与 [syncStore] 同进同退）。
  final WebdavClient? syncClient;

  /// 书签存储（阅读页；`M2b-T06` 引入、`M4-T05` 才接上生产链路）。
  ///
  /// `null` = 未接线：书签不落库（同款降级口径）。
  final BookmarkStore? bookmarkStore;

  /// 阅读偏好存储（字号/行距等；同 [bookmarkStore] 接线时点）。
  final ReadingPrefsStore? readingPrefsStore;

  /// 同步触发器（`M4-T05` `SYNC-06/07`）：启动拉进度、退页/退出上报 +
  /// 设置页「同步状态与备份」入口。
  ///
  /// `null` = 未接线：无自动触发，状态页入口隐藏。
  final SyncTrigger? syncTrigger;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  /// 书架页句柄：底栏**绿圆钮**的「导入书籍」动作经它转到
  /// [ShelfPageState.pickAndImport]（2026-10-16 功能迁移批）。
  final GlobalKey<ShelfPageState> _shelfKey = GlobalKey<ShelfPageState>();

  /// 当前底栏下标。
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // `SYNC-06`：App 启动 → 仅拉进度（条目/书籍不拉，PRD §10.4）。
    final SyncTrigger? trigger = widget.syncTrigger;
    if (trigger != null) {
      unawaited(trigger.onAppStart());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `SYNC-06`：退到后台/退出 → 上报全部变更 + 备份间隔判定。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final SyncTrigger? trigger = widget.syncTrigger;
      if (trigger != null) {
        unawaited(trigger.onAppExit());
      }
    }
  }

  /// 底栏标签（顺序即下标语义，**勿任意重排**）：书架 / 笔记 / 我的。
  ///
  /// 2026-10-15「底栏整组换参考项目」批（负责人拍板）：
  ///   · **移除「统计」tab**——统计页入口收进「我的」页（`onOpenStats`）；
  ///   · **「设置」改名「我的」**，图标用参考项目 `SmileyBeretIconPainter`；
  ///   · 「书架」「笔记」图标按参考风格新画（`nav_icons.dart`，2026-10-16 随
  ///     参考项目组织更名集中）。
  ///
  /// 图标 painter 的墨色随明暗模式（[MiColors.foregroundFor]）⇒ 在 build 里
  /// 组装，不是常量。
  List<MiGlassNavItem> _navItems(MiThemeMode mode) {
    final Color ink = MiColors.foregroundFor(mode);
    return <MiGlassNavItem>[
      MiGlassNavItem(label: '书架', painter: ShelfBooksIconPainter(ink)),
      MiGlassNavItem(label: '笔记', painter: NotesIconPainter(ink)),
      MiGlassNavItem(label: '我的', painter: SmileyBeretIconPainter(ink)),
    ];
  }

  /// 三个 tab 的内容页。
  ///
  /// 每页**自带** [GlassNavScaffold]（顶栏 + 不透明正文），本壳层只负责
  /// 「选哪一页」与「底栏」。**统计页不在其中**（2026-10-15 移出底栏）——
  /// 入口收进「我的」页（`SettingsPage.onOpenStats`），从那里推入。
  List<Widget> _buildPages() => <Widget>[
    ShelfPage(
      key: _shelfKey,
      repository: widget.repository,
      coverStore: widget.coverStore,
      progressStore: widget.progressStore,
      shelfPrefs: widget.shelfPrefs,
      shelfLayout: widget.shelfLayout,
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
    ),
    NotesPage(
      vocabStore: widget.vocabStore,
      // 生词本页依赖全在壳层（仓库 / 进度 / AI / 统计），由回调就地组装——
      // 笔记页只留「计数 + 入口」两个字段，不背开书管道的依赖。
      onOpenVocab: widget.vocabStore == null
          ? null
          : () => unawaited(_openVocabPage()),
    ),
    SettingsPage(
      perfPrefs: widget.perfPrefs,
      settings: widget.settings,
      aiStore: widget.aiStore,
      aiClient: widget.aiClient,
      syncStore: widget.syncStore,
      syncClient: widget.syncClient,
      syncTrigger: widget.syncTrigger,
      onOpenStats: () => unawaited(_openStatsPage()),
    ),
  ];

  /// push 生词本页（词条点击跳回原文的开书依赖在此组装）。
  Future<void> _openVocabPage() {
    final VocabStore? vocab = widget.vocabStore;
    if (vocab == null) return Future<void>.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VocabPage(
          repository: widget.repository,
          progressStore: widget.progressStore,
          vocabStore: vocab,
          aiStore: widget.aiStore,
          aiClient: widget.aiClient,
          statsService: widget.statsService,
          summaryCache: widget.summaryCache,
          ragStore: widget.ragStore,
          ttsSettings: widget.ttsSettings,
          onlineTts: widget.onlineTts,
          bookmarkStore: widget.bookmarkStore,
          readingPrefsStore: widget.readingPrefsStore,
          syncTrigger: widget.syncTrigger,
        ),
      ),
    );
  }

  /// push 统计页（2026-10-15 统计移出底栏后，「我的」页的唯一入口）。
  ///
  /// 依赖与原底栏 tab 时代同源（组合根注入的 [StatsService] / [LibraryRepository]），
  /// 统计页自身带 [GlassNavScaffold] 顶栏与返回键（`canPop` 时显示）。
  Future<void> _openStatsPage() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StatsPage(
          service: widget.statsService,
          repository: widget.repository,
        ),
      ),
    );
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  /// 导入书籍绿圆钮（**两种导航形态共用同一份声明**，上游口径）：
  /// 窄窗挂底栏右侧（栏体左移让位）、宽屏挂侧栏栏尾下方；显隐契约、弹出曲线
  /// 与直径/间距 token 两种形态逐帧同源（选中「书架」= `tabIndex 0` 时弹出）。
  ///
  /// 2026-10-16 功能迁移批：绿钮接「导入书籍」（经 [_shelfKey] 转
  /// [ShelfPageState.pickAndImport]），取代原书架头部加号按钮。
  MiGlassNavFab _buildFab() => MiGlassNavFab(
    tabIndex: 0,
    onTap: () => _shelfKey.currentState?.pickAndImport(),
    // 绿钮 glyph = 参考项目配套用法（`d6893f7`）：白色圆角加号
    // （电话 App 截图 1220×378 实测）；此前点阵 glyph 是旧口径。
    child: Semantics(
      label: '导入书籍',
      button: true,
      child: CustomPaint(
        painter: PlusIconPainter(Colors.white),
        size: const Size.square(18.2),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = _buildPages();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 与上游 `MiBreakpoints.usesSideNav` 同口径：**严格大于** 600 才切侧栏。
        final bool sideNav = constraints.maxWidth > kShellRailBreakpoint;
        return _buildLayout(pages, sideNav);
      },
    );
  }

  /// 统一布局（上游 `demo_app.dart` 同构）：底栏 ⇄ 侧栏切换时**页面恒为
  /// Stack 第一个子级、位置只改 `left`**——Element 不重建，切形态时各页
  /// 滚动位置与页内状态保留。
  Widget _buildLayout(List<Widget> pages, bool sideNav) {
    final MiThemeMode mode = navThemeModeOf(context);
    final List<MiGlassNavItem> items = _navItems(mode);
    // edge-to-edge（T12）后内容铺到状态栏 / 手势条下面，浮层类元素要让开安全区。
    final double safeTop = MediaQuery.paddingOf(context).top;
    final double safeBottom = MediaQuery.paddingOf(context).bottom;
    // 页底色：与各页（书架 [shelfGradientBackground] 的 base）同源取
    // `scaffoldBackgroundColor`，铺满**整个窗口**（含侧栏那一列）。
    //
    // 上游 `demo_app.dart` 同款做法：内容只占右侧列，侧栏列若不铺页底色，
    // 露出的就是窗口底色——浅色下与页面之间出现一道色差（2026-10-18 亮色
    // 反馈「亮色模式需要这样」：截图里侧栏列与内容列是同一片浅底）。
    final Color pageBg = Theme.of(context).scaffoldBackgroundColor;
    return ColoredBox(
      color: pageBg,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: sideNav ? MiGlassSideNavMetrics.gutterWidth : 0,
            top: 0,
            right: 0,
            bottom: 0,
            // [IndexedStack] 让三页都保活（切回书架时滚动位置与筛选不丢），
            // 非当前页不绘制、不参与命中测试。
            child: IndexedStack(index: _index, children: pages),
          ),
          if (sideNav)
            // 侧栏贴顶对齐、距画面左缘与安全区各一档留白（与底部栏距屏底一档
            // 留白同一口径）；栏体自身收缩到内容高。一定要让开状态栏：铺满窗口
            // 后侧栏顶就在状态栏那一带。
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: MiGlassSideNavMetrics.gutterWidth,
              child: Padding(
                padding: EdgeInsets.only(
                  left: MiGlassSideNavMetrics.railMargin,
                  top: safeTop + MiGlassSideNavMetrics.railMargin,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: GlassSideNavHost(
                    items: items,
                    selectedIndex: _index,
                    onTabSelected: _select,
                    themeMode: mode,
                    // 绿色圆钮挂在栏尾下方（选中「书架」时弹出）。
                    fab: _buildFab(),
                  ),
                ),
              ),
            )
          else
            // 窄屏（手机 / 窄窗）：内容 + 浮动胶囊底栏 + 绿色圆钮。
            //
            // ⚠️ **必须是 `Stack + Positioned` 而非 `Scaffold.bottomNavigationBar`**：
            // 玻璃底栏的 [BackdropFilter] 需要采样**栏下方**的内容才能出磨砂效果；
            // 放进 `bottomNavigationBar` 时底栏在内容**之上**，采样不到正文，
            // 磨砂会退化成一块纯色。
            //
            // 栏体浮起 24.2dp（参考项目实测「bar bottom sits 24.2 dp above screen
            // bottom」）；edge-to-edge 下再让开手势条（上游同款）。
            Positioned(
              left: 0,
              right: 0,
              bottom: kShellNavBarBottomLift + safeBottom,
              child: GlassNavHost(
                items: items,
                selectedIndex: _index,
                onTabSelected: _select,
                themeMode: mode,
                fab: _buildFab(),
              ),
            ),
        ],
      ),
    );
  }
}
