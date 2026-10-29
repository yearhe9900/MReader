// 玻璃控件薄封装 + `UI-04` 内容层不透明红线 + `UI-05`/`UI-06` 档位生效接线。
//
// ══════════════════════════════════════════════════════════════════════════════
// UI-04 红线（内容层不透明）—— 违反即返工
// ══════════════════════════════════════════════════════════════════════════════
// 1. 内容层**一律不透明**、**不得**嵌套玻璃（书架 / 目录 / 搜索 / 生词本 / 统计排行行与
//    图表、阅读页正文 / 图片 / 漫画区、详情页封面与简介区，PRD §11.2 + `UI-04`）：
//    统一用 [OpaqueContentSurface]（本文件是「不透明」的**唯一出口**），不要各页
//    自己写 `Container(color:)`。
// 2. `premium` **严禁**进入 `ListView` / `CustomScrollView`（滚动区会渲染异常，
//    PRD §11.2 理由③ + §11.4）；滚动区一律 `standard` 或 `minimal`。
// 3. 玻璃控件**不可嵌套**（`GlassCard` 内不得放 `GlassButton` 等，PRD §11.4），
//    用 [isGlassWidget] debug 自检。
//
// ══════════════════════════════════════════════════════════════════════════════
// UI-05 / UI-06 档位生效接线 —— 本文件是**唯一消费点**
// ══════════════════════════════════════════════════════════════════════════════
// 每个薄封装在 `build` 里经 `GlassScope.configOf(context)` 取**生效配置**（用户偏好 ×
// 「降低视觉特效」× 低端钳制 × 帧预算降档；真值在 `glass_runtime.dart`）：
//   · 固定表面（顶栏 / 底栏）—— 高档不覆盖（库自动提升 `premium`，`UI-05` ①）；
//     中 / 低档以 `GlassIsolationScope(defaultQuality:)` 显式钉 `standard` / `minimal`
//     （库 `GlassThemeHelpers.resolveQuality` 优先级链：最近隔离作用域压过
//     `GlassScaffold` 内层的 `premium` 提示）；
//   · 滚动区 / 浮层 —— 显式传 `scrollQuality`（永不 `premium`）；
//   · 「关」档（`UI-06` ②）—— 整体退化为 Material 纯色（[AppBar] / [NavigationBar] /
//     [Scaffold] / [showDialog] / [showModalBottomSheet]），功能完整可用。
//
// 质量档位策略（PRD §11.3）：固定表面由库 `GlassScaffold → GlassIsolationScope`
// **自动提升 `premium`**（高档下本项目**不手动传 `premium`**）；浮层与滚动区玻璃 →
// `standard`（高档）；P0 **不使用** `adaptiveQuality` / `GlassAdaptiveScope`
// （`@experimental`，首启要跑约 3 秒基准）——自动降级走项目自己的
// `PerfDegradePolicy` + `PerfFrameMonitor`。
import 'dart:async';

// `showCupertinoDialog` 不经 `material.dart` 导出（同 `CupertinoPageTransitionsBuilder`
// 那个坑，见 `lib/theme/app_theme.dart`）——浮层统一配置要用它给确认框透传遮罩色，
// 因为库 `GlassDialog.show` 的 `barrierColor` 是死参数（见 [OverlayStyle.barrier]）。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_material.dart';
import 'glass_runtime.dart';
import 'glass_scope.dart';

/// 玻璃库符号 re-export，业务页面只 import 本文件、**不必直接 import 玻璃库**：
/// [GlassOverlays.showAlert] 的动作按钮、`GlassTab` / `GlassTabBarExtraButton`
/// （导航壳层构造底栏标签）、`GlassLargeTitle`（`CustomScrollView` 首个 sliver）与
/// `GlassLargeTitleController`（[GlassTopBar.largeTitleController] 的参数类型 +
/// 页面 `State` 成员）、`GlassToastType`（[GlassOverlays.showToast] 的语义参数）、
/// `GlassButton` / `GlassChip` / `GlassTextField`（搜索胶囊 / 分组 chips / 搜索输入框
/// 的真玻璃实现）、`GlassDefaults` / `LiquidGlassSettings` / `LiquidRoundedRectangle`
/// （控件级显式材质与胶囊形状）。
export 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassButton,
        GlassChip,
        GlassDefaults,
        GlassDialogAction,
        GlassInteractionBehavior,
        GlassLargeTitle,
        GlassLargeTitleController,
        GlassTab,
        GlassTabBarExtraButton,
        GlassTextField,
        GlassToastType,
        LiquidGlassSettings,
        LiquidRoundedRectangle;

/// 应用默认玻璃质量档位（PRD §11.3，= 高档的滚动区档位）。
///
/// **默认值**常量；运行时生效值见 [GlassKit.overlayQuality]（`UI-05` 接线后随档位变）。
const GlassQuality kAppGlassQuality = GlassQuality.standard;

/// 底栏选中指示块的**液态形变强度**。库默认 `0.4`（iOS 26 折中档）；参考图的
/// 拉宽 + 边缘 pinch 更强 ⇒ `0.75`。**不取 1.0**：满档在 thickness 1.0 时 pinch
/// 深度上限过大、指示块边缘会啃进图标。`0.0` = 关闭（退化为纯平移）。
const double kNavPinchStrength = 0.75;

/// 底栏选中指示块**静止态**的磨砂强度（库默认 `0.0` = 不画静置磨砂）：参考图的
/// 选中块比底栏本体「亮一档」，靠静置磨砂 + 指示块自身的浅色玻璃叠加。`0.0` = 关闭。
const double kNavRestingBlur = 0.6;

