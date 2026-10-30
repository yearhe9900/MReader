// `test/ui/shelf_page_test.dart`：书架首页 widget 测试（LIB-01/05/06）。
// 导入走 `LibraryRepository.importFile()` 直调——`FilePicker.platform.pickFiles()` 在 widget 测试不可用。
//
// ⚠️ FakeAsync 铁律：widget 内部发起的真异步 IO 不会自行推进，直接 `pumpAndSettle()` 会超时；
// 必须用 [_settle]（`runAsync` 让出真实事件循环 + `pump` 排空 fake 队列）。
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
import 'package:mreader/ui/shelf_search_page.dart';

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
    Uint8List.fromList(utf8.encode(content));

/// 合法 UTF-8 的 TXT 字节——**真正要打开**的书必须可解码（回归①②④走完整开书链路）。
Uint8List _utf8TxtBytes(String content) =>
    Uint8List.fromList(utf8.encode(content));

/// 让 widget 内发起的**真异步 IO** 完成并推进若干帧。
///
/// ⚠️ FakeAsync 区里 IO 完成回调排在 fake 队列不会自行推进，**必须 `runAsync`+`pump` 多轮交替**
/// （串行多次 await IO 各要一轮）；**禁 `pumpAndSettle`**（载入期无限动画永不 settle，会超时）。
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
/// ⚠️ 末尾 `.first` 是**去重**不是随便挑：无封面书卡的占位封面顶部也画书名，
/// `find.text` 会命中 2 个 `Text`、把同一张 [BookCard] 列两次，不取 `.first` 则 `tap()` 报歧义。
Finder _cardOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(BookCard)).first;

/// 全树范围找 [ReaderPage]（`skipOffstage: false`：被覆盖路由若仍挂着也要揪出来，
/// 否则「恰好 push 一次」的断言会被 offstage 藏掉漏检）。
Finder _readerPages() => find.byType(ReaderPage, skipOffstage: false);

/// 全树范围找 [BookDetailPage]（同上：覆盖栈里的详情页也要揪出来）。
Finder _detailPages() => find.byType(BookDetailPage, skipOffstage: false);

/// 经**长按弹框**进详情页（点卡 = 直接进阅读页，详情页只剩「长按 → 书籍详情」一个入口，
/// `META-08`）。
Future<void> _openDetailViaSheet(WidgetTester tester, Finder card) async {
  await tester.longPress(card);
  await tester.pumpAndSettle(); // mi_like_ui `MiDialog` 弹框入场
  await tester.tap(find.text('书籍详情'));
  await _settle(tester); // 弹层 pop + 详情页 push + 详情页自身 IO
}

/// 网格中书卡的显示顺序（element 顺序 = 网格顺序）。
List<String> _titles(WidgetTester tester) => tester
    .widgetList<BookCard>(find.byType(BookCard))
    .map((BookCard card) => card.record.title)
    .toList();

