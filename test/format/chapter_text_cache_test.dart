// 章正文磁盘缓存（EPUB + TXT 共用）的行为测试（tech-usage.md §2.81）。
//
// 三组验收：
//   1. 索引信封 + 负载编解码（纯层）：区间表往返还原；判据（bookId/mtime/size）
//      任一不符即 miss；schema / 形状损坏 → miss 不抛；段落表 ⇄ UTF-8 JSON
//      逐字往返（含 NUL 锚点标记、段内换行）；
//   2. `FileChapterTextCacheStore`（磁盘）：写两章 → 逐字读回、同章重写 → 新值、
//      未写章 → null、判据失效 → 整体重置（旧章不可读 + 首写截断旧 blob）、
//      并发写多章 → 串行化区间不串味、delete → 读 null 且文件消失；
//   3. `DartEpubSource` 接线：content 首次现场计算 → 写回 1 次；重开命中 →
//      零写、结果与现场计算**逐字相同**；命中短路哨兵（缓存回什么就回什么，
//      零解压零 HTML 解析）；mtime 变 → 判据失效重算；读写故障当 miss / 静默。
//
// 期望值硬编码字面量（引用常量 = 同义反复）；本文件在 VM 上跑（`flutter test`），
// 故允许 `dart:io`——`lib/format/**` / `lib/storage/**` 的分层铁律不因此松动。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/chapter_text_cache.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/format/structure_cache.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/storage/chapter_text_cache_store.dart';

import 'epub_builder.dart';

/// 章正文缓存内存 fake（判据逐字段比对；可预置哨兵、可模拟故障）。
class _FakeChapterStore implements ChapterTextCacheStore {
  final Map<String, (StructureCacheKey, Map<int, List<String>>)> byBook =
      <String, (StructureCacheKey, Map<int, List<String>>)>{};
  int reads = 0;
  int writes = 0;
  bool throwOnRead = false;
  bool throwOnWrite = false;

  /// 预置一本（用于「命中短路哨兵」等场景）。
  void seed(StructureCacheKey key, int chapterIndex, List<String> paragraphs) {
    final (StructureCacheKey, Map<int, List<String>>)? old = byBook[key.bookId];
    final Map<int, List<String>> table =
        old != null && old.$1 == key ? old.$2 : <int, List<String>>{};
    table[chapterIndex] = List<String>.from(paragraphs);
    byBook[key.bookId] = (key, table);
  }

  @override
  Future<List<String>?> read(StructureCacheKey key, int chapterIndex) async {
    reads++;
    if (throwOnRead) throw StateError('缓存读故障（模拟）');
    final (StructureCacheKey, Map<int, List<String>>)? hit = byBook[key.bookId];
    if (hit == null) return null;
    if (hit.$1 != key) return null;
    return hit.$2[chapterIndex];
  }

  @override
  Future<void> write(
    StructureCacheKey key,
    int chapterIndex,
    List<String> paragraphs,
  ) async {
    writes++;
    if (throwOnWrite) throw StateError('缓存写故障（模拟）');
    seed(key, chapterIndex, paragraphs);
  }

  @override
  Future<void> delete(String bookId) async {
    byBook.remove(bookId);
  }
}

/// 临时目录根（磁盘组用）。
class _TmpPaths implements AppPaths {
  _TmpPaths(this.root);

  final Directory root;

  @override
  Future<Directory> dataDir() async => root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory d =
        Directory('${root.path}${Platform.pathSeparator}$name');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }
}

/// 两节最小 EPUB：每节两段纯文本（无标题层级 / 锚点标记，段落输出确定）。
Uint8List _miniEpub() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '章缓存测试书',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml') +
              itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1') + itemrefXml('c2'),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', paragraphs: <String>['第一段。', '第二段。'])),
      textEntry('OEBPS/text/ch2.xhtml',
          xhtmlDoc(title: '二 承', paragraphs: <String>['第三段。', '第四段。'])),
    ]);