/// 档位策略的运行时出口（生效值来自 [GlassRuntime.config]）。
abstract final class GlassKit {
  /// 浮层 / 滚动区玻璃的**生效**档位：高档 / 中档 `standard`、低档 `minimal`。
  static GlassQuality get overlayQuality => GlassRuntime.config.scrollQuality;

  /// 固定表面（顶栏 / 底栏）的生效覆盖值：高档 `null`（库自动提升 `premium`，
  /// `UI-05` ①）；中档 `standard`（取消提升）；低档 `minimal`。本项目**从不**
  /// 手动传 `premium`（`UI-05` ①）。
  static GlassQuality? get fixedSurfaceQualityOverride =>
      GlassRuntime.config.fixedSurfaceQualityOverride;

  /// 特效总开关（`UI-06`）：`false` = 「关」档，全部薄封装退化为纯色。
  static bool get glassEnabled => GlassRuntime.config.glassEnabled;
}

/// 判定一个 [Widget] 是否是「玻璃控件」（`UI-04` 红线的**可判定形式**）。
///
/// 覆盖玻璃库的容器 / 交互 / 输入 / 导航 / 浮层各类表面。用于 debug 自检：
/// 内容层容器内、以及玻璃卡片内，都不应出现玻璃控件。
bool isGlassWidget(Widget widget) =>
    widget is GlassCard ||
    widget is GlassContainer ||
    widget is GlassDivider ||
    widget is GlassGroupedSection ||
    widget is GlassListTile ||
    widget is GlassStepper ||
    widget is GlassButton ||
    widget is GlassIconButton ||
    widget is GlassButtonGroup ||
    widget is GlassChip ||
    widget is GlassBadge ||
    widget is GlassSegmentedControl ||
    widget is GlassSlider ||
    widget is GlassSwitch ||
    widget is GlassProgressIndicator ||
    widget is GlassFormField ||
    widget is GlassTextField ||
    widget is GlassTextArea ||
    widget is GlassPasswordField ||
    widget is GlassSearchBar ||
    widget is GlassPicker ||
    widget is GlassPullDownButton ||
    widget is GlassPageControl ||
    widget is GlassAppBar ||
    widget is GlassTabBar ||
    widget is GlassToolbar ||
    widget is GlassLargeTitle ||
    widget is GlassScaffold ||
    widget is GlassDialog ||
    widget is GlassSheet ||
    widget is GlassModalSheet ||
    widget is GlassMenu ||
    widget is GlassMenuItem ||
    widget is GlassPopover ||
    widget is GlassToast;

/// 内容层不透明容器（`UI-04` 红线的**唯一出口**）。
///
/// 内容层（列表行 / 图表 / 正文区…）必须不透明，且不得直接嵌套玻璃控件。
/// 各页统一用它，而不是自己写 `Container(color:)`——这样才能在一处守住红线：
/// - 底色**强制完全不透明**（alpha 置 1，见 [fullyOpaque]）；
/// - debug 下断言直接子节点不是玻璃控件（玻璃不可嵌套）。
class OpaqueContentSurface extends StatelessWidget {
  /// 创建一个不透明内容容器。
  const OpaqueContentSurface({super.key, required this.child, this.color});

  /// 内容层内容（**不得**是玻璃控件；debug 下自检）。
  final Widget child;

  /// 底色；缺省取 `colorScheme.surface`。**会被强制为完全不透明**。
  final Color? color;

  /// 把一个颜色强制为完全不透明（alpha = 1）。`UI-04` 的「不透明」即此语义。
  static Color fullyOpaque(Color color) => color.withValues(alpha: 1.0);

  /// 该容器实际使用的底色（已强制不透明）。
  Color surfaceColorOf(BuildContext context) =>
      fullyOpaque(color ?? Theme.of(context).colorScheme.surface);

  @override
  Widget build(BuildContext context) {
    assert(
      !isGlassWidget(child),
      'UI-04 红线：OpaqueContentSurface 内不得直接放玻璃控件'
      '（玻璃不可嵌套；内容层须由不透明控件构成）。',
    );
    // 用 Material 提供不透明底色——它同时给出 Material 祖先（玻璃库无 Material 祖先，
    // 见 PRD §11.4），避免其下文本渲染成黄色双下划线。
    return Material(color: surfaceColorOf(context), child: child);
  }
}

// ---------------------------------------------------------------------------
// 导航层（薄封装，最小集；档位生效 + 「关」档纯色退化的唯一出口）
// ---------------------------------------------------------------------------

/// 把 `defaultQuality` 钉进最近的 [GlassIsolationScope]（固定表面降档用）。
/// [GlassScaffold] 内层给条面包了 `GlassIsolationScope(defaultQuality: premium)`；
/// 在条面**更内侧**再包一层同类型作用域即可覆盖该提示（库
/// `GlassThemeHelpers.resolveQuality` 取最近作用域）。[quality] 为 `null`
/// （高档）时不包——维持库自动 `premium` 提升（`UI-05` ①）。
Widget _withFixedSurfaceQuality(GlassQuality? quality, Widget bar) {
  if (quality == null) return bar;
  return GlassIsolationScope(
    isolated: true,
    defaultQuality: quality,
    child: bar,
  );
}

