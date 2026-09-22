// `test/ui/shelf_page_test.dart`：书架首页 widget 测试（LIB-01/05/06）。
//
// 注意：`FilePicker.platform.pickFiles()` 在 widget 测试中不可用，
// 故导入操作通过 `LibraryRepository.importFile()` 直接调用（测试后端逻辑）。
//
// ⚠️ FakeAsync 铁律：`testWidgets` 测试体跑在 FakeAsync 区，**widget 内部**
// （`initState` / 回调）发起的真异步 IO 不会自行推进；直接 `pumpAndSettle()` 会超时。
// 必须用 [_settle]（`runAsync` 让出到真实事件循环 + `pumpAndSettle` 排空+重建）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/shelf_page.dart';

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
    Uint8List.fromList(content.codeUnits);

/// 让 widget 内发起的**真异步 IO** 完成，并推进若干帧。
///
/// `testWidgets` 的测试体在 FakeAsync 区：`pumpWidget` 触发 `initState` 起的真 IO
/// （`File.exists` / `readAsString` …）其完成回调排进 **fake 微任务队列**，不会自行推进。
/// 关键在于 **交替**：`runAsync` 让出到真实事件循环让 IO 完成，`pump` 排空 fake 队列
/// 使下一段 IO 得以启动——**串行的多次 await IO 需要多轮交替**。
///
/// 不能用 `pumpAndSettle`：`ShelfPage` 载入期的 `CircularProgressIndicator` 是无限动画，
/// 只要 `_loading` 仍为 true 就永不 settle（会超时）。
Future<void> _settle(WidgetTester tester, {int rounds = 40}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  group('ShelfPage', () {
    late Directory tempDir;
    late LibraryRepository repo;
    late FileCoverStore coverStore;
    late ProgressStore progressStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_shelf_');
      final AppPaths paths = _TestAppPaths(tempDir);
      coverStore = FileCoverStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: coverStore);
      progressStore = ProgressStore(paths);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Widget buildApp() {
      return MaterialApp(
        home: ShelfPage(
          repository: repo,
          coverStore: coverStore,
          progressStore: progressStore,
        ),
      );
    }

    testWidgets('LIB-01 空态：引导文案 + 导入按钮可见', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(find.text('书架空空如也'), findsOneWidget);
      expect(find.text('导入 EPUB / TXT 文件开始阅读'), findsOneWidget);
      expect(find.text('导入书籍'), findsOneWidget);
      // 顶部 AppBar 也有导入按钮（IconButton）
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('LIB-01 导入后：书卡显示在网格中', (WidgetTester tester) async {
      // `setUp` / `tearDown` 在 FakeAsync 之外，可照常 await。
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('三体的内容'), fileName: '三体.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 空态消失
      expect(find.text('书架空空如也'), findsNothing);
      // 书卡出现
      expect(find.byType(BookCard), findsOneWidget);
      // 书名和作者可见
      expect(find.text('三体'), findsOneWidget);
    });

    testWidgets('LIB-05 多本书：网格显示多个书卡', (WidgetTester tester) async {
      await tester.runAsync(() async {
        await repo.importFile(bytes: _txtBytes('内容A'), fileName: 'a.txt');
        await repo.importFile(bytes: _txtBytes('内容B'), fileName: 'b.txt');
        await repo.importFile(bytes: _txtBytes('内容C'), fileName: 'c.txt');
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(find.byType(BookCard), findsNWidgets(3));
    });

    testWidgets('LIB-06 长按弹出删除确认对话框', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('要删的书'), fileName: '删我.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 长按书卡
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 确认对话框出现
      expect(find.text('删除确认'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('LIB-06 点击删除后书从列表移除', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('要删的书'), fileName: '删我.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 长按触发删除对话框
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 点击「删除」（`_deleteBook` 内含真 IO，需 _settle）
      await tester.tap(find.text('删除'));
      await _settle(tester);

      // 书卡消失，空态出现
      expect(find.byType(BookCard), findsNothing);
      expect(find.text('书架空空如也'), findsOneWidget);

      // 后端确认已删除
      expect(await tester.runAsync(() => repo.loadBooks()), isEmpty);
    });

    testWidgets('LIB-06 删除书时连带清理阅读进度文件', (WidgetTester tester) async {
      final ImportResult imported = (await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('带进度的书'), fileName: '进度书.txt'),
      ))!;
      final String bookId = imported.record.bookId;

      // 预置一条阅读进度，删除后应连同清理。
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: bookId,
            chapterHref: 'h1',
            chapterIndex: 0,
            chapterPos: 0.5,
            updatedAt: 1,
          ),
        ),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);
      expect(await tester.runAsync(() => progressStore.load(bookId)), isNotNull);

      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await _settle(tester);

      expect(await tester.runAsync(() => progressStore.load(bookId)), isNull);
    });

    testWidgets('LIB-06 取消删除不影响列表', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('不该删的书'), fileName: '留我.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 点击「取消」（仅关闭对话框，无 IO）
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 书卡仍在
      expect(find.byType(BookCard), findsOneWidget);
      expect(await tester.runAsync(() => repo.loadBooks()), hasLength(1));
    });
  });
}
