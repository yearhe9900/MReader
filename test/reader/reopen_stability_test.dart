// 章尾反复开关书的稳定性回归（2026-10-09 真机「多次开关图书，章节跳动」）。
//
// ## 症状与根因（完整链条见 `docs/tech-usage.md` §2.80）
//
// 停在**章尾页**（读数 `第一章 2/2`）时关书 → 重开，读数会**每次向前漂一整章**
// （`第一章 → 第二章 → 第三章`），几次后才收敛。
//
// 链条：开书时窗口按「锚点可达」贪心向后 append，而**未排页表的章只贡献一条
// `_placeholderBandHeight`（≈96dp）占位带**，`layout.totalHeight` 因此几乎永远
// 够不到 `anchor + 视口高` ⇒ 窗口一路撑到全书 ⇒ 这些章全被登记进预分页队列 ⇒
// `kPaginationCacheChapters`（5）被挤爆 ⇒ **最先排完页表的当前章被 LRU 淘汰**
// （读路径 `_paginatedOf` 走只读 `peek`，不参与提位）⇒ 当前章视图静默退化为
// 占位带、锚点以上布局塌陷一整章高 ⇒ 同帧 `sampleNow` 把现场像素映射到**邻章**，
// 且 `_applyPagedSample(save: true)` 把它写进存档 ⇒ 下一次开书从错章开始。
//
// 判据是**端到端读数**：三次「关书 → 重开」后章标题与章内页位必须与关书前一致，
// 且第 2 / 第 3 轮读数**逐字相同**（不累积漂移）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// 25 段 × 一行 ≈ 1125px ⇒ 每章 2 页，第二页是「短尾页」（正是负责人说的「页尾」）。
const List<int> kCounts = <int>[25, 25, 25, 25, 25, 25];

void main() {
  capTestTimeout();

  testWidgets('章尾页反复关书 / 重开：章节与页位读数不漂移（变异即判红）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);

    final Directory tempDir =
        Directory.systemTemp.createTempSync('mreader_reopen_stability_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final TestAppPaths paths = TestAppPaths(tempDir);
    final ProgressStore store = ProgressStore(paths);

    Widget app() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(paragraphCounts: kCounts),
            record: fakeRecord(),
            progressStore: store,
            repository: fakeRepository(paths),
          ),
        );

    String readout() {
      final Finder f = find.byKey(const Key('reader-progress-chapter'));
      if (f.evaluate().isEmpty) return '<无读数>';
      return tester.widget<Text>(f).data ?? '';
    }

    String pageTail() {
      final Finder f = find.byKey(const Key('reader-progress-text'));
      if (f.evaluate().isEmpty) return '<无>';
      return tester.widget<Text>(f).data ?? '';
    }

    // ── 拖到第一章的最后一页（`2/2`）后停手 ────────────────────────────────
    await tester.pumpWidget(app());
    await settle(tester);
    expect(readout(), '第一章', reason: '新书应停在第一章');

    final Finder area =
        find.byKey(const ValueKey<String>('reader-content-area'));
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(area));
    bool reached = false;
    for (int step = 0; step < 40; step++) {
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      if (pageTail().startsWith('2/2')) {
        reached = true;
        break;
      }
    }
    await gesture.up();
    await settle(tester);
    expect(reached, isTrue, reason: '探针应能拖到章尾页（2/2）');
    expect(readout(), '第一章');
    expect(pageTail().startsWith('2/2'), isTrue);

    // ── 关书 → 重开 ×3：读数必须原地不动 ──────────────────────────────────
    final List<String> readings = <String>[];
    for (int round = 1; round <= 3; round++) {
      await closeBook(tester);
      await tester.pumpWidget(app());
      await settle(tester);
      readings.add('${readout()} ${pageTail()}');
    }

    for (int i = 0; i < readings.length; i++) {
      expect(
        readings[i].startsWith('第一章 2/2'),
        isTrue,
        reason: '第 ${i + 1} 次重开后章/页漂移了：$readings',
      );
    }
    // 第 2 / 3 轮逐字相同 ⇒ 位置本身不再累积漂移（第一轮允许 ±0.1pp 的
    // 行顶对齐回读差，见 `docs/tech-usage.md` §2.70）。
    expect(readings[1], readings[2], reason: '重开读数在累积漂移：$readings');

    await closeBook(tester);
  });
}
