// 底栏宿主集成测试。
//
// 组件本体（果冻飞行 / 沉降 / 拖拽 / 按压 / 圆钮 / 明暗配方）的契约由
// `test/ui/mi_like_ui/` 的移植套件 + 上游黄金图钉死；本文件只钉 **MReader 侧**的接线：
//   · 「关」档退化 Material [NavigationBar]（`UI-06` ②，功能完整可用）；
//   · 明暗映射（`UI-01` ②：`GlassScope` 亮度 → [MiThemeMode]，标签墨色同源）；
//   · 标签形态（3 格：书架 / 笔记 / 我的；「我的」= 参考项目笑脸贝雷帽 painter；
//     绿色圆钮挂在「书架」= `MiGlassNavFab.tabIndex == 0`）；
//   · 点按不被拖动识别器吞掉（notes-pitfalls §2.98 ④ 坑位回归——旧实现曾在
//     `onHorizontalDragCancel` 里置点击拦截位，导致**每一次点击**都被吞）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_nav_host.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';
import 'package:mreader/ui/nav_icons.dart';

import '../test_config.dart';

/// 钉档 + 钉亮度的宿主（[GlassScope] 直接构造，不经库级联）。
Widget host({
  required Brightness brightness,
  required GlassQualityTier tier,
  required List<MiGlassNavItem> items,
  required ValueChanged<int> onTap,
  int selectedIndex = 0,
  MiGlassNavFab? fab,
}) {
  return MaterialApp(
    home: GlassScope(
      brightness: brightness,
      config: glassTierConfigFor(tier),
      glassAllowed: true,
      child: Scaffold(
        body: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              bottom: 24.2,
              child: GlassNavHost(
                items: items,
                selectedIndex: selectedIndex,
                onTabSelected: onTap,
                themeMode: brightness == Brightness.dark
                    ? MiThemeMode.dark
                    : MiThemeMode.light,
                fab: fab,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 与 `home_shell._navItems` 同款的三格配置（墨色按明暗取）。
List<MiGlassNavItem> itemsFor(MiThemeMode mode) {
  final Color ink = MiColors.foregroundFor(mode);
  return <MiGlassNavItem>[
    MiGlassNavItem(label: '书架', painter: ShelfBooksIconPainter(ink)),
    MiGlassNavItem(label: '笔记', painter: NotesIconPainter(ink)),
    MiGlassNavItem(label: '我的', painter: SmileyBeretIconPainter(ink)),
  ];
}

/// 与 `home_shell` 同款的绿色圆钮（仅还原视觉，不接功能）。
MiGlassNavFab demoFab() => MiGlassNavFab(
      tabIndex: 0,
      child: CustomPaint(
        painter: GridDotsIconPainter(const Color(0xFFFFFFFF)),
        size: const Size.square(18.2),
      ),
    );

/// 从树里取「书架」图标的 painter（树里 CustomPaint 很多，按 painter 类型筛）。
ShelfBooksIconPainter shelfPainterOf(WidgetTester tester) {
  for (final CustomPaint paint
      in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    if (paint.painter is ShelfBooksIconPainter) {
      return paint.painter as ShelfBooksIconPainter;
    }
  }
  fail('未找到 ShelfBooksIconPainter（书架图标未渲染？）');
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  group('底栏宿主 · 关档退化（UI-06 ②）', () {
    testWidgets('关档：底栏换 Material NavigationBar，无玻璃底栏',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        brightness: Brightness.dark,
        tier: GlassQualityTier.off,
        items: itemsFor(MiThemeMode.dark),
        onTap: (_) {},
      ));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(MiGlassNavBar), findsNothing);
      // 功能完整可用：三个标签照常渲染。
      expect(find.text('书架'), findsOneWidget);
      expect(find.text('笔记'), findsOneWidget);
      expect(find.text('我的'), findsOneWidget);
    });

    testWidgets('关档点按仍切换', (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await tester.pumpWidget(host(
        brightness: Brightness.dark,
        tier: GlassQualityTier.off,
        items: itemsFor(MiThemeMode.dark),
        onTap: taps.add,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(taps, <int>[2]);
    });
  });

  group('底栏宿主 · 明暗映射（UI-01 ②）', () {
    testWidgets('暗色亮度 → MiThemeMode.dark 配方', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        brightness: Brightness.dark,
        tier: GlassQualityTier.high,
        items: itemsFor(MiThemeMode.dark),
        onTap: (_) {},
      ));
      await tester.pumpAndSettle();

      final MiGlassNavBar bar =
          tester.widget<MiGlassNavBar>(find.byType(MiGlassNavBar));
      expect(bar.themeMode, MiThemeMode.dark);
      // 标签墨色与配方同源（暗色 = #F5F5F5）。
      expect(shelfPainterOf(tester).color, MiColors.foreground);
    });

    testWidgets('亮色亮度 → MiThemeMode.light 配方', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        brightness: Brightness.light,
        tier: GlassQualityTier.high,
        items: itemsFor(MiThemeMode.light),
        onTap: (_) {},
      ));
      await tester.pumpAndSettle();

      final MiGlassNavBar bar =
          tester.widget<MiGlassNavBar>(find.byType(MiGlassNavBar));
      expect(bar.themeMode, MiThemeMode.light);
      expect(shelfPainterOf(tester).color, MiColors.foregroundLight);
    });
  });

  group('底栏宿主 · 标签形态', () {
    testWidgets('3 格：书架 / 笔记 / 我的，「我的」用参考项目笑脸贝雷帽',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        brightness: Brightness.dark,
        tier: GlassQualityTier.high,
        items: itemsFor(MiThemeMode.dark),
        onTap: (_) {},
        fab: demoFab(),
      ));
      await tester.pumpAndSettle();

      final MiGlassNavBar bar =
          tester.widget<MiGlassNavBar>(find.byType(MiGlassNavBar));
      expect(bar.items.map((MiGlassNavItem e) => e.label).toList(),
          <String>['书架', '笔记', '我的']);
      expect(bar.items[0].painter, isA<ShelfBooksIconPainter>());
      expect(bar.items[1].painter, isA<NotesIconPainter>());
      expect(bar.items[2].painter, isA<SmileyBeretIconPainter>());

      // 绿色圆钮挂在「书架」（tabIndex 0），与参考项目同款「预留空位圆钮」。
      expect(bar.fab, isNotNull);
      expect(bar.fab!.tabIndex, 0);
    });
  });

  group('底栏宿主 · 点按坑位回归（§2.98 ④）', () {
    testWidgets('连点三次，三次都触发（点击不被拖动识别器吞掉）',
        (WidgetTester tester) async {
      final List<int> taps = <int>[];
      int selected = 0;
      await tester.pumpWidget(host(
        brightness: Brightness.dark,
        tier: GlassQualityTier.high,
        items: itemsFor(MiThemeMode.dark),
        selectedIndex: selected,
        onTap: taps.add,
      ));
      await tester.pumpAndSettle();

      for (final String label in <String>['笔记', '我的', '书架']) {
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(taps, <int>[1, 2, 0]);
    });

    testWidgets('小幅拖动（未过 slop）后，紧随的点按仍生效',
        (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await tester.pumpWidget(host(
        brightness: Brightness.dark,
        tier: GlassQualityTier.high,
        items: itemsFor(MiThemeMode.dark),
        onTap: taps.add,
      ));
      await tester.pumpAndSettle();

      // 短拖：拖动识别器输掉竞技场 → onHorizontalDragCancel 在**同一次事件派发**
      // 里先来，紧接 tap。旧实现在 cancel 里置拦截位 ⇒ 每次点击都被吞。
      final Offset center = tester.getCenter(find.text('书架'));
      final TestGesture gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(4, 0));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('笔记'));
      await tester.pump(const Duration(milliseconds: 500));
      // 短拖的松手**本身**按「点在书架」触发（识别器输给 tap 的正常路径），
      // 随后点「笔记」再生效 ⇒ 两次点击都没被吞（旧 bug 会把两次都吞掉）。
      expect(taps, <int>[0, 1], reason: '短拖松手 + 紧随点按必须两次都触发');
    });
  });
}
