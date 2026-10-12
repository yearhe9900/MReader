// 玻璃**材质**参数的唯一事实源（2026-10-12 参考图批，负责人「参考图片/视频里
// 主题商店的搜索栏、按钮、底部导航栏效果」）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么要有这个文件（根因，2026-10-12 实证）
// ══════════════════════════════════════════════════════════════════════════════
// 参考图（HyperOS 主题商店）的玻璃 = 三层：**磨砂模糊**（内容透出但不可读）+
// **增白纱罩**（表面亮白）+ **Fresnel 边缘高光**。改动前 MReader 三处对不上：
//   ① 全 app **没有挂 `GlassTheme`**（`main.dart` 的 `wrap` 只传了
//      `brightnessResolver`）→ 所有玻璃面吃库默认材质（玻璃色 12% 冷蓝白、
//      blur 5、无增白），偏「清玻璃」，离参考图的「强磨砂亮面」很远；
//   ② 书架搜索胶囊 / 分组 chips **根本不是玻璃控件**——是
//      `surfaceContainerHighest` α0.6 纯色填充 + outline 描边的普通
//      `Container` / `FilterChip`，无模糊、无增白、无边缘光；
//   ③ 底栏虽是真玻璃，但库的 `GlassTabBar.bottom` **不吃主题**——它用私有预设
//      `kBottomBarGlassDefaults`（`tab_bar_bottom_internal.dart:47`：
//      blur 3 / 折射 1.59 / 玻璃色 α0.24），必须显式传 `settings` 才换得掉。
//
// ══════════════════════════════════════════════════════════════════════════════
// 两级参数（为什么不是一套）
// ══════════════════════════════════════════════════════════════════════════════
// · [GlassMaterial.light] / [GlassMaterial.dark]（[GlassThemeSettings]）——
//   经 [GlassTheme] 全局生效，覆盖「没有显式 settings 也没有父层」的玻璃面：
//   各页顶栏里的玻璃按钮、浮层（`GlassSheet` / `GlassDialog` / `GlassToast`）。
//   ⚠️ [GlassThemeSettings] **不含 `whitenStrength`**（`glass_theme_settings.dart`
//   的 `applyTo` 原样透传 base 值）——增白纱罩在主题级表达不了。
// · [GlassMaterial.settingsFor]（完整 [LiquidGlassSettings]）——给显式传
//   `settings:` 的控件：书架搜索胶囊、分组 chips、浮动底栏、书库搜索页输入框。
//   与主题值**逐项一致**，只多 `whitenStrength`（亮模式增白、暗模式微霜）。
//   改材质只改这里 + 主题两套，**三处消费点不许另写字面量**。
//
// 质量档位（`UI-05` / `UI-06`）**不受本文件影响**：主题 `quality` 恒 `null`
// （`GlassThemeVariant.quality`），解析继续走「控件显式 → 隔离作用域 →
// 主题 → 控件类默认」链；运行时档位仍由 [GlassRuntime] / [GlassScope] 说了算。
//
// 契约测试：`test/ui/glass_material_test.dart`（常量字面量 + 组装 + 透传）。
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'glass_scope.dart';

/// MReader 玻璃材质参数（唯一事实源）。
///
/// 消费方式：
/// · 主题级——[themeData] 由 `main.dart` 的 `LiquidGlassWidgets.wrap(theme:)` 挂载；
/// · 控件级——[settingsFor] 在 `build` 里按亮度解析，显式传给库控件。
abstract final class GlassMaterial {
  // ── 主题级（亮模式）────────────────────────────────────────────────────────
  /// 亮模式材质：强磨砂（blur 9）+ 亮白玻璃色（α0.18）+ 环境光 0.2。
  ///
  /// 对照库默认（`GlassThemeVariant.light`：玻璃色 12% 冷蓝白 / blur 5 /
  /// 环境光 0.15 / thickness 12）：blur 接近翻倍（参考图是「内容透出但不可读」
  /// 的强 frost），玻璃色提亮并去掉冷蓝（参考图表面是亮白而非蓝灰），
  /// 厚度加到 16 给出一点折射体感。
  static const GlassThemeSettings light = GlassThemeSettings(
    thickness: 16,
    blur: 9,
    glassColor: Color.fromRGBO(255, 255, 255, 0.18),
    lightIntensity: 0.85,
    ambientStrength: 0.2,
    refractiveIndex: 1.2,
    saturation: 1.15,
    chromaticAberration: 0.01,
  );

