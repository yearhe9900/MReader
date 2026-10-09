// 章正文缓存的磁盘实现（`DATA-01` 通道）：追加式 blob + 索引信封。
//
// 文件布局（`subDir('chapters')/`）：
//   · `<bookId>.index.json` —— 索引信封（schema + 判据 + 章 → blob 字节区间），
//     编解码在纯层 `lib/format/chapter_text_cache.dart`；
//   · `<bookId>.blob` —— 各章负载（UTF-8 JSON 段落表）的**顺序拼接**。
//
// ## 为什么是 blob + 索引而不是一章一文件
//
// 1152 章的书若一章一文件，导入预热会一次产上千个小文件（删书要清一整个目录）；
// blob + 索引文件数恒定 2，按章读 = 一次 `RandomAccessFile` 切片，与章节总量无关。
//
// ## 一致性口径
//
// · **写 = 先追加 blob、再原子写索引**：索引只引用**完整落盘**的块，中途崩溃最多
//   留一段无人引用的尾部垃圾（下一次重置时回收），不会读到半截负载；
// · **同一章重写 = 追加新块 + 换区间**：旧字节留作垃圾（同上回收）；
// · **同一本书的写入串行化**（Future 链）：blob 是追加式的，并发交错会把区间写花；
// · **判据失效（bookId/mtime/size 任一变）→ 整体重置**：首次写清空索引并截断
//   blob，绝不让旧文件的字节混进新判据的区间表；
// · 读写失败一律当 miss / 静默（缓存是加速层），调用方（两个源的 `content()`）
//   自有回落路径。
import 'dart:io';

import '../format/chapter_text_cache.dart';
import '../format/structure_cache.dart';
import '../platform/app_paths.dart';
import 'atomic_file.dart';
import 'json_store.dart';

/// 按 `AppPaths.subDir('chapters')` 落盘的章正文缓存。
class FileChapterTextCacheStore implements ChapterTextCacheStore {
  FileChapterTextCacheStore(AppPaths paths) : _paths = paths;

  final AppPaths _paths;

  /// 每本书一份内存态（索引 + 写串行链）；单实例生命周期 = 进程（书库持有）。
  final Map<String, _BookCache> _books = <String, _BookCache>{};

  Future<AtomicFile> _indexFileFor(String bookId) async {
    final Directory dir = await _paths.subDir('chapters');
    return AtomicFile('${dir.path}${Platform.pathSeparator}$bookId.index.json');
  }

  Future<File> _blobFileFor(String bookId) async {
    final Directory dir = await _paths.subDir('chapters');
    return File('${dir.path}${Platform.pathSeparator}$bookId.blob');
  }

  @override
  Future<List<String>?> read(StructureCacheKey key, int chapterIndex) async {
    if (chapterIndex < 0) return null;
    final _BookCache book =
        _books.putIfAbsent(key.bookId, () => _BookCache(key.bookId));
    try {
      await _ensureLoaded(book, key);
      final ChapterTextSpan? span = book.spans[chapterIndex];
      if (span == null) return null;

      final File blob = await _blobFileFor(key.bookId);
      final RandomAccessFile raf = await blob.open();
      try {
        await raf.setPosition(span.start);
        final List<int> bytes = await raf.read(span.end - span.start);
        // 截断 / 尺寸不符（blob 被外部动过）→ 当 miss。
        if (bytes.length != span.end - span.start) return null;
        return decodeChapterTextPayload(bytes);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null; // 任何 IO / 解析故障当 miss
    }
  }

  @override
  Future<void> write(
    StructureCacheKey key,
    int chapterIndex,
    List<String> paragraphs,
  ) async {
    if (chapterIndex < 0) return;
    final _BookCache book =
        _books.putIfAbsent(key.bookId, () => _BookCache(key.bookId));
    // 写入串行化：blob 是追加式的，交错写会把区间表写花。单次失败不掐断链条。
    final Future<void> next = book.writes
        .then((_) => _writeOne(book, key, chapterIndex, paragraphs));
    book.writes = next.then<void>((_) {}, onError: (Object _) {});
    await next;
  }

  Future<void> _writeOne(
    _BookCache book,
    StructureCacheKey key,
    int chapterIndex,
    List<String> paragraphs,
  ) async {
    await _ensureLoaded(book, key);

    final List<int> payload = encodeChapterTextPayload(paragraphs);
    final File blob = await _blobFileFor(key.bookId);

    // 重置后的首写：截断旧 blob，杜绝旧判据的垃圾字节混进新区间表。
    if (book.spans.isEmpty && await blob.exists()) {
      await blob.writeAsBytes(const <int>[]);
    }

    final int start = await blob.exists() ? await blob.length() : 0;
    await blob.writeAsBytes(payload, mode: FileMode.append);
    book.spans[chapterIndex] = ChapterTextSpan(
      chapterIndex: chapterIndex,
      start: start,
      end: start + payload.length,
    );

    final AtomicFile indexFile = await _indexFileFor(key.bookId);
    await JsonStore(indexFile)
        .write(encodeChapterTextIndex(key, book.spans.values.toList()));
  }

  /// 载入（或重置为）[key] 对应的索引态：判据不符 / 无索引 / 损坏 = 空区间表。
  Future<void> _ensureLoaded(_BookCache book, StructureCacheKey key) async {
    if (book.loaded && book.key == key) return;
    book.resetTo(key);
    try {
      final JsonStore store = JsonStore(await _indexFileFor(book.bookId));
      final List<ChapterTextSpan>? spans =
          decodeChapterTextIndex(await store.read(), key: key);
      if (spans != null) {
        for (final ChapterTextSpan s in spans) {
          book.spans[s.chapterIndex] = s;
        }
      }
    } catch (_) {
      // 载入失败 = 空区间表（当 miss），不影响后续写入重建。
    }
  }

  @override
  Future<void> delete(String bookId) async {
    try {
      final AtomicFile index = await _indexFileFor(bookId);
      for (final String path in <String>[
        index.path,
        index.backupPath,
        index.corruptPath,
        index.tempPath,
      ]) {
        final File f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      }
      final File blob = await _blobFileFor(bookId);
      if (await blob.exists()) {
        await blob.delete();
      }
    } catch (_) {
      // 清理失败静默（缓存文件本就是可再生的加速层数据）。
    }
    _books.remove(bookId);
  }
}

/// 一本书的内存态：索引区间表 + 判据快照 + 写串行链。
class _BookCache {
  _BookCache(this.bookId);

  final String bookId;

  /// 是否已从磁盘载入过（同判据的后续读写不再触碰索引文件）。
  bool loaded = false;

  /// 当前索引态对应的判据（`null` = 尚未载入）。
  StructureCacheKey? key;

  /// 章号 → blob 区间。
  final Map<int, ChapterTextSpan> spans = <int, ChapterTextSpan>{};

  /// 写串行链（尾节点）。
  Future<void> writes = Future<void>.value();

  /// 整体重置到新判据（清空区间表；blob 截断推迟到首写，见 [_writeOne]）。
  void resetTo(StructureCacheKey newKey) {
    loaded = true;
    key = newKey;
    spans.clear();
  }
}
