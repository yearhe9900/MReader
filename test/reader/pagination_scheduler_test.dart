// 分页调度器契约测试（T02）：目标页优先 + ±1 章窗口预分页、帧驱动
// 「当前章优先 / 一帧一片」、换章换参作废、缓存命中直通。
// 期望值一律硬编码字面量。夹具同 `pagination_measure_test.dart`（等宽、
// 字宽 18、行高 29.0、页 6 行 174.0）：100 字段落恒切 2 页，4 段章 = 8 页。
// 全部用 `budget: Duration.zero` 驱动（prime 零预算不测量、step 零预算
// 恰测 1 段），帧序列完全确定，不依赖机器速度。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/incremental_paginator.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/pagination_cache.dart';
import 'package:mreader/reader/pagination/pagination_scheduler.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  const TextStyle base = TextStyle(fontSize: 18, height: 1.6);
  const PaginationConfig cfg = PaginationConfig(
    pageWidth: 180,
    pageHeight: 200,
    textStyle: base,
  );
  const PaginationConfig cfg2 = PaginationConfig(
    pageWidth: 180,
    pageHeight: 300, // 换参数（配置哈希失效的调度层一半）
    textStyle: base,
  );

  /// 100 字段落（→ 2 页）。
  String para() => '0123456789' * 10;

  List<String> paras(int n) => List<String>.filled(n, para());

  bool openA(
    PaginationScheduler s, {
    String href = 'a',
    int count = 4,
    PaginationConfig config = cfg,
    String? prevHref,
    int prevCount = 2,
    String? nextHref,
    int nextCount = 2,
  }) {
    return s.open(
      href: href,
      paragraphs: paras(count),
      config: config,
      budget: Duration.zero,
      prevHref: prevHref,
      prevParagraphs: prevHref == null ? null : paras(prevCount),
      nextHref: nextHref,
      nextParagraphs: nextHref == null ? null : paras(nextCount),
    );
  }

  group('空调度器基线', () {
    test('无任务：hasWork false、stepIdle false、currentPage null', () {
      final PaginationScheduler s = PaginationScheduler();
      expect(s.hasWork, isFalse);
      expect(s.stepIdle(budget: Duration.zero), isFalse);
      expect(s.currentPage, isNull);
      expect(s.active, isNull);
      expect(s.activeHref, isNull);
      expect(s.cache.count, 0);
    });

    test('setWindow 在 open 前无操作（无参数快照）', () {
      final PaginationScheduler s = PaginationScheduler();
      s.setWindow(nextHref: 'n', nextParagraphs: paras(2));
      expect(s.prefetchPending, 0);
    });
  });

  group('open：未就绪返回 false、缓存命中直通', () {
    test('零预算 open 新章：false + 任务挂起、页表为初始空页', () {
      final PaginationScheduler s = PaginationScheduler();
      expect(openA(s), isFalse);
      expect(s.active, isNotNull);
      expect(s.activeHref, 'a');
      expect(s.active!.measuredParagraphs, 0);
      expect(s.hasWork, isTrue);

      final PaginatedChapter? page = s.currentPage;
      expect(page, isNotNull);
      expect(page!.complete, isFalse);
      expect(page.pages.length, 1); // 初始占位空页
      expect(page.pages.single.end, 0);
    });

    test('缓存命中：再次 open 直接 true（零预算不进 prime）、不重建任务', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s); // 未就绪
      while (s.stepIdle(budget: Duration.zero)) {}
      expect(s.cache.count, 1); // a 定稿入缓存

      final bool ready = openA(s); // 零预算仍应命中直通
      expect(ready, isTrue);
      expect(s.active, isNull);
      expect(s.cache.count, 1); // 不重复入缓存
      expect(s.currentPage!.complete, isTrue);
      expect(s.currentPage!.pages.length, 8); // 4 段 = 8 页
    });

    test('同章重开：保留进度与任务实例（不清队列）', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, nextHref: 'n');
      expect(s.prefetchPending, 1);
      s.stepIdle(budget: Duration.zero); // a 测 1 段
      final IncrementalPaginator before = s.active!;

      // 1 段 2 页已覆盖目标 0 ⇒ 可落位（initialReady 放宽后返 true；
      // 「先 5 页」口径下此处是 false）。本用例的判据是**进度与实例保留**。
      expect(openA(s, nextHref: 'n'), isTrue);
      expect(identical(s.active, before), isTrue);
      expect(s.active!.measuredParagraphs, 1); // 进度不回退
      expect(s.prefetchPending, 1); // 旧队列保留且去重（仍 1 个）
    });
  });

  group('帧驱动：当前章优先、一帧一片、完成后轮转邻章', () {
    test('完整帧序列：a 4 帧 → p 2 帧 → n 2 帧，邻章在 a 完成前零推进', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, prevHref: 'p', nextHref: 'n');
      expect(s.prefetchPending, 2);
      expect(s.prefetchJobs[0].href, 'p'); // prev 先入队
      expect(s.prefetchJobs[1].href, 'n');

      // 帧 1~3：只推当前章，每帧恰 1 段；邻章零推进。
      for (int frame = 1; frame <= 3; frame++) {
        expect(s.stepIdle(budget: Duration.zero), isTrue, reason: '帧 $frame');
        expect(s.active!.measuredParagraphs, frame);
        expect(s.prefetchJobs[0].measuredParagraphs, 0, reason: '帧 $frame');
        expect(s.prefetchJobs[1].measuredParagraphs, 0, reason: '帧 $frame');
      }

      // 帧 4：a 第 4 段完成 → 定稿入缓存、让位（预分页仍 2 个）。
      expect(s.stepIdle(budget: Duration.zero), isTrue);
      expect(s.active, isNull);
      expect(s.cache.count, 1);
      expect(s.cache.hrefs.toList(), <String>['a']);
      expect(s.prefetchPending, 2);

      // 帧 5~6：队头 p（2 段）。
      expect(s.stepIdle(budget: Duration.zero), isTrue);
      expect(s.prefetchJobs[0].measuredParagraphs, 1);
      expect(s.prefetchJobs[1].measuredParagraphs, 0); // 一帧只给一个任务
      expect(s.stepIdle(budget: Duration.zero), isTrue); // p 完成 → 出队入缓存
      expect(s.prefetchPending, 1);
      expect(s.cache.count, 2);

      // 帧 7~8：n（2 段），第 8 帧收工。
      expect(s.stepIdle(budget: Duration.zero), isTrue);
      expect(s.prefetchJobs.single.measuredParagraphs, 1);
      expect(s.stepIdle(budget: Duration.zero), isFalse); // 全部完成
      expect(s.hasWork, isFalse);
      expect(s.cache.hrefs.toList(), <String>['a', 'p', 'n']);
      expect(s.stepIdle(budget: Duration.zero), isFalse); // 幂等
    });

    test('当前章未完成时不动邻章（延迟一切非目标章工作）', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, nextHref: 'n');
      s.stepIdle(budget: Duration.zero);
      s.stepIdle(budget: Duration.zero);
      expect(s.active!.measuredParagraphs, 2);
      expect(s.prefetchJobs.single.measuredParagraphs, 0);
      expect(s.cache.count, 0); // 还没有任何定稿
    });
  });

  group('换章 / 提拔 / 换参作废', () {
    test('换章：旧当前章部分任务丢弃（不入缓存）、旧 ±1 队列整体作废', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, prevHref: 'p', nextHref: 'n');
      s.stepIdle(budget: Duration.zero); // a 测 1 段（部分页表）
      expect(s.prefetchPending, 2);

      expect(openA(s, href: 'b', count: 2), isFalse);
      expect(s.activeHref, 'b');
      expect(s.active!.measuredParagraphs, 0); // 新任务
      expect(s.prefetchPending, 0); // 旧窗口作废（b 无窗口）
      expect(s.cache.count, 0); // a 的部分页表不留缓存
    });

    test('从预分页队列提拔：进度保留、旧队列作废', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, nextHref: 'n', nextCount: 2);
      // 恰 4 帧完成 a（零预算 = 每帧 1 段）；第 4 帧返回 true 因队列还有 n，
      // 但 n 一帧都没轮到（当前章优先）。
      for (int frame = 0; frame < 4; frame++) {
        expect(s.stepIdle(budget: Duration.zero), isTrue, reason: '帧 $frame');
      }
      expect(s.cache.count, 1);
      expect(s.prefetchJobs.single.measuredParagraphs, 0);

      expect(s.stepIdle(budget: Duration.zero), isTrue); // n 测 1 段
      expect(s.prefetchJobs.single.measuredParagraphs, 1);

      // 提拔 n：1 段 2 页已覆盖目标 0 ⇒ 可落位返 true（initialReady 放宽；
      // 「先 5 页」口径下此处是 false）。本用例判据是**进度保留 + 队列作废**。
      expect(openA(s, href: 'n', count: 2), isTrue);
      expect(s.activeHref, 'n');
      expect(s.active!.measuredParagraphs, 1); // 预分页进度保住
      expect(s.prefetchPending, 0); // 旧队列作废
      expect(s.cache.count, 1); // a 仍在缓存
    });

    test('换章时旧活动任务被丢弃：从队列提拔仅限目标章', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, nextHref: 'n');
      s.stepIdle(budget: Duration.zero); // a 部分
      expect(openA(s, href: 'n', count: 2), isFalse); // 提拔 n（进度 0）
      expect(s.activeHref, 'n');
      expect(s.active!.measuredParagraphs, 0);
      expect(s.prefetchPending, 0);
      expect(s.cache.count, 0); // a 部分页表被丢弃
    });

    test('换参：任务、队列、缓存整体作废，用新参数重建', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, config: cfg, nextHref: 'n');
      s.stepIdle(budget: Duration.zero); // a 部分 + 队列 1 个
      // 先让 n 完成入缓存，验证换参把缓存也清掉。
      openA(s, href: 'n', count: 2, config: cfg);
      while (s.stepIdle(budget: Duration.zero)) {}
      expect(s.cache.count, 1); // n 在缓存

      expect(openA(s, href: 'b', count: 2, config: cfg2), isFalse);
      expect(s.config, cfg2);
      expect(s.cache.count, 0); // 旧配置缓存整体清空
      expect(s.prefetchPending, 0);
      expect(s.activeHref, 'b');
      expect(s.active!.measuredParagraphs, 0); // 新任务从头开始
    });
  });

  group('setWindow 登记规则', () {
    test('登记 ±1、去重、跳过自己、跳过已缓存章', () {
      final PaginationScheduler s = PaginationScheduler();
      // 先把 n 走完入缓存。
      openA(s, href: 'n', count: 2);
      while (s.stepIdle(budget: Duration.zero)) {}
      expect(s.cache.count, 1);

      openA(s, href: 'a', count: 4); // 当前章 a（未完成）
      s.setWindow(
        prevHref: 'a',
        prevParagraphs: paras(2), // == 自己 → 跳过
        nextHref: 'n',
        nextParagraphs: paras(2), // 已缓存 → 跳过
      );
      expect(s.prefetchPending, 0);

      s.setWindow(prevHref: 'p', prevParagraphs: paras(2)); // 新章 → 登记
      expect(s.prefetchPending, 1);
      s.setWindow(prevHref: 'p', prevParagraphs: paras(2)); // 重复 → 去重
      expect(s.prefetchPending, 1);
      expect(s.prefetchJobs.single.href, 'p');
      expect(s.prefetchJobs.single.measuredParagraphs, 0);
    });

    test('open 自带窗口与后续 setWindow 合并去重', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, prevHref: 'p');
      expect(s.prefetchPending, 1);
      s.setWindow(prevHref: 'p', prevParagraphs: paras(2), nextHref: 'n',
          nextParagraphs: paras(2));
      expect(s.prefetchPending, 2); // p 去重、n 新增
      expect(s.prefetchJobs[0].href, 'p');
      expect(s.prefetchJobs[1].href, 'n');
    });
  });

  group('章标题高预留（headingHeight 穿透，里程碑 §2 决策）', () {
    test('open 的 headingHeight 裁页 0：首页 5 行、切点 48（基线 58）', () {
      final PaginationScheduler s = PaginationScheduler();
      expect(
        s.open(
          href: 'a',
          paragraphs: paras(1),
          config: cfg,
          headingHeight: 48, // 页 0 预算 200−48=152：5 行 145.0 ≤ 152、6 行 174 超
          budget: Duration.zero,
        ),
        isFalse,
      );
      expect(s.active!.headingHeight, 48);
      while (s.stepIdle(budget: Duration.zero)) {}

      final PaginatedChapter chapter = s.cache.get('a', cfg)!;
      expect(chapter.pages.length, 2);
      expect(chapter.pages[0].end, 48); // 5 行 = 50 可见 − 2 缩进
      expect(chapter.pages[0].lineCount, 5);
      expect(chapter.pages[0].height, 145.0);
      expect(chapter.pages[1].start, 48);
      expect(chapter.pages[1].end, 100); // 页 1 恢复整页高：6 行
      expect(chapter.pages[1].lineCount, 6);
    });

    test('prev/next headingHeight 穿透到 ±1 预分页任务；setWindow 同', () {
      final PaginationScheduler s = PaginationScheduler();
      s.open(
        href: 'a',
        paragraphs: paras(4),
        config: cfg,
        budget: Duration.zero,
        prevHref: 'p',
        prevParagraphs: paras(2),
        prevHeadingHeight: 36,
        nextHref: 'n',
        nextParagraphs: paras(2),
        nextHeadingHeight: 72,
      );
      expect(s.prefetchJobs[0].href, 'p');
      expect(s.prefetchJobs[0].headingHeight, 36);
      expect(s.prefetchJobs[1].href, 'n');
      expect(s.prefetchJobs[1].headingHeight, 72);

      // setWindow 换窗口登记，高度同样穿透。
      s.setWindow(
        nextHref: 'm',
        nextParagraphs: paras(2),
        nextHeadingHeight: 60,
      );
      expect(s.prefetchJobs.last.href, 'm');
      expect(s.prefetchJobs.last.headingHeight, 60);
    });

    test('同章重开 headingHeight 变化 → 丢弃旧任务重建（页 0 预算不同不可混用）', () {
      final PaginationScheduler s = PaginationScheduler();
      s.open(href: 'a', paragraphs: paras(4), config: cfg, budget: Duration.zero);
      s.stepIdle(budget: Duration.zero); // 测 1 段（部分进度）
      expect(s.active!.measuredParagraphs, 1);

      s.open(
        href: 'a',
        paragraphs: paras(4),
        config: cfg,
        headingHeight: 48,
        budget: Duration.zero,
      );
      expect(s.active!.headingHeight, 48);
      expect(s.active!.measuredParagraphs, 0); // 新任务，进度不带入
    });
  });

  group('动画期冻结（T04，保证 ③ 动画期零排版）', () {
    test('freeze 后 stepIdle 返 true 但零推进，unfreeze 后续排', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, prevHref: 'p', nextHref: 'n');
      expect(s.stepIdle(budget: Duration.zero), isTrue); // a 测 1 段
      expect(s.active!.measuredParagraphs, 1);

      s.freeze();
      expect(s.frozen, isTrue);
      for (int frame = 1; frame <= 3; frame++) {
        expect(s.stepIdle(budget: Duration.zero), isTrue,
            reason: '冻结帧 $frame：有活继续持帧');
        expect(s.active!.measuredParagraphs, 1, reason: '冻结帧 $frame 零推进');
        expect(s.prefetchJobs[0].measuredParagraphs, 0);
        expect(s.prefetchJobs[1].measuredParagraphs, 0);
        expect(s.cache.count, 0, reason: '冻结期无新定稿');
      }

      s.unfreeze();
      expect(s.frozen, isFalse);
      expect(s.stepIdle(budget: Duration.zero), isTrue);
      expect(s.active!.measuredParagraphs, 2, reason: '解冻后续排');
    });

    test('freeze/unfreeze 幂等；空调度器冻结期 stepIdle false', () {
      final PaginationScheduler s = PaginationScheduler();
      s.freeze();
      s.freeze();
      expect(s.frozen, isTrue);
      expect(s.stepIdle(budget: Duration.zero), isFalse, reason: '无活仍 false');
      s.unfreeze();
      s.unfreeze();
      expect(s.frozen, isFalse);
    });

    test('open 不受冻结影响：建任务、登记窗口、缓存命中直通照常', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'n', count: 2);
      while (s.stepIdle(budget: Duration.zero)) {}
      expect(s.cache.count, 1);

      s.freeze();
      // 冻结中开新章：prime 照常执行（未就绪 false、任务挂起、窗口登记）。
      expect(openA(s, href: 'a', count: 4, nextHref: 'm'), isFalse);
      expect(s.activeHref, 'a');
      expect(s.prefetchPending, 1, reason: '窗口登记不因冻结跳过');
      // 冻结期 stepIdle 不推进。
      expect(s.stepIdle(budget: Duration.zero), isTrue);
      expect(s.active!.measuredParagraphs, 0);
      // 缓存命中直通照常（换章到已定稿的 n）。
      expect(openA(s, href: 'n', count: 2), isTrue);
      expect(s.active, isNull);
      expect(s.cache.count, 1);
    });
  });

  group('图片真尺寸进测量（T05-b）', () {
    test('任务共享 imageSizes 引用：入表即对进行中任务可见', () {
      final PaginationScheduler s = PaginationScheduler();
      expect(s.imageSizes, isEmpty);

      openA(s, href: 'a', count: 4, prevHref: 'p', nextHref: 'n');
      expect(s.active!.imageSizes, same(s.imageSizes));
      expect(s.prefetchJobs[0].imageSizes, same(s.imageSizes));

      s.imageSizes['a.png'] = const Size(300, 150);
      expect(s.active!.imageSizes!['a.png'], const Size(300, 150));
    });

    test('真尺寸改变行高：宽图 fit 页宽 180 → 90（回退口径 48）', () {
      final PaginationScheduler s = PaginationScheduler();
      s.imageSizes['a.png'] = const Size(300, 150);

      s.open(
        href: 'img',
        paragraphs: <String>['\x00IMG:a.png\x00'],
        config: cfg,
        budget: Duration.zero,
      );
      expect(s.stepIdle(budget: Duration.zero), isFalse); // 单段章一轮测完
      final PaginatedChapter chapter = s.currentPage!;
      expect(chapter.complete, isTrue);
      // fit 180 宽 → 缩进 36px 挤不下，图换行：2 行（29.0 + 90.0），仍 1 页。
      expect(chapter.lines.length, 2);
      expect(chapter.lines[1].height, 90.0);
      expect(chapter.pageCount, 1);
    });

    test('invalidateForImageSizes：清任务/队列/缓存，保留 config 与定位', () {
      final PaginationScheduler s = PaginationScheduler();
      openA(s, href: 'a', count: 4, prevHref: 'p', nextHref: 'n');
      s.stepIdle(budget: Duration.zero); // 部分进度
      expect(s.active, isNotNull);
      expect(s.prefetchPending, 2);

      s.imageSizes['a.png'] = const Size(300, 150);
      s.invalidateForImageSizes();

      expect(s.active, isNull, reason: '进行中任务作废（行表不可信）');
      expect(s.prefetchPending, 0, reason: '预分页队列作废');
      expect(s.cache.count, 0, reason: '缓存页表整体换新');
      expect(s.activeHref, 'a', reason: '阅读定位保留');
      expect(s.config, cfg, reason: '排版参数保留');

      // 重开（上层带原 targetCharOffset）= 从零重建、共享新表。
      expect(openA(s, href: 'a', count: 4), isFalse);
      expect(s.active!.measuredParagraphs, 0);
      expect(s.active!.imageSizes, same(s.imageSizes));
    });
  });
}
