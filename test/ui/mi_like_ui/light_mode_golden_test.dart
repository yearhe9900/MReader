import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 框架 API 走公共 barrel。
//
// MReader 移植注（2026-10-15）：原文件末尾两条 **demo 层**用例（DemoApp 明暗
// 切换联动 / demo 截图）未随移植——demo 层不在 MReader 树内；组件级亮色用例
// 即下面两条，与上游同名同断言。
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

// 亮色参考截图的三种典型背景（881×1920 实测色）：暗卡 / 灰白照片卡 / 蓝卡，
// 页面底色 #F7F7F7（新参考图平坦底色实测）—— 玻璃透射差异靠这些背景读出来。
Widget lightBackdrop() {
  return Container(
    color: const Color(0xFFF7F7F7),
    padding: const EdgeInsets.fromLTRB(20, 120, 20, 0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: Container(color: const Color(0xFF3C3C40))),
        const SizedBox(width: 12),
        Expanded(child: Container(color: const Color(0xFFB9C2CC))),
        const SizedBox(width: 12),
        Expanded(child: Container(color: const Color(0xFF6E8FE0))),
      ],
    ),
  );
}

List<MiGlassNavItem> itemsInk(Color ink) => [
      MiGlassNavItem(label: '首页', painter: RollerIconPainter(ink)),
      MiGlassNavItem(label: '分类', painter: GridSparkleIconPainter(ink)),
      MiGlassNavItem(label: '我的', painter: SmileyBeretIconPainter(ink)),
    ];

Widget lightFrame(int selected, {MiGlassNavFab? fab}) {
  final ink = MiColors.foregroundFor(MiThemeMode.light);
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: lightBackdrop()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24.2,
            child: MiGlassNavBar(
              items: itemsInk(ink),
              selectedIndex: selected,
              onTap: (_) {},
              themeMode: MiThemeMode.light,
              fab: fab,
            ),
          ),
        ],
      ),
    ),
  );
}

MiGlassNavFab lightFab() => MiGlassNavFab(
      tabIndex: 0,
      child: CustomPaint(
        painter: GridDotsIconPainter(const Color(0xFFFFFFFF)),
        size: const Size.square(18.2),
      ),
    );

void main() {
  testWidgets('light bar renders with the light palette (fab shown)', (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(393 * 3, 160 * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(lightFrame(0, fab: lightFab()));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(MiGlassNavBar), matchesGoldenFile('goldens/light_bar_home.png'));
  });

  testWidgets('light bar on another tab (fab hidden)', (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(393 * 3, 160 * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(lightFrame(2, fab: lightFab()));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(MiGlassNavBar), matchesGoldenFile('goldens/light_bar_mine.png'));
  });
}