/// 把顶栏标题包成「随手滚动淡入」（[GlassTopBar.largeTitleController] 的
/// **关档等价实现**）。公式**必须与库 `glass_app_bar.dart` 的实现逐字一致**
/// （先取 `collapseProgress` 后半段 `(p - 0.5) / 0.5`、再过 `Curves.easeOut`），
/// 否则切档（玻璃 ⇄ 纯色）会出现标题明暗跳变。为什么自己写：玻璃档走
/// [GlassAppBar]（内建 `ListenableBuilder`），**关档**退化成 Material [AppBar]、
/// 不认 `GlassLargeTitleController`——不补这段，「内容层大标题 + 顶栏标题」
/// 会同时可见（两条一模一样的标题上下叠着）。
Widget? _fadeInBarTitle(Widget? title, GlassLargeTitleController? controller) {
  if (title == null || controller == null) return title;
  return ListenableBuilder(
    listenable: controller,
    builder: (BuildContext context, Widget? child) {
      final double progress = controller.collapseProgress;
      final double barProgress = ((progress - 0.5) / 0.5).clamp(0.0, 1.0);
      return Opacity(
        opacity: Curves.easeOut.transform(barProgress),
        child: child,
      );
    },
    child: title,
  );
}

/// 导航层顶栏（薄封装 [GlassAppBar]）。
///
/// 注意：`GlassAppBar` 的**条面本身是布局容器**，玻璃质感来自条内的按钮
/// （见库文档）——故降档靠 [GlassIsolationScope] 的 `defaultQuality` 提示。
/// 「关」档（`UI-06` ②）退化为 Material [AppBar]。
class GlassTopBar extends StatelessWidget implements PreferredSizeWidget {
  /// 创建玻璃顶栏。
  const GlassTopBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.centerTitle = true,
    this.backgroundColor = const Color(0x00000000),
    this.toolbarHeight = 44.0,
    this.largeTitleController,
  });

  /// 标题区。
  final Widget? title;

  /// 标题前置区。
  final Widget? leading;

  /// 标题后动作区。
  final List<Widget>? actions;

  /// 标题是否居中。
  final bool centerTitle;

  /// 条面背景（透明 = 玻璃质感来自条内控件）。
  final Color backgroundColor;

  /// 工具条高度。
  final double toolbarHeight;

  /// 大标题 ⇄ 顶栏标题的收起联动控制器（可选；设置页大标题用）。
  ///
  /// 传入后顶栏标题**随滚动淡入**：内容层大标题滚走一半才开始出现、滚完完全可见。
  /// **必须**与内容层 `GlassLargeTitle` 共用同一个 `GlassLargeTitleController`
  /// 实例（库要求，见 `glass_large_title.dart:53-173`）——两处都订阅它，
  /// 不存在第二份进度真值。
  ///
  /// 玻璃档直接透传给库（`GlassAppBar.largeTitleController`）；
  /// 「关」档（`UI-06` ②）的 Material [AppBar] 不认该控制器，故由
  /// [_fadeInBarTitle] 复刻同一条淡入曲线。
  final GlassLargeTitleController? largeTitleController;

  /// [Scaffold] 退化路径需要的首选尺寸（= [toolbarHeight]）。
  @override
  Size get preferredSize => Size.fromHeight(toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色顶栏，功能完整可用。
      // 标题淡入需自己补（`AppBar` 不认大标题控制器，见 [_fadeInBarTitle]）。
      return AppBar(
        title: _fadeInBarTitle(title, largeTitleController),
        leading: leading,
        actions: actions,
        centerTitle: centerTitle,
        toolbarHeight: toolbarHeight,
      );
    }
    return _withFixedSurfaceQuality(
      config.fixedSurfaceQualityOverride,
      GlassAppBar(
        title: title,
        leading: leading,
        actions: actions,
        centerTitle: centerTitle,
        backgroundColor: backgroundColor,
        toolbarHeight: toolbarHeight,
        largeTitleController: largeTitleController,
      ),
    );
  }
}

