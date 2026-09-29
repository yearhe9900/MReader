// 应用主题（PRD `UI-01` ②：玻璃必须跟随**应用 ThemeMode**，而非仅系统亮度）。
//
// 设计约定：
//   · 本文件**不 import 任何玻璃库**——有效亮度解析是纯逻辑，可在 `flutter pub get`
//     之前先单测（见 test/ui/app_theme_test.dart）。
//   · 主题色与基础文本样式以**具名、可复用**的形态暴露（`seed` / `bodyTextStyle` /
//     `primaryOf`），而不是只导出一个 `ThemeData`：
//       - M1-T05 合成封面要「背景取主题色」（`META-07` ①）→ 用 [AppTheme.seed] / [AppTheme.primaryOf]；
//       - M1-T06 排版要正文默认字号/行距 → 用 [AppTheme.bodyTextStyle]（口径与 `TYP-01` 一致）。
// `CupertinoPageTransitionsBuilder` 定义在 `src/cupertino/route.dart`，
// **不经 `material.dart` 导出**——这里只定向引它，避免整包 cupertino 与 material
// 的同名符号（如 `RefreshCallback`）冲突。
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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

/// 主题三态的中文名（设置页「外观」组用；措辞照 `TYP-03`「日间 / 夜间 / 跟随系统」）。
///
/// 与 [resolveThemeMode] 同处一地——避免「一处主题、两处口径」（同
/// `app.dart` 对映射函数集中放置的说明）。设置页把它同时用作行的当前值与
/// 弹层候选项文案，故**只此一份**。
String appThemeModeLabel(AppThemeMode mode) {
  switch (mode) {
    case AppThemeMode.light:
      return '日间';
    case AppThemeMode.dark:
      return '夜间';
    case AppThemeMode.system:
      return '跟随系统';
  }
}

/// 应用页面转场（2026-09-29 拍板：**关掉 Android 手势返回的缩放动画**）。
///
/// ══════════════════════════════════════════════════════════════════════════════
/// 根因（读 Flutter 3.47 源码 + 清单 + 设备三方交叉）
/// ══════════════════════════════════════════════════════════════════════════════
/// `targetSdk = 36`（Flutter 3.47 默认，`FlutterExtension.kt:34`）且设备为 Android 16 时，
/// **系统预测性返回默认开启**（清单未声明 `enableOnBackInvokedCallback`）；而 Flutter 给
/// Android 的默认转场是 [PredictiveBackPageTransitionsBuilder]（`page_transitions_theme.dart:766`），
/// 它在手势进行中（`route.popGestureInProgress`）走 shared-element 转场，内部就是
/// **`Transform.scale` 缩到 0.90**（`_kMinScale`）外加设备圆角 `ClipRRect` 与淡出
/// （`predictive_back_page_transitions_builder.dart:350/385/520-540`）——即
/// 「手指还没松开，页面就先缩小成一张圆角卡片」。负责人要求关闭该效果。
///
/// ══════════════════════════════════════════════════════════════════════════════
/// 处置与代价
/// ══════════════════════════════════════════════════════════════════════════════
/// Android 改 [FadeForwardsPageTransitionsBuilder]（Android 16 原生 M3 风格：
/// 横向位移 + 淡出，**无缩放、无圆角**；`transitionDuration` 与预测返回同为 450ms，
/// 故**时长不变、只有观感变**）。
///
/// 该 builder **不含** `_PredictiveBackGestureDetector`，故系统手势不再被 App 接管。
/// 框架对此有明确回落：无人处理预测性返回时，提交即走普通 `handlePopRoute()`
/// （`widgets/binding.dart:1196-1205`）——**返回功能不受影响**，
/// 代价仅是拖动过程不再有跟手预览（无 preview，松手后播完整转场）。
///
/// **其余四个平台逐字保持框架默认**，这里必须写**全量**映射：
/// `_PageTransitionsThemeTransitionsState.build:881-890` 的缺省回退是
/// 「iOS → Cupertino，其余（**含 macOS**）→ Zoom」，只传 `{android: …}`
/// 会让 macOS 从 Cupertino 悄悄退化成 Zoom（即把缩放又引回来）。
///
/// **未动（待负责人定，未擅自扩大范围）**：Windows / Linux 仍是
/// [ZoomPageTransitionsBuilder]（框架默认）——按返回键时同样是缩小式转场，
/// 只是发生在「按钮返回」而非「手势返回」。
const PageTransitionsTheme kAppPageTransitions = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(),
    TargetPlatform.linux: ZoomPageTransitionsBuilder(),
  },
);

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
        // 页面转场：Android 换掉预测性返回的缩放（见 [kAppPageTransitions]）。
        // 浅色 / 深色共用同一份映射，避免两套主题观感漂移。
        pageTransitionsTheme: kAppPageTransitions,
      );
}
