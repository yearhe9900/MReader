// 设置页（PRD §12.1 页面 7；2026-09-29 重做视觉，2026-10-19 顶栏切上游）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-10-20 「玻璃效果」分组移除（负责人口径）
// ══════════════════════════════════════════════════════════════════════════════
// 「效果质量」「降低视觉特效」两行整组移除（[GlassSettingsSection] 组件一并删除）。
// **玻璃档位能力不删**：`PerfPrefsStore` 仍由 `main.dart` 加载并
// `GlassRuntime.bind`，只是不再有 UI 修改入口 —— 档位恒为默认值（高 /
// 降低特效关）；`UI-06` ② 的关档纯色退化路径（`GlassNavHost` /
// `GlassSideNavHost`）继续保留，供后续重新加入口或设备自动降级复用。
// 本页因此不再消费 `perfPrefs`：构造参数同步移除，不留无消费者的依赖。
//
// 视觉红线（`UI-04`）不变：内容层不透明，玻璃只出现在导航层。
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-10-19 上游顶栏批：顶栏与内容区模糊切上游 [MiTopBar]
// ══════════════════════════════════════════════════════════════════════════════
// 本批把顶栏从旧玻璃库体系（[GlassNavScaffold] + [GlassTopBar] +
// [GlassLargeTitle] + [OpaqueContentSurface]）整体切到上游移植体 [MiTopBar]，
// 与上游「我的」页（`_MockPageShell`，大标题折叠形态）同款：
//   · 页面 = `Stack[Positioned.fill(滚动内容), Positioned(top: 0, MiTopBar)]`；
//   · [MiTopBar] 是受控组件：`ScrollController` 位移经 [ValueNotifier] 喂给
//     `scrollOffset`，只重建顶栏一层（上游同款做法）；
//   · **内容区顶部渐进模糊由顶栏材质自带**（`showBlur` 默认 true，内部复用
//     独立组件 `MiGradientBlur`——上游设计：磨砂本体属于内容区，顶栏按材质
//     盒高复用它），页面不再单独叠模糊层；
//   · 「我的」是底栏顶层页 → `showBack` 保持默认 false（上游口径：顶层页无
//     返回圆钮）；
//   · 旧批的搜索占位随 GlassLargeTitle 一并移除——上游「我的」页顶栏无搜索
//     头部（搜索形态属分类页），占位本就是「未实现」的死功能（拍板④）。
//
// 下方 2026-09-29 改版的拍板口径**仍然有效**（①卡片不透明③外观组④不给错误
// 预期），仅②的大标题实现载体换为 [MiTopBar]（两段式收起实测同源：大标题
// 1:1 随内容上移 + 独立淡出，紧凑标题随后淡入）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-09-29 改版（参考 HyperOS 深色设置页）
// ══════════════════════════════════════════════════════════════════════════════
// 四点拍板口径：
//   ① **卡片不透明**。PRD §11.2 原把「设置页内的控件 / 分组卡片」列为玻璃，与同节
//      理由①（库的设计哲学）与③（`premium` 禁进滚动区、滚动区渲染成本）取向相左
//      ——§11.2 的内部张力已上报负责人，本批按参考图的实心卡片落地，
//      PRD §11.2 两行同步改文（v2.10）。**浮层仍走玻璃**（§11.2「浮层 = 玻璃」）。
//   ② **内容层大标题**：页面首个 sliver 是 [GlassLargeTitle]，卡片上滑时大标题
//      收起、顶栏出现「设置」（两段式：大标题先淡出，搜索条随后收起）。
//   ③ **「外观」组**：本批让主题三态真正可用——此前 `SettingsStore.setThemeMode`
//      除测试外**零调用者**、应用级没有主题入口（`ReaderSettings.themeMode` 也
//      无消费点，见回报），故本组是第一个入口。
//   ④ **搜索框只做占位**：不接任何过滤逻辑，点击给一条轻提示，避免「能搜但搜不到」
//      的错误预期。
//
// 为什么玻璃库的 sliver 可以直接放进 `OpaqueContentSurface`：该容器的断言只校验
// **直接子节点**（`glass_kit.dart:139-143`），本页的直接子节点是 `CustomScrollView`；
// 而 [GlassLargeTitle] 只画文本与 `Transform.scale`（`glass_large_title.dart:398-458`，
// **零着色器、零玻璃质感**），既是库文档指定的「`CustomScrollView` 首个 sliver」用法，
// 也不违反「不透明内容层」红线。**关档**下它同样在场——因为它是布局/动画组件而非
// 玻璃质感组件，`UI-06` ② 的「纯色退化」不受影响。
import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/provider_store.dart';
import '../settings/settings_store.dart';
import '../sync/sync_config_store.dart';
import '../sync/sync_trigger.dart';
import '../sync/webdav_client.dart';
import '../theme/app_theme.dart';
import 'ai_settings_page.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'mi_like_ui/mi_like_ui.dart' show MiTopBar, MiTopBarMetrics;
import 'settings_kit.dart';
import 'sync_settings_page.dart';
import 'sync_status_page.dart';

