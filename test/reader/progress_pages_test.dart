// `M-PAGE` T03：进度采样 / 恢复 与 页表 的桥接纯函数（progress_pages.dart）。
//
// 页表夹具 = `pagination_incremental_test.dart` 的 4 段章 8 页表
// （等宽 fontSize 18 / height 1.6、pageWidth 180、pageHeight 200，100 字/段
// 恒切 2 页）——期望值**硬编码字面量**，不引用被测常量。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/progress_pages.dart';
import 'package:mreader/reader/reading_progress.dart';

/// T01 夹具：4 段 × 100 字 = 400 字章的完整页表（8 页）。
const List<PageSlice> kPages = <PageSlice>[
  PageSlice(index: 0, start: 0, end: 60, height: 174, firstLine: 0, lineCount: 6),
  PageSlice(index: 1, start: 60, end: 100, height: 116, firstLine: 6, lineCount: 4),
  PageSlice(index: 2, start: 100, end: 160, height: 174, firstLine: 10, lineCount: 6),
  PageSlice(index: 3, start: 160, end: 200, height: 116, firstLine: 16, lineCount: 4),
  PageSlice(index: 4, start: 200, end: 260, height: 174, firstLine: 20, lineCount: 6),
  PageSlice(index: 5, start: 260, end: 300, height: 116, firstLine: 26, lineCount: 4),
  PageSlice(index: 6, start: 300, end: 360, height: 174, firstLine: 30, lineCount: 6),
  PageSlice(index: 7, start: 360, end: 400, height: 116, firstLine: 36, lineCount: 4),
];