/// 导航层底栏（薄封装 [GlassTabBar.bottom]；库的原生形态即 **iOS 26 浮动胶囊**——
/// 左右 / 底部各留内边距、圆角、64 高，**不是贴底通栏**）。显式传档位（高档
/// `null` = 吃 `GlassScaffold` 的 `premium` 提示）；「关」档退化为 Material [NavigationBar]。
///
/// 显式传 `settings: GlassMaterial.settingsFor(context)`：库的底栏**不吃主题**
/// （私有预设 `kBottomBarGlassDefaults`：blur 3 / 折射 1.59 / 玻璃色 α0.24），
/// 不传就永远是那套；且 [GlassThemeSettings] 表达不了 `whitenStrength`，增白纱罩
/// 只能在控件级给。**形态不变**（拍板：保持悬浮胶囊、只升材质，见 `glass_material.dart`）。
/// 各尺寸参数与库默认一致——**只作显式化**，便于按平台 / 档位微调（`UI-05`）；
/// **不暴露 `barBorderRadius`**（库默认圆角是私有常量，硬编码会与库升级脱钩）。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 触摸反馈口径（拍板：移除「放大」）
/// ══════════════════════════════════════════════════════════════════════════
/// 库 `GlassTabBar` 的 `interactionBehavior` 缺省是 `GlassInteractionBehavior.full`
/// （= 方向光晕 **+** 物理弹簧缩放），薄封装不透传就会以库默认值静默生效（同
/// `showSheet` 未透传 `interactionScale` 一类坑）。故显式传
/// [GlassInteractionBehavior.glowOnly]（只出柔和高光、**不做形变**）。
/// **若连高光也要去掉**：改传 `GlassInteractionBehavior.none`（一行）。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 指示块形变 vs 按下缩放：两套独立机制
/// ══════════════════════════════════════════════════════════════════════════
/// | 观感 | 库参数 | 本项目口径 |
/// |---|---|---|
/// | 整条胶囊被按下时膨胀/回弹 | `interactionBehavior`（`full` 含弹簧缩放） | **保持 [GlassInteractionBehavior.glowOnly]** |
/// | 指示块切换时的拉宽 + 边缘 pinch | `indicatorPinchStrength` | [kNavPinchStrength]（库默认 0.4 → 0.75） |
/// | 指示块静止时的磨砂 | `innerBlur`（库默认 0.0 = 关闭） | [kNavRestingBlur] |
///
/// 指示块滑动的回弹弹簧由库固定（`bottom` 工厂**不透传** `springDescription`），
/// 本封装不暴露无效开关。
/// ⚠️「移除放大」的拍板**不需要撤销**：它指的是**按下时整个胶囊膨胀**（消费点
/// 据此把 `interactionScale` 钉成 1.0），与指示块切换时的形变是两回事，
/// 两条同时成立即库文档推荐的组合。
class GlassNavBar extends StatelessWidget {
  /// 创建玻璃底栏（默认即浮动胶囊形态）。
  const GlassNavBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
    this.extraButton,
    this.standalone = false,
    this.barHeight = 64,
    this.horizontalPadding = 20,
    this.verticalPadding = 20,
    this.spacing = 8,
    this.iconSize = 24,
    this.labelFontSize = 11,
    this.showIndicator = true,
    this.indicatorColor,
    this.selectedIconColor,
    this.unselectedIconColor,
    this.indicatorPinchStrength = kNavPinchStrength,
    this.indicatorInnerBlur = kNavRestingBlur,
  });

  /// 标签页配置。
  final List<GlassTab> tabs;

  /// 当前选中下标。
  final int selectedIndex;

  /// 选中回调。
  final ValueChanged<int> onTabSelected;

  /// 胶囊内的醒目附加按钮（贴右侧、与标签区分开，如「＋」/ 主操作）。
  /// 「关」档（Material [NavigationBar]）**不渲染**该按钮——需要它的页面应
  /// 另有入口（如顶栏按钮）。
  final GlassTabBarExtraButton? extraButton;

  /// 是否作为**独立浮层**使用（没有 [GlassScaffold] 祖先，例如 `Stack` 里浮起的
  /// 胶囊）。库的固定表面 `premium` 提升来自 `GlassScaffold` 内层注入的
  /// `GlassIsolationScope(defaultQuality: premium)`（`UI-05` ①）；脱离该祖先时
  /// `GlassThemeHelpers.resolveQuality` 落到 `fallback = standard`，高档跟不上
  /// 设计意图。`standalone: true` 时本封装**只在高档**显式声明 `premium`，语义与
  /// 「库自动提升」等价——**不是「写死 premium」**（中 / 低档仍由 [GlassScope] 的
  /// `fixedSurfaceQualityOverride` 钉 standard / minimal）。常规用法保持 `false`。
  final bool standalone;

  /// 胶囊高度。
  final double barHeight;

  /// 胶囊左右外边距（`>0` 即「悬浮」、内容在其两侧可见）。
  final double horizontalPadding;

  /// 胶囊底部外边距（浮起高度，安全区由此之上叠加）。
  final double verticalPadding;

  /// 标签之间的间距。
  final double spacing;

  /// 图标尺寸。
  final double iconSize;

  /// 标签文字字号。
  final double labelFontSize;

  /// 是否显示选中指示器（滑动胶囊）。
  final bool showIndicator;

  /// 指示器颜色（缺省随主题 `colorScheme.primary`）。
  final Color? indicatorColor;

  /// 选中态图标颜色。
  final Color? selectedIconColor;

  /// 未选中态图标颜色。
  final Color? unselectedIconColor;

  /// 选中指示块的**液态形变强度**（切换 tab 时横向拉宽、边缘向内 pinch 成透镜）：
  /// 库默认 `0.4`，提到 [kNavPinchStrength]。`1.0` = 满档（thickness 1.0 时的
  /// pinch 深度上限），`0.0` = 完全关闭。
  /// ⚠️ 与「触摸反馈口径」**互不干涉**：pinch 管指示块**切换/拖动**时的形变，
  /// `interactionBehavior` 管**整条胶囊被按下**时的缩放；前者要、后者不要，
  /// 两者可同时成立。
  final double indicatorPinchStrength;

  /// 指示块**静止态**的磨砂强度（`0.0` = 关闭，库默认）：静置带磨砂、与背景
  /// 明确分层，滑动时磨砂化开、morph 成液态透镜；选中块「亮一档」的一部分来源。
  final double indicatorInnerBlur;

  @override
  Widget build(BuildContext context) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色底栏。
      return NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onTabSelected,
        destinations: <NavigationDestination>[
          for (final GlassTab tab in tabs)
            NavigationDestination(
              icon: tab.icon ?? const SizedBox.shrink(),
              selectedIcon: tab.activeIcon,
              label: tab.label ?? '',
            ),
        ],
      );
    }
    return GlassTabBar.bottom(
      tabs: tabs,
      selectedIndex: selectedIndex,
      onTabSelected: onTabSelected,
      extraButton: extraButton,
      barHeight: barHeight,
      horizontalPadding: horizontalPadding,
      verticalPadding: verticalPadding,
      spacing: spacing,
      iconSize: iconSize,
      labelFontSize: labelFontSize,
      showIndicator: showIndicator,
      indicatorColor: indicatorColor,
      selectedIconColor: selectedIconColor,
      unselectedIconColor: unselectedIconColor,
      // 选中块滑动时的液态形变 + 静置磨砂。
      // 这两项**不改按下反馈**（仍是下方glowOnly）——`interactionBehavior` 管
      // 整条胶囊被按下的缩放，pinch / innerBlur 管指示块自身的形变，两套独立。
      indicatorPinchStrength: indicatorPinchStrength,
      innerBlur: indicatorInnerBlur,
      // 固定表面档位：中 / 低档由 `fixedSurfaceQualityOverride` 钉死（取消提升）；
      // 高档为 `null` —— 在 [GlassScaffold] 祖先内（默认用法）库会自动提升 `premium`
      // （§11.3 / `UI-05 ①`）；若是独立浮层（[standalone]），该祖先不存在、
      // `resolveQuality` 会落到 `fallback = standard`，故显式补上 `premium`。
      quality:
          config.fixedSurfaceQualityOverride ??
          (standalone ? GlassQuality.premium : null),
      // 触摸反馈：移除「放大」（不做形变、保留手指位置的柔和高光）
      // —— 见 [GlassNavBar] doc 的「触摸反馈口径」。库默认是 `full`（光晕 + 弹簧缩放）。
      interactionBehavior: GlassInteractionBehavior.glowOnly,
      // 材质：控件级显式设置（库底栏不吃主题 + 主题无 whitenStrength；
      // 固定表面档位仍由上面的 quality 逻辑决定）。
      settings: GlassMaterial.settingsFor(context),
    );
  }
}