/// 页面内容的左右留白（上游「我的」页实测 20，2026-10-19 随顶栏批对齐；
/// 原 16 是 2026-09-29 改版自定值，随搜索占位一并退场）。
const double _kPageInset = 20;

/// 设置页。
class SettingsPage extends StatefulWidget {
  /// 创建设置页（依赖显式注入，非全局单例）。
  const SettingsPage({
    super.key,
    required this.settings,
    required this.aiStore,
    required this.aiClient,
    this.syncStore,
    this.syncClient,
    this.syncTrigger,
    this.onOpenStats,
  });

  /// 设置服务（主题三态；`app.dart` 由它驱动 `MaterialApp.themeMode`）。
  final SettingsStore settings;

  /// AI 配置存储（「AI 服务」入口 → AI 设置页）。
  final ProviderStore aiStore;

  /// AI 客户端（注入 AI 设置页的测试连接）。
  final AiClient aiClient;

  /// 同步配置存储（`M4-T01` `SYNC-01`，「同步备份」组入口）。
  ///
  /// `null` = 未接线 → 本页同步组整体隐藏（与 `vocabStore` 等可选依赖
  /// 同款降级口径）。
  final SyncConfigStore? syncStore;

  /// WebDAV 客户端（注入同步设置页的测试连接）；与 [syncStore] 同进同退。
  final WebdavClient? syncClient;

  /// 同步触发器（`M4-T05` `SYNC-06/07`）：「同步状态与备份」页入口。
  ///
  /// `null` = 未接线 → 该入口不渲染（同步组其余入口不受影响）。
  final SyncTrigger? syncTrigger;

