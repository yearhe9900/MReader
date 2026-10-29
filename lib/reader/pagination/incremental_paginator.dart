// 增量分页器：**目标页覆盖即上屏、空闲帧补完、每帧预算让出**。
//
// `dart:ui` 排版只能在 root isolate、无后台线程 → 靠时间预算切片让出主线程：
// · [step]：至少测 1 段（绝不空转），预算尽即返回；调用方在空闲帧循环。
// · [prime]：开书/跳章首屏突发，按 [kPrimeSlice] 小片推进到 [initialReady]
//   （达标即停，不会一次测完整章）；预算尽未达标 → 返回 false，调用方挂
//   占位页转空闲帧补（保证④「占位上屏 + 一次落位」前半段）。
//
// 首屏线口径（统一方案 Phase 1 §6.3）：`initialReady` = **目标页覆盖**（1 页即上屏），
// 5 页线（[kBackgroundPageGoal]）只作**后台目标**（[backgroundGoalReached]，
// 空闲帧 [step] 续排天然越过），**不挡首屏**。
//
// 页表前缀稳定性（上屏契约）：贪心切页前缀决定——除**末页**（随行耗尽增长）外，
// 已产出页边界不随后续测量改变；`covers` 只信末页覆盖范围。与渲染一致性：
// [lines] 只追加、[pages] 每次换新列表 → 快照下标永不过期。均由
// `pagination_incremental_test.dart` 钉死。
import 'package:flutter/painting.dart';

import 'pagination_cache.dart';
import 'page_breaker.dart';
import 'page_paginator.dart';

/// 空闲帧排版预算（里程碑原文「每帧排版预算 **4~8ms** 让出」，取中 6ms）。
const Duration kIdleFrameBudget = Duration(milliseconds: 6);

/// 开书/跳章首次上屏的突发预算（≈ 1 帧；超时未达标转占位 + 空闲帧补）。
const Duration kFirstPaintBudget = Duration(milliseconds: 16);

/// 首屏突发的后台目标页数（原「先 5 页上屏」的 5 页线）。
///
/// **不挡首屏**（统一方案 Phase 1 §6.3）：`initialReady` 只看目标页覆盖，本值只作
/// [backgroundGoalReached] 的判据与测试口径。
const int kBackgroundPageGoal = 5;

/// [prime] 的推进小片（达标即停的粒度上界；实测单段远小于此）。
const Duration kPrimeSlice = Duration(milliseconds: 4);

/// 一章的**增量**分页任务（进行中持有部分页表；完成后快照落 LRU 缓存）。
class IncrementalPaginator {
  IncrementalPaginator({
    required this.href,
    required this.paragraphs,
    required this.config,
    this.headingHeight = 0,
    this.imageSizes,
    this.targetCharOffset = 0,
  })  : totalChars = PagePaginator.charCountOf(paragraphs),
        _complete = paragraphs.isEmpty,
        _pages = PageBreaker.paginate(
          const <MeasuredLine>[],
          pageHeight: config.pageHeight,
          paragraphSpacing: config.paragraphSpacing,
          firstPageHeight: config.pageHeight - headingHeight,
        );

  /// 章标识（缓存与调度的 key）。
  final String href;

  /// 章节原文段落（`ExtractedSection.paragraphs`，只读）。
  final List<String> paragraphs;

  /// 排版参数（行测量与切页共用）。
  final PaginationConfig config;

  /// 章标题占高（页 0 预算 = `pageHeight − headingHeight`）。
  /// **不进 [PaginationConfig]**——逐章不同，进缓存键会触发全量失效。
  final double headingHeight;

  /// 图片真尺寸表（src → Size，书级共享引用）。
  /// **不进 [PaginationConfig]**——运行中会增长（`ensureImageSize` 异步补入），
  /// 由调度方 `invalidateForImageSizes()` 显式重分页，不走配置失效。
  /// null / 未命中 → 48×48 占位回退。
  final Map<String, Size>? imageSizes;

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

  /// 首屏是否就绪：**目标页已覆盖即真**（1 页即上屏，统一方案 Phase 1 §6.3；
  /// 5 页线已降为后台目标，不挡首屏）。
  bool get initialReady => targetCovered;

  /// 后台目标是否达成（≥ [kBackgroundPageGoal] 页）：只作续排观测口径，
  /// 不参与 [initialReady] / [prime] 的达标判定。
  bool get backgroundGoalReached =>
      _complete || _pages.length >= kBackgroundPageGoal;

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
        imageSizes: imageSizes,
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
  /// 转空闲帧继续 [step]）。已达标（含空章构造即完成）**零预算也直通**——
  /// 「目标页已可落位」是状态判定，不该被预算短路。
  bool prime(Duration budget) {
    if (initialReady) return true;
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
      firstPageHeight: config.pageHeight - headingHeight,
    );
  }
}
