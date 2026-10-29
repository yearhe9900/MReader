// 滚动模式「停手不许跳动」契约（真机症状：顶端行弹跳露全、每次滚动都跳）。
//
// ## 缺陷
//
// `PagedScrollerState.offsetFor` 的落位口径 = **页顶 + 目标行行顶**（`§2.70`，
// 为「开书/跳转后不从半行开始读」而设）。但 `_onPagedStopped` ⑤ 的
// `_ensurePagedActive()` **每次停手**都调 `_primeOpenSync(charOffset:
// _currentCharOffset())`，于是自由滚动的视口顶被反复吸附到行顶：
// 内容整块下移「该行已被滚过的余量」⇒ 顶端那行露全（实测每次停手位移恒定）。
//
// ## 修法（`_scrollRemainderOf`）
//
// `§2.71` 已定「视口顶落在行中间」是连续排版的固有形态、**不是缺陷**；语义上
// 「用户滚到哪就是哪」。故自然停手时把「行内像素余量」补回行顶 ⇒ 布局未变时
// 目标值与现场像素**恰好相等** ⇒ `_jumpPaged` 被 `|Δ| < 0.01` 挡掉，位移为 0。
// 程序化落位（开书恢复 / 跳章 / 跳书签 / 跳目录 / 搜索命中）保持**行顶对齐**。
//
// ## 本文件钉住两条
//
//   ① 自由滚动停手：**offset 零位移** + 页面矩形**零移动**（用户可见口径）；
//   ② 程序化落位（本文件用「开书恢复上次 pos」驱动）：**仍按行顶对齐**（`§2.70`）。
//
// 夹具沿用 `placeholder_band_test`：视口 800×600（页高 572 = 600 − 28 让位）、
// 字 18 / 行高 1.6 ⇒ 行高 28.8。拖拽一律用**裸手势**：`tester.drag` 会连带
// `pump`，停稳流程可能在读取「自由滚动落点」之前就跑完了（探针第一版就栽在这，
// 量出来的 delta 恒为 0 —— 假绿）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/diagnostics/perf_log.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/page_renderer.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_prefs_store.dart';
import 'package:mreader/reader/reading_progress.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout();

  late Directory tempDir;
  late TestAppPaths paths;
  late ProgressStore progressStore;
  late ReadingPrefsStore prefsStore;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mreader_stop_');
    paths = TestAppPaths(tempDir);
    progressStore = ProgressStore(paths);
    prefsStore = ReadingPrefsStore(paths);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget buildApp() => MaterialApp(
        home: ReaderPage(
          source: FakeBookSource(paragraphCounts: const <int>[60, 60, 60]),
          record: fakeRecord(),
          progressStore: progressStore,
          repository: fakeRepository(paths),
          readingPrefsStore: prefsStore,
        ),
      );

  Finder areaFinder() =>
      find.byKey(const ValueKey<String>('reader-content-area'));

  PagedScrollerState scrollerState(WidgetTester tester) =>
      tester.state<PagedScrollerState>(
          find.byType(PagedScroller, skipOffstage: false));

  /// 可见页的**屏幕纵坐标**（`章href#页序 → 全局 top`）。
  ///
  /// 这是用户看得见的口径：offset 相同但内容位置不同的情况下（例如布局表被
  /// 换掉），只有本表能把它照出来；反过来说，本表不变 ⇒ 用户眼里「没动」。
  Map<String, double> visiblePageTops(WidgetTester tester) {
    final Map<String, double> out = <String, double>{};
    for (final Element e
        in find.byType(PageContent, skipOffstage: false).evaluate()) {
      final PageContent w = e.widget as PageContent;
      final RenderBox box = e.renderObject! as RenderBox;
      out['${w.chapterHref}#${w.page.index}'] =
          box.localToGlobal(Offset.zero).dy;
    }
    return out;
  }

  /// 独立口径（**不经过** `PagedScrollerState.offsetFor`）：章内每一行的绝对行顶。
  ///
  /// 由 `PageSlice` 页顶 + 行表逐行累加推出，跨段处补 `paragraphSpacing`
  /// （与 `PageBreaker._heightOf` / 渲染侧 `SizedBox` 同口径）。用来判「某个
  /// 偏移是不是行顶」——`offsetFor` 自己算的不能拿来验证自己。
  /// 与 `paged_scroller_test.lineTopInChapter` 同一手法（那里是章内相对坐标）。
  List<double> lineTopsOf(PagedScrollerState st, String href) {
    final List<PagedChapterView> views = st.widget.chapters;
    final int c = views.indexWhere((PagedChapterView v) => v.href == href);
    if (c < 0) return const <double>[];
    final PagedChapterView chapter = views[c];
    final double spacing = st.widget.config.paragraphSpacing;
    final List<double> tops = <double>[];
    for (int p = 0; p < chapter.pages.length; p++) {
      final PageSlice page = chapter.pages[p];
      final int last = page.firstLine + page.lineCount - 1;
      double y = st.layout.pageTops[c][p];
      for (int i = page.firstLine; i <= last && i < chapter.lines.length; i++) {
        tops.add(y);
        y += chapter.lines[i].height;
        final int nx = i + 1;
        if (nx < chapter.lines.length &&
            chapter.lines[nx].paragraphIndex !=
                chapter.lines[i].paragraphIndex) {
          y += spacing;
        }
      }
    }
    return tops;
  }

  group('滚动模式停手稳定性', () {
    testWidgets('① 自由滚动停手零位移（offset 不变 + 页面矩形不移动）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      final PagedScrollerState st = scrollerState(tester);
      expect(st.offset, 60.0, reason: '开书落位基线（章标题占高 60：文本 24 + '
          'gapTop 24 + gapBottom 12，章标题改版后 §2.82）');

      // 连续四轮「慢滚 → 停」，每轮都必须零位移（真机症状是「每次滚动都跳」）。
      for (int round = 0; round < 4; round++) {
        final double before = st.offset;

        // 裸手势：把「自由滚动落点」卡在 `up()` 之前读出来。
        final TestGesture g =
            await tester.startGesture(tester.getCenter(areaFinder()));
        await g.moveBy(const Offset(0, -80));
        await tester.pump();
        await g.moveBy(const Offset(0, -57));
        await tester.pump();
        final double during = st.offset;
        final Map<String, double> topsDuring = visiblePageTops(tester);

        // **判别力自检**：现场必须**不在行顶**，否则「停手不跳」是句废话
        // （本来就没得跳）。
        final ScrollSample sample = st.sampleNow()!;
        final double? lineTop = st.offsetForCharOffset(sample.href, sample.charOffset);
        expect(lineTop, isNotNull);
        expect((lineTop! - during).abs(), greaterThan(1.0),
            reason: '第 $round 轮夹具必须让视口停在行中间（当前 offset=$during '
                '行顶=$lineTop），否则本用例测不出「吸附到行顶」这个缺陷');

        PerfLog.records.clear(); // 清在 `up()` 之前：停手流从 `up()` 那一刻起跑
        await g.up();
        await settle(tester, rounds: 25);

        // 主断言（用户可见口径放最前）：页面矩形一格都不许挪。
        expect(visiblePageTops(tester), topsDuring,
            reason: '第 $round 轮：停手不许移动正文（改前每次整块平移 12dp，'
                '顶端被切半的行突然露全 = 真机「弹跳」）');
        // offset 断言：锁定机制本身（页面矩形靠 setState 间接反映）。
        expect(st.offset, during,
            reason: '第 $round 轮：停手后 offset 必须与自由滚动落点一致'
                '（before=$before during=$during after=${st.offset}）');
        // 最直接的一条：**`_jumpPaged` 连跳都不该发起**（`|Δ| < 0.01` 挡掉）。
        // 这条同时说明 `paged.move` 是真机排查用的有效探针——它零出现即零位移。
        final List<String> moves = PerfLog.records
            .where((String r) => r.contains('paged.move'))
            .toList();
        expect(moves, isEmpty,
            reason: '第 $round 轮：停手流里不许出现任何程序化位移（改后应恒为空；'
                '改前会打出 why=prime d=-12.0）：$moves');
        expect(
            PerfLog.records.any((String r) => r.contains('paged.stop')),
            isTrue,
            reason: '第 $round 轮：停手流必须真的跑过（否则上面两条是假绿）');
      }

      await closeBook(tester);
    });

    testWidgets('② 程序化落位仍按行顶对齐（开书恢复上次 pos，`§2.70`）',
        (WidgetTester tester) async {
      // 预置进度：第 2 章章内 50% ⇒ charOffset 落在页中间、**行中间**。
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h2',
            chapterIndex: 1,
            chapterPos: 0.5,
            updatedAt: 1,
          ),
        ),
      );

      await tester.pumpWidget(buildApp());
      await settle(tester);

      final PagedScrollerState st = scrollerState(tester);
      final ScrollSample sample = st.sampleNow()!;
      expect(sample.href, 'h2', reason: '应恢复落在第 2 章');

      // 恢复的落位必须**恰好是某一行行顶**（独立口径算，不用 `offsetFor`）。
      final List<double> tops = lineTopsOf(st, 'h2');
      expect(tops, isNotEmpty, reason: '第 2 章应已有真页表');
      final double nearest =
          tops.reduce((double a, double b) => (a - st.offset).abs() <
                  (b - st.offset).abs()
              ? a
              : b);
      expect((nearest - st.offset).abs(), lessThan(0.01),
          reason: '开书恢复必须落在行顶（`§2.70`：从整行开始读，不切半行）；'
              'offset=${st.offset} 最近行顶=$nearest');
      // 断言不是「章首恰好对齐」混过去的：恢复点必须真的在章内深处。
      final double chapterTop = st.layout.chapterTops[1];
      expect(st.offset, greaterThan(chapterTop + 100.0),
          reason: '恢复点应在章内深处（章顶=$chapterTop offset=${st.offset}），'
              '否则本用例退化成「章首对齐」的弱断言');

      await closeBook(tester);
    });
  });
}
