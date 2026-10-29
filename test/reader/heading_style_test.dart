// TYP-04 章标题样式（改版口径：「将章节名左对齐，加粗字体，且不需要横线分割；
// 每章节之间添加空行隔离」——改「标题居中」旧口径）。
//
// 分页路径（`_headingWidget`）渲染结构：
//   Column[ SizedBox(_kHeadingGapTop=24)、Text(左对齐+加粗)、 SizedBox(_kHeadingGapBottom=12) ]
//
//   · 章间空行隔离 = 每个标题块**顶部** 24 空档（分页长卷里章与章恒隔一个空行量级）；
//   · 题文呼吸 12 保留（横线删了，题-文间距不塌）；
//   · 测量与渲染**同源**：`_headingHeightOf` 与 `_headingWidget` 共用文本 / 样式 /
//     缩放，标题占高 = 文本 24 + 24 + 12 = 60.0。
//
// ListView 路径（`_buildChapterItem`，`!_pagedMode` 旧连续滚动）同款改动
// （Text 左对齐加粗、删 Divider、题文呼吸 12）；其占位判据只看 `content == null`，
// 空段章天然渲染「标题 + 0 段」，无「载入中」问题（`empty_chapter_test` 钉 paged 路径）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_prefs_store.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout();

  group('TYP-04 章标题样式（2026-10-09 改版）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late ReadingPrefsStore prefsStore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_heading_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      prefsStore = ReadingPrefsStore(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[20, 20, 20]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
            readingPrefsStore: prefsStore,
          ),
        );

    PagedScroller scroller(WidgetTester tester) => tester.widget<PagedScroller>(
        find.byType(PagedScroller, skipOffstage: false));

    testWidgets('分页路径：左对齐、加粗、无横线，章间空行隔离',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      final PagedChapterView view = scroller(tester).chapters.first;

      // 渲染结构：顶部空档 24（章间隔离）→ 标题 → 题文呼吸 12。
      final Widget? heading = view.heading;
      expect(heading, isA<Column>(), reason: '标题块是 Column 三段结构');
      final List<Widget> children = (heading! as Column).children;
      expect(children, hasLength(3),
          reason: '改前 4 件（Text/6/Divider/12）；横线与题-文 6 空档已删');

      expect(children[0], isA<SizedBox>());
      expect((children[0] as SizedBox).height, 24.0,
          reason: '章间空行隔离：每个标题块顶部 24 空档');

      expect(children[1], isA<Text>());
      final Text title = children[1] as Text;
      expect(title.textAlign, TextAlign.left, reason: '左对齐（改「居中」旧口径）');
      expect(title.style?.fontWeight, FontWeight.bold, reason: '加粗');

      expect(children[2], isA<SizedBox>());
      expect((children[2] as SizedBox).height, 12.0,
          reason: '题文呼吸（横线删了，题-文间距不塌）');

      // 无横线：分页长卷里不许再出现任何 Divider。
      expect(
        find.descendant(
          of: find.byType(PagedScroller, skipOffstage: false),
          matching: find.byType(Divider),
        ),
        findsNothing,
        reason: '「不需要横线分割」——改前每个章标题下有一条 Divider',
      );

      // 测量与渲染同源：标题占高 = 文本 24 + 24 + 12 = 60.0。
      expect(view.headingHeight, 60.0);

      await closeBook(tester);
    });
  });
}
