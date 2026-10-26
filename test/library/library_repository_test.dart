// `lib/library/library_repository_test.dart`：LibraryRepository 集成测试。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
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

/// 最简 TXT 内容。
Uint8List _txtBytes([String content = '这是正文内容。']) =>
    Uint8List.fromList(utf8.encode(content));

void main() {
  group('LibraryRepository', () {
    late Directory tempDir;
    late LibraryRepository repo;
    late FileCoverStore coverStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_repo_');
      final AppPaths paths = _TestAppPaths(tempDir);
      coverStore = FileCoverStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: coverStore);
    });

    tearDown(() async {
      // 三层解析缓存与导入预热已下线（2026-10-26，内核唯一实现）：
      // 导入本身同步落盘，删目录前不再有后台写盘任务要等。
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('首次 loadBooks 返回空列表', () async {
      expect(await repo.loadBooks(), isEmpty);
    });

    test('importFile：TXT 导入 → 文件落盘 + 索引更新 + isNew=true', () async {
      final Uint8List bytes = _txtBytes('第一本书的内容。');
      final ImportResult result = await repo.importFile(
        bytes: bytes,
        fileName: '好书.txt',
      );

      expect(result.isNew, isTrue);
      expect(result.record.title, isNotEmpty);
      expect(result.record.format, 'txt');

      // 索引已更新
      final List<BookRecord> books = await repo.loadBooks();
      expect(books, hasLength(1));
      expect(books[0].bookId, result.record.bookId);

      // 副本文件存在
      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}${result.record.filePath}',
      );
      expect(await file.exists(), isTrue);
    });

    test('LIB-05：同内容二次导入 → isNew=false，索引仍 1 条', () async {
      final Uint8List bytes = _txtBytes('同一本书的内容。');
      final ImportResult first = await repo.importFile(
        bytes: bytes,
        fileName: '好书.txt',
      );
      expect(first.isNew, isTrue);

      final ImportResult second = await repo.importFile(
        bytes: bytes,
        fileName: '好书_副本.txt', // 同名不同名无所谓——内容相同就判重
      );
      expect(second.isNew, isFalse);
      expect(second.record.bookId, first.record.bookId);

      expect(await repo.loadBooks(), hasLength(1));
    });

    test('LIB-05：同名不同内容 → 可共存（两条）', () async {
      final ImportResult a = await repo.importFile(
        bytes: _txtBytes('内容A'),
        fileName: '同名.txt',
      );
      final ImportResult b = await repo.importFile(
        bytes: _txtBytes('内容B'),
        fileName: '同名.txt',
      );
      expect(a.isNew, isTrue);
      expect(b.isNew, isTrue);
      expect(a.record.bookId, isNot(b.record.bookId));

      expect(await repo.loadBooks(), hasLength(2));
    });

    test('LIB-06：deleteBook → 副本删除 + 索引移除', () async {
      final ImportResult result = await repo.importFile(
        bytes: _txtBytes('要删的书。'),
        fileName: '删我.txt',
      );
      expect(await repo.loadBooks(), hasLength(1));

      // 记下副本路径
      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}library${Platform.pathSeparator}${result.record.filePath}',
      );
      expect(await file.exists(), isTrue);

      // 删除
      await repo.deleteBook(result.record);

      // 索引清空
      expect(await repo.loadBooks(), isEmpty);
      // 副本文件已删
      expect(await file.exists(), isFalse);
    });

    test('LIB-06：删一本书不影响其余书', () async {
      final ImportResult a = await repo.importFile(
        bytes: _txtBytes('书A'),
        fileName: 'a.txt',
      );
      final ImportResult b = await repo.importFile(
        bytes: _txtBytes('书B'),
        fileName: 'b.txt',
      );
      expect(await repo.loadBooks(), hasLength(2));

      await repo.deleteBook(a.record);

      final List<BookRecord> remaining = await repo.loadBooks();
      expect(remaining, hasLength(1));
      expect(remaining[0].bookId, b.record.bookId);
    });

    test('LIB-06：删书后副本不残留（三层解析缓存已下线，目录不得再生）', () async {
      final ImportResult result = await repo.importFile(
        bytes: _txtBytes('刚导入就删的书。'),
        fileName: '秒删.txt',
      );
      await repo.deleteBook(result.record);

      // library/ 副本必须消失（LIB-06 ①）。
      final File bookFile = await repo.bookFile(result.record);
      expect(await bookFile.exists(), isFalse);

      // 三层缓存（outline / chapters / structure）已随纯 Dart 源下线：这些
      // 目录**不该再出现**；出现即说明有人把已删的基建接了回来。
      for (final String sub in <String>['outline', 'chapters', 'structure']) {
        final Directory dir = Directory(
          '${tempDir.path}${Platform.pathSeparator}$sub',
        );
        expect(await dir.exists(), isFalse,
            reason: '$sub/ 属已下线的解析缓存目录，不应再生');
      }
    });

    test('purgeOrphans：孤儿封面被清理', () async {
      // 导入一本 TXT（NoCover → 无封面文件）
      await repo.importFile(
        bytes: _txtBytes('没有封面的书'),
        fileName: '无封面.txt',
      );

      // 手动放一个孤儿封面文件到 covers/
      final Directory realCovers = Directory(
        '${tempDir.path}${Platform.pathSeparator}covers',
      );
      await realCovers.create(recursive: true);
      final File orphan = File(
        '${realCovers.path}${Platform.pathSeparator}orphan.cover.jpg',
      );
      await orphan.writeAsBytes(<int>[0xFF, 0xD8, 0xFF], flush: true);
      expect(await orphan.exists(), isTrue);

      // purgeOrphans 应删除它（不在 index 引用集合中）
      final int removed = await repo.purgeOrphans();
      expect(removed, greaterThanOrEqualTo(1));
      expect(await orphan.exists(), isFalse);
    });
  });
}
