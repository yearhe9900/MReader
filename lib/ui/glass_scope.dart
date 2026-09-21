// 玻璃作用域：把「当前有效亮度 / 当前质量档位 / 玻璃隔离范围」收敛到一处。
//
// 本批只做**基础设施**，不接任何业务页面。作用域的三个值都从环境解析、可显式覆盖：
//   · 有效亮度 —— 来自玻璃库的 `GlassTheme.brightnessOf`（它内部是三级级联：
//     外部 `brightnessResolver`（Material 集成）→ Cupertino 主题 → 系统亮度）；
//   · 质量档位 —— 默认 [kAppGlassQuality]（`standard`）；若上层有自适应作用域则取其有效档位；
//   · 玻璃隔离范围 —— `glassAllowed`，供内容层把「此范围内禁止玻璃」显式表达出来（`UI-04`）。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_kit.dart';

/// 玻璃作用域（[InheritedWidget]）。
///
/// 让下游不必各自去猜「现在是亮是暗、该用哪档、这里能不能放玻璃」。
/// `UI-01` ② 的落点之一：[brightnessOf] 优先本作用域，其次交给库级联。
class GlassScope extends InheritedWidget {
  /// 创建一个玻璃作用域。
  const GlassScope({
    super.key,
    required this.brightness,
    required this.quality,
    required this.glassAllowed,
    required super.child,
  });

  /// 当前有效亮度（跟随应用 ThemeMode）。
  final Brightness brightness;

  /// 当前质量档位。
  final GlassQuality quality;

  /// 玻璃隔离范围：`true` = 作用域内允许玻璃；`false` = 禁止（内容层用）。
  final bool glassAllowed;

  /// 取最近的作用域；不存在返回 `null`。
  static GlassScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassScope>();

  /// 有效亮度：优先本作用域；否则交给玻璃库的亮度级联。
  static Brightness brightnessOf(BuildContext context) =>
      maybeOf(context)?.brightness ?? GlassTheme.brightnessOf(context);

  /// 当前质量档位：优先本作用域；否则取库自适应作用域的有效档位；再否则 [kAppGlassQuality]。
  static GlassQuality qualityOf(BuildContext context) =>
      maybeOf(context)?.quality ??
      GlassAdaptiveScopeData.maybeOf(context)?.effectiveQuality ??
      kAppGlassQuality;

  /// 该上下文是否允许玻璃存在（`UI-04` 隔离范围）。
  ///
  /// 无作用域时**宽松默认允许**——玻璃默认可见，只有显式标注为内容层的子树才禁止。
  static bool allowsGlass(BuildContext context) =>
      maybeOf(context)?.glassAllowed ?? true;

  @override
  bool updateShouldNotify(GlassScope oldWidget) =>
      brightness != oldWidget.brightness ||
      quality != oldWidget.quality ||
      glassAllowed != oldWidget.glassAllowed;
}

/// 从环境解析并下发 [GlassScope]（放在 `MaterialApp` 之下、业务页之上）。
///
/// 之所以是 [StatelessWidget] 而非在 `main()` 直接构造 [GlassScope]：
/// 有效亮度必须从**应用主题**解析，而主题只有在 `MaterialApp` 之下才可读。
class GlassScopeProvider extends StatelessWidget {
  /// 创建设置作用域的包裹组件。
  const GlassScopeProvider({
    super.key,
    this.quality,
    this.glassAllowed = true,
    required this.child,
  });

  /// 覆盖档位；缺省取自适应作用域的有效档位或 [kAppGlassQuality]。
  final GlassQuality? quality;

  /// 玻璃隔离范围（`UI-04`）；内容层子树可传 `false`。
  final bool glassAllowed;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassScope(
      brightness: GlassTheme.brightnessOf(context),
      quality: quality ??
          GlassAdaptiveScopeData.maybeOf(context)?.effectiveQuality ??
          kAppGlassQuality,
      glassAllowed: glassAllowed,
      child: child,
    );
  }
}
