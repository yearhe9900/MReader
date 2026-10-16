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
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';
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
///
/// ⚠️ 末尾的 `.first` 是为**去重**，不是「随便挑一个」：2026-09-29 起无封面书卡的
/// 占位封面（`DefaultBookCover`）顶部也画一遍书名，于是同一张卡里 `find.text(title)`
/// 会命中 2 个 `Text`（封面一个、信息区一个），`find.ancestor` 便把**同一张**
/// `BookCard`（同一个 Element、同一个 State）列出两次，`tap()` 会报「歧义」。
Finder _cardOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(BookCard)).first;

/// 全树范围找 [ReaderPage]（`skipOffstage: false`：被覆盖路由若仍挂着也要揪出来，
/// 否则「恰好 push 一次」的断言会被 offstage 藏掉漏检）。
Finder _readerPages() => find.byType(ReaderPage, skipOffstage: false);

/// 全树范围找 [BookDetailPage]（同上：覆盖栈里的详情页也要揪出来）。
Finder _detailPages() => find.byType(BookDetailPage, skipOffstage: false);

/// 经**长按操作单**进详情页。
///
/// 2026-09-29 改道后：点卡 = **直接进阅读页**，详情页只剩「长按 → 书籍详情」一个入口
/// （`META-08` 同步改文；与 anx-reader 的 `book_bottom_sheet` 同构）。
Future<void> _openDetailViaSheet(WidgetTester tester, Finder card) async {
  await tester.longPress(card);
  await tester.pumpAndSettle(); // 玻璃底部操作单滑入
  await tester.tap(find.text('书籍详情'));
  await _settle(tester); // 弹层 pop + 详情页 push + 详情页自身 IO
}

/// 网格中书卡的显示顺序（element 顺序 = 网格顺序）。
List<String> _titles(WidgetTester tester) => tester
    .widgetList<BookCard>(find.byType(BookCard))
    .map((BookCard card) => card.record.title)
    .toList();