/// 导航壳层（薄封装 [GlassScaffold]）。
///
/// 保证顶栏 / 底栏玻璃永远绘制在正文之上；正文请用
/// [OpaqueContentSurface] 承载（`UI-04`）。[extendBody] 决定正文是否穿顶栏
/// （edge-to-edge + 顶栏下磨砂模糊，`UI-02` ②）。「关」档（`UI-06` ②）退化为
/// Material [Scaffold]（appBar 由 [GlassTopBar] 自身退化，这里只换壳）。
class GlassNavScaffold extends StatelessWidget {
  /// 创建玻璃导航壳层。
  const GlassNavScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomBar,
    this.background,
    this.extendBody = false,
  });

  /// 页面正文（内容层请用 [OpaqueContentSurface] 承载）。
  final Widget body;

  /// 顶栏（通常 [GlassTopBar]）。
  final Widget? appBar;

  /// 底栏（通常 [GlassNavBar]）。
  final Widget? bottomBar;

  /// 背景层（仅玻璃档生效；退化档由 Scaffold 自身背景承担）。
  final Widget? background;

  /// 正文是否铺满全屏、从顶栏下**穿过**（edge-to-edge；`UI-02` ②）。
  ///
  /// 默认 `false` = 正文避让顶栏，多数页面保持此形态。传 `true` 后正文从 y=0 起、
  /// 滚动时从玻璃顶栏下穿过，顶栏下方内容透出**磨砂模糊**（`GlassScrollEdgeStyle.blur`，
  /// 即 PRD `UI-02` ②「滚动时顶栏下内容透出模糊而非纯色遮挡」的正式落地形态）。
  /// **传 `true` 的页面必须自行保证「首行不被盖住」**：给滚动内容的 `padding.top`
  /// 留出 `状态栏 + 顶栏高 + 间距`（书架见 `shelfGridPadding`），否则网格首行会被
  /// 浮动顶栏永久压住；`test/ui/glass_nav_inset_test.dart` 对**默认 `false`** 保留回归锁。
  final bool extendBody;

  @override
  Widget build(BuildContext context) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色壳层，功能完整可用。
      // `extendBodyBehindAppBar` 与 [extendBody] 同语义（正文是否穿顶栏）；
      // 此档无磨砂渐隐（Material 无此物），正文从实心 AppBar 后滑过。
      return Scaffold(
        appBar: appBar is PreferredSizeWidget
            ? appBar! as PreferredSizeWidget
            : null,
        body: body,
        bottomNavigationBar: bottomBar,
        extendBodyBehindAppBar: extendBody,
      );
    }
    return GlassScaffold(
      body: body,
      appBar: appBar,
      bottomBar: bottomBar,
      background: background,
      // [extendBody] 语义：库默认 `true` → 正文铺满整屏从 y=0 起；`false` →
      // 正文避让顶栏。默认保持 `false`（漏传该参数曾把书架筛选栏顶进状态栏、
      // 网格首行被顶栏盖住）；库文档声称会「automatically add a top spacer」，
      // 但全文**零处实现**——以代码为准。
      //
      // 书架页显式传 `true`：内容 edge-to-edge、从浮动玻璃头部下穿过，首行保护
      // 改由页面自己的 `padding.top` 承担（见 [extendBody] 文档）。
      // **传 true 必须配套内容顶部留白。**
      //
      // 底部不受影响：本项目底栏是 `home_shell` 自己 `Positioned` 的浮动胶囊，
      // **不走** `GlassScaffold.bottomBar`，故 `bottomBar == null` → 两档 `bottom`
      // 恒 0，底部留白仍由各页的 `kShellBottomInset` 独立承担。
      extendBody: extendBody,
      // 边缘效果：**blur 档**（`UI-02` ②「顶栏下内容透出模糊」）。库默认 `soft`
      // 是「内容渐隐进背景」= 接近该验收项否定的「纯色遮挡」；`blur` 把穿顶栏
      // 滚动的内容渐进磨砂（顶部 sigma 最高）。仅 `extendBody: true` 时生效。
      // 代价（库文档自述）：Skia/Android 上 `BackdropFilterLayer` 逐帧合成，比
      // soft 略贵——要退回渐隐档改传 `GlassScrollEdgeStyle.soft`（一行）。
      edgeStyle: GlassScrollEdgeStyle.blur,
    );
  }
}

