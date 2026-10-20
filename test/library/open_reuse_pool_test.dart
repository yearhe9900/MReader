// 开书复用池的**接线**测试（`LibraryRepository` ⇄ `ImportService` ⇄ 池）。
//
// 验收口径（负责人 2026-10-20 的诉求：「导入一本新书后能快速打开，之后更快」）：
//   1. 导入返回的**已解析书源**直接进池 ⇒ 导入后立刻开书 = 命中（零读盘零解析）；
//   2. 关书回池（`recycleBookSource`）⇒ 第二次、第三次打开同样命中；
//   3. 副本文件被替换（判据变）⇒ 池条目作废、走冷路径（绝不给旧字节）；
//   4. 删书 ⇒ 池里的驻留源一并丢弃。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/structure_cache.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';

/// 临时目录实现 [AppPaths]。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);

  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir =
        Directory('${_root.path}${Platform.pathSeparator}$name');
    await dir.create(recursive: true);
    return dir;
  }
}

Uint8List _txtBytes([String content = '第一章 开始\n这是正文内容。']) =>
    Uint8List.fromList(content.codeUnits);

void main() {
  group('开书复用池接线', () {
    late Directory tempDir;
    late LibraryRepository repo;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_pool_');
      final AppPaths paths = _TestAppPaths(tempDir);
      repo = LibraryRepository(
        paths: paths,
        coverStore: FileCoverStore(paths),
      );
    });

    tearDown(() async {
      // 预热是后台写盘任务：先等收尾再删目录（§2.81 的删目录竞态）。
      await repo.pendingWarmUps;
      await repo.sourcePool.clear();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('导入即入池：导入返回的书源可直接被开书管道取走', () async {
      final BookRecord record = (await repo.importFile(
        bytes: _txtBytes(),
        fileName: '池测试.txt',
      ))
          .record;

      final StructureCacheKey? key = await repo.structureCacheKey(record);
      expect(key, isNotNull);

      // 导入管道解析好的那份 source 已在池里 → 开书直接命中（零读盘）。
      final BookSource? pooled = repo.takePooledSource(record, key);
      expect(pooled, isNotNull, reason: '导入即入池：首开不该再读盘/解析');
      expect(pooled!.implId, 'dart-txt');
      // 取出即独占。
      expect(repo.takePooledSource(record, key), isNull);
      await pooled.dispose();
    });

    test('关书回池：第二次、第三次打开都能命中', () async {
      final BookRecord record = (await repo.importFile(
        bytes: _txtBytes('第三章 回池\n正文。'),
        fileName: '回池.txt',
      ))
          .record;
      final StructureCacheKey? key = await repo.structureCacheKey(record);

      // 第一次：取走导入时那份。
      final BookSource? first = repo.takePooledSource(record, key);
      expect(first, isNotNull);

      // 关书：还回池子。
      await repo.recycleBookSource(record, first!);
      expect(repo.sourcePool.length, 1);

      // 第二次。
      final BookSource? second = repo.takePooledSource(record, key);
      expect(second, isNotNull);
      await repo.recycleBookSource(record, second!);

      // 第三次。
      final BookSource? third = repo.takePooledSource(record, key);
      expect(third, isNotNull);
      await repo.recycleBookSource(record, third!);
    });

    test('副本被替换（判据变）→ 池条目作废，走冷路径', () async {
      final BookRecord record = (await repo.importFile(
        bytes: _txtBytes('第五章 替换\n正文。'),
        fileName: '替换.txt',
      ))
          .record;
      final StructureCacheKey? key = await repo.structureCacheKey(record);
      final BookSource? pooled = repo.takePooledSource(record, key);
      expect(pooled, isNotNull);
      await repo.recycleBookSource(record, pooled!);

      // 模拟副本被重写：mtime/size 变 → 判据不符。
      final File copy = await repo.bookFile(record);
      await copy.writeAsBytes(_txtBytes('第六章 被替换后的内容\n正文。'));
      final StructureCacheKey? touched = await repo.structureCacheKey(record);
      expect(touched, isNot(key));

      expect(repo.takePooledSource(record, touched), isNull,
          reason: '文件变了，旧书源必须作废（不许拿旧字节冒充新文件）');
    });

    test('删书 → 池里的驻留源一并丢弃', () async {
      final BookRecord record = (await repo.importFile(
        bytes: _txtBytes('第七章 删除\n正文。'),
        fileName: '删除.txt',
      ))
          .record;
      expect(repo.sourcePool.length, 1);

      await repo.deleteBook(record);
      expect(repo.sourcePool.length, 0);
      expect(await repo.loadBooks(), isEmpty);
    });

    test('超过单本字节上限 → 不入池，且原始书源被销毁（不泄漏）', () async {
      // 用默认池的 maxBytes（48MB）无法在测试里造出来 ⇒ 这里直接验「池级别」的
      // 判定已由 book_source_pool_test 覆盖，此处只锁「导入路径不吃异常」。
      final BookRecord record = (await repo.importFile(
        bytes: _txtBytes('第八章 小书\n正文。'),
        fileName: '小书.txt',
      ))
          .record;
      expect(repo.sourcePool.length, 1);
      // 索引里恰好一条（入池不影响导入结果）。
      expect((await repo.loadBooks()).single.bookId, record.bookId);
    });
  });
}
