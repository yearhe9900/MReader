// 玻璃控件薄封装 + `UI-04` 内容层不透明红线（本批基础设施，**不接任何业务页面**）。
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
// 质量档位策略（PRD §11.3）：
//   · 固定表面（顶栏 / 底栏）→ 由库的 `GlassScaffold → GlassIsolationScope` **自动提升为
//     `premium`**，本项目**不手动传 `premium`**（见 [GlassKit.fixedSurfaceQualityOverride]）；
//   · 浮层（对话框 / 底部弹窗）与滚动区内的玻璃 → [kAppGlassQuality]（= `standard`）；
//   · P0 **不使用** `adaptiveQuality`（标记 `@experimental`，首启要跑约 3 秒基准，且不持久化
//     `initialQuality` 会每次冷启动重现降级窗口，PRD §11.3）。`minimal` 与用户可调档位属
//     `UI-05`（M2b）。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 应用统一玻璃质量档位（PRD §11.3）。P0 固定 `standard`。
///
/// 其 API 与语义来自 `liquid_glass_widgets` 1.6.2 的 `GlassQuality` 枚举
/// （取值：`standard` / `premium` / `minimal`）。
const GlassQuality kAppGlassQuality = GlassQuality.standard;

/// 档位策略的唯一出口（PRD §11.3）。测试在此断言「P0 不引入 premium」。
abstract final class GlassKit {
  /// 浮层 / 滚动区玻璃使用的档位：非固定表面 → `standard`。
  static const GlassQuality overlayQuality = kAppGlassQuality;

  /// 固定表面（顶栏 / 底栏）的档位覆盖值：**恒为 `null`**。
  ///
  /// 传 `null` 即「不覆盖」——库在 `GlassScaffold` 内经 `GlassIsolationScope`
  /// 把导航栏自动提升为 `premium`。本项目**从不**手动传 `premium`（`UI-05` ①）。
  static const GlassQuality? fixedSurfaceQualityOverride = null;
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
// 导航层（薄封装，最小集）
// ---------------------------------------------------------------------------

/// 导航层顶栏（薄封装 [GlassAppBar]）。
///
/// 注意：`GlassAppBar` 的**条面本身是布局容器**，玻璃质感来自条内的按钮
/// （见库文档）。固定表面的 premium 由库自动提升，此处**不传档位**。
class GlassTopBar extends StatelessWidget {
  /// 创建玻璃顶栏。
  const GlassTopBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.centerTitle = true,
    this.backgroundColor = const Color(0x00000000),
    this.toolbarHeight = 44.0,
  });

  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final bool centerTitle;
  final Color backgroundColor;
  final double toolbarHeight;

  @override
  Widget build(BuildContext context) => GlassAppBar(
        title: title,
        leading: leading,
        actions: actions,
        centerTitle: centerTitle,
        backgroundColor: backgroundColor,
        toolbarHeight: toolbarHeight,
      );
}

/// 导航层底栏（薄封装 [GlassTabBar.bottom]）。
class GlassNavBar extends StatelessWidget {
  /// 创建玻璃底栏。
  const GlassNavBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  final List<GlassTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) => GlassTabBar.bottom(
        tabs: tabs,
        selectedIndex: selectedIndex,
        onTabSelected: onTabSelected,
        // 固定表面：**不传 quality** → 库在 GlassScaffold 内自动提升为 premium（§11.3 / UI-05 ①）。
        // 切勿在此写死 premium（那会绕过库的自适应与隔离策略）；见 [GlassKit]。
      );
}

/// 导航壳层（薄封装 [GlassScaffold]）。
///
/// 保证顶栏 / 底栏玻璃永远绘制在正文之上，并给内容边缘做渐隐；正文请用
/// [OpaqueContentSurface] 承载（`UI-04`）。
class GlassNavScaffold extends StatelessWidget {
  /// 创建玻璃导航壳层。
  const GlassNavScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.bottomBar,
    this.background,
  });

  final Widget body;
  final Widget? appBar;
  final Widget? bottomBar;
  final Widget? background;

  @override
  Widget build(BuildContext context) => GlassScaffold(
        body: body,
        appBar: appBar,
        bottomBar: bottomBar,
        background: background,
      );
}

// ---------------------------------------------------------------------------
// 浮层（薄封装，最小集）
// ---------------------------------------------------------------------------

/// 浮层玻璃入口（对话框 / 底部弹窗）。
///
/// 浮层不是「固定表面」，故显式使用 [GlassKit.overlayQuality]（= `standard`），
/// **不传 `premium`**（§11.3）。
abstract final class GlassOverlays {
  /// 浮层档位（见 [GlassKit.overlayQuality]）。
  static const GlassQuality quality = GlassKit.overlayQuality;

  /// 弹出玻璃确认框（薄封装 [GlassDialog.show]）。
  static Future<T?> showAlert<T>({
    required BuildContext context,
    required List<GlassDialogAction> actions,
    String? title,
    String? message,
    Widget? content,
  }) =>
      GlassDialog.show<T>(
        context: context,
        actions: actions,
        title: title,
        message: message,
        content: content,
        quality: quality,
      );

  /// 弹出玻璃底部弹窗（薄封装 [GlassSheet.show]）。
  static Future<T?> showSheet<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) =>
      GlassSheet.show<T>(
        context: context,
        builder: builder,
        quality: quality,
      );
}
