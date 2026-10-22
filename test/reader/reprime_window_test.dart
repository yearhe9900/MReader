// 换参 reprime 后窗口不卡「载入中…」占位带（2026-10-22，真机
// 「快速缩小字体，会出现这个问题」：视口里连着多条『第 N 章 · 载入中…』
// 占位带不消失，底部读数停在「1/1」）。
//
// ## 根因
//
// 字号 / 行距 / 页边距变更走 LayoutBuilder 检出 cfg 变化 → `_requestReprime`
// → `_primeOpenSync` 重分页。这条路径有两个盲区：
//   ① `scheduler.open` 只登记当前 ±1，`_repairReachable` 扩窗追加的章
//      （占位带只 ≈96dp，锚点 + 视口高会逼着多 append 约 `ceil(vh/96)` 章）
//      与窗口内其余章**不登记就永无页表**——`_registerWindowUnpaginated`
//      此前只挂在停稳流⑧ / 尾追加 / 跳转三处，reprime 后没有等价物；
//   ② `_startPagedFrames` 也不在 reprime 路径上：`open` 的 prime 突发达
//      `initialReady`（「1 页即上屏」，统一方案 Phase 1 §6.3）即停，剩余
//      页表全靠 `stepIdle` 空闲帧链续排——帧链没起，当前章页表就冻结在
//      1 页（读数「1/1」），±1 的预分页任务更是没跑过。
// 换参 `open` 又会把缓存与预分页队列**全部作废**（`_acceptConfig`）⇒ 快速
// 连点字号 = 反复清盘、只补回 ±1，其余章永远停在占位带。
//
// 任何滚动停稳都会经停稳流⑧（`_ensureAutoFill` → 补齐循环每批
// `_registerWindowUnpaginated` + `_startPagedFrames`）自愈 ⇒ 此前只在
// 「改完字号不滚动」时暴露。
//
// ## 修法
//
// `_primeOpenSync` 收尾补上停稳流⑧的等价物：窗口全量登记 + 启动空闲帧链
// + 触发补齐。三者都幂等，开书 / 跳转 / 停稳路径重复调用无副作用。
//
// 夹具：`FakeBookSource(paragraphCounts: [60 × 6])`——6 章全在补齐半径
// （`kEagerLoadRadius` 12）内、内容全驻留，窗口里的占位带只能来自
// 「分页缺席」而非「正文没来」；拖尾让窗口从 ±1 起步，reprime 的
// `_repairReachable` 再把它扩到超 ±1（与真机现场同构）。
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

  group('换参 reprime 后窗口不卡占位带', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late ReadingPrefsStore prefsStore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_reprime_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      prefsStore = ReadingPrefsStore(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(
              paragraphCounts: const <int>[60, 60, 60, 60, 60, 60],
            ),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
            readingPrefsStore: prefsStore,
          ),
        );

    PagedScroller scroller(WidgetTester tester) => tester.widget<PagedScroller>(
        find.byType(PagedScroller, skipOffstage: false));

    testWidgets('快速缩小字体（连点字号 −）后占位带全部换真、不卡「载入中…」',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 拖到窗口尾 → 尾追加出超 ±1 的窗口（同 `placeholder_band_test` 手法）。
      final Finder area =
          find.byKey(const ValueKey<String>('reader-content-area'));
      await tester.drag(area, const Offset(0, -6000));
      await settle(tester, rounds: 25);

      // 前置：此刻窗口内全部真页表——「载入中…」只许是 reprime 之后出现的。
      final List<PagedChapterView> before = scroller(tester).chapters;
      expect(before.length, greaterThanOrEqualTo(3),
          reason: '拖尾后窗口至少 ±1 三章');
      for (final PagedChapterView v in before) {
        expect(v.pages, isNotEmpty, reason: '${v.href} 前置应是真页表');
      }

      // 快速缩小字体：连点 5 次「字号 −」（20 → 15），每步只 pump 一帧。
      await showChrome(tester);
      for (int i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const Key('reader-setting-font-dec')));
        await tester.pump();
      }
      await settle(tester, rounds: 40);

      // 数据口径：窗口内每章都必须有页表（`_viewportReal` 同源判据：
      // `pages` 非空 = 真身；空 = 占位带）。
      final List<PagedChapterView> after = scroller(tester).chapters;
      expect(after.length, greaterThanOrEqualTo(3));
      for (final PagedChapterView v in after) {
        expect(
          v.pages,
          isNotEmpty,
          reason: '${v.href} 卡在「载入中…」占位带——改前 reprime 只登记 ±1 '
              '且不起空闲帧链，换参清盘后窗口其余章永无页表（真机：快速缩小'
              '字体后视口里连着 5 条『第 N 章 · 载入中…』）',
        );
      }

      // 用户可见口径：正文卷里不许再挂占位文案。
      expect(
        find.descendant(
          of: find.byType(PagedScroller, skipOffstage: false),
          matching: find.textContaining('载入中'),
        ),
        findsNothing,
        reason: '改完字号不滚动也不该卡「载入中…」——滚动停稳自愈不算修好',
      );

      await closeBook(tester);
    });
  });
}
