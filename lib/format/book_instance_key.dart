// 书**副本判据**（`bookId` + 副本 `mtime` + `size`）——开书复用池的条目 key。
//
// 它原本是 `structure_cache.dart` 里的 `StructureCacheKey`：当年三层解析缓存
// （结构 / TXT 大纲 / 章正文）与复用池共用这一个判据值对象。2026-10-26 纯 Dart
// 解析源与三层缓存整体下线（内核成唯一实现，见上游 `rust_reader_kernel#12`）后，
// 判据只剩复用池这一位用户，遂改名并搬到自己的文件里——它**不是缓存概念**，
// 而是「同一份文件」的判定：文件被替换 / 副本被重写 → 判据不符 → 池条目就地销毁。
//
// 纯 Dart（不 import Flutter、不 import `dart:io`），与 `lib/format/**` 同铁律。

/// 一本书的**副本判据**：内容摘要 + 落盘副本的修改时间与字节数。
class BookInstanceKey {
  const BookInstanceKey({
    required this.bookId,
    required this.mtimeMs,
    required this.size,
  });

  /// SHA-256 hex 前 16 位（`ImportService.computeBookId`）——文件名安全字符。
  final String bookId;

  /// 副本文件修改时间（epoch 毫秒）。
  final int mtimeMs;

  /// 副本文件字节数。
  final int size;

  @override
  bool operator ==(Object other) =>
      other is BookInstanceKey &&
      other.bookId == bookId &&
      other.mtimeMs == mtimeMs &&
      other.size == size;

  @override
  int get hashCode => Object.hash(bookId, mtimeMs, size);

  @override
  String toString() => 'BookInstanceKey($bookId, mtime=$mtimeMs, size=$size)';
}
