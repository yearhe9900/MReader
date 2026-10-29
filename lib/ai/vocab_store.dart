// 生词本持久化（`AI-03` ②「存入生词本后退出重进仍在」）。
//
// 形制与其它 store 同款（勿改）：进程内共享实例 + 监听回调，落盘经
// [JsonStore] → [AtomicFile]（`DATA-01` 原子写入）；实例在 `main()` 创建注入。
//
// 全局一份 `vocab.json`（生词与书无关地聚合存放；条目自带 bookId /
// chapterHref / paraIndex 供跳回原文——`AI-03` ③）。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 一条生词（不可变值对象）。
class VocabEntry {
  VocabEntry({
    required this.id,
    required this.word,
    required this.meaning,
    required this.bookId,
    required this.bookTitle,
    required this.chapterHref,
    required this.paraIndex,
    required this.createdAt,
  });

  /// 稳定 id（[VocabStore.newId] 派生；删除按 id）。
  final String id;

  /// 选中的词 / 短语。
  final String word;

  /// 释义（生成时的快照——重生成不回写）。
  final String meaning;

  /// 所在书 bookId（跳回原文用）。
  final String bookId;

  /// 所在书书名（列表展示）。
  final String bookTitle;

  /// 所在章 href（跳回原文用）。
  final String chapterHref;

  /// 章内段落下标（跳回原文用）。
  final int paraIndex;

  /// 收录时间。
  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'word': word,
        'meaning': meaning,
        'bookId': bookId,
        'bookTitle': bookTitle,
        'chapterHref': chapterHref,
        'paraIndex': paraIndex,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  /// 由持久化 JSON 还原；结构异常返 null（坏条目由 store 跳过）。
  static VocabEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? id = json['id'];
    final Object? word = json['word'];
    final Object? meaning = json['meaning'];
    final Object? bookId = json['bookId'];
    final Object? chapterHref = json['chapterHref'];
    if (id is! String ||
        id.isEmpty ||
        word is! String ||
        meaning is! String ||
        bookId is! String ||
        chapterHref is! String) {
      return null;
    }
    final Object? createdAt = json['createdAt'];
    return VocabEntry(
      id: id,
      word: word,
      meaning: meaning,
      bookId: bookId,
      bookTitle: json['bookTitle'] is String
          ? json['bookTitle'] as String
          : '',
      chapterHref: chapterHref,
      paraIndex: json['paraIndex'] is num
          ? (json['paraIndex'] as num).toInt()
          : 0,
      createdAt: createdAt is num
          ? DateTime.fromMillisecondsSinceEpoch(createdAt.toInt())
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 生词本存储（进程内共享，显式注入）。
class VocabStore {
  VocabStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}vocab.json',
          ),
        );

  final JsonStore _store;
  List<VocabEntry> _entries = <VocabEntry>[];
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 全部生词快照（只读；新收录在前按 [createdAt] 由页面排序）。
  List<VocabEntry> get entries => List<VocabEntry>.unmodifiable(_entries);

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 新 id（微秒时间戳 base36，进程内稳定唯一）。
  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// 从磁盘加载；文件缺失或损坏回退空表。
  Future<void> load() async {
    final Object? json = await _store.read();
    final List<VocabEntry> next = <VocabEntry>[];
    if (json is List) {
      for (final Object? item in json) {
        final VocabEntry? entry = VocabEntry.fromJson(item);
        if (entry != null) next.add(entry);
      }
    }
    _entries = next;
    _loaded = true;
    _notify();
  }

  /// 收录一条生词（同 id 覆盖，语义幂等）。
  Future<void> add(VocabEntry entry) {
    final List<VocabEntry> next = List<VocabEntry>.of(_entries);
    final int i = next.indexWhere((VocabEntry e) => e.id == entry.id);
    if (i >= 0) {
      next[i] = entry;
    } else {
      next.insert(0, entry);
    }
    return _update(next);
  }

  /// 删除一条（按 id；不存在静默）。
  Future<void> remove(String id) {
    final List<VocabEntry> next = List<VocabEntry>.of(_entries)
      ..removeWhere((VocabEntry e) => e.id == id);
    if (next.length == _entries.length) return Future<void>.value();
    return _update(next);
  }

  /// 订阅变更。
  void addListener(void Function() listener) => _listeners.add(listener);

  /// 退订变更。
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// 更新内存 → 通知 → 原子落盘。
  Future<void> _update(List<VocabEntry> next) async {
    _entries = next;
    _notify();
    await _store.write(<Object?>[
      for (final VocabEntry e in _entries) e.toJson(),
    ]);
  }

  /// 通知所有监听者（遍历副本，容忍回调内订阅 / 退订）。
  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