// ---------------------------------------------------------------------------
// 浮层（薄封装，最小集；档位生效 + 「关」档纯色退化）
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 浮层共有配置（对话框 / 底部弹窗 / 轻提示 三处入口的**唯一**参数源）
// ---------------------------------------------------------------------------
// 背景：遮罩色与形态参数曾散在 `showAlert` / `showSheet` 各自的默认值与方法体里，
// 四个入口的遮罩来自三个不同源头（库 `GlassDialog.show` 的 `barrierColor` 是**死参数**、
// 未透传；Material `DialogRoute` 默认 `Colors.black54` = 已判「太重的灰」那个值）。
// 拍板：① 四路遮罩**全统一**；② 统一范围 = **遮罩 + 形态 + 尺寸**。故 [OverlayStyle]
// 是本项目浮层参数的**唯一事实源**：三个入口一律从这里取，**不要在方法体里另写
// 默认值**。玻璃档与「关」档共用 [OverlayStyle.barrier]（两档观感一致）；其余
// 「玻璃专属」项（形态 / 尺寸）在关档退化为 Material 时**不适用**——关档走平台
// 标准外观（`maxWidth` 等是玻璃档参数，见 `showAlert` 注释）。

/// 浮层（对话框 / 底部弹窗 / 轻提示）的共有配置——**本项目浮层参数的唯一事实源**。
///
/// 改这里即三处入口同改；**不要在 [GlassOverlays.showAlert] /
/// [GlassOverlays.showSheet] 的方法体里另写常量**（那就又散回去了）。
/// 契约测试：`test/ui/overlay_style_test.dart`（常量字面量）+
/// `test/ui/glass_sheet_form_test.dart`（玻璃档四路遮罩与形态尺寸的透传）。
abstract final class OverlayStyle {
  /// 模态遮罩色——**四个入口**（玻璃/关 × 弹窗/确认框）共用同一色源。
  ///
  /// **为什么必须压淡**（不只是审美）：遮罩与弹窗共用 350ms 转场，而弹窗从屏幕外
  /// 滑入 ⇒ 头 ~150ms「灰幕已到场、弹窗还没进屏」，深灰在那一瞬就是一条**纯灰幕**
  /// （详见 `GlassOverlays.showSheet`）。**取值** `0x3D000000`（α ≈ **0.24**，约库
  /// 默认的 45%）——既保留「背后内容退到次要层」的模态语义（`UI-03` 浮层玻璃要求
  /// 遮罩在场、「点遮罩关闭」也要有可点的遮罩面），又不会在弹窗到位前形成突兀
  /// 灰幕。**只换色源、不动时序**（同 `bookCoverShadowOf` 口径）：时序归库，要改
  /// 就得抄一份 `showGeneralDialog` 并放弃库的液态玻璃渲染，代价不成比例。
  ///
  /// ⚠️ **统一带来的代价（真机对照项）**：暗色主题下确认框遮罩变淡、模态压迫感
  /// 减弱；若真机觉得「压不住背景」，**只调本项**（四个入口同步变重，正是
  /// 「统一」的本意）。
  static const Color barrier = Color(0x3D000000);

  // ── 形态：触摸反馈 ──────────────────────────────────────────────────────────
  // 拍板「去除弹框点击放大高亮特效」。三项均为薄封装原先吃掉的**库默认值**
  // （同 `GlassScaffold.extendBody` 一类坑），故在此写死：「点击放大」=
  // `interactionScale`；「点击高亮」= `enableInteractionGlow` + `enableSaturationGlow`
  // （两条独立通路）。

  /// 按压缩放系数——`1.0` 即**无放大**。
  static const double interactionScale = 1.0;

  /// 触摸光晕（跟随手指的高光）——关。
  static const bool interactionGlow = false;

  /// 触摸饱和度脉冲——关。
  static const bool saturationGlow = false;

  // ── 形态：拖拽 ─────────────────────────────────────────────────────────────
  // 拍板「不需要上划的弹框，去除小横条」：「上划」= **禁止拖拽关闭手势**
  // （`enableDrag: false` 后库完全不加拖拽手势、零副作用；**底部滑入的入场动画
  // 保留**、与 `enableDrag` 无关；**点遮罩关闭不变**）。

  /// 顶部小横条——关（库内还带一个覆盖顶部的可拖拽 `handleZone`）。
  static const bool dragIndicator = false;

  /// 拖拽关闭手势——关。
  static const bool enableDrag = false;

  // ── 尺寸 ───────────────────────────────────────────────────────────────────

  /// 确认框最大宽（与库 `GlassDialog` 默认同值——iOS 标准警示框宽度）。
  ///
  /// 关档（Material `AlertDialog`）**不适用**：走平台标准宽度，见 [GlassOverlays.showAlert]。
  static const double dialogMaxWidth = 280;

  /// 底部弹窗顶部圆角（与库 `GlassSheet` 默认同值）。
  static const double sheetTopBorderRadius = 32;

  /// 底部弹窗外边距（与库 `GlassSheet` 默认同值：左右各留 8，露出背后内容）。
  static const EdgeInsets sheetMargin =
      EdgeInsets.symmetric(horizontal: 8, vertical: 8);

  /// 轻提示停留时长（比库默认 3s 短 1s——本项目的提示都是短反馈）。
  static const Duration toastDuration = Duration(seconds: 2);

  // ── 明确**不**在此收口的（免得看起来是"漏了"）─────────────────────────────
  // · `quality` —— 是**运行时值**（`GlassScope.configOf(context).scrollQuality`），
  //   随用户偏好 ×「降低视觉特效」× 帧预算降档变，不是常量，见各入口；
  // · `isScrollable` —— 由调用场景决定（内容自带列表时传 `false`，防纵向滚动嵌套）；
  // · `padding` —— **内容自持**：库中 `null` 即 `EdgeInsets.zero`
  //   （`glass_sheet.dart:562,569`），各弹层内容自己给内边距；
  // · `stretch` / `resistance` / `glowRadius` —— 拖拽与光晕关掉后已无触发路径；
  // · `settings` / `bottomBorderRadius` / `dragIndicatorColor` —— 未定制，走库默认。
}

