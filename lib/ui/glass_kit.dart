// 玻璃控件薄封装 + `UI-04` 内容层不透明红线 + `UI-05`/`UI-06` 档位生效接线。
//
// ══════════════════════════════════════════════════════════════════════════════
// UI-04 红线（内容层不透明）—— 违反即返工
// ══════════════════════════════════════════════════════════════════════════════
// 1. 内容层**一律不透明**、**不得**嵌套玻璃。内容层包括：书架列表行、目录列表行、
//    搜索结果行、生词本行、**统计排行列表行与统计图表**、**阅读页正文区 / 图片区 / 漫画页**、
//    书籍详情页的封面区与简介文本区（PRD §11.2 + `UI-04`）。
//    内容层统一用 [OpaqueContentSurface]（本文件是「不透明」的**唯一出口**），
//    不要各页自己写 `Container(color:)`。
// 2. `premium` **严禁**进入 `ListView` / `CustomScrollView` —— 放进滚动区会渲染异常
//    （PRD §11.2 理由③ + §11.4）。滚动区一律 `standard` 或 `minimal`。
// 3. 玻璃控件**不可嵌套** —— 玻璃卡片里只能放不透明内容（`GlassCard` 内不得再放
//    `GlassButton` 等，PRD §11.4）。用 [isGlassWidget] 在 debug 下自检。
//
// ══════════════════════════════════════════════════════════════════════════════
// UI-05 / UI-06 档位生效接线（M2b-T07 接线批）—— 本文件是**唯一消费点**
// ══════════════════════════════════════════════════════════════════════════════
// 每个薄封装在 `build` 里经 `GlassScope.configOf(context)` 取**生效配置**
// （用户偏好 ×「降低视觉特效」× 低端钳制 × 帧预算降档；真值在 `glass_runtime.dart`）：
//   · 固定表面（顶栏 / 底栏）—— 高档不覆盖（库自动提升 `premium`，`UI-05` ①）；
//     中 / 低档以 `GlassIsolationScope(defaultQuality:)` 显式钉 `standard` / `minimal`
//     （库 `GlassThemeHelpers.resolveQuality` 优先级链：最近的隔离作用域 defaultQuality
//     压过 `GlassScaffold` 内层的 `premium` 提示）；
//   · 滚动区 / 浮层 —— 显式传 `scrollQuality`（永不 `premium`）；
//   · 「关」档（`UI-06` ②）—— 整体退化为 Material 纯色（[AppBar] / [NavigationBar] /
//     [Scaffold] / [showDialog] / [showModalBottomSheet]），功能完整可用。
//
// 质量档位策略（PRD §11.3）：
//   · 固定表面（顶栏 / 底栏）→ 由库的 `GlassScaffold → GlassIsolationScope` **自动提升为
//     `premium`**，高档下本项目**不手动传 `premium`**；
//   · 浮层（对话框 / 底部弹窗）与滚动区内的玻璃 → `standard`（高档）；
//   · P0 **不使用** `adaptiveQuality` / `GlassAdaptiveScope`（`@experimental`，首启要跑
//     约 3 秒基准，PRD §11.3）。自动降级走项目自己的 `PerfDegradePolicy` + `PerfFrameMonitor`。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_runtime.dart';
import 'glass_scope.dart';

/// 玻璃对话框动作按钮类型（[GlassOverlays.showAlert] 的参数元素）——
/// 在此 re-export，调用方只需 import 本文件。
///
/// 同 `GlassTab` / `GlassTabBarExtraButton`：导航壳层（`home_shell.dart`）需要它们
/// 构造底栏标签，re-export 后全仓页面**不必直接 import 玻璃库**。
///
/// `GlassLargeTitle` / `GlassLargeTitleController` 同理（2026-09-29 设置页大标题）：
/// 前者要作为 `CustomScrollView` 的首个 sliver，后者既是
/// [GlassTopBar.largeTitleController] 的参数类型、又是页面 `State` 的成员
/// ——不 re-export 的话，用到大标题的页面就必须直接 import 玻璃库。
///
/// `GlassToastType` 同理（[GlassOverlays.showToast] 的语义参数）。
export 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassDialogAction,
        GlassLargeTitle,
        GlassLargeTitleController,
        GlassTab,
        GlassTabBarExtraButton,
        GlassToastType;

