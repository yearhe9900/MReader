import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 框架 API 走公共 barrel；若导出缺失会在这里暴露。
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

/// 自适应（响应式）回归：断点判定 / 等比缩放画布 / 网格列数 / 窗口实时变化。
///
/// 上游同名测试还覆盖 demo 外壳三档（DemoStage/DemoHome），MReader 侧无
/// demo 层，只移植框架纯函数与组件组；壳层形态由 MReader 自己的用例覆盖。
///
/// 判据约定：
///  * **不溢出** = `tester.takeException()` 为 null（`RenderFlex overflowed`
///    在 debug 下会记为 FlutterError，被这里捕获）；
///  * **不变形** = 渲染宽高比恒等于设计宽高比（compact/medium 档）；
///  * **不丢内容** = 关键部件（导航栏 / 卡片）的渲染矩形完整落在窗口内。
void main() {
  group('MiBreakpoints', () {
    test('窗口三档边界', () {
      expect(MiBreakpoints.ofWidth(0), MiWindowSize.compact);
      expect(MiBreakpoints.ofWidth(320), MiWindowSize.compact);
      expect(MiBreakpoints.ofWidth(599.99), MiWindowSize.compact);
      expect(MiBreakpoints.ofWidth(600), MiWindowSize.medium);
      expect(MiBreakpoints.ofWidth(1023.99), MiWindowSize.medium);
      expect(MiBreakpoints.ofWidth(1024), MiWindowSize.expanded);
      expect(MiBreakpoints.ofWidth(3000), MiWindowSize.expanded);
    });

    test('列数按容器宽断点，并 clamp 到 [1, maxColumns]', () {
      int cols(double w, {int maxColumns = 12}) => MiBreakpoints.columnsFor(
            w,
            compact: 3,
            medium: 4,
            expanded: 6,
            maxColumns: maxColumns,
          );
      expect(cols(393), 3);
      expect(cols(599), 3);
      expect(cols(600), 4);
      expect(cols(1023), 4);
      expect(cols(1024), 6);
      // 非法/极端值不产生 0 列，也不无限扩列
      expect(
        MiBreakpoints.columnsFor(120, compact: 0, medium: 0, expanded: 0),
        1,
      );
      expect(cols(4000, maxColumns: 5), 5);
    });
  });

  group('MiScaledCanvas', () {
    test('scaleFor 取两方向较小者、只缩不放', () {
      const design = Size(393, 856);
      // 宽受限
      expect(MiScaledCanvas.scaleFor(const Size(200, 800), design),
          closeTo(200 / 393, 1e-9));
      // 高受限
      expect(MiScaledCanvas.scaleFor(const Size(800, 400), design),
          closeTo(400 / 856, 1e-9));
      // 空间足够：按上限 1x，不放大
      expect(MiScaledCanvas.scaleFor(const Size(800, 1000), design), 1.0);
      // 显式放开上限：仍取两方向较小者（这里高受限）
      expect(
        MiScaledCanvas.scaleFor(const Size(800, 1000), design, maxScale: 2),
        closeTo(1000 / 856, 1e-9),
      );
      // 两方向都无界：不无限放大
      expect(
        MiScaledCanvas.scaleFor(const Size(double.infinity, double.infinity), design),
        1.0,
      );
    });

    testWidgets('画布按设计尺寸布局、按比例渲染，且完整落在父级内', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(200, 400);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MiScaledCanvas(
              designSize: const Size(393, 856),
              child: const ColoredBox(
                key: ValueKey('canvas'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );

      // 布局尺寸 = 设计尺寸（逻辑尺寸不变，只改渲染尺寸）
      final logical = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('canvas')),
      ).size;
      expect(logical, const Size(393, 856));

      // 渲染尺寸 = 等比缩放到 200×400 内（高受限 → 高撑满 400）
      final rect = tester.getRect(find.byKey(const ValueKey('canvas')));
      expect(rect.height, closeTo(400, 0.01));
      expect(rect.width, closeTo(393 * 400 / 856, 0.01));
      expect(rect.width / rect.height, closeTo(393 / 856, 1e-6));
      expect(tester.takeException(), isNull);
    });
  });

  group('MiResponsiveGrid', () {
    Widget gridWith({required double width, required int count}) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: MiResponsiveGrid(
                compactColumns: 3,
                mediumColumns: 4,
                expandedColumns: 6,
                itemSpacing: 10,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < count; i++)
                    SizedBox(key: ValueKey(i), height: 20),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('等分列宽、末行留空不拉伸、不溢出', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 400);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(gridWith(width: 300, count: 7));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      const cellWidth = (300 - 2 * 10) / 3; // 93.33
      final a = tester.getTopLeft(find.byKey(const ValueKey(0)));
      final b = tester.getTopLeft(find.byKey(const ValueKey(1)));
      final d = tester.getTopLeft(find.byKey(const ValueKey(3)));
      // 3 列：列宽 93.33、相邻列起点差 = 列宽 + 间距 10
      expect(b.dx - a.dx, closeTo(cellWidth + 10, 0.01));
      // 第 4 项回到第一列、落到下一行
      expect(d.dx, closeTo(a.dx, 0.01));
      expect(d.dy, greaterThan(a.dy));
      // 每格宽 = 列宽（Expanded 等分，末行只有 1 项也不被拉满行）
      expect(
        tester.getSize(find.byKey(const ValueKey(0))).width,
        closeTo(cellWidth, 0.01),
      );
    });

    testWidgets('宽容器换到 6 列', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 400);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(gridWith(width: 1100, count: 7));
      await tester.pumpAndSettle();
      final a = tester.getTopLeft(find.byKey(const ValueKey(0)));
      final e = tester.getTopLeft(find.byKey(const ValueKey(5)));
      final f = tester.getTopLeft(find.byKey(const ValueKey(6)));
      expect(e.dy, closeTo(a.dy, 0.01)); // 第 6 项仍在首行
      expect(f.dy, greaterThan(a.dy)); // 第 7 项换行
    });
  });

  group('MiViewport', () {
    testWidgets('随窗口尺寸变化重建', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 856);
      addTearDown(tester.view.reset);

      final seen = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final viewport = MiViewport.of(context);
              seen.add(viewport.windowSize.name);
              return Text(viewport.windowSize.name);
            },
          ),
        ),
      );
      expect(find.text('compact'), findsOneWidget);

      tester.view.physicalSize = const Size(800, 856);
      await tester.pumpAndSettle();
      expect(find.text('medium'), findsOneWidget);

      tester.view.physicalSize = const Size(1400, 900);
      await tester.pumpAndSettle();
      expect(find.text('expanded'), findsOneWidget);
      expect(seen, ['compact', 'medium', 'expanded']);
    });
  });
}
