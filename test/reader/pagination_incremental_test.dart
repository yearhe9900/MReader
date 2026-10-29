// 增量分页器契约测试（T02）：目标覆盖即上屏、预算让出、**部分页表前缀 ==
// 最终前缀**。期望值一律硬编码字面量。夹具同 `pagination_measure_test.dart`
// （等宽、字宽 18、行高 29.0、页 6 行 174.0、段首 2 缩进）：100 字段落 =
// 102 可见 → 11 行 → 恒切 2 页——页 2k = `[100k, 100k+58)` h=**174.0**、
// 页 2k+1 = `[100k+58, 100k+100)` h=**145.0**（跨段回拉到段末
// paragraphEnd，50 字窗口内，页高不含段距）。
// 全部用 `budget: Duration.zero` 驱动（step 零预算恰测 1 段），帧序列确定。
// 首屏线口径（统一方案 Phase 1 §6.3）：`initialReady` = 目标页覆盖（1 段 2 页
// 即就绪）；「5 页线」降为后台目标 `backgroundGoalReached`。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/incremental_paginator.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/pagination_cache.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  const TextStyle base = TextStyle(fontSize: 18, height: 1.6);
  const PaginationConfig config = PaginationConfig(
    pageWidth: 180,
    pageHeight: 200,
    textStyle: base,
  );

  /// 100 字段落（+2 缩进 → 11 行 → 2 页）。
  String para() => '0123456789' * 10;

  IncrementalPaginator jobOf(int paragraphCount, {int target = 0}) =>
      IncrementalPaginator(
        href: 'ch',
        paragraphs: List<String>.filled(paragraphCount, para()),
        config: config,
        targetCharOffset: target,
      );

  /// 页表 `(start, end)` 序列（前缀比较用）。
  List<(int, int)> bounds(List<PageSlice> pages) =>
      <(int, int)>[for (final PageSlice p in pages) (p.start, p.end)];

  group('step 切片语义', () {
    test('step(Duration.zero) 恰测 1 段：页表 2 页、任务未完成', () {
      final IncrementalPaginator job = jobOf(4);
      expect(job.measuredParagraphs, 0);
      expect(job.totalChars, 400);
      expect(job.pages.length, 1); // 构造占位空页 [0, 0)
      expect((job.pages.single.start, job.pages.single.end), (0, 0));

      expect(job.step(Duration.zero), isTrue); // 预算尽让出（未完成）
      expect(job.measuredParagraphs, 1);
      expect(job.isComplete, isFalse);
      expect(job.hasWork, isTrue);

      expect(job.pages.length, 2);
      expect(bounds(job.pages), <(int, int)>[(0, 58), (58, 100)]);
      expect(job.pages[0].height, 174.0);
      expect(job.pages[0].lineCount, 6);
      expect(job.pages[0].firstLine, 0);
      expect(job.pages[1].height, 145.0);
      expect(job.pages[1].lineCount, 5);
      expect(job.pages[1].firstLine, 6);
    });

    test('空章：构造即完成，1 个空页 [0,0)，step/prime 直通', () {
      final IncrementalPaginator job = IncrementalPaginator(
        href: 'e',
        paragraphs: const <String>[],
        config: config,
      );
      expect(job.isComplete, isTrue);
      expect(job.hasWork, isFalse);
      expect(job.totalChars, 0);
      expect(job.step(Duration.zero), isFalse);
      expect(job.prime(Duration.zero), isTrue); // 完成态恒真（先于预算检查）
      expect(job.initialReady, isTrue);
      expect(job.targetCovered, isTrue);
      expect(job.pages.length, 1);
      expect((job.pages.single.start, job.pages.single.end), (0, 0));
    });

    test('最后一段测完即定稿：4 段 → 8 页、step 返回 false', () {
      final IncrementalPaginator job = jobOf(4);
      expect(job.step(Duration.zero), isTrue);
      expect(job.step(Duration.zero), isTrue);
      expect(job.step(Duration.zero), isTrue);
      expect(job.step(Duration.zero), isFalse); // 末段完成 → 定稿
      expect(job.isComplete, isTrue);
      expect(job.hasWork, isFalse);
      expect(job.measuredParagraphs, 4);

      expect(bounds(job.pages), <(int, int)>[
        (0, 58),
        (58, 100),
        (100, 158),
        (158, 200),
        (200, 258),
        (258, 300),
        (300, 358),
        (358, 400),
      ]);
      expect(job.pages[6].height, 174.0);
      expect(job.pages[6].firstLine, 33);
      expect(job.pages[6].lineCount, 6);
      expect(job.pages[7].height, 145.0);
      expect(job.pages[7].firstLine, 39);
      expect(job.pages[7].lineCount, 5);
    });
  });

  group('首屏就绪（目标页覆盖即上屏）', () {
    test('initialReady 边界：1 段 2 页即就绪；5 页线只是后台目标', () {
      final IncrementalPaginator job = jobOf(8);
      expect(job.initialReady, isFalse); // 初始空页 [0,0) 不覆盖目标 0
      job.step(Duration.zero);
      expect(job.pages.length, 2);
      // 判别点（统一方案 Phase 1 §6.3）：2 页即就绪——「先 5 页」口径下此处
      // 必须 false（4 页 < 5）。
      expect(job.initialReady, isTrue);
      expect(job.backgroundGoalReached, isFalse); // 2 页 < 5
      job.step(Duration.zero);
      expect(job.backgroundGoalReached, isFalse); // 4 页 < 5
      job.step(Duration.zero);
      expect(job.pages.length, 6);
      expect(job.backgroundGoalReached, isTrue); // 6 ≥ 5
      expect(job.initialReady, isTrue);
    });

    test('目标页优先：target 450 时 initialReady 等到第 5 段（页尾 500 > 450）', () {
      final IncrementalPaginator job = jobOf(8, target: 450);
      job.step(Duration.zero);
      expect(job.targetCovered, isFalse); // 页尾 100
      job.step(Duration.zero);
      expect(job.targetCovered, isFalse); // 页尾 200
      job.step(Duration.zero);
      expect(job.pages.length, 6);
      expect(job.targetCovered, isFalse); // 页尾 300 ≤ 450
      // 页数已超旧 5 页线仍不就绪——钉「就绪只看目标覆盖，不看页数」。
      expect(job.initialReady, isFalse);
      job.step(Duration.zero);
      expect(job.targetCovered, isFalse); // 页尾 400
      job.step(Duration.zero);
      expect(job.targetCovered, isTrue); // 页尾 500 > 450
      expect(job.initialReady, isTrue);
    });

    test('prime(Duration.zero) 不测量直接 false（预算尽让出）', () {
      final IncrementalPaginator job = jobOf(8);
      expect(job.prime(Duration.zero), isFalse);
      expect(job.measuredParagraphs, 0);
      expect(job.isComplete, isFalse);
    });

    test('prime 已达标直通：目标覆盖后零预算也 true、不重复测量', () {
      final IncrementalPaginator job = jobOf(300);
      job.step(Duration.zero); // 恰测 1 段（确定性零预算）→ 2 页覆盖目标 0
      expect(job.pages.length, 2);
      expect(job.measuredParagraphs, 1);

      expect(job.prime(Duration.zero), isTrue); // 已可落位：零预算直通
      expect(job.measuredParagraphs, 1); // 直通不触发测量
      expect(job.isComplete, isFalse);
    });

    test('prime 大预算：达标即停、大章不被测完', () {
      final IncrementalPaginator job = jobOf(300);
      expect(job.prime(const Duration(seconds: 5)), isTrue);
      expect(job.initialReady, isTrue);
      expect(job.targetCovered, isTrue);
      // 达标即停：首个4ms 切片后目标已覆盖，不会推进完整章。
      expect(job.isComplete, isFalse);
      expect(job.measuredParagraphs, lessThan(300));
    });

    test('小章：prime 首屏预算内直接测完 → true + 定稿', () {
      final IncrementalPaginator job = jobOf(1);
      expect(job.prime(kFirstPaintBudget), isTrue);
      expect(job.isComplete, isTrue);
      expect(job.hasWork, isFalse);
      expect(job.pages.length, 2);
    });
  });

  group('页表前缀稳定性（部分 == 最终前缀）', () {
    test('逐步测量：每步页表前缀等于最终页表前缀（末页只许增长）', () {
      final IncrementalPaginator job = jobOf(4);
      final List<List<PageSlice>> partials = <List<PageSlice>>[];
      while (job.step(Duration.zero)) {
        partials.add(job.pages); // 每次重切为新列表（旧引用不被改写）
      }
      final List<PageSlice> finalPages = job.pages;
      expect(finalPages.length, 8);
      expect(partials.length, 3); // 第 4 步完成 → 循环体外
      expect([for (final List<PageSlice> p in partials) p.length],
          <int>[2, 4, 6]);
      expect(bounds(partials[0]), <(int, int)>[(0, 58), (58, 100)]);

      for (final List<PageSlice> partial in partials) {
        // 除末页外：边界 / 行下标逐项与最终前缀相等。
        for (int i = 0; i < partial.length - 1; i++) {
          expect(partial[i].start, finalPages[i].start, reason: '页 $i start');
          expect(partial[i].end, finalPages[i].end, reason: '页 $i end');
          expect(partial[i].firstLine, finalPages[i].firstLine,
              reason: '页 $i firstLine');
          expect(partial[i].lineCount, finalPages[i].lineCount,
              reason: '页 $i lineCount');
        }
        // 末页暂定：起点已定、只许增长（end 不回退）。
        final PageSlice last = partial.last;
        final PageSlice ref = finalPages[partial.length - 1];
        expect(last.start, ref.start);
        expect(last.end, lessThanOrEqualTo(ref.end));
      }
      // 本夹具逐段对齐：6 页部分表 == 最终前 6 页。
      expect(bounds(partials.last), bounds(finalPages.sublist(0, 6)));
    });

    test('snapshot 隔离：pages 不被后续测量改写、lines 共享只追加', () {
      final IncrementalPaginator job = jobOf(4);
      job.step(Duration.zero);
      final PaginatedChapter snap = job.snapshot();
      expect(snap.complete, isFalse); // 完成态是快照时点的拷贝
      expect(snap.pages.length, 2);
      expect(identical(snap.lines, job.lines), isTrue);
      expect(snap.lines.length, 11); // 100 字 + 2 缩进 = 11 行

      while (job.step(Duration.zero)) {}
      expect(job.pages.length, 8);
      expect(snap.pages.length, 2); // 旧快照页表未被改写
      expect(snap.complete, isFalse);
      expect(bounds(snap.pages), <(int, int)>[(0, 58), (58, 100)]);
      expect(snap.lines.length, 44); // 共享行表只追加（4 段 × 11 行）
      expect(snap.totalChars, 400);

      // 共享行表 + 下标不过期：快照页区间在增长后的行表上仍成立。
      for (final PageSlice p in snap.pages) {
        expect(snap.lines[p.firstLine].start, p.start);
        expect(snap.lines[p.firstLine + p.lineCount - 1].end, p.end);
      }
    });
  });

  group('targetCovered 边界', () {
    test('初始空页不覆盖任何目标（含 0）', () {
      final IncrementalPaginator job = jobOf(4); // target 0
      expect(job.targetCovered, isFalse);
      expect(job.pages.single.end, 0);
    });

    test('覆盖随页表推进翻转：target 150 → 第 2 段后页尾 200', () {
      final IncrementalPaginator job = jobOf(4, target: 150);
      job.step(Duration.zero);
      expect(job.targetCovered, isFalse); // 页尾 100 ≤ 150
      job.step(Duration.zero);
      expect(job.targetCovered, isTrue); // 页尾 200 > 150
    });

    test('完成后恒真（含越界目标）', () {
      final IncrementalPaginator job = jobOf(2, target: 99999);
      expect(job.targetCovered, isFalse);
      while (job.step(Duration.zero)) {}
      expect(job.isComplete, isTrue);
      expect(job.targetCovered, isTrue); // 完成态直接为真
      expect(job.initialReady, isTrue);
    });
  });

  group('调度常量（里程碑 §1 口径）', () {
    test('空闲帧预算 4~8ms 取中、后台目标 5 页、突发预算 16ms', () {
      expect(kIdleFrameBudget.inMilliseconds, 6); // 里程碑「4~8ms」取中
      expect(kFirstPaintBudget.inMilliseconds, 16);
      expect(kBackgroundPageGoal, 5); // 原「先 5 页」线，现为后台目标
      expect(kPrimeSlice.inMilliseconds, 4);
    });
  });
}
