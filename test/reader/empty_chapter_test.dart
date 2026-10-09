// 空段章契约（2026-10-09，真机《枭臣》「初次打开图书，章间卡着一条
// 『第 2 章 · 载入中…』不消失」）。
//
// ## 根因
//
// TOC 规则（legado `txtTocRule` 的 `正文(?!完|结)`）把孤行「正文」切成独立章，
// 正文区间只含空行 ⇒ `_splitParagraphs` 后 **0 段**。旧真身判据掺
// `paragraphList.isNotEmpty` ⇒ 空段章**永驻**占位分支——把「这一章没有正文」
// 错当成「正文还没来」；`_registerWindowUnpaginated` 又跳过空段章 ⇒ 永无分页
// 条目，占位块永远换不成真身（楔子真身在下方渲染出来了，占位带还卡在章间）。
//
// ## 修法（负责人拍板「可以只显示章节名」）
//
// 空段章走完分页管线拿**天生空页**（分页内核空章契约：`PageBreaker.paginate([])`
// 「每章至少一页」返回一页空页、`IncrementalPaginator` 空段构造即完成），
// 真身判据 = 「内容已就绪 + 页表已出」（**刻意不看段落数**）⇒ 空段章渲染
// **只有章标题**的真身块。签名 / 翻页零改动（空页使占位→真切换、翻页落页 0
// 显示章名都自然成立）。
//
// 夹具：`FakeBookSource(paragraphCounts: [60, 0, 60])`——第 2 章 0 段，与
// 《枭臣》孤行「正文」切出的空段章同构（`content` 非 null、段落表空）。
// 视口 800×600（页高 572 = 600 − 28 指示条让位），与 `placeholder_band_test` 同款。
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
  capTestTimeout();

  group('空段章只显章名（不卡「载入中…」）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late ReadingPrefsStore prefsStore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_empty_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      prefsStore = ReadingPrefsStore(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// 宿主：第 2 章 **0 段**（空段章），第 1/3 章正常 60 段。
    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[60, 0, 60]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
            readingPrefsStore: prefsStore,
          ),
        );

    PagedScroller scroller(WidgetTester tester) => tester.widget<PagedScroller>(
        find.byType(PagedScroller, skipOffstage: false));

    testWidgets('空段章拿天生空页、只显章名，不卡「载入中…」',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 拖到窗口尾 → 三章全入窗（同 `placeholder_band_test` 手法）。
      await tester.drag(
          find.byKey(const ValueKey<String>('reader-content-area')),
          const Offset(0, -6000));
      await settle(tester, rounds: 25);

      final PagedScroller sc = scroller(tester);
      final List<PagedChapterView> views = sc.chapters;
      expect(views.length, 3, reason: '窗口应已尾追加到第 3 章');
      expect(views[0].pages, isNotEmpty, reason: '第 1 章照常分页');
      expect(views[2].pages, isNotEmpty, reason: '第 3 章照常分页');

      // 空段章（第 2 章）：走完分页管线拿到**一页空页**（内核「每章至少一页」）。
      // 改前 `pages` 恒空（`_registerWindowUnpaginated` 跳过空段章 ⇒ 永无页表）
      // ⇒ 永驻占位分支。
      expect(views[1].paragraphs, isEmpty, reason: '空段章段落表为空');
      expect(views[1].lines, isEmpty, reason: '空页没有行');
      expect(views[1].pages, hasLength(1),
          reason: '空章契约：每章至少一页——空段章是一页空页的定稿章，'
              '不再是「正文还没来」');
      expect(views[1].heading, isA<Column>(),
          reason: '真身标题块（占位分支的 heading 是 Center「载入中」）');

      // 用户可见口径：章间不再卡「载入中…」占位带，章名照显（只显章名）。
      expect(
        find.descendant(
          of: find.byType(PagedScroller, skipOffstage: false),
          matching: find.textContaining('载入中'),
        ),
        findsNothing,
        reason: '空段章是「这一章没有正文」不是「正文还没来」——'
            '改前每次开书都在章间卡一条『第 2 章 · 载入中…』',
      );
      expect(find.text('第二章', skipOffstage: false), findsOneWidget,
          reason: '负责人拍板「可以只显示章节名」');

      await closeBook(tester);
    });

    testWidgets('窗口第 3 章的空段章拿天生空页（窗口登记路径，非 ±1 邻章）',
        (WidgetTester tester) async {
      // [60, 0, 0]：尾部连排两个空段章（夹具刻意为之）。拖动后 target 停在
      // 章 0 深处（-2500 实测 px=2540、prime index=0），views[2] **不是**
      // target ±1（= 0,1）⇒ `_primeOpenSync` 的 prev/next 路径覆盖不到它，
      // 页表只能来自 `_registerWindowUnpaginated`（窗口全量登记，空段章也
      // 登记——登记即秒完成入缓存）。这条用例把「窗口登记放行空段章」单独
      // 钉住：变异（登记时跳过空段章）后 views[2] 恒无页表 ⇒ 永驻占位。
      //
      // 章 1 也是空段（矮）⇒ 窗口 [0,1] 尾近，视口底越过窗口尾即触发尾追加
      // [0,1,2]（换正常高章则窗口尾远、尾追加不触发——第一版就栽在这）。
      final Widget app = MaterialApp(
        home: ReaderPage(
          source: FakeBookSource(paragraphCounts: const <int>[60, 0, 0]),
          record: fakeRecord(),
          progressStore: progressStore,
          repository: fakeRepository(paths),
          readingPrefsStore: prefsStore,
        ),
      );
      await tester.pumpWidget(app);
      await settle(tester);

      final Finder area =
          find.byKey(const ValueKey<String>('reader-content-area'));
      await tester.drag(area, const Offset(0, -2500));
      await settle(tester, rounds: 25);

      final List<PagedChapterView> views = scroller(tester).chapters;
      expect(views.length, 3, reason: '窗口应已尾追加到第 3 章');
      expect(views[0].pages, isNotEmpty, reason: '第 1 章照常分页');
      expect(views[1].pages, hasLength(1),
          reason: 'views[1] 是 target 的 next 邻章（±1 预分页覆盖），'
              '空段章同样拿一页空页——第一条用例的同款语义');

      // 空段章（index 2）：不在 target ±1 仍拿到天生空页。
      expect(views[2].paragraphs, isEmpty);
      expect(views[2].pages, hasLength(1),
          reason: '窗口登记放行空段章——登记即秒完成入缓存（一张空页）；'
              '改前登记跳过空段章 ⇒ 永无页表 ⇒ 永驻「载入中…」');
      expect(views[2].heading, isA<Column>());

      expect(
        find.descendant(
          of: find.byType(PagedScroller, skipOffstage: false),
          matching: find.textContaining('载入中'),
        ),
        findsNothing,
        reason: '空段章只显章名，不卡占位',
      );

      await closeBook(tester);
    });
  });
}