/// 分组筛选栏的标签文案（顺序即渲染顺序，「全部」恒在首位）。
///
/// 2026-10-16 参考项目批：控件换成 [MiPillTabBar]（一比一移植体胶囊标签行），
/// 文案改读 `MiPillTabBar.labels`（组件渲染 `Text(labels[i])`）。
List<String> _chipLabels(WidgetTester tester) =>
    tester.widget<MiPillTabBar>(find.byType(MiPillTabBar)).labels;

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
      // 导入预热收尾再删目录（防后台写盘 vs 删目录竞态，§2.81）。
      // tearDown 在 FakeAsync 之外跑，真 await 照常（与 setUp 同款口径）。
      await repo.pendingWarmUps;
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
      // 书名和作者可见。
      //
      // ⚠️ 书名与作者**各出现两次**是预期：一次在封面（`DefaultBookCover` 顶部大字
      // / 底部小字，2026-09-29 采用 anx 默认封面后如此），一次在下方信息区。作者不是
      // 空串——`META-01` 保证缺失时兜底成「未知作者」（`lib/meta/meta_source.dart:14`），
      // 故封面画的也是「未知作者」。
      expect(find.text('三体'), findsNWidgets(2));
      expect(find.text('未知作者'), findsNWidgets(2));
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

    testWidgets('顶栏搜索胶囊：靠左铺满（全宽）+ 真玻璃材质（GlassButton.custom）',
        (WidgetTester tester) async {
      // 800 宽视口才分得清「靠左铺满」与「居中收缩」。须同时钉
      // `devicePixelRatio = 1`（默认 3 会把逻辑宽算成 266，动作按钮一挤
      // 可用宽就变、结论随之改变）。
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('一本'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(find.text('搜索书名、作者'), findsOneWidget);

      // 机制锁：顶栏须显式关掉居中档（默认 `true` 会走库的「等边距居中」分支，
      // 两行头部会被收缩）。
      expect(
        tester.widget<GlassTopBar>(find.byType(GlassTopBar)).centerTitle,
        isFalse,
      );

      // 几何契约：靠左贴顶栏内边距（`GlassAppBar` 默认 horizontal padding = 8），
      // 并**铺满可用宽**——2026-09-29 参考图批撤掉原先的 `maxWidth: 400`
      // 桌面上限（拍板「全宽搜索胶囊」）：800 - 16(两侧内边距) - 96(两按钮)
      // ≈ 688，故断言 > 600；若退回 400 上限或居中档立刻红。
      final Finder box = find.byKey(const Key('shelf-search-entry'));
      expect(box, findsOneWidget);
      expect(tester.getTopLeft(box).dx, lessThanOrEqualTo(16));
      expect(tester.getSize(box).width, greaterThan(600));
      // 右侧仍留出两个动作按钮的位置（导入 / 排序）。
      expect(tester.getTopRight(box).dx, lessThan(800 - 48));

      // 材质契约（2026-10-12 参考图批）：胶囊已从「半透明色块 `Container` +
      // 描边」换成**真玻璃** [GlassButton.custom]——磨砂模糊 + 增白纱罩 +
      // Fresnel 边缘光。断言按材质事实源逐项钉：改材质只许改
      // `glass_material.dart`（`UI-07` 口径：业务页面不写字面量），这里跟
      // `glass_material_test.dart` 一样用**字面量**，避免同义反复。
      final GlassButton btn = tester.widget<GlassButton>(box);
      expect(btn.height, 36);
      expect(btn.useOwnLayer, isTrue,
          reason: '顶栏内无父玻璃层；grouped 模式下 per-widget settings 被忽略');
      expect(btn.settings, isNotNull);
      expect(btn.settings!.blur, 9);
      expect(btn.settings!.glassColor.a, closeTo(0.18, 0.001));
      expect(btn.settings!.whitenStrength, closeTo(0.16, 0.001));
      // 交互：去放大（项目口径）+ 轻微果冻。
      expect(btn.interactionScale, 1.0);
      expect(btn.stretch, closeTo(0.15, 0.001));
      // 内容左对齐（默认 center 会把图标 + 文字收到胶囊中间）。
      expect(btn.alignment, Alignment.centerLeft);
    });

    testWidgets('分组标签行：MiPillTabBar 接线（参考项目胶囊组件，滚动区无玻璃控件）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('一本'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 「全部」默认选中；胶囊几何走组件默认（87.6×39.9 参考实测，定宽）。
      final MiPillTabBar bar =
          tester.widget<MiPillTabBar>(find.byType(MiPillTabBar));
      expect(bar.labels, <String>['全部']);
      expect(bar.selectedIndex, 0);
      expect(bar.itemWidth, MiPillTabMetrics.itemWidth);
      // 明暗由 `GlassScope` 级联亮度解析（同底栏 `navThemeModeOf`）；测试
      // 环境默认亮色主题 → light 配方。
      expect(bar.themeMode, MiThemeMode.light);
      // `UI-04` 红线延续：横向滚动区里**不得有玻璃控件**（旧行为是 GlassChip
      // 显式 standard 档位防 premium 提升；换纯色胶囊组件后由结构满足）。
      expect(find.byType(GlassChip), findsNothing);
    });

    testWidgets('浮动头部 + 内容 edge-to-edge：两行头部恒在顶栏内、首行不被盖住',
        (WidgetTester tester) async {
      // 钉 dpr = 1：断言的是**逻辑像素**几何（96 / 108），默认 dpr 3 会把
      // 物理尺寸与逻辑尺寸搅在一起。
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('一本'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // ① 内容 edge-to-edge：壳层显式开 `extendBody`（正文从 y=0 起、
      // 滚动时从浮动头部下穿过，顶栏下透出磨砂模糊 = `UI-02` ②）。
      expect(
        tester
            .widget<GlassNavScaffold>(find.byType(GlassNavScaffold))
            .extendBody,
        isTrue,
        reason: '书架是「全浮动头部」形态：正文必须穿顶栏（拍板 2026-09-29）',
      );

      // ② 头部两行**恒在顶栏内**：搜索胶囊与分组 chips 都是 `GlassTopBar` 的
      // 子树（原实现里 chips 在正文 Column 里，移动回正文即红）。
      expect(
        find.descendant(
          of: find.byType(GlassTopBar),
          matching: find.byKey(const Key('shelf-search-entry')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(GlassTopBar),
          matching: find.byType(MiPillTabBar),
        ),
        findsOneWidget,
      );

      // ③ 头部总高 96 = 搜索行 44 + 间距 12 + chips 行 40（`kShelfHeaderHeight`；
      // 这里按**字面量**锁——引用常量等于同义反复）。
      expect(
        tester.widget<GlassTopBar>(find.byType(GlassTopBar)).toolbarHeight,
        96,
      );

      // ④ 首行不被盖住：第一张书卡顶边 = 状态栏 0 + 头部 96 + 网格上间距 12 = 108。
      // 去掉网格 `padding.top` 的头部留白 → 变 0，立即红。
      expect(
        tester.getTopLeft(find.byType(BookCard).first).dy,
        108,
        reason: '首行必须落在浮动头部之下（拍板验收条目），否则被磨砂头部盖住',
      );

      // ⑤ 胶囊行左缘与搜索胶囊对齐：组件内置 11.9 内嵌被拓盒抵消
      // （`_buildGroupFilterBar` 注释）；去掉 OverflowBox 拓宽 → 立即红。
      // OverflowBox 居中带来 ~1e-14 浮点噪声，用 closeTo 收。
      final Finder firstPill = find.ancestor(
        of: find.text('全部'),
        matching: find.byType(AnimatedContainer),
      );
      expect(
        tester.getTopLeft(firstPill).dx,
        closeTo(
          tester.getTopLeft(find.byKey(const Key('shelf-search-entry'))).dx,
          0.001,
        ),
        reason: '胶囊左缘必须与搜索胶囊左缘对齐（浮动头部既有形态）',
      );
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

      // 点击「删除」（`_deleteBook` 内含真 IO，需 _settle）。
      // 删书链的真 IO 步数多（副本/封面/三份缓存清理/索引+进度收尾），
      // 40 轮预算不够走到 `_loadBooks` 刷 UI → 加深到 100 轮（§2.81 实测）。
      await tester.tap(find.text('删除'));
      await _settle(tester, rounds: 100);

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
      // 删书链真 IO 步数多（见上一用例注释）：预算加深到 100 轮（§2.81）。
      await _settle(tester, rounds: 100);

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

    testWidgets('回归①：点书卡直接进阅读页（不经详情页；`META-08` 入口改道）',
        (WidgetTester tester) async {
      final ImportResult a = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      ))!;

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 一次点击 → 恰好一个阅读页，且**零**详情页。
      // （2026-09-29 拍板：原「点卡 → 详情页 → 继续阅读」两层链路压缩为一层，
      // 对齐 anx-reader `book_item.dart:51-53` 的 `pushToReadingPage`。）
      await tester.tap(find.byType(BookCard));
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
      expect(_detailPages(), findsNothing);
      expect(
        tester.widget<ReaderPage>(_readerPages()).record.bookId,
        a.record.bookId,
      );
    });

    testWidgets('回归①补：详情页仍可达——长按操作单「书籍详情」（`META-08` 唯一入口）',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await _openDetailViaSheet(tester, find.byType(BookCard));

      // 进详情页但**不自动开书**（详情页只是展示 + 提供「继续阅读」）。
      expect(_detailPages(), findsOneWidget);
      expect(_readerPages(), findsNothing);

      // 详情页字段可见：书名 + 来源标记（TXT 书名来自文件名，`META-08 ②`）。
      // 注意：被覆盖的书架卡片同名文本也在树上，故范围限定在详情页内断言。
      // 书名在详情页内也是**两处**（`DefaultBookCover` 封面 + 标题栏大标题），
      // 故是 `findsNWidgets(2)` 而非 1。
      expect(
        find.descendant(of: _detailPages(), matching: find.text('甲书')),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: _detailPages(), matching: find.text('文件名推断')),
        findsWidgets,
      );

      // 详情页「继续阅读」→ 阅读页（复用书架注入的开书管道，恰好一次）。
      await tester.tap(find.text('继续阅读'));
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
    });

    testWidgets('回归①b：连点卡片只 push 一个阅读页（准备期守卫吞第二击）',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 两击落在同一帧（中间无 pump）：第一击在首个 await **之前**同步置
      // `_opening = true`，故第二击落在准备期 → 被守卫吞掉，不得叠两个阅读页。
      final Finder card = find.byType(BookCard);
      await tester.tap(card);
      await tester.tap(card);
      await _settle(tester);

      expect(_readerPages(), findsOneWidget);
      expect(_detailPages(), findsNothing);
    });

    testWidgets('回归②：关书后立即点另一本 → 一次即进（主因窗口回归）',
        (WidgetTester tester) async {
      final ImportResult a = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      ))!;
      final ImportResult b = (await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('乙书正文。'), fileName: '乙书.txt'),
      ))!;

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 打开甲书：一次点击**直接**进阅读页（改道后少一层详情页）。
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
      expect(_readerPages(), findsNothing); // 阅读页已完全退出（回书架）

      // 紧接着点乙书必须一次即进。
      await tester.tap(_cardOf('乙书'));
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

    testWidgets('回归④：点卡开书准备期有可见反馈，未即刻导航',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 点卡即开书 → 只推一帧、不给 runAsync → 仍在准备期。
      await tester.tap(find.byType(BookCard));
      await tester.pump();

      // 被点卡片的 loading 覆盖层出现（书架侧 `_opening` 状态生效，用户可见）。
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

    // ── 分组（`P2-02`；2026-09-29 取代「阅读状态筛选」，拖拽归类已移除） ──

    testWidgets('分组 chips：默认「全部」，点分组只剩该分组的书，再点回「全部」',
        (WidgetTester tester) async {
      late String groupId;
      await tester.runAsync(() async {
        final ImportResult a =
            await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        await repo.importFile(bytes: _txtBytes('B'), fileName: 'b.txt');
        await repo.importFile(bytes: _txtBytes('C'), fileName: 'c.txt');
        // 把 a 归入「玄幻」→ 书架顶部应出现「全部 / 玄幻」两个 chip。
        groupId = (await shelfLayout.assignByName(a.record.bookId, '玄幻'))!;
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 默认「全部」：分组内的书在「全部」里**照常显示**（分组是筛选而非隔离）。
      expect(_chipLabels(tester), <String>['全部', '玄幻']);
      expect(_titles(tester), hasLength(3));

      await tester.tap(find.text('玄幻'));
      await _settle(tester);
      expect(_titles(tester), <String>['a']); // 默认降序 c,b,a → 只剩 a
      expect(shelfPrefs.prefs.groupId, groupId);

      // 再点**已选中**的分组 → 回「全部」。
      await tester.tap(find.text('玄幻'));
      await _settle(tester);
      expect(_titles(tester), hasLength(3));
      expect(shelfPrefs.prefs.groupId, isNull);
    });

    testWidgets('分组 chips：切另一个分组顶掉原选择（单选，不叠加）',
        (WidgetTester tester) async {
      late String xuanhuanId;
      late String kehuanId;
      await tester.runAsync(() async {
        final ImportResult a =
            await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        final ImportResult b =
            await repo.importFile(bytes: _txtBytes('B'), fileName: 'b.txt');
        xuanhuanId = (await shelfLayout.assignByName(a.record.bookId, '玄幻'))!;
        kehuanId = (await shelfLayout.assignByName(b.record.bookId, '科幻'))!;
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);
      expect(_chipLabels(tester), <String>['全部', '玄幻', '科幻']);

      await tester.tap(find.text('玄幻'));
      await _settle(tester);
      expect(_titles(tester), <String>['a']);

      await tester.tap(find.text('科幻'));
      await _settle(tester);
      expect(_titles(tester), <String>['b']); // 顶掉玄幻，不是并集
      expect(shelfPrefs.prefs.groupId, kehuanId);
      expect(shelfPrefs.prefs.groupId, isNot(xuanhuanId));
    });

    testWidgets('选中分组被删掉（书被删空）→ chip 消失且书架回落「全部」',
        (WidgetTester tester) async {
      late String groupId;
      await tester.runAsync(() async {
        final ImportResult a =
            await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        groupId = (await shelfLayout.assignByName(a.record.bookId, '玄幻'))!;
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);
      await tester.tap(find.text('玄幻'));
      await _settle(tester);
      expect(_titles(tester), <String>['a']);

      // 分组不见了（书被删空后 `prune` 会清掉空分组；此处直接删组等价）。
      await tester.runAsync(() => shelfLayout.deleteGroup(groupId));
      await _settle(tester);

      // chip 消失、书回到「全部」，且「全部」呈选中态（标签行选中下标归零）。
      expect(find.text('玄幻'), findsNothing);
      expect(_titles(tester), <String>['a']);
      expect(
        tester.widget<MiPillTabBar>(find.byType(MiPillTabBar)).selectedIndex,
        0,
      );
      // 渲染层回落，**不改写**用户偏好（分组可能因同步 / 撤销而回来）。
      expect(shelfPrefs.prefs.groupId, groupId);
    });

    testWidgets('详情页「分组」行 → 新建分组后，返回书架 chips 出现该分组',
        (WidgetTester tester) async {
      // 详情页正文较长：调到接近真机的视口并钉 `devicePixelRatio = 1`
      // （默认 dpr=3 会把逻辑高度算成 333，分组行被挤出 `ListView` 懒构建范围）。
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);
      expect(find.text('玄幻'), findsNothing); // 还没有任何分组

      // 进详情页（改道后走长按操作单）→ 点「分组」入口（当前显示「未分组」）。
      await _openDetailViaSheet(tester, find.byType(BookCard));
      expect(find.byType(BookDetailPage), findsOneWidget);
      await tester.tap(find.text('未分组'));
      await _settle(tester);

      // 弹层：「未分组 / 新建分组…」。
      expect(find.text('新建分组…'), findsOneWidget);
      await tester.tap(find.text('新建分组…'));
      await _settle(tester);

      // ⚠️ 写分组走 `AtomicFile` **真文件 IO**，`pumpAndSettle` 在 FakeAsync 区
      // 推不动它 → 必须用 `_settle`（`runAsync` 让出真事件循环），否则
      // `assignByName` 之后的那次 `setState` 永远不会执行。
      await tester.enterText(find.byType(TextField), '玄幻');
      await tester.tap(find.text('确定'));
      await _settle(tester);

      // 详情页分组行显示新组名（且分组已落盘到共享 store）。
      expect(find.text('玄幻'), findsWidgets);
      expect(shelfLayout.layout.groups.single.name, '玄幻');

      // 返回书架 → chips 出现「玄幻」。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await _settle(tester);
      expect(_chipLabels(tester), <String>['全部', '玄幻']);
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

    testWidgets('没有任何分组时，chips 只有「全部」', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(_chipLabels(tester), <String>['全部']);
      expect(_titles(tester), hasLength(1));
    });
  });
}
