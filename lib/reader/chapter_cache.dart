// `PERF-02`：章正文的**有界 LRU 缓存** + **按距离补齐的加载规划**（纯 Dart，可单测）。
//
// 单独成文件是为了能在**纯 Dart 单测**里直接断言（`testWidgets` 的 FakeAsync 区
// `await` 真异步 IO 会挂死）：「缓存 + 规划」抽成两个不依赖 Flutter 的类，由
// `ReaderPage` 驱动、由 `test/perf/*` 直接测。
//
// ⚠️ 本文件**不 import Flutter、不 import `dart:io`**（可进 isolate）。
import 'dart:async';
import 'dart:collection';

import '../model/chapter_content.dart';

/// 同时驻留的章正文**上界**（`PERF-02`：不一次性常驻全书解压结果）。
///
/// 常量对外可见，供测试直接断言「已加载章数 ≤ 该上界」。
const int kMaxLoadedChapters = 30;

/// 后台补齐的「当前章两侧」半径（章）。窗口 ≈ 2×半径+1 = 25 < [kMaxLoadedChapters]，
/// 因此**窗口内的章不会因淘汰上界而被逐出**。
const int kEagerLoadRadius = 12;

/// 首帧邻章预取半径：目标章**必等**，± [kFirstBatchRadius] 章预取不阻塞。
const int kFirstBatchRadius = 1;

/// 后台每批加载的章数（每批都 `setState` 合入，避免长任务卡 UI）。
const int kLoadBatchSize = 3;

/// 章正文的**有界 LRU 缓存**（纯 Dart）。
///
/// 用 `LinkedHashMap` 保「插入序 == 最近使用序（末尾最新）」：`get` / `touch` 会把
/// 命中项移到末尾；[put] 触发后按上界从头部淘汰最久未用者。
class ChapterCache {
  ChapterCache({this.maxLoaded = kMaxLoadedChapters});

  /// 同时驻留上界（构造可覆盖，便于测试用小值）。
  final int maxLoaded;

  final LinkedHashMap<int, ChapterContent> _entries =
      LinkedHashMap<int, ChapterContent>();

  /// 当前驻留的章数。
  int get count => _entries.length;

  /// 已驻留的章索引（按最近使用序，末尾最新）。返回**只读视图**。
  Iterable<int> get loadedIndices => _entries.keys;

  /// 第 [index] 章是否已驻留。
  bool contains(int index) => _entries.containsKey(index);

  /// 取第 [index] 章正文；命中则**标记为最近使用**，未命中返回 `null`。
  ChapterContent? get(int index) {
    final ChapterContent? content = _entries.remove(index);
    if (content == null) return null;
    _entries[index] = content; // 移到末尾（最近使用）
    return content;
  }

  /// 只读查看：命中返回正文但**不改变最近使用序**（供 `build` 期读取，避免副作用）。
  ChapterContent? peek(int index) => _entries[index];

  /// 写入（或更新）第 [index] 章正文，随后按上界淘汰最久未用者。
  void put(int index, ChapterContent content) {
    _entries.remove(index);
    _entries[index] = content;
    _evict();
  }

  /// 标记第 [index] 章为最近使用（滚动到当前章时调用）；未驻留则无操作。
  void touch(int index) {
    final ChapterContent? content = _entries.remove(index);
    if (content != null) _entries[index] = content;
  }

  /// 是否已驻留 `0..target`（`RD-04`「同版面 `initialScrollOffset` 精确恢复」的前提：
  /// 目标章**上方**的所有内容高度必须都是真值，否则首帧总高不足、jump 会被 clamp）。
  bool coversPrefix(int target) {
    if (target < 0) return true;
    for (int i = 0; i <= target; i++) {
      if (!_entries.containsKey(i)) return false;
    }
    return true;
  }

