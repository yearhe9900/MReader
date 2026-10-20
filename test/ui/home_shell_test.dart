// `test/ui/home_shell_test.dart`：主壳层接线测试（底栏绿圆钮 → 书架导入）。
//
// 2026-10-16 功能迁移批：书架「添加图书」入口从顶部加号按钮迁到底栏**绿圆钮**
// （`MiGlassNavFab`，经 `GlobalKey<ShelfPageState>` 转 `pickAndImport`）。
// 本文件钉整条接线链：绿圆钮 onTap → pickAndImport → `FilePicker.platform
// .pickFiles`（epub/txt 多选）。`FilePicker` 用假件替换（`FilePicker.platform`
// 的 setter 允许注入，假件须 **extends** [FilePicker] 才能过
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
import 'package:mreader/ui/home_shell.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart'
    show MiGlassNavMetrics, MiGlassNavBar;

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
    lastAllowedExtensions = allowedExtensions;
    lastAllowMultiple = allowMultiple;
    return null;
  }
}

/// 绿圆钮 glyph 的 [Semantics]（`HomeShell` 接线时挂的「导入书籍」标签）。
///
/// 不用 `find.bySemanticsLabel`：空态引导按钮的语义标签同为「导入书籍」会歧义；
/// 这里按 [Semantics.properties.label] 精确匹配 widget 本体，只命中绿圆钮。
Finder _fabGlyph() => find.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.label == '导入书籍',
    );

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('底栏绿圆钮 → 导入接线', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late LibraryRepository repo;
    late _RecordingFilePicker picker;
    FilePicker? originalPicker;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_home_shell_');
      paths = TestAppPaths(tempDir);
      repo = fakeRepository(paths);
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
      // 导入预热收尾再删目录（防后台写盘 vs 删目录竞态，§2.81 同款口径）。
      await repo.pendingWarmUps;
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

    testWidgets('点绿圆钮 → pickFiles（epub/txt 多选）被调用一次', (tester) async {
      // ⚠️ 必须钉**窄视口**：默认测试窗 800 宽 > `kShellRailBreakpoint`(600)
      // 会走宽屏侧边导航轨，绿圆钮（底栏形态专属）不在树上。
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      // 绿圆钮挂在「书架」tab（tabIndex 0），首页默认选中 → 弹出可见。
      expect(_fabGlyph(), findsOneWidget);

      await tester.tap(_fabGlyph());
      await tester.pump(); // pickAndImport 的假件 await 在微任务里完成

      expect(picker.pickCalls, 1, reason: '绿圆钮 onTap 必须走到 FilePicker');
      expect(picker.lastAllowedExtensions, <String>['epub', 'txt']);
      expect(picker.lastAllowMultiple, isTrue);

      // 拆树排空（各页 initState 起的真 IO），避免 tearDown 删目录竞态。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });

    testWidgets('绿圆钮带「导入书籍」无障碍标签（按钮语义）', (tester) async {
      // 同上：窄视口才走底栏形态。
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildShell());
      await settle(tester, rounds: 30);

      final Semantics semantics =
          tester.widget<Semantics>(_fabGlyph());
      expect(semantics.properties.button, isTrue);

      // 旧入口（顶部加号按钮）已移除，导入只剩绿圆钮 + 空态引导两个入口。
      expect(find.byIcon(Icons.add), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });
  });

  // ────────────────────────────────────────────────────────────────────────────
  // 2026-10-18 反馈批：底栏浮起口径 + 亮色侧栏列铺页底色（截图对照上游）
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
      await repo.pendingWarmUps;
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

      // 2026-10-18/19 两轮真机反馈「手机模式底栏高度变了 / 还是没调整过来」
      // 的根因契约：浮起口径 = `MiGlassNavMetrics` 实测「bar bottom sits
      // 24.2 dp above **screen bottom**」——edge-to-edge 下 `Positioned.bottom`
      // 量到物理屏底，**不再叠 safeBottom**（第一轮误叠手势条 inset，胶囊被
      // 整抬 ~34dp）。
      // **差分判别**：注入 bottom inset = 34 后，胶囊底边仍须距屏底 24.2——
      // 「叠回 + safeBottom」的变异会让胶囊上移 34 判红（§2.97：钉住新行为
      // 必须有能判别它的用例）。
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
      // 宽视口（800 > 600）走侧栏形态——此时内容只占右侧列，侧栏列必须同样
      // 铺页底色，否则露出窗口底色，浅色下与页面之间出现一道色差（截图差异根因）。
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
}
