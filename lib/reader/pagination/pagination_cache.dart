// 分页结果缓存（T02）：**LRU 5 章 + 配置哈希失效**。
// 与 `ChapterCache`（章正文 LRU 30）分层：那边管文本常驻，这边管「该章在
// **一套排版参数**下是否已分好页」。以 `href` 为槽位、逐条校验
// [PaginationConfig]（值相等 `==`/`hashCode` 即整套排版参数哈希），
// **不匹配即整条移除**（不占 LRU 槽位）。
// 只存**完整**结果——部分结果留在进行中的 [IncrementalPaginator]，完成才落库。
import 'dart:collection';

import 'page_breaker.dart';
import 'page_paginator.dart';

/// 同时驻留的完整分页结果上界（里程碑 T02：**LRU 5 章**）。
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
  void put(PaginatedChapter chapter) {
    _entries.remove(chapter.href);
    _entries[chapter.href] = chapter;
    while (_entries.length > maxChapters) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 清空（换书 / 配置整体切换时由调度器调用）。
  void clear() => _entries.clear();
}
