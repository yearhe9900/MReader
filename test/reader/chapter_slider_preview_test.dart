// §2.122 拖动章节滑条的气泡文案（宿主 `_chapterPreviewLabel` 口径）：
//
//   ① 目标章**页表已就绪** → 「章名 · 落地页/本章总页页」——落地恒为章
//      起点（`_goToChapter` 跳 `pos: 0`）⇒ 分子恒 1，分母 = 该章总页数；
//   ② 目标章在**分页窗口外**（未分页）→ 回落「章名 · 全书百分比」
//      （诚实降级，不显示 0/0，也不显示拖动中的伪精确值）。
//
// harness：3 章假书，初始窗口 = 中心 ±1 ⇒ `[0, 1]`（`_computeWindow`）
// ⇒ 拖到第 2 章（index 1，窗口内）走 ①、拖到第 3 章（index 2，窗口外）
// 走 ②——两条路径同一份代码都钉住。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// 读气泡里的「章节名 · 进度」文案（拖动中才在树上）。
String _bubbleText(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('reader-chapter-preview')),
        matching: find.byType(Text),
      ),
    )
    .data!;

/// 按住滑条并拖到归一化位置 [t]（0 = 最左 / 1 = 最右）；保持按住不松手。
Future<TestGesture> _dragTo(WidgetTester tester, double t) async {
  final Finder slider = find.byKey(const Key('reader-control-progress'));
  final Rect rect = tester.getRect(slider);
  final TestGesture gesture =
      await tester.startGesture(rect.centerLeft + const Offset(8, 0));
  await gesture.moveTo(Offset(rect.left + rect.width * t, rect.center.dy));
  await tester.pump();
  return gesture;
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('章节滑条气泡：落地页读数', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_bubble_');
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

    testWidgets('窗口内目标章 → 「章名 · 1/本章总页页」', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      await showChrome(tester);

      // t = 0.5 ⇒ 吸附到 index 1（`round(0.5 × (3−1))`），窗口 [0,1] 内。
      final TestGesture gesture = await _dragTo(tester, 0.5);
      final String text = _bubbleText(tester);
      expect(text, matches(RegExp(r'^第二章 · 1/\d+页$')),
          reason: '窗口内目标章应显示落地页读数（分子恒 1），实际：$text');

      await gesture.up();
      await tester.pump();
    });

    testWidgets('窗口外目标章（未分页）→ 回落全书百分比', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      await showChrome(tester);

      // t ≈ 0.95 ⇒ 吸附到 index 2（末章）；初始窗口 [0,1] 不含它。
      final TestGesture gesture = await _dragTo(tester, 0.95);
      final String text = _bubbleText(tester);
      expect(text, matches(RegExp(r'^第三章 · \d+%$')),
          reason: '页表未就绪应诚实回落百分比（不显示 0/0），实际：$text');
      expect(text, isNot(contains('页')),
          reason: '回落态不得掺页码读数');

      await gesture.up();
      await tester.pump();
    });
  });
}
