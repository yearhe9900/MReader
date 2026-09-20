// 书源（JSON）导入解析。
//
// 对照参考实现 `legado_flutter-2026/lib/services/source/book_source_parser.dart`，
// 保留它的三条主张（Isolate 解析、单条失败不影响整体、必填字段校验），
// 并补三件它没做的事：
//   1. **记录失败原因**：它对每条脏数据 `continue` 掉且不留下任何痕迹，
//      用户导入 300 条源少 5 条无从查起。这里把「第几条、哪个 key、什么错」留下来。
//   2. **按 bookSourceUrl 去重**：合并导出的书源文件里重复条目很常见。
//   3. **吃下两种根结构**：`[{...}]`、`{...}`，以及 `{"bookSources": [...]}`
//      这种被别的工具包了一层的写法。
//
// 不依赖 Flutter（`compute` 来自 flutter/foundation，所以异步入口单独用条件导入隔离 ——
// 见文件末尾的说明；本文件只依赖 dart:convert，保持可在纯 Dart 下单测）。

import 'dart:convert';

import 'book_source.dart';

/// 一条被跳过的原始记录。
class SkippedRecord {
  const SkippedRecord({
    required this.index,
    required this.reason,
    this.preview = '',
  });

  /// 在原数组里的下标（单对象根结构恒为 0）。
  final int index;

  /// 跳过原因（人话）。
  final String reason;

  /// 该记录的简要预览，便于定位（通常是 bookSourceUrl 或前几个键）。
  final String preview;

  @override
  String toString() => '第 $index 条：$reason${preview.isEmpty ? '' : '（$preview）'}';
}

/// 导入解析结果。
class BookSourceImportResult {
  const BookSourceImportResult({
    required this.sources,
    required this.skipped,
    required this.rawCount,
    required this.duplicateCount,
  });

  /// 解析成功的书源（已去重）。
  final List<BookSource> sources;

  /// 被跳过的记录。
  final List<SkippedRecord> skipped;

  /// 原始记录数（去重、跳过之前）。
  final int rawCount;

  /// 因 `bookSourceUrl` 重复而被合并掉的条数。
  final int duplicateCount;

  /// 是否解析成功（至少拿到一条）。
  bool get isEmpty => sources.isEmpty;

  /// 一行摘要，适合直接 toast / 显示在列表顶部。
  String get summary {
    final StringBuffer buffer = StringBuffer('解析 $rawCount 条');
    buffer.write('，成功 ${sources.length} 条');
    if (duplicateCount > 0) buffer.write('，去重 $duplicateCount 条');
    if (skipped.isNotEmpty) buffer.write('，跳过 ${skipped.length} 条');
    return buffer.toString();
  }

  @override
  String toString() => 'BookSourceImportResult($summary)';
}

/// [BookSourceParser._flatten] 的结果：可用的记录 + 原始条数。
class _Flattened {
  const _Flattened(this.items, this.total);

  /// 能当书源继续处理的记录。
  final List<Map<String, dynamic>> items;

  /// JSON 里实际出现的记录条数（含被跳过的）。
  final int total;
}

/// 书源导入解析器。
class BookSourceParser {
  /// 从 JSON 文本解析书源。
  ///
  /// **不抛异常**：JSON 语法错误也会被转成「0 条成功 + 1 条 skipped」的结果，
  /// 由调用方决定怎么提示。
  static BookSourceImportResult parse(String jsonText) {
    final List<SkippedRecord> skipped = <SkippedRecord>[];

    // ---- 1. 解出根结构 ----
    Object? root;
    try {
      root = jsonDecode(jsonText);
    } on FormatException catch (error) {
      return BookSourceImportResult(
        sources: const <BookSource>[],
        skipped: <SkippedRecord>[
          SkippedRecord(
            index: 0,
            reason: 'JSON 语法错误：${error.message}'
                '（偏移 ${error.offset}）',
          ),
        ],
        rawCount: 0,
        duplicateCount: 0,
      );
    }

    final _Flattened flattened = _flatten(root, skipped);

    // ---- 2. 逐条转模型 ----
    final List<BookSource> parsed = <BookSource>[];
    final Set<String> seen = <String>{};
    int duplicateCount = 0;

    final List<Map<String, dynamic>> rawItems = flattened.items;
    for (int i = 0; i < rawItems.length; i++) {
      final Map<String, dynamic> item = rawItems[i];
      final String preview = _previewOf(item);

      BookSource source;
      try {
        source = BookSource.fromJson(item);
      } catch (error) {
        skipped.add(SkippedRecord(
          index: i,
          reason: '字段解析异常：$error',
          preview: preview,
        ));
        continue;
      }

      // 必填校验：bookSourceUrl 为空的书源无法使用（也是 legado 的唯一标识）
      if (source.bookSourceUrl.isEmpty) {
        skipped.add(SkippedRecord(
          index: i,
          reason: '缺少 bookSourceUrl（书源的唯一标识，必填）',
          preview: preview,
        ));
        continue;
      }

      // 去重：同地址只保留先出现的那条
      if (!seen.add(source.bookSourceUrl)) {
        duplicateCount++;
        continue;
      }

      parsed.add(source);
    }

    return BookSourceImportResult(
      sources: List<BookSource>.unmodifiable(parsed),
      skipped: List<SkippedRecord>.unmodifiable(skipped),
      // 用摊平时数到的**原始条数**，而不是「成功转成 Map 的条数」——
      // 否则 `[1,"x",{...}]` 会显示成「解析 1 条，跳过 2 条」，对不上账。
      rawCount: flattened.total,
      duplicateCount: duplicateCount,
    );
  }

  /// 把各种根结构摊平成「一串 Map」，同时数出原始记录条数。
  ///
  /// 支持：`[{...}]`、`{...}`、`{"bookSources": [...]}`（外层被包了一层）。
  static _Flattened _flatten(
    Object? root,
    List<SkippedRecord> skipped,
  ) {
    if (root is List) {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
      for (int i = 0; i < root.length; i++) {
        final Object? element = root[i];
        if (element is Map) {
          items.add(element.map(
            (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
          ));
        } else {
          skipped.add(SkippedRecord(
            index: i,
            reason: '该元素不是对象（实际是 ${element.runtimeType}），书源项应为 JSON 对象',
          ));
        }
      }
      return _Flattened(items, root.length);
    }

    if (root is Map) {
      // 被包了一层：找第一个值是数组的键
      for (final Object? value in root.values) {
        if (value is List) {
          return _flatten(value, skipped);
        }
      }
      return _Flattened(
        <Map<String, dynamic>>[
          root.map(
            (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
          ),
        ],
        1,
      );
    }

    skipped.add(SkippedRecord(
      index: 0,
      reason: 'JSON 根节点既不是数组也不是对象（实际是 ${root.runtimeType}）',
    ));
    return const _Flattened(<Map<String, dynamic>>[], 0);
  }

  /// 给一条记录做简要预览，便于用户定位到具体是哪个源出的问题。
  static String _previewOf(Map<String, dynamic> item) {
    final Object? url = item['bookSourceUrl'];
    if (url is String && url.isNotEmpty) return url;
    final Object? name = item['bookSourceName'];
    if (name is String && name.isNotEmpty) return name;
    final List<String> keys = item.keys.take(3).toList(growable: false);
    return keys.isEmpty ? '（空对象）' : '键：${keys.join(', ')}';
  }
}
