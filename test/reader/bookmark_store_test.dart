// `TYP-06`：书签模型与持久化单测（纯 Dart，用 `test()` 而非 `testWidgets()`）。
//
// ⚠️ 用 `test()` 而非 `testWidgets()`：后者运行在 FakeAsync 区，真异步 IO 需要
// `tester.runAsync` 包裹否则挂死；`test()` 不在 FakeAsync 区，直接 `await` 即可
// （与 `progress_store_test.dart` 同款写法）。
//
// 预期值人工推演：
//   · `chapterPos` 构造 clamp 到 `[0, 1]`：传 1.5 → 1.0，传 -0.2 → 0.0；
//   · 书签文件**每书一个**（`bookmarks/<bookId>.json`），顶层带 `bookId` 哨兵——
//     串档文件（顶层 bookId 不符）整体作废返回空表；单条损坏只丢单条；
//   · `remove` 幂等，且连 `.bak` / `.corrupt` / `.tmp` 兄弟文件一并清理。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/bookmark.dart';
import 'package:mreader/reader/bookmark_store.dart';

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

Bookmark _sample({
  String bookId = 'abc123',
  String chapterHref = 'txt:100',
  int chapterIndex = 2,
  double chapterPos = 0.25,
  String chapterTitle = '第三章',
  int createdAt = 1700000000000,
}) {
  return Bookmark(
    bookId: bookId,
    chapterHref: chapterHref,
    chapterIndex: chapterIndex,
    chapterPos: chapterPos,
    chapterTitle: chapterTitle,
    createdAt: createdAt,
  );
}

