// `lib/library/book_index_test.dart`：BookIndex 单测（LIB-03 逐条降级）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_index.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/platform/app_paths.dart';

/// 临时目录实现 [AppPaths]，仅用于测试。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir = Directory(
      '${_root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}

/// 构造一个测试用 [BookRecord]。
BookRecord _makeRecord({
  String bookId = 'aabbccdd11223344',
  String fileName = '三体.epub',
  String filePath = 'aabbccdd11223344.epub',
  String title = '三体',
  String author = '刘慈欣',
  String format = 'epub',
  CoverRef cover = const NoCover(),
  int importedAt = 1695300000000,
}) {
  return BookRecord(
    bookId: bookId,
    fileName: fileName,
    filePath: filePath,
    title: title,
    author: author,
    format: format,
    cover: cover,
    importedAt: importedAt,
  );
}

void main() {
  group('BookIndex', () {
    late Directory tempDir;
    late BookIndex index;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_test_');
      index = BookIndex(_TestAppPaths(tempDir));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('首次加载返回空列表', () async {
      expect(await index.load(), isEmpty);
    });

    test('写入后读回：字段逐一匹配', () async {
      final List<BookRecord> originals = <BookRecord>[
        _makeRecord(bookId: 'aaaa1111', title: '三体', fileName: '三体.epub'),
        _makeRecord(
          bookId: 'bbbb2222',
          title: '活着',
          fileName: '活着.txt',
          filePath: 'bbbb2222.txt',
          format: 'txt',
        ),
      ];

      await index.save(originals);
      final List<BookRecord> loaded = await index.load();

      expect(loaded, hasLength(2));
      expect(loaded[0].bookId, 'aaaa1111');
      expect(loaded[0].title, '三体');
      expect(loaded[0].format, 'epub');
      expect(loaded[1].bookId, 'bbbb2222');
      expect(loaded[1].title, '活着');
      expect(loaded[1].format, 'txt');
    });

    test('覆盖写入：新列表完全替换旧列表', () async {
      await index.save(<BookRecord>[
        _makeRecord(bookId: 'old00001', title: '旧书'),
      ]);
      expect(await index.load(), hasLength(1));

      await index.save(<BookRecord>[
        _makeRecord(bookId: 'new00001', title: '新书A'),
        _makeRecord(bookId: 'new00002', title: '新书B'),
      ]);
      final List<BookRecord> loaded = await index.load();
      expect(loaded, hasLength(2));
      expect(loaded[0].title, '新书A');
      expect(loaded[1].title, '新书B');
    });

    test('LIB-03：索引写成非法 JSON 内容仍能启动（回退为空）', () async {
      // 先写一条有效记录。
      await index.save(<BookRecord>[_makeRecord()]);
      expect(await index.load(), hasLength(1));

      // 手工把索引文件写成非法 JSON（绕过 JsonStore 直接写文件）。
      final String indexPath =
          '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}index.json';
      await File(indexPath).writeAsString('这不是合法的 JSON', flush: true);

      // 加载：应返回空列表（损坏 → 隔离 + 回退 → 无 .bak → null → 空列表）。
      final List<BookRecord> loaded = await index.load();
      expect(loaded, isEmpty, reason: '非法 JSON 应降级为空列表，不崩溃');
    });

    test('LIB-03：列表含损坏条目时跳过该条，其余正常加载', () async {
      // 直接把 JSON 数组写到索引文件，其中一条合法一条损坏。
      final String indexPath =
          '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}index.json';
      await Directory('${tempDir.path}${Platform.pathSeparator}library')
          .create(recursive: true);
      final String badJson = '[ '
          '{"bookId":"ok111111","fileName":"好书.epub","filePath":"ok111111.epub","title":"好书","author":"好作者","format":"epub","cover":{"kind":"none"},"importedAt":1695300000000}, '
          '{"这一条":"缺少 bookId 等必填字段"}, '
          '{"bookId":"ok222222","fileName":"第二好书.epub","filePath":"ok222222.epub","title":"第二好书","author":"好作者","format":"epub","cover":{"kind":"none"},"importedAt":1695300000001}'
          ']';
      await File(indexPath).writeAsString(badJson, flush: true);

      final List<BookRecord> loaded = await index.load();
      expect(loaded, hasLength(2),
          reason: '损坏条目跳过，两条合法记录正常加载');
      expect(loaded[0].bookId, 'ok111111');
      expect(loaded[1].bookId, 'ok222222');
    });

    test('LIB-03：列表含非 Map 条目（字符串）时跳过', () async {
      final String indexPath =
          '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}index.json';
      await Directory('${tempDir.path}${Platform.pathSeparator}library')
          .create(recursive: true);
      // 有效记录 + 一条纯字符串 + 一条数字
      final String mixedJson = '[ '
          '{"bookId":"ok333333","fileName":"好书.epub","filePath":"ok333333.epub","title":"好书","author":"好作者","format":"epub","cover":{"kind":"none"},"importedAt":1695300000000}, '
          '"不是一本书", '
          '42'
          ']';
      await File(indexPath).writeAsString(mixedJson, flush: true);

      final List<BookRecord> loaded = await index.load();
      expect(loaded, hasLength(1));
      expect(loaded[0].bookId, 'ok333333');
    });

    test('StoredCover 封面引用 round-trip', () async {
      final BookRecord record = _makeRecord(
        cover: const StoredCover('aabbccdd11223344.cover.jpg'),
      );
      await index.save(<BookRecord>[record]);
      final List<BookRecord> loaded = await index.load();
      expect(loaded, hasLength(1));
      expect(loaded[0].cover, isA<StoredCover>());
      expect((loaded[0].cover as StoredCover).fileName, 'aabbccdd11223344.cover.jpg');
    });

    test('PendingCover 不得持久化（encodeCoverRef 抛 StateError）', () async {
      final BookRecord record = _makeRecord(
        cover: PendingCover(
          // 这里用空字节，实际内容不重要；只需要 cover 类型是 PendingCover。
          Uint8List(0),
          CoverFormat.png,
        ),
      );
      expect(
        () => index.save(<BookRecord>[record]),
        throwsA(isA<StateError>()),
        reason: 'PendingCover 序列化时应抛 StateError（持久化不变式）',
      );
    });
  });
}
