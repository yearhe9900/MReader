// 换参 reprime 的两条契约（2026-10-22 真机两连报）：
//   A. 窗口不卡「载入中…」占位带（「快速缩小字体，视口里连着多条
//      『第 N 章 · 载入中…』不消失，读数停「1/1」」）；
//   B. 切字号不许闪动（「切换字体大小，会出现闪动」：先闪出一帧别处正文
//      再跳回来，录屏逐帧实测 f55 正确 → f56 另一段 → f57 回来，读数没变）。
//
// ## A 的根因
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
// ## A 的修法
//
// `_primeOpenSync` 收尾补上停稳流⑧的等价物：窗口全量登记 + 启动空闲帧链
// + 触发补齐。三者都幂等，开书 / 跳转 / 停稳路径重复调用无副作用。
//
// ## B 的根因（三个力叠在一起，都会让「换参后的第一次落位」落在别处）
//
//   ① **估算落位口径错**：页表覆盖不到目标时 `_primeOpenSync` 用
//      `章顶 + 章内比例 × cfg.pageHeight` 估——等于把整章当一页高。34 页的章
//      66% 处被落成 0.66 页（探针 `paged.estimate ... off=380`，真值 12480）。
//   ② **突发太短**：`kFirstPaintBudget` 16ms 在长章深位置只排到 ~40% ⇒ ①必被
//      触发（每次点字号都在打 `paged.estimate`）。
//   ③ **邻章塌成占位带**：换参把页表整体作废，已分页的邻章瞬间退化成
//      96dp 占位带 ⇒ 当前章章顶塌一整章高；补偿目标超出**旧布局**的
//      `maxScrollExtent` ⇒ `_jumpPaged` 推迟到帧末 ⇒ 中间那一帧显示错章正文
//      （探针 `paged.move why=views.late ... d=18330`）。连续换参时更糟：
//      上一轮已把邻章变成占位带，从视图读不到真章高，塌陷会再来一次。
//
// ## B 的修法
//
//   ① 估算改「按已测前缀的像素/字符密度外推」（扣标题占高，误差 ~22 页 → ≤1 页）；
//   ② reprime 单独用 `kReprimeBurstBudget`（48ms）——覆盖到目标就一次精确落位，
//      根本不进估算分支；
//   ③ 换参期间占位带**沿用上一次真实渲染的章高**（`_stickyChapterHeights`，
//      占位带自己也继承上一轮的值）⇒ 章顶不动，补偿只剩重排量、同帧预跳。
//
// 判据用 `PerfLog.records`（同 `test/diagnostics/open_trace_test.dart`）：
// 换参期间**不许出现 `paged.estimate`**（估算落位）与
// **不许出现 `.late`**（延迟补跳）——这两条正是「可见错帧」的留痕。
//
// 夹具 A：`FakeBookSource(paragraphCounts: [60 × 6])`——6 章全在补齐半径
// （`kEagerLoadRadius` 12）内、内容全驻留，窗口里的占位带只能来自
// 「分页缺席」而非「正文没来」；拖尾让窗口从 ±1 起步，reprime 的
// `_repairReachable` 再把它扩到超 ±1（与真机现场同构）。
//
// 夹具 B：`[400 × 4]` + 预写进度「第 3 章 66%」——当前章**有前置章**（换参后
// 最容易塌）且章内位置深（突发最容易覆盖不到），与录屏现场同构。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/diagnostics/perf_log.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_prefs_store.dart';
import 'package:mreader/reader/reading_progress.dart';

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

  group('换参 reprime 不许闪动（逐帧对拍「视口顶是哪段文字」）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late ReadingPrefsStore prefsStore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_flash_');
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
              paragraphCounts: const <int>[400, 400, 400, 400],
            ),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
            readingPrefsStore: prefsStore,
          ),
        );

    testWidgets('连点字号 −：逐帧视口顶仍是同一段文字（不许闪到别处再回来）',
        (WidgetTester tester) async {
      // 夹具现场 = 真机录屏同构：开书落在**第 3 章 66%**——当前章有前置章
      // （换参后前置章页表被作废，最容易塌成占位带）且章内位置深（首屏突发
      // 最容易覆盖不到目标、走估算落位）。
      await tester.runAsync(() => progressStore.save(ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h3',
            chapterIndex: 2,
            chapterPos: 0.66,
            updatedAt: 1,
          )));
      await tester.pumpWidget(buildApp());
      await settle(tester, rounds: 80);

      final PagedScrollerState st = tester.state<PagedScrollerState>(
          find.byType(PagedScroller, skipOffstage: false));
      final ScrollSample? ref = st.sampleNow();
      expect(ref, isNotNull, reason: '开书应落在第 3 章深处（真页表）');
      expect(ref!.href, 'h3');

      // 只看「点字号之后」的排版留痕（`PerfLog.records` 可断言，同
      // `test/diagnostics/open_trace_test.dart`）。
      PerfLog.records.clear();

      await showChrome(tester);
      for (int tap = 0; tap < 3; tap++) {
        await tester.tap(find.byKey(const Key('reader-setting-font-dec')));
        for (int f = 0; f < 4; f++) {
          await tester.pump();
        }
      }
      await settle(tester, rounds: 20);

      final List<String> moves = PerfLog.records
          .where((String r) => r.contains('paged.move'))
          .toList(growable: false);

      // ① 不许走「估算落位」：换参后页表覆盖不到目标 = 先跳到一个算出来的
      //    位置再收敛，真机表现就是闪出一帧别处正文（本夹具改前每次点字号
      //    都打 `paged.estimate ... off=380`，真值 12480）。
      expect(
        PerfLog.records.where((String r) => r.contains('paged.estimate')),
        isEmpty,
        reason: '换参落位必须一次精确（reprime 突发预算 kReprimeBurstBudget）——'
            '走估算就会先闪到别处再跳回来',
      );

      // ② 不许有「延迟补跳」（`why=xxx.late`）：那是 offset 超出**旧布局**
      //    滚动域、跳转推迟到帧末的留痕——中间那一帧正是用户看到的错章正文。
      //    改前实测 `paged.move why=views.late ... d=18330`。
      expect(
        moves.where((String m) => m.contains('.late')),
        isEmpty,
        reason: '换参期间的位移必须同帧预跳（预跳与换视图同帧上屏，看不见）；'
            '出现 late 就是闪了一帧',
      );

      // ③ 收尾仍停在原处（位置没被闪动带走）。
      final ScrollSample? end = st.sampleNow();
      expect(end, isNotNull);
      expect(end!.href, ref.href, reason: '切完字号不许换章');
      expect((end.charOffset - ref.charOffset).abs(), lessThanOrEqualTo(64),
          reason: '切完字号章内位置不许漂（容差 ≈ 一道行）');
      // ④ 正文卷里不许出现占位带（切字号顺带把邻章排空）。
      expect(
        find.descendant(
          of: find.byType(PagedScroller, skipOffstage: false),
          matching: find.textContaining('载入中'),
        ),
        findsNothing,
      );

      await closeBook(tester);
    });
  });
}