  /// 统计页入口（2026-10-15 统计移出底栏，入口收进本页）。
  ///
  /// `null` = 未接线 → 入口行不渲染（同款降级口径）。
  final VoidCallback? onOpenStats;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 滚动位移 → 顶栏折叠的受控链（上游 `_MockPageShell` 同款）：
  /// [ScrollController] 喂 [ValueNotifier]，[MiTopBar] 只跟着这一层重建，
  /// 不整页 `setState`。
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_syncScrollOffset);
    widget.settings.addListener(_onDepsChanged);
    // 同步配置可选（`SYNC-01`）：订阅配置增删，「已配置 / 未配置」值不陈旧。
    widget.syncStore?.addListener(_onDepsChanged);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_syncScrollOffset);
    _scrollController.dispose();
    _scrollOffset.dispose();
    widget.settings.removeListener(_onDepsChanged);
    widget.syncStore?.removeListener(_onDepsChanged);
    super.dispose();
  }

  void _syncScrollOffset() => _scrollOffset.value = _scrollController.offset;

  /// 依赖任一变即重绘本页（项目既定状态管理约定）。
  void _onDepsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 弹出主题模式单选弹层；选中后写入 [SettingsStore]。
  ///
  /// 写入会通知 `MReaderApp`（`app.dart:32-56`）重建 `MaterialApp`，整树换色。
  Future<void> _pickThemeMode() async {
    final AppThemeMode current = widget.settings.settings.themeMode;
    final AppThemeMode? picked = await showSettingsPicker<AppThemeMode>(
      context: context,
      title: '主题模式',
      current: current,
      options: <SettingsPickerOption<AppThemeMode>>[
        for (final AppThemeMode mode in AppThemeMode.values)
          SettingsPickerOption<AppThemeMode>(
            value: mode,
            label: appThemeModeLabel(mode),
          ),
      ],
    );
    // 弹层关闭 + 落盘期间本页可能已卸载（`mounted` 必查）。
    if (!mounted || picked == null || picked == current) return;
    await widget.settings.setThemeMode(picked);
  }

  @override
  Widget build(BuildContext context) {
    // 上游「我的」页同款（`_MockPageShell`）：滚动内容铺底 + 顶栏钉顶。
    // 页底色与 home_shell 铺的整窗页底同源（`scaffoldBackgroundColor`），
    // 页面独立成树（测试 / push 子页）时也不露窗口底色。
    //
    // 顶栏形态 = 大标题折叠（上游「我的」页实测形态）：磨砂 + 叠色 + 大/紧凑
    // 标题两段式；内容区顶部渐进模糊由顶栏材质自带（`showBlur` 内部复用
    // `MiGradientBlur`，上游设计——磨砂本体属于内容区、顶栏按材质盒高复用）。
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ListView(
              controller: _scrollController,
              // 顶部让位 = 上游实测 [MiTopBarMetrics.contentTopInset]（183，
              // 大标题墨心之下）；底部自留浮动胶囊底栏的空白（`kShellBottomInset`）。
              padding: const EdgeInsets.fromLTRB(
                _kPageInset,
                MiTopBarMetrics.contentTopInset,
                _kPageInset,
                0,
              ),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(bottom: kShellBottomInset),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildStatsGroup(),
                      _buildAppearanceGroup(),
                      _buildAiGroup(),
                      _buildSyncGroup(),
                      // 后续分组（RUST-10 加速参数…）在此追加。
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 顶栏必须 Positioned 钉顶（上游 ⚠️：留作非定位子级时 Stack 按它
          // 收缩，整页在 loose 约束里被垂直居中）。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: _scrollOffset,
              builder: (BuildContext context, double offset, _) => MiTopBar(
                // 2026-10-15 底栏「设置」tab 改名「我的」后，本页标题同步改名。
                title: '我的',
                scrollOffset: offset,
                // 「我的」是底栏顶层页 → 无返回圆钮（默认 false，上游口径）。
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「统计」组（2026-10-15 统计移出底栏后的唯一入口）：push 统计页。
  ///
  /// [SettingsPage.onOpenStats] 为 `null` = 未接线 → 本组整体隐藏（同款降级口径）。
  Widget _buildStatsGroup() {
    final VoidCallback? onOpenStats = widget.onOpenStats;
    if (onOpenStats == null) {
      return const SizedBox.shrink();
    }
    return SettingsGroupCard(
      header: '统计',
      children: <Widget>[
        SettingsTile(
          icon: Icons.insights,
          accent: SettingsAccents.green,
          title: '阅读统计',
          subtitle: '阅读时长 / 读完本数 / 排行',
          onTap: onOpenStats,
        ),
      ],
    );
  }

  /// 「外观」组（本批新增；主题三态的第一个应用级入口）。
  Widget _buildAppearanceGroup() {
    return SettingsGroupCard(
      header: '外观',
      children: <Widget>[
        SettingsTile(
          icon: Icons.brightness_6_outlined,
          accent: SettingsAccents.purple,
          title: '主题模式',
          subtitle: '日间 / 夜间 / 跟随系统',
          value: appThemeModeLabel(widget.settings.settings.themeMode),
          onTap: _pickThemeMode,
        ),
      ],
    );
  }

  /// 「AI」组：进 AI 设置页（配置 / 密钥 / `AI-09` 开关）。
  Widget _buildAiGroup() {
    return SettingsGroupCard(
      header: 'AI',
      children: <Widget>[
        SettingsTile(
          icon: Icons.auto_awesome_outlined,
          accent: SettingsAccents.purple,
          title: 'AI 服务',
          subtitle: '模型配置 / 密钥 / 隐私开关',
          value: widget.aiStore.prefs.aiEnabled ? '已启用' : '已关闭',
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => AiSettingsPage(
                store: widget.aiStore,
                client: widget.aiClient,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 「同步备份」组（`M4-T01` `SYNC-01`）：进同步设置页（连接配置 / 测试连接）。
  ///
  /// [SettingsPage.syncStore] / [SettingsPage.syncClient] 任一为 `null`
  /// = 未接线 → 本组整体隐藏（既定降级口径，同 `vocabStore`）。
  Widget _buildSyncGroup() {
    final SyncConfigStore? syncStore = widget.syncStore;
    final WebdavClient? syncClient = widget.syncClient;
    final SyncTrigger? syncTrigger = widget.syncTrigger;
    if (syncStore == null || syncClient == null) {
      return const SizedBox.shrink();
    }
    return SettingsGroupCard(
      header: '同步备份',
      children: <Widget>[
        SettingsTile(
          icon: Icons.sync_outlined,
          accent: SettingsAccents.blue,
          title: 'WebDAV 同步',
          subtitle: '服务器地址 / 账号 / 测试连接',
          value: syncStore.isConfigured ? '已配置' : '未配置',
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => SyncSettingsPage(
                store: syncStore,
                client: syncClient,
              ),
            ),
          ),
        ),
        // 「同步状态与备份」（`M4-T05`）：手动同步/备份/恢复 + 失败清单（`SYNC-07`）。
        if (syncTrigger != null)
          SettingsTile(
            icon: Icons.cloud_sync_outlined,
            accent: SettingsAccents.blue,
            title: '同步状态与备份',
            subtitle: '立即同步 / 备份 / 从云端恢复',
            value: syncTrigger.isRunning ? '同步中' : '查看',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => SyncStatusPage(trigger: syncTrigger),
              ),
            ),
          ),
      ],
    );
  }
}

// 「搜索设置项」占位（`_SettingsSearchPlaceholder`）已随 2026-10-19 上游顶栏
// 批移除：它挂在旧 [GlassLargeTitle] 的 searchBar 插槽上，而上游「我的」页顶栏
// （大标题折叠形态）没有搜索头部——搜索形态属分类页（吸顶头部），本批对齐
// 上游形态后占位失去挂点；其本就是「未实现」的死功能（拍板④），点击只弹
// 轻提示，移除不损失任何真实能力。
