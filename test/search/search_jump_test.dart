// `CNT-06` 验收②：搜索跳转与关键词高亮端到端。
//
// 真按钮链：`reader-search` → 面板输入提交 → 点命中行 → 弹层 pop →
// 跳到目标章 + 正文关键词高亮（`InlineParagraph.highlightQuery`）。
//
// 预期值人工推演（防假绿）——`FakeBookSource` 段落模板 `'第${章序}章正文$p'`：
//   章 2（index 1）段落 = '第2章正文1'..'第2章正文20'，段 1~9 各 **6** 字符、
//   段 10~20 各 **7** 字符（中日韩统一表意文字按 UTF-16 code unit 各计 1）。
//   段 3（index 2）= '第2章正文3'：第(0) 2(1) 章(2) 正(3) 文(4) 3(5)，
//   '正文' at 3 → 命中 offset = 段0(6) + 段1(6) + 3 = **15**；
//   换算回段落下标：15 < 段0 末 6？否 → < 段1 末 12？否 → < 段2 末 18？是 → **paraIndex 2**。
//
// ⚠️ FakeAsync 陷阱同 `reader_page_test.dart`：搜索走本 isolate 流式路径
// （假源 `searchSpec => null`），禁用后台 isolate（见 search_fakes.dart 头注）。
// 装具（假源 / settle / closeBook）见 `reader_harness.dart`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/typography/typeset.dart';

import '../reader/reader_harness.dart';
import '../test_config.dart';
import 'search_fakes.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  /// 收集 span 树里带 [kSearchHighlightColor] 背景的高亮片段文本。
  List<String> highlightedFragments(WidgetTester tester) {
    final List<String> found = <String>[];
    for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
      final InlineSpan? span = text.textSpan;
      if (span == null) continue;
      span.visitChildren((InlineSpan s) {
        if (s is TextSpan && s.style?.backgroundColor == kSearchHighlightColor) {
          found.add(s.text ?? '');
        }
        return true;
      });
    }
    return found;
  }

  group('CNT-06 搜索跳转高亮', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_search_ui_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildApp(BookSource source) => MaterialApp(
          home: ReaderPage(
            source: source,
            record: fakeRecord(),
            progressStore: progressStore,
            repository: repo,
          ),
        );

    testWidgets('验收②：点命中 → 跳到目标章 + 关键词高亮', (WidgetTester tester) async {
      // 推演见文件头：offset 15 → 章 2（index 1）段 3（index 2）。
      final StubSearchSource source = StubSearchSource(events: <SearchEvent>[
        SearchEvent.hit(fakeHit(
          chapterIndex: 1,
          chapterTitle: '第二章',
          offset: 15,
          context: '第2章正文3',
        )),
        const SearchEvent.progress(1.0),
      ]);
      await tester.pumpWidget(buildApp(source));
      await settle(tester);

      // 真按钮链：搜索按钮 → 面板 → 提交 → 点第一条命中。
      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-input')), '正文');
      await tester.tap(find.byKey(const Key('search-submit')));
      await settle(tester, rounds: 10);
      await tester.tap(find.byKey(const Key('search-hit-0')));
      await tester.pumpAndSettle(); // 弹层 pop。
      await settle(tester); // 跳转：loadFirstBatch + 「估算 + 校正」收敛。
      await tester.pumpAndSettle();

      // ⚠️ 跳转后 chrome 必须自动收起（`_exitChrome`）：chrome 是覆盖层，顶栏压在
      // 正文上沿，而跳转落位一律「目标在页顶」——顶栏若还开着，目标整行都压在它
      // 下面，两态目标矩形完全相同，差别只在可命中性（开 0 / 收 1）。
      expect(find.byType(AppBar), findsNothing,
          reason: '从弹层跳转后应收起 chrome，否则页顶的目标被顶栏压住');

      // ⚠️ 视口语义一律用 hitTestable：分页模式下 `_window` 把三章页面整棵构建在
      // 树上，`find.text` 的「在树上」不等于「在视口内」（视口外页面被裁剪、不参与
      // 命中）；章标题只作「目标章已载入」的存在性断言——段落级对齐会把章题滚到
      // 视口上方，本就不该要求它在视口内。
      expect(find.textContaining('第2章'), findsWidgets);
      expect(find.text('第一章').hitTestable(), findsNothing);
      expect(find.textContaining('第2章正文3').hitTestable(), findsWidgets);

      // 关键词高亮：视口内正文的 '正文' 片段全部带高亮底色。
      // （highlightQuery 对整章生效——所有可见段落里的 '正文' 都高亮。）
      final List<String> highlights = highlightedFragments(tester);
      expect(highlights, isNotEmpty);
      expect(
        highlights.every((String t) => t == '正文'),
        isTrue,
        reason: '高亮片段应恰为关键词「正文」，实得 $highlights',
      );
    });

    testWidgets('图片页命中：纯跳章（CBZ / PDF 路径，无段落换算）',
        (WidgetTester tester) async {
      // 3 章全图片页；命中第 3 章（index 2），offset 无段落可换算 → 纯跳章。
      final StubImagePageSource source =
          StubImagePageSource(events: <SearchEvent>[
        SearchEvent.hit(fakeHit(
          chapterIndex: 2,
          chapterTitle: '第三章',
          offset: 0,
          context: '',
        )),
        const SearchEvent.progress(1.0),
      ]);
      await tester.pumpWidget(buildApp(source));
      await settle(tester);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-input')), '图');
      await tester.tap(find.byKey(const Key('search-submit')));
      await settle(tester, rounds: 10);
      await tester.tap(find.byKey(const Key('search-hit-0')));
      await tester.pumpAndSettle();
      await settle(tester);
      await tester.pumpAndSettle();

      // 落到第 3 章的图片页（key = `reader-image-page:<src>`），不崩、不错跳。
      expect(
        find.byKey(const Key('reader-image-page:img-2.png')),
        findsOneWidget,
      );
    });
  });
}
