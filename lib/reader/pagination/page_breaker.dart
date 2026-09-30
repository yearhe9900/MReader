// 分页切页内核（纯 Dart：**不 import Flutter、不 import dart:io**）。
//
// 职责：把「已测量好的行」按页高切成页，并给出「页 ↔ 字符偏移」的互查。
// 测量（`TextPainter` 行排版）不在这里——`dart:ui` 文本排版只能在 root
// isolate（这是与 567Reader「排版跑 IO 协程」最大的结构差异），故测量留在
// `page_paginator.dart`，本文件只做与渲染无关的**纯数值切页**，便于纯 `test()`
// 断言（本项目已两次实证 `testWidgets` + 真异步 IO 挂死）。
//
// 切页规则（选型文档 §3 + `docs/里程碑-分页引擎.md` §2.4）：
//   1. 页 = 连续若干**整行**（词完整性由行断保证，切点必在行边界）；
//   2. 页内相邻段之间加段间距；跨页处不加（页首无段间距）；
//   3. 至少推进 1 行（单行高于整页时亦独占一页），绝不死循环；
//   4. 「断句回拉」：切点在段中间时，按类别优先级把页尾回拉到更自然的行边界
//      （直译 legado_flutter 未接线 `paginator.dart:114-142` 的 `_findBestBreakPoint`，
//      唯一差异是把「回拉到字符」改成「回拉到行」——本方案切点只在行边界）。
//
// 字符偏移空间（全里程碑共享定义）：`ExtractedSection.paragraphs` 各段**原文**
// （含 `\x00` 标记与 `<b>/<i>` 标签）**无分隔符**顺序拼接，`joinedOffset =
// Σ 前段长度 + 段内偏移`。刻意与 `BookSource.totalCharCount()` 的「`paragraph.length`
// 累加」口径一致，全书字数加权进度 `(前章字数 + 章内偏移) / totalCharCount()`
// 才能天然连续（若改用 `\n` 拼接，每章会多出 n-1 的漂移）。

/// 行尾断点质量（供「断句回拉」判优先级）。
///
/// 类别表直译 legado_flutter `_findBestBreakPoint` 的优先级
/// （换行 > `。！？；` > `，、` > 空格/全角空格），并补两处：
/// ① 段落结束等价于「换行」（原文段落间本就无 `\n` 字符）；
/// ② `…` `!` `?` `;` 与中文标点同档（半角标点在中文正文里同义）。
enum LineBreakQuality {
  /// 段末（最强断点，等价 legado 的 `\n`）。
  paragraphEnd,

  /// 句读：`。！？；…!?;`
  strong,

  /// 顿逗：`，、,`
  weak,

  /// 空格 / 制表 / 全角空格。
  space,

  /// 其它（含图片占位之后的断点按 [strong] 计——图片边界是自然断点）。
  none,
}

/// 已测量的一行（字符区间已是**章内拼接空间**的偏移）。
class MeasuredLine {
  const MeasuredLine({
    required this.start,
    required this.end,
    required this.height,
    required this.paragraphIndex,
    required this.quality,
  });

  /// 行首字符偏移（含）。
  final int start;

  /// 行尾字符偏移（不含）——等于下一行行首；该段最后一行等于段末。
  final int end;

  /// 行高（逻辑像素，来自 `LineMetrics.height`，含 `TextStyle.height` 倍数）。
  final double height;

  /// 所属段落下标（段间距与「切在段中间」判定用）。
  final int paragraphIndex;

  /// 行尾断点质量。
  final LineBreakQuality quality;

  /// 行内字符数（回拉窗口按字符量计，直译 legado 的「向前找 50 字符」）。
  int get charCount => end - start;

  @override
  String toString() =>
      'MeasuredLine([$start, $end) h=${height.toStringAsFixed(1)} p=$paragraphIndex $quality)';
}

/// 一页（章内页码从 0 起）。
class PageSlice {
  const PageSlice({
    required this.index,
    required this.start,
    required this.end,
    required this.height,
    required this.firstLine,
    required this.lineCount,
  });

  /// 章内页码（0 起，等于在页列表中的下标）。
  final int index;

  /// 页首字符偏移（含）。
  final int start;

  /// 页尾字符偏移（不含）。
  final int end;

  /// 页内容高（行高之和 + 页内段间距之和）。
  final double height;

  /// 页首行在行列表中的下标。
  final int firstLine;

  /// 页内行数（空章节的占位页为 0）。
  final int lineCount;

  /// 该页是否含指定字符偏移。
  bool contains(int charOffset) => charOffset >= start && charOffset < end;

  @override
  String toString() => 'PageSlice(#$index [$start, $end) h=${height.toStringAsFixed(1)} lines=$lineCount)';
}

/// 切页器（纯函数，无状态）。
abstract final class PageBreaker {
  /// 断句回拉的向前搜索窗口（字符数）——直译 legado `_findBestBreakPoint` 的 50。
  static const int kMaxPullBackChars = 50;

