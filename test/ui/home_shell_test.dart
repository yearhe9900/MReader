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
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/settings/shelf_layout_store.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';
import 'package:mreader/stats/stats_service.dart';
import 'package:mreader/ui/home_shell.dart';

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
            perfPrefs: PerfPrefsStore(tempDir),
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
}
