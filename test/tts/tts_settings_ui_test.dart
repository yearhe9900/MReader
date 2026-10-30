// `TTS-04`/`TTS-05` 朗读设置面板与引擎应用接线 widget 测试。
//
// 覆盖：A（`TTS-04` ①② 开读路径）开读前应用存储的语速 / 音色——假引擎收到
// `setRate(1.0)` 与 `setVoice(zh-fake)`；B（①② 面板路径 + `TTS-05`）面板滑块 /
// 音色 / 定时三区，拖语速与切音色同步引擎，「跟随系统语速」开关回默认并禁用
// 滑块，定时 30 分钟落盘、新实例回读一致（② 重启保留）。
//
// 口径：装具复用 `test/reader/reader_harness`；玻璃钉「关」档；引擎注入
// [FakeTtsEngine]；弹层开合用 `pumpAndSettle`（无无限动画）；⚠️ **本文件不触发
// 定时计时**（面板测试不朗读、A 测试不设定时 → 不遗留 pending Timer）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/tts_settings_sheet.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/tts/online_tts.dart';
import 'package:mreader/tts/tts_engine.dart';
import 'package:mreader/tts/tts_settings.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/tts_settings_page.dart';

import '../reader/reader_harness.dart';
import '../test_config.dart';
import 'tts_fakes.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  group('TTS-04/05 朗读设置', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;
    late TtsSettingsStore ttsSettings;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mreader_tts_sheet_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
      ttsSettings = TtsSettingsStore(tempDir);
      await ttsSettings.load();
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// 关档宿主（builder 形制：provider 覆盖路由树，toast 零玻璃开销）。
    Widget buildApp(FakeTtsEngine engine) => MaterialApp(
          builder: (BuildContext context, Widget? child) => GlassScopeProvider(
            config: glassTierConfigFor(GlassQualityTier.off),
            child: child ?? const SizedBox.shrink(),
          ),
          home: ReaderPage(
            source: FakeBookSource(),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: repo,
            ttsEngine: engine,
            ttsSettings: ttsSettings,
          ),
        );

    testWidgets('A 开读应用存储的语速 / 音色（TTS-04 ①②）', (tester) async {
      // 真实落盘 IO 必须包 runAsync（testWidgets 体内直接 await 会挂死）。
      await tester.runAsync(() async {
        await ttsSettings.setRate(1.0);
        await ttsSettings.setVoice(name: 'zh-fake', locale: 'zh-CN');
      });
      final FakeTtsEngine engine = FakeTtsEngine();
      await tester.pumpWidget(buildApp(engine));
      await settle(tester);
      await showChrome(tester); // 听钮在底部菜单上方，需先唤出菜单

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester);

      expect(engine.spoken, hasLength(1));
      expect(engine.lastRate, 1.0); // 存储语速在开读前已应用
      expect(engine.lastVoice?.name, 'zh-fake');
      expect(engine.lastVoice?.locale, 'zh-CN');

      // 停读收尾（不留会话）。
      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester, rounds: 20);
      await closeBook(tester);
    });

    testWidgets('B 面板三区 + 实时生效 + 落盘回读（TTS-04/05）', (tester) async {
      final FakeTtsEngine engine = FakeTtsEngine();
      await tester.pumpWidget(buildApp(engine));
      await settle(tester);

      // 朗读设置已收进菜单「更多」列表：先唤出菜单 → 开更多 → 选「朗读设置」
      // （懒建控制器取音色 → 弹层）。
      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('朗读设置'));
      await tester.pumpAndSettle();

      expect(find.text('朗读设置'), findsOneWidget);
      expect(find.byKey(const Key('tts-rate-slider')), findsOneWidget);
      expect(find.byKey(const Key('tts-follow-rate')), findsOneWidget);
      expect(find.byKey(const Key('tts-voice-default')), findsOneWidget);
      expect(find.text('zh-fake'), findsOneWidget);
      expect(find.byKey(const Key('tts-sleep-off')), findsOneWidget);
      expect(find.byKey(const Key('tts-sleep-30')), findsOneWidget);
      expect(find.byKey(const Key('tts-sleep-180')), findsOneWidget);

      // 语速滑块拖动 → store 与引擎立即同步（TTS-04 ①）。
      await tester.drag(
        find.byKey(const Key('tts-rate-slider')),
        const Offset(120, 0),
      );
      await settle(tester, rounds: 10);
      expect(ttsSettings.value.rate, greaterThan(0.5));
      expect(engine.lastRate, ttsSettings.value.rate);

      // 音色 chip 切换 → 引擎收到对应 voice（TTS-04 ②）。
      await tester.tap(find.text('zh-fake'));
      await settle(tester, rounds: 10);
      expect(ttsSettings.value.voiceName, 'zh-fake');
      expect(engine.lastVoice?.name, 'zh-fake');

      // 定时 30 分钟（TTS-05）。
      await tester.tap(find.byKey(const Key('tts-sleep-30')));
      await settle(tester, rounds: 10);
      expect(ttsSettings.value.sleepMinutes, 30);

      // 跟随系统语速 → 引擎回默认 0.5 且滑块禁用（TTS-04 开关语义）。
      await tester.tap(find.byKey(const Key('tts-follow-rate')));
      await settle(tester, rounds: 10);
      expect(ttsSettings.value.followSystemRate, isTrue);
      expect(engine.lastRate, 0.5);
      final Slider slider =
          tester.widget<Slider>(find.byKey(const Key('tts-rate-slider')));
      expect(slider.onChanged, isNull);

      // 落盘回读（TTS-05 ② 重启保留）：排空真实 IO 后用新实例验证。
      await settle(tester, rounds: 20);
      final TtsSettingsStore reopened = TtsSettingsStore(tempDir);
      await tester.runAsync(() => reopened.load());
      expect(reopened.value.sleepMinutes, 30);
      expect(reopened.value.voiceName, 'zh-fake');
      expect(reopened.value.followSystemRate, isTrue);

      await closeBook(tester);
    });
  });

  group('TTS-07 引擎选择区（面板）', () {
    late Directory tempDir;
    late OnlineTtsStore onlineTts;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mreader_tts_engine_');
      onlineTts = OnlineTtsStore(tempDir);
      await onlineTts.load();
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// 直接泵面板（Scaffold 给 ChoiceChip 一个 Material 祖先）。
    Widget sheet({
      OnlineTtsStore? online,
      required ValueChanged<TtsSettings> onChanged,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: TtsSettingsSheet(
              settings: const TtsSettings(),
              voices: const <TtsVoice>[],
              onChanged: onChanged,
              onlineTts: online,
            ),
          ),
        );

    testWidgets('store 缺席 → 引擎区与配置入口整体隐藏', (tester) async {
      TtsSettings? got;
      await tester.pumpWidget(sheet(onChanged: (TtsSettings s) => got = s));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tts-engine-system')), findsNothing);
      expect(find.byKey(const Key('tts-engine-online')), findsNothing);
      expect(find.byKey(const Key('tts-online-config')), findsNothing);
      expect(find.text('引擎'), findsNothing);
      expect(got, isNull);
    });

    testWidgets('chip 切在线引擎回传 engine + 配置入口推进配置页', (tester) async {
      TtsSettings? got;
      await tester.pumpWidget(
        sheet(online: onlineTts, onChanged: (TtsSettings s) => got = s),
      );
      await tester.pumpAndSettle();

      expect(find.text('引擎'), findsOneWidget);
      expect(find.byKey(const Key('tts-engine-system')), findsOneWidget);
      expect(find.byKey(const Key('tts-engine-online')), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('tts-engine-system')))
            .selected,
        isTrue, // 默认系统引擎
      );

      await tester.tap(find.byKey(const Key('tts-engine-online')));
      await tester.pumpAndSettle();
      expect(got?.engine, TtsEngineKind.online);
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('tts-engine-online')))
            .selected,
        isTrue,
      );

      // 配置入口 → 在线 TTS 配置页（TTS-07 的「怎么连」表单）。
      await tester.tap(find.byKey(const Key('tts-online-config')));
      await tester.pumpAndSettle();
      await settle(tester, rounds: 10); // initState 读密钥（真 IO）
      await tester.pumpAndSettle();
      expect(find.byType(TtsSettingsPage), findsOneWidget);
      expect(find.text('模式'), findsOneWidget);
    });
  });
}
