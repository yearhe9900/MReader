// 设置页（PRD §12.1 页面 7，底栏 tab 名 = 「我的」）。
//
// 视觉**对齐上游 mi_like_ui demo「我的」页**（上游 `a12d6f3` + `5fb8199`，
// 2026-10-27 拍板「全跟上游」）：分组圆角卡片 + 整行按压高亮带（样式与度量
// 逐项收在 `settings_kit.dart` 的 [SettingsKitMetrics]），卡片直接自上而下
// 排列——**组标题已去掉**（上游无组标题；AI / 同步等子页仍保留各自的组标题
// 与脚注，分组语义不丢）。页底取 Mi 页底色（`MiColors.pageBackgroundFor`，
// 与 `shelf_search_page` 同先例；上游卡片色 #FFFFFF/#1E1E1E 依赖它才有对比）。
//
// **无搜索栏**：上游「我的」页首行有静态 `MiSearchBar`（demo 占位），本项目
// **不搬**——拍板④「不给能搜但搜不到的错误预期」仍有效（旧搜索占位已删），
// 故内容顶缘继续用 [MiTopBarMetrics.contentTopInset]（上游含搜索栏时才用
// `searchBarTopInset`）。
//
// 「玻璃效果」分组已移除（负责人口径）：「效果质量」「降低视觉特效」两行整组删除，
// **玻璃档位能力不删**——`PerfPrefsStore` 仍由 `main.dart` 加载并 `GlassRuntime.bind`，
// 档位恒为默认值；`UI-06` ② 的关档纯色退化路径（`GlassNavHost` / `GlassSideNavHost`）
// 继续保留，供后续重新加入口或设备自动降级复用。本页不消费 `perfPrefs`（构造参数
// 同步移除，不留无消费者的依赖）。
//
// 视觉红线（`UI-04`）不变：内容层不透明，玻璃只出现在导航层。
//
// 顶栏与内容区模糊切上游 [MiTopBar]（上游「我的」页大标题折叠形态同款）：
//   · 页面 = `Stack[Positioned.fill(滚动内容), Positioned(top: 0, MiTopBar)]`；
//   · [MiTopBar] 是受控组件：`ScrollController` 位移经 [ValueNotifier] 喂给
//     `scrollOffset`，只重建顶栏一层（上游同款做法）；
//   · **内容区顶部渐进模糊由顶栏材质自带**（`showBlur` 默认 true，内部复用
//     `MiGradientBlur`——上游设计：磨砂本体属于内容区，顶栏按材质盒高复用），
//     页面不再单独叠模糊层；
//   · 「我的」是底栏顶层页 → `showBack` 保持默认 false（顶层页无返回圆钮）。
//
// 既有拍板口径**仍然有效**（①卡片不透明③外观组④不给错误预期），仅②的大标题实现
// 载体换为 [MiTopBar]（两段式收起同源：大标题 1:1 随内容上移 + 独立淡出，紧凑标题
// 随后淡入）：
//   ① **卡片不透明**（PRD §11.2 原把「设置页内的控件 / 分组卡片」列为玻璃，与同节
//      理由①（库的设计哲学：导航层玻璃、内容层不透明）与③（`premium` 禁进滚动区、
//      滚动区渲染成本）取向相左，拍板实心卡片、§11.2 两行同步改文）。
//      **浮层仍走玻璃**（§11.2「浮层 = 玻璃」）。
//   ③ **「外观」组**：主题三态的第一个应用级入口（此前 `SettingsStore.setThemeMode`
//      除测试外零调用者、应用级没有主题入口）。
//   ④ **不给「能搜但搜不到」的错误预期**（原搜索占位已随旧顶栏移除，见文末）。
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
import 'mi_like_ui/mi_like_ui.dart'
    show MiColors, MiDimens, MiThemeMode, MiTopBar, MiTopBarMetrics, MiViewport;
import 'settings_kit.dart';
import 'sync_settings_page.dart';
import 'sync_status_page.dart';

