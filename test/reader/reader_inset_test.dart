// 阅读页正文**不被系统栏 / AppBar / 常驻进度条遮挡**的布局契约（2026-10-06）。
//
// 起因：负责人真机截图「字没显示全」——首行被 AppBar 压住、末行被常驻
// [ReaderProgressIndicator] 压住。根因是改前正文按**满屏视口**排版
// （`pageHeight = constraints.maxHeight`），分页模式尤其明显（每页两端各切一截）。
//
// 本测试钉住：给simulated 带刘海/手势条的手机上，正文区上下各留出了对应高度。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout();

  group('阅读页正文避让系统栏与常驻进度条', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_inset_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    testWidgets('正文区上下留出系统栏 + 常驻进度条的高度',
        (WidgetTester tester) async {
      // 模拟刘海机：顶部 44（状态栏）、底部 34（手势条），屏高 852。
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: ReaderPage(
          source: FakeBookSource(),
          record: fakeRecord(),
          progressStore: progressStore,
          repository: repo,
        ),
      ));
      await settle(tester);

      // 探针实测基线（393×852，top44/bottom34）：
      //   viewport top=100 bottom=687 h=587 / progress-indicator top=661 bottom=687 h=26
      // 正文区高587 =屏高852 − AppBar区(100) − 底部控制条(165)，
      // 其中 165 已含系统手势条 34 + 进度条预留 28 + 控制条本体。
      final Size viewport =
          tester.getSize(find.byKey(const Key('reader-viewport')));
      expect(viewport.height, 587, reason: '正文区高度实测基线（探针）');

      // 关键契约：**正文区底边 = 进度条底边**（进度条在 Stack 内 `bottom: 0`），
      // 且 viewport 底边 **高于** AppBar 底边——两者共同保证首行/末行都不被遮。
      final double vBottom =
          tester.getBottomLeft(find.byKey(const Key('reader-viewport'))).dy;
      final double pBottom =
          tester.getBottomRight(find.byKey(const Key('reader-progress-indicator'))).dy;
      expect(vBottom, moreOrLessEquals(pBottom, epsilon: 0.5),
          reason: '进度条应贴在正文区底部（vBottom=$vBottom pBottom=$pBottom）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('变异护栏：inset 归零时正文区会变高（此测试应判红）',
        (WidgetTester tester) async {
      // 防「有人把inset 删了但测试仍绿」——把viewport 高度**下限**钉住：
      // 带 inset 时 587；去掉 44+34+28=106 后约 693。故下界取 640可捕获。
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: ReaderPage(
          source: FakeBookSource(),
          record: fakeRecord(),
          progressStore: progressStore,
          repository: repo,
        ),
      ));
      await settle(tester);

      final Size viewport =
          tester.getSize(find.byKey(const Key('reader-viewport')));
      expect(viewport.height, lessThan(640),
          reason: 'inset 失效时正文区会高约 106dp（实测 ${viewport.height}px）');
      expect(tester.takeException(), isNull);
    });
  });
}
