// `LIB-01~06`：书库仓库（索引 + CoverStore 的胶水层）。
//
// 本类是书架 UI 的**唯一后端**——UI 层只依赖本类的公开方法，
// 不直接访问 [BookIndex] / [ImportService] / [CoverStore]。
//
// 职责：
//   · [loadBooks]：加载全部在库书籍（`LIB-01`）；
//   · [importFile]：判重（`LIB-05`）+ 导入 + 索引更新（`LIB-02`）；
//   · [deleteBook]：副本 + 封面 + 索引连带清理（`LIB-06`）；
//   · [purgeOrphans]：孤儿封面 GC（`META-06 ③`）。
import 'dart:io';
import 'dart:typed_data';

import '../meta/cover_store.dart';
import '../model/book_meta.dart';
import '../platform/app_paths.dart';
import 'book_index.dart';
import 'book_record.dart';
import 'import_service.dart';

/// 导入结果。
class ImportResult {
  const ImportResult({required this.record, required this.isNew});

  /// 导入（或已存在）的书籍记录。
  final BookRecord record;

  /// `true` = 新导入；`false` = 已存在（`LIB-05` 判重命中）。
  final bool isNew;
}

/// 书库仓库：索引 + CoverStore + ImportService 的胶水。
class LibraryRepository {
  LibraryRepository({
    required AppPaths paths,
    required CoverStore coverStore,
  })  : _paths = paths,
        _coverStore = coverStore,
        _index = BookIndex(paths),
        _importService = ImportService(paths, coverStore);

  final AppPaths _paths;
  final CoverStore _coverStore;
  final BookIndex _index;
  final ImportService _importService;

  /// 加载全部在库书籍（`LIB-01` / `LIB-03`）。
  Future<List<BookRecord>> loadBooks() => _index.load();

  /// 导入单个文件（`LIB-02` + `LIB-05` 判重）。
  ///
  /// 同内容（bookId 相同）→ 返回已有记录 + `isNew: false`，不新增。
  /// 同名不同内容 → 可共存（bookId 不同，`LIB-05` 验收要点 ②）。
  Future<ImportResult> importFile({
    required Uint8List bytes,
    required String fileName,
  }) async {
    // 判重：同内容 → 提示「已存在」，不新增。
    final String bookId = ImportService.computeBookId(bytes);
    final List<BookRecord> existing = await _index.load();
    for (final BookRecord r in existing) {
      if (r.bookId == bookId) {
        return ImportResult(record: r, isNew: false);
      }
    }

    // 新导入（解析 → 复制 → 封面物化 → BookRecord）
    final BookRecord record = await _importService.import(
      bytes: bytes,
      fileName: fileName,
    );

    // 更新索引
    existing.add(record);
    await _index.save(existing);
    return ImportResult(record: record, isNew: true);
  }

  /// 删除一本书（`LIB-06`：副本 + 封面 + 索引条目连带清理）。
  ///
  /// **二次确认**在 UI 层（`showDialog`），本方法直接执行。
  /// 删除进度 / 书签 / 笔记 / 统计记录 在 M1-T04 / M2b 接入时连带清理。
  Future<void> deleteBook(BookRecord record) async {
    // ① 删封面（LIB-06 / META-06；NoCover / SyntheticCover 为空操作）
    await _coverStore.delete(record.cover);

    // ② 删副本文件
    final Directory libDir = await _paths.subDir('library');
    final File bookFile = File(
      '${libDir.path}${Platform.pathSeparator}${record.filePath}',
    );
    if (await bookFile.exists()) {
      await bookFile.delete();
    }

    // ③ 从索引移除
    final List<BookRecord> records = await _index.load();
    records.removeWhere((BookRecord r) => r.bookId == record.bookId);
    await _index.save(records);
  }

  /// 清理孤儿封面（`META-06 ③`）。
  ///
  /// 汇总在库书籍引用的 [StoredCover] 文件名，交给 [CoverStore.purgeOrphans]。
  Future<int> purgeOrphans() async {
    final List<BookRecord> records = await _index.load();
    final Set<String> referencedFileNames = <String>{};
    for (final BookRecord r in records) {
      if (r.cover is StoredCover) {
        referencedFileNames.add((r.cover as StoredCover).fileName);
      }
    }
    return _coverStore.purgeOrphans(referencedFileNames: referencedFileNames);
  }

  /// 读取书籍副本文件的原始字节（供打开阅读用）。
  ///
  /// 文件不存在时返回 `null`（LIB-03：文件缺失场景）。
  Future<Uint8List?> readBookBytes(BookRecord record) async {
    final Directory libDir = await _paths.subDir('library');
    final File file = File(
      '${libDir.path}${Platform.pathSeparator}${record.filePath}',
    );
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// 更新一本书的「最近阅读时间 + 已读百分比」（`RD-04` 的 `BookRecord` 侧）。
  ///
  /// 由 `ReaderPage` 在保存进度时调用。`bookId` 不在库中时**静默返回**（不报错）。
  Future<void> markRead(
    String bookId, {
    required int lastReadAt,
    required double readProgress,
  }) async {
    final List<BookRecord> records = await _index.load();
    bool found = false;
    final List<BookRecord> next = <BookRecord>[];
    for (final BookRecord r in records) {
      if (r.bookId == bookId) {
        next.add(r.copyWith(lastReadAt: lastReadAt, readProgress: readProgress));
        found = true;
      } else {
        next.add(r);
      }
    }
    if (!found) return;
    await _index.save(next);
  }
}
