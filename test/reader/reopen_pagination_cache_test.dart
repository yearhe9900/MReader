// 修法③「冷缓存收口」红灯（路线 A §7③）：
// **开书重入不丢分页缓存**。
//
// 机制链③（开书闪动）：改前 `_open` 每次
// `PaginationScheduler()` 新建 ⇒ 分页结果缓存随阅读页 State 生死，重开书
// 冷缓存——目标章页表要重排，**首见**只有 prime 突发（`kFirstPaintBudget`
// 16ms）的 5 页估算落位（章头一带），二次精确落位要等空闲帧把全章排完，
// 这段「先估后跳」就是闪动链③的现场。
//
// 判据：关书重开后**首个非空采样**（`PagedScrollerState.sampleNow`）必须
// 已在目标语义坐标——暖缓存（定稿页表随书驻留）首见即完整页表、一次精确
// 落位；冷缓存首见是估算位（`chapterPos × pageHeight`，章头一带）。
//
// 夹具与「放行门闸=精确落位」用例同款：3000 段长章 + 进度 90%——prime 16ms
// 够不到 90% 处，必然经历「估算 → 空闲帧补完 → 二次精确」。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_progress.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// 一轮一轮推，捕获**首个**非空采样（`sampleNow` 在占位视图下恒 null，
/// 页表一上屏就非空——首个非空值就是「首见页表」下的落位现场）。
Future<ScrollSample?> firstSample(WidgetTester tester, {int maxRounds = 100}) async {
  for (int i = 0; i < maxRounds; i++) {
    if (find.byType(PagedScroller).evaluate().isNotEmpty) {
      final ScrollSample? sample = tester
          .state<PagedScrollerState>(find.byType(PagedScroller))
          .sampleNow();
      if (sample != null) return sample;
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump(const Duration(milliseconds: 8));
  }
  return null;
}

void main() {
  capTestTimeout(); // 30s 超时兜底 + 每用例清共享分页缓存（见 test_config.dart）。

  testWidgets('重开书不丢分页缓存：二次开书首见即精确落位（估算落位不复现）',
      (WidgetTester tester) async {
    final Directory tempDir =
        Directory.systemTemp.createTempSync('mreader_reopen_cache_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final TestAppPaths paths = TestAppPaths(tempDir);
    final ProgressStore progressStore = ProgressStore(paths);
    // 进度：第 1 章 90%。两次开书共用同一 ProgressStore / LibraryRepository
    // 实例（同书重开），书源夹具逐次新建（内容恒等：3000 段同文案）。
    await tester.runAsync(
      () => progressStore.save(
        ReadingProgress(
          bookId: 'testbook01',
          chapterHref: 'h1',
          chapterIndex: 0,
          chapterPos: 0.9,
          updatedAt: 1,
        ),
      ),
    );
    Widget host() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[3000]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          ),
        );
    int total = 0;
    for (int p = 1; p <= 3000; p++) {
      total += '第1章正文$p'.length;
    }
    final int targetChar = (0.9 * total).round();

    // ── 开书①（冷）：走完整的「估算 → 二次精确」，收尾把全章定稿入缓存 ──
    await tester.pumpWidget(host());
    final ScrollSample? first1 = await firstSample(tester);
    expect(first1, isNotNull, reason: '开书①应能采到样（页表已上屏）');
    expect(
      first1!.charOffset,
      isNot(inInclusiveRange(targetChar - 40, targetChar + 40)),
      reason: '前提：首见必须是估算落位（章头一带）——若首见即目标，'
          '说明 prime 突发已覆盖 90% 处，夹具失效（长章不够长）',
    );
    // 等二次精确落位收敛（顺带等全章定稿落缓存——缓存只存完整结果，
    // 收敛后多推 60 轮让 `stepIdle` 收尾；空闲链 `hasWork` 尽即自停）。
    // 轮数预算 120：收敛点 = 页表排到「目标 + 一屏」之后（可达性验收，
    // `§2.92`），实测 ~43 轮，但 `stepIdle` 切片粒度随机器负载浮动——
    // 预算只影响「等多久」，不影响判据（±40 字符精确坐标）。
    bool converged = false;
    for (int i = 0; i < 120 && !converged; i++) {
      final PagedScrollerState st =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      final ScrollSample? s = st.sampleNow();
      converged =
          s != null && (s.charOffset - targetChar).abs() <= 40;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 8)));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(converged, isTrue,
        reason: '开书①的二次精确落位应收敛到目标语义坐标');
    await settle(tester, rounds: 60);
    await closeBook(tester);

    // ── 开书②（重开）：分页缓存随书驻留 ⇒ 首见即完整页表、一次精确落位 ──
    await tester.pumpWidget(host());
    final ScrollSample? first2 = await firstSample(tester);
    expect(first2, isNotNull, reason: '开书②应能采到样（页表已上屏）');
    expect(
      first2!.charOffset,
      inInclusiveRange(targetChar - 40, targetChar + 40),
      reason: '重开书首见即精确落位：冷缓存（调度器随 State 新建）时首见是'
          '估算落位（章头一带，与目标差约两万字符），二次精确落位要等'
          '空闲帧把全章排完（开书闪动链③）',
    );

    await closeBook(tester);
  });
}
