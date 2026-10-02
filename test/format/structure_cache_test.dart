// M-PAGE `T06`：结构缓存的行为测试。
//
// 三组验收：
//   1. 信封序列化（纯层）：往返还原全字段；判据（bookId/mtime/size）任一不符即
//      miss；schema 不符 / 形状损坏 → miss 不抛；
//   2. `DartEpubSource` 接线：miss → isolate 派发 1 次 + 写回；同判据重开 →
//      **零派发**（里程碑「重开零解析」验收）；mtime 变化 → 失效重解析；
//      缓存读/写故障 → 当没接过缓存，开书不受影响；
//   3. `FileStructureCacheStore`（磁盘）：write→read 往返、判据不符 null、
//      delete 清理、损坏文件隔离后按 miss 返回。
//
// 期望值硬编码字面量（引用常量 = 同义反复）；本文件在 VM 上跑（`flutter test`），
// 故允许 `dart:io`——`lib/format/**` / `lib/storage/**` 的分层铁律不因此松动。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/epub/epub_parser.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/format/structure_cache.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/storage/structure_cache_store.dart';
import 'package:mreader/task/isolate_runner.dart';

import 'epub_builder.dart';

/// 记录派发的 spy runner（真实派发照走，仅旁路记录）。
class _RecordingRunner extends IsolateRunner {
  final List<Object?> messages = <Object?>[];

  @override
  Future<R> run<M, R>(IsolateTask<M, R> task, M message, {String? debugLabel}) {
    messages.add(message);
    return super.run<M, R>(task, message, debugLabel: debugLabel);
  }
}

/// 内存 fake：按真实信封语义比对判据（键 = bookId，值 = 判据 + 结构）。
class _FakeStore implements StructureCacheStore {
  final Map<String, (StructureCacheKey, EpubStructure)> byBook =
      <String, (StructureCacheKey, EpubStructure)>{};
  int reads = 0;
  int writes = 0;
  bool throwOnRead = false;
  bool throwOnWrite = false;

  @override
  Future<EpubStructure?> read(StructureCacheKey key) async {
    reads++;
    if (throwOnRead) throw StateError('缓存读故障（模拟）');
    final (StructureCacheKey, EpubStructure)? hit = byBook[key.bookId];
    if (hit == null) return null;
    if (hit.$1 != key) return null; // 判据不符 = miss（同磁盘信封语义）
    return hit.$2;
  }

  @override
  Future<void> write(StructureCacheKey key, EpubStructure structure) async {
    writes++;
    if (throwOnWrite) throw StateError('缓存写故障（模拟）');
    byBook[key.bookId] = (key, structure);
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

/// 无 toc 的最小 EPUB（dc:title = '缓存测试书'，一章一节）。
Uint8List _miniEpub() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '缓存测试书',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一章', paragraphs: <String>['正文。'])),
    ]);

/// 全字段非默认的结构样本（往返测试用；各字段取值刻意互不相同）。
EpubStructure _fullStructure() => const EpubStructure(
      title: '缓存测试书',
      author: '测试者',
      language: 'zh',
      description: '一段简介',
      creators: <String>['甲作者', '乙作者'],
      fileName: 'mini.epub',
      sections: <EpubSectionRef>[
        EpubSectionRef(id: 'c1', href: 'OEBPS/text/ch1.xhtml'),
        EpubSectionRef(id: 'c9', href: 'OEBPS/text/after.xhtml', linear: false),
      ],
      toc: <Chapter>[
        Chapter(
          href: 'OEBPS/text/ch1.xhtml',
          title: '第一章',
          level: 2,
          locate: 'anchor1',
        ),
      ],
      coverCandidates: <CoverCandidate>[
        CoverCandidate(href: 'OEBPS/cover.png', source: 'meta'),
      ],
      entryNames: <String, String>{'oebps/cover.png': 'OEBPS/cover.png'},
      flatTitles: <String, String>{'OEBPS/text/ch1.xhtml': '章节标题'},
    );

const StructureCacheKey _key = StructureCacheKey(
  bookId: '0123456789abcdef',
  mtimeMs: 1759300000000,
  size: 4096,
);

