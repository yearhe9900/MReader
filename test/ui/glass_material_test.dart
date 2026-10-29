// 玻璃**材质**唯一事实源的契约测试。
//
// 背景：全 app 曾未挂 `GlassTheme`（吃库默认），且书架搜索胶囊 / 分组 chips 是半透明
// 色块而非玻璃控件。本文件钉住四件事：
//   ① 常量字面量（亮 / 暗主题级 + 控件级完整设置 + 交互去放大）——改材质必须改
//      `glass_material.dart`，业务页面不许另写字面量；
//   ② `themeData` 组装（两档 settings 就位、quality 恒 null＝不碰 `UI-05` 档位链）；
//   ③ `settingsFor` 按亮度分流（整对象相等，含 whitenStrength / whitenGated）；
//   ④ [GlassNavBar] 把控件级材质透传给 `GlassTabBar.bottom`（库底栏不吃主题、
//      用私有预设 `kBottomBarGlassDefaults`，不传就永远是 blur 3 / 折射 1.59 那套）。
//
// 口径同 `overlay_style_test.dart`：期望值**硬编码字面量**（下方 `expected*`
// 常量），不引用被测代码——引用即同义反复、永远红不了。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/glass_material.dart';

import '../test_config.dart';

/// 亮模式**控件级完整设置**的字面量基准（与 `glass_material.dart` 的
/// `_lightFull` 逐项一致；whitenStrength 主题级表达不了，只能控件级给）。
const LiquidGlassSettings _expectedLightFull = LiquidGlassSettings(
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

/// 暗模式**控件级完整设置**的字面量基准（微霜 0.06 + 关门控）。
const LiquidGlassSettings _expectedDarkFull = LiquidGlassSettings(
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

/// 两个最小标签页（[GlassTab] 至少要有 icon 或 label）。
const List<GlassTab> _kTabs = <GlassTab>[
  GlassTab(icon: Icon(Icons.list), label: '书架'),
  GlassTab(icon: Icon(Icons.settings), label: '设置'),
];

/// 钉亮度宿主：[GlassTheme.brightness] 是四级级联的最高优先級，钉它即钉死
/// 玻璃控件的有效亮度（`GlassScope` 无作用域时走库级联）。
Widget _host(Brightness brightness, Widget home) => GlassTheme(
      data: GlassThemeData(brightness: brightness),
      child: MaterialApp(home: home),
    );

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('GlassMaterial 常量（字面量契约）', () {
    test('亮模式主题级：强磨砂 + 亮白玻璃色 + 环境光', () {
      const GlassThemeSettings s = GlassMaterial.light;
      expect(s.thickness, 16);
      expect(s.blur, 9);
      // 亮白（非库默认的冷蓝白 210,220,240）。
      expect(s.glassColor, const Color.fromRGBO(255, 255, 255, 0.18));
      expect(s.lightIntensity, 0.85);
      expect(s.ambientStrength, 0.2);
      expect(s.refractiveIndex, 1.2);
      expect(s.saturation, 1.15);
      expect(s.chromaticAberration, 0.01);
    });

    test('暗模式主题级：磨砂 8 + 白玻璃色 0.10 + 低环境光', () {
      const GlassThemeSettings s = GlassMaterial.dark;
      expect(s.thickness, 14);
      expect(s.blur, 8);
      expect(s.glassColor, const Color.fromRGBO(255, 255, 255, 0.10));
      expect(s.lightIntensity, 0.7);
      expect(s.ambientStrength, 0.06);
      expect(s.refractiveIndex, 1.2);
      expect(s.saturation, 1.1);
      expect(s.chromaticAberration, 0.01);
    });

    test('交互：全局去「放大」（interactionScale 1.0）+ 轻微果冻', () {
      expect(GlassMaterial.interaction.interactionScale, 1.0);
      expect(GlassMaterial.interaction.stretch, 0.15);
    });
  });

  group('GlassMaterial.themeData 组装', () {
    test('两档 settings 就位、quality 恒 null（不碰 UI-05 档位链）', () {
      final GlassThemeData data = GlassMaterial.themeData;
      expect(data.light.settings, same(GlassMaterial.light));
      expect(data.dark.settings, same(GlassMaterial.dark));
      // quality null = 解析继续走「控件显式 → 隔离作用域 → 主题 → 控件类默认」；
      // 固定表面 premium 自动提升（UI-05 ①）不受影响。
      expect(data.light.quality, isNull);
      expect(data.dark.quality, isNull);
      // 交互物理挂顶层（亮暗通用）。
      expect(data.interaction.interactionScale, 1.0);
    });
  });

  group('GlassMaterial.settingsFor 亮度分流（整对象相等）', () {
    testWidgets('亮模式 → 亮完整设置', (WidgetTester tester) async {
      LiquidGlassSettings? captured;
      await tester.pumpWidget(
        _host(
          Brightness.light,
          Builder(
            builder: (BuildContext ctx) {
              captured = GlassMaterial.settingsFor(ctx);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, _expectedLightFull);
    });

    testWidgets('暗模式 → 暗完整设置', (WidgetTester tester) async {
      LiquidGlassSettings? captured;
      await tester.pumpWidget(
        _host(
          Brightness.dark,
          Builder(
            builder: (BuildContext ctx) {
              captured = GlassMaterial.settingsFor(ctx);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, _expectedDarkFull);
    });
  });

  group('GlassNavBar 透传控件级材质（库底栏不吃主题）', () {
    testWidgets('亮模式：GlassTabBar.settings = 亮完整设置', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          Brightness.light,
          Scaffold(
            bottomNavigationBar: GlassNavBar(
              tabs: _kTabs,
              selectedIndex: 0,
              onTabSelected: (int _) {},
            ),
          ),
        ),
      );

      final GlassTabBar bar =
          tester.widget<GlassTabBar>(find.byType(GlassTabBar));
      expect(bar.settings, isNotNull,
          reason: '不传 settings 底栏就吃私有预设 kBottomBarGlassDefaults');
      expect(bar.settings, _expectedLightFull);
      // 反向：不得回落库预设（blur 3 / 折射 1.59 / 玻璃色 α0.24）。
      expect(bar.settings!.blur, isNot(3));
      expect(bar.settings!.refractiveIndex, isNot(1.59));
      expect(bar.settings!.glassColor.a, closeTo(0.18, 0.001));
    });

    testWidgets('暗模式：GlassTabBar.settings = 暗完整设置', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          Brightness.dark,
          Scaffold(
            bottomNavigationBar: GlassNavBar(
              tabs: _kTabs,
              selectedIndex: 0,
              onTabSelected: (int _) {},
            ),
          ),
        ),
      );

      final GlassTabBar bar =
          tester.widget<GlassTabBar>(find.byType(GlassTabBar));
      expect(bar.settings, _expectedDarkFull);
    });
  });
}
