// 分页调度器（T02）：**目标页优先 + ±1 章窗口预分页**。
// 分工：[PaginationCache] 管已完成页表 LRU；[IncrementalPaginator] 管单章
// 预算切片；本类管**跨章优先级**——当前章独占预算直到首屏就绪，完成后才
// 轮到预分页队列（±1 章窗口，延迟一切非目标章工作）。
//
// 帧驱动契约（上层接线用）：
//   1. 开书/跳章 → [open]（内部跑突发预算；未就绪返回 `false`）；
//   2. 每空闲帧 → [stepIdle]，`true` = 还有活；一帧只给一个任务一个
//      [kIdleFrameBudget] 切片，超预算让出；
//   3. 动画期上层调 [freeze]（保证③「动画期零排版」，T04）；
//   4. [setWindow] 登记 prev/next；当前章完成前不动邻章，换章旧队列作废。
import 'incremental_paginator.dart';
import 'page_paginator.dart';
import 'pagination_cache.dart';

/// 分页调度器：当前章优先、±1 章窗口预分页（纯逻辑，帧驱动由上层负责）。
class PaginationScheduler {
  PaginationScheduler({PaginationCache? cache})
      : cache = cache ?? PaginationCache();

  /// 已完成页表的 LRU 缓存（可注入，便于测试观察）。
  final PaginationCache cache;

  /// 当前章的进行中任务（首屏就绪前独占预算）。
  IncrementalPaginator? _active;

  /// 预分页队列（当前章完成后才推进；换章/换参数作废）。
  final List<IncrementalPaginator> _prefetch = <IncrementalPaginator>[];

  /// 当前章标识（缓存命中判定与 [currentPage] 读取用）。
  String? get activeHref => _active?.href ?? _lastActiveHref;
  String? _lastActiveHref;

  /// 排版参数快照（调度器级失效判定：换字号/尺寸 → 任务与队列作废）。
  PaginationConfig? get config => _active?.config ?? _config;
  PaginationConfig? _config;

  /// 进行中的当前章任务（无则 `null`）。
  IncrementalPaginator? get active => _active;

  /// 待预分页的邻章数（测试观察窗口行为）。
  int get prefetchPending => _prefetch.length;

  /// 预分页队列（只读视图；观察/测试用，元素暴露 [IncrementalPaginator] 进度）。
  List<IncrementalPaginator> get prefetchJobs =>
      List<IncrementalPaginator>.unmodifiable(_prefetch);

  /// 是否还有排版工作（任一任务未完成）。
  bool get hasWork => (_active?.hasWork ?? false) || _prefetch.isNotEmpty;

  /// 动画期冻结开关（保证③「动画期零排版」，T04）。
  ///
  /// `true` 时 [stepIdle] 直接返回、不推进任何任务（任务与队列原样保留）；
  /// [open] 不受冻结影响——开书/跳章是用户主动动作，必须立即响应。
  /// 上层在翻页手势按下 / settling 动画期 `freeze()`，动画结束 `unfreeze()`。
  bool get frozen => _frozen;
  bool _frozen = false;

  /// 冻结排版队列（幂等）。
  void freeze() => _frozen = true;

  /// 解冻排版队列（幂等）。
  void unfreeze() => _frozen = false;

  /// 当前章的页表（进行中给部分结果；完成后给缓存定稿）。
  PaginatedChapter? get currentPage {
    final IncrementalPaginator? active = _active;
    if (active != null) return active.snapshot();
    final String? href = _lastActiveHref;
    final PaginationConfig? cfg = _config;
    if (href == null || cfg == null) return null;
    return cache.get(href, cfg);
  }

