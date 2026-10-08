// `TYP-09`：沉浸全屏与细粒度进度指示 widget 测试。
//
// ## 口径变更（2026-10-08，负责人拍板）
// ① 默认即沉浸全屏：`_fullscreen` 初值 `true`，顶栏与底部控制条**默认不在树上**；
//    顶栏「进入全屏」按钮（`reader-fullscreen-enter`）与全屏时右上角「退出全屏」
//    浮层按钮（`reader-fullscreen-exit`）**均已移除**——切换唯一入口是点正文
//    （`reader-chrome-toggle`）。
// ② 底部读数格式从「第 N/M 章 · X%」改为**左章节标题 + 右「页/总页 百分比」**
//    （百分比一位小数）：`第一章` / `1/2 0.0%`。
//
// 验收映射（PRD `TYP-09`，2026-10-08 改口径后的三条）：
//   ① 进阅读页即全屏且全屏切换按钮不存在；点正文可唤出与收起顶栏 / 控制条
//      ——默认态无 `AppBar`、无 `ReaderControlBar`、两个全屏按钮 key 皆 `findsNothing`，
//      点 `reader-chrome-toggle` 出现顶栏 + 书名 + 控制条，再点收回；
//   ② 读数随滚动 / 翻页**实时**更新——手势**按住未抬起**时滚动（此时绝无
//      `ScrollEndNotification`），一帧后读数即变化：排除「只在滚动结束才更新」
//      的旧路径（显示值语义见 `reader_page._liveIndex` 注释）；
//   ③ 读数含当前章标题、当前章 `n/N` 与全书百分比——右读数格式被正则
//      `^(\d+)/(\d+) (\d+\.\d)%$` **钉死**（掉页读数 / 回退整数百分比都会判红），
//      并单独验证长距离滚动后左读数换成下一章标题。
//
// 预期值人工推演（3 章 × 20 段假书，默认字号 18 / 行距 1.6）：
//   · 单段行高 = 18 × 1.6 = 28.8，段底 padding 16 → 每段 44.8；
//   · 章块 ≈ 标题块 57 + 20 × 44.8 ≈ 953；拖 150px（扣约 18px 手势阈值）→
//     offset ≈ 132 → 章内 ≈ 0.14 → 全书 = 0.14 / 3 ≈ 4%。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// 从底部常驻进度指示器读取「左章标题 + 右页/总页 + 百分比」。
///
/// 右读数格式被正则**钉死**：`页/总页 百分比`，百分比必须带一位小数——
/// 格式回退（如改回整数或丢掉页读数）会在这里判红。
({String chapter, int page, int pages, double percent}) _progressOf(
    WidgetTester tester) {
  final String chapter = tester
      .widget<Text>(find.byKey(const Key('reader-progress-chapter')))
      .data!;
  final String data =
      tester.widget<Text>(find.byKey(const Key('reader-progress-text'))).data!;
  final RegExpMatch? match =
      RegExp(r'^(\d+)/(\d+) (\d+\.\d)%$').firstMatch(data);
  expect(match, isNotNull,
      reason: '底部读数格式应为「页/总页 百分比(一位小数)」，实际：$data');
  return (
    chapter: chapter,
    page: int.parse(match!.group(1)!),
    pages: int.parse(match.group(2)!),
    percent: double.parse(match.group(3)!),
  );
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('TYP-09 全屏与进度指示', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_full_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: repo,
          ),
        );

    testWidgets('验收①：默认即沉浸全屏；点正文唤出顶栏与控制条，再点收起',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 验收①：默认态没有任何 chrome——顶栏与控制条都不在树上，只有常驻进度指示。
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(ReaderControlBar), findsNothing);
      expect(find.text('书架书名'), findsNothing);
      expect(
        find.byKey(const Key('reader-progress-indicator')),
        findsOneWidget,
        reason: 'chrome 全隐藏时进度指示必须仍在（TYP-09 验收①）',
      );
      // 两个全屏切换按钮都已移除（负责人要求）。
      expect(find.byKey(const Key('reader-fullscreen-enter')), findsNothing);
      expect(find.byKey(const Key('reader-fullscreen-exit')), findsNothing);

      // 验收①：点正文唤出 chrome（正文层入口）。
      await tester.tap(find.byKey(const Key('reader-chrome-toggle')));
      await tester.pump();

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('书架书名'), findsOneWidget);
      expect(find.byType(ReaderControlBar), findsOneWidget);

      // 再点一次收回——chrome 是开关，不是单向退出。
      await tester.tap(find.byKey(const Key('reader-chrome-toggle')));
      await tester.pump();

      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(ReaderControlBar), findsNothing);
      expect(find.text('书架书名'), findsNothing);
    });

    testWidgets('验收②：进度随滚动实时更新（手势未抬起即更新）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 初始：第一章、页 1、百分比 0.0（书首，pos 回落 0.0 → 0/3 → 0.0%）。
      final ({
        String chapter,
        int page,
        int pages,
        double percent
      }) initial = _progressOf(tester);
      expect(initial.chapter, '第一章');
      expect(initial.page, 1, reason: '书首应落在本章第 1 页');
      expect(initial.pages, greaterThanOrEqualTo(1));
      expect(initial.percent, 0.0);

      // ⚠️ 手势的**第一次** `moveBy` 只用来「确立拖动原点」，实测**不产生任何滚动**
      // （探针实证：首移 150px 后 offset 仍为 43 不变，第二次同量移动才真的滚 150px
      // ——`DragGestureRecognizer` 接受手势时把原点记在首移后的位置上）。
      // 所以先做一次热身移动，再取基线：否则「进度是否随滚动变化」根本没被检验
      // （改前那条 `percent1 > 0` 就是被初始落位 offset=43 自己撑起来的，拖动
      // 一步都没生效——**形式上在测实时更新，实际测的是初始值非零**）。
      final TestGesture gesture = await tester
          .startGesture(tester.getCenter(find.byType(PagedScroller)));
      await gesture.moveBy(const Offset(0, -150));
      await tester.pump();

      final double before = _progressOf(tester).percent;

      // 第二次移动**手势仍按住**（必然没有 ScrollEnd）：一帧后进度即变化。
      await gesture.moveBy(const Offset(0, -150));
      await tester.pump();

      final ({
        String chapter,
        int page,
        int pages,
        double percent
      }) scrolled = _progressOf(tester);
      expect(scrolled.percent, greaterThan(before),
          reason: '滚动一帧后进度必须已更新（实时；此时无 ScrollEnd）');
      expect(scrolled.percent, greaterThan(0.0),
          reason: '真实滚动 150px 后进度必须为正');
      expect(scrolled.percent, lessThanOrEqualTo(25.0),
          reason: '推演：约 150px / 章高约 927 → 全书约 5%');
      expect(scrolled.chapter, '第一章',
          reason: '推演：约 193px 仍在第 1 章内（章高约 927）');
      expect(scrolled.page, lessThanOrEqualTo(scrolled.pages),
          reason: '页码必须落在 1..本章总页数 内');

      await gesture.up();
      await settle(tester);
    });

    testWidgets('验收③：读数格式「章标题 + 页/总页 + 百分比(一位小数)」；随章推进换标题',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      expect(_progressOf(tester).chapter, '第一章');

      // 章块 ≈ 953（推演见文件头）；拖足 ~1500px 保证越过章边界。
      final TestGesture gesture = await tester
          .startGesture(tester.getCenter(find.byType(PagedScroller)));
      for (int i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, -150));
        await tester.pump();
      }
      expect(_progressOf(tester).chapter, '第二章',
          reason: '滚过约 1500px 后应进入第 2 章（章高约 953）');
      expect(_progressOf(tester).percent, greaterThan(25.0),
          reason: '推演：约 1320px / 全书约 2860px ≈ 46%');

      await gesture.up();
      await settle(tester);
    });
  });
}
