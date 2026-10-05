// `TTS-04`/`TTS-05` 朗读设置面板与引擎应用接线 widget 测试（M3-T08）。
//
// 验收映射：
//   A（`TTS-04` ①② 开读路径）：开读前应用存储的语速 / 音色——假引擎收到
//      `setRate(1.0)` 与 `setVoice(zh-fake)`；
//   B（`TTS-04` ①②面板路径 + `TTS-05`）：面板打开出滑块 / 音色 / 定时三区；
//      拖语速 → store 与引擎同步变化；切音色 chip → 引擎收到对应 voice；
//      开「跟随系统语速」→ 引擎回默认 0.5 且滑块禁用；定时 30 分钟落盘，
//      新 store 实例回读一致（`TTS-05` ② 重启保留）。
//
// 口径：装具复用 `test/reader/reader_harness`（FakeBookSource / settle /
// 假仓库）；玻璃钉「关」档；引擎注入 [FakeTtsEngine]；弹层开合用
// `pumpAndSettle`（无无限动画）；**本文件不触发定时计时**（面板测试不朗读、
// A 测试不设定时 → 不遗留 pending Timer）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/tts/tts_settings.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

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

      // 打开朗读设置面板（懒建控制器取音色 → 弹层）。
      await tester.tap(find.byKey(const Key('reader-control-tts-settings')));
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
}
