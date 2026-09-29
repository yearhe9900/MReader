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
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/settings/shelf_layout_store.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/book_detail_page.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/shelf_folder_page.dart';
import 'package:mreader/ui/shelf_grid.dart';
import 'package:mreader/ui/shelf_page.dart';

import '../test_config.dart';

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

/// 全树范围找 [BookDetailPage]（同上：覆盖栈里的详情页也要揪出来）。
Finder _detailPages() => find.byType(BookDetailPage, skipOffstage: false);

/// 长按启动拖拽。
///
/// `LongPressDraggable` 的 delay 默认是 `kLongPressTimeout`（500ms），
/// 故先推 600ms 假帧让 drag 真正启动，再交给调用方 `moveTo`。
Future<TestGesture> _startDrag(WidgetTester tester, Finder from) async {
  final TestGesture gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(const Duration(milliseconds: 600));
  return gesture;
}

/// 网格中书卡的显示顺序（element 顺序 = 网格顺序）。
List<String> _titles(WidgetTester tester) => tester
    .widgetList<BookCard>(find.byType(BookCard))
    .map((BookCard card) => card.record.title)
    .toList();

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('ShelfPage', () {
    late Directory tempDir;
    late LibraryRepository repo;
    late FileCoverStore coverStore;
    late ProgressStore progressStore;
    late ShelfPrefsStore shelfPrefs;
    late ShelfLayoutStore shelfLayout;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_shelf_');
      final AppPaths paths = _TestAppPaths(tempDir);
      coverStore = FileCoverStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: coverStore);
      progressStore = ProgressStore(paths);
      shelfPrefs = ShelfPrefsStore(tempDir);
      shelfLayout = ShelfLayoutStore(tempDir);
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
          shelfPrefs: shelfPrefs,
          shelfLayout: shelfLayout,
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

    testWidgets('LIB-06 长按弹操作单，选「移出书架」后再弹删除确认',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('要删的书'), fileName: '删我.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 长按书卡 → **底部操作单**（2026-09-28 改版，照搬 anx-reader）：
      // 长按不再直接弹删除确认，破坏性动作收进操作单，缩短误触路径。
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      expect(find.text('继续阅读'), findsOneWidget);
      expect(find.text('书籍详情'), findsOneWidget);
      expect(find.text('移出书架'), findsOneWidget);
      expect(find.text('删除确认'), findsNothing);

      // 选「移出书架」→ 才弹二次确认（`LIB-06`）。
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();

      // 确认对话框出现
      expect(find.text('删除确认'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);

      // `UI-03`（M2a-T04）：确认框是玻璃对话框，不是 Material AlertDialog。
      expect(find.byType(GlassDialog, skipOffstage: false), findsOneWidget);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);

      // 点「取消」→ 返回 false → 不删（返回值语义与原 showDialog 一致）。
      await tester.tap(find.text('取消'));
      // 玻璃弹窗关闭转场 >400ms，_settle 推不完 → pumpAndSettle 走到路由移除。
      await tester.pumpAndSettle();
      expect(find.byType(BookCard), findsOneWidget);
      expect(find.text('删除确认'), findsNothing);
      expect(await tester.runAsync(() => repo.loadBooks()), hasLength(1));
    });

    testWidgets('M2a-T04 书架顶栏为 GlassTopBar、内容层不透明（UI-02/UI-04）',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('一本'), fileName: 'a.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 导航层：玻璃壳 + 玻璃顶栏（`UI-02`）。
      expect(find.byType(GlassNavScaffold), findsOneWidget);
      expect(find.byType(GlassTopBar), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);

      // 内容层：网格被 OpaqueContentSurface 承载（`UI-04`）；
      // 书卡（内容层元素）在其**子树内**且不直接是玻璃控件。
      expect(find.byType(OpaqueContentSurface), findsOneWidget);
      expect(
        find.ancestor(of: find.byType(BookCard), matching: find.byType(OpaqueContentSurface)),
        findsWidgets,
      );
      expect(isGlassWidget(find.byType(BookCard).evaluate().single.widget), isFalse);
    });

    testWidgets('LIB-06 点击删除后书从列表移除', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('要删的书'), fileName: '删我.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 长按 → 操作单 → 「移出书架」→ 删除确认
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出书架'));
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
      await tester.tap(find.text('移出书架'));
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
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();

      // 点击「取消」（仅关闭对话框，无 IO）
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 书卡仍在
      expect(find.byType(BookCard), findsOneWidget);
      expect(await tester.runAsync(() => repo.loadBooks()), hasLength(1));
    });

    // —— 首点无响应回归（_opening 守卫作用域 + 准备期反馈 + InkWell）——

    testWidgets('回归①：点卡片进详情页，详情页→继续阅读→阅读页（链路各一次）',
        (WidgetTester tester) async {
      final ImportResult a = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      ))!;

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 一次点击 → 恰好一个详情页、尚无阅读页（`F9` / `META-08 ①` 入口改道）。
      await tester.tap(find.byType(BookCard));
      await _settle(tester);
      expect(_detailPages(), findsOneWidget);
      expect(_readerPages(), findsNothing);

      // 详情页字段可见：书名 + 来源标记（TXT 书名来自文件名，`META-08 ②`）。
      // 注意：被覆盖的书架卡片同名文本也在树上，故范围限定在详情页内断言。
      expect(
        find.descendant(of: _detailPages(), matching: find.text('甲书')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _detailPages(), matching: find.text('文件名推断')),
        findsWidgets,
      );

      // 详情页「继续阅读」→ 阅读页（复用书架注入的开书管道，恰好一次）。
      await tester.tap(find.text('继续阅读'));
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
      expect(
        tester.widget<ReaderPage>(_readerPages()).record.bookId,
        a.record.bookId,
      );
    });

    testWidgets('回归①b：连点卡片只进一个详情页；准备期连点「继续阅读」只 push 一次',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      final Finder card = find.byType(BookCard);
      await tester.tap(card);
      await tester.tap(card); // 第二击落在过渡期 → `_detailPushing` 吞掉
      await _settle(tester);

      expect(_detailPages(), findsOneWidget);
      expect(_readerPages(), findsNothing);

      // 开书准备期连点「继续阅读」：第二击落在准备期 → 守卫吞掉，不得双 push。
      final Finder cont = find.text('继续阅读');
      await tester.tap(cont);
      await tester.tap(cont);
      await _settle(tester);

      expect(_readerPages(), findsOneWidget);
    });

    testWidgets('回归②：关书+关详情后立即点另一本 → 一次即进（主因窗口回归）',
        (WidgetTester tester) async {
      final ImportResult a = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      ))!;
      final ImportResult b = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('乙书正文。'), fileName: '乙书.txt'),
      ))!;

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 打开甲书：卡片 → 详情页 → 继续阅读。
      await tester.tap(_cardOf('甲书'));
      await _settle(tester);
      expect(_detailPages(), findsOneWidget);
      await tester.tap(find.text('继续阅读'));
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
      expect(_readerPages(), findsNothing); // 阅读页已完全退出（回详情页）
      expect(_detailPages(), findsOneWidget);

      // 关详情页回书架（同样只推假帧），紧接着点乙书必须一次即进。
      Navigator.of(tester.element(_detailPages())).pop();
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_detailPages(), findsNothing); // 详情页已完全退出

      await tester.tap(_cardOf('乙书'));
      await _settle(tester);
      expect(_detailPages(), findsOneWidget);

      await tester.tap(find.text('继续阅读'));
      await _settle(tester);

      expect(_readerPages(), findsOneWidget);
      expect(
        tester.widget<ReaderPage>(_readerPages()).record.bookId,
        b.record.bookId,
      );
    });

    testWidgets('回归③：长按弹操作单，不误触发 onTap', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('要删的书'), fileName: '删我2.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 长按弹的是操作单（2026-09-28 改版），确认框要再点「移出书架」才出。
      expect(find.text('移出书架'), findsOneWidget);
      expect(find.text('删除确认'), findsNothing);
      // onTap 未被误触发：没有导航发生（既不进详情页也不进阅读页）。
      expect(_detailPages(), findsNothing);
      expect(_readerPages(), findsNothing);

      // 再走一步到确认框，仍然不该有导航。
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();
      expect(find.text('删除确认'), findsOneWidget);
      expect(_detailPages(), findsNothing);
      expect(_readerPages(), findsNothing);
    });

    testWidgets('回归④：开书准备期（详情页「继续阅读」）有可见反馈，未即刻导航',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(find.byType(BookCard));
      await _settle(tester);
      expect(_detailPages(), findsOneWidget);

      await tester.tap(find.text('继续阅读'));
      await tester.pump(); // 只推一帧、不给 runAsync → 仍在准备期

      // ① 详情页按钮出现进行中反馈（用户可见）。
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      // ② 被点卡片的 loading 覆盖层同步出现（书架侧 `_opening` 状态生效）。
      expect(
        find.descendant(
          of: find.byType(BookCard),
          matching: find.byKey(const ValueKey<String>('book-opening-overlay')),
        ),
        findsOneWidget,
      );
      expect(_readerPages(), findsNothing); // 尚未导航

      // 准备完成后正常进入阅读页（覆盖层随准备完成消失）。
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
    });

    // ── L3：拖拽重排 / 文件夹 ────────────────────────────────────────────

    testWidgets('L3 拖拽重排：顺序落盘并自动切到「手动排序」',
        (WidgetTester tester) async {
      // 分三次导入并留出时间差，让 importedAt 严格递增（默认按它降序）。
      // 同时记下各自 bookId——`layout.order` 存的是 **bookId**，不是书名。
      late String aId;
      late String bId;
      late String cId;
      await tester.runAsync(() async {
        aId = (await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt'))
            .record
            .bookId;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        bId = (await repo.importFile(bytes: _txtBytes('B'), fileName: 'b.txt'))
            .record
            .bookId;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        cId = (await repo.importFile(bytes: _txtBytes('C'), fileName: 'c.txt'))
            .record
            .bookId;
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(_titles(tester), <String>['c', 'b', 'a']);

      // 把第一张（c）拖到第三张（a）上 → 按 `ReorderableListView` 约定
      // 「插到目标之前」→ 期望 b, c, a。
      final TestGesture gesture =
          await _startDrag(tester, find.byType(BookCard).at(0));
      await gesture.moveTo(tester.getCenter(find.byType(BookCard).at(2)));
      await tester.pump(); // 仅一帧：远未到 900ms 的合并阈值 → 判为纯重排
      await gesture.up();
      await _settle(tester);

      expect(_titles(tester), <String>['b', 'c', 'a']);
      // 拖拽后自动切「手动排序」，否则当前排序字段会立刻把顺序排回去。
      expect(shelfPrefs.prefs.sortField, ShelfSortField.manual);
      // 顺序已落盘（`order` 只含散书，元素是 bookId 而非书名）。
      expect(shelfLayout.layout.order, <String>[bId, cId, aId]);
    });

    testWidgets('L3 拖到另一本书上悬停 → 新建文件夹，两本都移出散书区',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await repo.importFile(bytes: _txtBytes('B'), fileName: 'b.txt');
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);
      expect(find.byType(BookCard), findsNWidgets(2));

      // 拖 b（默认降序下是第 0 张）到 a 上，并**悬停够时长**。
      final TestGesture gesture =
          await _startDrag(tester, find.byType(BookCard).at(0));
      await gesture.moveTo(tester.getCenter(find.byType(BookCard).at(1)));
      await tester.pump(); // `onMove` 起计时器
      await tester.pump(kFolderMergeHoverDelay); // 计时到点 → 合并就绪
      await tester.pump(); // 画「新建文件夹」提示
      await gesture.up();
      await _settle(tester);

      // 两本书都进了文件夹 → 散书区一张书卡都不剩，只剩文件夹卡。
      expect(find.byType(BookCard), findsNothing);
      expect(shelfLayout.layout.folders, hasLength(1));
      expect(shelfLayout.layout.folders.single.bookIds, hasLength(2));
      // 新文件夹以目标书书名命名（a），角标显示书数。
      expect(find.text('a'), findsOneWidget);
      expect(find.text('2 本'), findsOneWidget);
      // 操作反馈轻提示走 Overlay（`GlassOverlays.showToast`）——壳层无
      // Material `Scaffold`，此处若退回 `ScaffoldMessenger` 会直接断言崩溃。
      expect(find.text('已创建文件夹「a」'), findsOneWidget);
    });

    testWidgets('L3 拖到文件夹卡上 → 移入该文件夹', (WidgetTester tester) async {
      late String folderId;
      await tester.runAsync(() async {
        final ImportResult a =
            await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        final ImportResult b =
            await repo.importFile(bytes: _txtBytes('B'), fileName: 'b.txt');
        await repo.importFile(bytes: _txtBytes('C'), fileName: 'c.txt');
        folderId = await shelfLayout.createFolder(
          name: '合集',
          bookIds: <String>[a.record.bookId, b.record.bookId],
        );
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 散书区只剩 c 一张书卡（a、b 已归属文件夹）。
      expect(find.byType(BookCard), findsOneWidget);
      expect(find.text('合集'), findsOneWidget);

      final Finder folderCell = find.ancestor(
        of: find.text('合集'),
        matching: find.byType(DragTarget<BookRecord>),
      );
      final TestGesture gesture =
          await _startDrag(tester, find.byType(BookCard));
      await gesture.moveTo(tester.getCenter(folderCell.first));
      await tester.pump();
      await gesture.up();
      await _settle(tester);

      final BookFolder folder = shelfLayout.layout.folders
          .firstWhere((BookFolder f) => f.id == folderId);
      expect(folder.bookIds, hasLength(3));
      expect(find.byType(BookCard), findsNothing);
    });

    testWidgets('L3 点文件夹卡进文件夹内页，书都在里面', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final ImportResult a =
            await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        final ImportResult b =
            await repo.importFile(bytes: _txtBytes('B'), fileName: 'b.txt');
        await shelfLayout.createFolder(
          name: '合集',
          bookIds: <String>[a.record.bookId, b.record.bookId],
        );
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(find.text('合集'));
      await _settle(tester);

      expect(find.byType(ShelfFolderPage), findsOneWidget);
      // 文件夹内页显示两本书（顶栏标题 + 两张书卡）。
      expect(find.byType(BookCard), findsNWidgets(2));
    });

    testWidgets('L3 长按文件夹卡 → 操作单；解散后书回到散书区',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        final ImportResult a =
            await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        final ImportResult b =
            await repo.importFile(bytes: _txtBytes('B'), fileName: 'b.txt');
        await shelfLayout.createFolder(
          name: '合集',
          bookIds: <String>[a.record.bookId, b.record.bookId],
        );
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.longPress(find.text('合集'));
      await tester.pumpAndSettle();
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('解散文件夹'), findsOneWidget);

      await tester.tap(find.text('解散文件夹'));
      await tester.pumpAndSettle();
      // 二次确认框（标题同名），此时操作单已关闭。
      expect(find.text('解散'), findsOneWidget);

      await tester.tap(find.text('解散'));
      await _settle(tester);

      expect(shelfLayout.layout.folders, isEmpty);
      // 两本书回到散书区。
      expect(find.byType(BookCard), findsNWidgets(2));
      expect(find.text('合集'), findsNothing);
    });

    testWidgets('L3 排序菜单含「手动排序」一项', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();

      expect(find.text('手动排序'), findsOneWidget);
      expect(find.text('导入时间'), findsOneWidget);
    });

    // ── 阅读状态筛选：单选（2026-09-29 改版，对齐 anx-reader） ──────────

    testWidgets('筛选 chips：已读完/正在读/未开始，单选且立即过滤书目',
        (WidgetTester tester) async {
      final ImportResult finished = (await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('读完的'), fileName: '完.txt'),
      ))!;
      final ImportResult reading = (await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('读一半的'), fileName: '半.txt'),
      ))!;
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('没读的'), fileName: '新.txt'),
      );
      // 预置阅读进度：完=1.0（已读完）、半=0.4（正在读）、新=null（未开始）。
      await tester.runAsync(() async {
        await repo.markRead(
          finished.record.bookId,
          lastReadAt: 2,
          readProgress: 1.0,
        );
        await repo.markRead(
          reading.record.bookId,
          lastReadAt: 1,
          readProgress: 0.4,
        );
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);
      expect(_titles(tester), hasLength(3));

      // chips 文案与顺序（照搬 anx `bookshelf_page.dart:111-141`）。
      final List<String> chipLabels = tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .map((FilterChip chip) => (chip.label as Text).data!)
          .toList();
      expect(chipLabels, <String>['已读完', '正在读', '未开始']);

      // 选「已读完」→ 只剩读完的那本。
      await tester.tap(find.text('已读完'));
      await _settle(tester);
      expect(_titles(tester), <String>['完']);

      // 再选「正在读」→ **顶掉**上一个（单选，不是叠加）。
      await tester.tap(find.text('正在读'));
      await _settle(tester);
      expect(_titles(tester), <String>['半']);
      expect(shelfPrefs.prefs.filter, ShelfReadingFilter.reading);

      // 再点已选中的「正在读」→ 取消 → 全部三本回来。
      await tester.tap(find.text('正在读'));
      await _settle(tester);
      expect(_titles(tester), hasLength(3));
      expect(shelfPrefs.prefs.filter, isNull);
    });
  });
}
