// T03：进度采样 / 恢复 与 页表 的桥接（纯函数，无 Flutter 依赖）。
// 采样（保存）：当前页 `start` + 页内比例细分（翻页视图下细分恒 0 = 页首）；
// 动画期不写盘由调用方把关，本文件只做停手后的纯换算。
// 恢复（落位）：`chapterPos`（字符偏移比例，§0）→ charOffset → 二分找页
// ——页表变了也不漂移（保证②：记 charOffset → 重分页 → 二分落位）。

import 'page_breaker.dart';

/// 采样：页表 + 当前页 + 页内细分 → 章内字符偏移（保存进度用）。
///
/// [pageIndex] 越界 / [pages] 为空 → 返回 `0`（没有可信位置，不写垃圾值）。
/// [withinPageFraction] clamp 到 `[0,1]`；页内细分按字符均匀折算
/// （`start + fraction × (end - start)`），与几何像素比例解耦。
int sampleCharOffset({
  required List<PageSlice> pages,
  required int pageIndex,
  double withinPageFraction = 0.0,
}) {
  if (pages.isEmpty) return 0;
  if (pageIndex < 0 || pageIndex >= pages.length) return 0;
  final PageSlice page = pages[pageIndex];
  final double fraction = withinPageFraction.clamp(0.0, 1.0).toDouble();
  final int offset =
      (page.start + fraction * (page.end - page.start)).round();
  return offset.clamp(page.start, page.end);
}

/// 采样 + 换算一步到位：页表 → `chapterPos`（字符偏移比例）。
double sampleChapterPos({
  required List<PageSlice> pages,
  required int pageIndex,
  required int totalChars,
  double withinPageFraction = 0.0,
}) {
  final int offset = sampleCharOffset(
    pages: pages,
    pageIndex: pageIndex,
    withinPageFraction: withinPageFraction,
  );
  if (totalChars <= 0) return 0.0;
  return (offset / totalChars).clamp(0.0, 1.0).toDouble();
}

/// 恢复：`chapterPos`（字符偏移比例）→ charOffset → 页索引（二分）。
///
/// [pages] 为空 / [totalChars] ≤ 0 → 返回 `0`（首屏兜底；调用方在页表
/// 就绪前应保持首帧估算，勿据此写盘）。
/// 页表部分分页（增量补页中）时二分仍正确：落在未测区域则返回最末已知页。
int pageIndexForProgress({
  required List<PageSlice> pages,
  required double chapterPos,
  required int totalChars,
}) {
  if (pages.isEmpty || totalChars <= 0) return 0;
  final int charOffset =
      (chapterPos.clamp(0.0, 1.0) * totalChars).round().clamp(0, totalChars);
  final int index = PageBreaker.findPageByCharOffset(pages, charOffset);
  return index < 0 ? 0 : index;
}