/// 页面内容的左右留白（上游「我的」页口径：手机档 11.9、宽屏档 32）。
///
/// 上游同款断点（`MiViewport`）：compact 取素材度量 11.9，其余档取
/// `MiDimens.spaceXxxl`（32）——宽屏下 11.9 会把卡片顶到窗口边缘。
double _pageInset(BuildContext context) =>
    MiViewport.of(context).isCompact ? 11.9 : MiDimens.spaceXxxl;

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

  /// 同步配置存储（`SYNC-01`，「同步备份」组入口）。
  ///
  /// `null` = 未接线 → 本页同步组整体隐藏（与 `vocabStore` 等可选依赖
  /// 同款降级口径）。
  final SyncConfigStore? syncStore;

  /// WebDAV 客户端（注入同步设置页的测试连接）；与 [syncStore] 同进同退。
  final WebdavClient? syncClient;

  /// 同步触发器（`SYNC-06/07`）：「同步状态与备份」页入口。
  ///
  /// `null` = 未接线 → 该入口不渲染（同步组其余入口不受影响）。
  final SyncTrigger? syncTrigger;

  /// 统计页入口（统计移出底栏后收进本页的唯一入口）。
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
    // 上游「我的」页同款：滚动内容铺底 + 顶栏钉顶。页底取 **Mi 页底色**（上游
    // 卡片色 #FFFFFF/#1E1E1E 依赖它才有对比；与 `shelf_search_page` 同先例），
    // 页面独立成树（测试 / push 子页）时也不露窗口底色。顶栏形态 = 大标题折叠：
    // 磨砂 + 叠色 + 大/紧凑标题两段式；内容区顶部渐进模糊由顶栏材质自带
    // （`showBlur` 内部复用 `MiGradientBlur`）。
    final MiThemeMode mode = Theme.of(context).brightness == Brightness.light
        ? MiThemeMode.light
        : MiThemeMode.dark;
    return ColoredBox(
      // 定位键：契约测试按它读页底色（`find.byType(ColoredBox).first` 会撞上
      // 树里其它透明 ColoredBox）。
      key: const ValueKey<String>('settings-page-background'),
      color: MiColors.pageBackgroundFor(mode),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ListView(
              controller: _scrollController,
              // 顶部让位 = [MiTopBarMetrics.contentTopInset]（大标题墨心之下）；
              // 底部自留浮动胶囊底栏的空白（`kShellBottomInset`）。
              padding: EdgeInsets.fromLTRB(
                _pageInset(context),
                MiTopBarMetrics.contentTopInset,
                _pageInset(context),
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
                // 本页标题 = 「我的」（与底栏 tab 同名）。
                title: '我的',
                scrollOffset: offset,
                // 「我的」是底栏顶层页 → 无返回圆钮（默认 false）。
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「统计」组（统计移出底栏后的唯一入口）：push 统计页。
  ///
  /// [SettingsPage.onOpenStats] 为 `null` = 未接线 → 本组整体隐藏（同款降级口径）。
  Widget _buildStatsGroup() {
    final VoidCallback? onOpenStats = widget.onOpenStats;
    if (onOpenStats == null) {
      return const SizedBox.shrink();
    }
    return SettingsGroupCard(
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

  /// 「外观」组（主题三态的第一个应用级入口）。
  Widget _buildAppearanceGroup() {
    return SettingsGroupCard(
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

  /// 「同步备份」组（`SYNC-01`）：进同步设置页（连接配置 / 测试连接）。
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
        // 「同步状态与备份」：手动同步/备份/恢复 + 失败清单（`SYNC-07`）。
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

// 「搜索设置项」占位（`_SettingsSearchPlaceholder`）已随上游顶栏批移除：它挂在旧
// [GlassLargeTitle] 的 searchBar 插槽上，而新顶栏无搜索头部、占位失去挂点；其本就
// 是「未实现」的死功能（拍板④），移除不损失任何真实能力。
