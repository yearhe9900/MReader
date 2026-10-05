// 应用主壳层：五 tab（书架 / 统计 / AI / 笔记 / 设置）+ 玻璃浮动底栏。
//
// ══════════════════════════════════════════════════════════════════════════════
// 结构（2026-09-28 定；参考 anx-reader 的 `page/home_page.dart`）
// ══════════════════════════════════════════════════════════════════════════════
// 外层**不是** Scaffold，而是 `Stack`：子页与底栏叠放，底栏浮在最上层。
// 子页各自持有 [GlassNavScaffold]（含自己的顶栏）——若外层再套一层 Scaffold，
// 就会形成 `GlassScaffold` 嵌套 `GlassScaffold`，直接违反 `UI-04`
// 「玻璃控件不可嵌套」。底栏因此以 `standalone: true` 使用 [GlassNavBar]
// （脱离 `GlassScaffold` 祖先，高档需显式声明固定表面档位，见该参数文档）。
//
// 底栏形态 = 库原生的 **iOS 26 浮动胶囊**（左右 / 底部留边距、圆角、64 高），
// 不是贴底通栏——与 anx-reader 的 `flutter_floating_bottom_bar` 观感一致。
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
import '../reader/progress_store.dart';
import '../settings/perf_prefs_store.dart';
import '../settings/settings_store.dart';
import '../settings/shelf_layout_store.dart';
import '../settings/shelf_prefs_store.dart';
import '../stats/stats_service.dart';
import '../sync/sync_config_store.dart';
import '../sync/webdav_client.dart';
import '../tts/online_tts.dart';
import '../tts/tts_settings.dart';
import 'ai_page.dart';
import 'glass_kit.dart';
import 'notes_page.dart';
import 'settings_page.dart';
import 'shelf_page.dart';
import 'stats_page.dart';
import 'vocab_page.dart';

/// 浮动底栏为各页内容预留的底部空白。
///
/// 胶囊高 64 + 底部外边距 20 + 安全区与呼吸余量 ≈ 96。
/// 各页把它并入自己滚动容器的 `padding.bottom`。
const double kShellBottomInset = 96;

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

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// 当前底栏下标。
  int _index = 0;

  /// 底栏标签（顺序即下标语义，**勿任意重排**）。
  static const List<GlassTab> _tabs = <GlassTab>[
    GlassTab(
      icon: Icon(Icons.menu_book_outlined),
      activeIcon: Icon(Icons.menu_book),
      label: '书架',
    ),
    GlassTab(
      icon: Icon(Icons.insights_outlined),
      activeIcon: Icon(Icons.insights),
      label: '统计',
    ),
    GlassTab(
      icon: Icon(Icons.auto_awesome_outlined),
      activeIcon: Icon(Icons.auto_awesome),
      label: 'AI',
    ),
    GlassTab(
      icon: Icon(Icons.sticky_note_2_outlined),
      activeIcon: Icon(Icons.sticky_note_2),
      label: '笔记',
    ),
    GlassTab(
      icon: Icon(Icons.settings_outlined),
      activeIcon: Icon(Icons.settings),
      label: '设置',
    ),
  ];

  /// 五个 tab 的内容页。
  ///
  /// 每页**自带** [GlassNavScaffold]（顶栏 + 不透明正文），本壳层只负责
  /// 「选哪一页」与「底栏」。
  List<Widget> _buildPages() => <Widget>[
        ShelfPage(
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
        ),
        StatsPage(service: widget.statsService, repository: widget.repository),
        const AiPage(),
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

  /// 窄屏（手机 / 窄窗）：内容 + 浮动胶囊底栏。
  ///
  /// [IndexedStack] 让五页都保活（切回书架时滚动位置与筛选不丢），
  /// 非当前页不绘制、不参与命中测试。
  Widget _buildBottomBarLayout(List<Widget> pages) {
    return Stack(
      children: <Widget>[
        IndexedStack(index: _index, children: pages),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: GlassNavBar(
            tabs: _tabs,
            selectedIndex: _index,
            onTabSelected: _select,
            // 独立浮层：没有 GlassScaffold 祖先，高档需显式声明固定表面档位。
            standalone: true,
          ),
        ),
      ],
    );
  }

  /// 宽屏：侧边导航轨 + 内容。
  Widget _buildRailLayout(List<Widget> pages) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          SafeArea(
            child: NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              destinations: <NavigationRailDestination>[
                for (final GlassTab tab in _tabs)
                  NavigationRailDestination(
                    icon: tab.icon ?? const SizedBox.shrink(),
                    selectedIcon: tab.activeIcon,
                    label: Text(tab.label ?? ''),
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
