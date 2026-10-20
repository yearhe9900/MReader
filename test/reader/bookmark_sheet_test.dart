// `TYP-06`：书签（添加 / 删除 / 列表 / 跳转 / 按书持久化）widget 测试。
//
// 验收映射（PRD `TYP-06`）：
//   ① 书签退出重进仍在（按书持久化）——加书签 → 真关书 → 换 store 实例重开 → 列表仍在；
//   ② 点击跳回该位置——第 3 章加书签 → 回第 1 章 → 点书签行 → 落回第 3 章；
//   ③ 删除后列表实时更新——点删除后**只 pump 一帧**（不等任何异步落盘）即少一条。
//
// 装具（假源 / settle / closeBook）见 `reader_harness.dart`。
// 预期值人工推演：开书落点为书首（无进度）→ 当前位置 = 第 1 章 0%，
// 书签行副标题恒为「第 1 章 · 0%」（`chapterPos` 探测在顶内边距回落 0.0；
// 即使收敛残差 ±1px 也只是 0.001 量级，向下取整后仍是 0%）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/bookmark.dart';
import 'package:mreader/reader/bookmark_sheet.dart';
import 'package:mreader/reader/bookmark_store.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('TYP-06 书签', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late BookmarkStore bookmarkStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_bm_ui_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      bookmarkStore = BookmarkStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildApp({BookmarkStore? store}) => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: repo,
            bookmarkStore: store ?? bookmarkStore,
          ),
        );

    testWidgets('验收①：添加当前书签，退出重进仍在（按书持久化）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-bookmarks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bookmark-add')));
      await tester.pump(); // 列表即时出现（不等落盘）。

      // 列表出现一条：第一章 · 「第 1 章 · 0%」（范围限定弹窗内，正文同名文本不干扰）。
      final Finder sheet = find.byType(BookmarkSheet);
      expect(
        find.descendant(of: sheet, matching: find.byType(ListTile)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('第一章')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('第 1 章 · 0%')),
        findsOneWidget,
      );

      await settle(tester); // 排空落盘
      final List<Bookmark>? saved =
          await tester.runAsync<List<Bookmark>>(() => bookmarkStore.load('testbook01'));
      expect(saved, hasLength(1));
      expect(saved!.single.bookId, 'testbook01');
      expect(saved.single.chapterHref, 'h1');
      expect(saved.single.chapterIndex, 0);
      expect(saved.single.chapterTitle, '第一章');
      // 推演：书首探测 pos 回落 0.0（收敛残差 ±1px ≈ 0.001 量级）。
      expect(saved.single.chapterPos, inInclusiveRange(0.0, 0.02));

      // 真·关书再开（同类型 widget 会复用 State，必须换异类拆树）。
      await closeBook(tester);

      // 第二次打开：换一个 store 实例（模拟重启）→ 书签仍在。
      await tester.pumpWidget(buildApp(store: BookmarkStore(paths)));
      await settle(tester);
      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-bookmarks')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BookmarkSheet),
          matching: find.byType(ListTile),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(BookmarkSheet),
          matching: find.text('第 1 章 · 0%'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('验收②：点书签跳回标记位置', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 去第 3 章，在那里加书签。
      await showChrome(tester);
      await tester.tap(find.byIcon(Icons.list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第三章'));
      await tester.pumpAndSettle();
      await settle(tester);
      await tester.pumpAndSettle();
      expect(chapterHeading('第三章'), findsOneWidget);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-bookmarks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bookmark-add')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(BookmarkSheet),
          matching: find.text('第 3 章 · 0%'),
        ),
        findsOneWidget,
        reason: '书签应记在第 3 章（当前位置）',
      );

      // 关弹窗 → 回第 1 章 → 再开弹窗点书签行 → 应跳回第 3 章。
      Navigator.of(tester.element(find.byType(BookmarkSheet))).pop();
      await tester.pumpAndSettle();
      await showChrome(tester);
      await tester.tap(find.byIcon(Icons.list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第一章'));
      await tester.pumpAndSettle();
      await settle(tester);
      await tester.pumpAndSettle();
      expect(chapterHeading('第一章'), findsOneWidget);
      expect(chapterHeading('第三章'), findsNothing);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-bookmarks')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(BookmarkSheet),
          matching: find.byType(ListTile),
        ),
      );
      await tester.pumpAndSettle();
      await settle(tester);
      await tester.pumpAndSettle();

      // 验收②：落回书签标记的第 3 章。
      expect(chapterHeading('第三章'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);
      expect(find.textContaining('第3章'), findsWidgets);
    });

    testWidgets('验收③：删除书签后列表实时更新', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-bookmarks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bookmark-add')));
      await tester.tap(find.byKey(const Key('bookmark-add')));
      await tester.pump();
      final Finder rows = find.descendant(
        of: find.byType(BookmarkSheet),
        matching: find.byType(ListTile),
      );
      expect(rows, findsNWidgets(2));

      // 删除第一条：**只 pump 一帧**（不等任何异步落盘）列表即少一条 —— 实时。
      await tester.tap(find.byKey(const Key('bookmark-delete-0')));
      await tester.pump();
      expect(rows, findsOneWidget);

      // 落盘结果收敛到 1 条（删除也即时持久化）。
      //
      // **条件驱动**而非固定轮数：玻璃弹层在 `flutter test` 的软件光栅下每帧
      // 带数百毫秒真实异步开销（`liquid_glass_widgets` 的背景捕获路径，见
      // §2.26），固定 60 轮会逼近 30s 超时线、整组并发跑必炸。
      // 故一轮让出多次真实事件循环（IO 完成回调靠它投递）+ 一次 `pump` 排空
      // 假区微任务，条件满足即退出；20 轮上限兜底防「永不落盘」时挂满超时。
      List<Bookmark>? saved;
      for (int round = 0; round < 20; round++) {
        saved = await tester.runAsync<List<Bookmark>>(() async {
          for (int k = 0; k < 16; k++) {
            await Future<void>.delayed(Duration.zero);
          }
          return bookmarkStore.load('testbook01');
        });
        if (saved != null && saved.length == 1) break;
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(saved, hasLength(1), reason: '删除后落盘结果应收敛到 1 条');
    });
  });
}