void main() {
  group('信封序列化（纯层）', () {
    test('T06 往返：encode → json 往返 → decode 还原全部字段', () {
      final EpubStructure src = _fullStructure();
      final Object? round = jsonDecode(
        jsonEncode(encodeStructureEnvelope(_key, src)),
      );
      final EpubStructure? back = decodeStructureEnvelope(round, key: _key);

      expect(back, isNotNull);
      final EpubStructure s = back!;
      expect(s.title, '缓存测试书');
      expect(s.author, '测试者');
      expect(s.language, 'zh');
      expect(s.description, '一段简介');
      expect(s.creators, <String>['甲作者', '乙作者']);
      expect(s.fileName, 'mini.epub');
      expect(s.sections.length, 2);
      expect(s.sections[0].id, 'c1');
      expect(s.sections[0].href, 'OEBPS/text/ch1.xhtml');
      expect(s.sections[0].linear, isTrue);
      expect(s.sections[1].id, 'c9');
      expect(s.sections[1].linear, isFalse);
      expect(s.toc.length, 1);
      expect(s.toc[0].href, 'OEBPS/text/ch1.xhtml');
      expect(s.toc[0].title, '第一章');
      expect(s.toc[0].level, 2);
      expect(s.toc[0].locate, 'anchor1');
      expect(s.coverCandidates.length, 1);
      expect(s.coverCandidates[0].href, 'OEBPS/cover.png');
      expect(s.coverCandidates[0].source, 'meta');
      expect(s.entryNames, <String, String>{'oebps/cover.png': 'OEBPS/cover.png'});
      expect(s.flatTitles, <String, String>{'OEBPS/text/ch1.xhtml': '章节标题'});
    });

    test('T06 判据：bookId / mtime / size 任一不符即 miss', () {
      final Object envelope =
          encodeStructureEnvelope(_key, _fullStructure());

      expect(
        decodeStructureEnvelope(envelope,
            key: const StructureCacheKey(
                bookId: 'fedcba9876543210', mtimeMs: 1759300000000, size: 4096)),
        isNull,
      );
      expect(
        decodeStructureEnvelope(envelope,
            key: const StructureCacheKey(
                bookId: '0123456789abcdef', mtimeMs: 1759300000001, size: 4096)),
        isNull,
      );
      expect(
        decodeStructureEnvelope(envelope,
            key: const StructureCacheKey(
                bookId: '0123456789abcdef', mtimeMs: 1759300000000, size: 4097)),
        isNull,
      );
    });

    test('T06 schema 版本不符 → miss（旧文件按 miss 处理，不迁移）', () {
      final Map<String, Object?> envelope =
          encodeStructureEnvelope(_key, _fullStructure());
      envelope['schema'] = kStructureCacheSchema + 1;
      expect(decodeStructureEnvelope(envelope, key: _key), isNull);
    });

    test('T06 形状损坏 → miss 不抛', () {
      expect(decodeStructureEnvelope('not a map', key: _key), isNull);
      expect(decodeStructureEnvelope(42, key: _key), isNull);
      expect(decodeStructureEnvelope(<String, Object?>{}, key: _key), isNull);

      // structure 在、但 toc 项缺字段。
      final Map<String, Object?> envelope =
          encodeStructureEnvelope(_key, _fullStructure());
      ((envelope['structure'] as Map<String, Object?>)['toc'] as List)
          .add(<String, Object?>{'href': 'x'});
      expect(decodeStructureEnvelope(envelope, key: _key), isNull);
    });
  });

  group('DartEpubSource 缓存接线', () {
    test('T06 miss → 派发 1 次 + 写回 1 次；同判据重开 → 零派发', () async {
      final _FakeStore fake = _FakeStore();
      final _RecordingRunner runner1 = _RecordingRunner();
      final DartEpubSource first = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        runner: runner1,
        structureCache: fake,
        cacheKey: _key,
      );
      final BookMeta meta1 = await first.load();
      expect(meta1.title, '缓存测试书');
      expect(runner1.messages.length, 1); // miss：派发一次
      expect(fake.reads, 1);
      expect(fake.writes, 1); // 解析成功后写回

      // 重开（同 bytes、同判据）：命中 → 零派发。
      final _RecordingRunner runner2 = _RecordingRunner();
      final DartEpubSource second = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        runner: runner2,
        structureCache: fake,
        cacheKey: _key,
      );
      final BookMeta meta2 = await second.load();
      expect(meta2.title, '缓存测试书');
      expect(runner2.messages, isEmpty); // 里程碑验收：重开零解析
      expect(fake.writes, 1); // 命中不重写
      await first.dispose();
      await second.dispose();
    });

    test('T06 mtime 变化 → 判据失效，重解析并覆盖写回', () async {
      final _FakeStore fake = _FakeStore();
      final DartEpubSource first = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        structureCache: fake,
        cacheKey: _key,
      );
      await first.load();
      expect(fake.writes, 1);

      // 同 bookId、mtime 变化（副本被替换）→ 判据失效。
      const StructureCacheKey touched = StructureCacheKey(
        bookId: '0123456789abcdef',
        mtimeMs: 1759400000000,
        size: 4096,
      );
      final _RecordingRunner runner = _RecordingRunner();
      final DartEpubSource second = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        runner: runner,
        structureCache: fake,
        cacheKey: touched,
      );
      final BookMeta meta = await second.load();
      expect(meta.title, '缓存测试书');
      expect(runner.messages.length, 1); // 失效 → 重新派发解析
      expect(fake.writes, 2); // 新判据覆盖写回
      await first.dispose();
      await second.dispose();
    });

    test('T06 缓存读故障 → 当 miss，开书不受影响', () async {
      final _FakeStore fake = _FakeStore()..throwOnRead = true;
      final _RecordingRunner runner = _RecordingRunner();
      final DartEpubSource source = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        runner: runner,
        structureCache: fake,
        cacheKey: _key,
      );
      final BookMeta meta = await source.load();
      expect(meta.title, '缓存测试书');
      expect(runner.messages.length, 1); // 回落正常解析
      await source.dispose();
    });

    test('T06 缓存写故障 → 开书不受影响，不写不抛', () async {
      final _FakeStore fake = _FakeStore()..throwOnWrite = true;
      final _RecordingRunner runner = _RecordingRunner();
      final DartEpubSource source = DartEpubSource(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        runner: runner,
        structureCache: fake,
        cacheKey: _key,
      );
      final BookMeta meta = await source.load();
      expect(meta.title, '缓存测试书');
      expect(runner.messages.length, 1);
      expect(fake.byBook, isEmpty); // 写失败被吞，缓存保持空
      await source.dispose();
    });

    test('T06 注入缝：openBook 成对透传到 DartEpubSource', () async {
      final _FakeStore fake = _FakeStore();
      final BookSource source = await openBook(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        structureCache: fake,
        cacheKey: _key,
      );
      expect(source, isA<DartEpubSource>());
      final DartEpubSource epub = source as DartEpubSource;
      expect(epub.structureCache, same(fake));
      expect(epub.cacheKey, _key);

      // 缺对（不给 cacheKey）→ 字段透传但按「未启用」处理（读写均为 0）。
      final BookSource bare = await openBook(
        fileName: 'mini.epub',
        bytes: _miniEpub(),
        structureCache: fake,
      );
      expect((bare as DartEpubSource).cacheKey, isNull);
      await bare.load();
      expect(fake.reads, 0);
      expect(fake.writes, 0);
      await source.dispose();
      await bare.dispose();
    });
  });

  group('FileStructureCacheStore（磁盘）', () {
    late Directory tmp;
    late _TmpPaths paths;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mreader_struct_cache_');
      paths = _TmpPaths(tmp);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('T06 write → read 往返命中；判据变 → null；delete → null', () async {
      final FileStructureCacheStore store = FileStructureCacheStore(paths);
      await store.write(_key, _fullStructure());

      final EpubStructure? hit = await store.read(_key);
      expect(hit, isNotNull);
      expect(hit!.title, '缓存测试书');
      expect(hit.sections.length, 2);
      expect(hit.flatTitles, <String, String>{'OEBPS/text/ch1.xhtml': '章节标题'});

      // mtime 变 → 信封判据不符 → miss。
      expect(
        await store.read(const StructureCacheKey(
            bookId: '0123456789abcdef', mtimeMs: 1, size: 4096)),
        isNull,
      );

      await store.delete(_key.bookId);
      expect(await store.read(_key), isNull);
      // 主文件与轮转备份一并清理。
      expect(
        File('${tmp.path}${Platform.pathSeparator}structure'
                '${Platform.pathSeparator}0123456789abcdef.json')
            .existsSync(),
        isFalse,
      );
      expect(
        File('${tmp.path}${Platform.pathSeparator}structure'
                '${Platform.pathSeparator}0123456789abcdef.json.bak')
            .existsSync(),
        isFalse,
      );
    });

    test('T06 损坏文件 → 隔离为 .corrupt 并按 miss 返回，不抛', () async {
      final Directory dir = await paths.subDir('structure');
      final File file = File(
        '${dir.path}${Platform.pathSeparator}0123456789abcdef.json',
      );
      file.writeAsStringSync('{ 坏掉的 json');

      final FileStructureCacheStore store = FileStructureCacheStore(paths);
      expect(await store.read(_key), isNull); // 损坏 → miss（无 .bak 可回退）
      expect(
        File('${file.path}.corrupt').existsSync(),
        isTrue, // 损坏文件被隔离，不静默丢弃（DATA-01 ②）
      );
    });
  });
}
