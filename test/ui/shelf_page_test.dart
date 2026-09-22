// `test/ui/shelf_page_test.dart`：书架首页 widget 测试（LIB-01/05/06）。
//
// 注意：`FilePicker.platform.pickFiles()` 在 widget 测试中不可用，
// 故导入操作通过 `LibraryRepository.importFile()` 直接调用（测试后端逻辑）。
//
// ⚠️ FakeAsync 铁律：`testWidgets` 测试体跑在 FakeAsync 区，**widget 内部**
// （`initState` / 回调）发起的真异步 IO 不会自行推进；直接 `pumpAndSettle()` 会超时。
// 必须用 [_settle]（`runAsync` 让出到真实事件循环 + `pumpAndSettle` 排空+重建）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
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

/// 合法 UTF-8 的 TXT 字节——**真正要打开**的书必须可解码（回归①②④走完整开书链路）。
Uint8List _utf8TxtBytes(String content) =>
    Uint8List.fromList(utf8.encode(content));

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

/// 按书名找到书卡（书名文本的最近 [BookCard] 祖先）。
Finder _cardOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(BookCard));

/// 全树范围找 [ReaderPage]（`skipOffstage: false`：被覆盖路由若仍挂着也要揪出来，
/// 否则「恰好 push 一次」的断言会被 offstage 藏掉漏检）。
Finder _readerPages() => find.byType(ReaderPage, skipOffstage: false);

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

    // —— 首点无响应回归（_opening 守卫作用域 + 准备期反馈 + InkWell）——

    testWidgets('回归①：单击一次即导航一次（无须点两次）', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(find.byType(BookCard));
      await _settle(tester);

      // 一次点击 → 恰好一次导航（全树范围计数，含被覆盖路由）。
      expect(_readerPages(), findsOneWidget);
    });

    testWidgets('回归①b：准备期连点两次也只 push 一次（防双 push 回退）',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      final Finder card = find.byType(BookCard);
      await tester.tap(card);
      await tester.tap(card); // 第二击落在准备期 → 守卫吞掉，不得再 push
      await _settle(tester);

      expect(_readerPages(), findsOneWidget);
    });

    testWidgets('回归②：从阅读页 pop 后立即点另一本 → 一次即进（主因窗口回归）',
        (WidgetTester tester) async {
      final ImportResult a = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      ))!;
      final ImportResult b = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('乙书正文。'), fileName: '乙书.txt'),
      ))!;

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 打开甲书。
      await tester.tap(_cardOf('甲书'));
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
      expect(
        tester.widget<ReaderPage>(_readerPages()).record.bookId,
        a.record.bookId,
      );

      // 关书（pop）——**只推假帧、不给 runAsync**：此刻正处主因窗口（旧代码
      // `_opening` 仍为 true），紧接着点另一本必须一次即进。
      // 注意：pop 过渡动画 ticker **首拍才起算**，单次大帧推不完；用多帧小步
      // 推完过渡 + 路由移除（全程无 runAsync，主因窗口不被破坏）。
      Navigator.of(tester.element(_readerPages())).pop();
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_readerPages(), findsNothing); // 阅读页已完全退出

      await tester.tap(_cardOf('乙书'));
      await _settle(tester);

      expect(_readerPages(), findsOneWidget);
      expect(
        tester.widget<ReaderPage>(_readerPages()).record.bookId,
        b.record.bookId,
      );
    });

    testWidgets('回归③：长按触发删除确认，不误触发 onTap', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('要删的书'), fileName: '删我2.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      expect(find.text('删除确认'), findsOneWidget);
      // onTap 未被误触发：没有导航发生。
      expect(_readerPages(), findsNothing);
    });

    testWidgets('回归④：开书准备期卡片显示 loading 覆盖层', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(find.byType(BookCard));
      await tester.pump(); // 只推一帧、不给 runAsync → 仍在准备期

      // 被点的卡片上出现 loading 覆盖层，且尚未导航。
      expect(
        find.descendant(
          of: find.byType(BookCard),
          matching: find.byKey(const ValueKey<String>('book-opening-overlay')),
        ),
        findsOneWidget,
      );
      expect(_readerPages(), findsNothing);

      // 准备完成后正常进入阅读页（覆盖层随准备完成消失）。
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
    });
  });
}
