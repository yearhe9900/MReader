// 页面推入转场（[MiCardPageRoute]）契约 —— 几何 / 时值 / 两种角色 / 终态零图层。
//
// 2026-10-22 上游 `b003a87 feat(navigation): 页面推入转场 MiCardPageRoute`
// 一比一移植（移植树 `lib/ui/mi_like_ui/src/components/navigation/card_page_route/`），
// 用例同步移植；上游 demo 专属的「示例接线」组不适用本仓库（宿主接线见
// `test/ui/shelf_page_test.dart` 的搜索推入用例）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

/// 规格口径：素材 393dp 设计宽。
void main() {
  const pageKey = ValueKey<String>('incoming');
  const hostKey = ValueKey<String>('host');
  const double w = 393.0;
  const double h = 856.0;

  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(w, h);
    addTearDown(tester.view.reset);
    // 宿主首页**也用本路由**：下层页的视差靠 secondaryAnimation，
    // 平台自带路由没有这个钩子。
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        initialRoute: '/',
        onGenerateRoute: (RouteSettings settings) => MiCardPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(
            key: hostKey,
            body: Center(
              child: TextButton(
                onPressed: () => navigatorKey.currentState!.push(
                  MiCardPageRoute<void>(
                    builder: (_) => const Scaffold(
                      key: pageKey,
                      body: SizedBox.expand(),
                    ),
                  ),
                ),
                child: const Text('push'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double leftOf(WidgetTester tester, Key key) =>
      tester.getTopLeft(find.byKey(key)).dx;

  group('几何与时值', () {
    test('时值 / 圆角 / 视差都是度量值', () {
      expect(MiCardPageRouteMetrics.durationMs, 400);
      // 素材 190px ÷ 3.104 px/dp = 61.2
      expect(MiCardPageRouteMetrics.cornerRadius, moreOrLessEquals(61.2));
      expect(MiCardPageRouteMetrics.parallaxFraction, 0.25);
      expect(MiCardPageRouteMetrics.dimAlpha, moreOrLessEquals(0.55));
      // 位置曲线 = easeOutCubic
      expect(
        MiCardPageRouteMetrics.motion.transform(0.5),
        moreOrLessEquals(Curves.easeOutCubic.transform(0.5)),
      );
    });

    test('压暗随进度线性淡入，两端夹紧', () {
      expect(MiTransparencyTokens.pushDimAt(0).a, 0);
      expect(
        MiTransparencyTokens.pushDimAt(1).a,
        moreOrLessEquals(MiTransparencyTokens.pushDimAlphaMax, epsilon: 0.01),
      );
      expect(
        MiTransparencyTokens.pushDimAt(0.5).a,
        moreOrLessEquals(MiTransparencyTokens.pushDimAlphaMax * 0.5,
            epsilon: 0.01),
      );
      // 越界不炸
      expect(MiTransparencyTokens.pushDimAt(-1).a, 0);
      expect(
        MiTransparencyTokens.pushDimAt(2).a,
        moreOrLessEquals(MiTransparencyTokens.pushDimAlphaMax, epsilon: 0.01),
      );
    });

    testWidgets('新页起手整页在右缘外、400ms 归位到 0', (WidgetTester tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump();
      expect(leftOf(tester, pageKey), moreOrLessEquals(w, epsilon: 1),
          reason: '起手 = FractionalTranslation(+1)，整页在右缘外');
      // 半程：easeOutCubic 已经走掉 87.5%，故只要求落在中间区间
      await tester.pump(const Duration(milliseconds: 100));
      final double mid = leftOf(tester, pageKey);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(w));
      await tester.pump(const Duration(milliseconds: 300));
      expect(leftOf(tester, pageKey), moreOrLessEquals(0, epsilon: 0.5));
    });

    testWidgets('转场中前缘有 61.2 圆角，归位后不再裁剪', (WidgetTester tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final ClipRRect clip = tester.widget<ClipRRect>(
        find
            .ancestor(
              of: find.byKey(pageKey),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(
        clip.borderRadius,
        BorderRadius.circular(MiCardPageRouteMetrics.cornerRadius),
      );

      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.ancestor(
          of: find.byKey(pageKey),
          matching: find.byType(ClipRRect),
        ),
        findsNothing,
        reason: '归位后不加任何图层：静止页逐像素不变',
      );
    });

    testWidgets('转场中铺全屏压暗，归位后撤掉', (WidgetTester tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final double dim = MiTransparencyTokens.pushDimAt(0.5).a;
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is ColoredBox &&
              w.color.r == 0 &&
              w.color.g == 0 &&
              w.color.b == 0 &&
              (w.color.a - dim).abs() < 0.02,
        ),
        findsWidgets,
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color.a > 0 && w.color.a < 0.9,
        ),
        findsNothing,
        reason: '归位后不再留半透明层（否则静止页多一次全屏绘制）',
      );
    });

    testWidgets('下层页按 0.25 × 页宽左移，且不缩放', (WidgetTester tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final double visual = Curves.easeOutCubic.transform(0.5);
      expect(
        leftOf(tester, hostKey),
        moreOrLessEquals(
            -MiCardPageRouteMetrics.parallaxFraction * w * visual),
      );
      // 高度不变 → 只平移、没缩放
      expect(tester.getSize(find.byKey(hostKey)).height, moreOrLessEquals(h));
      await tester.pumpAndSettle();
    });
  });

  group('进出与栈行为', () {
    testWidgets('返回时新页滑回右缘并出栈', (WidgetTester tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(find.byKey(pageKey), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final double mid = leftOf(tester, pageKey);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(w));

      await tester.pumpAndSettle();
      expect(find.byKey(pageKey), findsNothing);
      // 下层页回到原位
      expect(leftOf(tester, hostKey), moreOrLessEquals(0, epsilon: 0.5));
    });

    testWidgets('压暗层不吃手势', (WidgetTester tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final Finder dimBox = find.byWidgetPredicate(
        (Widget w) => w is ColoredBox && w.color.r == 0 && w.color.a > 0,
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(of: dimBox, matching: find.byType(IgnorePointer))
                  .first,
            )
            .ignoring,
        isTrue,
      );
      await tester.pumpAndSettle();
    });
  });
}
