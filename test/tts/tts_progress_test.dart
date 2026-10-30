// `TTS-06` 朗读进度联动 widget 测试。
//
// 覆盖：② 数据面——朗读期间每段推进即写入阅读进度（progressStore 落盘可见推进）；
// ① 落点面——手动滚动暂停跟随后（视口被拖离、与朗读位不同步）停止并关书，落点
// 仍是**朗读坐标**，陈旧视口坐标**不得覆盖**（`_ttsProgress` override 的核心防线）。
//
// 口径：装具复用 `test/reader/reader_harness`（FakeBookSource 3 章 × 20 段 /
// settle / 假仓库）；玻璃钉「关」档；引擎注入 [FakeTtsEngine]（speak 挂起等
// 手动结局）；期望值按 `_writeTtsProgress` 同源算法（段落前缀和 ÷
// `PagePaginator.charCountOf`）在测试内独立算出，输入取假源字面量。
// 真异步 IO（progressStore.load）一律 `tester.runAsync` 包裹。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../reader/reader_harness.dart';
import '../test_config.dart';
import 'tts_fakes.dart';

/// 假源第一章段落（与 `FakeBookSource.content(0)` 同字面量）。
List<String> _chapterOneParas() =>
    <String>[for (int p = 1; p <= 20; p++) '第1章正文$p'];

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  group('TTS-06 朗读进度联动', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_tts_prog_');
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

    testWidgets('①② 每段直写进度；拖离后停止关书仍落朗读坐标', (tester) async {
      final FakeTtsEngine engine = FakeTtsEngine();
      await tester.pumpWidget(buildApp(engine));
      await settle(tester);

      // 开读（起点 = 视口中心命中段；先记下起点段供期望值计算）。
      await showChrome(tester); // 听钮在底部菜单上方
      await tester.tap(find.byKey(const Key('reader-control-tts')));
      await settle(tester);
      expect(engine.spoken, hasLength(1));

      // 手指拖拽：暂停自动跟随 + 视口离开朗读位（override 让位路径）。
      await tester.drag(find.byType(PagedScroller), const Offset(0, -600));
      await settle(tester);

      // 推进 4 段（跟随已暂停 → 视口不再跟读），共发声 5 段。
      for (int i = 0; i < 4; i++) {
        engine.completeCurrent();
        await settle(tester, rounds: 20);
      }
      expect(engine.spoken, hasLength(5));

      // 期望朗读坐标：起始段 + 4 次推进后的当前段，前缀和 ÷ 全章字数。
      final List<String> paras = _chapterOneParas();
      final int startPara = paras.indexOf(engine.spoken.first);
      expect(startPara, greaterThanOrEqualTo(0), reason: '首段应命中假源段落');
      final int activePara = startPara + 4;
      int prefix = 0;
      for (int p = 0; p < activePara; p++) {
        prefix += paras[p].length;
      }
      final double expected =
          prefix / PagePaginator.charCountOf(paras);

      // ② 朗读期间进度已落盘（数据面：段推进即写）。
      final ReadingProgress? mid = await tester
          .runAsync<ReadingProgress?>(() => progressStore.load('testbook01'));
      expect(mid, isNotNull);
      expect(mid!.chapterIndex, 0);
      expect(mid.chapterHref, 'h1');
      expect(mid.chapterPos, closeTo(expected, 1e-9));

      // ① 关书：dispose 收尾保存走 override → 落点仍是朗读坐标，
      // 不被拖离后的视口坐标覆盖。
      await closeBook(tester);
      final ReadingProgress? after = await tester
          .runAsync<ReadingProgress?>(() => progressStore.load('testbook01'));
      expect(after, isNotNull);
      expect(after!.chapterIndex, 0);
      expect(after.chapterHref, 'h1');
      expect(after.chapterPos, closeTo(expected, 1e-9));
    });
  });
}
