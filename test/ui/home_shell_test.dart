// `test/ui/home_shell_test.dart`：主壳层接线测试（底栏绿圆钮「更多」菜单 → 书架）。
//
// 书架「添加图书」入口 = 底栏**绿圆钮**（`MiGlassNavFab`）的竖点「更多」→ `MiMenu`
// 菜单「添加图书」（经 `GlobalKey<ShelfPageState>` 转 `pickAndImport`）；同菜单的
// 「排序」走级联子菜单（规则 = `ShelfSortField`，排在「添加图书」上方、只做降序）。
// 本文件钉整条接线链：圆钮 → 菜单项 → pickAndImport → `FilePicker.platform.pickFiles`
// （桌面走格式层白名单、移动端不过滤，多选），以及排序级联选中即落盘且方向恒降序。
// `FilePicker` 用假件替换（setter 允许注入，假件须 **extends** [FilePicker] 才能过
// `PlatformInterface.verifyToken`），记录调用参数后返回 null（模拟取消）。
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/settings/shelf_layout_store.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';
import 'package:mreader/stats/stats_service.dart';
import 'package:mreader/ui/glass_nav_host.dart';
import 'package:mreader/ui/home_shell.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart'
    show MiGlassNavMetrics, MiGlassNavBar, MiSearchCancelButton;
import 'package:mreader/ui/shelf_page.dart'
    show importPickerOptions, shelfSortLabel;

import '../reader/reader_harness.dart';
import '../test_config.dart';

/// 假 [FilePicker]：记录 `pickFiles` 调用与关键参数，返回 null（用户取消）。
///
/// ⚠️ 必须 `extends`（不是 `implements`）：`FilePicker.platform` 的 setter 会
/// `PlatformInterface.verifyToken` 校验实例携带 file_picker 私有 token，只有
/// 经 `FilePicker()` 构造链（`super(token: _token)`）的子类才带得上。
/// 其余成员基类自带 `UnimplementedError` 默认实现，无需补。
class _RecordingFilePicker extends FilePicker {
  int pickCalls = 0;
  FileType? lastType;
  List<String>? lastAllowedExtensions;
  bool? lastAllowMultiple;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickCalls++;
    lastType = type;
    lastAllowedExtensions = allowedExtensions;
    lastAllowMultiple = allowMultiple;
    return null;
  }
}

