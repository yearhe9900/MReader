// 增量分页器（`T02`，里程碑 §1）：**先 5 页上屏、空闲帧补完、每帧预算让出**。
//
// 对应选型 §2.1 第 2 条（直译 legado_flutter `paginateIncremental` 思路）：
// 进章后先在**首次上屏预算**内分出「目标页 + 至少 5 页」，其余页由空闲帧
// 按 [kIdleFrameBudget] 逐步补完；`dart:ui` 文本排版只能在 root isolate，
// 所以没有后台线程，只能靠**时间预算切片**让出主线程（与 567Reader IO 线程
// 排版的结构差异，见选型 §0「关键约束」）。
//
// ## 切片语义
// · [step]：至少测 **1 段**（保证前进，绝不空转），预算尽即返回——调用方
//   在空闲帧循环 `step(kIdleFrameBudget)` 直到 `hasWork == false`。
// · [prime]：开书/跳章的「首屏突发」，按 4ms 小片推进到 [initialReady]
//   （目标页已覆盖 且 至少 [kInitialPageCount] 页）——小片粒度保证**达标即停**，
//   不会把整章测完才返回（16ms 大预算下单次 step 会一路测到底）。
// · 预算耗尽仍未达标 → 返回 `false`，调用方挂占位页、继续空闲帧补（保证④
//   「占位上屏 + 一次落位」的前半段）。
//
// ## 页表前缀稳定性（上屏依赖的契约）
// 贪心切页是**前缀决定**的：除**末页**外，已产出的页边界不随后续测量改变
// （末页由「行耗尽」关闭、可能增长，故部分结果只有末页是暂定的）。
// `PaginatedChapter.covers` 据此只信末页覆盖范围；契约测试
// `test/reader/pagination_incremental_test.dart` 钉死「部分页表前缀 == 最终前缀」。
//
// ## 与渲染的一致性
// [lines] 只追加；[pages] 每次重切为**新列表**（旧快照不被改写）。
// 快照 `snapshot()` 共享活 `lines` 列表——只追加保证既有页的
// `firstLine`/`lineCount` 下标永不过期（契约测试钉死）。
import 'pagination_cache.dart';
import 'page_breaker.dart';
import 'page_paginator.dart';

/// 空闲帧排版预算（里程碑原文「每帧排版预算 **4~8ms** 让出」，取中 6ms）。
const Duration kIdleFrameBudget = Duration(milliseconds: 6);

/// 开书/跳章首次上屏的突发预算（≈ 1 帧；超时未达标转占位 + 空闲帧补）。
const Duration kFirstPaintBudget = Duration(milliseconds: 16);

/// 首屏最少页数（「先 **5 页**上屏」，legado_flutter 同款）。
const int kInitialPageCount = 5;

/// [prime] 的推进小片（达标即停的粒度上界；实测单段远小于此）。
const Duration kPrimeSlice = Duration(milliseconds: 4);

/// 一章的**增量**分页任务（进行中持有部分页表；完成后快照落 LRU 缓存）。
class IncrementalPaginator {
  IncrementalPaginator({
    required this.href,
    required this.paragraphs,
    required this.config,
    this.targetCharOffset = 0,
  })  : totalChars = PagePaginator.charCountOf(paragraphs),
        _complete = paragraphs.isEmpty,
        _pages = PageBreaker.paginate(
          const <MeasuredLine>[],
          pageHeight: config.pageHeight,
          paragraphSpacing: config.paragraphSpacing,
        );

  /// 章标识（缓存与调度的 key）。
  final String href;

  /// 章节原文段落（`ExtractedSection.paragraphs`，只读）。
  final List<String> paragraphs;

  /// 排版参数（行测量与切页共用）。
  final PaginationConfig config;

  /// 目标字符偏移（开书恢复 / 跳转落位点；可随复用改写）。
  int targetCharOffset;

  /// 章内总字数（`Σ paragraph.length`，与 `totalCharCount()` 同口径）。
  final int totalChars;

  final List<MeasuredLine> _lines = <MeasuredLine>[];
  List<PageSlice> _pages;
  int _nextParagraph = 0;
  int _baseOffset = 0;
  bool _complete;

  /// 已测量到第几段（0 起；下一段待测）。
  int get measuredParagraphs => _nextParagraph;

  /// 是否全章测完。
  bool get isComplete => _complete;

  /// 是否还有排版工作可调度。
  bool get hasWork => !_complete;

  /// 当前页表（部分结果的**末页暂定**，其余稳定；见文件头契约）。
  List<PageSlice> get pages => _pages;

  /// 当前行表（只追加的活列表；上层按快照读取）。
  List<MeasuredLine> get lines => _lines;

  /// 目标页是否已可落位（完成即真；部分结果看末页是否覆盖目标）。
  bool get targetCovered =>
      _complete ||
      (_pages.isNotEmpty && targetCharOffset < _pages.last.end);

  /// 首屏是否就绪：目标页已覆盖 **且** 至少 [kInitialPageCount] 页
  /// （全章不足 5 页时以完成为准）。开书「先 5 页上屏」的判定。
  bool get initialReady =>
      _complete || (_pages.length >= kInitialPageCount && targetCovered);

  /// 一个预算切片的排版：至少测 1 段，预算尽即让出。
  ///
  /// 返回 `true` = 尚未完成、可继续调度；`false` = 已完成（页表已定稿）。
  bool step(Duration budget) {
    if (_complete) return false;
    final Stopwatch clock = Stopwatch()..start();
    do {
      final String raw = paragraphs[_nextParagraph];
      _lines.addAll(PagePaginator.measureParagraphs(
        paragraphs: <String>[raw],
        config: config,
        startIndex: _nextParagraph,
        baseOffset: _baseOffset,
      ));
      _baseOffset += raw.length;
      _nextParagraph++;
      if (_nextParagraph >= paragraphs.length) {
        _complete = true;
        _reslice();
        return false;
      }
    } while (clock.elapsed < budget);
    _reslice();
    return true;
  }

  /// 首屏突发：在 [budget] 内按 [kPrimeSlice] 小片推进到 [initialReady]。
  ///
  /// 返回 `initialReady`；`false` 表示预算已尽仍未达标（调用方挂占位页、
  /// 转空闲帧继续 [step]）。空章构造即完成，恒 `true`。
  bool prime(Duration budget) {
    if (_complete) return true;
    if (budget <= Duration.zero) return false;
    final Stopwatch clock = Stopwatch()..start();
    while (!initialReady) {
      final Duration remaining = budget - clock.elapsed;
      if (remaining <= Duration.zero) return false;
      final Duration slice =
          remaining < kPrimeSlice ? remaining : kPrimeSlice;
      if (!step(slice)) break; // 完成
    }
    return initialReady;
  }

  /// 当前状态快照（落缓存 / 交给上屏）。
  PaginatedChapter snapshot() => PaginatedChapter(
        href: href,
        config: config,
        lines: _lines,
        pages: _pages,
        totalChars: totalChars,
        complete: _complete,
      );

  void _reslice() {
    _pages = PageBreaker.paginate(
      _lines,
      pageHeight: config.pageHeight,
      paragraphSpacing: config.paragraphSpacing,
    );
  }
}
