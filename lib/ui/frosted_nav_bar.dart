// 自磨砂伪玻璃底栏（2026-10-12 参考图复刻批，负责人拍板「抛弃库的限制，采用
// 磨砂伪玻璃设计」）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么不用 `GlassTabBar`（取舍依据，详见 [NavBarStyle] 文件头）
// ══════════════════════════════════════════════════════════════════════════════
// 参考图那一档玻璃**没有**折射/ 色散——抓底栏上边缘只看到「内容被磨砂 + 亮白
// 纱罩 + 上缘一道高光」。这正是 `BackdropFilter` 的能力范围。而 `GlassTabBar`
// 要为导航栏加载 2574 行 GLSL 并附带一整套已记录的限制（PRD §11.4），用不上
// 它的核心却要承担全部重量。
//
// **换来的三个实质收益**（不是「更干净」这种虚话）：
//   ① 几何 100% 可控——实测参考图标签中心**严格等分**（间距 129/129/129），
//      而库默认 `spacing: 8` 会破坏等分；自研直接按`可用宽 / n` 均分。
//   ② 选中块宽度可定——实测 = 格宽的 **69%**（略微内缩），库的指示块
//      宽度由内部计算、无法按实测值定。
//   ③ 测试开销归零——库玻璃在 `flutter test` 软件光栅下每帧 620~662ms 真实
//      异步开销（tech-usage §2.26），本控件不依赖着色器，测试可正常
//      `pumpAndSettle`。
//
// ⚠️ **范围**：只替换导航栏。顶栏与弹层仍用库（那里折射是真需求，见 `glass_kit`）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 实现要点（都是「用库时拿不到的」东西）
// ══════════════════════════════════════════════════════════════════════════════
// · **磨砂**：[BackdropFilter] 包住整个栏体 —— 它采样的是**栏下方的内容**
//   （`home_shell` 把本控件 `Positioned(bottom: 0)` 浮在 `Stack` 上，正文在其
//   下层），这正是「悬浮玻璃」的定义。若改为 `Scaffold.bottomNavigationBar`
//   则底栏在内容**之上**、[BackdropFilter] 采样不到正文，磨砂会退化成纯色 ——
//   故调用点必须保持 `Stack + Positioned`。
// · **两层纱罩**：磨砂之上再叠半透明白层，模拟参考图「磨砂 + 增白」的观感。
//   暗色下纱罩换**黑色**（压暗提对比），不是加白。
// · **选中块**：`AnimatedPositioned`（[NavBarStyle.switchCurve] = `easeOutBack`
//   提供过冲回弹）+ `Transform.scale` 做拖动跟手拉伸。
// · **档位退化**：「关」档退化为 Material [NavigationBar]（`UI-06` ②），
//   中 / 低档钉 standard 口径不降级外观，仅关掉交互高光。
import 'package:flutter/material.dart';

import 'glass_scope.dart';
import 'nav_bar_style.dart';

/// 自研底栏的一个标签。
@immutable
class NavTab {
  /// 创建标签。
  const NavTab({
    required this.label,
    this.icon,
    this.activeIcon,
    this.semanticLabel,
  });

  /// 未选中时的图标。
  final IconData? icon;

  /// 选中时的图标（缺省用 [icon]）。
  final IconData? activeIcon;

  /// 文字标签（同时作为无障碍语义）。
  final String label;

  /// 无障碍标签（缺省用 [label]）。
  final String? semanticLabel;

  /// 取当前状态该用的图标。
  IconData? iconFor({required bool selected}) =>
      (selected ? activeIcon : icon) ?? icon;
}

/// 磨砂伪玻璃底栏（悬浮胶囊形态）。
///
/// **几何与材质的唯一事实源是 [NavBarStyle]**，本类只负责组装与动效。
class FrostedNavBar extends StatefulWidget {
  /// 创建底栏。
  const FrostedNavBar({
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
    super.key,
  });

  /// 标签配置（顺序即下标语义）。
  final List<NavTab> tabs;

  /// 当前选中下标。
  final int selectedIndex;

