// 分页结果缓存单测（`T02`，里程碑 §1）：LRU 5 章 + 配置哈希失效 + covers 语义。
//
// 期望值一律**硬编码字面量**（上界 5、页区间 [0,60) 都写死在断言里，
// 不引用被测常量）。缓存本身不排版，但 [PaginationConfig] 带 [TextStyle]，
// 需要 flutter 环境。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/pagination_cache.dart';

void main() {
  const TextStyle base = TextStyle(fontSize: 18, height: 1.6);
  const PaginationConfig cfg1 =
      PaginationConfig(pageWidth: 180, pageHeight: 200, textStyle: base);
  const PaginationConfig cfg2 =
      PaginationConfig(pageWidth: 180, pageHeight: 300, textStyle: base);

  PaginatedChapter ch(String href, {PaginationConfig? config, bool complete = true}) {
    return PaginatedChapter(
      href: href,
      config: config ?? cfg1,
      lines: const <MeasuredLine>[],
      pages: const <PageSlice>[
        PageSlice(index: 0, start: 0, end: 60, height: 174, firstLine: 0, lineCount: 6),
      ],
      totalChars: 100,
      complete: complete,
    );
  }

  group('LRU 上界与提位', () {
    test('默认上界 5 章：第 6 条挤掉最久未用者', () {
      final PaginationCache cache = PaginationCache();
      for (int i = 0; i < 6; i++) {
        cache.put(ch('c$i'));
      }
      expect(cache.count, 5);
      expect(cache.hrefs.toList(), <String>['c1', 'c2', 'c3', 'c4', 'c5']);
    });

    test('get 命中提位到队尾', () {
      final PaginationCache cache = PaginationCache(maxChapters: 3);
      cache
        ..put(ch('A'))
        ..put(ch('B'))
        ..put(ch('C'));
      expect(cache.get('A', cfg1), isNotNull); // 提位：[A,B,C] → [B,C,A]
      cache.put(ch('D'));
      expect(cache.count, 3);
      expect(cache.hrefs.toList(), <String>['C', 'A', 'D']); // B 最久未用被挤掉
      expect(cache.get('B', cfg1), isNull);
    });

    test('put 已存在 href = 更新并提位（不占两个槽）', () {
      final PaginationCache cache = PaginationCache(maxChapters: 2);
      cache
        ..put(ch('A'))
        ..put(ch('B'));
      cache.put(ch('A')); // 更新 A → 提位
      expect(cache.count, 2);
      expect(cache.hrefs.toList(), <String>['B', 'A']);
    });

    test('has 只读不提位（供入队去重判断，不动 LRU 序）', () {
      final PaginationCache cache = PaginationCache(maxChapters: 2);
      cache
        ..put(ch('A'))
        ..put(ch('B'));
      expect(cache.has('A', cfg1), isTrue);
      expect(cache.hrefs.toList(), <String>['A', 'B']); // 序未变
      cache.put(ch('C'));
      expect(cache.hrefs.toList(), <String>['B', 'C']); // A 仍是最久未用，被挤掉
    });

    test('clear 清空（换书/换参数整体作废）', () {
      final PaginationCache cache = PaginationCache();
      cache
        ..put(ch('A'))
        ..put(ch('B'));
      cache.clear();
      expect(cache.count, 0);
      expect(cache.hrefs.toList(), isEmpty);
      expect(cache.get('A', cfg1), isNull);
    });
  });

  group('配置哈希失效', () {
    test('config 不匹配：get 返回 null 且整条移除（释放槽位）', () {
      final PaginationCache cache = PaginationCache();
      cache.put(ch('A', config: cfg1));
      expect(cache.get('A', cfg2), isNull);
      expect(cache.count, 0); // 连槽位一起释放
      expect(cache.get('A', cfg1), isNull); // 旧配置条目已不在
    });

    test('has 对不匹配 config 返回 false 但不移除（不触碰）', () {
      final PaginationCache cache = PaginationCache();
      cache.put(ch('A', config: cfg1));
      expect(cache.has('A', cfg2), isFalse);
      expect(cache.count, 1); // has 不做失效清除
      expect(cache.has('A', cfg1), isTrue);
    });
  });

  group('PaginatedChapter.covers 语义', () {
    test('完整结果：任意偏移可落位', () {
      final PaginatedChapter full = ch('A');
      expect(full.complete, isTrue);
      expect(full.pageCount, 1);
      expect(full.covers(0), isTrue);
      expect(full.covers(59), isTrue);
      expect(full.covers(60), isTrue);
      expect(full.covers(99999), isTrue);
    });

    test('部分结果：只信末页覆盖范围（末页可增长）', () {
      final PaginatedChapter partial = ch('A', complete: false);
      expect(partial.covers(0), isTrue);
      expect(partial.covers(59), isTrue);
      expect(partial.covers(60), isFalse); // 末页 end=60 不含 60
      expect(partial.covers(99999), isFalse);
    });
  });
}
