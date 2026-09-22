// `RD-04`：进度持久化单测（纯 Dart，用 `test()` 而非 `testWidgets()`）。
//
// ⚠️ 用 `test()` 而非 `testWidgets()`：后者运行在 FakeAsync 区，真异步 IO 需要
// `tester.runAsync` 包裹否则挂死；`test()` 不在 FakeAsync 区，直接 `await` 即可。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reading_progress.dart';

/// 临时目录实现 [AppPaths]，仅用于测试（与 `test/ui/shelf_page_test.dart` 同款）。
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

ReadingProgress _sample({
  String bookId = 'abc123',
  String chapterHref = 'txt:100',
  int chapterIndex = 2,
  double chapterPos = 0.25,
  int updatedAt = 1700000000000,
}) {
  return ReadingProgress(
    bookId: bookId,
    chapterHref: chapterHref,
    chapterIndex: chapterIndex,
    chapterPos: chapterPos,
    updatedAt: updatedAt,
  );
}

void main() {
  group('ProgressStore', () {
    late Directory tempDir;
    late _TestAppPaths paths;
    late ProgressStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_progress_');
      paths = _TestAppPaths(tempDir);
      store = ProgressStore(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('save 后 load 取回同一进度', () async {
      await store.save(_sample());
      final ReadingProgress? loaded = await store.load('abc123');
      expect(loaded, isNotNull);
      expect(loaded!.bookId, 'abc123');
      expect(loaded.chapterHref, 'txt:100');
      expect(loaded.chapterIndex, 2);
      expect(loaded.chapterPos, closeTo(0.25, 1e-9));
      expect(loaded.updatedAt, 1700000000000);
    });

    test('load 缺失文件 → null（且不抛）', () async {
      expect(await store.load('nobody'), isNull);
    });

    test('load 损坏 JSON → null（且不抛）', () async {
      final Directory dir = await paths.subDir(ProgressStore.dirName);
      final File file = File('${dir.path}${Platform.pathSeparator}broken.json');
      await file.writeAsString('{ this is not json');
      expect(await store.load('broken'), isNull);
    });

    test('load JSON 合法但字段缺失 → null', () async {
      final Directory dir = await paths.subDir(ProgressStore.dirName);
      final File file = File('${dir.path}${Platform.pathSeparator}partial.json');
      await file.writeAsString('{"bookId":"partial"}');
      expect(await store.load('partial'), isNull);
    });

    test('load 内容 bookId 与请求不一致 → null（防串档）', () async {
      final Directory dir = await paths.subDir(ProgressStore.dirName);
      final File file = File('${dir.path}${Platform.pathSeparator}other.json');
      await file.writeAsString(
        '{"bookId":"someoneelse","chapterHref":"h","chapterIndex":0,'
        '"chapterPos":0.0,"updatedAt":1}',
      );
      expect(await store.load('other'), isNull);
    });

    test('remove 删除进度文件（含备份兄弟文件）', () async {
      await store.save(_sample());
      expect(await store.load('abc123'), isNotNull);
      // 再写一次以生成 .bak 兄弟文件，验证 remove 一并清理。
      await store.save(_sample(chapterPos: 0.5));
      await store.remove('abc123');
      expect(await store.load('abc123'), isNull);

      final Directory dir = await paths.subDir(ProgressStore.dirName);
      final List<String> leftovers = dir
          .listSync()
          .map((FileSystemEntity e) => e.path.split(Platform.pathSeparator).last)
          .where((String name) => name.startsWith('abc123'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('remove 不存在 → 静默成功（幂等）', () async {
      await store.remove('neverSaved');
      await store.remove('neverSaved');
    });

    test('save / load / remove 非法 bookId → ArgumentError', () async {
      await expectLater(
        store.save(_sample(bookId: '../evil')),
        throwsArgumentError,
      );
      await expectLater(store.load('a/b'), throwsArgumentError);
      await expectLater(store.remove('bad name'), throwsArgumentError);
      await expectLater(store.remove(''), throwsArgumentError);
    });

    test('多本书记录相互独立', () async {
      await store.save(_sample(bookId: 'bookA', chapterPos: 0.1));
      await store.save(_sample(bookId: 'bookB', chapterPos: 0.9));
      expect((await store.load('bookA'))!.chapterPos, closeTo(0.1, 1e-9));
      expect((await store.load('bookB'))!.chapterPos, closeTo(0.9, 1e-9));
    });
  });
}
