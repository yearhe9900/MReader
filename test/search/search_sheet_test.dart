// `CNT-06`：全书搜索面板（① 命中数与列表行数同源对表 ② 点行跳转 + 关键词高亮
// ③ 搜索中可取消且 UI 不卡死）。
//
// 面板侧收口在「点行 → onJump(hit, query)」（跳转与正文高亮端到端见
// `search_jump_test.dart`，列表片段高亮本文件覆盖）；取消下传 `CancelToken`
// （协议级取消，会话层见 `search_session_test.dart`）。
//
// ⚠️ 假源一律走本 isolate 流式路径（`searchSpec => null` + `localSource`），**禁用
// 后台 isolate**（FakeAsync 不排空 isolate 消息会挂死，见 search_fakes.dart）。
// 预期值人工推演后写死（防假绿）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/task/search_session.dart';
import 'package:mreader/typography/typeset.dart';
import 'package:mreader/ui/search_sheet.dart';

import '../reader/reader_harness.dart';
import '../test_config.dart';
import 'search_fakes.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  /// 把 [SearchSheet] 摆进最小 app（TextField / 主题依赖 MaterialApp）。
  Widget wrap(SearchSheet sheet) => MaterialApp(
        home: Scaffold(body: sheet),
      );

  /// 以 [source] 起本 isolate 流式会话（测试禁用后台 isolate 路径）。
  SearchSession Function(String) starter(FakeBookSource source) =>
      (String query) =>
          SearchSession.start(query: query, localSource: source);

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

  group('CNT-06 搜索面板', () {
    testWidgets('验收①：命中列表「章节名 + 上下文片段」，计数与列表对表',
        (WidgetTester tester) async {
      // 2 命中 + 2 进度交错（与 search_session_test 的回放形状一致）。
      final StubSearchSource source = StubSearchSource(events: <SearchEvent>[
        SearchEvent.hit(fakeHit(
          chapterIndex: 0,
          chapterTitle: '第一章',
          offset: 0,
          context: '开头 alpha 段落。',
        )),
        const SearchEvent.progress(0.5),
        SearchEvent.hit(fakeHit(
          chapterIndex: 1,
          chapterTitle: '第二章',
          offset: 6,
          context: '第二处 alpha 段落。',
        )),
        const SearchEvent.progress(1.0),
      ]);
      SearchHit? jumped;
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {
          jumped = hit;
        },
      )));
      await tester.enterText(find.byKey(const Key('search-input')), 'alpha');
      await tester.tap(find.byKey(const Key('search-submit')));
      await settle(tester, rounds: 10);

      final Finder sheet = find.byType(SearchSheet);
      expect(
        find.descendant(of: sheet, matching: find.byKey(const Key('search-hit-0'))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.byKey(const Key('search-hit-1'))),
        findsOneWidget,
      );
      // 章节名（title）。
      expect(find.descendant(of: sheet, matching: find.text('第一章')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('第二章')), findsOneWidget);
      // 上下文片段（subtitle Text.rich，findRichText 才可见）。
      expect(
        find.descendant(
          of: sheet,
          matching: find.textContaining('开头 alpha 段落。', findRichText: true),
        ),
        findsOneWidget,
      );
      // 验收①计数对表：「共命中 2 处」= 事件流里的 2 条 hit = 2 行。
      expect(find.text('共命中 2 处'), findsOneWidget);
      // 片段内命中词高亮（与正文同款 highlightSpans 口径）。
      expect(highlightedFragments(tester), <String>['alpha', 'alpha']);
      // 未点行时 onJump 不触发。
      expect(jumped, isNull);
    });

    testWidgets('验收③：搜索中显示进度与实时计数，取消下传 CancelToken',
        (WidgetTester tester) async {
      final ControlledSearchSource source = ControlledSearchSource();
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {},
      )));
      await tester.enterText(find.byKey(const Key('search-input')), 'alpha');
      await tester.tap(find.byKey(const Key('search-submit')));
      await tester.pump();

      // 手动推 1 条命中 + 1 条进度（流未关闭 = 仍在搜索）。
      source.controller.add(SearchEvent.hit(fakeHit(
        chapterIndex: 0,
        chapterTitle: '第一章',
        offset: 0,
        context: 'alpha 在此。',
      )));
      source.controller.add(const SearchEvent.progress(0.5));
      await settle(tester, rounds: 6);

      final Finder sheet = find.byType(SearchSheet);
      expect(find.descendant(of: sheet, matching: find.byKey(const Key('search-progress'))),
          findsOneWidget);
      expect(find.text('已命中 1 处'), findsOneWidget);
      expect(find.byKey(const Key('search-cancel')), findsOneWidget);

      // 取消：终态定格（保留已收命中），令牌置位（协议级取消下传）。
      await tester.tap(find.byKey(const Key('search-cancel')));
      await tester.pump();
      expect(find.byKey(const Key('search-cancel')), findsNothing);
      expect(find.byKey(const Key('search-progress')), findsNothing);
      expect(find.text('共命中 1 处'), findsOneWidget);
      expect(source.cancels, hasLength(1));
      expect(source.cancels.single.isCancelled, isTrue);
      unawaited(source.controller.close());
    });

    testWidgets('验收②（面板侧）：点命中行 → onJump 收到 hit + 搜索词',
        (WidgetTester tester) async {
      final StubSearchSource source = StubSearchSource(events: <SearchEvent>[
        SearchEvent.hit(fakeHit(
          chapterIndex: 1,
          chapterTitle: '第二章',
          offset: 15,
          context: '第2章正文3',
        )),
        const SearchEvent.progress(1.0),
      ]);
      SearchHit? jumped;
      String? jumpedQuery;
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {
          jumped = hit;
          jumpedQuery = query;
        },
      )));
      await tester.enterText(find.byKey(const Key('search-input')), '正文');
      await tester.tap(find.byKey(const Key('search-submit')));
      await settle(tester, rounds: 10);
      await tester.tap(find.byKey(const Key('search-hit-0')));
      await tester.pump();

      expect(jumped, isNotNull);
      expect(jumped!.chapterIndex, 1);
      expect(jumped!.offset, 15);
      expect(jumped!.context, '第2章正文3');
      expect(jumpedQuery, '正文');
    });

    testWidgets('空词提交不发起搜索', (WidgetTester tester) async {
      final StubSearchSource source = StubSearchSource();
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {},
      )));
      // 不输入直接点搜索按钮。
      await tester.tap(find.byKey(const Key('search-submit')));
      await tester.pump();
      expect(source.searchCalls, 0);
      expect(find.text('输入关键词搜索全书。'), findsOneWidget);
    });

    testWidgets('重复提交：旧会话被取消，新会话接管', (WidgetTester tester) async {
      final ControlledSearchSource source = ControlledSearchSource();
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {},
      )));
      await tester.enterText(find.byKey(const Key('search-input')), 'alpha');
      await tester.tap(find.byKey(const Key('search-submit')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('search-input')), 'beta');
      await tester.tap(find.byKey(const Key('search-submit')));
      await tester.pump();

      expect(source.searchCalls, 2);
      expect(source.cancels, hasLength(2));
      expect(source.cancels[0].isCancelled, isTrue, reason: '旧会话应被取消');
      expect(source.cancels[1].isCancelled, isFalse, reason: '新会话仍在搜索');
      unawaited(source.controller.close());
    });

    testWidgets('流错误：显示错误文案（RD-05 唯一来源口径）',
        (WidgetTester tester) async {
      final MReaderFormatException error =
          const MReaderFormatException(FormatErrorCode.corruptFile);
      final StubSearchSource source = StubSearchSource(error: error);
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {},
      )));
      await tester.enterText(find.byKey(const Key('search-input')), 'alpha');
      await tester.tap(find.byKey(const Key('search-submit')));
      await settle(tester, rounds: 10);

      // 格式错误文案逐字取 kFormatErrorMessages（不自拼字符串）。
      expect(find.text(error.message), findsOneWidget);
      expect(find.byKey(const Key('search-cancel')), findsNothing);
    });

    testWidgets('dispose 时仍在搜索 → 取消（不留后台会话）',
        (WidgetTester tester) async {
      final ControlledSearchSource source = ControlledSearchSource();
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {},
      )));
      await tester.enterText(find.byKey(const Key('search-input')), 'alpha');
      await tester.tap(find.byKey(const Key('search-submit')));
      await tester.pump();
      expect(source.cancels, hasLength(1));

      // 拆树（换异类 widget）→ dispose 链路应取消会话。
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(source.cancels.single.isCancelled, isTrue);
      unawaited(source.controller.close());
    });

    testWidgets('零命中：完成提示 + 「共命中 0 处」', (WidgetTester tester) async {
      final StubSearchSource source = StubSearchSource(
        events: <SearchEvent>[const SearchEvent.progress(1.0)],
      );
      await tester.pumpWidget(wrap(SearchSheet(
        startSearch: starter(source),
        onJump: (SearchHit hit, String query) {},
      )));
      await tester.enterText(find.byKey(const Key('search-input')), 'alpha');
      await tester.tap(find.byKey(const Key('search-submit')));
      await settle(tester, rounds: 10);

      expect(find.text('没有找到「alpha」。'), findsOneWidget);
      expect(find.text('共命中 0 处'), findsOneWidget);
    });
  });
}
