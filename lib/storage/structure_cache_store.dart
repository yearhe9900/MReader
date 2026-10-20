// M-PAGE `T06`：结构缓存的磁盘实现（`DATA-01` 通道）。
//
// 文件布局：`subDir('structure')/<bookId>.bin`（bookId = SHA-256 前 16 hex，
// 文件名安全）。信封（magic + schema + 判据 + 结构）的编解码在纯层
// `lib/format/structure_cache.dart`——本文件只管 IO，不懂结构语义。
//
// ## 为什么是二进制 + `AtomicFile` 而不是 `JsonStore`（2026-10-20，§2.107）
//
// 结构缓存是**开书关键路径**上的读取方：JSON 文本解码要在主 isolate 重建上千个
// 中间对象（探针实测 15MB / 471 章真实书 ≈ 17ms 桌面，真机更要翻几倍），
// 而这份数据本来就是「写一次、读很多次」的纯数据。改成紧凑二进制后解码只做
// 「顺序读 + 直接建对象」，不再有中间树。
//
// 原子写 / 损坏隔离仍然保留（`DATA-01` ②）：写入走 `AtomicFile`（tmp → flush →
// 轮转 .bak → rename）；读出解码失败时把文件轮转成 `.corrupt`，绝不静默吞掉坏文件。
import 'dart:io';
import 'dart:typed_data';

import '../epub/epub_parser.dart';
import '../format/structure_cache.dart';
import '../platform/app_paths.dart';
import 'atomic_file.dart';

/// 按 `AppPaths.subDir('structure')` 落盘的结构缓存。
class FileStructureCacheStore implements StructureCacheStore {
  FileStructureCacheStore(AppPaths paths) : _paths = paths;

  final AppPaths _paths;

  Future<AtomicFile> _fileFor(String bookId) async {
    final Directory dir = await _paths.subDir('structure');
    return AtomicFile('${dir.path}${Platform.pathSeparator}$bookId.bin');
  }

  /// 旧版（v1 JSON 信封）文件路径——升级后顺手回收，避免留一堆死重量。
  Future<AtomicFile> _legacyJsonFileFor(String bookId) async {
    final Directory dir = await _paths.subDir('structure');
    return AtomicFile('${dir.path}${Platform.pathSeparator}$bookId.json');
  }

  @override
  Future<EpubStructure?> read(StructureCacheKey key) async {
    final AtomicFile file = await _fileFor(key.bookId);
    final Uint8List? blob = await _readOrNull(file);
    if (blob == null) return null;
    final StructureDecodeResult result =
        decodeStructureEnvelopeDetailed(blob, key: key);
    if (result.isHit) return result.structure;
    // 按 `DATA-01` ②：只有**真损坏**才隔离留证；判据失效（副本被替换 / 版本升级）
    // 是正常失效，隔离它只会在磁盘上堆垃圾。
    if (result.status == StructureDecodeStatus.corrupted) {
      await _quarantine(file);
    }
    return null;
  }

  @override
  Future<void> write(StructureCacheKey key, EpubStructure structure) async {
    final AtomicFile file = await _fileFor(key.bookId);
    await file.writeBytes(encodeStructureEnvelope(key, structure));
    await _deleteLegacy(key.bookId);
  }

  @override
  Future<void> delete(String bookId) async {
    // 清理语义：主文件 + 轮转备份 + 损坏隔离 + 残留临时文件，一并回收；
    // best-effort——单个文件删不掉不抛（调用方是连带清理链，不该因此失败）。
    for (final String suffix in <String>['', '.bak', '.corrupt', '.tmp']) {
      await _deleteQuietly(await _fileFor(bookId), suffix);
    }
    await _deleteLegacy(bookId);
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<Uint8List?> _readOrNull(AtomicFile file) async {
    try {
      final List<int>? bytes = await file.readBytes();
      if (bytes == null || bytes.isEmpty) {
        // 主文件缺失：尝试上一份有效副本（`DATA-01` ①的 .bak 回退）。
        if (!await file.hasBackup()) return null;
        return await File(file.backupPath).readAsBytes();
      }
      return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    } catch (_) {
      return null; // IO 故障当 miss
    }
  }

  /// 把无法解析的主文件轮转成 `.corrupt`（`DATA-01` ② 留证 + 下次写入自愈）。
  Future<void> _quarantine(AtomicFile file) async {
    try {
      final File corrupt = File(file.corruptPath);
      if (await corrupt.exists()) await corrupt.delete();
      await File(file.path).rename(file.corruptPath);
    } catch (_) {
      // 隔离失败静默（缓存是加速层）。
    }
  }

  Future<void> _deleteQuietly(AtomicFile file, String suffix) async {
    try {
      final File f = File('${file.path}$suffix');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _deleteLegacy(String bookId) async {
    try {
      final AtomicFile legacy = await _legacyJsonFileFor(bookId);
      for (final String suffix in <String>['', '.bak', '.corrupt', '.tmp']) {
        await _deleteQuietly(legacy, suffix);
      }
    } catch (_) {}
  }
}
