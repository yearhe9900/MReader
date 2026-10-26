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

import '../format/book_source.dart';
import '../format/book_instance_key.dart';
import '../format/rust_kernel_source.dart';
import '../format/book_source_pool.dart';
import '../meta/cover_store.dart';
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

  /// **已解析书源复用池**（§2.108）：导入即入池、关书回池，同一本书再开时零读盘零解析。
  late final BookSourcePool _sourcePool = BookSourcePool();

  /// 复用池（测试观察 / 清场用）。
  BookSourcePool get sourcePool => _sourcePool;

  /// 取池中「已解析好的书源」（命中即**独占取走**）。[key] 是开书当场 stat 出来的
  /// 判据：与池内条目不符（文件被替换）→ 当 miss 并就地销毁旧条目；返回 `null` =
  /// 走完整冷路径（读字节 + 建源）。
  BookSource? takePooledSource(BookRecord record, BookInstanceKey? key) =>
      _sourcePool.take(record.bookId, key);

  /// 把一个书源交回池（阅读页关闭 / 预热收尾时调用）。内部重新 stat 取判据：文件已删 /
  /// 不可读 → 直接销毁，不入池；不满足驻留条件时 [BookSourcePool.put] 内部会销毁它，
  /// 故本方法**恒不泄漏**——调用方不需要再自己 dispose。
  Future<void> recycleBookSource(BookRecord record, BookSource source) async {
    final BookInstanceKey? key = await bookInstanceKey(record);
    _sourcePool.put(record.bookId, key, source);
  }

  /// 加载全部在库书籍（`LIB-01` / `LIB-03`）。
  Future<List<BookRecord>> loadBooks() => _index.load();

  /// 导入单个文件（`LIB-02` + `LIB-05` 判重）：同内容（bookId 相同）→ 返回已有记录
  /// + `isNew: false`，不新增；同名不同内容 → 可共存（`LIB-05` 验收要点 ②）。
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

    // 新导入（复制副本 → 带缓存解析 → 封面物化 → BookRecord）
    final ImportOutcome outcome = await _importService.import(
      bytes: bytes,
      fileName: fileName,
    );
    final BookRecord record = outcome.record;

    existing.add(record);
    await _index.save(existing);
    // **导入即入池**（§2.108）：刚解析好的书源直接驻留，导入完立刻点开 =
    // 零读盘、零解析（章节表都是现成的）。`put` 超限 / 不可驻留时会自己
    // dispose，这里恒不泄漏。
    _sourcePool.put(record.bookId, outcome.cacheKey, outcome.source);
    return ImportResult(record: record, isNew: true);
  }

  /// 删除一本书（`LIB-06`：副本 + 封面 + 索引条目连带清理）。**二次确认**在 UI 层
  /// （`showDialog`），本方法直接执行。删除进度 / 书签 / 笔记 / 统计记录接入后连带清理。
  Future<void> deleteBook(BookRecord record) async {
    // ⓪ 丢弃复用池里的驻留源（§2.108）：书都要删了，没必要再占一份内存；
    //    也杜绝「删完又从池里打开」这条不该存在的路径。取出后顺手用它的**内容
    //    哈希**把内核内容缓存整本失效（不留「删完还留着缓存条目」的孤儿；
    //    不在池里的书没有哈希来源，等清缓存目录时一并回收）。
    final BookSource? pooled = _sourcePool.remove(record.bookId);
    if (pooled != null) {
      if (pooled is RustKernelSource) {
        RustKernelSource.invalidateContentCache(pooled.contentHash);
      }
      await pooled.dispose();
    }

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

  /// 清理孤儿封面（`META-06 ③`）：汇总在库书籍引用的 [StoredCover] 文件名，
  /// 交给 [CoverStore.purgeOrphans]。
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

  /// 读取书籍副本文件的原始字节（供打开阅读用）；文件不存在 / 不可读时返回 `null`
  /// （`LIB-03` 文件缺失场景）。
  Future<Uint8List?> readBookBytes(BookRecord record) async {
    final File file = await bookFile(record);
    // 省掉一次 `exists()` 往返（开书关键路径）：直接读、按异常判定缺失。
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      return null; // 文件缺失 / 不可读 → 与「不存在」同口径（`LIB-03`）
    }
  }

  /// 书籍副本文件句柄（**不要求存在**——`SYNC-05` 下载补齐时按同一路径落盘）。
  /// 命名与 [readBookBytes] / [deleteBook] 同一路径口径：`library/{filePath}`；
  /// 上传与下载以 `filePath` 的 basename 为远端名（引擎内净化），两台设备导入同一
  /// 文件时同名 → 跨设备可对上（同内容不同文件名时以先传者为准）。
  Future<File> bookFile(BookRecord record) async {
    final Directory libDir = await _paths.subDir('library');
    return File(
      '${libDir.path}${Platform.pathSeparator}${record.filePath}',
    );
  }

  /// 取某本书的副本判据（`bookId` + library 副本 mtime/size，复用池条目 key）：
  /// 副本缺失 → `null`（调用方按「不入池」处理）；只 `stat` 不读内容——判据不含
  /// 字节（`PERF-02`）。
  Future<BookInstanceKey?> bookInstanceKey(BookRecord record) async {
    final File file = await bookFile(record);
    // 一次 `stat` 拿全（mtime + size）——本方法在**开书关键路径**上与读字节串行；
    // 文件不存在时 `stat()` 不抛，返回 `type == notFound` 的 FileStat。
    try {
      final FileStat stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return BookInstanceKey(
        bookId: record.bookId,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
      );
    } on FileSystemException {
      return null; // 不可读 → 按「不启用缓存」处理
    }
  }

  /// library 副本文件大小（字节；`META-08` 详情页「文件大小」展示用）。文件不存在时
  /// 返回 `null`（`LIB-03` 文件缺失场景）；只 `stat` 不读内容——大书展示大小不把整本
  /// 书读进内存（`PERF-02`）。
  Future<int?> bookFileSize(BookRecord record) async {
    final File file = await bookFile(record);
    try {
      final FileStat stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return stat.size;
    } on FileSystemException {
      return null;
    }
  }

  /// 更新一本书的「最近阅读时间 + 已读百分比」（`RD-04` 的 `BookRecord` 侧）：由
  /// `ReaderPage` 在保存进度时调用；`bookId` 不在库中时**静默返回**（不报错）。
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

  /// 用 [record] 整体替换索引中的同 `bookId` 条目（`META-09` 编辑 / 恢复自动值落盘）。
  /// 走既有 `_index.load` → 替换 → `save` 模式（同 [markRead]）；`bookId` 不在库中时
  /// **静默返回**（不报错、不新增）。UI 层只依赖本类，**不直接触碰 [BookIndex]**（架构既有规则）。
  Future<void> updateRecord(BookRecord record) async {
    final List<BookRecord> records = await _index.load();
    bool found = false;
    final List<BookRecord> next = <BookRecord>[];
    for (final BookRecord r in records) {
      if (r.bookId == record.bookId) {
        next.add(record);
        found = true;
      } else {
        next.add(r);
      }
    }
    if (!found) return;
    await _index.save(next);
  }
}