  /// 打开 / 跳转到 [href]：作废异参数任务 → 查缓存（命中即就绪）→ 新建/复用
  /// 任务 → [IncrementalPaginator.prime] 突发到首屏就绪 → 登记 ±1 邻章预分页。
  /// 返回「目标页已可落位」——`false` 时上层挂占位页、由 [stepIdle] 补完。
  /// 换章时旧当前章任务丢弃（部分页表不留缓存）、旧 ±1 队列整体作废；
  /// 同章重开保留进度与队列。
  bool open({
    required String href,
    required List<String> paragraphs,
    required PaginationConfig config,
    int targetCharOffset = 0,
    String? prevHref,
    List<String>? prevParagraphs,
    String? nextHref,
    List<String>? nextParagraphs,
    Duration budget = kFirstPaintBudget,
  }) {
    _acceptConfig(config);

    // 缓存命中：直接就绪（换章也走这里，触发 LRU 提位）。
    final PaginatedChapter? hit = cache.get(href, config);
    if (hit != null) {
      if (_lastActiveHref != href) _prefetch.clear(); // 换章：旧窗口作废
      _adoptCached(href, hit);
      _registerWindow(prevHref, prevParagraphs, nextHref, nextParagraphs);
      return true;
    }

    final IncrementalPaginator? current = _active;
    late final IncrementalPaginator job;
    if (current != null && current.href == href) {
      job = current; // 同章重开：保留进度与 ±1 队列
    } else {
      // 换章：优先从旧队列提拔（保住已测进度），否则新建。
      job = _prefetch.firstWhere(
        (IncrementalPaginator p) => p.href == href,
        orElse: () => IncrementalPaginator(
          href: href,
          paragraphs: paragraphs,
          config: config,
          targetCharOffset: targetCharOffset,
        ),
      );
      _prefetch.clear(); // 旧 ±1 窗口整体作废（随后按新章重登）
      _active = null; // 旧当前章任务丢弃（部分页表不留缓存）
    }
    job.targetCharOffset = targetCharOffset;
    _active = job;
    _lastActiveHref = href;
    _config = config;

    final bool ready = job.prime(budget);
    if (!job.hasWork) {
      // 突发期直接测完（小章）：定稿入缓存。
      cache.put(job.snapshot());
      _active = null;
    }
    _registerWindow(prevHref, prevParagraphs, nextHref, nextParagraphs);
    return ready;
  }

  /// 登记 ±1 章预分页窗口（仅收**未完成**且不在缓存/队列中的邻章；
  /// 当前章完成前不动它们——延迟一切非目标章工作）。
  void setWindow({
    String? prevHref,
    List<String>? prevParagraphs,
    String? nextHref,
    List<String>? nextParagraphs,
  }) {
    final PaginationConfig? cfg = _config;
    if (cfg == null) return;
    _registerWindow(prevHref, prevParagraphs, nextHref, nextParagraphs);
  }

  /// 一帧空闲排版：当前章任务优先，其次预分页队列头部。
  ///
  /// 返回 `true` = 还有活（下一帧继续）；`false` = 全部完成或无任务。
  /// 每次调用最多给**一个**任务一个 [budget] 切片（超时让出主线程）。
  /// 冻结期（[frozen]）返回 `hasWork` 但**不推进**——上层据 `hasWork`
  /// 继续持帧回调，解冻后自然续排。
  bool stepIdle({Duration budget = kIdleFrameBudget}) {
    if (!hasWork) return false;
    if (_frozen) return true; // 动画期零排版（T04）：有活但本帧不动

    final IncrementalPaginator? active = _active;
    if (active != null && active.hasWork) {
      if (!active.step(budget)) {
        // 当前章定稿：落缓存、让位给预分页队列。
        cache.put(active.snapshot());
        _active = null;
      }
      return hasWork;
    }
    if (active != null && !active.hasWork) {
      cache.put(active.snapshot());
      _active = null;
    }

    // 预分页队列：逐个补完（近者先入队，先入先补）。
    while (_prefetch.isNotEmpty) {
      final IncrementalPaginator job = _prefetch.first;
      if (!job.step(budget)) {
        cache.put(job.snapshot());
        _prefetch.removeAt(0);
        return hasWork; // 一帧一片，超预算让出
      }
      return true;
    }
    return false;
  }

  /// 换参数/换书：任务、队列、缓存整体作废（配置哈希失效的调度层一半）。
  void _acceptConfig(PaginationConfig config) {
    if (_config == config) return;
    _config = config;
    _active = null;
    _prefetch.clear();
    cache.clear();
  }

  void _adoptCached(String href, PaginatedChapter hit) {
    _active = null;
    _lastActiveHref = href;
    // 同章进行中的旧任务作废（缓存已有定稿）。
    _prefetch.removeWhere((IncrementalPaginator p) => p.href == href);
    assert(hit.complete, '缓存只应存完整结果');
  }

  void _registerWindow(
    String? prevHref,
    List<String>? prevParagraphs,
    String? nextHref,
    List<String>? nextParagraphs,
  ) {
    _enqueuePrefetch(prevHref, prevParagraphs);
    _enqueuePrefetch(nextHref, nextParagraphs);
  }

  void _enqueuePrefetch(String? href, List<String>? paragraphs) {
    final PaginationConfig? cfg = _config;
    if (href == null || paragraphs == null || cfg == null) return;
    if (href == activeHref) return; // 不预分页自己
    if (cache.has(href, cfg)) return; // 已有定稿
    if (_prefetch.any((IncrementalPaginator p) => p.href == href)) return;
    _prefetch.add(IncrementalPaginator(
      href: href,
      paragraphs: paragraphs,
      config: cfg,
      targetCharOffset: 0,
    ));
  }

  @override
  String toString() => 'PaginationScheduler(active: $activeHref, '
      'prefetch: ${_prefetch.length}, cache: ${cache.count})';
}
