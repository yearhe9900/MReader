// TXT 大纲缓存 + 章正文缓存的行为测试（tech-usage.md §2.81）。
//
// 三组验收：
//   1. 信封序列化（纯层）：往返还原全字段；判据（bookId/mtime/size）任一不符即
//      miss；schema 不符 / 形状损坏 → miss 不抛；
//   2. `FileTxtOutlineCacheStore`（磁盘）：write→read 往返、判据不符 null、
//      delete 清理、无文件 null；
//   3. `DartTxtSource` 接线：大纲 miss → isolate 派发 1 次 + 写回；同判据重开 →
//      **零派发**（「重开不再整本解码/全文正则」验收）；判据变 → 重算；
//      章正文缓存命中 → 零派发取正文；大纲命中但章正文 miss → 回落解码 1 次。
//
// 期望值硬编码字面量（引用常量 = 同义反复）；本文件在 VM 上跑（`flutter test`），
// 故允许 `dart:io`——`lib/format/**` / `lib/storage/**` 的分层铁律不因此松动。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/chapter_text_cache.dart';
import 'package:mreader/format/dart_txt_source.dart';
import 'package:mreader/format/structure_cache.dart';
import 'package:mreader/format/txt_outline_cache.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/storage/txt_outline_cache_store.dart';
import 'package:mreader/task/isolate_runner.dart';

/// 记录派发的 spy runner（真实派发照走，仅旁路记录）。
class _RecordingRunner extends IsolateRunner {
  int dispatches = 0;

  @override
  Future<R> run<M, R>(IsolateTask<M, R> task, M message, {String? debugLabel}) {
    dispatches++;
    return super.run<M, R>(task, message, debugLabel: debugLabel);
  }
}

/// 内存 fake：按真实信封语义比对判据（键 = bookId）。
class _FakeOutlineStore implements TxtOutlineCacheStore {
  final Map<String, (StructureCacheKey, TxtOutline)> byBook =
      <String, (StructureCacheKey, TxtOutline)>{};
  int reads = 0;
  int writes = 0;
  bool throwOnRead = false;

  @override
  Future<TxtOutline?> read(StructureCacheKey key) async {
    reads++;
    if (throwOnRead) throw StateError('缓存读故障（模拟）');
    final (StructureCacheKey, TxtOutline)? hit = byBook[key.bookId];
    if (hit == null) return null;
    if (hit.$1 != key) return null;
    return hit.$2;
  }

  @override
  Future<void> write(StructureCacheKey key, TxtOutline outline) async {
    writes++;
    byBook[key.bookId] = (key, outline);
  }

  @override
  Future<void> delete(String bookId) async {
    byBook.remove(bookId);
  }
}

