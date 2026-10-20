// `LIB-02` / `LIB-05`：单个文件的导入管道（Flutter 侧：用 `dart:io` 写文件副本）。
//
// 职责：
//   1. 格式检测 + 解析元数据（`BookSource`）；
//   2. 内容摘要 SHA-256 hex 前 16 位（`LIB-05` 判重键）；
//   3. 文件副本写入 App 私有目录（`AtomicFile`，`DATA-01`）；
//   4. 封面物化（`PendingCover` → `StoredCover`，`META-06`）；
//   5. 构造 [BookRecord]（不含索引写入——由 `LibraryRepository` 管理）。
//
// **判重**在 `LibraryRepository.importFile()` 层完成（查 index），
// 本文件只管「一个文件 → 一条 BookRecord」的转换管道。
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../format/book_registry.dart';
import '../format/book_source.dart';
import '../format/chapter_text_cache.dart';
import '../format/structure_cache.dart';
import '../format/txt_outline_cache.dart';
import '../meta/cover_store.dart';
import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import 'book_record.dart';

/// 一次导入的产物：记录 + **已经解析好的书源** + 副本判据。
///
/// [source] 是「活着的」书源（结构已解析、章节表已就绪，未 dispose）：调用方要
/// 么把它交给 `BookSourcePool` 驻留（导入后立刻点开 = 零读盘零解析），要么
/// 自己 `dispose()`。**丢失引用 = 泄漏一份整本字节**，故这里刻意不用可空字段。
///
/// [cacheKey] 为 `null` = 副本 stat 失败（极端情况）：此时缓存不启用，
/// 书源仍可用，只是不走缓存加速。
class ImportOutcome {
  const ImportOutcome({
    required this.record,
    required this.source,
    required this.cacheKey,
  });

  final BookRecord record;
  final BookSource source;
  final StructureCacheKey? cacheKey;
}

/// 单个文件的导入管道。
class ImportService {
  ImportService(this._paths, this._coverStore);

  final AppPaths _paths;
  final CoverStore _coverStore;

  /// SHA-256 hex 前 16 位（`LIB-05` 内容摘要判重键）。
  ///
  /// 确定性、跨平台稳定：相同字节 → 相同 bookId。
  static String computeBookId(Uint8List bytes) {
    final Digest digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  /// 导入单个文件：检测 → bookId → **复制副本** → 缓存判据 → 解析（带缓存）→
  /// 封面物化 → [BookRecord]。
  ///
  /// ## 为什么「先复制、再解析」（2026-10-20 改，§2.108）
  ///
  /// 旧顺序是「先解析、再复制」：解析用的是**裸** `openBook`（不注入缓存），
  /// 解析结果 `load()` 完就 `dispose()` 扔掉——于是导入后的预热要**再解析一遍**，
  /// 用户点开时又是第三遍（读磁盘缓存）。
  ///
  /// 现在的顺序让**同一份解析只做一次**：
  ///   ① 副本先落盘 → ② 用刚写好的副本 stat 出缓存判据 → ③ 带缓存解析
  ///   （结构缓存写盘、后续预热/开书直接命中）。
  ///
  /// 代价：解析失败时副本已经落盘，需要显式清理（见 [_deleteQuietly]），否则留
  /// 下一个无索引引用的孤儿文件。
  ///
  /// 不写索引（由 `LibraryRepository.importFile()` 负责）。
  /// 格式不支持时抛 [MReaderFormatException]（`RD-05`）。
  Future<ImportOutcome> import({
    required Uint8List bytes,
    required String fileName,
    StructureCacheStore? structureCache,
    TxtOutlineCacheStore? txtOutlineCache,
    ChapterTextCacheStore? chapterTextCache,
  }) async {
    // 1. 格式检测
    final FormatKind kind = sniffFormat(fileName: fileName, bytes: bytes);
    if (kind == FormatKind.unsupported) {
      throw const MReaderFormatException(FormatErrorCode.unsupportedFormat);
    }
    // MOBI 系已被魔数识别但解析器未接入（`M2b-T05`）：导入即拒绝，口径区分
    // 「这是 MOBI，还没支持」与「不认识的格式」（`FMT-06` ①）。
    if (kind == FormatKind.mobi) {
      throw const MReaderFormatException(FormatErrorCode.mobiUnsupported);
    }
    // 落盘扩展名 = 格式名（`unsupported`/`mobi` 已在上方拦截，这两臂不可达）。
    final String format = switch (kind) {
      FormatKind.epub => 'epub',
      FormatKind.txt => 'txt',
      FormatKind.cbz => 'cbz',
      FormatKind.cbr => 'cbr',
      FormatKind.pdf => 'pdf',
      FormatKind.mobi => 'mobi',
      FormatKind.unsupported =>
        throw const MReaderFormatException(FormatErrorCode.unsupportedFormat),
    };

    // 2. 内容摘要
    final String bookId = computeBookId(bytes);

    // 3. 复制文件到 library/<bookId>.<ext>（`AtomicFile` 原子写入）
    final Directory libDir = await _paths.subDir('library');
    final String destFileName = '$bookId.$format';
    final String destPath =
        '${libDir.path}${Platform.pathSeparator}$destFileName';
    await AtomicFile(destPath).writeBytes(bytes);

    // 4. 缓存判据：用**刚落盘副本**的 mtime/size（`T06` 口径）
    final StructureCacheKey? cacheKey = await _keyFor(bookId, destPath);

    // 5. 解析元数据（**带缓存**：结构缓存就此写盘，预热与开书都能零解析命中）
    final BookSource source = await openBook(
      fileName: fileName,
      bytes: bytes,
      structureCache: structureCache,
      cacheKey: cacheKey,
      txtOutlineCache: txtOutlineCache,
      chapterTextCache: chapterTextCache,
    );
    final BookMeta meta;
    try {
      meta = await source.load();
    } catch (_) {
      // 解析失败：销毁源 + 清掉刚落盘的副本，绝不留无索引引用的孤儿文件。
      await source.dispose();
      await _deleteQuietly(destPath);
      rethrow;
    }

    // 6. 封面物化（`PendingCover` → `StoredCover`；其它类型原样保留）
    CoverRef cover = meta.cover;
    if (cover is PendingCover) {
      cover = await _coverStore.materialize(bookId: bookId, pending: cover);
    }

    // 7. 构造记录（带入 intro + 四来源标记：新导入的书来源天然正确，`META-08 ②`）
    return ImportOutcome(
      source: source,
      cacheKey: cacheKey,
      record: BookRecord(
        bookId: bookId,
        fileName: fileName,
        filePath: destFileName,
        title: meta.title,
        author: meta.author,
        format: format,
        cover: cover,
        importedAt: DateTime.now().millisecondsSinceEpoch,
        intro: meta.intro,
        titleOrigin: meta.titleOrigin,
        authorOrigin: meta.authorOrigin,
        introOrigin: meta.introOrigin,
        coverOrigin: meta.coverOrigin,
      ),
    );
  }

  /// 副本判据（`bookId + mtime + size`）；stat 失败 → `null`（不启用缓存）。
  Future<StructureCacheKey?> _keyFor(String bookId, String path) async {
    try {
      final FileStat stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return StructureCacheKey(
        bookId: bookId,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 清理失败静默：导入本来就失败，不再叠加新错误。
    }
  }
}
