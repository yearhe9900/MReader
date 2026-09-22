// `RD-04`：阅读进度持久化（**每本书记一个文件**）。
//
// 落点：`<dataDir>/progress/<bookId>.json`——**每本书独立文件**，好处有二：
//   · 单本损坏（由 [JsonStore] 隔离为 `.corrupt`）不影响其它书；
//   · 删除书即删该文件（`LIB-06` 连带清理，见 `shelf_page._deleteBook`）。
//
// 落盘一律经 [JsonStore] → [AtomicFile]（`DATA-01` 原子写入 + 备份回退）。
// bookId 直接用作文件名，故先做**白名单校验**——防路径穿越 / 非法字符。
import 'dart:io';

import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'reading_progress.dart';

/// 阅读进度持久化服务（进程内共享，显式注入 `ReaderPage`）。
class ProgressStore {
  ProgressStore(this._paths);

  final AppPaths _paths;

  /// 进度子目录名（落在 `<dataDir>/progress/`）。
  static const String dirName = 'progress';

  /// 文件名后缀（bookId 之外的固定部分）。
  static const String _fileSuffix = '.json';

  /// 合法 bookId：只允许字母 / 数字 / `_` / `-`（SHA-256 hex 前 16 位天然满足）。
  static final RegExp _validBookId = RegExp(r'^[A-Za-z0-9_-]+$');

  /// 加载某本书的进度。
  ///
  /// 文件缺失 / 内容损坏 / bookId 不匹配 → 返回 `null`（调用方回落到第 1 章开头）。
  /// [bookId] 非法时抛 [ArgumentError]（调用契约错误，不是运行期数据问题）。
  Future<ReadingProgress?> load(String bookId) async {
    _ensureValidBookId(bookId);
    final JsonStore store = await _storeFor(bookId);
    final Object? json = await store.read();
    final ReadingProgress? progress = ReadingProgress.fromJson(json);
    if (progress == null) {
      return null;
    }
    // 防串档：文件内容里的 bookId 必须与请求一致。
    if (progress.bookId != bookId) {
      return null;
    }
    return progress;
  }

  /// 保存某本书的进度（原子写入）。
  ///
  /// [bookId] 非法时抛 [ArgumentError]。
  Future<void> save(ReadingProgress progress) async {
    _ensureValidBookId(progress.bookId);
    final JsonStore store = await _storeFor(progress.bookId);
    await store.write(progress.toJson());
  }

  /// 删除某本书的进度文件（`LIB-06` 连带清理）。
  ///
  /// **幂等**：文件不存在时静默成功；连同 `.bak` / `.corrupt` / `.tmp` 兄弟文件一并清理。
  /// [bookId] 非法时抛 [ArgumentError]。
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

  /// 解析某本书进度文件对应的 [JsonStore]。
  Future<JsonStore> _storeFor(String bookId) async {
    final Directory dir = await _paths.subDir(dirName);
    return JsonStore(AtomicFile(_pathFor(dir, bookId)));
  }

  /// 拼接进度文件的绝对路径。
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
