// `TYP-06`：书签持久化（**每本书记一个文件**）+ `LIB-06` 连带清理。
//
// 落点：`<dataDir>/bookmarks/<bookId>.json`——**每本书独立文件**，与
// [ProgressStore]（`progress/<bookId>.json`）同构：单本损坏（由 [JsonStore]
// 隔离为 `.corrupt`）不影响其它书；删除书即删该文件（`LIB-06` 连带清理）。
//
// 文件形态：`{"bookId": …, "bookmarks": […]}`——顶层带 bookId 是**防串档**哨兵
// （与 `ReadingProgress.bookId` 同一防线）：文件内容与请求不一致时整体作废，
// 绝不把别本书的书签当成本书的。
//
// 落盘一律经 [JsonStore] → [AtomicFile]（`DATA-01` 原子写入 + 备份回退）。
// bookId 直接用作文件名，故先做**白名单校验**——防路径穿越 / 非法字符。
import 'dart:io';

import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'bookmark.dart';

/// 书签持久化服务（进程内共享，显式注入 `ReaderPage`）。
class BookmarkStore {
  BookmarkStore(this._paths);

  final AppPaths _paths;

  /// 书签子目录名（落在 `<dataDir>/bookmarks/`）。
  static const String dirName = 'bookmarks';

  /// 文件名后缀（bookId 之外的固定部分）。
  static const String _fileSuffix = '.json';

  /// 合法 bookId：只允许字母 / 数字 / `_` / `-`（SHA-256 hex 前 16 位天然满足）。
  static final RegExp _validBookId = RegExp(r'^[A-Za-z0-9_-]+$');

  /// 加载某本书的全部书签（**添加顺序**，即 `createdAt` 升序的保存顺序）。
  ///
  /// 文件缺失 / 内容损坏 / bookId 串档 → 返回**空表**（调用方按「无书签」渲染，
  /// 单条损坏的条目静默丢弃）。[bookId] 非法时抛 [ArgumentError]（调用契约错误）。
  Future<List<Bookmark>> load(String bookId) async {
    _ensureValidBookId(bookId);
    final JsonStore store = await _storeFor(bookId);
    final Object? json = await store.read();
    return parseBookmarks(json, bookId);
  }

  /// 保存某本书的全部书签（整体覆盖写，原子写入）。
  ///
  /// [bookId] 非法时抛 [ArgumentError]。
  Future<void> save(String bookId, List<Bookmark> bookmarks) async {
    _ensureValidBookId(bookId);
    final JsonStore store = await _storeFor(bookId);
    await store.write(<String, Object?>{
      'bookId': bookId,
      'bookmarks': <Object?>[
        for (final Bookmark bookmark in bookmarks) bookmark.toJson(),
      ],
    });
  }

  /// 删除某本书的书签文件（`LIB-06` 连带清理）。
  ///
  /// **幂等**：文件不存在时静默成功；连同 `.bak` / `.corrupt` / `.tmp` 兄弟文件
  /// 一并清理。[bookId] 非法时抛 [ArgumentError]。
  Future<void> remove(String bookId) async {
    _ensureValidBookId(bookId);
    final Directory dir = await _paths.subDir(dirName);
    final AtomicFile file = AtomicFile(_pathFor(dir, bookId));
    for (final String path in <String>[
      file.path,
      file.backupPath,
      file.corruptPath,
      file.tempPath,
    ]) {
      final File candidate = File(path);
      if (await candidate.exists()) {
        await candidate.delete();
      }
    }
  }

  /// 解析某本书书签文件对应的 [JsonStore]。
  Future<JsonStore> _storeFor(String bookId) async {
    final Directory dir = await _paths.subDir(dirName);
    return JsonStore(AtomicFile(_pathFor(dir, bookId)));
  }

  /// 拼接书签文件的绝对路径。
  String _pathFor(Directory dir, String bookId) =>
      '${dir.path}${Platform.pathSeparator}$bookId$_fileSuffix';

  /// 校验 bookId 合法性（白名单正则），非法即抛 [ArgumentError]。
  void _ensureValidBookId(String bookId) {
    if (!_validBookId.hasMatch(bookId)) {
      throw ArgumentError.value(
        bookId,
        'bookId',
        '非法 bookId：只允许字母 / 数字 / 下划线 / 连字符',
      );
    }
  }
}

/// 解析书签文件内容（纯函数，便于单测）。
///
/// 防御式：非 `Map` / 顶层 `bookId` 与 [bookId] 不一致（串档）→ **空表**；
/// `bookmarks` 非 `List` → 空表；单条非法 → 静默丢弃该条，其余照常。
List<Bookmark> parseBookmarks(Object? json, String bookId) {
  if (json is! Map) {
    return <Bookmark>[];
  }
  if (json['bookId'] != bookId) {
    return <Bookmark>[];
  }
  final Object? entries = json['bookmarks'];
  if (entries is! List) {
    return <Bookmark>[];
  }
  final List<Bookmark> result = <Bookmark>[];
  for (final Object? entry in entries) {
    final Bookmark? bookmark = Bookmark.fromJson(entry);
    if (bookmark != null && bookmark.bookId == bookId) {
      result.add(bookmark);
    }
  }
  return result;
}
