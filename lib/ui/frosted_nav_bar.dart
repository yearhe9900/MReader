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
//   ① 几何 100% 可控——实测参考图标签中心**严格等分**（间距 254/254.5/254.5），
//      而库默认 `spacing: 8` 会破坏等分；自研直接按 `标签区宽 / n` 均分。
//   ② 选中块宽度可定——实测 = 格宽的 **112%**（286px/255px，向两侧溢出格子），
//      库的指示块宽度由内部计算、无法按实测值定。
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
// · **拖动**：跟手位移走 `Transform.translate`（无动画、逐帧 1:1），切换位移走
//   `AnimatedPositioned`（过冲回弹）。松手时**吸附到最近的格子**并切换 tab，同时把
//   手指偏离量平滑归零——归零动画刻意与 `AnimatedPositioned` **同曲线
//   （[NavBarStyle.switchCurve]）同时长（[NavBarStyle.switchDuration]）**。
//   两者同曲线时组合位移退化为「在曲线空间里的直线插值」：
//
//   ```text
//     left(t) = lerp(旧格, 新格, c(t))   dx(t) = D × (1 − c(t))
//     合成(t) = left(旧) + D + c(t) × (left(新) − left(旧) − D)
//   ```
//
//   ⇒ 起点恒等于松手位置、终点恒等于新格，中途**不绕路**。若两条动画曲线/时长
//   不一致，合成位移会先弹回旧格再滑向新格（参考视频里是「一边收缩一边平移」）。
// · **左右边界**：选中块**拉伸后**的左右缘都不得越出栏体（参考视频实测：右缘顶在
//   栏体内缘 575 / 578 就不再外扩）。`Stack.clipBehavior: Clip.none` 不做裁剪，
//   故必须在算位置时**显式 clamp 选中块中心**。
// · **档位退化**：「关」档退化为 Material [NavigationBar]（`UI-06` ②），
//   中 / 低档钉 standard 口径不降级外观，仅关掉交互高光。
import 'dart:math' as math;

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
  /// 松手后的归零动画。
  ///
  /// 时长 / 曲线**必须**与 [_AnimatedPill] 里 `AnimatedPositioned` 用的那条一致，
  /// 否则组合位移会绕路（见文件头）。
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: NavBarStyle.switchDuration,
  );

  /// 加了曲线的归零进度（`easeOutBack` 会给出一段 > 1 的过冲）。
  late final CurvedAnimation _settleCurve = CurvedAnimation(
    parent: _settle,
    curve: NavBarStyle.switchCurve,
  );

  /// 拖动跟手的横向偏移（px，手指按下期间逐帧 1:1）。
  double _dragDx = 0;

  /// 松手瞬间的偏移量（归零动画的起点）。
  double _releaseDx = 0;

  /// 本次拖动的起始下标（松手时按「拖过几格」推算目标格）。
  int _dragStartIndex = 0;

  /// 拖动是否进行中（决定选中块位移的来源：手指偏移 vs 归零动画）。
  bool _dragging = false;

  /// 是否吞掉紧随拖动之后的那次 tap（拖动末端的抬手会再触发一次 tap）。
  bool _suppressTap = false;

  /// 上一帧布局算出的格宽（拖动收尾在 build 之外，需缓存）。
  double _cellWidth = 0;

  /// 选中块当前的横向偏移。
  double get _pillDx =>
      _dragging ? _dragDx : _releaseDx * (1 - _settleCurve.value);

  /// 开关档（Material退化）。
  bool get _glassOff => !GlassScope.configOf(context).glassEnabled;

  @override
  void dispose() {
    _settleCurve.dispose();
    _settle.dispose();
    super.dispose();
  }

  void _onTap(int index) {
    if (_suppressTap) {
      // 拖动的收尾已在 `_onDragEnd` 处理，这里吞掉拖动后的误触点击。
      return;
    }
    widget.onTabSelected(index);
  }

  /// 跟手形变：拖动时选中块跟着手指横向位移并拉伸（[NavBarStyle.dragStretchPerCell]）。
  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      if (!_dragging) {
        // 首次 update：上一轮可能还有归零动画在跑，先打断并记下起始格。
        _dragging = true;
        _dragStartIndex = widget.selectedIndex;
        _dragDx = 0;
        _releaseDx = 0;
        _settle.value = 0;
      }
      _dragDx += details.delta.dx;
      _suppressTap = true;
    });
  }

  /// 松手：**吸附到最近的格子**并把手指偏离量按同一曲线归零。
  ///
  /// 吸附目标按「偏移量相当于几格」四舍五入（选中块中心间距就是格宽，故
  /// `round(dx / cellWidth)` 即步数），再夹到合法下标区间。
  void _onDragEnd(DragEndDetails details) {
    // ⚠️⚠️ 这条守卫是 2026-10-13 真机「无法点击」的**主修法**（变异判红实证：
    // 把守卫摘掉、并让 `_onDragCancel` 委托到本方法，`onTap` 就会被吞掉）。
    //
    // `_dragging == false` ⇒ 本次拖动**一次 update 都没进过**。这有两种来路：
    //   ① 识别器输给了 tap —— 指针抬起、未越过 slop，它 `resolve(rejected)` 后
    //      仍会走 `onCancel`，随即同级 `InkWell` 的 `onTap` 就触发了；
    //   ② 识别器刚接受就抬手。
    // 两种都必须**当作无手势**：否则会顺手置 `_suppressTap` 吞掉那次 `onTap`
    // （①），或按陈旧的 `_dragStartIndex` 把选中块跳到无关的格子（②）。
    if (!_dragging) {
      return;
    }
    final int n = widget.tabs.length;
    final double cell = _cellWidth;
    final int target = cell <= 0
        ? widget.selectedIndex
        : (_dragStartIndex + (_dragDx / cell).round()).clamp(0, n - 1);

    setState(() {
      _releaseDx = _dragDx;
      _dragDx = 0;
      _dragging = false;
      _suppressTap = true;
    });
    _settle.forward(from: 0);
    if (target != widget.selectedIndex) {
      widget.onTabSelected(target);
    }

    // 延后一帧再解除误触拦截：`GestureDetector` 的 tap 在 drag end 之后才判定，
    // 立即置 false 会让拖动末端的抬手误触发切换。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _suppressTap) {
        setState(() => _suppressTap = false);
      }
    });
  }

  /// 手势被打断（拖动**已真正开始**后被外部手势抢占）。
  ///
  /// ⚠️⚠️ **这个回调「点一下」就会来**（2026-10-13 真机 + 测试双重复现）：
  /// `HorizontalDragGestureRecognizer` 在指针抬起且未越过 slop 时走
  /// `resolve(rejected)` → `onCancel`，**它不是「拖动松手」**。而同级 `InkWell`
  /// 的 `onTap` 在**同一次事件派发里紧接着**执行（探针实测顺序：
  /// `onDragCancel(_dragging=false)` → `onTap(_suppressTap=true)`）。
  ///
  /// 故本方法**绝不置 `_suppressTap`**：一旦置上，紧接着的 `onTap` 会看到拦截位
  /// 已开而直接 return ⇒ **整个底栏点不动**（真机现象：「无法点击」；且因为
  /// `onCancel` 每次点击都会来，是**每一次点击**都被吞，不是只吞第一次）。
  void _onDragCancel() {
    if (!_dragging) {
      // 从没真正拖动过 ⇒ 识别器输给了 tap，状态干净，一个字都不要改。
      return;
    }
    // 真的拖过又被抢占：原地吸附回当前格，**不切换、不拦截点击**。
    setState(() {
      _releaseDx = _dragDx;
      _dragDx = 0;
      _dragging = false;
    });
    _settle.forward(from: 0);
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
              // ⭐ 标签区**居中 + 左右侧内缩**（参考图实测：侧留白 ≈ 0.10 格宽）。
              // 严格等分指标签中心间距均匀（实测 254/254.5/254.5），**不是**标签占满
              // 栏体——不内缩的话，112% 宽的选中块在首/末格会贴到栏体边框
              // （见 [NavBarStyle.sideInsetCellFactor]）。
              final int n = widget.tabs.length;
              final double available = constraints.maxWidth;
              final double labelAreaWidth =
                  available / (1 + 2 * NavBarStyle.sideInsetCellFactor / n);
              final double sideInset = (available - labelAreaWidth) / 2;
              final double cellWidth = labelAreaWidth / n;
              final double pillHeight =
                  NavBarStyle.barHeight * NavBarStyle.pillHeightFactor;
              final double pillWidth = cellWidth * NavBarStyle.pillWidthFactor;

              // 拖动收尾发生在 build 之外（手势回调），故把布局派生量缓存下来，
              // 供 `_onDragEnd` 按「偏移量相当于几格」推算吸附目标。
              _cellWidth = cellWidth;

              return _GlassShell(
                brightness: brightness,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  onHorizontalDragCancel: _onDragCancel,
                  // 归零动画按帧驱动选中块；标签行不参与动画，作为 `child` 缓存
                  // （否则每帧重建整行 `InkWell`）。
                  child: AnimatedBuilder(
                    animation: _settleCurve,
                    builder: (BuildContext context, Widget? rowChild) => Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        // 选中块（在下层，内容压在它上面）。
                        //⚠️ `AnimatedPositioned` 必须是 `Stack` 的**直接**子节点，
                        // 不能套 `Positioned.fill`（会丢父约束导致布局断言）。故侧
                        // 内缩直接并入它的 `left`。
                        //⚠️ 也**不能**把它包进 `AnimatedBuilder`——那会让
                        // `Positioned` 不再是 Stack 直接子节点而报 ParentData 断言。
                        // 故动画器包在 Stack **外面**。
                        _AnimatedPill(
                          index: widget.selectedIndex,
                          sideInset: sideInset,
                          cellWidth: cellWidth,
                          pillWidth: pillWidth,
                          pillHeight: pillHeight,
                          available: available,
                          dragDx: _pillDx,
                          brightness: brightness,
                        ),
                        // 标签行。
                        ?rowChild,
                      ],
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: sideInset),
                      child: Row(
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
                    ),
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

/// 栏体外壳：磨砂 + 纱罩 + 四周细亮边。
///
/// ⚠️ **不做左右缘高光带**（2026-10-13 第二轮实测更正）：参考图栏体从边缘内侧
/// 第 2px 起就稳定在 `lum 20~21`，一路到标签都是平坦的；只有四周一道 1~2px 的
/// 亮描边（[NavBarStyle.barBorderAlpha] 已覆盖）。上一版凭压缩帧测到的
/// 「左缘 42px 宽、lum 185 的亮带」是压缩 / 边缘混淆的产物，已删除。
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
            // 四周一道细亮边 = 「玻璃有厚度」的线索（参考图实测 1~2px，
            // 栏体上缘 lum 46 vs 本体 21 ⇒ alpha ≈ 0.11）。
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
/// （`during == before`，不是「动得慢」）。故三件事各走各的通道：
///
/// ```text
///   · 切档位移   → AnimatedPositioned(left)      switchCurve / switchDuration
///   · 拖动跟手   → Transform.translate(dx)       无动画，逐帧 1:1
///   · 拖动拉伸   → Transform.scale(scaleX)       无动画，∝ |dx|
/// ```
///
/// 松手时 `dx` 由 `_FrostedNavBarState` 的归零动画驱动**衰减到 0**——那条动画与
/// `AnimatedPositioned` **同曲线同时长**，两者叠加后合成位移是「曲线空间里的直线」，
/// 起点 = 松手位置、终点 = 吸附格，中途不绕路（推到见文件头）。
///
/// ⚠️ **拉伸后的左右缘必须显式夹在栏体内**：`Stack` 是 `Clip.none`，不做裁剪。
class _AnimatedPill extends StatelessWidget {
  const _AnimatedPill({
    required this.index,
    required this.sideInset,
    required this.cellWidth,
    required this.pillWidth,
    required this.pillHeight,
    required this.available,
    required this.dragDx,
    required this.brightness,
  });

  final int index;

  /// 标签区相对栏体的左右内缩（由调用方从 `sideInsetCellFactor` 解出）。
  final double sideInset;
  final double cellWidth;
  final double pillWidth;
  final double pillHeight;

  /// 栏体可用宽（= `Stack` 的宽）。左右边界约束按它算。
  final double available;
  final double dragDx;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    // 动画位置：只由「选中下标」决定，不含拖动偏移。
    // `sideInset` 让首/末格的选中块不贴栏体边框（参考图实测边距 3~4dp）。
    final double left =
        sideInset + cellWidth * index + (cellWidth - pillWidth) / 2;

    // 拖动时横向拉伸（跟手形变），静止时 0。
    // 比例 ∝ 拖过的格数，封顶 [NavBarStyle.dragStretchMax]。
    final double stretch = cellWidth <= 0
        ? 0.0
        : math.min(
            (dragDx.abs() / cellWidth) * NavBarStyle.dragStretchPerCell,
            NavBarStyle.dragStretchMax,
          );

    // ── 左右边界 ─────────────────────────────────────────────────────────────
    // ⚠️ `Transform.scale` 以**盒中心**为原点缩放，故拉伸后的左右缘是
    // `中心 ± 半宽`。`Stack` 是 `Clip.none`（不裁剪），若不管就会溢出栏体。
    // 把**中心**夹到「左缘 ≥ 0 且右缘 ≤ 可用宽」的区间内 ⇒ 拖到两端就顶住
    // （参考视频实测：右缘顶在栏体内缘 575 / 578 即不再外扩）。
    final double restCenter = left + pillWidth / 2;
    final double halfSpan = pillWidth * (1 + stretch) / 2;
    final double rawCenter = restCenter + dragDx;
    final double center = halfSpan * 2 >= available
        // 极端窄栏（如 2 格 + 最大拉伸）：整块拉满，居中即可，否则夹取区间为空。
        ? available / 2
        : rawCenter.clamp(halfSpan, available - halfSpan);

    return AnimatedPositioned(
      duration: NavBarStyle.switchDuration,
      curve: NavBarStyle.switchCurve,
      left: left,
      top: (NavBarStyle.barHeight - pillHeight) / 2,
      width: pillWidth,
      height: pillHeight,
      child: Transform.translate(
        // 拖动跟手 + 边界修正：走 `Transform` 而非并入上面的 `left`——`Transform`
        // 无动画，逐帧 1:1 跟手（原因见类注释）。
        offset: Offset(center - restCenter, 0),
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
    // ⚠️ 参考图实测**选中与未选中的图标/文字亮度几乎一致**（图标中位数
    // 242~247、文字 215~223）⇒ 选中态**只靠灰底衬区分**。故两者同取
    // `onSurface`，只留一档极小的 alpha 差供无障碍/聚焦可辨。若未选中改用
    // `onSurfaceVariant`，未选中项会明显发灰——这正是 10-12 那版"太丑"的
    // 另一半原因（当时把它归到选中块宽度上了，真机截图才暴露）。
    final Color labelColor = selected
        ? colors.onSurface.withValues(alpha: NavBarStyle.selectedLabelAlpha)
        : colors.onSurface.withValues(alpha: NavBarStyle.unselectedLabelAlpha);
    final Color iconColor = selected
        ? colors.onSurface.withValues(alpha: NavBarStyle.selectedIconAlpha)
        : colors.onSurface.withValues(alpha: NavBarStyle.unselectedIconAlpha);

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