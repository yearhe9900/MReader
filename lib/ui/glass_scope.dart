// 玻璃作用域：把「当前有效亮度 / 当前生效档位配置 / 玻璃隔离范围」收敛到一处，
// 三个值都从环境解析、可显式覆盖：
//   · 有效亮度 —— 玻璃库的 `GlassTheme.brightnessOf`（内部三级级联：外部
//     `brightnessResolver` → Cupertino 主题 → 系统亮度）；
//   · 档位配置 —— 默认 [GlassRuntime.config]；[GlassScopeProvider] 订阅
//     [GlassRuntime]，档位切换时**整树重建**，薄封装层（`glass_kit.dart`）
//     经 [GlassScope.configOf] 自动跟档；
//   · 玻璃隔离范围 —— `glassAllowed`，供内容层把「此范围内禁止玻璃」显式表达出来（`UI-04`）。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_runtime.dart';

/// 玻璃作用域（[InheritedWidget]）：下游不必各自去猜「现在是亮是暗、该用哪档、
/// 这里能不能放玻璃」。`UI-01` ② 的落点之一：[brightnessOf] 优先本作用域，其次交给库级联。
class GlassScope extends InheritedWidget {
  /// 创建一个玻璃作用域。
  const GlassScope({
    super.key,
    required this.brightness,
    required this.config,
    required this.glassAllowed,
    required super.child,
  });

  /// 当前有效亮度（跟随应用 ThemeMode）。
  final Brightness brightness;

  /// 当前生效的玻璃档位配置（`UI-05` / `UI-06` 接线后的唯一真值）。
  final GlassTierConfig config;

  /// 玻璃隔离范围：`true` = 作用域内允许玻璃；`false` = 禁止（内容层用）。
  final bool glassAllowed;

  /// 取最近的作用域；不存在返回 `null`。
  static GlassScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassScope>();

  /// 有效亮度：优先本作用域；否则交给玻璃库的亮度级联。
  static Brightness brightnessOf(BuildContext context) =>
      maybeOf(context)?.brightness ?? GlassTheme.brightnessOf(context);

  /// 当前生效档位配置：优先本作用域；否则 [GlassRuntime.config]。
  /// 薄封装层（`glass_kit.dart`）应经本方法取值——`dependOn` 建立的依赖保证
  /// 档位切换（作用域重建）时自动重跑 `build`（`UI-05` ③ 切档即生效）。
  static GlassTierConfig configOf(BuildContext context) =>
      maybeOf(context)?.config ?? GlassRuntime.config;

  /// 当前滚动区 / 浮层档位（[GlassTierConfig.scrollQuality] 的快捷方式）。
  static GlassQuality qualityOf(BuildContext context) =>
      configOf(context).scrollQuality;

  /// 该上下文是否允许玻璃存在（`UI-04` 隔离范围）；无作用域时**宽松默认允许**——
  /// 玻璃默认可见，只有显式标注为内容层的子树才禁止。
  static bool allowsGlass(BuildContext context) =>
      maybeOf(context)?.glassAllowed ?? true;

  @override
  bool updateShouldNotify(GlassScope oldWidget) =>
      brightness != oldWidget.brightness ||
      config != oldWidget.config ||
      glassAllowed != oldWidget.glassAllowed;
}

/// 从环境解析并下发 [GlassScope]（放在 `MaterialApp` 之下、业务页之上）。
/// **订阅 [GlassRuntime]**：生效档位变化（切档 / 「降低视觉特效」/ 自动降档）时
/// 重建作用域，整棵子树的玻璃控件跟档（`UI-05` ③ / `UI-06` 的生效触点）。
class GlassScopeProvider extends StatefulWidget {
  /// 创建设置作用域的包裹组件。
  const GlassScopeProvider({
    super.key,
    this.config,
    this.glassAllowed = true,
    required this.child,
  });

  /// 覆盖档位配置（测试 / 特定子树钉档用）；缺省取 [GlassRuntime.config]。
  final GlassTierConfig? config;

  /// 玻璃隔离范围（`UI-04`）；内容层子树可传 `false`。
  final bool glassAllowed;

  /// 作用域包裹的子树。
  final Widget child;

  @override
  State<GlassScopeProvider> createState() => _GlassScopeProviderState();
}

class _GlassScopeProviderState extends State<GlassScopeProvider> {
  @override
  void initState() {
    super.initState();
    GlassRuntime.addListener(_onRuntimeChanged);
  }

  @override
  void dispose() {
    GlassRuntime.removeListener(_onRuntimeChanged);
    super.dispose();
  }

  void _onRuntimeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassScope(
      brightness: GlassTheme.brightnessOf(context),
      config: widget.config ?? GlassRuntime.config,
      glassAllowed: widget.glassAllowed,
      child: widget.child,
    );
  }
}
