// `TTS-01`/`TTS-02` ReaderPage 朗读接线 widget 测试。
//
// 覆盖：①（`TTS-01` ①）点「朗读」从当前段起读——引擎收到正文、高亮在场、按钮
// 切「停止朗读」，再点停止并撤高亮；②（§15.3）init 不可用 → 中文提示「本机未
// 安装语音引擎」，不静默失败、不发声；③（`TTS-02` ③）手动滚动暂停自动跟随；
// ④（`TTS-02` ②）自动跟随滚动位移增长、高亮持续在场。
//
// 口径：装具复用 `test/reader/reader_harness`；玻璃钉「关」档；引擎注入
// [FakeTtsEngine]（speak 挂起等手动结局）；widget 内真异步 IO 用 [settle] 推进。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/highlight_follow.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../reader/reader_harness.dart';
import '../test_config.dart';
import 'tts_fakes.dart';

/// 当前朗读段高亮（`SpeakingHighlight.active` 恒定一层包装，只有 flag 翻转）。
Finder _activeHighlight() =>
    find.byWidgetPredicate((Widget w) => w is SpeakingHighlight && w.active);

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  group('TTS-01/02 朗读接线', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mreader_tts_ui_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
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
          ),
        );

    testWidgets('① 开读 → 文本上引擎 + 高亮在场 + 按钮切换；再点停止', (tester) async {
      final FakeTtsEngine engine = FakeTtsEngine();
      await tester.pumpWidget(buildApp(engine));
      await settle(tester);

      // 未开读：无朗读高亮，按钮为「朗读」（听钮在底部菜单上方，需先唤出）。
      await showChrome(tester);
      expect(_activeHighlight(), findsNothing);
      expect(find.byTooltip('朗读'), findsOneWidget);

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester);

      // 引擎收到当前段正文；朗读段高亮唯一在场；按钮切「停止朗读」。
      expect(engine.spoken, hasLength(1));
      expect(engine.spoken.single, startsWith('第1章正文'));
      expect(_activeHighlight(), findsOneWidget);
      expect(find.byTooltip('停止朗读'), findsOneWidget);

      // 再点 = 停止：高亮撤除、按钮复位、不再推进。
      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester, rounds: 20);

      expect(_activeHighlight(), findsNothing);
      expect(find.byTooltip('朗读'), findsOneWidget);
      expect(engine.spoken, hasLength(1));

      await closeBook(tester);
    });

    testWidgets('② 引擎 init 不可用 → 中文提示，不发声', (tester) async {
      final FakeTtsEngine engine = FakeTtsEngine()..initResult = false;
      await tester.pumpWidget(buildApp(engine));
      await settle(tester);
      await showChrome(tester);

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester, rounds: 20);

      expect(find.text('本机未安装语音引擎'), findsOneWidget);
      expect(engine.spoken, isEmpty);
      expect(_activeHighlight(), findsNothing);
      expect(find.byTooltip('朗读'), findsOneWidget); // 按钮未入朗读态

      await closeBook(tester);
    });

    testWidgets('③ 手动滚动暂停跟随（TTS-02 ③）：拖后再推进，位移不变', (tester) async {
      final FakeTtsEngine engine = FakeTtsEngine();
      await tester.pumpWidget(buildApp(engine));
      await settle(tester);
      await showChrome(tester);

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester);
      expect(engine.spoken, hasLength(1));

      // 手指拖拽（dragDetails 非空 → noteManualScroll）。
      await tester.drag(find.byType(PagedScroller), const Offset(0, -600));
      await settle(tester); // 停稳（ballistic + 停手采样防抖）

      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      final double before = state.offset;
      expect(before, greaterThan(0)); // 拖拽确实动了

      // 推进一段：朗读推进（发声 + 高亮换段）但**不再滚动**。
      engine.completeCurrent();
      await settle(tester, rounds: 20);

      expect(engine.spoken, hasLength(2));
      expect(state.offset, closeTo(before, 1.0));

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester, rounds: 10);
      await closeBook(tester);
    });

    testWidgets('④ 自动跟随（TTS-02 ②）：连续推进 14 段，位移增长', (tester) async {
      final FakeTtsEngine engine = FakeTtsEngine();
      await tester.pumpWidget(buildApp(engine));
      await settle(tester);
      await showChrome(tester);

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester);
      expect(engine.spoken, hasLength(1));

      final PagedScrollerState state =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      final double start = state.offset;

      for (int i = 0; i < 14; i++) {
        final int before = engine.spoken.length;
        engine.completeCurrent();
        await settle(tester, rounds: 20);
        expect(
          engine.spoken.length,
          before + 1,
          reason: '第 ${i + 1} 次推进后应读下一段',
        );
      }

      // 越过视口下缘后逐次落位 → 卷轴位移明显增长。
      expect(state.offset, greaterThan(start + 100));
      expect(_activeHighlight(), findsOneWidget); // 高亮持续与朗读一致

      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester, rounds: 10);
      await closeBook(tester);
    });
  });
}