/// 章正文缓存内存 fake（判据逐字段比对）。
class _FakeChapterStore implements ChapterTextCacheStore {
  final Map<String, (StructureCacheKey, Map<int, List<String>>)> byBook =
      <String, (StructureCacheKey, Map<int, List<String>>)>{};
  int reads = 0;
  int writes = 0;
  bool throwOnRead = false;

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
    final (StructureCacheKey, Map<int, List<String>>)? old = byBook[key.bookId];
    final Map<int, List<String>> table =
        old != null && old.$1 == key ? old.$2 : <int, List<String>>{};
    table[chapterIndex] = List<String>.from(paragraphs);
    byBook[key.bookId] = (key, table);
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

/// 一行正文（21 个非空白字 + 换行），与 `dart_txt_source_test.dart` 同款夹具。
const String _line = '这是本章的正文内容，重复若干次以超过阈值。';

String _body(int n) {
  final StringBuffer sb = StringBuffer();
  while (sb.length < n) {
    sb.write('$_line\n');
  }
  return sb.toString();
}

/// 「第X章」两章 + 长正文（实测走规则「目录」→ 2 章）。
String _twoChaptersText() => '第一章 起\n${_body(1500)}第二章 承\n${_body(1500)}';

Uint8List _utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

const StructureCacheKey _key = StructureCacheKey(
  bookId: '0123456789abcdef',
  mtimeMs: 1000,
  size: 42,
);
const StructureCacheKey _keyMtimeChanged = StructureCacheKey(
  bookId: '0123456789abcdef',
  mtimeMs: 2000,
  size: 42,
);

TxtOutline _sampleOutline() => const TxtOutline(
      encoding: 'utf-8',
      chapters: <TxtChapterSpan>[
        TxtChapterSpan(start: 5, end: 1529, title: '第一章 起'),
        TxtChapterSpan(start: 1529, end: 3048, title: '第二章 承'),
      ],
    );

void main() {
  group('① 信封序列化（纯层）', () {
    test('往返还原全字段', () {
      final Map<String, Object?> envelope =
          encodeTxtOutlineEnvelope(_key, _sampleOutline());
      final TxtOutline? back = decodeTxtOutlineEnvelope(envelope, key: _key);
      expect(back, isNotNull);
      expect(back!.encoding, 'utf-8');
      expect(back.chapters, _sampleOutline().chapters);
    });

    test('判据任一不符 → miss', () {
      final Map<String, Object?> envelope =
          encodeTxtOutlineEnvelope(_key, _sampleOutline());
      expect(
        decodeTxtOutlineEnvelope(
          envelope,
          key: const StructureCacheKey(
            bookId: 'ffffffffffffffff',
            mtimeMs: 1000,
            size: 42,
          ),
        ),
        isNull,
      );
      expect(
        decodeTxtOutlineEnvelope(envelope, key: _keyMtimeChanged),
        isNull,
      );
      expect(
        decodeTxtOutlineEnvelope(
          envelope,
          key: const StructureCacheKey(
            bookId: '0123456789abcdef',
            mtimeMs: 1000,
            size: 7,
          ),
        ),
        isNull,
      );
    });

    test('schema 不符 / 形状损坏 → miss 不抛', () {
      final Map<String, Object?> envelope =
          encodeTxtOutlineEnvelope(_key, _sampleOutline());
      final Map<String, Object?> wrongSchema =
          Map<String, Object?>.from(envelope)..['schema'] = 999;
      expect(decodeTxtOutlineEnvelope(wrongSchema, key: _key), isNull);
      expect(decodeTxtOutlineEnvelope(<String, Object?>{}, key: _key), isNull);
      expect(decodeTxtOutlineEnvelope('not a map', key: _key), isNull);

      // outline 里的 start/end 倒挂 → 整体 miss。
      final Map<String, Object?> badSpan = <String, Object?>{
        'schema': kTxtOutlineCacheSchema,
        'bookId': _key.bookId,
        'mtimeMs': _key.mtimeMs,
        'size': _key.size,
        'outline': <String, Object?>{
          'encoding': 'utf-8',
          'chapters': <Map<String, Object?>>[
            <String, Object?>{'start': 10, 'end': 5, 'title': '坏章'},
          ],
        },
      };
      expect(decodeTxtOutlineEnvelope(badSpan, key: _key), isNull);
    });
  });

  group('② FileTxtOutlineCacheStore（磁盘）', () {
    late Directory tmp;
    late FileTxtOutlineCacheStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mreader_outline_');
      store = FileTxtOutlineCacheStore(_TmpPaths(tmp));
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('write → read 往返', () async {
      await store.write(_key, _sampleOutline());
      final TxtOutline? hit = await store.read(_key);
      expect(hit, isNotNull);
      expect(hit!.chapters, _sampleOutline().chapters);
    });

    test('判据不符 / 无文件 → null；delete 后清空', () async {
      expect(await store.read(_key), isNull);

      await store.write(_key, _sampleOutline());
      expect(await store.read(_keyMtimeChanged), isNull);
      expect(await store.read(_key), isNotNull);

      await store.delete(_key.bookId);
      expect(await store.read(_key), isNull);
    });
  });

  group('③ DartTxtSource 接线', () {
    test('大纲 miss → 派发 1 次 + 写回；重开 → 零派发、章表一致', () async {
      final _FakeOutlineStore outline = _FakeOutlineStore();
      final _RecordingRunner runner1 = _RecordingRunner();
      final DartTxtSource first = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: runner1,
        outlineCache: outline,
        cacheKey: _key,
      );
      final List<Chapter> chapters1 = await first.chapters();
      expect(chapters1.map((Chapter c) => c.title).toList(),
          <String>['第一章 起', '第二章 承']);
      expect(chapters1.map((Chapter c) => c.href).toList(),
          <String>['txt:5', 'txt:1529']);
      expect(runner1.dispatches, 1); // 只派「解码 + 分章」那一次
      expect(outline.writes, 1);
      // 进度权重走区间长度：现场解析实测（硬编码字面量钉住）。
      final List<int> weights1 = (await first.chapterWeightEstimates())!;
      expect(weights1, <int>[1519, 1519]);
      await first.dispose();

      final _RecordingRunner runner2 = _RecordingRunner();
      final DartTxtSource second = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: runner2,
        outlineCache: outline,
        cacheKey: _key,
      );
      final List<Chapter> chapters2 = await second.chapters();
      expect(runner2.dispatches, 0); // 命中大纲：零解码、零正则、零拷贝
      expect(
        chapters2.map((Chapter c) => (c.href, c.title)).toList(),
        chapters1.map((Chapter c) => (c.href, c.title)).toList(),
      );
      // 进度权重走区间长度：缓存命中与现场解析逐项相同。
      expect(await second.chapterWeightEstimates(), weights1);
      expect(outline.writes, 1); // 命中路径不重复写
      await second.dispose();
    });

    test('判据变（mtime）→ 失效重算', () async {
      final _FakeOutlineStore outline = _FakeOutlineStore();
      final _RecordingRunner runner = _RecordingRunner();
      final DartTxtSource source = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: runner,
        outlineCache: outline,
        cacheKey: _keyMtimeChanged,
      );
      await source.chapters();
      expect(runner.dispatches, 1);
      expect(outline.writes, 1); // 以新判据覆盖写
      expect(outline.byBook[_key.bookId]!.$1, _keyMtimeChanged);
      await source.dispose();
    });

