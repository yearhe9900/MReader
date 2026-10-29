// `LIB-03`：书库索引持久化（逐条降级：单条损坏跳过，不崩全库）。
//
// 底层走 `JsonStore` + `AtomicFile`（`DATA-01` 四态回退），索引文件为
// `library/index.json`。读出的 JSON 数组逐条解析，任何条目抛异常即跳过
// （`LIB-03` 验收要点 ②「索引写成非法内容仍能启动」）。
import 'dart:io';

import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'book_record.dart';

/// 索引文件名。
const String _indexFileName = 'index.json';

/// 索引所在子目录名。
const String _libraryDirName = 'library';

/// 书库索引：读 / 写 [BookRecord] 列表，底层经 `JsonStore` 落盘。
///
/// **逐条降级**（`LIB-03`）：[load] 逐条 try-catch，单条解析失败 → 跳过，
/// 不会因某一条损坏而导致整库无法加载。
class BookIndex {
  BookIndex(this._paths);

  final AppPaths _paths;
  JsonStore? _store;

  Future<JsonStore> _ensureStore() async {
    if (_store != null) return _store!;
    final Directory dir = await _paths.subDir(_libraryDirName);
    final String indexPath =
        '${dir.path}${Platform.pathSeparator}$_indexFileName';
    _store = JsonStore(AtomicFile(indexPath));
    return _store!;
  }

  /// 加载全部记录（无数据 / 首次运行返回空列表）；`LIB-03` 逐条降级：
  /// 每条 try-catch，失败跳过（不崩全库）。
  Future<List<BookRecord>> load() async {
    final JsonStore store = await _ensureStore();
    final Object? raw = await store.read();

    if (raw is! List) return <BookRecord>[];

    final List<BookRecord> records = <BookRecord>[];
    for (final Object? item in raw) {
      try {
        if (item is Map<String, Object?>) {
          records.add(BookRecord.fromJson(Map<String, Object?>.from(item)));
        } else {
          // 非 Map 条目（如字符串、数字）：跳过。
        }
      } catch (_) {
        // LIB-03：单条损坏跳过，不崩全库。
      }
    }
    return records;
  }

  /// 写入全量记录列表（**覆盖式**：旧内容被完全替换）。经 `AtomicFile`
  /// 原子写入，任何时刻断电都不会留下半截文件。
  Future<void> save(List<BookRecord> records) async {
    final JsonStore store = await _ensureStore();
    await store.write(
      records.map((BookRecord r) => r.toJson()).toList(),
    );
  }
}
