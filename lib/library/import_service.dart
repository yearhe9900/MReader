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
import '../meta/cover_store.dart';
import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import 'book_record.dart';

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

  /// 导入单个文件：解析 → bookId → 复制 → 封面物化 → [BookRecord]。
  ///
  /// 不写索引（由 `LibraryRepository.importFile()` 负责）。
  /// 格式不支持时抛 [MReaderFormatException]（`RD-05`）。
  Future<BookRecord> import({
    required Uint8List bytes,
    required String fileName,
  }) async {
    // 1. 格式检测
    final FormatKind kind = sniffFormat(fileName: fileName, bytes: bytes);
    if (kind == FormatKind.unsupported) {
      throw const MReaderFormatException(FormatErrorCode.unsupportedFormat);
    }
    final String format = kind == FormatKind.epub ? 'epub' : 'txt';

    // 2. 解析元数据（`BookSource`；finally 保证 dispose，无论成功与否）
    final BookSource source = await openBook(fileName: fileName, bytes: bytes);
    final BookMeta meta;
    try {
      meta = await source.load();
    } finally {
      await source.dispose();
    }

    // 3. 内容摘要
    final String bookId = computeBookId(bytes);

    // 4. 复制文件到 library/<bookId>.<ext>（`AtomicFile` 原子写入）
    final Directory libDir = await _paths.subDir('library');
    final String destFileName = '$bookId.$format';
    final String destPath =
        '${libDir.path}${Platform.pathSeparator}$destFileName';
    await AtomicFile(destPath).writeBytes(bytes);

    // 5. 封面物化（`PendingCover` → `StoredCover`；其它类型原样保留）
    CoverRef cover = meta.cover;
    if (cover is PendingCover) {
      cover = await _coverStore.materialize(bookId: bookId, pending: cover);
    }

    // 6. 构造记录（带入 intro + 四来源标记：新导入的书来源天然正确，`META-08 ②`）
    return BookRecord(
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
    );
  }
}