/// 浮层玻璃入口（对话框 / 底部弹窗）。
///
/// 档位随 [GlassScope.configOf]（滚动区 / 浮层档），**不传 `premium`**（§11.3）；
/// 「关」档（`UI-06` ②）退化为 Material [showDialog] / [showModalBottomSheet]。
abstract final class GlassOverlays {
  /// 浮层**生效**档位（见 [GlassKit.overlayQuality]）。
  static GlassQuality get quality => GlassKit.overlayQuality;

  /// 弹出玻璃确认框（薄封装 [GlassDialog.show]；「关」档退化 [showDialog]）。
  ///
  /// 返回值语义与 `showDialog<T>` 一致：动作回调里 `Navigator.pop(ctx, value)`，
  /// barrier 关闭（[barrierDismissible]）返回 `null`。[barrierDismissible] 缺省
  /// `false`（库默认）——确认框须显式选择，防误触取消。
  /// ⚠️ **玻璃档不走 `GlassDialog.show`**（它的 `barrierColor` 是**死参数**，无法
  /// 经由它统一遮罩，缘由见方法体内注释）。外观与行为逐项等价，只是遮罩色与
  /// `maxWidth` 都改从 [OverlayStyle] 取（`test/ui/glass_sheet_form_test.dart` 钉住）。
  static Future<T?> showAlert<T>({
    required BuildContext context,
    required List<GlassDialogAction> actions,
    String? title,
    String? message,
    Widget? content,
    bool barrierDismissible = false,
    double maxWidth = OverlayStyle.dialogMaxWidth,
  }) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色对话框（maxWidth 为玻璃档参数，退化档
      // 用平台标准宽度，功能完整可用）。
      return showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        // 遮罩统一：Material `DialogRoute` 默认 `Colors.black54`（`0x8A000000`、
        // **α0.541**）正是已判「太重」的那个值，这里显式换成共用的 [OverlayStyle.barrier]。
        barrierColor: OverlayStyle.barrier,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: title == null ? null : Text(title),
          content: message == null && content == null
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (message != null) Text(message),
                    ?content,
                  ],
                ),
          actions: <Widget>[
            for (final GlassDialogAction action in actions)
              TextButton(
                onPressed: action.onPressed,
                child: Text(
                  action.label,
                  style: TextStyle(
                    fontWeight: action.isPrimary ? FontWeight.bold : null,
                    color: action.isDestructive
                        ? Theme.of(dialogContext).colorScheme.error
                        : null,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    // 玻璃档：**不经** `GlassDialog.show` —— 它的 `barrierColor` 是**死参数**
    // （`glass_dialog.dart:268` 声明、`:271-283` 调 `showCupertinoDialog` 时未透传），
    // 无法经由它设置遮罩色；统一配置要求确认框也用 [OverlayStyle.barrier]，
    // 故照抄它那 12 行自行透传。除遮罩外与 `GlassDialog.show` **逐项等价**：
    // 同一个 `showCupertinoDialog`、同一个 [GlassDialog] widget、同一套默认
    // （`useRootNavigator: true`、`barrierDismissible` 透传、`barrierLabel` 留空
    // 交由 `CupertinoDialogRoute` 取 `modalBarrierDismissLabel`、转场仍是
    // `CupertinoDialogRoute` 的 250ms spring）。
    return showCupertinoDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: OverlayStyle.barrier,
      builder: (BuildContext dialogContext) => GlassDialog(
        title: title,
        message: message,
        content: content,
        actions: actions,
        quality: config.scrollQuality,
        maxWidth: maxWidth,
      ),
    );
  }

  /// 弹出玻璃底部弹窗（薄封装 [GlassSheet.show]；「关」档退化 [showModalBottomSheet]）。
  ///
  /// [isScrollable] 缺省 `true`（库默认，内容外包 `SingleChildScrollView`）；
  /// 内容自带可滚动列表时（如目录 `TocSheet` 的 `ListView`）传 `false`，
  /// 避免纵向滚动视图嵌套（外层会吃掉内层的拖拽手势）。
  ///
  /// ══════════════════════════════════════════════════════════════════════════
  /// 本项目弹层形态口径 —— 参数**统一收在 [OverlayStyle]**（本方法只负责透传）
  /// ══════════════════════════════════════════════════════════════════════════
  /// 拍板「去除弹框点击放大高亮特效、不需要上划的弹框、去除小横条」：①「上划」=
  /// **禁止拖拽关闭手势**（保留底部滑入动画）；② **全部弹层统一生效**。症状与库
  /// 参数一一对应（原先吃库默认值，同 `GlassScaffold.extendBody` 一类坑，故写死）：
  /// 「点击放大」= `interactionScale` → 1.0；「点击高亮」= `enableInteractionGlow`
  /// + `enableSaturationGlow` → 均关；「小横条」= `showDragIndicator` → 关；
  /// 「上划」= `enableDrag` → 关。
  ///
  /// **「上划」的确切含义**：`enableDrag: false` 后库完全不加拖拽 `GestureDetector`，
  /// 零副作用；**底部滑入的入场动画保留**（独立 `SlideTransition`，与 `enableDrag`
  /// 无关）；**点遮罩关闭不变**。**未动**：`stretch`（拖拽液态拉伸）与
  /// `topBorderRadius` 等外观参数——前者不属「放大」，且已无拖拽手势触发它。
  /// 「关」档（`UI-06` ②）同步 `enableDrag: false`，并**删去自绘的拖拽指示条**。
  ///
  /// ══════════════════════════════════════════════════════════════════════════
  /// 弹层遮罩 —— 显式传 [OverlayStyle.barrier]
  /// ══════════════════════════════════════════════════════════════════════════
  /// 症状（§2.56，历史例：书架长按操作单——该入口 2026-10-23 起改走 mi_like_ui
  /// `MiDialog`，其余底部弹层同此口径）：**在弹层露头之前**整屏先蒙一层灰。根因：遮罩与
  /// 弹窗共用 350ms 转场，而弹窗从屏幕外滑入 ⇒ 头 ~150ms「灰幕已铺开、弹窗还没
  /// 进屏」。处置：**只换遮罩色源、不动时序**（与 `bookCoverShadowOf` 同口径）——
  /// 两档**都**显式传同一个 [OverlayStyle.barrier]。**为什么不改时序**：转场时长
  /// 与滑入动画都是库内部构造，要改就得抄一份 `showGeneralDialog`（放弃库的液态
  /// 玻璃渲染）；遮罩压淡后「弹窗迟到」在观感上就不再是一条灰幕。
  static Future<T?> showSheet<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollable = true,
  }) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色底部弹窗（保留滚动语义；无横条、
      // 不可拖拽关闭，与玻璃档口径一致）。
      return showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        enableDrag: false,
        // 遮罩统一：两档共用 [OverlayStyle.barrier]。
        barrierColor: OverlayStyle.barrier,
        builder: (BuildContext sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isScrollable)
                Flexible(
                  child: SingleChildScrollView(child: builder(sheetContext)),
                )
              else
                builder(sheetContext),
            ],
          ),
        ),
      );
    }
    return GlassSheet.show<T>(
      context: context,
      builder: builder,
      quality: config.scrollQuality,
      isScrollable: isScrollable,
      // 以下各项一律取自 [OverlayStyle]（浮层参数的唯一事实源）：
      // 「无横条、不可拖拽关闭、无触摸放大 / 光晕 / 饱和度脉冲」口径 + 尺寸 +
      // 遮罩色（库默认 0x8A000000 太重、且先于弹窗可见，见上方本方法注释）。
      showDragIndicator: OverlayStyle.dragIndicator,
      enableDrag: OverlayStyle.enableDrag,
      interactionScale: OverlayStyle.interactionScale,
      enableInteractionGlow: OverlayStyle.interactionGlow,
      enableSaturationGlow: OverlayStyle.saturationGlow,
      topBorderRadius: OverlayStyle.sheetTopBorderRadius,
      margin: OverlayStyle.sheetMargin,
      barrierColor: OverlayStyle.barrier,
    );
  }

  /// 轻提示（操作结果反馈；薄封装 `GlassToast.show`）。
  ///
  /// **为什么不用 `ScaffoldMessenger.showSnackBar`**：玻璃壳层（`GlassScaffold`
  /// 内层是 `CupertinoPageScaffold`）与窄屏浮动底栏布局**都没有 Material
  /// `Scaffold`**，`_scaffolds` 为空 → `showSnackBar` 断言失败（debug 崩、release
  /// `_scaffolds.last` 抛 `StateError`）。故轻提示一律走 **Overlay 浮层**，
  /// 不依赖任何 `Scaffold` 祖先。
  ///
  /// 「关」档（`UI-06` ②）退化为纯色浮层（[_PlainToast]），零玻璃效果。
  ///
  /// 返回**手动关闭**回调（同 `GlassToast.show`）；不调用则按时长自动消失。
  static VoidCallback showToast({
    required BuildContext context,
    required String message,
    GlassToastType type = GlassToastType.neutral,
    Duration duration = OverlayStyle.toastDuration,
  }) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      return _showPlainToast(context, message: message, duration: duration);
    }
    return GlassToast.show(
      context,
      message: message,
      type: type,
      duration: duration,
      quality: config.scrollQuality,
    );
  }
}

