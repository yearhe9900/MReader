// 阅读页底部 chrome 的**布局契约**：六格悬浮工具栏（章节选择行已下线）。
//
// 钉住：
//   ① 四档屏宽（800/393/360/320）六格一个不少、无溢出；胶囊宽 = 屏宽 − 24
//      （宽屏封顶 6×64 + 24 = 408，仍是胶囊不是横幅）；
//   ② 六格文案按截图：目录/书签/外观/操作/查找/日间（夜间）；
//   ③ 「操作」无收纳项时该格降禁用态（不消失）；
//   ④ 章节选择行（上一章 / 滑条 / 下一章）与拖动气泡**已下线**（2026-11-10
//      负责人口径）——相关 key 一律不在树上，防回潮；
//   ⑤ 盒高 = 胶囊 72（+ 系统 inset），覆盖层不给正文排版带来额外预算。
//
// ⚠️ 期望值用硬编码字面量 / 实测 rect，不用被测常量自证。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  Future<void> pumpBar(
    WidgetTester tester,
    int width, {
    bool withActions = true,
    bool nightActive = false,
    double bottomInset = 0,
  }) async {
    tester.view.physicalSize = Size(width.toDouble(), 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(bottom: bottomInset);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ReaderControlBar(
          onToc: () {},
          onBookmarks: () {},
          onAppearance: () {},
          onActions: withActions ? () {} : null,
          onSearch: () {},
          onNight: () {},
          nightActive: nightActive,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('六格悬浮工具栏', () {
    testWidgets('四档屏宽六格一个不少、无溢出', (WidgetTester tester) async {
      for (final int width in <int>[800, 393, 360, 320]) {
        await pumpBar(tester, width);
        expect(tester.takeException(), isNull,
            reason: '${width}dp 宽下不得出现 RenderFlex 溢出');
        for (final String key in <String>[
          'reader-toc',
          'reader-bookmarks',
          'reader-appearance',
          'reader-more',
          'reader-search',
          'reader-night',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget,
              reason: '${width}dp 下 $key 不应消失');
        }
      }
    });

    testWidgets('六格文案按截图：目录/书签/外观/操作/查找/夜间（日间）',
        (WidgetTester tester) async {
      await pumpBar(tester, 393);
      for (final String label in <String>[
        '目录',
        '书签',
        '外观',
        '操作',
        '查找',
        '夜间',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺格 $label');
      }

      await pumpBar(tester, 393, nightActive: true);
      expect(find.text('日间'), findsOneWidget,
          reason: '夜间态末格文案应是「切到日间」这个动作');
      expect(find.text('夜间'), findsNothing);
    });

    testWidgets('胶囊宽 = 屏宽 − 24（宽屏封顶 408）、居中不越屏',
        (WidgetTester tester) async {
      for (final int width in <int>[393, 360, 320]) {
        await pumpBar(tester, width);
        final Rect pill =
            tester.getRect(find.byKey(const Key('reader-toolbar-pill')));
        expect(pill.width, moreOrLessEquals(width - 24, epsilon: 0.6),
            reason: '${width}dp 下胶囊宽 ${pill.width}');
        expect(pill.center.dx, moreOrLessEquals(width / 2, epsilon: 0.5));
        expect(pill.left, greaterThanOrEqualTo(0));
        expect(pill.right, lessThanOrEqualTo(width + 0.5));
      }

      await pumpBar(tester, 800);
      final Rect wide =
          tester.getRect(find.byKey(const Key('reader-toolbar-pill')));
      expect(wide.width, moreOrLessEquals(6 * 64 + 24, epsilon: 0.6),
          reason: '宽屏每格封顶 64dp，胶囊仍应是 408dp');
      expect(wide.center.dx, moreOrLessEquals(400, epsilon: 0.5));
    });

    testWidgets('章节选择行已下线：章节行 / 章钮 / 滑条 / 气泡全不在树上',
        (WidgetTester tester) async {
      await pumpBar(tester, 393);
      for (final String key in <String>[
        'reader-chapter-row',
        'reader-control-prev',
        'reader-control-next',
        'reader-control-progress',
        'reader-chapter-preview',
      ]) {
        expect(find.byKey(Key(key)), findsNothing,
            reason: '$key 属已下线的章节滑条功能，不许回潮');
      }
    });

    testWidgets('「操作」无收纳项 → 该格禁用但不消失',
        (WidgetTester tester) async {
      await pumpBar(tester, 800, withActions: false);
      final MiActionEntry entry =
          tester.widget<MiActionEntry>(find.byKey(const Key('reader-more')));
      expect(entry.onPressed, isNull);
      expect(find.text('操作'), findsOneWidget);

      await pumpBar(tester, 800, withActions: true);
      expect(
        tester
            .widget<MiActionEntry>(find.byKey(const Key('reader-more')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('盒高是覆盖层常量：胶囊 72，系统 inset 另计不吞正文',
        (WidgetTester tester) async {
      await pumpBar(tester, 393);
      final double plain =
          tester.getSize(find.byType(ReaderControlBar)).height;
      expect(plain, moreOrLessEquals(72, epsilon: 0.5),
          reason: '盒高 = 胶囊（外留白 16 + 单格 56）= 72，实际 $plain');

      await pumpBar(tester, 393, bottomInset: 34);
      final double withInset =
          tester.getSize(find.byType(ReaderControlBar)).height;
      expect(withInset, moreOrLessEquals(plain + 34, epsilon: 0.5),
          reason: '系统手势条 inset 应计入盒高，胶囊仍让开它');
    });
  });
}
