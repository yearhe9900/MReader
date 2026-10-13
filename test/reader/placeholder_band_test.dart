// 未分页占位块契约（2026-10-08，真机「章节间有大段空白 / 滚动时跳动」）。
//
// 两条被钉死的行为：
//   ① 占位块高 = **章标题占高 + 一行正文 + 24**，不再是整页高。
//      改前 `_buildPageViews` 给未分页章 `headingHeight: cfg.pageHeight` ⇒
//      滚动长卷里每个待排章先占**一整屏**空白（探针实测 572dp），用户看到
//      「上一章正文 → 一整屏空白 → 下一章正文」。
//   ② 占位块→真实章的合入**不许移动视口**（占位 1 屏 → 真实 5 屏，约 4.8 倍
//      高度突变）。改前实测视口从 5454 掉到 4882（Δ = 572 = 一整屏）——
//      这正是「滚动时跳动」的量级。
//
// 夹具：`FakeBookSource(paragraphCounts: [60,60,60])`，第 3 章用闸门挂住内容
// ⇒ 它必然停在占位块（可稳定观察）。视口 800×572（800×600 − 28dp 指示条让位）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_prefs_store.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('未分页占位块（paged）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late ReadingPrefsStore prefsStore;
    late Completer<void> gate;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_ph_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      prefsStore = ReadingPrefsStore(paths);
      gate = Completer<void>();
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// 宿主：第 3 章内容被闸门挂住（永不完成 ⇒ 永远是占位块）。
    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(
              paragraphCounts: const <int>[60, 60, 60],
              gates: <int, Completer<void>>{2: gate},
            ),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
            readingPrefsStore: prefsStore,
          ),
        );

    PagedScroller scroller(WidgetTester tester) => tester.widget<PagedScroller>(
        find.byType(PagedScroller, skipOffstage: false));

    PagedScrollerState scrollerState(WidgetTester tester) =>
        tester.state<PagedScrollerState>(
            find.byType(PagedScroller, skipOffstage: false));

    testWidgets('占位块高 = 标题占高 + 一行 + 24（不再是整页高）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 拖到窗口尾 → 触发尾追加：第 3 章以占位块上屏（第 1/2 章已是真页表）。
      await tester.drag(
          find.byKey(const ValueKey<String>('reader-content-area')),
          const Offset(0, -6000));
      await settle(tester, rounds: 25);

      final PagedScroller sc = scroller(tester);
      final List<PagedChapterView> views = sc.chapters;
      expect(views.length, 3, reason: '窗口应已尾追加到第 3 章');
      expect(views[0].pages, isNotEmpty, reason: '第 1 章应是真页表');
      expect(views[1].pages, isNotEmpty, reason: '第 2 章应是真页表');
      expect(views[2].pages, isEmpty, reason: '第 3 章被闸门挂住 ⇒ 占位块');

      // ① 占位块高：改前 = `cfg.pageHeight`（572.0 = 整屏）。现 = 116.0
      //    （标题 60.0 + 正文一行 20×1.6 = 32 + 24 呼吸；默认字号 20，
      //    `TYP-01` 2026-10-13 起）。
      //    标题占高 60.0 = 文本 24 + `_kHeadingGapTop` 24 + `_kHeadingGapBottom` 12
      //    （章标题改版后留白链 19→36，`§2.82`）。
      expect(views[2].headingHeight, 116.0);
      expect(views[0].headingHeight, 60.0, reason: '真章标题占高仍是实测值');
      // 与「整页高」的对比断言：占位块必须**远小于**一页。
      expect(views[2].headingHeight, lessThan(sc.config.pageHeight / 2),
          reason: '占位块不许再占一整屏（改前 = ${572.0}，pageHeight=' 
              '${sc.config.pageHeight}）');
      expect(sc.config.pageHeight, 572.0);

      // ② 布局总高 = 两章真内容 + 一个占位块（不是三章整屏）。
      //    默认字号 20 的章几何：标题 60 + 内容 2864（页 0 = 11 段 512 +
      //    4×12 段 560 + 尾页 1 段 32 + 5×16 跨页段距）= 2924/章。
      final PagedLayout layout = scrollerState(tester).layout;
      expect(layout.chapterTops[2], 5848.0); // 2924 × 2 章
      expect(layout.totalHeight, 5964.0); // 5848.0 + 占位块 116.0
    });

    testWidgets('占位块→真实章合入不许移动视口（Δ ≤ 2dp）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 两次下拖才真正顶到滚动域下界（单次 drag 的位移会被手势/物理层截断，
      // 探针实测单次 −6000 只到 4885、再 −3000 才到 max）。
      final Finder area =
          find.byKey(const ValueKey<String>('reader-content-area'));
      await tester.drag(area, const Offset(0, -6000));
      await settle(tester, rounds: 25);
      await tester.drag(area, const Offset(0, -3000));
      await settle(tester, rounds: 25);

      final PagedScrollerState st = scrollerState(tester);
      final double before = st.offset;
      // 停稳在窗口尾：视口可见第 3 章的占位块。
      expect(before, greaterThan(0));
      expect(st.offset, greaterThan(st.maxScrollExtent - 4.0),
          reason: '必须真的顶到滚动域下界（否则测不到占位块→真实的合入）；'
              'allow 4dp：drag 惯性停在物理余量处（实测 4975.0 / max 4977.8）');

      // 放行第 3 章：占位块（116.0）→ 真实章（2924.0 = 标题 60 + 6 页 60 段）。
      gate.complete();
      await settle(tester, rounds: 40);

      final double after = scrollerState(tester).offset;
      // 断言主句放最前：修前实测 5454.0 → 4882.0（Δ = 572.0 = 一整屏），
      // 真机表现即「章节间有一大段空白，然后视口跳一下」。
      expect((after - before).abs(), lessThanOrEqualTo(2.0),
          reason: '占位→真实的高度合入必须零扰动（before=$before after=$after）');
      expect(scroller(tester).chapters[2].pages, isNotEmpty,
          reason: '第 3 章应已补齐为真页表（排除「什么都没发生」假绿）');

      await closeBook(tester);
    });
  });
}
