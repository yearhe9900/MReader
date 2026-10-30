// 阅读页底部菜单（mi_like_ui 风格）的**布局契约**。
//
// 背景：旧控制条是「章节 / 朗读与 AI / 排版」三分组两行 11 控件；按截图形态
// 简化为两行菜单（`control_bar.dart`）：第一行 上一章—进度滑条—下一章，
// 第二行 目录 / 夜间 / 设置 / 更多 四格。本测试钉住：
//   ① 菜单不吞正文高度（覆盖层，高 ≤ 110dp）；
//   ② 四档屏宽（800/393/360/320）均无溢出；
//   ③ 控件一个不少（四格 + 两章钮 + 滑条，窄屏也不吞控件）；
//   ④ 进度滑条始终可用（宽度不下探 60dp）；
//   ⑤ 首章 / 末章：章钮降禁用态而非消失；
//   ⑥ 「更多」无收纳项时该格不渲染（不留空壳）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  // 按给定屏宽构建阅读页菜单并 settle。
  Future<void> pumpBar(
    WidgetTester tester,
    int width, {
    bool withMore = true,
    bool canGoPrev = true,
    bool canGoNext = true,
    int chapterIndex = 42,
    int chapterCount = 1152,
  }) async {
    tester.view.physicalSize = Size(width.toDouble(), 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ReaderControlBar(
          chapterIndex: chapterIndex,
          chapterCount: chapterCount,
          canGoPrev: canGoPrev,
          canGoNext: canGoNext,
          onPrevChapter: () {},
          onNextChapter: () {},
          onSeek: (int _) {},
          onToc: () {},
          onNight: () {},
          nightActive: false,
          onSettings: () {},
          onMore: withMore ? () {} : null,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('阅读页底部菜单（简化形态）', () {
    testWidgets('菜单不吞正文高度：两行 ≤ 110dp', (WidgetTester tester) async {
      // 两行标称 44 + 56 = 100dp；断言上限而非精确值——真值口径是
      // 「不得显著长高」，因为菜单是 `bottomNavigationBar` 覆盖层，
      // 长高 1dp 就是正文少 1dp（`TYP-09` 契约由 inset 测试钉住）。
      await pumpBar(tester, 800);
      expect(tester.getSize(find.byType(ReaderControlBar)).height,
          lessThanOrEqualTo(110));
    });

    testWidgets('四档屏宽（800/393/360/320）均无溢出、无重叠',
        (WidgetTester tester) async {
      for (final int width in <int>[800, 393, 360, 320]) {
        await pumpBar(tester, width);
        expect(tester.takeException(), isNull,
            reason: '${width}dp 宽下不得出现 RenderFlex 溢出');
      }
    });

    testWidgets('控件一个不少：章钮 2 + 滑条 + 四格全在（窄屏也不吞控件）',
        (WidgetTester tester) async {
      for (final int width in <int>[393, 320]) {
        await pumpBar(tester, width);
        for (final String key in <String>[
          'reader-control-prev',
          'reader-control-next',
          'reader-control-progress',
          'reader-toc',
          'reader-night',
          'reader-appearance',
          'reader-more',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget,
              reason: '${width}dp 下 $key 不应消失');
        }
      }
    });

    testWidgets('进度滑条始终可用：四档宽度均 > 60dp',
        (WidgetTester tester) async {
      for (final int width in <int>[800, 393, 360, 320]) {
        await pumpBar(tester, width);
        final double sliderWidth = tester
            .getSize(find.byKey(const Key('reader-control-progress')))
            .width;
        expect(sliderWidth, greaterThan(60),
            reason: '${width}dp 下进度滑条宽 ${sliderWidth}dp，已不可用');
      }
    });

    testWidgets('首章 / 末章：章钮保留为禁用态（不消失）',
        (WidgetTester tester) async {
      await pumpBar(tester, 800, canGoPrev: false, canGoNext: false);

      // Key 挂在 MiPressable 包装层上，取它读 onPressed。
      final MiPressable prev =
          tester.widget<MiPressable>(find.byKey(const Key('reader-control-prev')));
      final MiPressable next =
          tester.widget<MiPressable>(find.byKey(const Key('reader-control-next')));
      expect(prev.onPressed, isNull, reason: '首章「上一章」应为禁用态');
      expect(next.onPressed, isNull, reason: '末章「下一章」应为禁用态');
      expect(find.byKey(const Key('reader-control-prev')), findsOneWidget,
          reason: '禁用不等于消失');
    });

    testWidgets('「更多」无收纳项 → 该格不渲染；有则在场',
        (WidgetTester tester) async {
      await pumpBar(tester, 800, withMore: false);
      expect(find.byKey(const Key('reader-more')), findsNothing,
          reason: '全不可用时不留空壳格子');

      await pumpBar(tester, 800, withMore: true);
      expect(find.byKey(const Key('reader-more')), findsOneWidget);
    });

    testWidgets('单章书：滑条降禁用（无处可跳）', (WidgetTester tester) async {
      await pumpBar(tester, 800, chapterCount: 1);
      final MiSlider slider = tester
          .widget<MiSlider>(find.byKey(const Key('reader-control-progress')));
      expect(slider.onChanged, isNull, reason: '单章书滑条应禁用');
    });
  });
}
