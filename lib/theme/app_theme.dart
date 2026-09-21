// 应用主题（PRD `UI-01` ②：玻璃必须跟随**应用 ThemeMode**，而非仅系统亮度）。
//
// 设计约定：
//   · 本文件**不 import 任何玻璃库**——有效亮度解析是纯逻辑，可在 `flutter pub get`
//     之前先单测（见 test/ui/app_theme_test.dart）。
//   · 主题色与基础文本样式以**具名、可复用**的形态暴露（`seed` / `bodyTextStyle` /
//     `primaryOf`），而不是只导出一个 `ThemeData`：
//       - M1-T05 合成封面要「背景取主题色」（`META-07` ①）→ 用 [AppTheme.seed] / [AppTheme.primaryOf]；
//       - M1-T06 排版要正文默认字号/行距 → 用 [AppTheme.bodyTextStyle]（口径与 `TYP-01` 一致）。
import 'package:flutter/material.dart';

import '../settings/settings_store.dart';

/// 主题色种子：玻璃卡片、合成封面、强调色的统一来源。
const Color kAppSeedColor = Colors.indigo;

/// 正文默认字号（逻辑像素，= `TYP-01` 默认值 18）。
const double kBodyFontSize = Settings.defaultFontSize;

/// 正文默认行距倍数（= `TYP-01` 默认值 1.6）。
const double kBodyLineHeight = Settings.defaultLineHeight;

/// 有效亮度解析（`UI-01` ② 的硬要求，**纯函数**，便于单测）。
///
/// 玻璃控件的亮度**必须**跟随应用主题三态（[AppThemeMode]），而不是只跟系统亮度：
/// - [AppThemeMode.light]  → 恒 [Brightness.light]（即使系统是深色）；
/// - [AppThemeMode.dark]   → 恒 [Brightness.dark]（即使系统是浅色）；
/// - [AppThemeMode.system] → 取 [platformBrightness]（系统亮度）。
Brightness resolveBrightness(AppThemeMode mode, Brightness platformBrightness) {
  switch (mode) {
    case AppThemeMode.light:
      return Brightness.light;
    case AppThemeMode.dark:
      return Brightness.dark;
    case AppThemeMode.system:
      return platformBrightness;
  }
}

/// 主题三态 → Flutter [ThemeMode]（供 `MaterialApp.themeMode` 使用）。
ThemeMode resolveThemeMode(AppThemeMode mode) {
  switch (mode) {
    case AppThemeMode.light:
      return ThemeMode.light;
    case AppThemeMode.dark:
      return ThemeMode.dark;
    case AppThemeMode.system:
      return ThemeMode.system;
  }
}

/// 合成封面的主题（日 / 夜）。
///
/// `META-07` 的「书名 + 作者 + 主题 合成封面」需要一个**小枚举**承载主题维度；
/// 本枚举由 `app_theme`（主题口径的**唯一出处**）暴露（架构 §N.7`SynthCoverRenderer.render`
/// 的 `CoverTheme theme` 参数）。
enum CoverTheme { day, night }

/// 有效亮度 → 合成封面主题。
CoverTheme coverThemeOf(Brightness brightness) =>
    brightness == Brightness.dark ? CoverTheme.night : CoverTheme.day;

/// 应用主题的具名出口（**只导出一个 `ThemeData` 是不够的**）。
abstract final class AppTheme {
  /// 主题色种子。合成封面（`META-07` ①「背景取主题色」）直接取它。
  static const Color seed = kAppSeedColor;

  /// 基础正文样式（M1-T06 排版取默认字号/行距）。
  static const TextStyle bodyTextStyle = TextStyle(
    fontSize: kBodyFontSize,
    height: kBodyLineHeight,
  );

  /// 浅色主题。
  static ThemeData light() => _build(Brightness.light);

  /// 深色主题。
  static ThemeData dark() => _build(Brightness.dark);

  /// 从当前上下文取主题色（合成封面 / 强调色）。
  static Color primaryOf(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  static ThemeData _build(Brightness brightness) => ThemeData(
        colorSchemeSeed: seed,
        brightness: brightness,
        useMaterial3: true,
      );
}
