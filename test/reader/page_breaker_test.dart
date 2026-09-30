// 分页切页内核单测（`T01`，纯逻辑 —— 不碰 Flutter 渲染）。
//
// 期望值一律**硬编码字面量**（引用被测常量 = 同义反复）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  MeasuredLine ln(
    int start,
    int end,
    double height, {
    int p = 0,
    LineBreakQuality q = LineBreakQuality.none,
  }) =>
      MeasuredLine(
        start: start,
        end: end,
        height: height,
        paragraphIndex: p,
        quality: q,
      );

  group('PageBreaker.paginate 累高切页', () {
    test('同段 7 行 ×30 高、页高 100 → 3 / 3 / 1', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        for (int i = 0; i < 7; i++) ln(i * 10, (i + 1) * 10, 30),
      ];

      final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100);

      expect(pages.length, 3);
      expect(pages[0].index, 0);
      expect(pages[0].start, 0);
      expect(pages[0].end, 30);
      expect(pages[0].lineCount, 3);
      expect(pages[0].height, 90);
      expect(pages[1].start, 30);
      expect(pages[1].end, 60);
      expect(pages[1].lineCount, 3);
      expect(pages[2].start, 60);
      expect(pages[2].end, 70);
      expect(pages[2].lineCount, 1);
    });

    test('页内跨段加段间距、跨页不加', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        ln(0, 10, 30), // p0
        ln(10, 20, 30, p: 1),
        ln(20, 30, 30, p: 1),
      ];

      final List<PageSlice> pages =
          PageBreaker.paginate(lines, pageHeight: 100, paragraphSpacing: 16);

      expect(pages.length, 2);
      expect(pages[0].end, 20);
      expect(pages[0].height, 76); // 30 + 间距 16 + 30
      expect(pages[1].start, 20);
      expect(pages[1].height, 30); // 页首不加段间距
    });

    test('单行高于整页 → 独占一页，且至少推进 1 行', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        ln(0, 10, 150),
        ln(10, 20, 20),
        ln(20, 30, 20),
      ];

      final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100);

      expect(pages.length, 2);
      expect(pages[0].end, 10);
      expect(pages[0].lineCount, 1);
      expect(pages[0].height, 150);
      expect(pages[1].start, 10);
      expect(pages[1].end, 30);
      expect(pages[1].lineCount, 2);
    });

    test('空行表 → 一个空页 [0, 0)（保证每章至少一页）', () {
      final List<PageSlice> pages = PageBreaker.paginate(const <MeasuredLine>[], pageHeight: 100);

      expect(pages.length, 1);
      expect(pages.single.start, 0);
      expect(pages.single.end, 0);
      expect(pages.single.lineCount, 0);
      expect(pages.single.height, 0);
    });
  });

  group('断句回拉', () {
    test('页尾落在段中间且更早的行有句读 → 回拉到句读处', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        ln(0, 10, 30),
        ln(10, 20, 30, q: LineBreakQuality.strong),
        ln(20, 30, 30),
        ln(30, 40, 30),
      ];

      final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100);

      // 自然切点在 [0,30)（3 行 = 90 ≤ 100），回拉到第 2 行（句读）→ 页 1 只剩 2 行。
      expect(pages.length, 2);
      expect(pages[0].start, 0);
      expect(pages[0].end, 20);
      expect(pages[0].lineCount, 2);
      expect(pages[0].height, 60);
      expect(pages[1].start, 20);
      expect(pages[1].end, 40);
      expect(pages[1].lineCount, 2);
    });

    test('回拉窗口按字符量封顶 50：超出窗口的句读不算数', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        ln(0, 40, 30),
        ln(40, 50, 30, q: LineBreakQuality.strong),
        ln(50, 110, 30), // 60 字 > 50 → 扫描到它就出窗口
        ln(110, 120, 30),
      ];

      final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100);

      expect(pages.length, 2);
      expect(pages[0].end, 110); // 维持自然切点，未回拉
      expect(pages[0].lineCount, 3);
      expect(pages[1].start, 110);
      expect(pages[1].end, 120);
    });

    test('回拉到页首行也允许（页内至少保留 1 行，代价 ≤50 字）', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        ln(0, 20, 30, q: LineBreakQuality.strong),
        ln(20, 30, 30),
        ln(30, 40, 30),
        ln(40, 50, 30),
      ];

      final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100);

      expect(pages.length, 2);
      expect(pages[0].end, 20);
      expect(pages[0].lineCount, 1);
      expect(pages[1].start, 20);
      expect(pages[1].end, 50);
      expect(pages[1].lineCount, 3);
    });

    test('切点落在段末（下一行起新段）→ 不回拉', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        ln(0, 10, 40, q: LineBreakQuality.strong),
        ln(10, 20, 40, q: LineBreakQuality.strong), // p0 末行
        ln(20, 30, 40, p: 1), // p1 首行（新段）
      ];

      final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100);

      // 自然填充：40 + 40 = 80 ≤ 100，第 3 行 +40 = 120 > 100 → 切在
      // line1（恰为 p0 段末）；下一行起新段 ⇒ 回拉条件（同段续行）不成立。
      expect(pages.length, 2);
      expect(pages[0].end, 20); // 段末即天然断点，页尾就在段末
      expect(pages[0].lineCount, 2);
      expect(pages[1].start, 20);
    });
  });

  group('findPageByCharOffset（二分）', () {
    final List<MeasuredLine> lines = <MeasuredLine>[
      for (int i = 0; i < 7; i++) ln(i * 10, (i + 1) * 10, 30),
    ];
    final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100); // [0,30) [30,60) [60,70)

    test('空页表 → -1', () {
      expect(PageBreaker.findPageByCharOffset(const <PageSlice>[], 5), -1);
    });

    test('页首 / 页内 / 页尾', () {
      expect(PageBreaker.findPageByCharOffset(pages, 0), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 17), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 29), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 30), 1);
      expect(PageBreaker.findPageByCharOffset(pages, 59), 1);
      expect(PageBreaker.findPageByCharOffset(pages, 60), 2);
      expect(PageBreaker.findPageByCharOffset(pages, 69), 2);
    });

    test('越界宽容：负数 → 首页；超尾 → 末页', () {
      expect(PageBreaker.findPageByCharOffset(pages, -3), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 70), 2);
      expect(PageBreaker.findPageByCharOffset(pages, 9999), 2);
    });
  });

  group('不变量', () {
    test('页区间首尾相接、覆盖整段字符范围', () {
      final List<MeasuredLine> lines = <MeasuredLine>[
        for (int i = 0; i < 23; i++) ln(i * 7, (i + 1) * 7, 30, q: LineBreakQuality.weak),
      ];

      final List<PageSlice> pages = PageBreaker.paginate(lines, pageHeight: 100, paragraphSpacing: 6);

      expect(pages.first.start, lines.first.start);
      expect(pages.last.end, lines.last.end);
      for (int i = 1; i < pages.length; i++) {
        expect(pages[i].start, pages[i - 1].end);
        expect(pages[i].index, i);
      }
      // 每页要么不超页高，要么只有 1 行（单行超页的兜底）。
      for (final PageSlice page in pages) {
        expect(page.height <= 100 || page.lineCount == 1, isTrue, reason: '$page');
      }
    });
  });
}
