// 设置页（PRD §12.1 页面 7；M2b-T07 只落「玻璃效果」分组，2026-09-29 重做视觉）。
//
// 本页是玻璃质量档位的**消费点**（`UI-05` / `UI-06`）：档位生效接线后，
// 「关」档纯色退化已下沉到 [GlassNavScaffold] 等薄封装（`glass_kit.dart`），
// 本页不再做档位特判——切档后经 `GlassRuntime` 全局生效、整树跟档。
//
// 视觉红线（`UI-04` + 本批口径）：内容层永远不透明（[OpaqueContentSurface]），
// 玻璃只出现在导航层；玻璃库锁定 1.7.0 不动。
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
// `GlassLargeTitle` 与顶栏标题**共用同一个** [GlassLargeTitleController]：
// 控制器自持 `ScrollController`（接给本页 `CustomScrollView`），两处都订阅它，
// 不存在第二份进度真值。控制器由本页 `State` 创建与释放。
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
import '../settings/perf_prefs_store.dart';
import '../settings/settings_store.dart';
import '../theme/app_theme.dart';
import 'ai_settings_page.dart';
import 'glass_kit.dart';
import 'glass_settings_section.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'settings_kit.dart';

/// 页面内容的左右留白（卡片与搜索占位对齐同一左边缘）。
const double _kPageInset = 16;

/// 设置页。
class SettingsPage extends StatefulWidget {
  /// 创建设置页（依赖显式注入，非全局单例）。
  const SettingsPage({
    super.key,
    required this.perfPrefs,
    required this.settings,
    required this.aiStore,
    required this.aiClient,
  });

  /// 性能偏好服务（玻璃质量档位 / 降低视觉特效开关的持久化）。
  final PerfPrefsStore perfPrefs;

  /// 设置服务（主题三态；`app.dart` 由它驱动 `MaterialApp.themeMode`）。
  final SettingsStore settings;

  /// AI 配置存储（「AI 服务」入口 → AI 设置页）。
  final ProviderStore aiStore;

  /// AI 客户端（注入 AI 设置页的测试连接）。
  final AiClient aiClient;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 大标题 ⇄ 顶栏标题的收起联动控制器。
  ///
  /// 自持 `ScrollController`（见库 `glass_large_title.dart:53-173`），
  /// **必须**由本 `State` 释放；顶栏（[GlassTopBar.largeTitleController]）与内容层
  /// 大标题（[GlassLargeTitle]）共用同一实例。
  final GlassLargeTitleController _titleController = GlassLargeTitleController();

  @override
  void initState() {
    super.initState();
    widget.perfPrefs.addListener(_onDepsChanged);
    widget.settings.addListener(_onDepsChanged);
  }

  @override
  void dispose() {
    widget.perfPrefs.removeListener(_onDepsChanged);
    widget.settings.removeListener(_onDepsChanged);
    _titleController.dispose();
    super.dispose();
  }

  /// 两个依赖任一变化即重绘本页（项目既定状态管理约定）。
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
    // 档位生效统一走薄封装（GlassNavScaffold 内部读 `GlassScope.configOf`）：
    // 高 / 中 / 低档玻璃壳层；「关」档自动退化纯色（`UI-06` ②）。
    return GlassNavScaffold(
      // 大标题在内容层（本页自己画），顶栏标题由控制器驱动淡入——故顶栏标题
      // 初帧不可见（`collapseProgress == 0` → `barProgress == 0`）。
      // 居中与否保持库默认（`centerTitle: true`）：两段式收起是 iOS 26 的
      // 大标题范式，库的 `_buildTitle` 也把标题强制 `TextAlign.center`。
      appBar: GlassTopBar(
        title: const Text('设置'),
        largeTitleController: _titleController,
      ),
      body: OpaqueContentSurface(
        child: CustomScrollView(
          controller: _titleController.scrollController,
          slivers: <Widget>[
            GlassLargeTitle(
              text: '设置',
              controller: _titleController,
              // 显式给色：库缺省取 `CupertinoColors.label`（走 Cupertino 主题级联），
              // 这里直接跟 Material 主题的 `onSurface`，与卡片文字同一口径。
              color: Theme.of(context).colorScheme.onSurface,
              padding: const EdgeInsetsDirectional.fromSTEB(
                _kPageInset,
                0,
                _kPageInset,
                4,
              ),
              searchBarPadding: const EdgeInsetsDirectional.fromSTEB(
                _kPageInset,
                4,
                _kPageInset,
                12,
              ),
              searchBar: const _SettingsSearchPlaceholder(),
            ),
            SliverToBoxAdapter(
              child: Padding(
                // 底部自留浮动胶囊底栏的空白（`home_shell.dart:18-20` / `kShellBottomInset`）。
                padding: const EdgeInsetsDirectional.fromSTEB(
                  _kPageInset,
                  0,
                  _kPageInset,
                  kShellBottomInset,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildAppearanceGroup(),
                    _buildAiGroup(),
                    GlassSettingsSection(perfPrefs: widget.perfPrefs),
                    // 后续分组（同步备份 / RUST-10 加速参数…）在此追加。
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
}

/// 「搜索设置项」输入框的**占位**（本批不实现搜索）。
///
/// 拍板口径：「先做搜索框占位，不实际实现」——**不接任何过滤逻辑**，
/// 点击只给一条轻提示，明确告知尚未实现，不给「能搜但搜不到」的错误预期。
/// 形态照参考图：40 高、圆角 20、`surfaceContainerHighest` 填充 + `outlineVariant` 描边。
class _SettingsSearchPlaceholder extends StatelessWidget {
  const _SettingsSearchPlaceholder();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      // 自带 Material：水波纹才画在本框之上——`OpaqueContentSurface` 的 Material
      // 在滚动视图之外，波纹会被本框底色盖住（同 `settings_kit.dart` 卡片的口径）。
      color: colors.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: InkWell(
        onTap: () => GlassOverlays.showToast(
          context: context,
          message: '设置搜索尚未实现',
        ),
        child: SizedBox(
          height: 40,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 12),
              Icon(Icons.search, size: 20, color: colors.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                '搜索系统设置项',
                style: TextStyle(
                  fontSize: 14,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