/// 绿圆钮 glyph 的 [Semantics]（`HomeShell` 接线时挂的「更多」标签）。
///
/// 不用 `find.bySemanticsLabel`：空态引导按钮的语义标签「导入书籍」与菜单项同名时
/// 会歧义；这里按 [Semantics.properties.label] 精确匹配 widget 本体，只命中绿圆钮。
Finder _moreGlyph() => find.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.label == '更多',
    );

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('底栏绿圆钮 → 导入接线', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late LibraryRepository repo;
    late ShelfPrefsStore prefs;
    late _RecordingFilePicker picker;
    FilePicker? originalPicker;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_home_shell_');
      paths = TestAppPaths(tempDir);
      repo = fakeRepository(paths);
      prefs = ShelfPrefsStore(tempDir);
      picker = _RecordingFilePicker();
      // `FilePicker._instance` 是 `late`：未初始化时 getter 抛错，此时无从恢复，
      // 留假件在原地无妨（本文件独立 isolate，不影响其它测试文件）。
      try {
        originalPicker = FilePicker.platform;
      } catch (_) {
        originalPicker = null;
      }
      FilePicker.platform = picker;
    });

    tearDown(() async {
      if (originalPicker != null) {
        FilePicker.platform = originalPicker!;
      }
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildShell() => MaterialApp(
          home: HomeShell(
            repository: repo,
            coverStore: FileCoverStore(paths),
            progressStore: ProgressStore(paths),
            shelfPrefs: prefs,
            shelfLayout: ShelfLayoutStore(tempDir),
            settings: SettingsStore(tempDir),
            statsService: StatsService(paths),
            aiStore: ProviderStore(
              tempDir,
              AiKeyVault(FileSecureStore(directory: tempDir)),
            ),
            aiClient: AiClient(),
          ),
        );

    testWidgets('点绿圆钮 → 「添加图书」→ pickFiles（全部已支持格式，多选）被调用一次',
        (tester) async {
      // ⚠️ 必须钉**窄视口**：默认测试窗 800 宽 > `kShellRailBreakpoint`(600)
      // 会走宽屏侧边导航轨，绿圆钮（底栏形态专属）不在树上。
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      // 绿圆钮挂在「书架」tab（tabIndex 0），首页默认选中 → 弹出可见。
      expect(_moreGlyph(), findsOneWidget);

      await tester.tap(_moreGlyph());
      await settle(tester, rounds: 60); // 「更多」菜单展开（弹簧 ~0.5s）
      expect(find.text('添加图书'), findsOneWidget,
          reason: '圆钮只负责开菜单，导入动作在菜单项里');
      expect(picker.pickCalls, 0, reason: '开菜单不该直接触发文件选择器');

      await tester.tap(find.text('添加图书'));
      await tester.pump(); // pickAndImport 的假件 await 在微任务里完成

      expect(picker.pickCalls, 1, reason: '菜单「添加图书」必须走到 FilePicker');
      expect(picker.lastType, FileType.custom,
          reason: '测试宿主是桌面平台 ⇒ 走保留白名单的分支');
      // ⚠️ 期望值**故意硬编码字面量**（不引用 `kImportExtensions`）：引用同一
      // 常量会变成同义反复，白名单漏掉 azw3 / mobi 时用例照样判绿。
      expect(picker.lastAllowedExtensions, <String>[
        'epub',
        'txt',
        'pdf',
        'cbz',
        'cbr',
        'mobi',
        'azw3',
      ], reason: 'MOBI/AZW3 等已支持格式必须能在导入选择器里选中');
      expect(picker.lastAllowMultiple, isTrue);

      // 拆树排空（各页 initState 起的真 IO），避免 tearDown 删目录竞态。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });

    testWidgets('书架进入就地搜索态 → 浮动底栏与绿圆钮整组卸掉；退出装回',
        (tester) async {
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      expect(find.byType(GlassNavHost), findsOneWidget);
      expect(_moreGlyph(), findsOneWidget);

      await tester.tap(find.byKey(const Key('shelf-search-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(GlassNavHost), findsNothing,
          reason: '搜索态照参考素材是整屏无 App 级导航：底栏整组卸掉');
      expect(_moreGlyph(), findsNothing);

      await tester.tap(find.byType(MiSearchCancelButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(GlassNavHost), findsOneWidget,
          reason: '退出搜索态底栏装回');
      expect(_moreGlyph(), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });

    testWidgets('绿圆钮带「更多」无障碍标签（按钮语义）', (tester) async {
      // 同上：窄视口才走底栏形态。
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      final Semantics semantics =
          tester.widget<Semantics>(_moreGlyph());
      expect(semantics.properties.button, isTrue);

      // 旧入口（顶部加号按钮）已移除；导入只剩「更多」菜单 + 空态引导两个入口。
      expect(find.byIcon(Icons.add), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });
    testWidgets('「更多」→ 排序级联：排序在「添加图书」上方、列全部规则、选中即降序',
        (tester) async {
      // 同上：窄视口才走底栏形态（宽屏圆钮挂在侧栏栏尾）。
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      await tester.tap(_moreGlyph());
      await settle(tester, rounds: 60);
      // 一级两行：**排序在上、添加图书在下**；副标题 = 当前规则（无方向档）。
      expect(find.text('排序'), findsOneWidget);
      expect(find.text('添加图书'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('排序')).dy,
        lessThan(tester.getTopLeft(find.text('添加图书')).dy),
        reason: '排序行必须排在添加图书上方',
      );
      expect(find.text('导入时间'), findsOneWidget,
          reason: '默认规则 = 导入时间（ShelfPrefs 默认值）');
      expect(find.text('升序'), findsNothing,
          reason: '方向没有 UI 入口，菜单里不该出现升序');

      await tester.tap(find.text('排序'));
      // 退出层（一级）约 300ms 才从树上移除，等 480ms 才算切干净。
      await settle(tester, rounds: 60);
      // 级联子菜单 = 返回上级的同名行 + 全部规则。
      expect(find.text('排序'), findsOneWidget, reason: '首行是返回上级的同名行');
      for (final ShelfSortField field in ShelfSortField.values) {
        expect(find.text(shelfSortLabel(field)), findsWidgets,
            reason: '规则「${shelfSortLabel(field)}」必须在子菜单里可点');
      }

      // `.last`：返回上级那行会照抄父项副标题（= 当前规则名），同名文本会
      // 同时命中「副标题」与「规则行」，规则行在树里靠后。
      await tester.tap(find.text('书名').last);
      await settle(tester, rounds: 60);
      expect(prefs.prefs.sortField, ShelfSortField.title,
          reason: '选中规则必须写进偏好（书架顺序由它驱动）');
      expect(prefs.prefs.sortAscending, isFalse, reason: '只做降序');

      // 再开一次：菜单读的是**最新偏好**（壳层订阅 prefs，不是展开那刻的快照）。
      await tester.tap(_moreGlyph());
      await settle(tester, rounds: 60);
      expect(find.text('书名'), findsOneWidget,
          reason: '一级行副标题必须跟着偏好刷新');
      expect(find.text('书名 · 降序'), findsNothing, reason: '方向不进副标题');
      await tester.tap(find.text('排序'));
      await settle(tester, rounds: 60);
      await tester.tap(find.text('书名').last);
      await settle(tester, rounds: 60);
      expect(prefs.prefs.sortAscending, isFalse,
          reason: '同一条规则再点也不翻方向（升序没有入口）');

      // 残留的升序（旧偏好数据）在选中规则时被拉回降序。
      await tester.runAsync(() => prefs.setSortAscending(true));
      await settle(tester, rounds: 20);
      expect(prefs.prefs.sortAscending, isTrue, reason: '前提：旧数据确实是升序');
      await tester.tap(_moreGlyph());
      await settle(tester, rounds: 60);
      await tester.tap(find.text('排序'));
      await settle(tester, rounds: 60);
      await tester.tap(find.text('书名').last);
      await settle(tester, rounds: 60);
      expect(prefs.prefs.sortAscending, isFalse,
          reason: '升序在选中规则时必须被拉回降序');

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });
  });

  // ────────────────────────────────────────────────────────────────────────────
  // 底栏浮起口径 + 亮色侧栏列铺页底色（对照上游 demo）
  // ────────────────────────────────────────────────────────────────────────────
  group('底栏浮起与页底色（对齐上游 demo_app.dart）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_shell_geom_');
      paths = TestAppPaths(tempDir);
      repo = fakeRepository(paths);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildShell() => MaterialApp(
          home: HomeShell(
            repository: repo,
            coverStore: FileCoverStore(paths),
            progressStore: ProgressStore(paths),
            shelfPrefs: ShelfPrefsStore(tempDir),
            shelfLayout: ShelfLayoutStore(tempDir),
            settings: SettingsStore(tempDir),
            statsService: StatsService(paths),
            aiStore: ProviderStore(
              tempDir,
              AiKeyVault(FileSecureStore(directory: tempDir)),
            ),
            aiClient: AiClient(),
          ),
        );

    testWidgets('手机模式：底栏浮起 = 距物理屏底 24.2（不叠手势条 inset）',
        (tester) async {
      // 窄视口（393 < 600）走底栏形态。
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 根因契约：浮起口径 = 距**物理屏底** 24.2dp（`MiGlassNavMetrics` 实测）——
      // edge-to-edge 下 `Positioned.bottom` 量到物理屏底，**不得再叠 safeBottom**
      // （叠手势条 inset 会把胶囊整抬 ~34dp）。**差分判别**：注入 bottom inset = 34 后
      // 胶囊底边仍须距屏底 24.2，「叠回 + safeBottom」的变异会让胶囊上移 34 判红
      // （§2.97：钉住新行为必须有能判别它的用例）。
      tester.view.padding = const FakeViewPadding(bottom: 34);
      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      final double inset = tester.view.padding.bottom;
      expect(inset, 34, reason: '测试窗 bottom inset 须已注入为 34');

      final Rect bar = tester.getRect(find.byType(MiGlassNavBar).first);
      // 屏高 800 − 浮起 24.2 = 胶囊底边（**不减 inset**）。
      expect(
        bar.bottom,
        moreOrLessEquals(800 - kShellNavBarBottomLift, epsilon: 0.01),
        reason: '底栏胶囊底边距物理屏底须恒为 kShellNavBarBottomLift（24.2），'
            '与手势条 inset 无关；叠 inset 时胶囊会偏高 34',
      );
      // 胶囊高度须等于上游实测 token，不得被宿层压缩/拉伸。
      expect(
        bar.height,
        moreOrLessEquals(MiGlassNavMetrics.barHeight, epsilon: 0.01),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });

    testWidgets('宽屏模式：整块布局铺页底色（侧栏列与内容列同底，无色差竖缝）',
        (tester) async {
      // 宽视口（800 > 600）走侧栏形态——侧栏列必须同样铺页底色，否则露出窗口底色，
      // 浅色下与页面之间出现一道色差竖缝。
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      final Color pageBg =
          Theme.of(tester.element(find.byType(HomeShell)))
              .scaffoldBackgroundColor;
      // 侧栏那一列（x < gutterWidth）背后的最底层容器必须已是页底色——由壳层
      // ColoredBox 铺满整窗提供。取 ancestor 链上首个同色 ColoredBox。
      final Iterable<ColoredBox> colored = tester.widgetList<ColoredBox>(
        find.ancestor(
          of: find.byType(IndexedStack),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(colored, isNotEmpty, reason: '壳层须有 ColoredBox 铺页底色');
      final ColoredBox gutterBg =
          colored.firstWhere((ColoredBox w) => w.color == pageBg);
      final Rect gutterRect = tester.getRect(find.byWidget(gutterBg));
      // 该底色盒必须横跨整窗（含侧栏列与内容列），否则侧栏列仍会露底。
      expect(gutterRect.left, lessThanOrEqualTo(0));
      expect(
        gutterRect.width,
        greaterThanOrEqualTo(800),
        reason: '页底色须铺满整窗宽度（含侧栏那一列），不得只铺内容列',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });
  });

  // ────────────────────────────────────────────────────────────────────────────
  // 导入选择器分流：移动端系统类型映射会漏格式，必须绕开扩展名过滤
  // ────────────────────────────────────────────────────────────────────────────
  group('importPickerOptions（移动端不过滤 / 桌面保留白名单）', () {
    test('mobile=true → FileType.any + allowedExtensions 为 null', () {
      final ({FileType type, List<String>? allowedExtensions}) options =
          importPickerOptions(mobile: true);
      expect(options.type, FileType.any,
          reason: 'Android MimeTypeMap / iOS UTType 解析不出 azw3 等扩展名时'
              '会静默跳过，custom 白名单在真机上等于把书挡在门外');
      expect(options.allowedExtensions, isNull,
          reason: 'FileType.any 传非空 allowedExtensions 会被 file_picker 抛异常');
    });

    test('mobile=false → FileType.custom + 7 项白名单（含 azw3）', () {
      final ({FileType type, List<String>? allowedExtensions}) options =
          importPickerOptions(mobile: false);
      expect(options.type, FileType.custom);
      // 硬编码字面量（不引用 `kImportExtensions`），保证漏格式能判红。
      expect(options.allowedExtensions, <String>[
        'epub',
        'txt',
        'pdf',
        'cbz',
        'cbr',
        'mobi',
        'azw3',
      ]);
    });

    test('不传 mobile 时按真实平台判定（widget 测试宿主 = 桌面）', () {
      expect(importPickerOptions().type, FileType.custom,
          reason: 'flutter test 跑在 Windows/Linux 宿主，不是 Android/iOS');
    });
  });
}