void main() {
  group('Bookmark（值对象）', () {
    test('chapterPos 构造 clamp 到 [0, 1]', () {
      expect(_sample(chapterPos: 1.5).chapterPos, 1.0);
      expect(_sample(chapterPos: -0.2).chapterPos, 0.0);
      expect(_sample(chapterPos: 0.25).chapterPos, 0.25);
    });

    test('toJson 往返保持全部字段', () {
      final Bookmark bookmark = _sample();
      final Bookmark? restored = Bookmark.fromJson(bookmark.toJson());
      expect(restored, bookmark); // 值相等（== 覆盖全部字段）
    });

    test('fromJson 防御：非 Map / 字段缺失 / 类型错 → null', () {
      expect(Bookmark.fromJson(null), isNull);
      expect(Bookmark.fromJson('x'), isNull);
      expect(Bookmark.fromJson(<String, Object?>{'bookId': 'abc123'}), isNull);
      expect(
        Bookmark.fromJson(<String, Object?>{
          'bookId': 'abc123',
          'chapterHref': 'h1',
          'chapterIndex': 'x', // 类型错（应为 num）
          'chapterPos': 0.5,
          'chapterTitle': '第一章',
          'createdAt': 1,
        }),
        isNull,
      );
    });
  });

  group('BookmarkStore', () {
    late Directory tempDir;
    late BookmarkStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_bookmarks_');
      store = BookmarkStore(_TestAppPaths(tempDir));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('往返：保存 2 条按添加顺序读回', () async {
      final List<Bookmark> bookmarks = <Bookmark>[
        _sample(createdAt: 100, chapterTitle: '第一章'),
        _sample(createdAt: 200, chapterTitle: '第二章'),
      ];
      await store.save('abc123', bookmarks);

      final List<Bookmark> loaded = await store.load('abc123');
      expect(loaded, bookmarks);
      expect(loaded.first.createdAt, 100);
      expect(loaded.last.createdAt, 200);
    });

    test('按书隔离：不同 bookId 各自独立文件、互不影响', () async {
      await store.save('book_a', <Bookmark>[
        _sample(bookId: 'book_a', createdAt: 1),
        _sample(bookId: 'book_a', createdAt: 2),
      ]);
      await store.save('book_b', <Bookmark>[
        _sample(bookId: 'book_b', createdAt: 3),
      ]);

      expect((await store.load('book_a')).length, 2);
      expect((await store.load('book_b')).length, 1);

      await store.remove('book_a');
      expect((await store.load('book_a')), isEmpty);
      // 验收④口径（LIB-06）：删一本不影响其余书。
      expect((await store.load('book_b')).length, 1);
    });

    test('无存档 → 空表；bookId 非法 → ArgumentError', () async {
      expect(await store.load('none99'), isEmpty);
      expect(() => store.load('bad/id'), throwsArgumentError);
      expect(() => store.save('bad id', <Bookmark>[]), throwsArgumentError);
      expect(() => store.remove('..'), throwsArgumentError);
    });

    test('防串档：文件顶层 bookId 与请求不符 → 整体作废返回空表', () async {
      // 手工写入「属于别人」的书签文件到 abc123 的路径上。
      final String path = <String>[
        tempDir.path,
        BookmarkStore.dirName,
        'abc123.json',
      ].join(Platform.pathSeparator);
      await File(path).create(recursive: true);
      await File(path).writeAsString(
        '{"bookId":"zzz999","bookmarks":[{"bookId":"zzz999",'
        '"chapterHref":"h1","chapterIndex":0,"chapterPos":0.0,'
        '"chapterTitle":"第一章","createdAt":1}]}',
      );

      expect(await store.load('abc123'), isEmpty);
    });

    test('单条损坏静默丢弃，其余保留', () async {
      final String path = <String>[
        tempDir.path,
        BookmarkStore.dirName,
        'abc123.json',
      ].join(Platform.pathSeparator);
      await File(path).create(recursive: true);
      await File(path).writeAsString(
        '{"bookId":"abc123","bookmarks":['
        '{"bookId":"abc123","chapterHref":"h1","chapterIndex":0,'
        '"chapterPos":0.0,"chapterTitle":"第一章","createdAt":1},'
        '{"垃圾":true},'
        '{"bookId":"zzz999","chapterHref":"h1","chapterIndex":0,'
        '"chapterPos":0.0,"chapterTitle":"他书","createdAt":2}'
        ']}',
      );

      final List<Bookmark> loaded = await store.load('abc123');
      expect(loaded.length, 1, reason: '损坏条目与串档条目各丢一条，合法条目保留');
      expect(loaded.single.createdAt, 1);
    });

    test('文件损坏 → 空表（损坏件隔离为 .corrupt，不静默丢弃）', () async {
      await store.save('abc123', <Bookmark>[_sample()]);
      final String path = <String>[
        tempDir.path,
        BookmarkStore.dirName,
        'abc123.json',
      ].join(Platform.pathSeparator);
      await File(path).writeAsString('not-json');

      expect(await store.load('abc123'), isEmpty);
      expect(File('$path.corrupt').existsSync(), isTrue);
    });

    test('remove 幂等，且连 .bak / .corrupt / .tmp 兄弟文件一并清理', () async {
      // 保存两次 → 第二次轮转产生 .bak。
      await store.save('abc123', <Bookmark>[_sample(createdAt: 1)]);
      await store.save('abc123', <Bookmark>[
        _sample(createdAt: 1),
        _sample(createdAt: 2),
      ]);
      final String path = <String>[
        tempDir.path,
        BookmarkStore.dirName,
        'abc123.json',
      ].join(Platform.pathSeparator);
      expect(File('$path.bak').existsSync(), isTrue);

      await store.remove('abc123');
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.bak').existsSync(), isFalse);
      expect(File('$path.corrupt').existsSync(), isFalse);
      expect(File('$path.tmp').existsSync(), isFalse);

      // 幂等：再删一次静默成功。
      await store.remove('abc123');
    });

    test('parseBookmarks：非 Map / bookmarks 非 List → 空表', () {
      expect(parseBookmarks(null, 'abc123'), isEmpty);
      expect(parseBookmarks('x', 'abc123'), isEmpty);
      expect(parseBookmarks(<String, Object?>{'bookId': 'abc123'}, 'abc123'), isEmpty);
    });
  });
}
