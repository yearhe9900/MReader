// `TYP-09`：沉浸全屏与细粒度进度指示 widget 测试。
//
// 验收映射（PRD `TYP-09`，指示格式「第 12/87 章 · 43%」）：
//   ① 全屏无顶部栏——进全屏后 `AppBar` 消失（底部控制条一并隐藏，沉浸）；
//   ② 进度随滚动**实时**更新——手势**按住未抬起**时滚动（此时绝无
//     `ScrollEndNotification`），一帧后进度即变化：排除「只在滚动结束才更新」
//     的旧路径（显示值语义见 `reader_page._liveIndex` 注释）；
//   ③ 退出全屏可恢复——顶部栏 / 书名 / 控制条原样回来。
//
// 预期值人工推演（3 章 × 20 段假书，默认字号 18 / 行距 1.6）：
//   · 单段行高 = 18 × 1.6 = 28.8，段底 padding 16 → 每段 44.8；
//   · 章块 ≈ 标题块 57 + 20 × 44.8 ≈ 953；拖 150px（扣约 18px 手势阈值）→
//     offset ≈ 132 → 章内 ≈ 0.14 → 全书 = 0.14 / 3 ≈ 4%；
//   · 再拖 150px → offset ≈ 282 → 全书 ≈ 9%——两段都在第 1 章内（章高 953）。
//   故断言：首拖后 0% < p ≤ 25%，二拖后严格递增，且章序仍为 1（带宽容差）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// 从进度指示条读取「第 N/M 章 · P%」并解析。
({int chapter, int total, int percent}) _progressOf(WidgetTester tester) {
  final Text text =
      tester.widget<Text>(find.byKey(const Key('reader-progress-text')));
  final RegExpMatch? match =
      RegExp(r'^第 (\d+)/(\d+) 章 · (\d+)%$').firstMatch(text.data!);
  expect(match, isNotNull, reason: '进度指示格式应为「第 N/M 章 · X%」，实际：${text.data}');
  return (
    chapter: int.parse(match!.group(1)!),
    total: int.parse(match.group(2)!),
    percent: int.parse(match.group(3)!),
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

    testWidgets('验收①③：全屏无顶部栏（含控制条隐藏），退出全屏可恢复',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('书架书名'), findsOneWidget);
      expect(find.byType(ReaderControlBar), findsOneWidget);

      await tester.tap(find.byKey(const Key('reader-fullscreen-enter')));
      await tester.pump();

      // 验收①：全屏无顶部栏；底部控制条也隐藏（沉浸）；进度指示仍在。
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(ReaderControlBar), findsNothing);
      expect(find.text('书架书名'), findsNothing);
      expect(
        find.byKey(const Key('reader-progress-indicator')),
        findsOneWidget,
      );
      // 验收③前提：退出入口可见。
      expect(find.byKey(const Key('reader-fullscreen-exit')), findsOneWidget);

      await tester.tap(find.byKey(const Key('reader-fullscreen-exit')));
      await tester.pump();

      // 验收③：退出全屏可恢复（顶部栏 / 书名 / 控制条原样回来）。
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('书架书名'), findsOneWidget);
      expect(find.byType(ReaderControlBar), findsOneWidget);
    });

    testWidgets('验收②：进度随滚动实时更新（手势未抬起即更新）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 初始：第 1/3 章 · 0%（推演：书首，pos 回落 0.0，0/3 → 0%）。
      final ({int chapter, int total, int percent}) initial =
          _progressOf(tester);
      expect((initial.chapter, initial.total, initial.percent), (1, 3, 0));

      // 手势按住拖动（**未抬起** = 必然没有 ScrollEnd）：一帧后进度即变化。
      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(find.byType(ListView)));
      await gesture.moveBy(const Offset(0, -150));
      await tester.pump();

      final int percent1 = _progressOf(tester).percent;
      expect(percent1, greaterThan(0),
          reason: '滚动一帧后进度必须已更新（实时；此时无 ScrollEnd）');
      expect(percent1, lessThanOrEqualTo(25),
          reason: '推演：约 132px / 章高约 953 → 全书约 4%');

      await gesture.moveBy(const Offset(0, -150));
      await tester.pump();
      final ({int chapter, int total, int percent}) second = _progressOf(tester);
      expect(second.percent, greaterThan(percent1),
          reason: '继续滚动进度继续涨（随滚动实时更新）');
      expect(second.chapter, 1,
          reason: '推演：约 282px 仍在第 1 章内（章高约 953）');
      expect(second.total, 3);

      await gesture.up();
      await settle(tester);
    });
  });
}