  /// 计算「以 [current] 为中心、半径 [radius]、**尚未驻留**」的待加载章索引，
  /// **按离 [current] 的距离升序**（近的先载）。
  List<int> planLoad(int current, int chapterCount, {required int radius}) {
    if (chapterCount <= 0) return const <int>[];
    final int lo = (current - radius).clamp(0, chapterCount - 1);
    final int hi = (current + radius).clamp(0, chapterCount - 1);
    final List<int> pending = <int>[];
    for (int i = lo; i <= hi; i++) {
      if (!_entries.containsKey(i)) pending.add(i);
    }
    pending.sort(
      (int a, int b) => (a - current).abs().compareTo((b - current).abs()),
    );
    return pending;
  }

  /// 清空缓存。
  void clear() => _entries.clear();

  void _evict() {
    while (_entries.length > maxLoaded) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// 章正文的**增量加载驱动器**（纯 Dart）。
///
/// 与 [ChapterCache] 配合：[loadFirstBatch] 只等目标章，邻章各自到货、不阻塞
/// （首帧用）；[fillOnce] 在后台按「离当前章由近及远」逐批补齐。每批加载后
/// [_protectWindow] 把窗口内的章标为「最近使用」，LRU 淘汰只会逐出**窗口外**的章。
class ChapterAutoLoader {
  ChapterAutoLoader({
    required this.chapterCount,
    required this.loadContent,
    ChapterCache? cache,
    this.batchSize = kLoadBatchSize,
  }) : cache = cache ?? ChapterCache();

  /// 总章数。
  final int chapterCount;

  /// 由实现方提供的单章正文读取（含「单章失败降级」的 catch 语义）。
  final Future<ChapterContent> Function(int index) loadContent;

  /// 缓存（可注入，便于测试观察上界）。
  final ChapterCache cache;

  /// 每批章数。
  final int batchSize;

  /// 首帧批次：加载「[target] ± [kFirstBatchRadius]」（clamp 到边界，去重）。
  ///
  /// **只等目标章**（首帧渲染依赖它）；邻章并发启动但**不阻塞**返回，各自到货各自
  /// 入缓存——若全等，任一邻章解析慢（甚至挂起）都会拖住整个开书流程。
  Future<void> loadFirstBatch(int target) async {
    final List<int> batch =
        cache.planLoad(target, chapterCount, radius: kFirstBatchRadius);
    final List<int> neighbors =
        batch.where((int i) => i != target).toList(growable: false);
    for (final int i in neighbors) {
      unawaited(_loadOne(i)); // 邻章预取：不等待、互不拖累
    }
    if (batch.any((int i) => i == target)) {
      await _loadOne(target); // 目标章必等（首帧渲染依赖）
    }
    _protectWindow(target);
  }

  /// 后台补齐**一批**（半径 [kEagerLoadRadius] 内、尚未驻留者，近的先载）。
  ///
  /// 返回 `false` 表示「当前窗口内已全部驻留」，调用方可停止循环（滚动后需再触发）。
  Future<bool> fillOnce(int current) async {
    final List<int> plan =
        cache.planLoad(current, chapterCount, radius: kEagerLoadRadius);
    if (plan.isEmpty) return false;
    final int take = plan.length < batchSize ? plan.length : batchSize;
    await _loadAll(plan.sublist(0, take));
    _protectWindow(current);
    return true;
  }

  /// 载入单章并落库（越界不落）。
  Future<void> _loadOne(int index) async {
    final ChapterContent content = await loadContent(index);
    if (index < 0 || index >= chapterCount) return;
    cache.put(index, content);
  }

  /// 并发加载一批并等待**全部**完成；每章**各自到货各自 `put`**——
  /// 同批里一章慢/挂不拖住他章的落库（等齐只为 [fillOnce] 的批节奏）。
  Future<void> _loadAll(List<int> indices) async {
    await Future.wait<void>(indices.map(_loadOne));
  }

  /// 把窗口 `[current - kEagerLoadRadius, current + kEagerLoadRadius]` 内已驻留的章
  /// 全部标为「最近使用」，使其免受 LRU 淘汰（窗口 ≤ 25 < 上界 30）。
  void _protectWindow(int current) {
    for (final int i in cache.loadedIndices.toList(growable: false)) {
      if ((i - current).abs() <= kEagerLoadRadius) cache.touch(i);
    }
  }
}