  // ── 主题级（暗模式）────────────────────────────────────────────────────────
  /// 暗模式材质：磨砂 blur 8 + 白玻璃色 α0.10 + 环境光 0.06 + 微霜增白。
  ///
  /// 暗下面玻璃本身已发亮，增白只留 6%（且 `whitenGated: false`——按亮度门控
  /// 在近黑背板上会把增白整块归零，见 `LiquidGlassSettings.whitenGated` 注释）。
  static const GlassThemeSettings dark = GlassThemeSettings(
    thickness: 14,
    blur: 8,
    glassColor: Color.fromRGBO(255, 255, 255, 0.10),
    lightIntensity: 0.7,
    ambientStrength: 0.06,
    refractiveIndex: 1.2,
    saturation: 1.1,
    chromaticAberration: 0.01,
  );

  // ── 控件级（完整设置，含主题表达不了的 whitenStrength）────────────────────
  /// 亮模式完整设置（= [light] 全量 + 增白纱罩 0.16）。
  ///
  /// `whitenStrength` 是 iOS 26 亮模式玻璃的「可读性纱罩」：整面朝白色混染
  /// `mix(glass, white, 0.16)`，premium 路径作最后一步、standard/frosted 路径
  /// 用「玻璃色向白抬升」近似（`liquid_glass_settings.dart:408-422`）——
  /// 这就是参考图「表面亮白、图标文字清晰」的来源。
  static const LiquidGlassSettings _lightFull = LiquidGlassSettings(
    thickness: 16,
    blur: 9,
    glassColor: Color.fromRGBO(255, 255, 255, 0.18),
    lightIntensity: 0.85,
    ambientStrength: 0.2,
    refractiveIndex: 1.2,
    saturation: 1.15,
    chromaticAberration: 0.01,
    whitenStrength: 0.16,
    whitenGated: true,
  );

  /// 暗模式完整设置（= [dark] 全量 + 微霜增白 0.06，不按亮度门控）。
  static const LiquidGlassSettings _darkFull = LiquidGlassSettings(
    thickness: 14,
    blur: 8,
    glassColor: Color.fromRGBO(255, 255, 255, 0.10),
    lightIntensity: 0.7,
    ambientStrength: 0.06,
    refractiveIndex: 1.2,
    saturation: 1.1,
    chromaticAberration: 0.01,
    whitenStrength: 0.06,
    whitenGated: false,
  );

  /// 交互物理（全局去「放大」）——主题级单一出处。
  ///
  /// 2026-09-29 负责人拍板「移除放大特效」时只落在了导航栏
  /// （`GlassInteractionBehavior.glowOnly`）与浮层（[OverlayStyle] 的
  /// `interactionScale = 1.0`）两处；库其余交互控件（[GlassButton] /
  /// [GlassChip] / [GlassTextField]）的按下膨胀仍吃各自的硬编码默认
  /// （按钮按最长边 +17pt、chips 1.03）。主题级钉 `interactionScale: 1.0`
  /// 后全线一致；`stretch: 0.15` 保留一丝拖拽果冻感（0 = 完全刚体）。
  static const GlassInteractionSettings interaction = GlassInteractionSettings(
    interactionScale: 1.0,
    stretch: 0.15,
  );

  /// 按当前亮度解析控件级完整设置。
  ///
  /// 亮度经 [GlassScope.brightnessOf]（本作用域 → 库四级级联），与玻璃控件
  /// 内部的 `GlassTheme.brightnessOf` 同源；应用 ThemeMode 由 `main.dart` 的
  /// `brightnessResolver` 接进级联（`UI-01` ②）。
  static LiquidGlassSettings settingsFor(BuildContext context) {
    return GlassScope.brightnessOf(context) == Brightness.dark
        ? _darkFull
        : _lightFull;
  }

  /// 组装应用级 [GlassThemeData]（`main.dart` 的 `wrap(theme:)` 用）。
  ///
  /// `quality` 两档都留 `null`：不碰项目自己的档位链（`UI-05` ①：
  /// 固定表面由 `GlassScaffold` 自动提升 premium，中 / 低档由
  /// `GlassIsolationScope` 钉 standard / minimal）。
  static GlassThemeData get themeData => const GlassThemeData(
        light: GlassThemeVariant(settings: light),
        dark: GlassThemeVariant(settings: dark),
        interaction: interaction,
      );
}
