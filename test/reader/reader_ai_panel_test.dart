// 阅读页 AI 面板（`AI-04`~`AI-07` 分组收纳入口）的 widget 测试。
//
// 改前 4 个 AI 入口平铺在 AppBar：搜索/书签/前情回顾/AI 摘要/AI 问答/人物与设定/
// 外观/目录/全屏共 9 个 48dp 按钮 = 432dp > 手机屏宽（393dp），书名与副标题被挤没。
// 收进面板后 AppBar 只剩 6 个按钮；本测试钉住「面板四行都在、回调一一对应、
// 关闭后回到阅读页」，确保收纳没有丢功能。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_ai_panel.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('阅读页 AI 面板', () {
    testWidgets('四行入口齐全，点任一行都关闭面板并回调',
        (WidgetTester tester) async {
      final List<String> tapped = <String>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => showReaderAiPanel(
                  context: context,
                  onSummary: () => tapped.add('summary'),
                  onAsk: () => tapped.add('ask'),
                  onEntities: () => tapped.add('entities'),
                  onRecap: () => tapped.add('recap'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 面板标题 + 四行（文案与改前 tooltip 一致）。
      expect(find.text('AI 助手'), findsOneWidget);
      for (final String label in <String>[
        'AI 摘要',
        'AI 问答',
        '人物与设定',
        '前情回顾',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺入口：$label');
      }

      // Key 与改前 AppBar 一致（便于既有查找口径延续）。
      expect(find.byKey(const Key('reader-summary')), findsOneWidget);
      expect(find.byKey(const Key('reader-ask')), findsOneWidget);
      expect(find.byKey(const Key('reader-entities')), findsOneWidget);
      expect(find.byKey(const Key('reader-recap')), findsOneWidget);

      // 点「AI 问答」→ 面板关闭 + 回调触发。
      await tester.tap(find.byKey(const Key('reader-ask')));
      await tester.pumpAndSettle();
      expect(tapped, <String>['ask']);
      expect(find.text('AI 助手'), findsNothing);
    });

    testWidgets('onRecap 为 null 时不渲染「前情回顾」行（AI-05 ② 会话内一次性）',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => showReaderAiPanel(
                  context: context,
                  onSummary: () {},
                  onAsk: () {},
                  onEntities: () {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reader-recap')), findsNothing);
      expect(find.text('前情回顾'), findsNothing);
      // 其余三行不受影响。
      expect(find.byKey(const Key('reader-summary')), findsOneWidget);
      expect(find.byKey(const Key('reader-ask')), findsOneWidget);
      expect(find.byKey(const Key('reader-entities')), findsOneWidget);
    });
  });

  group('阅读页顶栏分组（AppBar）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_appbar_');
      paths = TestAppPaths(tempDir);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    testWidgets('顶栏按钮收纳到 ≤ 6 个（改前 9 个挤掉书名），书名可见',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: ReaderPage(
          source: FakeBookSource(),
          record: fakeRecord(),
          progressStore: ProgressStore(paths),
          repository: repo,
        ),
      ));
      await settle(tester);

      final AppBar bar = tester.widget<AppBar>(find.byType(AppBar));
      // 顶栏动作数上限：搜索/书签/AI/外观/目录/全屏 = 6。
      expect(bar.actions!.length, lessThanOrEqualTo(6),
          reason: '顶栏动作过多会把标题挤没（9 × 48dp > 393dp 屏宽）');

      // 书名与副标题都还在（改前被挤成 0 宽）。
      expect(find.text('书架书名'), findsOneWidget);
      expect(find.textContaining('第1章'), findsWidgets);

      // 关键入口 Key 全在场。
      for (final String key in <String>[
        'reader-search',
        'reader-bookmarks',
        'reader-appearance',
        'reader-toc',
        'reader-fullscreen-enter',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: '缺入口 $key');
      }
    });
  });
}