const StructureCacheKey _key = StructureCacheKey(
  bookId: '0123456789abcdef',
  mtimeMs: 1759300000000,
  size: 4096,
);
const StructureCacheKey _keyMtimeChanged = StructureCacheKey(
  bookId: '0123456789abcdef',
  mtimeMs: 1759400000000,
  size: 4096,
);

void main() {
  group('① 索引信封 + 负载编解码（纯层）', () {
    test('索引信封往返还原区间表', () {
      final List<ChapterTextSpan> spans = <ChapterTextSpan>[
        const ChapterTextSpan(chapterIndex: 0, start: 0, end: 10),
        const ChapterTextSpan(chapterIndex: 3, start: 10, end: 25),
      ];
      final Object? round = jsonDecode(
        jsonEncode(encodeChapterTextIndex(_key, spans)),
      );
      final List<ChapterTextSpan>? back =
          decodeChapterTextIndex(round, key: _key);
      expect(back, spans); // ChapterTextSpan 值相等
    });

    test('判据任一不符 → miss', () {
      final Map<String, Object?> envelope = encodeChapterTextIndex(_key,
          <ChapterTextSpan>[
            const ChapterTextSpan(chapterIndex: 0, start: 0, end: 10),
          ]);
      expect(
        decodeChapterTextIndex(envelope,
            key: const StructureCacheKey(
                bookId: 'ffffffffffffffff', mtimeMs: 1759300000000, size: 4096)),
        isNull,
      );
      expect(decodeChapterTextIndex(envelope, key: _keyMtimeChanged), isNull);
      expect(
        decodeChapterTextIndex(envelope,
            key: const StructureCacheKey(
                bookId: '0123456789abcdef', mtimeMs: 1759300000000, size: 7)),
        isNull,
      );
    });

    test('schema 不符 / 形状损坏 → miss 不抛', () {
      final Map<String, Object?> ok = encodeChapterTextIndex(_key,
          <ChapterTextSpan>[
            const ChapterTextSpan(chapterIndex: 0, start: 0, end: 10),
          ]);
      final Map<String, Object?> wrongSchema =
          Map<String, Object?>.from(ok)..['schema'] = 999;
      expect(decodeChapterTextIndex(wrongSchema, key: _key), isNull);
      expect(decodeChapterTextIndex('not a map', key: _key), isNull);
      expect(decodeChapterTextIndex(42, key: _key), isNull);
      expect(decodeChapterTextIndex(<String, Object?>{}, key: _key), isNull);

      Map<String, Object?> withSpans(Object? spans) => <String, Object?>{
            'schema': kChapterTextCacheSchema,
            'bookId': _key.bookId,
            'mtimeMs': _key.mtimeMs,
            'size': _key.size,
            'spans': spans,
          };
      expect(decodeChapterTextIndex(withSpans('x'), key: _key), isNull);
      expect(decodeChapterTextIndex(withSpans(<Object>[42]), key: _key), isNull);
      expect(
        decodeChapterTextIndex(
          withSpans(<Object>[
            <String, Object?>{'i': 0, 'start': '0', 'end': 10},
          ]),
          key: _key,
        ),
        isNull,
      );
      // i 负数 / start 负数 / end<start 倒挂 → 整体 miss。
      expect(
        decodeChapterTextIndex(
          withSpans(<Object>[
            <String, Object?>{'i': -1, 'start': 0, 'end': 10},
          ]),
          key: _key,
        ),
        isNull,
      );
      expect(
        decodeChapterTextIndex(
          withSpans(<Object>[
            <String, Object?>{'i': 0, 'start': 0, 'end': -5},
          ]),
          key: _key,
        ),
        isNull,
      );
      expect(
        decodeChapterTextIndex(
          withSpans(<Object>[
            <String, Object?>{'i': 0, 'start': 10, 'end': 5},
          ]),
          key: _key,
        ),
        isNull,
      );
    });

    test('负载编解码：段落 ⇄ UTF-8 JSON 逐字往返', () {
      expect(
        utf8.decode(encodeChapterTextPayload(<String>['第一段。'])),
        '["第一段。"]',
      );
      expect(
        decodeChapterTextPayload(utf8.encode('["a","b"]')),
        <String>['a', 'b'],
      );
      // NUL 锚点标记、段内换行原样往返（JSON 无转义歧义）。
      const List<String> tricky = <String>['\x00ID:anchor1\x00开头', '带\n换行'];
      expect(decodeChapterTextPayload(encodeChapterTextPayload(tricky)),
          tricky);
      // 空表是稳定事实，照编照解。
      expect(decodeChapterTextPayload(encodeChapterTextPayload(<String>[])),
          <String>[]);
    });

    test('负载损坏 → null 不抛', () {
      expect(decodeChapterTextPayload(<int>[0xFF, 0xFE, 0x00]), isNull);
      expect(decodeChapterTextPayload(utf8.encode('{"a":1}')), isNull);
      expect(decodeChapterTextPayload(utf8.encode('[1,2]')), isNull);
      expect(decodeChapterTextPayload(utf8.encode('["a",2]')), isNull);
    });
  });

  group('② FileChapterTextCacheStore（磁盘）', () {
    late Directory tmp;
    late FileChapterTextCacheStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mreader_chapter_cache_');
      store = FileChapterTextCacheStore(_TmpPaths(tmp));
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('写两章 → 逐字读回；未写章 → null', () async {
      await store.write(_key, 0, <String>['第一章第一段。', '第一章第二段。']);
      await store.write(_key, 1, <String>['第二章唯一段。']);
      expect(await store.read(_key, 0),
          <String>['第一章第一段。', '第一章第二段。']);
      expect(await store.read(_key, 1), <String>['第二章唯一段。']);
      expect(await store.read(_key, 2), isNull);
      expect(await store.read(_key, -1), isNull);
    });

    test('同章重写 → 新值覆盖旧值', () async {
      await store.write(_key, 0, <String>['旧值段落。']);
      await store.write(_key, 0, <String>['新值段落。']);
      expect(await store.read(_key, 0), <String>['新值段落。']);
    });

    test('判据失效 → 整体重置；首写截断旧 blob', () async {
      await store.write(_key, 0, <String>['aaaa']);
      expect(await store.read(_key, 0), <String>['aaaa']);

      // 判据变（mtime）→ 旧章读不到（整体重置，旧区间表作废）。
      expect(await store.read(_keyMtimeChanged, 0), isNull);
      await store.write(_keyMtimeChanged, 0, <String>['bb']);
      expect(await store.read(_keyMtimeChanged, 0), <String>['bb']);
      // 旧判据回头读：索引已换判据 → miss。
      expect(await store.read(_key, 0), isNull);

      // 重置后首写截断旧 blob：只剩新负载 `["bb"]` 的 6 字节（旧 `["aaaa"]` 被回收）。
      final File blob = File(
        '${tmp.path}${Platform.pathSeparator}chapters'
        '${Platform.pathSeparator}0123456789abcdef.blob',
      );
      expect(await blob.length(), 6);
    });

    test('并发写多章 → 串行化，区间不串味', () async {
      final List<List<String>> paras = <List<String>>[
        <String>['章零正文。'],
        <String>['章一正文。'],
        <String>['章二正文。'],
        <String>['章三正文。'],
        <String>['章四正文。'],
        <String>['章五正文。'],
      ];
      await Future.wait(<Future<void>>[
        for (int i = 0; i < paras.length; i++) store.write(_key, i, paras[i]),
      ]);
      for (int i = 0; i < paras.length; i++) {
        expect(await store.read(_key, i), paras[i], reason: '第 $i 章区间不串味');
      }
    });

    test('delete → 读 null，index / blob 文件消失', () async {
      await store.write(_key, 0, <String>['待删段落。']);
      await store.delete(_key.bookId);
      expect(await store.read(_key, 0), isNull);
      final String base = '${tmp.path}${Platform.pathSeparator}chapters'
          '${Platform.pathSeparator}0123456789abcdef';
      expect(File('$base.index.json').existsSync(), isFalse);
      expect(File('$base.blob').existsSync(), isFalse);
    });
  });

  group('③ DartEpubSource 接线', () {
    test('content 首次现场计算 → 写回 1 次；重开命中 → 零写、逐字相同', () async {
      final _FakeChapterStore fake = _FakeChapterStore();
      final DartEpubSource first = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: fake,
        cacheKey: _key,
      );
      final ChapterContent live = await first.content(0);
      expect(live.paragraphList, <String>['第一段。', '第二段。']);
      expect(fake.reads, 1); // 先查缓存（miss）
      expect(fake.writes, 1); // 现场抽取后写回
      await first.dispose();

      final DartEpubSource second = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: fake,
        cacheKey: _key,
      );
      final ChapterContent cached = await second.content(0);
      expect(cached.paragraphList, <String>['第一段。', '第二段。']);
      expect(cached.paragraphList, live.paragraphList); // 与现场计算逐字相同
      expect(fake.reads, 2);
      expect(fake.writes, 1); // 命中不重写
      await second.dispose();
    });

    test('命中短路哨兵：缓存回什么就回什么（零解压零解析）', () async {
      final _FakeChapterStore fake = _FakeChapterStore();
      fake.seed(_key, 0, <String>['缓存命中哨兵。']);
      final DartEpubSource source = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: fake,
        cacheKey: _key,
      );
      final ChapterContent hit = await source.content(0);
      // 若走了现场抽取，结果必是 `['第一段。', '第二段。']`——回哨兵即证短路。
      expect(hit.paragraphList, <String>['缓存命中哨兵。']);
      expect(fake.writes, 0);
      await source.dispose();
    });

    test('mtime 变 → 判据失效，重算并覆盖写回', () async {
      final _FakeChapterStore fake = _FakeChapterStore();
      fake.seed(_key, 0, <String>['旧判据缓存。']);
      final DartEpubSource source = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: fake,
        cacheKey: _keyMtimeChanged,
      );
      final ChapterContent rebuilt = await source.content(0);
      expect(rebuilt.paragraphList, <String>['第一段。', '第二段。']);
      expect(fake.writes, 1); // 以新判据覆盖写回
      expect(fake.byBook[_key.bookId]!.$1, _keyMtimeChanged);
      await source.dispose();
    });

    test('缓存读故障当 miss / 写故障静默，开书不受影响', () async {
      final _FakeChapterStore readBoom = _FakeChapterStore()..throwOnRead = true;
      final DartEpubSource a = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: readBoom,
        cacheKey: _key,
      );
      expect((await a.content(0)).paragraphList,
          <String>['第一段。', '第二段。']); // 回落现场计算
      await a.dispose();

      final _FakeChapterStore writeBoom = _FakeChapterStore()
        ..throwOnWrite = true;
      final DartEpubSource b = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: writeBoom,
        cacheKey: _key,
      );
      expect((await b.content(0)).paragraphList, <String>['第一段。', '第二段。']);
      expect(writeBoom.byBook, isEmpty); // 写失败被吞，缓存保持空
      await b.dispose();
    });

    test('注入缝：openBook 透传 chapterTextCache（缺 key 即不启用）', () async {
      final _FakeChapterStore fake = _FakeChapterStore();
      final BookSource source = await openBook(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: fake,
        cacheKey: _key,
      );
      expect(source, isA<DartEpubSource>());
      expect((source as DartEpubSource).chapterTextCache, same(fake));
      expect(source.cacheKey, _key);
      await source.dispose();

      // 缺对（不给 cacheKey）→ 字段透传但按「未启用」处理（读写均为 0）。
      final BookSource bare = await openBook(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        chapterTextCache: fake,
      );
      await bare.content(0);
      expect(fake.reads, 0);
      expect(fake.writes, 0);
      await bare.dispose();
    });
  });
}