/// 应用默认玻璃质量档位（PRD §11.3，= 高档的滚动区档位）。
///
/// **默认值**常量；运行时生效值见 [GlassKit.overlayQuality]（`UI-05` 接线后随档位变）。
const GlassQuality kAppGlassQuality = GlassQuality.standard;

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
    return Material(
      color: surfaceColorOf(context),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// 导航层（薄封装，最小集；档位生效 + 「关」档纯色退化的唯一出口）
// ---------------------------------------------------------------------------

/// 把 `defaultQuality` 钉进最近的 [GlassIsolationScope]（固定表面降档用）。
///
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
/// **关档等价实现**）。
///
/// 公式照抄库 `glass_app_bar.dart:426-436`：先取 `collapseProgress` 的**后半段**
/// （`(p - 0.5) / 0.5`），再过 `Curves.easeOut`——即大标题走完一半才开始出现、
/// 走完才完全可见。两处**必须逐字一致**，否则切档（玻璃 ⇄ 纯色）会出现
/// 标题明暗跳变。
///
/// 为什么必须自己写：玻璃档走 [GlassAppBar]，它内建 `ListenableBuilder`
/// （`glass_app_bar.dart:421-438`）；**关档**退化成 Material [AppBar]，
/// `AppBar` 不认 `GlassLargeTitleController`。不补这段，「内容层大标题 + 顶栏标题」
/// 会同时可见（两条一模一样的「设置」上下叠着）。
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

  /// 大标题 ⇄ 顶栏标题的收起联动控制器（可选；2026-09-29 设置页大标题用）。
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
/// 左右 / 底部各留内边距、圆角、64 高，**不是贴底通栏**）。
///
/// 显式传档位（高档 `null` = 吃 `GlassScaffold` 的 `premium` 提示）；
/// 「关」档退化为 Material [NavigationBar]。
///
/// 各尺寸参数的默认值与库一致——传出去等价于不传，**只作显式化**，
/// 便于将来按平台/档位微调（`UI-05`）。**不暴露 `barBorderRadius`**：
/// 库的默认圆角是私有常量，硬编码会与库升级脱钩。
///
/// ══════════════════════════════════════════════════════════════════════════
/// 触摸反馈口径（2026-09-29 拍板：移除「放大」）
/// ══════════════════════════════════════════════════════════════════════════
/// 负责人「移除导航栏放大特效」。库 `GlassTabBar` 的 `interactionBehavior` 缺省是
/// **`GlassInteractionBehavior.full`**（= 方向光晕 **+** 物理弹簧缩放；doc 自述
/// "the glass **inflates** subtly (bottom-anchored spring) on touch"），本项目原先
/// **未透传** → 点击底栏时整个胶囊会膨胀（同 `showSheet` 未透传 `interactionScale`
/// 一类坑：薄封装没暴露的参数会以库默认值静默生效）。
///
/// 现显式传 [GlassInteractionBehavior.glowOnly]（= 只手指出现柔和高光、**不做形变**，
/// 库 doc 正是推荐给「flat navigation bars that should remain spatially stable
/// while still feeling reactive to touch」；消费点 `tab_bar_bottom_layout.dart:390`
/// 据此把 `interactionScale` 钉成 `1.0`）。
///
/// **若连高光也要去掉**：改传 `GlassInteractionBehavior.none` 即可（一行，
/// 该档 doc："fully rigid glass, no directional glow"）。
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
  });

  /// 标签页配置。
  final List<GlassTab> tabs;

  /// 当前选中下标。
  final int selectedIndex;

  /// 选中回调。
  final ValueChanged<int> onTabSelected;

  /// 胶囊内的醒目附加按钮（贴右侧、与标签区分开，如「＋」/ 主操作）。
  ///
  /// 「关」档（Material [NavigationBar]）**不渲染**该按钮——退化档以功能完整为准，
  /// 需要它的页面应另有入口（如顶栏按钮）。
  final GlassTabBarExtraButton? extraButton;

  /// 是否作为**独立浮层**使用（没有 [GlassScaffold] 祖先，例如 `Stack` 里浮起的胶囊）。
  ///
  /// 库的固定表面 `premium` 提升来自 `GlassScaffold` 内层注入的
  /// `GlassIsolationScope(defaultQuality: premium)`（`UI-05 ①`）。脱离该祖先时
  /// `GlassThemeHelpers.resolveQuality` 会落到 `fallback = GlassQuality.standard`，
  /// 高档就跟不上设计意图。`standalone: true` 时本封装**只在高档**显式声明
  /// `premium`，语义与「库自动提升」等价——**不是「写死 premium」**：
  /// 中 / 低档仍由 [GlassScope] 的 `fixedSurfaceQualityOverride` 钉 standard / minimal。
  ///
  /// `GlassNavScaffold` 内的常规用法保持 `false`。
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
      // 固定表面档位：中 / 低档由 `fixedSurfaceQualityOverride` 钉死（取消提升）；
      // 高档为 `null` —— 在 [GlassScaffold] 祖先内（默认用法）库会自动提升 `premium`
      // （§11.3 / `UI-05 ①`）；若是独立浮层（[standalone]），该祖先不存在、
      // `resolveQuality` 会落到 `fallback = standard`，故显式补上 `premium`。
      quality: config.fixedSurfaceQualityOverride ??
          (standalone ? GlassQuality.premium : null),
      // 触摸反馈：移除「放大」（不做形变、保留手指位置的柔和高光）
      // —— 见 [GlassNavBar] doc 的「触摸反馈口径」。库默认是 `full`（光晕 + 弹簧缩放）。
      interactionBehavior: GlassInteractionBehavior.glowOnly,
    );
  }
}

