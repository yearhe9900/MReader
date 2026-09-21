// `UI-01` ② 有效亮度解析 + `TYP-03` 主题三态映射的单测（**纯逻辑，无 Widget**）。
//
// 本文件之所以可以早于 `flutter pub get` 先跑：`lib/theme/app_theme.dart` 不 import
// 任何玻璃库，有效亮度解析是纯函数。三态覆盖是 PRD `UI-01` ② 的硬要求。
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

    test('正文默认口径与 TYP-01 一致（字号 18 / 行距 1.6）', () {
      expect(AppTheme.bodyTextStyle.fontSize, Settings.defaultFontSize);
      expect(AppTheme.bodyTextStyle.height, Settings.defaultLineHeight);
      expect(AppTheme.bodyTextStyle.fontSize, 18.0);
      expect(AppTheme.bodyTextStyle.height, 1.6);
    });
  });
}
