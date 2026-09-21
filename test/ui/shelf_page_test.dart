// `lib/ui/shelf_page_test.dart`：书架首页 widget 测试（LIB-01/05/06）。
//
// 注意：`FilePicker.platform.pickFiles()` 在 widget 测试中不可用，
// 故导入操作通过 `LibraryRepository.importFile()` 直接调用（测试后端逻辑），
// UI 通过 `setState` / 重建自动刷新。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
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

void main() {
  group('ShelfPage', () {
    late Directory tempDir;
    late LibraryRepository repo;
    late FileCoverStore coverStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_shelf_');
      final AppPaths paths = _TestAppPaths(tempDir);
      coverStore = FileCoverStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: coverStore);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Widget buildApp() {
      return MaterialApp(
        home: ShelfPage(repository: repo, coverStore: coverStore),
      );
    }

    testWidgets('LIB-01 空态：引导文案 + 导入按钮可见', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(find.text('书架空空如也'), findsOneWidget);
      expect(find.text('导入 EPUB / TXT 文件开始阅读'), findsOneWidget);
      expect(find.text('导入书籍'), findsOneWidget);
      // 顶部 AppBar 也有导入按钮（IconButton）
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('LIB-01 导入后：书卡显示在网格中', (WidgetTester tester) async {
      // 先通过仓库导入一本书
      await repo.importFile(bytes: _txtBytes('三体的内容'), fileName: '三体.txt');

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      // 空态消失
      expect(find.text('书架空空如也'), findsNothing);
      // 书卡出现
      expect(find.byType(BookCard), findsOneWidget);
      // 书名和作者可见
      expect(find.text('三体'), findsOneWidget);
    });

    testWidgets('LIB-05 多本书：网格显示多个书卡', (WidgetTester tester) async {
      await repo.importFile(bytes: _txtBytes('内容A'), fileName: 'a.txt');
      await repo.importFile(bytes: _txtBytes('内容B'), fileName: 'b.txt');
      await repo.importFile(bytes: _txtBytes('内容C'), fileName: 'c.txt');

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(find.byType(BookCard), findsNWidgets(3));
    });

    testWidgets('LIB-06 长按弹出删除确认对话框', (WidgetTester tester) async {
      await repo.importFile(bytes: _txtBytes('要删的书'), fileName: '删我.txt');

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      // 长按书卡
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 确认对话框出现
      expect(find.text('删除确认'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('LIB-06 点击删除后书从列表移除', (WidgetTester tester) async {
      await repo.importFile(bytes: _txtBytes('要删的书'), fileName: '删我.txt');

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      // 长按触发删除对话框
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 点击「删除」
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      // 书卡消失，空态出现
      expect(find.byType(BookCard), findsNothing);
      expect(find.text('书架空空如也'), findsOneWidget);

      // 后端确认已删除
      expect(await repo.loadBooks(), isEmpty);
    });

    testWidgets('LIB-06 取消删除不影响列表', (WidgetTester tester) async {
      await repo.importFile(bytes: _txtBytes('不该删的书'), fileName: '留我.txt');

      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 点击「取消」
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 书卡仍在
      expect(find.byType(BookCard), findsOneWidget);
      expect(await repo.loadBooks(), hasLength(1));
    });
  });
}