/// 导航壳层（薄封装 [GlassScaffold]）。
///
/// 保证顶栏 / 底栏玻璃永远绘制在正文之上，并给内容边缘做渐隐；正文请用
/// [OpaqueContentSurface] 承载（`UI-04`）。「关」档（`UI-06` ②）退化为 Material
/// [Scaffold]（appBar 由 [GlassTopBar] 自身退化，这里只换壳）。
class GlassNavScaffold extends StatelessWidget {
  /// 创建玻璃导航壳层。
  const GlassNavScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomBar,
    this.background,
  });

  /// 页面正文（内容层请用 [OpaqueContentSurface] 承载）。
  final Widget body;

  /// 顶栏（通常 [GlassTopBar]）。
  final Widget? appBar;

  /// 底栏（通常 [GlassNavBar]）。
  final Widget? bottomBar;

  /// 背景层（仅玻璃档生效；退化档由 Scaffold 自身背景承担）。
  final Widget? background;

  @override
  Widget build(BuildContext context) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色壳层，功能完整可用。
      return Scaffold(
        appBar: appBar is PreferredSizeWidget ? appBar! as PreferredSizeWidget : null,
        body: body,
        bottomNavigationBar: bottomBar,
      );
    }
    return GlassScaffold(
      body: body,
      appBar: appBar,
      bottomBar: bottomBar,
      background: background,
      // 顶栏避让（批次① `06063c8` 漏传的参数，2026-09-29 修）。
      //
      // 库默认 `extendBody: true` → `glass_scaffold.dart:487-489` 走
      // `Positioned.fill`，**正文铺满整屏、从 y=0 起、完全不避让顶栏**：
      // 书架的筛选栏被顶进状态栏、网格首行封面被顶栏盖住（真机截图实证）。
      // `extendBody: false` 才走 `:491-494` 的 `top: topPad + appBarHeight`。
      // 库文档 `:153` / `:83` 声称会「automatically add a top spacer」，
      // 但 1.7.0 全文 grep 只有这三处文字、**零处实现**——以代码为准。
      //
      // 底部不受影响：本项目底栏是 `home_shell` 自己 `Positioned` 的
      // 浮动胶囊，**不走** `GlassScaffold.bottomBar`，故 `bottomBar == null`
      // → `bottom: 0`，底部留白仍由各页的 `kShellBottomInset` 独立承担。
      //
      // 已知代价：`:458` 的 `if (extendBody && …)` 不再成立，正文不再包
      // `GlassScrollEdgeEffect` → **顶栏下方的滚动渐隐一并关闭**（拍板取舍）。
      extendBody: false,
    );
  }
}

// ---------------------------------------------------------------------------
// 浮层（薄封装，最小集；档位生效 + 「关」档纯色退化）
// ---------------------------------------------------------------------------

/// 浮层玻璃入口（对话框 / 底部弹窗）。
///
/// 档位随 [GlassScope.configOf]（滚动区 / 浮层档），**不传 `premium`**（§11.3）；
/// 「关」档（`UI-06` ②）退化为 Material [showDialog] / [showModalBottomSheet]。
abstract final class GlassOverlays {
  /// 浮层**生效**档位（见 [GlassKit.overlayQuality]）。
  static GlassQuality get quality => GlassKit.overlayQuality;