/// 分组筛选栏的标签文案（顺序即渲染顺序，「全部」恒在首位）。
/// 文案读 [MiPillTabBar.labels]（组件渲染 `Text(labels[i])`）。
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
      // tearDown 在 FakeAsync 之外跑，真 await 照常（与 setUp 同款口径）。
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
      // 顶栏加号按钮**已移除**，导入入口迁到底栏绿圆钮（`HomeShell` 侧，本测试不挂壳层
      // 故不在树上）；空态引导按钮仍保留（`LIB-01` ②）。
      expect(find.byIcon(Icons.add), findsNothing);
    });

    testWidgets('LIB-01 导入后：书卡显示在网格中', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('三体的内容'), fileName: '三体.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 空态消失
      expect(find.text('书架空空如也'), findsNothing);
      // 书卡出现
      expect(find.byType(BookCard), findsOneWidget);
      // ⚠️ 书名与作者**各出现两次**是预期（封面 + 信息区各一）；`META-01` 缺失时
      // 兜底「未知作者」（`lib/meta/meta_source.dart:14`），故封面画的也是兜底值。
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

    testWidgets('LIB-06 长按弹 MiDialog 操作弹框，选「移出书架」后再弹删除确认',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('要删的书'), fileName: '删我.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 长按书卡 → **操作弹框（mi_like_ui `MiDialog`，2026-10-23 换掉玻璃底部
      // 操作单）**：长按不再直接弹删除确认，破坏性动作收进弹框（缩短误触路径）。
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 弹框形态钉住：不透明卡片 + 自带遮罩（`MiDialog`），`GlassSheet` 不在树上。
      expect(find.byType(MiDialog, skipOffstage: false), findsOneWidget);
      expect(find.byType(GlassSheet, skipOffstage: false), findsNothing);
      // 列表形态（上游 `f254f85` / issue #1）：三项带图标 + 副标题，破坏性项的
      // 说明文案回到列表里（旧操作单那一行）；与删除确认框的正文不重名。
      expect(find.text('删除后封面文件一并清理'), findsOneWidget);

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

      // `UI-03`：确认框是玻璃对话框，不是 Material AlertDialog。
      expect(find.byType(GlassDialog, skipOffstage: false), findsOneWidget);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);

      // 点「取消」→ 返回 false → 不删。
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

    testWidgets('顶栏搜索胶囊：靠左铺满（全宽）+ 上游 MiSearchBar 材质',
        (WidgetTester tester) async {
      // 800 宽视口才分得清「靠左铺满」与「居中收缩」；**须钉 `devicePixelRatio = 1`**
      // （默认 3 会把逻辑宽算成 266，可用宽一变结论就变）。
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

      // 几何契约：靠左贴顶栏内边距（`GlassAppBar` 默认 horizontal padding = 8）并**铺满可用宽**。
      // 断言 > 600 留了余量（排序按钮移除后可用宽 ≈ 784）；若退回 `maxWidth: 400` 桌面上限
      // 或居中档立刻红。
      final Finder box = find.byKey(const Key('shelf-search-entry'));
      expect(box, findsOneWidget);
      expect(tester.getTopLeft(box).dx, lessThanOrEqualTo(16));
      expect(tester.getSize(box).width, greaterThan(600));
      // 常规态右侧已无动作按钮（排序入口移除），胶囊右缘可贴到内边距上。
      expect(tester.getTopRight(box).dx, lessThanOrEqualTo(800 - 8));

      // 材质契约：胶囊用上游 [MiSearchBar]（组件自带 stadium 高 44.1、半透明填充）。
      // 断言按组件事实源逐项钉：**改材质只许改移植树**（`mi_like_ui`，与上游 `diff -r`
      // 零差异），业务页不写字面量。
      final MiSearchBar bar = tester.widget<MiSearchBar>(box);
      // 占位文案（同 key 定位下钉 hint，避免「空栏」也过几何断言）。
      expect(bar.hint, '搜索书名、作者');
      // 点按接线：进入就地搜索态（onTap 非空 = 参与手势）。
      expect(bar.onTap, isNotNull);
      // 常规态不是输入框（不占焦点、不弹键盘）。
      expect(bar.editable, isFalse);
      // 磨砂分两层（上游 `81d2f86` 实机反馈口径）：头部铺渐进羽化阶梯
      //（`_buildHeaderBlur`），零件**始终自绘自己的玻璃**——旧口径（整条只糊
      // 一次）会让胶囊像不透明色块。
      expect(bar.frosted, isTrue);
      // 压在书卡上：垫玻璃膜（内容滚到头部后方才显出形状）。
      expect(bar.overContent, isTrue);
      // 明暗由 `GlassScope` 级联亮度解析；测试环境默认亮色 → light 配方。
      expect(bar.themeMode, MiThemeMode.light);
    });

    testWidgets('头部磨砂：头部区渐进羽化阶梯（恒定 σ 回潮即红）', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('一本'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 事实源同口径：头部磨砂 = `MiTopBar.headerBlurBands`（平台 8.5dp 线性
      // 衰减、胶囊行底后羽化收尾），extent = 状态栏 0 + 头部 96.1。
      final List<MiTopBarBlurBand> bands = MiTopBar.headerBlurBands(
        MiTopBarPalette.light,
        extent: 96.1,
        underSurface: false,
      );
      // 渐进阶梯（多段）；旧实现的「恒定 σ 一整段」回潮即红。
      expect(bands.length, greaterThan(1));

      // 页面真实的分段高斯层数与事实源同口径，且首段贴顶、末段落盒底。
      final Finder blurLayer = find.byKey(
        const ValueKey<String>('shelf-header-blur'),
      );
      expect(blurLayer, findsOneWidget);
      final Finder blurLayers = find.descendant(
        of: blurLayer,
        matching: find.byType(BackdropFilter),
      );
      expect(blurLayers, findsNWidgets(bands.length));
      expect(tester.getRect(blurLayers.first).top, 0);
      expect(
        tester.getRect(blurLayers.last).bottom,
        moreOrLessEquals(96.1, epsilon: 0.01),
        reason: '羽化收尾落在盒底（旧口径是栏底硬切）',
      );
    });

    testWidgets('头部亮边：静止不亮，网格滚动后搜索胶囊与胶囊行随位移渐亮', (
      WidgetTester tester,
    ) async {
      // 紧凑窗（3 列）：12 本书才有滚动余量（800 宽 6 列时 12 本两行就完，
      // 拖不动 → 断言全是假绿）。
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 多本书才有滚动余量。
      for (int i = 0; i < 12; i++) {
        await tester.runAsync(
          () => repo.importFile(bytes: _txtBytes('书$i'), fileName: 'b$i.txt'),
        );
      }
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      MiSearchBar bar() => tester.widget<MiSearchBar>(
            find.byKey(const Key('shelf-search-entry')),
          );
      MiPillTabBar pills() =>
          tester.widget<MiPillTabBar>(find.byType(MiPillTabBar));

      // 静止（offset 0）：亮边不亮（实机反馈：不能常驻描边）。
      expect(bar().rimProgress, 0.0);
      expect(pills().rimProgress, 0.0);

      // 滚过 ≥20dp（映射同 `MiTopBarMetrics.rimFadeDistance`）→ 满亮保持。
      await tester.drag(find.byType(GridView), const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(bar().rimProgress, greaterThan(0.99), reason: '滚过 20dp 后满亮');
      expect(pills().rimProgress, greaterThan(0.99));

      // 滚回顶部 → 渐隐回不亮。
      await tester.drag(find.byType(GridView), const Offset(0, 80));
      await tester.pumpAndSettle();
      expect(bar().rimProgress, 0.0);
      expect(pills().rimProgress, 0.0);
    });

    testWidgets('分组标签行：MiPillTabBar 自适应宽档接线（滚动区无玻璃控件）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('一本'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 「全部」默认选中；胶囊宽度走**自适应档**（min 87.6 / max 175.2 的
      // clamp 规则契约见框架 `pill_tab_bar_test`（上游 issue #3），本用例只钉接线）。
      final MiPillTabBar bar =
          tester.widget<MiPillTabBar>(find.byType(MiPillTabBar));
      expect(bar.labels, <String>['全部']);
      expect(bar.selectedIndex, 0);
      expect(bar.itemWidthMode, MiPillItemWidth.adaptive);
      // 明暗由 `GlassScope` 级联亮度解析；测试环境默认亮色 → light 配方。
      expect(bar.themeMode, MiThemeMode.light);
      // `UI-04` 红线：横向滚动区里**不得有玻璃控件**（换纯色胶囊组件后由结构满足）。
      expect(find.byType(GlassChip), findsNothing);
    });

    testWidgets('浮动头部 + 内容 edge-to-edge：两行头部恒在顶栏内、首行不被盖住',
        (WidgetTester tester) async {
      // 钉 dpr = 1：断言的是**逻辑像素**几何（96 / 108），默认 dpr 3 会把物理/逻辑尺寸搅在一起。
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('一本'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // ① 内容 edge-to-edge：壳层显式开 `extendBody`，正文从 y=0 起、滚动时从浮动头部下
      // 穿过，顶栏下透出磨砂模糊（`UI-02` ②）。
      expect(
        tester
            .widget<GlassNavScaffold>(find.byType(GlassNavScaffold))
            .extendBody,
        isTrue,
        reason: '书架是「全浮动头部」形态：正文必须穿顶栏（拍板 2026-09-29）',
      );

      // ② 头部两行**恒在顶栏内**（搜索胶囊与分组 chips 都在 `GlassTopBar` 子树）：
      // chips 移回正文 Column 即红。
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

      // ③ 头部总高 96.1 = 搜索行 44.1（MiSearchBar 栏高）+ 间距 12 + chips 行 40；
      // 按**字面量**锁——引用 `kShelfHeaderHeight` 等于同义反复。
      expect(
        tester.widget<GlassTopBar>(find.byType(GlassTopBar)).toolbarHeight,
        96.1,
      );

      // ④ 首行不被盖住：首卡顶边 = 状态栏 0 + 头部 96.1 + 网格上间距 12 = 108.1；
      // 去掉网格 `padding.top` 的头部留白 → 变 0，立即红。
      expect(
        tester.getTopLeft(find.byType(BookCard).first).dy,
        108.1,
        reason: '首行必须落在浮动头部之下（拍板验收条目），否则被磨砂头部盖住',
      );

      // ⑤ 胶囊行左缘与搜索胶囊对齐：组件内置 11.9 内嵌被拓盒抵消（`_buildGroupFilterBar`
      // 注释）；去掉 OverflowBox 拓宽 → 立即红。OverflowBox 居中带来浮点噪声，用 closeTo 收。
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

      // 长按 → 操作弹框 → 「移出书架」→ 删除确认
      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();

      // 点「删除」（`_deleteBook` 内含真 IO，需 _settle）；删书链真 IO 步数多
      // （副本/封面/缓存清理/索引+进度收尾），40 轮不够走到 `_loadBooks` 刷 UI → 加深到 100 轮（§2.81）。
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

      // 一次点击 → 恰好一个阅读页，且**零**详情页（点卡直接进阅读页，两层链路压成一层）。
      await tester.tap(find.byType(BookCard));
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
      expect(_detailPages(), findsNothing);
      expect(
        tester.widget<ReaderPage>(_readerPages()).record.bookId,
        a.record.bookId,
      );
    });

    testWidgets('回归①补：详情页仍可达——长按弹框「书籍详情」（`META-08` 唯一入口）',
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

      // 详情页字段可见：书名 + 来源标记（TXT 书名来自文件名，`META-08 ②`）。被覆盖的
      // 书架卡同名文本也在树上，故限定在详情页内断言；书名在详情页内**两处**（封面 + 标题栏）。
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

    testWidgets('回归①b：连点卡片只 push 一个阅读页（开书守卫吞第二击）',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 两击落在同一帧（中间无 pump）：开书守卫 `_opening` 从点下那一刻起
      // 覆盖到关书（`route.popped`）——第二击被吞，不得叠两个阅读页。
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

      // 打开甲书：一次点击**直接**进阅读页。
      await tester.tap(_cardOf('甲书'));
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
      expect(
        tester.widget<ReaderPage>(_readerPages()).record.bookId,
        a.record.bookId,
      );

      // 关书（pop）——**只推假帧、不给 runAsync**：此刻正处主因窗口，紧接着点另一本
      // 必须一次即进。pop 过渡 ticker **首拍才起算**、单次大帧推不完 → 多帧小步推完
      // 过渡 + 路由移除（全程无 runAsync，主因窗口不被破坏）。
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

    testWidgets('回归③：长按弹操作弹框，不误触发 onTap', (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('要删的书'), fileName: '删我2.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.longPress(find.byType(BookCard));
      await tester.pumpAndSettle();

      // 长按弹的是操作弹框（`MiDialog`），确认框要再点「移出书架」才出。
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

    testWidgets('回归④：点卡即进阅读页（骨架屏先上屏，书卡不再有 loading 覆盖层）',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _utf8TxtBytes('甲书正文。'), fileName: '甲书.txt'),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 点卡 → 只推一帧、不给 runAsync：阅读页已入栈（点击即开书），
      // 书源 / 章节表还没就绪 ⇒ 正文区是骨架屏。
      await tester.tap(find.byType(BookCard));
      await tester.pump();

      expect(_readerPages(), findsOneWidget, reason: '点卡应立即 push 阅读页（准备改在页内骨架屏期间）');
      expect(
        find.byKey(const ValueKey<String>('reader-skeleton')),
        findsOneWidget,
        reason: '书源未就绪时正文区应铺骨架屏（而非转圈 / 空白）',
      );
      // 书卡不再有「打开准备中」蒙层（旧形态：书架上转圈等准备）。
      expect(
        find.byKey(const ValueKey<String>('book-opening-overlay')),
        findsNothing,
      );

      // 准备完成后骨架屏换真正文。
      await _settle(tester);
      expect(_readerPages(), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('reader-skeleton')),
        findsNothing,
      );
    });

    // ── 分组（`P2-02`） ──

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
        tester
            .widget<MiPillTabBar>(find.byType(MiPillTabBar))
            .selectedIndex,
        0,
      );
      // 渲染层回落，**不改写**用户偏好（分组可能因同步 / 撤销而回来）。
      expect(shelfPrefs.prefs.groupId, groupId);
    });

    testWidgets('详情页「分组」行 → 新建分组后，返回书架 chips 出现该分组',
        (WidgetTester tester) async {
      // 详情页正文较长：调大视口并钉 `devicePixelRatio = 1`（默认 dpr=3 会把分组行
      // 挤出 `ListView` 懒构建范围）。
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);
      expect(find.text('玄幻'), findsNothing); // 还没有任何分组

      // 进详情页（长按弹框）→ 点「分组」入口（当前显示「未分组」）。
      await _openDetailViaSheet(tester, find.byType(BookCard));
      expect(find.byType(BookDetailPage), findsOneWidget);
      await tester.tap(find.text('未分组'));
      await _settle(tester);

      // 弹层：「未分组 / 新建分组…」。
      expect(find.text('新建分组…'), findsOneWidget);
      await tester.tap(find.text('新建分组…'));
      await _settle(tester);

      // ⚠️ 写分组走 `AtomicFile` **真文件 IO**，FakeAsync 区 `pumpAndSettle` 推不动它
      // → **必须用 `_settle`**（runAsync 让出真事件循环），否则此后 `setState` 永不执行。
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

    testWidgets('排序入口已移除（挂账），排序偏好仍驱动书架顺序',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        await repo.importFile(bytes: _txtBytes('A'), fileName: 'a.txt');
        await repo.importFile(bytes: _txtBytes('C'), fileName: 'c.txt');
      });

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 排序按钮已**移除**（顶部只留「搜索栏 + 胶囊行」）；反向钉住：谁把按钮加回搜索行就判红。
      expect(find.byIcon(Icons.sort), findsNothing);

      // 移除的只是**入口**，排序能力仍完整：偏好一改顺序随之变。两步都显式给方向，
      // 不依赖 store 的默认升降序（否则用例会跟着默认值漂）。
      await tester.runAsync(() async {
        await shelfPrefs.setSortField(ShelfSortField.title);
        await shelfPrefs.setSortAscending(true);
      });
      await _settle(tester);
      expect(_titles(tester).first, 'a', reason: '标题升序');

      await tester.runAsync(() => shelfPrefs.setSortAscending(false));
      await _settle(tester);
      expect(_titles(tester).first, 'c', reason: '标题降序');
    });

    testWidgets('点搜索栏 → 卡片式推入搜索页（头部三件套几何 + 返回圆钮出栈）',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(bytes: _txtBytes('甲'), fileName: 'alpha.txt'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(find.byType(MiPillTabBar), findsOneWidget);
      expect(find.byType(BookCard), findsOneWidget);

      await tester.tap(find.byKey(const Key('shelf-search-entry')));
      // 搜索页输入框光标闪烁是永不停的定时器：**禁 pumpAndSettle**，按转场时长
      // （`MiCardPageRouteMetrics.durationMs` = 400ms）固定推进。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));

      // ① 推入独立搜索页：整屏、无 App 级导航（书架被不透明路由盖住 → offstage）
      expect(find.byType(ShelfSearchPage), findsOneWidget);
      expect(find.byType(MiPillTabBar), findsNothing);
      expect(find.text('输入关键字开始搜索'), findsOneWidget);
      expect(find.byType(BookCard), findsNothing);

      // ② 头部几何（上游度量）：圆钮 ⌀44.1；输入框与圆钮同中心；圆钮→输入框 11
      final Rect back = tester
          .getRect(find.byKey(const ValueKey<String>('shelf-search-back')));
      final Rect field = tester
          .getRect(find.byKey(const ValueKey<String>('shelf-search-field')));
      expect(back.width, moreOrLessEquals(MiSearchBarMetrics.barHeight));
      expect(back.height, moreOrLessEquals(MiSearchBarMetrics.barHeight));
      expect(field.center.dy, moreOrLessEquals(back.center.dy, epsilon: 0.5));
      expect(field.left - back.right, moreOrLessEquals(11.0, epsilon: 0.2));

      // ③ 返回圆钮出栈，书架回来（头部仍是静态搜索胶囊）
      await tester.tap(find.byKey(const ValueKey<String>('shelf-search-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      expect(find.byType(ShelfSearchPage), findsNothing);
      expect(find.byType(MiSearchBar), findsOneWidget);
      expect(find.byType(MiPillTabBar), findsOneWidget);
    });

    testWidgets('搜索页输入即过滤（元数据命中）；无命中给提示；返回不残留',
        (WidgetTester tester) async {
      await tester.runAsync(() async {
        await repo.importFile(bytes: _txtBytes('甲'), fileName: 'alpha.txt');
        await repo.importFile(bytes: _txtBytes('乙'), fileName: 'beta.txt');
      });
      await tester.pumpWidget(buildApp());
      await _settle(tester);
      expect(find.byType(BookCard), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('shelf-search-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));

      Finder field() => find.descendant(
            of: find.byKey(const ValueKey<String>('shelf-search-field')),
            matching: find.byType(TextField),
          );

      // 输入即过滤：书名 / 作者 / 原始文件名任一命中
      await tester.enterText(field(), 'alpha');
      await tester.pump();
      expect(_titles(tester), <String>['alpha'], reason: '只留命中的那本');

      // 无命中 → 提示文案（不出网格）
      await tester.enterText(field(), '不存在的书名');
      await tester.pump();
      expect(find.byType(BookCard), findsNothing);
      expect(find.textContaining('没有匹配'), findsOneWidget);

      // 返回：搜索页出栈，书架全量网格照旧
      await tester.tap(find.byKey(const ValueKey<String>('shelf-search-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      expect(find.byType(ShelfSearchPage), findsNothing);
      expect(find.byType(BookCard), findsNWidgets(2));
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