    test('章正文缓存：写回后重开命中 → 零派发取正文', () async {
      final _FakeOutlineStore outline = _FakeOutlineStore();
      final _FakeChapterStore chapter = _FakeChapterStore();
      final _RecordingRunner runner1 = _RecordingRunner();
      final DartTxtSource first = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: runner1,
        outlineCache: outline,
        cacheKey: _key,
        chapterTextCache: chapter,
      );
      final ChapterContent live = await first.content(0);
      expect(live.paragraphList.first, _line);
      expect(chapter.writes, 1); // 现场计算后写回
      await first.dispose();

      final _RecordingRunner runner2 = _RecordingRunner();
      final DartTxtSource second = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: runner2,
        outlineCache: outline,
        cacheKey: _key,
        chapterTextCache: chapter,
      );
      final ChapterContent cached = await second.content(0);
      expect(runner2.dispatches, 0); // 大纲 + 章正文双命中：零派发
      expect(cached.paragraphList, live.paragraphList);
      await second.dispose();
    });

    test('大纲命中但章正文 miss → 回落解码 1 次并写回', () async {
      final _FakeOutlineStore outline = _FakeOutlineStore();
      final _FakeChapterStore chapter = _FakeChapterStore();

      // 先跑一遍把大纲写满（章正文不接）。
      final DartTxtSource warm = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: _RecordingRunner(),
        outlineCache: outline,
        cacheKey: _key,
      );
      final ChapterContent live = await warm.content(0);
      await warm.dispose();
      chapter.byBook.clear();
      outline.writes = 0;

      final _RecordingRunner runner = _RecordingRunner();
      final DartTxtSource source = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: runner,
        outlineCache: outline,
        cacheKey: _key,
        chapterTextCache: chapter,
      );
      final ChapterContent rebuilt = await source.content(0);
      expect(runner.dispatches, 1); // 只补解码这一跳
      expect(rebuilt.paragraphList, live.paragraphList);
      expect(chapter.writes, 1); // 回落计算后同样写回
      await source.dispose();
    });

    test('缓存读故障当 miss，开书不受影响', () async {
      final _FakeOutlineStore outline = _FakeOutlineStore()..throwOnRead = true;
      final _FakeChapterStore chapter = _FakeChapterStore()..throwOnRead = true;
      final _RecordingRunner runner = _RecordingRunner();
      final DartTxtSource source = DartTxtSource(
        fileName: 'book.txt',
        bytes: _utf8Bytes(_twoChaptersText()),
        runner: runner,
        outlineCache: outline,
        cacheKey: _key,
        chapterTextCache: chapter,
      );
      final ChapterContent content = await source.content(0);
      expect(content.paragraphList.first, _line);
      expect(runner.dispatches, 1);
      await source.dispose();
    });
  });
}