void main() {
  group('sampleCharOffset：页首偏移 + 页内细分', () {
    test('页首（fraction=0）→ 该页 start', () {
      expect(sampleCharOffset(pages: kPages, pageIndex: 0), 0);
      expect(sampleCharOffset(pages: kPages, pageIndex: 3), 160);
      expect(sampleCharOffset(pages: kPages, pageIndex: 7), 360);
    });

    test('页内细分按字符均匀折算（fraction clamp 0..1）', () {
      // 第 6 页 [300,360)：0.5 → 330。
      expect(
        sampleCharOffset(pages: kPages, pageIndex: 6, withinPageFraction: 0.5),
        330,
      );
      // fraction 越界 clamp：负值 → start，>1 → end。
      expect(
        sampleCharOffset(pages: kPages, pageIndex: 6, withinPageFraction: -0.4),
        300,
      );
      expect(
        sampleCharOffset(pages: kPages, pageIndex: 6, withinPageFraction: 3.0),
        360,
      );
      // 末页 fraction=1 → 章末 400。
      expect(
        sampleCharOffset(pages: kPages, pageIndex: 7, withinPageFraction: 1.0),
        400,
      );
    });

    test('页表空 / 页索引越界 → 0（不写垃圾值）', () {
      expect(sampleCharOffset(pages: const <PageSlice>[], pageIndex: 0), 0);
      expect(sampleCharOffset(pages: kPages, pageIndex: -1), 0);
      expect(sampleCharOffset(pages: kPages, pageIndex: 8), 0);
    });
  });

  group('sampleChapterPos：采样 → 字符偏移比例', () {
    test('页首采样换算成 charOffset / totalChars', () {
      // 第 4 页首 200 / 400 = 0.5。
      expect(
        sampleChapterPos(pages: kPages, pageIndex: 4, totalChars: 400),
        closeTo(0.5, 1e-9),
      );
      // 第 0 页首 → 0.0；末页页首 360/400 = 0.9。
      expect(
        sampleChapterPos(pages: kPages, pageIndex: 0, totalChars: 400),
        0.0,
      );
      expect(
        sampleChapterPos(pages: kPages, pageIndex: 7, totalChars: 400),
        closeTo(0.9, 1e-9),
      );
      // 带页内细分：第 6 页 0.5 → 330/400 = 0.825。
      expect(
        sampleChapterPos(
            pages: kPages, pageIndex: 6, totalChars: 400, withinPageFraction: 0.5),
        closeTo(0.825, 1e-9),
      );
    });

    test('totalChars ≤ 0 → 0.0；空表 → 0.0', () {
      expect(sampleChapterPos(pages: kPages, pageIndex: 4, totalChars: 0), 0.0);
      expect(sampleChapterPos(pages: kPages, pageIndex: 4, totalChars: -3), 0.0);
      expect(sampleChapterPos(pages: const <PageSlice>[], pageIndex: 0, totalChars: 400),
          0.0);
    });
  });

  group('pageIndexForProgress：charOffset 二分落位（重排恢复，保证②）', () {
    test('页首偏移 → 页索引（含边界）', () {
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: 0.0, totalChars: 400),
        0,
      );
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: 0.5, totalChars: 400),
        4, // offset 200 = 页 4 首
      );
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: 1.0, totalChars: 400),
        7, // offset 400 = 章末 → 末页
      );
    });

    test('页内偏移落进所属页（二分，不是线性扫）', () {
      // offset 350 ∈ [300,360) → 页 6。
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: 350 / 400, totalChars: 400),
        6,
      );
      // offset 99 ∈ [60,100) → 页 1。
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: 99 / 400, totalChars: 400),
        1,
      );
      // offset 100（页 2 首）→ 页 2（start 含、上页 end 不含）。
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: 100 / 400, totalChars: 400),
        2,
      );
    });

    test('部分分页（增量补页中）→ 落到最末已知页', () {
      final List<PageSlice> partial = kPages.sublist(0, 4); // 只测到页 3（end=200）
      // offset 350 ≥ partial.last.end → clamp 到页 3。
      expect(
        pageIndexForProgress(pages: partial, chapterPos: 350 / 400, totalChars: 400),
        3,
      );
      // offset 在已测范围内仍精确。
      expect(
        pageIndexForProgress(pages: partial, chapterPos: 120 / 400, totalChars: 400),
        2,
      );
    });

    test('空表 / totalChars ≤ 0 → 0（首屏兜底）', () {
      expect(
        pageIndexForProgress(
            pages: const <PageSlice>[], chapterPos: 0.5, totalChars: 400),
        0,
      );
      expect(pageIndexForProgress(pages: kPages, chapterPos: 0.5, totalChars: 0), 0);
      expect(pageIndexForProgress(pages: kPages, chapterPos: 0.5, totalChars: -1), 0);
    });

    test('chapterPos 越界 clamp 后仍落界内页', () {
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: -0.3, totalChars: 400),
        0,
      );
      expect(
        pageIndexForProgress(pages: kPages, chapterPos: 7.7, totalChars: 400),
        7,
      );
    });
  });

  group('采样 ↔ 恢复 round-trip（保存后重开落回原页）', () {
    test('页首采样 → 恢复 → 同一页', () {
      for (int i = 0; i < kPages.length; i++) {
        final double pos =
            sampleChapterPos(pages: kPages, pageIndex: i, totalChars: 400);
        expect(
          pageIndexForProgress(pages: kPages, chapterPos: pos, totalChars: 400),
          i,
          reason: '页 $i 采样后恢复应落回原页',
        );
      }
    });

    test('经 ReadingProgress chapterPos 中转（字段语义 = 字符偏移比例）', () {
      final ReadingProgress saved = ReadingProgress(
        bookId: 'b',
        chapterHref: 'ch',
        chapterIndex: 0,
        chapterPos:
            sampleChapterPos(pages: kPages, pageIndex: 5, totalChars: 400),
        updatedAt: 1,
      );
      // JSON 往返不丢语义（字段名/格式不变）。
      final ReadingProgress restored =
          ReadingProgress.fromJson(saved.toJson())!;
      expect(
        pageIndexForProgress(
            pages: kPages, chapterPos: restored.chapterPos, totalChars: 400),
        5,
      );
    });
  });
}
