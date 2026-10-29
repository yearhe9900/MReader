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
import 'package:mreader/reader/selection_overlay.dart';

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

    test('连续渲染口径：章高 == 标题 + Σ行高 + Σ跨段间距（页边界不产生缝合）', () {
      // **这是「滚动模式改连续渲染」的前提**：只有整章连续铺开的自然高与
      // `PagedLayout` 的章高（= Σ页高 + Σ跨页间距）**逐像素相等**，
      // `Positioned(top/height)`、`offsetFor`、`sampleNow` 才都不用动。
      // 夹具恰好覆盖两种页边界：`p0→p1` / `p2→p3` 是**段中续页**（补 0），
      // `p1→p2` 是**跨段**（补一次段间距 8）。
      const double spacing = 8;
      double continuousHeight(PagedChapterView v) {
        double h = v.headingHeight; // 标题占位（连续渲染里也照占）
        for (int i = 0; i < v.lines.length; i++) {
          if (i > 0 &&
              v.lines[i].paragraphIndex != v.lines[i - 1].paragraphIndex) {
            h += spacing;
          }
          h += v.lines[i].height;
        }
        return h;
      }

      final PagedLayout layout = PagedLayout.build(
        <PagedChapterView>[viewA(), viewB()],
        paragraphSpacing: spacing,
      );
      expect(
        continuousHeight(viewA()),
        layout.chapterTops[1] - layout.chapterTops[0],
        reason: '章 a 连续高应等于布局章高',
      );
      expect(
        continuousHeight(viewB()),
        layout.totalHeight - layout.chapterTops[1],
        reason: '章 b 连续高应等于布局章高',
      );
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

    /// 章内连续坐标：第 [k] 行的**行顶**（相对章内容起点，含标题占位）。
    ///
    /// 完全由 `lines`（测量产物）+ 段间距推出，**不经过 `PagedLayout`**——用来
    /// 交叉验证「页窗口的裁切边界是否恰好落在行边界上」。`lines` 是章内连续
    /// 无空档的行序，故第 k 行之前要补的是「跨段处一次段间距」（与
    /// `PageBreaker._heightOf` / 渲染侧 `SizedBox` 同口径）。
    double lineTopInChapter(List<MeasuredLine> lines, int k, double heading,
        double spacing) {
      double y = heading;
      for (int i = 0; i < k; i++) {
        if (i > 0 && lines[i].paragraphIndex != lines[i - 1].paragraphIndex) {
          y += spacing;
        }
        y += lines[i].height;
      }
      if (k > 0 && lines[k].paragraphIndex != lines[k - 1].paragraphIndex) {
        y += spacing;
      }
      return y;
    }

    testWidgets('连续铺开：页窗口恰为 [首行行顶, 末行行底]（滚动不切行、不留缝）',
        (WidgetTester tester) async {
      // 「**滚动时内容连续**」的正面证明：滚动模式是逐页 `PageContent` + `ClipRect`
      // 拼的，会不会切行取决于**裁切框的上下边是否恰好落在首行行顶 / 末行行底**。
      // 这里在真实渲染树里量 `PageContent` 矩形的上下边，与「只由测量行表推出的
      // 连续坐标」对拍——不经过布局表。
      // 覆盖三种落点：0（页 0 顶）、132 / 439（**非行对齐**的自由滚动位）、
      // 972（末端 clamp）。439 尤关键：视口顶落在页 2 内 72px = 2×29 + 14
      // 即**行中间**——正是这种非行对齐偏移会把首行切掉一半。
      final List<PagedChapterView> chs = <PagedChapterView>[viewA(), viewB()];
      await tester.pumpWidget(host(chs));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      for (final double target in <double>[0, 132, 439, 972]) {
        state.scrollController.jumpTo(target);
        await tester.pump();
        expect(state.offset, target);

        final VisibleRange range =
            state.layout.visibleRange(target, 400, config.pageHeight);
        final List<Rect> rects = <Rect>[];
        final List<int> owners = <int>[];
        for (int i = range.first; i <= range.last; i++) {
          final FlatPage e = state.layout.flatPages[i];
          final PagedChapterView chapter = chs[e.chapterIndex];
          final PageSlice page = chapter.pages[e.pageIndex];
          if (page.lineCount == 0) continue;
          final Rect r =
              tester.getRect(pageOf(chapter.paragraphs, e.pageIndex));
          final double chTop = state.layout.chapterTops[e.chapterIndex];
          final int last = page.firstLine + page.lineCount - 1;
          final double pageTop = lineTopInChapter(
              chapter.lines, page.firstLine, chapter.headingHeight, 8);
          final double pageBottom = lineTopInChapter(
                  chapter.lines, last, chapter.headingHeight, 8) +
              chapter.lines[last].height;

          // 上边 = 首行行顶、下边 = 末行行底 ⇒ 裁切框**不含任何半行**。
          expect(r.top + target, chTop + pageTop,
              reason: '章${chapter.href}页${e.pageIndex}@$target：上边未落在首行行顶');
          expect(r.bottom + target, chTop + pageBottom,
              reason: '章${chapter.href}页${e.pageIndex}@$target：下边未落在末行行底');
          rects.add(r);
          owners.add(e.chapterIndex);
        }

        final List<int> order = List<int>.generate(rects.length, (int i) => i)
          ..sort((int a, int b) => rects[a].top.compareTo(rects[b].top));
        for (int i = 1; i < order.length; i++) {
          final double gap =
              rects[order[i]].top - rects[order[i - 1]].bottom;
          // 同章：0（同段续页）或 8（跨段间距）；跨章：下一章的标题占位。
          final bool sameChapter = owners[order[i]] == owners[order[i - 1]];
          final double expected =
              sameChapter ? -1 : chs[owners[order[i]]].headingHeight;
          expect(sameChapter ? (gap == 0.0 || gap == 8.0) : gap == expected,
              isTrue,
              reason: sameChapter
                  ? '同章页间只允许 0 或 8，实测 $gap'
                  : '跨章页间应为标题占位 $expected，实测 $gap');
        }
        // 视口 [target, target+400]（布局坐标）全程被覆盖：页窗口 + 章标题占位。
        final double firstTop = rects[order.first].top + target;
        final double lastBottom = rects[order.last].bottom + target;
        expect(
            firstTop <= target ||
                firstTop - chs[owners[order.first]].headingHeight <= target,
            isTrue,
            reason: '@$target 视口顶未被页窗口或章标题占位覆盖（页顶 $firstTop）');
        expect(lastBottom, greaterThanOrEqualTo(target + 400),
            reason: '@$target 视口底未被页窗口覆盖（页底 $lastBottom）');
      }

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('段落渲染高 == Σ 测量行高（测量↔渲染无漂移 ⇒ 裁切框不切字）',
        (WidgetTester tester) async {
      // 上一条证明「裁切边界落在行边界」，这条证明「行边界本身两侧一致」：
      // 渲染出来的段落高度必须逐像素等于它的测量行高之和，否则页内末尾若干行
      // 会被裁掉（渲染比测量高）或留白（低）。
      //
      // 四支点（同宽 / 同样式缩进 / 同 textScaler / 同 strut）任一漂移都会在此判红。
      final List<PagedChapterView> chs = <PagedChapterView>[viewA(), viewB()];
      await tester.pumpWidget(host(chs));

      // 章 a 页 1 = 行 5..10，全部属段落 0 ⇒ 该页只渲染一个段落。
      final Finder para = find.descendant(
        of: pageOf(parasA, 1),
        matching: find.byKey(paragraphKey('a', 0)),
      );
      expect(para, findsOneWidget);
      final double measured = linesA
          .where((MeasuredLine l) => l.paragraphIndex == 0)
          .fold(0.0, (double a, MeasuredLine l) => a + l.height);
      expect(measured, 319.0); // 11 行 × 29（夹具实测行高）
      expect(tester.getSize(para).height, measured);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('页内容顶对齐：首段渲染顶 == 页框顶 − preHeight（禁 OverflowBox 居中）',
        (WidgetTester tester) async {
      // 上一条只证明「段落渲染高 == 测量行高」，**没证明段落在页框里的位置**
      // ——而位置才是「裁切窗顶边是否切在字中间」的决定因素。
      //
      // `PageContent` 的 `OverflowBox` 若不显式给 `alignment`，默认是
      // `Alignment.center` ⇒ 整块「完整段落」会在裁切框里**垂直居中**，偏移 =
      // (clipHeight − 内容高) / 2，既非行高整数倍、又随页内段数变化 ⇒ 页首行
      // 被裁掉一截、窗口还会落到相邻页正文上（真机症状：底部多出一行下半截）。
      //
      // 期望值硬编码（不引用生产常量，避免同义反复）：页框顶 {40,185,367,541}、
      // preHeight {0,145,0,174}（145 = 5×29、174 = 6×29，夹具行高 29）
      // ⇒ 首段渲染顶恒为 {40,40,367,367}。
      final List<PagedChapterView> chs = <PagedChapterView>[viewA(), viewB()];
      await tester.pumpWidget(host(chs));

      // 页 0/1 属段落 0，页 2/3 属段落 1（夹具：段 0 = 11 行、段 1 = 11 行）。
      const List<double> expectTop = <double>[40, 40, 367, 367];
      const List<int> paraOfPage = <int>[0, 0, 1, 1];
      for (int i = 0; i < 4; i++) {
        final Finder para = find.descendant(
          of: pageOf(parasA, i),
          matching: find.byKey(paragraphKey('a', paraOfPage[i])),
        );
        expect(para, findsOneWidget, reason: '页 $i 应渲染段落 ${paraOfPage[i]}');
        expect(
          tester.getTopLeft(para).dy,
          expectTop[i],
          reason: '页 $i：首段渲染顶必须等于「页框顶 − preHeight」。'
              '若为居中（偏移 (页框高 − 内容高)/2），此处会偏 −87 / −72.5。',
        );
      }

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('charOffset 落位', () {
    testWidgets('offsetForCharOffset 互查表 + 未覆盖 / 未知章返回 null',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      // 落位口径 = **行顶对齐**（契约变更：偏移 − 页顶恒为行高 29 的整数倍），
      // 故视口首行必是完整行。
      expect(state.offsetForCharOffset('a', 0), 40.0);
      expect(state.offsetForCharOffset('a', 100), 367.0); // 页 2 首行 → +0
      expect(state.offsetForCharOffset('a', 110), 396.0); // 页 2 第 2 行 → +29
      expect(state.offsetForCharOffset('a', 124), 425.0); // 页 2 第 3 行 → +58
      expect(state.offsetForCharOffset('a', 250), isNull); // 超出页表
      expect(state.offsetForCharOffset('zz', 0), isNull); // 不在窗口
      expect(state.offsetForCharOffset('b', 0), 726.0);
      expect(state.offsetForCharOffset('b', 100), 1053.0); // 页 2 首行 → +0

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

    testWidgets('行顶落位：charOffset 124 → offset 425，页顶上方 58 = 2×29（首行完整）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.jumpToCharOffset('a', 124), isTrue);
      await tester.pump();
      expect(state.offset, 425.0);
      final Finder target = pageOf(parasA, 2);
      expect(target, findsOneWidget);
      // 页顶被推到视口上方 58px = **整 2 行**（29×2）⇒ 视口首行是完整行；
      // 按页内比例折算会给 439（页顶上方 72 = 2×29 + 14）：首行被切掉 14px，
      // 即「字没显示全 / 文字丢失上一半」。
      final double pageTopDy = tester.getTopLeft(target).dy;
      expect(pageTopDy, -58.0);
      // 契约本身：视口顶必落在行边界上（页顶偏移是行高的整数倍）。
      expect(-pageTopDy % 29.0, 0.0);

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
      // 行表口径（§2.84）：视口顶 72 = 2×29+14 落在 L13 [118,128) → 取行首 118。
      expect(s.charOffset, 118);
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
      // 行表口径（§2.84）：停手 467 → 页内 100 落在 L14 [128,138) → 行首 128。
      expect(samples.last.charOffset, 128);
      await tester.pump(const Duration(milliseconds: 300));
      expect(samples, hasLength(2));

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('采样↔落位往返（§2.84：重复开关书不再漂移）', () {
    // 行表事实（探针实跑回填）：P2 [100,158) 六行行首 100/108/118/128/138/148、
    // P3 [158,200) 五行行首 158/168/178/188/198，行高一律 29；页顶 367/541。
    // **采样（像素→字符）与落位（字符→像素）必须共用同一行表口径**（§2.84），
    // 否则「采样→落位→采样」不为不动点，每次重开书误差复利、内容逐次漂移。
    testWidgets('往返幂等：439 采样→落位→重采 charOffset 不复利',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      state.scrollController.jumpTo(439); // P2 行中（页内 72 = 2×29 + 14）
      final ScrollSample? s1 = state.sampleNow();
      expect(state.jumpToCharOffset('a', s1!.charOffset), isTrue);
      await tester.pump();
      expect(state.offset, 425.0); // 落位仍行顶（367+58，§2.70 不破）
      final ScrollSample? s2 = state.sampleNow();
      // 目标断言（不动点）：落位后重采必须原样（均匀折算会复利、重开书逐次漂移）。
      expect(s2!.charOffset, s1.charOffset);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('落位后重采不跨行：168（L18 行首）重采仍 168，不漂回 L17',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      expect(state.jumpToCharOffset('a', 168), isTrue);
      await tester.pump();
      expect(state.offset, 570.0); // 541+29：L18 行顶（§2.70 行顶落位不破）
      final ScrollSample? s = state.sampleNow();
      // 目标断言：行首字符落位后重采 = 同行行首（避免跨行回退、重开书内容少一行）。
      expect(s!.charOffset, 168);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('行中采样取行首：584（L18 行中）→ 168（L18 行首）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      state.scrollController.jumpTo(584); // 541+29+14：L18 行中
      final ScrollSample? s = state.sampleNow();
      // 目标断言（行表口径）：视口顶落在行内何处，采样都取**该行行首**。
      expect(s!.charOffset, 168);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('三连环不累积：168 → 168 → 168（改前 168→166→158 每轮回退）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(<PagedChapterView>[viewA(), viewB()]));
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      // 模拟连续三轮「重开书」：落位（offsetFor）→ postFrame 采样写回。
      final List<int> traj = <int>[168];
      for (int i = 0; i < 2; i++) {
        expect(state.jumpToCharOffset('a', traj.last), isTrue);
        await tester.pump();
        traj.add(state.sampleNow()!.charOffset);
      }
      // 目标断言（误差不复利）：轨迹必须水平。
      expect(traj, <int>[168, 168, 168]);

      await tester.pumpWidget(const SizedBox());
    });

    // 合成「页内跨段」章（手搭行表/页表，不依赖文本测量）：3 段 × 3 行 ×
    // 10 字、行高一律 29、段间距 8。P0 跨段（行块 L2=[58,87)、段间距
    // [87,95)、L3=[95,124)…，高 182 = 6×29+8）、P1 三行（高 87）；
    // 标题 40、P0 顶 40、跨页段间距 8、P1 顶 230、总高 317。
    // parasA 的页内恰无段间距，跨段累加路径只有本夹具覆盖（真书多段页
    // 才是漂移主现场）。
    PagedChapterView viewC() {
      final List<MeasuredLine> lines = List<MeasuredLine>.generate(
        9,
        (int i) => MeasuredLine(
          start: i * 10,
          end: i * 10 + 10,
          height: 29,
          paragraphIndex: i ~/ 3,
          quality: LineBreakQuality.strong,
        ),
      );
      return PagedChapterView(
        href: 'c',
        paragraphs: <String>['0123456789' * 3, 'abcdefghij' * 3, 'zzzzzzzzzz' * 3],
        lines: lines,
        pages: const <PageSlice>[
          PageSlice(
              index: 0,
              start: 0,
              end: 60,
              height: 182,
              firstLine: 0,
              lineCount: 6),
          PageSlice(
              index: 1,
              start: 60,
              end: 90,
              height: 87,
              firstLine: 6,
              lineCount: 3),
        ],
        headingHeight: 40,
        heading: const Text('章 c'),
      );
    }

    // 视口 180×150：总高 317 ⇒ maxScrollExtent 167（行顶 135 等可直达）。
    Widget hostC() => MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 180,
              height: 150,
              child: PagedScroller(
                chapters: <PagedChapterView>[viewC()],
                config: config,
                resolveImage: resolve,
              ),
            ),
          ),
        );

    testWidgets('跨段行顶不动点：30 → 135（含页内段间距 8）→ 重采仍 30',
        (WidgetTester tester) async {
      await tester.pumpWidget(hostC());
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      // 落位：L3 行顶 = 40 + (3×29 + 8) = 135——段间距漏算会给 127（=L3
      // 被切进视口 8px 处），重蹈 §2.70「字没显示全」。
      expect(state.offsetForCharOffset('c', 30), 135.0);
      expect(state.jumpToCharOffset('c', 30), isTrue);
      await tester.pump();
      expect(state.offset, 135.0);
      // 不动点：行顶重采 = 同行行首。
      expect(state.sampleNow()!.charOffset, 30);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('段间距归下一行：127（段间距顶）/150（L3 行中）→ 均取 30',
        (WidgetTester tester) async {
      await tester.pumpWidget(hostC());
      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));

      // 段间距空白 [127,135) 归**下一行**块顶：视口顶在此 ⇒ 从 L3 读起。
      state.scrollController.jumpTo(127);
      expect(state.sampleNow()!.charOffset, 30);
      // L3 行中取行首。
      state.scrollController.jumpTo(150);
      expect(state.sampleNow()!.charOffset, 30);
      // L3 尾段（页内 118 ∈ [116,124)）：段间距若漏算，L3 块顶少 8px，
      // 此处会被误判进 L4（40）——跨段累加的单轴出界探针。
      state.scrollController.jumpTo(158);
      expect(state.sampleNow()!.charOffset, 30);

      // 三连环：30 → 30 → 30（误差不复利）。
      final List<int> traj = <int>[30];
      for (int i = 0; i < 2; i++) {
        expect(state.jumpToCharOffset('c', traj.last), isTrue);
        await tester.pump();
        traj.add(state.sampleNow()!.charOffset);
      }
      expect(traj, <int>[30, 30, 30]);

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