/// 「关」档纯色轻提示（[GlassOverlays.showToast] 的退化实现，零玻璃）。
///
/// 同样**不依赖 `Scaffold`**（壳层没有）：`OverlayEntry` + 自管定时移除。
/// 计时器在 [State.dispose] 里取消 —— 测试结束时绑定会先卸载整棵 widget 树
/// （`binding.dart` `_runTestBody`：`runApp(Container())` → `pump()` →
/// `_verifyInvariants()`），于是不会留下 pending `Timer`。
VoidCallback _showPlainToast(
  BuildContext context, {
  required String message,
  required Duration duration,
}) {
  final OverlayState overlayState = Overlay.of(context);
  late final OverlayEntry entry;
  void dismiss() => entry.remove();
  entry = OverlayEntry(
    builder: (_) =>
        _PlainToast(message: message, duration: duration, onDismissed: dismiss),
  );
  overlayState.insert(entry);
  return dismiss;
}

class _PlainToast extends StatefulWidget {
  const _PlainToast({
    required this.message,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_PlainToast> createState() => _PlainToastState();
}

class _PlainToastState extends State<_PlainToast> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.duration > Duration.zero) {
      _timer = Timer(widget.duration, () {
        if (mounted) widget.onDismissed();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.of(context).padding.bottom + 16,
      // 轻提示不拦截手势：浮在内容上但不抢焦点（`IgnorePointer`）。
      child: IgnorePointer(
        child: Semantics(
          liveRegion: true,
          label: widget.message,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: theme.shadowColor.withValues(alpha: 0.15),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Text(
                widget.message,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
