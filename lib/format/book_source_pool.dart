// 开书**复用池**：把「已经解析好的书源」留在内存里，下一次打开同一本书直接复用。
//
// ## 为什么需要它（2026-10-20，负责人：「导入一本新书后能快速打开，之后更快」）
//
// 开书链路里真正贵的是「文件字节 → 解析结构 → 章节表」这一段：整本读盘（15MB 书
// 真机 30~80ms）+ zip 中央目录 + isolate 结构解析 + 章节表构建。**而这些产物对
// 同一本书、同一份文件是完全确定的**——只要文件没变，就没必要每开一次重算一次。
//
// 旧实现每次都从零开始，于是「反复打开同一本书」的第二次、第三次和第一次一样慢。
// 本池把 [BookSource]（它自己持有原始字节 + 解析结果 + 章节表缓存）驻留起来：
//
//   · **导入即入池**：导入管道解析出的那个 source 不销毁，直接留在池里 ⇒ 用户
//     导入完点开，走的是「零读盘、零解析」；
//   · **关书回池**：阅读页关闭时把 source 还回来 ⇒ 第二次、第三次打开同样零成本。
//
// ## 口径（三条硬约束）
//
// 1. **判据必须校验**：池条目带 [StructureCacheKey]（`bookId + mtime + size`）。
//    文件被替换 / 副本被重写 → 判据不符 → 该条目**就地销毁**并当 miss
//    （绝不让旧字节冒充新文件，与磁盘缓存同一条纪律）。
// 2. **取出即独占**：同一本书不会同时被两个阅读页持有，故 [take] 命中时把条目
//    **移出池**，由调用方独占使用，用完再 [put] 回来。这样池里永远不会有一份
//    「正被别处用着」的 source。
// 3. **内存有上界**：条目数与单本条数上限双闸（[maxEntries] / [maxBytes]）。
//    超出 → 淘汰最久未用者并**立即 dispose**。驻留体积取**副本文件字节数**
//    （`StructureCacheKey.size`）——书源持有的正是这份整本字节，两者恒等，
//    因此不必为「内存占用」在 `BookSource` 合同里新开一个成员
//    （`implements` 语义下默认实现对 fake 无效，只会逼 7 处测试跟着改）。
//
// 本文件**不 import Flutter、不 import `dart:io`**（与 `lib/format/**` 同铁律），
// 可在纯 Dart 单测里直接断言。
import 'dart:async';
import 'dart:collection';

import 'book_source.dart';
import 'structure_cache.dart';

/// 默认驻留条目数：两本（「刚导入的那本」+「上次读的那本」）。
const int kBookSourcePoolEntries = 2;

/// 默认单本驻留上限（字节）：48MB。
///
/// 取 48MB 的理由：常见网文 EPUB/TXT 在 1~20MB，画册类才会破 50MB；超过这条线
/// 的「省一次解析」换不回一整份常驻内存，退回磁盘缓存路径即可（不阻断开书）。
const int kBookSourcePoolMaxBytes = 48 * 1024 * 1024;

/// 池条目：书源 + 判据 + 字节数 + 最近使用序（由 `LinkedHashMap` 的插入序维护）。
class _PooledSource {
  _PooledSource({
    required this.key,
    required this.byteSize,
    required this.source,
  });

  final StructureCacheKey key;
  final int byteSize;
  final BookSource source;
}

/// 已解析书源的**有界复用池**（进程级，纯 Dart）。
class BookSourcePool {
  BookSourcePool({
    this.maxEntries = kBookSourcePoolEntries,
    this.maxBytes = kBookSourcePoolMaxBytes,
  });

  /// 同时驻留的条目数上限。
  final int maxEntries;

  /// 单本条目的字节数上限（超过则不驻留）。
  final int maxBytes;

  final LinkedHashMap<String, _PooledSource> _entries =
      LinkedHashMap<String, _PooledSource>();

  /// 当前驻留条目数（测试观察用）。
  int get length => _entries.length;

  /// 已驻留的 bookId（按最近使用序，末尾最新）。
  Iterable<String> get bookIds => _entries.keys;

  /// [bookId] 是否已驻留**且判据一致**（不取走，供只读判断 / 测试）。
  bool contains(String bookId, StructureCacheKey? key) {
    final _PooledSource? entry = _entries[bookId];
    if (entry == null || key == null) return false;
    return entry.key == key;
  }

  /// 命中则**取走**（独占）并返回书源；miss / 判据不符返回 `null`。
  ///
  /// 判据不符时该条目会被就地销毁（`dispose`）——旧字节不能冒充新文件。
  BookSource? take(String bookId, StructureCacheKey? key) {
    final _PooledSource? entry = _entries.remove(bookId);
    if (entry == null) return null;
    if (key == null || entry.key != key) {
      unawaited(entry.source.dispose());
      return null;
    }
    return entry.source;
  }

  /// 归还一个书源；不满足驻留条件（无判据 / 超字节上限）则**当场销毁**。
  ///
  /// 同一 [bookId] 已有旧条目时先销毁旧条目（同一本书只留最新的一份）。
  void put(String bookId, StructureCacheKey? key, BookSource source) {
    if (key == null || key.size > maxBytes) {
      unawaited(source.dispose());
      return;
    }
    final _PooledSource? previous = _entries.remove(bookId);
    if (previous != null) unawaited(previous.source.dispose());
    _entries[bookId] =
        _PooledSource(key: key, byteSize: key.size, source: source);
    _evict();
  }

  /// 丢弃某本书的驻留源（删书 / 文件被替换时调用）。
  Future<void> evict(String bookId) async {
    final _PooledSource? entry = _entries.remove(bookId);
    if (entry != null) await entry.source.dispose();
  }

  /// 清空（测试收尾 / 组合根退出时用）。
  Future<void> clear() async {
    final List<_PooledSource> all = _entries.values.toList(growable: false);
    _entries.clear();
    for (final _PooledSource e in all) {
      await e.source.dispose();
    }
  }

  void _evict() {
    while (_entries.length > maxEntries) {
      final String victim = _entries.keys.first;
      final _PooledSource? entry = _entries.remove(victim);
      if (entry != null) unawaited(entry.source.dispose());
    }
  }
}
