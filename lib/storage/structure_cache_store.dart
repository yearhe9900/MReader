// M-PAGE `T06`：结构缓存的磁盘实现（`DATA-01` 通道）。
//
// 文件布局：`subDir('structure')/<bookId>.json`（bookId = SHA-256 前 16 hex，
// 文件名安全）。信封（schema + 判据 + 结构）的编解码在纯层
// `lib/format/structure_cache.dart`——本文件只管 IO，不懂结构语义。
//
// 读写全走 [JsonStore]（原子写 + 损坏隔离 `.corrupt` + `.bak` 自愈）；
// 解析层语义（判据不符 → miss）由 [decodeStructureEnvelope] 给出。
import 'dart:io';

import '../epub/epub_parser.dart';
import '../format/structure_cache.dart';
import '../platform/app_paths.dart';
import 'atomic_file.dart';
import 'json_store.dart';

/// 按 `AppPaths.subDir('structure')` 落盘的结构缓存。
class FileStructureCacheStore implements StructureCacheStore {
  FileStructureCacheStore(AppPaths paths) : _paths = paths;

  final AppPaths _paths;

  Future<AtomicFile> _fileFor(String bookId) async {
    final Directory dir = await _paths.subDir('structure');
    return AtomicFile('${dir.path}${Platform.pathSeparator}$bookId.json');
  }

  @override
  Future<EpubStructure?> read(StructureCacheKey key) async {
    final JsonStore store = JsonStore(await _fileFor(key.bookId));
    // JsonStore 语义：无数据 / 损坏不可回退 → null；损坏可回退 → 取 .bak。
    // 之后再由信封层比对判据（schema / mtime / size）——不符同样 miss。
    return decodeStructureEnvelope(await store.read(), key: key);
  }

  @override
  Future<void> write(StructureCacheKey key, EpubStructure structure) async {
    final JsonStore store = JsonStore(await _fileFor(key.bookId));
    await store.write(encodeStructureEnvelope(key, structure));
  }

  @override
  Future<void> delete(String bookId) async {
    // 清理语义：主文件 + 轮转备份 + 损坏隔离 + 残留临时文件，一并回收；
    // best-effort——单个文件删不掉不抛（调用方是连带清理链，不该因此失败）。
    try {
      final AtomicFile file = await _fileFor(bookId);
      for (final String path in <String>[
        file.path,
        file.backupPath,
        file.corruptPath,
        file.tempPath,
      ]) {
        final File f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (_) {
      // 清理失败静默（缓存文件本就是可再生的加速层数据）。
    }
  }
}