  /// 弹出玻璃确认框（薄封装 [GlassDialog.show]；「关」档退化 [showDialog]）。
  ///
  /// 返回值语义与 `showDialog<T>` 一致：动作回调里
  /// `Navigator.pop(ctx, value)`，barrier 关闭（[barrierDismissible]）返回 `null`。
  /// [barrierDismissible] 缺省 `false`（库默认）——确认框须显式选择，防误触取消。
  static Future<T?> showAlert<T>({
    required BuildContext context,
    required List<GlassDialogAction> actions,
    String? title,
    String? message,
    Widget? content,
    bool barrierDismissible = false,
    double maxWidth = 280,
  }) {
    final GlassTierConfig config = GlassScope.configOf(context);
    if (!config.glassEnabled) {
      // 「关」档（`UI-06` ②）：Material 纯色对话框（maxWidth 为玻璃档参数，退化档
      // 用平台标准宽度，功能完整可用）。
      return showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
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
    return GlassDialog.show<T>(
      context: context,
      actions: actions,
      title: title,
      message: message,
      content: content,
      quality: config.scrollQuality,
      barrierDismissible: barrierDismissible,
      maxWidth: maxWidth,
    );
  }

  /// 弹出玻璃底部弹窗（薄封装 [GlassSheet.show]；「关」档退化 [showModalBottomSheet]）。
  ///
  /// [isScrollable] 缺省 `true`（库默认，内容外包 `SingleChildScrollView`）；
  /// 内容自带可滚动列表时（如目录 `TocSheet` 的 `ListView`）传 `false`，
  /// 避免纵向滚动视图嵌套（外层会吃掉内层的拖拽手势）。
  ///
  /// ══════════════════════════════════════════════════════════════════════════
  /// 本项目弹层形态口径（2026-09-29 拍板）—— 以下各项**硬编码，不做成参数**
  /// ══════════════════════════════════════════════════════════════════════════
  /// 负责人「去除弹框点击会有放大高亮特效，不需要上划的弹框，去除小横条」；
  /// `AskUserQuestion` 两项拍板：①「上划」= **禁止拖拽关闭手势**（保留底部滑入动画）；
  /// ② **全部弹层统一生效**（改本处即 6 处弹层同时生效）。
  ///
  /// 三项症状与库参数**逐一对上**（均为本薄封装原先吃掉的库默认值，同
  /// `GlassNavScaffold.extendBody` 默认 `true` 一类坑，故这里直接写死）：
  ///   · 「点击放大」 = `interactionScale`（库默认 **1.01**，doc 自述
  ///     "Visual scale feedback on touch"；库 `stretch.dart:249` 按下时
  ///     `pressed ? interactionScale : 1.0`）→ 传 **1.0** 即无放大；
  ///   · 「点击高亮」 = `enableInteractionGlow`（默认 `true`，"Glint follows finger"）
  ///     + `enableSaturationGlow`（默认 `true`，"Pulsation on touch"）→ 均关；
  ///   · 「小横条」   = `showDragIndicator`（默认 `true`）→ 关（库内还带一个
  ///     覆盖顶部 44px 的可拖拽 `handleZone`，见 `glass_modal_sheet_internal.dart:294`）；
  ///   · 「上划」     = `enableDrag`（默认 `true`）→ 关。
  ///
  /// **「上划」的确切含义**：`enableDrag: false` 后库的 `_DismissibleSheetWrapper`
  /// **完全不加 `GestureDetector`**（`glass_sheet.dart:433` 的 `if (widget.enableDrag)`
  /// 分支跳过，直接返回 child），零副作用；**底部滑入的入场动画保留**——`GlassSheet.show`
  /// 的 `transitionBuilder` 是独立的 `SlideTransition`（`glass_sheet.dart:319`），
  /// 与 `enableDrag` 无关；**点遮罩关闭不变**（`isDismissible` 仍为库默认 `true`）。
  ///
  /// **未动（真机上若仍有按压形变再看）**：`stretch`（库默认 `0.5`，拖拽时的液态拉伸）
  /// 与 `topBorderRadius` 等外观参数——前者是「拉伸」不属负责人描述的「放大」，
  /// 且 `enableDrag: false` 后已无拖拽手势触发它。
  ///
  /// 「关」档（`UI-06` ②）同步：`showModalBottomSheet(enableDrag: false)`，
  /// 并**删去原先自绘的 36×4 拖拽指示条**（本薄封装自己画的那条，非库的）。
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
      // 本项目口径：无横条、不可拖拽关闭、无触摸放大 / 光晕 / 饱和度脉冲。
      showDragIndicator: false,
      enableDrag: false,
      interactionScale: 1.0,
      enableInteractionGlow: false,
      enableSaturationGlow: false,
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
    Duration duration = const Duration(seconds: 2),
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
    builder: (_) => _PlainToast(message: message, duration: duration, onDismissed: dismiss),
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
