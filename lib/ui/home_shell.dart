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
// 宽屏自适应
// ══════════════════════════════════════════════════════════════════════════════
// `maxWidth > 600` 改用侧边导航轨（与 anx-reader 同一断点）。**玻璃库不含
// 侧栏组件**（`lib/widgets/surfaces/` 下只有 appBar / tabBar / toolbar /
// navigationShell 等），故此处用 Material [NavigationRail]——宽屏多为桌面，
// 与 anx-reader 的选择一致，不额外造玻璃侧栏。
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

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = _buildPages();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth > kShellRailBreakpoint) {
          return _buildRailLayout(pages);
        }
        return _buildBottomBarLayout(pages);
      },
    );
  }

  /// 窄屏（手机 / 窄窗）：内容 + 浮动胶囊底栏 + 绿色圆钮。
  ///
  /// [IndexedStack] 让三页都保活（切回书架时滚动位置与筛选不丢），
  /// 非当前页不绘制、不参与命中测试。
  ///
  /// ⚠️ **必须是 `Stack + Positioned` 而非 `Scaffold.bottomNavigationBar`**：
  /// 玻璃底栏的 [BackdropFilter] 需要采样**栏下方**的内容才能出磨砂效果；
  /// 放进 `bottomNavigationBar` 时底栏在内容**之上**，采样不到正文，
  /// 磨砂会退化成一块纯色。
  ///
  /// 栏体浮起 24.2dp（参考项目实测「bar bottom sits 24.2 dp above screen
  /// bottom」）；绿色圆钮 = 参考项目 [MiGlassNavFab] 的「预留空位圆钮」：
  /// 选中「书架」时缩放弹出、栏体左移让位，切走镜像收起。
  /// **2026-10-16 功能迁移批**：绿钮接「导入书籍」（经 [_shelfKey] 转
  /// [ShelfPageState.pickAndImport]），取代原书架头部加号按钮。
  Widget _buildBottomBarLayout(List<Widget> pages) {
    final MiThemeMode mode = navThemeModeOf(context);
    return Stack(
      children: <Widget>[
        IndexedStack(index: _index, children: pages),
        Positioned(
          left: 0,
          right: 0,
          bottom: 24.2,
          child: GlassNavHost(
            items: _navItems(mode),
            selectedIndex: _index,
            onTabSelected: _select,
            themeMode: mode,
            fab: MiGlassNavFab(
              tabIndex: 0,
              // 2026-10-16 功能迁移：绿钮 =「导入书籍」入口（原书架头部
              // 加号按钮已移除）；空态引导按钮仍由 LIB-01 ② 保留。
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
            ),
          ),
        ),
      ],
    );
  }

  /// 宽屏：侧边导航轨 + 内容。
  Widget _buildRailLayout(List<Widget> pages) {
    final MiThemeMode mode = navThemeModeOf(context);
    final List<MiGlassNavItem> items = _navItems(mode);
    return Scaffold(
      body: Row(
        children: <Widget>[
          SafeArea(
            child: NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              destinations: <NavigationRailDestination>[
                for (final MiGlassNavItem item in items)
                  NavigationRailDestination(
                    icon: CustomPaint(
                      painter: item.painter,
                      size: const Size.square(24),
                    ),
                    label: Text(item.label),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(index: _index, children: pages),
          ),
        ],
      ),
    );
  }
}
