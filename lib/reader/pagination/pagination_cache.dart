// 分页结果缓存：**LRU 5 章 + 配置哈希失效**。与 `ChapterCache`（章正文 LRU）分层：
// 那边管文本常驻，这边管「该章在**一套排版参数**下是否已分好页」。以 `href` 为槽位、
// 逐条校验 [PaginationConfig]，**不匹配即整条移除**（不占 LRU 槽位）。
// 只存**完整**结果——部分结果留在进行中的 [IncrementalPaginator]，完成才落库。
import 'dart:collection';

import 'page_breaker.dart';
import 'page_paginator.dart';

/// 同时驻留的完整分页结果上界（里程碑 T02：**LRU 5 章**）。
///
/// ⚠️ `maxChapters` 是**目标值**而非硬上界：[setProtected] 保护中的条目跳过淘汰
/// （正在渲染的窗口章可能多于 5 章）。理由见 [PaginationCache.setProtected]。
const int kPaginationCacheChapters = 5;

/// 一章在一套排版参数下的分页结果（缓存值 / 上屏读取单元）。
///
/// [lines] / [pages] 为**只读**引用（部分来源是进行中任务的活列表，只追加、
/// 整表替换）；调用方不得修改。
class PaginatedChapter {
  const PaginatedChapter({
    required this.href,
    required this.config,
    required this.lines,
    required this.pages,
    required this.totalChars,
    required this.complete,
  });

  /// 章标识（EPUB 的章节 href / TXT 的稳定键）。
  final String href;

  /// 产出该结果的排版参数（缓存失效校验用）。
  final PaginationConfig config;

  /// 已测量的行表（章内拼接原文空间的字符区间）。
  final List<MeasuredLine> lines;

  /// 页表；`complete == false` 时**末页可能随测量增长**，其余页已稳定。
  final List<PageSlice> pages;

  /// 章内总字数（`Σ paragraph.length`，与 `BookSource.totalCharCount()` 同口径）。
  final int totalChars;

  /// 是否全章测量完毕。
  final bool complete;

  int get pageCount => pages.length;

  /// [charOffset] 是否已有可落位的页（完整结果恒真；部分结果看末页覆盖范围）。
  bool covers(int charOffset) =>
      complete || (pages.isNotEmpty && charOffset < pages.last.end);

  @override
  String toString() =>
      'PaginatedChapter($href, $pageCount 页${complete ? '' : '/部分'})';
}

/// 分页结果的**有界 LRU** 缓存（纯 Dart，可单测）。
///
/// 与 `ChapterCache` 同款手法：`LinkedHashMap` 插入序 == 最近使用序，
/// [get] 命中提位、[put] 超界从头部淘汰。
class PaginationCache {
  PaginationCache({this.maxChapters = kPaginationCacheChapters});

  /// 同时驻留上界（构造可覆盖，便于测试用小值）。
  final int maxChapters;

  final LinkedHashMap<String, PaginatedChapter> _entries =
      LinkedHashMap<String, PaginatedChapter>();

  /// 当前驻留条目数。
  int get count => _entries.length;

  /// 已驻留的章标识（按最近使用序，末尾最新）。返回**只读视图**。
  Iterable<String> get hrefs => _entries.keys;

  /// [href] 在 [config] 下是否有结果（**不触碰** LRU 序，供入队去重判断）。
  bool has(String href, PaginationConfig config) {
    final PaginatedChapter? entry = _entries[href];
    if (entry == null) return false;
    if (entry.config != config) return false;
    return true;
  }

  /// 取 [href] 在 [config] 下的分页结果，**不触碰** LRU 序、不移除失效项
  /// （供签名计算/只读判定；写路径仍走 [get]）。
  PaginatedChapter? peek(String href, PaginationConfig config) {
    final PaginatedChapter? entry = _entries[href];
    if (entry == null || entry.config != config) return null;
    return entry;
  }

  /// 取 [href] 在 [config] 下的分页结果；命中提位，未命中/配置失效返回 `null`。
  PaginatedChapter? get(String href, PaginationConfig config) {
    final PaginatedChapter? entry = _entries[href];
    if (entry == null) return null;
    if (entry.config != config) {
      // 配置哈希失效：排版参数变了，旧页表整体作废（顺手释放 LRU 槽位）。
      _entries.remove(href);
      return null;
    }
    _entries.remove(href);
    _entries[href] = entry; // 移到末尾（最近使用）
    return entry;
  }

  /// 写入（或更新）一条**完整**结果，随后按上界淘汰最久未用者。
  ///
  /// ⚠️ **淘汰必须跳过 [setProtected] 保护集**（真机「多次开关图书章节跳动」）：
  /// 读路径（[peek]）**不参与 LRU 提位**，「谁最新」只反映分页完成顺序、与「谁正在
  /// 被渲染」无关——窗口内章数超 [maxChapters] 时被淘汰的恰是最先排完的当前章，
  /// 它被挤掉后视图静默退化为占位带 ⇒ 锚点以上布局整体塌陷一章高 ⇒ 同帧采样把
  /// 像素映射到**邻章**并落盘，每次开书漂一整章。
  /// 因此 [maxChapters] 是**目标值**而非硬上界：全在保护集时宁可暂时超界。
  void put(PaginatedChapter chapter) {
    _entries.remove(chapter.href);
    _entries[chapter.href] = chapter;
    while (_entries.length > maxChapters) {
      String? victim;
      for (final String href in _entries.keys) {
        if (!_protected.contains(href)) {
          victim = href;
          break;
        }
      }
      if (victim == null) break; // 全受保护：不淘汰正在渲染的章。
      _entries.remove(victim);
    }
  }

  /// 保护集：**正在渲染的窗口章**（`ReaderPage._applyPagedViews` 每次换视图时
  /// 同步写入）。只在淘汰时起作用，不影响 [get] / [peek] 的返回值。
  Set<String> _protected = const <String>{};

  /// 覆盖保护集（传入当前窗口的全部 href；顺序无关）。
  void setProtected(Iterable<String> hrefs) => _protected = hrefs.toSet();

  /// 当前保护集（测试观察用）。
  Set<String> get protectedHrefs => _protected;

  /// 清空（换书 / 配置整体切换时由调度器调用）。
  void clear() {
    _entries.clear();
    _protected = const <String>{};
  }
}
