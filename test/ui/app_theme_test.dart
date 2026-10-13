// `UI-01` ② 有效亮度解析 + `TYP-03` 主题三态映射的单测（**纯逻辑，无 Widget**）。
//
// 本文件之所以可以早于 `flutter pub get` 先跑：`lib/theme/app_theme.dart` 不 import
// 任何玻璃库，有效亮度解析是纯函数。三态覆盖是 PRD `UI-01` ② 的硬要求。
// `CupertinoPageTransitionsBuilder` 不从 `material.dart` 导出（定义在 cupertino/route.dart），
// 故转场用例需要一个定向导入。
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/theme/app_theme.dart';

void main() {
  group('resolveBrightness（UI-01 ②：亮度必须跟随应用 ThemeMode，而非仅系统）', () {
    test('AppThemeMode.light → 恒为 light（即使系统是深色）', () {
      expect(
        resolveBrightness(AppThemeMode.light, Brightness.dark),
        Brightness.light,
      );
      expect(
        resolveBrightness(AppThemeMode.light, Brightness.light),
        Brightness.light,
      );
    });

    test('AppThemeMode.dark → 恒为 dark（即使系统是浅色）', () {
      expect(
        resolveBrightness(AppThemeMode.dark, Brightness.light),
        Brightness.dark,
      );
      expect(
        resolveBrightness(AppThemeMode.dark, Brightness.dark),
        Brightness.dark,
      );
    });

    test('AppThemeMode.system → 取平台亮度', () {
      expect(
        resolveBrightness(AppThemeMode.system, Brightness.light),
        Brightness.light,
      );
      expect(
        resolveBrightness(AppThemeMode.system, Brightness.dark),
        Brightness.dark,
      );
    });
  });

  group('resolveThemeMode（TYP-03 三态 → Flutter ThemeMode）', () {
    test('light / dark / system 一一对应', () {
      expect(resolveThemeMode(AppThemeMode.light), ThemeMode.light);
      expect(resolveThemeMode(AppThemeMode.dark), ThemeMode.dark);
      expect(resolveThemeMode(AppThemeMode.system), ThemeMode.system);
    });
  });

  group('AppTheme 具名出口（供 M1-T05 封面 / M1-T06 排版复用）', () {
    test('light / dark 的 brightness 正确、开启 Material3、共用同一 seed', () {
      final ThemeData light = AppTheme.light();
      final ThemeData dark = AppTheme.dark();

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.useMaterial3, isTrue);
      expect(dark.useMaterial3, isTrue);
      expect(AppTheme.seed, kAppSeedColor);
    });

    test('正文默认口径与 TYP-01 一致（字号 20 / 行距 1.6）', () {
      expect(AppTheme.bodyTextStyle.fontSize, Settings.defaultFontSize);
      expect(AppTheme.bodyTextStyle.height, Settings.defaultLineHeight);
      expect(AppTheme.bodyTextStyle.fontSize, 20.0);
      expect(AppTheme.bodyTextStyle.height, 1.6);
    });
  });

  group('页面转场（2026-09-29 拍板：关掉 Android 手势返回的缩放）', () {
    // 根因：targetSdk 36 + Android 16 → 系统预测性返回默认开启，而 Flutter 给 Android 的
    // 默认 builder 是 PredictiveBackPageTransitionsBuilder，手势中会把当前页缩到 0.90
    // 并加设备圆角（predictive_back_page_transitions_builder.dart:350/385/520-540）。
    test('Android 用 FadeForwards：既不是预测返回，也不是缩放式 Zoom', () {
      final PageTransitionsBuilder builder =
          AppTheme.light().pageTransitionsTheme.builders[TargetPlatform.android]!;

      expect(builder, isA<FadeForwardsPageTransitionsBuilder>());
      // 两条「反向断言」是本用例的真正价值：把「又被改回缩放」直接测红。
      expect(builder, isNot(isA<PredictiveBackPageTransitionsBuilder>()));
      expect(builder, isNot(isA<ZoomPageTransitionsBuilder>()));
    });

    test('浅色 / 深色共用同一套转场（避免两套主题漂移）', () {
      expect(
        AppTheme.dark().pageTransitionsTheme.builders[TargetPlatform.android],
        isA<FadeForwardsPageTransitionsBuilder>(),
      );
      expect(
        AppTheme.light().pageTransitionsTheme.builders[TargetPlatform.android]
            .runtimeType,
        AppTheme.dark().pageTransitionsTheme.builders[TargetPlatform.android]
            .runtimeType,
      );
    });

    test('其余四平台逐字保持框架默认（未扩大改动范围）', () {
      final Map<TargetPlatform, PageTransitionsBuilder> builders =
          AppTheme.light().pageTransitionsTheme.builders;

      expect(builders[TargetPlatform.iOS], isA<CupertinoPageTransitionsBuilder>());
      expect(builders[TargetPlatform.macOS], isA<CupertinoPageTransitionsBuilder>());
      expect(builders[TargetPlatform.windows], isA<ZoomPageTransitionsBuilder>());
      expect(builders[TargetPlatform.linux], isA<ZoomPageTransitionsBuilder>());
    });

    test('五个平台均有显式声明（缺省会落到 Zoom 回退，见框架 :881-890）', () {
      final Map<TargetPlatform, PageTransitionsBuilder> builders =
          AppTheme.light().pageTransitionsTheme.builders;

      // 必须显式声明而**不能**只写 android：框架对缺失平台的回退是
      // 「iOS → Cupertino，其余（含 macOS）→ Zoom」，只传 android 会让 macOS 退化。
      for (final TargetPlatform platform in const <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          builders[platform],
          isNotNull,
          reason: '$platform 缺显式声明会落到 Zoom 回退',
        );
      }
    });
  });
}
