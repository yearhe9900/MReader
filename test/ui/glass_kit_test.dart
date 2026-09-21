// `UI-04` 内容层不透明红线 + 玻璃档位策略（PRD §11.3）的单测。
//
// 三组断言：
//   ① 档位固定 `standard`，P0 不引入 `premium`（也不手动覆盖固定表面档位）；
//   ② `isGlassWidget` 是「是否玻璃控件」的可判定形式（红线自检的基础）；
//   ③ 内容层容器 [OpaqueContentSurface] 存在、底色完全不透明、且拒绝玻璃子控件。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/ui/glass_kit.dart';

void main() {
  group('玻璃档位固定为 standard（PRD §11.3 / P0）', () {
    test('应用档位 = standard', () {
      expect(kAppGlassQuality, GlassQuality.standard);
    });

    test('浮层 / 滚动区档位 = standard（非 premium / minimal）', () {
      expect(GlassKit.overlayQuality, GlassQuality.standard);
      expect(GlassOverlays.quality, GlassQuality.standard);
    });

    test('固定表面不手动覆盖档位（恒为 null → 交由库自动提升）', () {
      expect(GlassKit.fixedSurfaceQualityOverride, isNull);
    });
  });

  group('isGlassWidget（UI-04 红线的可判定形式）', () {
    test('玻璃控件判定为 true', () {
      expect(isGlassWidget(GlassCard(child: const SizedBox())), isTrue);
      expect(isGlassWidget(const SizedBox()), isFalse);
    });

    test('普通控件判定为 false', () {
      expect(isGlassWidget(const Text('正文')), isFalse);
      expect(isGlassWidget(const SizedBox(width: 8, height: 8)), isFalse);
    });
  });

  group('OpaqueContentSurface（UI-04 内容层不透明）', () {
    test('fullyOpaque 强制 alpha = 1', () {
      expect(OpaqueContentSurface.fullyOpaque(const Color(0x33112233)).a, 1.0);
    });

    testWidgets('容器存在、底色完全不透明、并自建 Material 祖先', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: OpaqueContentSurface(child: Text('正文'))),
      );

      expect(find.byType(OpaqueContentSurface), findsOneWidget);

      final Material material = tester.widget<Material>(find.byType(Material));
      expect(material.color, isNotNull);
      expect(material.color!.a, 1.0, reason: '内容层底色必须完全不透明');
    });

    testWidgets('内容层不得直接嵌套玻璃控件（debug 断言拒绝）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OpaqueContentSurface(
            child: GlassCard(child: const SizedBox(width: 8, height: 8)),
          ),
        ),
      );

      // 断言在 build 内触发，被测试框架捕获；玻璃不可嵌套（PRD §11.4）。
      expect(tester.takeException(), isA<AssertionError>());
    });
  });
}
