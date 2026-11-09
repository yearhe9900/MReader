// §2.122 阅读页底部 chrome 的**布局契约**：章节选择行 + 六格悬浮工具栏。
//
// 钉住：
//   ① 四档屏宽（800/393/360/320）六格一个不少、无溢出；胶囊宽 = 屏宽 − 24
//      （宽屏封顶 6×64 + 24 = 408，仍是胶囊不是横幅）；
//   ② 章节行在工具栏**上方**，上一章 / 滑条 / 下一章全在、滑条 > 60dp；
//   ③ 首末章钮降禁用态但**不消失**、单章书滑条禁用；
//   ④ 拖动滑条显示「章节名 · 进度」气泡、松手收起，落点按章吸附上抛；
//   ⑤ 「操作」无收纳项时该格降禁用态（不消失）；末格随明暗切「日间 / 夜间」；
//   ⑥ 盒高是覆盖层常量（≤ 180dp），不给正文排版带来额外预算。
//
// ⚠️ 期望值用硬编码字面量 / 实测 rect，不用被测常量自证。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  final List<int> seeked = <int>[];

  Future<void> pumpBar(
    WidgetTester tester,
    int width, {
    bool withActions = true,
    bool canGoPrev = true,
    bool canGoNext = true,
    int chapterIndex = 42,
    int chapterCount = 1152,
    bool nightActive = false,
    double bottomInset = 0,
  }) async {
    seeked.clear();
    tester.view.physicalSize = Size(width.toDouble(), 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(bottom: bottomInset);
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
          onSeek: seeked.add,
          previewLabel: (int index) => '第${index + 1}章 · 21%',
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

  group('§2.122 六格工具栏 + 章节选择行', () {
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

    testWidgets('章节行在工具栏上方，章钮 + 滑条全在且滑条 > 60dp',
        (WidgetTester tester) async {
      for (final int width in <int>[393, 320]) {
        await pumpBar(tester, width);
        final Rect row =
            tester.getRect(find.byKey(const Key('reader-chapter-row')));
        final Rect pill =
            tester.getRect(find.byKey(const Key('reader-toolbar-pill')));
        expect(row.bottom, lessThan(pill.top),
            reason: '章节行必须悬在工具栏上方');
        for (final String key in <String>[
          'reader-control-prev',
          'reader-control-next',
          'reader-control-progress',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget);
        }
        final double sliderWidth = tester
            .getSize(find.byKey(const Key('reader-control-progress')))
            .width;
        expect(sliderWidth, greaterThan(60),
            reason: '${width}dp 下滑条宽 $sliderWidth 已不可用');
      }
    });

    testWidgets('首章 / 末章：章钮保留为禁用态（不消失）',
        (WidgetTester tester) async {
      await pumpBar(tester, 800, canGoPrev: false, canGoNext: false);
      for (final String key in <String>[
        'reader-control-prev',
        'reader-control-next',
      ]) {
        final IconButton button =
            tester.widget<IconButton>(find.byKey(Key(key)));
        expect(button.onPressed, isNull, reason: '$key 应为禁用态');
        expect(find.byKey(Key(key)), findsOneWidget,
            reason: '禁用不等于消失');
      }
    });

    testWidgets('单章书：滑条降禁用（无处可跳）', (WidgetTester tester) async {
      await pumpBar(tester, 800, chapterIndex: 0, chapterCount: 1);
      final MiSlider slider = tester
          .widget<MiSlider>(find.byKey(const Key('reader-control-progress')));
      expect(slider.onChanged, isNull);
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

    testWidgets('拖动滑条：浮出「章节名 · 进度」，松手收起并按章上抛',
        (WidgetTester tester) async {
      await pumpBar(tester, 393);
      expect(find.byKey(const Key('reader-chapter-preview')), findsNothing,
          reason: '静止态不显示预览气泡');

      final Rect slider =
          tester.getRect(find.byKey(const Key('reader-control-progress')));
      final TestGesture gesture =
          await tester.startGesture(slider.centerLeft + const Offset(8, 0));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();

      expect(find.byKey(const Key('reader-chapter-preview')), findsOneWidget,
          reason: '拖动中必须显示章节名与进度');
      expect(find.textContaining('· 21%'), findsOneWidget);
      expect(seeked, isNotEmpty, reason: '落点要按章上抛给宿主');
      for (final int index in seeked) {
        expect(index, inInclusiveRange(0, 1151));
      }

      await gesture.up();
      await tester.pump();
      expect(find.byKey(const Key('reader-chapter-preview')), findsNothing,
          reason: '松手后气泡收起');
    });

    testWidgets('盒高是覆盖层常量：系统 inset 另计，不吞正文',
        (WidgetTester tester) async {
      await pumpBar(tester, 393);
      final double plain =
          tester.getSize(find.byType(ReaderControlBar)).height;
      expect(plain, lessThanOrEqualTo(180));
      expect(plain, greaterThanOrEqualTo(72 + 8 + 56 + 24),
          reason: '盒高必须含胶囊 72 + 间隙 8 + 章节行 56 + 气泡预留 24');

      await pumpBar(tester, 393, bottomInset: 34);
      final double withInset =
          tester.getSize(find.byType(ReaderControlBar)).height;
      expect(withInset, moreOrLessEquals(plain + 34, epsilon: 0.5),
          reason: '系统手势条 inset 应计入盒高，胶囊仍让开它');
    });
  });
}
