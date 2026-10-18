// 底栏宿主：把「一比一移植」的 mi_like_ui 玻璃底栏接到 MReader 的档位 / 主题体系。
//
// ══════════════════════════════════════════════════════════════════════════════
// 职责边界（2026-10-15「底栏整组换参考项目」批）
// ══════════════════════════════════════════════════════════════════════════════
// [MiGlassNavBar] 本身**逐字节保持与参考项目 `bottom_nav_demo` 一致**（明暗配方、
// 果冻飞行、沉降、拖拽、按压全在其内），本类只补两件参考项目不管的事：
//
//   ① **「关」档退化**（`UI-06` ②）：玻璃特效关闭时底栏换 Material [NavigationBar]
//      纯色形态——与旧 [FrostedNavBar] 的退化口径一致，功能完整可用；
//   ② **明暗映射**（`UI-01` ②）：[MiThemeMode] 由 `GlassScope` 级联亮度驱动
//      （应用主题三态，而非只跟系统亮度），标签墨色由调用方按同一亮度取
//      [MiColors.foregroundFor]，与栏体配方同源。
//
// 选中块位置 / 手势 / 动效**不在这里**——全在移植体内部，改动请改上游再重拷。
import 'package:flutter/material.dart';

import 'glass_scope.dart';
import 'mi_like_ui/mi_like_ui.dart';

/// mi_like_ui 玻璃底栏的 MReader 宿主（档位退化 + 明暗映射）。
class GlassNavHost extends StatelessWidget {
  /// 创建底栏宿主。
  const GlassNavHost({
    required this.items,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.themeMode,
    this.fab,
    super.key,
  });

  /// 标签配置（顺序即下标语义）。
  final List<MiGlassNavItem> items;

  /// 当前选中下标。
  final int selectedIndex;

  /// 选中回调。
  final ValueChanged<int> onTabSelected;

  /// 明暗模式（调用方按 `GlassScope` 亮度解析，与标签墨色同源）。
  final MiThemeMode themeMode;

  /// 预留空位圆钮（`null` = 不启用）。
  final MiGlassNavFab? fab;

  @override
  Widget build(BuildContext context) {
    if (!GlassScope.configOf(context).glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色底栏，功能完整可用。
      return NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onTabSelected,
        destinations: <NavigationDestination>[
          for (final MiGlassNavItem item in items)
            NavigationDestination(
              icon: CustomPaint(
                painter: item.painter,
                size: const Size.square(24),
              ),
              label: item.label,
            ),
        ],
      );
    }
    return MiGlassNavBar(
      items: items,
      selectedIndex: selectedIndex,
      onTap: onTabSelected,
      themeMode: themeMode,
      fab: fab,
    );
  }
}

/// 按 `GlassScope` 级联亮度解析底栏明暗（`UI-01` ②：跟应用主题三态）。
MiThemeMode navThemeModeOf(BuildContext context) =>
    GlassScope.brightnessOf(context) == Brightness.dark
        ? MiThemeMode.dark
        : MiThemeMode.light;

/// mi_like_ui 玻璃**侧边**导航栏的 MReader 宿主（档位退化 + 明暗映射）。
///
/// 2026-10-19 上游平板模式批：`maxWidth > kShellRailBreakpoint` 时取代底栏
/// [GlassNavHost]（上游 `demo_app.dart` 同款「侧栏 ⇄ 底栏」双形态）。
/// 与 [GlassNavHost] 逐条同构：
///   ① **「关」档退化**（`UI-06` ②）：换 Material [NavigationRail] 纯色形态，
///      功能完整可用（原宽屏实现即 Material rail，行为不变）；
///   ② **明暗映射**（`UI-01` ②）：[MiThemeMode] 由 `GlassScope` 级联亮度驱动。
///
/// 摆放位置（贴顶 + 距左缘 / 安全区留白）由宿主（`home_shell.dart`）给出——
/// 与底栏「栏体位置在壳层」的同构做法；本类只负责栏体本身。
class GlassSideNavHost extends StatelessWidget {
  /// 创建侧栏宿主。
  const GlassSideNavHost({
    required this.items,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.themeMode,
    this.fab,
    super.key,
  });

  /// 标签配置（顺序即下标语义；**与底栏同一份 items**，换形态不换语义）。
  final List<MiGlassNavItem> items;

  /// 当前选中下标。
  final int selectedIndex;

  /// 选中回调。
  final ValueChanged<int> onTabSelected;

  /// 明暗模式（调用方按 `GlassScope` 亮度解析，与标签墨色同源）。
  final MiThemeMode themeMode;

  /// 预留空位圆钮（`null` = 不启用；侧栏形态挂在**栏尾下方**）。
  final MiGlassNavFab? fab;

  @override
  Widget build(BuildContext context) {
    if (!GlassScope.configOf(context).glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色侧轨（原宽屏实现），功能完整可用。
      // 圆钮不接入（Material rail 无此形态）——与底栏关档丢弃 fab 同口径。
      return NavigationRail(
        selectedIndex: selectedIndex,
        onDestinationSelected: onTabSelected,
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
      );
    }
    return MiGlassSideNavBar(
      items: items,
      selectedIndex: selectedIndex,
      onTap: onTabSelected,
      themeMode: themeMode,
      fab: fab,
    );
  }
}
