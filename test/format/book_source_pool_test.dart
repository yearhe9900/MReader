// 开书复用池（`BookSourcePool`）的纯 Dart 单测（§2.108）。
//
// 验收口径：
//   1. 命中即**独占取走**（同一实例、取走后池里没有）；
//   2. 判据不符（文件被替换）→ miss 且旧源**当场销毁**（旧字节不能冒充新文件）；
//   3. 上界：条目数 / 单本字节数，超限者不入池或不驻留并销毁；
//   4. `evict` / `clear` 一定归还所有权（不泄漏）。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/book_source_pool.dart';
import 'package:mreader/format/book_instance_key.dart';

/// 记账用的假书源：只关心「被 dispose 了几次」。
class _FakeSource implements BookSource {
  int disposeCount = 0;

  @override
  String get implId => 'fake';

  @override
  Future<BookMeta> load() async => throw UnimplementedError();

  @override
  Future<List<Chapter>> chapters() async => const <Chapter>[];

  @override
  Future<ChapterContent> content(int chapterIndex) async =>
      const ChapterContent.paragraphs(<String>[]);

  @override
  Future<void> dispose() async {
    disposeCount++;
  }

  // 其余成员走接口默认实现（`searchSpec` / `totalCharCount` / `readResource` 等）。
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const BookInstanceKey _key = BookInstanceKey(
  bookId: 'book-a',
  mtimeMs: 1759300000000,
  size: 1024,
);

void main() {
  test('命中即独占取走：take 返回同一实例，取走后池里没有', () {
    final BookSourcePool pool = BookSourcePool();
    final _FakeSource source = _FakeSource();
    pool.put(_key.bookId, _key, source);

    expect(pool.length, 1);
    expect(pool.contains(_key.bookId, _key), isTrue);
    expect(pool.take(_key.bookId, _key), same(source));
    expect(pool.length, 0, reason: '取走后池里不该还留着一份（否则会被两处同时用）');
    // 再取一次：miss（已独占外借）。
    expect(pool.take(_key.bookId, _key), isNull);
    expect(source.disposeCount, 0, reason: '外借中的源不该被销毁');
  });

  test('判据不符 → miss，且旧源就地销毁（旧字节不能冒充新文件）', () {
    final BookSourcePool pool = BookSourcePool();
    final _FakeSource source = _FakeSource();
    pool.put(_key.bookId, _key, source);

    const BookInstanceKey replaced = BookInstanceKey(
      bookId: 'book-a',
      mtimeMs: 1759400000000, // 副本被替换
      size: 1024,
    );
    expect(pool.take(_key.bookId, replaced), isNull);
    expect(pool.length, 0);
    expect(source.disposeCount, 1);
  });

  test('key 为 null（文件缺失）→ 不驻留、直接销毁', () {
    final BookSourcePool pool = BookSourcePool();
    final _FakeSource source = _FakeSource();
    pool.put(_key.bookId, null, source);
    expect(pool.length, 0);
    expect(source.disposeCount, 1);
  });

  test('单本字节超上限 → 不驻留、直接销毁', () {
    final BookSourcePool pool = BookSourcePool(maxBytes: 1024);
    final _FakeSource source = _FakeSource();
    const BookInstanceKey big = BookInstanceKey(
      bookId: 'book-big',
      mtimeMs: 1,
      size: 2048,
    );
    pool.put(big.bookId, big, source);
    expect(pool.length, 0);
    expect(source.disposeCount, 1);
  });

  test('条目数超上限 → 淘汰最久未用者并销毁它', () {
    final BookSourcePool pool = BookSourcePool(maxEntries: 2);
    final _FakeSource a = _FakeSource();
    final _FakeSource b = _FakeSource();
    final _FakeSource c = _FakeSource();
    pool.put('a', const BookInstanceKey(bookId: 'a', mtimeMs: 1, size: 10), a);
    pool.put('b', const BookInstanceKey(bookId: 'b', mtimeMs: 1, size: 10), b);
    pool.put('c', const BookInstanceKey(bookId: 'c', mtimeMs: 1, size: 10), c);

    expect(pool.length, 2);
    expect(a.disposeCount, 1, reason: '最早的 a 被淘汰');
    expect(b.disposeCount, 0);
    expect(c.disposeCount, 0);
    expect(pool.bookIds, <String>['b', 'c']);
  });

  test('同 bookId 重复 put → 旧实例销毁，只留最新一份', () {
    final BookSourcePool pool = BookSourcePool();
    final _FakeSource first = _FakeSource();
    final _FakeSource second = _FakeSource();
    pool.put(_key.bookId, _key, first);
    pool.put(_key.bookId, _key, second);
    expect(first.disposeCount, 1);
    expect(pool.take(_key.bookId, _key), same(second));
  });

  test('evict / clear 归还所有权（不泄漏，也不留僵尸条目）', () async {
    final BookSourcePool pool = BookSourcePool();
    final _FakeSource a = _FakeSource();
    final _FakeSource b = _FakeSource();
    pool.put('a', const BookInstanceKey(bookId: 'a', mtimeMs: 1, size: 10), a);
    pool.put('b', const BookInstanceKey(bookId: 'b', mtimeMs: 1, size: 10), b);

    await pool.evict('a');
    expect(a.disposeCount, 1);
    expect(pool.length, 1);

    await pool.clear();
    expect(b.disposeCount, 1);
    expect(pool.length, 0);

    // 清空后再 evict 是无操作（幂等）。
    await pool.evict('a');
    expect(a.disposeCount, 1);
  });

  test('Uint8List 形态的字节不进池判断：只看 key.size', () {
    // 防回归：曾经的实现想在 `BookSource` 合同里加 `residentBytes`，而 `implements`
    // 语义下默认实现对 fake 无效（7 处测试被逼改）。现口径 = 副本文件 size。
    expect(Uint8List(0).length, 0);
    final BookSourcePool pool = BookSourcePool(maxBytes: 1024);
    final _FakeSource source = _FakeSource();
    pool.put(
      'exact',
      const BookInstanceKey(bookId: 'exact', mtimeMs: 1, size: 1024),
      source,
    );
    expect(pool.length, 1, reason: '恰好等于上限仍可驻留（判据是 > maxBytes 才拒）');
    expect(source.disposeCount, 0);
  });
}