  /// 选中回调。
  final ValueChanged<int> onTabSelected;

  @override
  State<FrostedNavBar> createState() => _FrostedNavBarState();
}

class _FrostedNavBarState extends State<FrostedNavBar>
    with SingleTickerProviderStateMixin {
  /// 拖动跟手的横向偏移（px，下一次布局结束后归零）。
  double _dragDx = 0;

  /// 拖动是否正在进行（用于抑制点击误触）。
  bool _dragging = false;

  /// 开关档（Material退化）。
  bool get _glassOff => !GlassScope.configOf(context).glassEnabled;

  void _onTap(int index) {
    if (_dragging) {
      // 拖动的收尾已在 `_onHorizontalDragEnd` 处理，这里吞掉拖动后的误触点击。
      return;
    }
    widget.onTabSelected(index);
  }

  /// 跟手形变：拖动时选中块跟着手指横向位移并拉伸。
  ///
  /// 参考图的拖动形变是「选中块被手指拽着走 + 横向拉宽」，松手弹回目标格。
  /// 这里只做**视觉跟手**，不实现「拖到哪格就切哪格」——那是交互语义变更，
  /// 需另行拍板（PRD 无对应验收项）。
  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragDx += details.delta.dx;
      _dragging = true;
    });
  }

  /// 松手：弹回（`_dragDx` 归零 ⇒ [AnimatedPositioned] 走弹簧曲线回位）。
  void _onDragEnd(DragEndDetails details) {
    setState(() => _dragDx = 0);
    // 延后一帧再解除误触拦截：`GestureDetector` 的 tap 在 drag end 之后才判定，
    // 立即置false 会让拖动末端的抬手误触发切换。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _dragging = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_glassOff) {
      // 「关」档（`UI-06` ②）：Material 纯色底栏，与 `GlassNavBar` 退化行为一致。
      return NavigationBar(
        selectedIndex: widget.selectedIndex,
        onDestinationSelected: widget.onTabSelected,
        destinations: <NavigationDestination>[
          for (final NavTab tab in widget.tabs)
            NavigationDestination(
              icon: tab.icon == null
                  ? const SizedBox.shrink()
                  : Icon(tab.icon),
              selectedIcon: tab.activeIcon == null
                  ? null
                  : Icon(tab.activeIcon),
              label: tab.label,
            ),
        ],
      );
    }

    final Brightness brightness = NavBarStyle.brightnessOf(context);
    // 玻璃库无 Material 祖先（PRD §11.4），而标签的 `InkWell` 需要最近的
    // Material 绘制水波纹。本控件挂在 `Stack + Positioned` 上（不是
    // `Scaffold.bottomNavigationBar`），故自带一层透明 Material 地基——
    // `MaterialType.transparency` 不绘制底色，不破坏磨砂观感（同
    // `GlassKit` 内既有的手法）。
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(
          left: NavBarStyle.horizontalPadding,
          right: NavBarStyle.horizontalPadding,
          bottom: NavBarStyle.verticalPadding,
        ),
      child: SizedBox(
          height: NavBarStyle.barHeight,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 严格等分：实测参考图标签中心间距 129/129/129，完全均匀。
              // 这是自研相对库（默认 spacing: 8 会破坏等分）的直接收益。
              final double cellWidth =
                  constraints.maxWidth / widget.tabs.length;
              final double pillHeight =
                  NavBarStyle.barHeight * NavBarStyle.pillHeightFactor;
              final double pillWidth = cellWidth * NavBarStyle.pillWidthFactor;

              return _GlassShell(
                brightness: brightness,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  onHorizontalDragCancel: () => setState(() => _dragDx = 0),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      // 选中块（在下层，内容压在它上面）。
                      _AnimatedPill(
                        index: widget.selectedIndex,
                        cellWidth: cellWidth,
                        pillWidth: pillWidth,
                        pillHeight: pillHeight,
                        dragDx: _dragDx,
                        brightness: brightness,
                      ),
                      // 标签行。
                      Row(
                        children: <Widget>[
                          for (int i = 0; i < widget.tabs.length; i++)
                            Expanded(
                              child: _TabItem(
                                tab: widget.tabs[i],
                                selected: i == widget.selectedIndex,
                                onTap: () => _onTap(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 栏体外壳：磨砂 + 纱罩 + 上缘高光。
class _GlassShell extends StatelessWidget {
  const _GlassShell({
    required this.brightness,
    required this.child,
  });

  final Brightness brightness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(NavBarStyle.barRadius),
      child: BackdropFilter(
        filter: NavBarStyle.barFilter(brightness),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: NavBarStyle.scrimColor(brightness),
            borderRadius: BorderRadius.circular(NavBarStyle.barRadius),
            // 上缘一道亮边 = 「玻璃有厚度」的关键线索（参考图可见）。
            border: Border.all(
              color: Colors.white.withValues(
                alpha: NavBarStyle.barBorderAlpha,
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 滑动选中块。
///
/// ⚠️ **位置动画与拖动跟手必须分两套机制**（本轮实测踩到）：
/// 拖动偏移若并入 [AnimatedPositioned] 的 `left`，每一帧拖动更新都会**重启
/// 那条 420ms 弹簧**，选中块被动画持续「拉回去」，实测表现为**完全不动**
/// （`during == before`，不是「动得慢」）。故：
///   · 切档位移 → [AnimatedPositioned]（`easeOutBack` 过冲回弹）；
///   · 拖动跟手 → [Transform]（无动画，逐帧 1:1 跟手）。
class _AnimatedPill extends StatelessWidget {
  const _AnimatedPill({
    required this.index,
    required this.cellWidth,
    required this.pillWidth,
    required this.pillHeight,
    required this.dragDx,
    required this.brightness,
  });

  final int index;
  final double cellWidth;
  final double pillWidth;
  final double pillHeight;
  final double dragDx;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    // 动画位置：只由「选中下标」决定，不含拖动偏移。
    final double left = cellWidth * index + (cellWidth - pillWidth) / 2;
    // 拖动时横向拉伸（跟手形变），静止时 1.0。
    final double stretch = dragDx == 0
        ? 0.0
        : (dragDx.abs() / cellWidth).clamp(0.0, NavBarStyle.dragStretch);
    return AnimatedPositioned(
      duration: NavBarStyle.switchDuration,
      curve: NavBarStyle.switchCurve,
      left: left,
      top: (NavBarStyle.barHeight - pillHeight) / 2,
      width: pillWidth,
      height: pillHeight,
      child: Transform.translate(
        // 拖动跟手：走 `Transform` 而非并入上面的 `left`——`Transform` 无动画，
        // 逐帧 1:1 跟手（原因见类注释）。
        offset: Offset(dragDx, 0),
        child: Transform.scale(
          scaleX: 1 + stretch,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              NavBarStyle.pillRadius(pillHeight),
            ),
            child: BackdropFilter(
              filter: NavBarStyle.pillFilter(brightness),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: NavBarStyle.pillScrimColor(brightness),
                  borderRadius: BorderRadius.circular(
                    NavBarStyle.pillRadius(pillHeight),
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: NavBarStyle.pillBorderAlpha,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个标签（图标 + 文字）。
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final NavTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color labelColor = selected
        ? colors.onSurface.withValues(alpha: NavBarStyle.selectedLabelAlpha)
        : colors.onSurface.withValues(alpha: NavBarStyle.unselectedLabelAlpha);
    final Color iconColor = selected
        ? colors.onSurface.withValues(alpha: NavBarStyle.selectedLabelAlpha)
        : colors.onSurfaceVariant
            .withValues(alpha: NavBarStyle.unselectedLabelAlpha);

    return Semantics(
      button: true,
      selected: selected,
      label: tab.semanticLabel ?? tab.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NavBarStyle.barRadius),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(tab.iconFor(selected: selected),
                size: NavBarStyle.iconSize, color: iconColor),
            SizedBox(height: NavBarStyle.iconLabelSpacing),
            Text(
              tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NavBarStyle.labelFontSize,
                color: labelColor,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}