  /// 把 [lines] 按 [pageHeight] 切成页。
  ///
  /// [paragraphSpacing]：页内相邻段之间的间距（跨页不加）。
  /// 空行表（空章）返回**一个空页** `[0, 0)`——保证「每章至少一页」，
  /// 免得上层到处判空页。
  static List<PageSlice> paginate(
    List<MeasuredLine> lines, {
    required double pageHeight,
    double paragraphSpacing = 0,
  }) {
    if (lines.isEmpty) {
      return const <PageSlice>[
        PageSlice(index: 0, start: 0, end: 0, height: 0, firstLine: 0, lineCount: 0),
      ];
    }

    final List<PageSlice> pages = <PageSlice>[];
    int cursor = 0;

    while (cursor < lines.length) {
      final int firstLine = cursor;
      int lastLine = cursor;
      double height = 0;
      double lastGap = 0;

      while (cursor < lines.length) {
        final double gap = _gapBefore(lines, cursor, lastLine, firstLine, paragraphSpacing);
        // 「本页还没收进任何行」= cursor 仍停在页首行。
        // 曾误写 `lastLine < firstLine`（初值 lastLine == firstLine 恒 false）：
        // 首行高于整页时一行都收不进、cursor 不前进，外层 while 每轮
        // pages.add 一页却原地踏步 → 列表无限增长 → 内存/磁盘打满、
        // 测试 VM 被 OOM 打死（2026-09-30 实测，批量 `did not complete` 即此）。
        final bool pageEmpty = cursor == firstLine;
        // 放不下且页内已有行 → 关页；本页首行则必收（至少推进 1 行）。
        if (!pageEmpty && height + gap + lines[cursor].height > pageHeight) {
          break;
        }
        height += gap + lines[cursor].height;
        lastGap = gap;
        lastLine = cursor;
        cursor++;
        // 单行高于整页：独占一页后立即关页（防死循环）。
        if (height > pageHeight) break;
      }

      // 硬底线：任何路径下每轮必须至少推进 1 行（里程碑 §1「至少推进、
      // 绝不死循环」）。正常路径不可达，纯防御——万一未来改动破坏了
      // 上面的不变量，这里兜底推进，绝不让 pages 无限增长。
      if (cursor == firstLine) cursor = firstLine + 1;

      // 断句回拉：仅当切点落在段中间（下一行仍是同段续行）时尝试。
      if (cursor < lines.length &&
          lines[cursor].paragraphIndex == lines[lastLine].paragraphIndex) {
        final int pulled = _pullBack(lines, firstLine, lastLine);
        if (pulled < lastLine) {
          lastLine = pulled;
          cursor = pulled + 1;
          height = _heightOf(lines, firstLine, lastLine, paragraphSpacing);
        }
      }

      pages.add(PageSlice(
        index: pages.length,
        start: lines[firstLine].start,
        end: lines[lastLine].end,
        height: height,
        firstLine: firstLine,
        lineCount: lastLine - firstLine + 1,
      ));
      // lastGap 只在「页内跨段」时非零，此处仅用于可读性；不改语义。
      assert(lastGap >= 0);
    }

    return pages;
  }

  /// 页内「本行之前」要加的间距：非首行且与上一行不同段时 = [paragraphSpacing]。
  static double _gapBefore(
    List<MeasuredLine> lines,
    int index,
    int lastLine,
    int firstLine,
    double paragraphSpacing,
  ) {
    if (lastLine < firstLine) return 0;
    return lines[index].paragraphIndex == lines[lastLine].paragraphIndex
        ? 0
        : paragraphSpacing;
  }

  /// 页内容高（含页内段间距）。
  static double _heightOf(
    List<MeasuredLine> lines,
    int firstLine,
    int lastLine,
    double paragraphSpacing,
  ) {
    double h = 0;
    for (int i = firstLine; i <= lastLine; i++) {
      h += (i == firstLine || lines[i].paragraphIndex == lines[i - 1].paragraphIndex)
          ? lines[i].height
          : paragraphSpacing + lines[i].height;
    }
    return h;
  }

  /// 断句回拉：返回新的「页尾行下标」（不回拉则原样返回 [lastLine]）。
  ///
  /// 从页尾向前扫描，累计字符量不超过 [kMaxPullBackChars]；
  /// **类别优先于位置**（legado 按类别依次 `lastIndexOf`，故窗口内更靠前的强断点
  /// 胜过更靠后的弱断点），同类取最靠后；回拉后页内仍至少保留 1 行。
  static int _pullBack(List<MeasuredLine> lines, int firstLine, int lastLine) {
    int best = -1;
    int bestRank = 0;
    int chars = 0;

    for (int i = lastLine; i >= firstLine; i--) {
      chars += lines[i].charCount;
      if (chars > kMaxPullBackChars) break;
      final int rank = _rankOf(lines[i].quality);
      if (rank > bestRank) {
        bestRank = rank;
        best = i;
      }
      if (bestRank == _rankOf(LineBreakQuality.paragraphEnd)) break;
    }

    // 未找到任何断点 / 没往回挪 → 维持原切点（legado 的「找不到就返回原位置」）。
    if (best < firstLine || best >= lastLine) return lastLine;
    return best;
  }

  static int _rankOf(LineBreakQuality quality) {
    switch (quality) {
      case LineBreakQuality.paragraphEnd:
        return 4;
      case LineBreakQuality.strong:
        return 3;
      case LineBreakQuality.weak:
        return 2;
      case LineBreakQuality.space:
        return 1;
      case LineBreakQuality.none:
        return 0;
    }
  }

  /// 字符偏移 → 页码（二分；直译 legado `findPageByCharOffset`，语义见下）。
  ///
  /// - 页表为空 → `-1`（无页可落）；
  /// - 偏移 ≤ 首页页首 → `0`；偏移 ≥ 末页页尾 → 末页下标（越界宽容）；
  /// - 其余情况返回包含该偏移的页；页区间不含空档，故总能命中。
  static int findPageByCharOffset(List<PageSlice> pages, int charOffset) {
    if (pages.isEmpty) return -1;
    if (charOffset <= pages.first.start) return 0;
    if (charOffset >= pages.last.end) return pages.length - 1;

    int lo = 0;
    int hi = pages.length - 1;
    while (lo <= hi) {
      final int mid = (lo + hi) ~/ 2;
      final PageSlice page = pages[mid];
      if (charOffset < page.start) {
        hi = mid - 1;
      } else if (charOffset >= page.end) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    return lo.clamp(0, pages.length - 1);
  }
}
