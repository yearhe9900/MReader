// 分页滚动容器（T05-c c2）契约：布局表 / 可见区间二分 / charOffset 落位 /
// 停手防抖采样。期望值一律硬编码（探针 `_probe_paged_scroller_test` 实跑回填）。
// 夹具同 `page_renderer_test`：fontSize 18 / height 1.6、pageWidth 180、
// pageHeight 200、段间距 8、headingHeight 40（页 0 预算 160）；两章各 2 段
// 100 字、内容同构。视口 180×400（`Align(topLeft)`）。
// 页表（A/B 同构）：lineCount 5/6/6/5、高 145/174/174/145、字符区间
// [0,48)/[48,100)/[100,158)/[158,200)；章内页顶 {40,185,367,541}、
// 章 b 顶 686、总高 1372、maxScrollExtent 972。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/page_renderer.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  const TextStyle base = TextStyle(fontSize: 18, height: 1.6);
  const PaginationConfig config = PaginationConfig(
    pageWidth: 180,
    pageHeight: 200,
    textStyle: base,
  );

  final List<String> parasA = <String>['0123456789' * 10, 'abcdefghij' * 10];
  final List<String> parasB = <String>['0123456789' * 10, 'abcdefghij' * 10];

  late List<MeasuredLine> linesA;
  late List<PageSlice> pagesA;
  late List<MeasuredLine> linesB;
  late List<PageSlice> pagesB;

  Future<Uint8List?> resolve(String _) async => null;

  setUp(() {
    linesA = PagePaginator.measureParagraphs(paragraphs: parasA, config: config);
    pagesA = PageBreaker.paginate(
      linesA,
      pageHeight: 200,
      paragraphSpacing: 8,
      firstPageHeight: 160,
    );
    linesB = PagePaginator.measureParagraphs(paragraphs: parasB, config: config);
    pagesB = PageBreaker.paginate(
      linesB,
      pageHeight: 200,
      paragraphSpacing: 8,
      firstPageHeight: 160,
    );
  });

  PagedChapterView viewA() => PagedChapterView(
        href: 'a',
        paragraphs: parasA,
        lines: linesA,
        pages: pagesA,
        headingHeight: 40,
        heading: const Text('章 a'),
      );

  PagedChapterView viewB() => PagedChapterView(
        href: 'b',
        paragraphs: parasB,
        lines: linesB,
        pages: pagesB,
        headingHeight: 40,
        heading: const Text('章 b'),
      );

  Widget host(List<PagedChapterView> chapters,
          {void Function(ScrollSample sample)? onSampled}) =>
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 180,
            height: 400,
            child: PagedScroller(
              chapters: chapters,
              config: config,
              resolveImage: resolve,
              onSampled: onSampled,
            ),
          ),
        ),
      );

  Finder pageOf(List<String> paragraphs, int pageIndex) =>
      find.byWidgetPredicate(
        (Widget w) =>
            w is PageContent &&
            identical(w.paragraphs, paragraphs) &&
            w.page.index == pageIndex,
      );

  group('布局表（纯函数）', () {
    test('页表与章内页顶：5/6/6/5 行、页顶 {40,185,367,541}、总高 1372', () {
      expect(
        pagesA.map((PageSlice p) => p.lineCount).toList(),
        <int>[5, 6, 6, 5],
      );
      expect(
        pagesA.map((PageSlice p) => p.height).toList(),
        <double>[145.0, 174.0, 174.0, 145.0],
      );
      expect(
        pagesA.map((PageSlice p) => '${p.start},${p.end}').toList(),
        <String>['0,48', '48,100', '100,158', '158,200'],
      );
      expect(
        pagesB.map((PageSlice p) => p.lineCount).toList(),
        <int>[5, 6, 6, 5],
      );

      final PagedLayout layout = PagedLayout.build(
        <PagedChapterView>[viewA(), viewB()],
        paragraphSpacing: 8,
      );
      expect(layout.chapterTops, <double>[0.0, 686.0]);
      expect(layout.pageTops[0], <double>[40.0, 185.0, 367.0, 541.0]);
      expect(layout.pageTops[1], <double>[726.0, 871.0, 1053.0, 1227.0]);
      expect(layout.totalHeight, 1372.0);
    });

    test('扁平序与跨页段间距：仅 p1→p2 补 8，章间不加', () {
      final PagedLayout layout = PagedLayout.build(
        <PagedChapterView>[viewA(), viewB()],
        paragraphSpacing: 8,
      );
      expect(layout.flatPages.length, 8);
      expect(
        layout.flatPages.map((FlatPage f) => f.height).toList(),
        <double>[145.0, 174.0, 174.0, 145.0, 145.0, 174.0, 174.0, 145.0],
      );
      expect(layout.chapterFlatStart, <int>[0, 4]);
      expect(layout.chapterFlatEnd, <int>[3, 7]);
      // 同段续页（p0→p1、p2→p3）不补；跨段（p1→p2）恰补一次 8。
      expect(layout.pageTops[0][1] - (layout.pageTops[0][0] + 145.0), 0.0);
      expect(layout.pageTops[0][2] - (layout.pageTops[0][1] + 174.0), 8.0);
      expect(layout.pageTops[0][3] - (layout.pageTops[0][2] + 174.0), 0.0);
      // 章间不加额外间距（标题占位已计入章 b 章顶）。
      expect(
        layout.chapterTops[1] - (layout.pageTops[0][3] + 145.0),
        0.0,
      );
    });

    test('可见区间二分：@0/@132/@439/@972 + 空表', () {
      final PagedLayout layout = PagedLayout.build(
        <PagedChapterView>[viewA(), viewB()],
        paragraphSpacing: 8,
      );
      expect(layout.visibleRange(0, 400, 200), const VisibleRange(0, 3));
      expect(layout.visibleRange(132, 400, 200), const VisibleRange(0, 4));
      expect(layout.visibleRange(439, 400, 200), const VisibleRange(1, 5));
      expect(layout.visibleRange(972, 400, 200), const VisibleRange(4, 7));

      final PagedLayout empty =
          PagedLayout.build(const <PagedChapterView>[], paragraphSpacing: 8);
      expect(empty.totalHeight, 0.0);
      expect(empty.visibleRange(0, 400, 200).isEmpty, isTrue);
      expect(empty.chapterAtOrBefore(0), -1);
    });
  });

  group('滚动容器上屏', () {
    testWidgets('首屏 4 页 + 章 a 标题在场、章 b 不在 + Clamping 惯性',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.offset, 0.0);
      expect(state.maxScrollExtent, 972.0);
      expect(find.byType(PageContent), findsNWidgets(4));
      expect(find.text('章 a'), findsOneWidget);
      expect(find.text('章 b'), findsNothing);
      final SingleChildScrollView sv =
          tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
      expect(sv.physics, isA<ClampingScrollPhysics>());

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('拖动推进可见区间：100 → 4 页；150 → 5 页 + 章 b 标题入场',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, -100));
      await tester.pump();
      expect(state.offset, 100.0);
      expect(find.byType(PageContent), findsNWidgets(4));
      await tester.pumpAndSettle();
      expect(state.offset, 100.0); // 无 fling（探针实证）
      expect(find.byType(PageContent), findsNWidgets(4));

      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, -50));
      await tester.pump();
      expect(state.offset, 150.0);
      expect(find.byType(PageContent), findsNWidgets(5));
      expect(find.text('章 b'), findsOneWidget);

      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('charOffset 落位', () {
    testWidgets('offsetForCharOffset 互查表 + 未覆盖 / 未知章返回 null',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.offsetForCharOffset('a', 0), 40.0);
      expect(state.offsetForCharOffset('a', 100), 367.0);
      expect(state.offsetForCharOffset('a', 124), 439.0);
      expect(state.offsetForCharOffset('a', 250), isNull); // 超出页表
      expect(state.offsetForCharOffset('zz', 0), isNull); // 不在窗口
      expect(state.offsetForCharOffset('b', 0), 726.0);
      expect(state.offsetForCharOffset('b', 100), 1053.0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('一次落位：charOffset 100 → offset 367，目标页顶 dy == 0',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      expect(state.offset, 0.0);

      expect(state.jumpToCharOffset('a', 100), isTrue);
      await tester.pump();
      expect(state.offset, 367.0);
      final Finder target = pageOf(parasA, 2);
      expect(target, findsOneWidget);
      expect(tester.getTopLeft(target).dy, 0.0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('分数落位：charOffset 124 → offset 439（页顶上方 72）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.jumpToCharOffset('a', 124), isTrue);
      await tester.pump();
      expect(state.offset, 439.0);
      final Finder target = pageOf(parasA, 2);
      expect(target, findsOneWidget);
      expect(tester.getTopLeft(target).dy, -72.0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('未覆盖 / 未知章不落位（false，偏移不动）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.jumpToCharOffset('a', 250), isFalse);
      expect(state.jumpToCharOffset('zz', 0), isFalse);
      await tester.pump();
      expect(state.offset, 0.0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('clamp 上界：charOffset 100@b → 1053 收进 972，章 a 标题退场',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.jumpToCharOffset('b', 100), isTrue);
      await tester.pump();
      expect(state.offset, state.maxScrollExtent);
      expect(state.offset, 972.0);
      expect(find.byType(PageContent), findsNWidgets(4));
      expect(find.text('章 a'), findsNothing); // 可见区间 4..7，章 a 整体退场
      expect(find.text('章 b'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('停手防抖采样', () {
    testWidgets('sampleNow：视口顶所在页 / 标题区 → 页 0 页首',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      ScrollSample? s = state.sampleNow();
      expect(s, isNotNull);
      expect(s!.href, 'a');
      expect(s.pageIndex, 0);
      expect(s.charOffset, 0);
      expect(s.withinPageFraction, 0.0);

      state.scrollController.jumpTo(367);
      s = state.sampleNow();
      expect(s!.href, 'a');
      expect(s.pageIndex, 2);
      expect(s.charOffset, 100);
      expect(s.withinPageFraction, 0.0);

      state.scrollController.jumpTo(439);
      s = state.sampleNow();
      expect(s!.href, 'a');
      expect(s.pageIndex, 2);
      expect(s.charOffset, 124);
      expect(s.withinPageFraction, closeTo(0.414, 0.001));

      // 章 b 标题区（章顶 686、首页顶 726）→ 页 0 页首。
      state.scrollController.jumpTo(700);
      s = state.sampleNow();
      expect(s!.href, 'b');
      expect(s.pageIndex, 0);
      expect(s.charOffset, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('防抖时序：落位 t+200 采一次；拖动滚动期不采、停手后再采一次',
        (WidgetTester tester) async {
      final List<ScrollSample> samples = <ScrollSample>[];
      await tester.pumpWidget(host(
        <PagedChapterView>[viewA(), viewB()],
        onSampled: samples.add,
      ));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      // 落位：t+199 不采、t+200 恰采一次（页首 char=100）。
      expect(state.jumpToCharOffset('a', 100), isTrue);
      await tester.pump(const Duration(milliseconds: 199));
      expect(samples, hasLength(0));
      await tester.pump(const Duration(milliseconds: 1));
      expect(samples, hasLength(1));
      expect(samples.single.href, 'a');
      expect(samples.single.pageIndex, 2);
      expect(samples.single.charOffset, 100);
      expect(samples.single.withinPageFraction, 0.0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(samples, hasLength(1)); // 静默期不重复采

      // 拖动（offset 367 → 467）：滚动事件重置计时器，停手 200ms 后再采。
      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, -100));
      expect(samples, hasLength(1));
      await tester.pump(const Duration(milliseconds: 199));
      expect(samples, hasLength(1));
      await tester.pumpAndSettle();
      expect(samples, hasLength(2));
      expect(samples.last.href, 'a');
      expect(samples.last.pageIndex, 2);
      expect(samples.last.charOffset, 133);
      await tester.pump(const Duration(milliseconds: 300));
      expect(samples, hasLength(2));

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('窗口变更', () {
    testWidgets('章窗口收缩：布局重算 + 偏移收进上界（972 → 286）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      state.scrollController.jumpTo(972);
      await tester.pump();
      expect(state.offset, 972.0);

      await tester.pumpWidget(host(<PagedChapterView>[viewA()]));
      expect(state.layout.totalHeight, 686.0);
      expect(state.maxScrollExtent, 286.0);
      expect(state.offset, 286.0);
      expect(find.byType(PageContent), findsNWidgets(4));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('空窗口：总高 0、采样与落位皆空操作', (WidgetTester tester) async {
      await tester.pumpWidget(host(const <PagedChapterView>[]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.maxScrollExtent, 0.0);
      expect(state.sampleNow(), isNull);
      expect(state.offsetForCharOffset('a', 0), isNull);
      expect(state.jumpToCharOffset('a', 0), isFalse);
      expect(find.byType(PageContent), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
