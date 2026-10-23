// 「搜索页进书剧烈闪动」护栏（2026-10-22 真机定案）。
//
// ## 机制
//
// 搜索页点书开读时**输入法还在收起途中**：阅读页 `Scaffold` 默认
// `resizeToAvoidBottomInset: true` ⇒ body 随键盘收起动画**逐帧变高** ⇒
// `_syncPageConfig` 的 `pageHeight` 每帧变 ⇒ 整章反复重排 = 剧烈闪动。
//
// ## 两条护栏
//
// ① 结构钉：阅读页 `Scaffold.resizeToAvoidBottomInset == false`（键盘不改
//    正文排版区，与 `extendBody*` 同属 `TYP-09`「正文一像素不动」契约）；
// ② 行为钉：注入 `viewInsets.bottom`（模拟键盘）后正文排版区**尺寸不变**。
// ③ 搜索页点结果先收键盘（`unfocus`），输入法不与开书转场叠加。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';
import 'package:mreader/ui/shelf_search_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('键盘不改正文排版区（搜索页进书剧烈闪动护栏）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_kb_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildApp({EdgeInsets viewInsets = EdgeInsets.zero}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(viewInsets: viewInsets),
            child: ReaderPage(
              source: FakeBookSource(),
              record: fakeRecord(),
              progressStore: progressStore,
              repository: repo,
            ),
          ),
        );

    testWidgets('结构钉：阅读页 Scaffold 键盘免疫', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      final Scaffold scaffold =
          tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.resizeToAvoidBottomInset,
        isFalse,
        reason: '键盘收起动画会让 body 逐帧变高 → 逐帧重排 = 剧烈闪动；'
            '正文区无输入框，应与 extendBody* 同款钉死',
      );
    });

    testWidgets('行为钉：注入键盘 inset 后正文排版区尺寸不变',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      final Size before = tester.getSize(find.byType(PagedScroller));

      await tester.pumpWidget(
          buildApp(viewInsets: const EdgeInsets.only(bottom: 300)));
      await settle(tester);
      final Size after = tester.getSize(find.byType(PagedScroller));

      expect(after, before,
          reason: '键盘 inset 不得改变正文排版区（否则开书转场期逐帧重排闪动）');
    });

    testWidgets('搜索页点结果先收键盘', (WidgetTester tester) async {
      BookRecord? opened;
      await tester.pumpWidget(MaterialApp(
        home: ShelfSearchPage(
          books: <BookRecord>[fakeRecord()],
          coverStore: FileCoverStore(paths),
          themeMode: MiThemeMode.light,
          onOpenBook: (BookRecord r) => opened = r,
          onBookActions: (BookRecord r) async {},
        ),
      ));
      await tester.pump();
      await tester.pump();

      // 唤起键盘并输入查询（空查询不出结果）。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.binding.focusManager.primaryFocus?.hasPrimaryFocus, isTrue,
          reason: '前置条件：输入框应处于聚焦态');
      // 前置：打字期间搜索页照常随键盘适配（结果区可见性）。
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first)
            .resizeToAvoidBottomInset,
        isTrue,
        reason: '打字期间应保持键盘适配；冻结只发生在点书那一刻',
      );
      await tester.enterText(find.byType(TextField), '书架');
      await tester.pump();
      expect(find.text(fakeRecord().title), findsWidgets,
          reason: '前置条件：查询后应出现结果书卡');

      // 点结果书卡（书名命中；书卡内书名可能多处渲染，点首个）。
      await tester.tap(find.text(fakeRecord().title).first);
      await tester.pump();

      expect(opened, isNotNull, reason: '点结果应触发开书回调');
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.focusNode?.hasPrimaryFocus ?? false,
        isFalse,
        reason: '点结果应先收键盘（输入框失焦），输入法收起不得与开书转场叠加',
      );
      // 点书后冻结布局：键盘收起动画不得逐帧改写 body 高度（背景重排=掉帧）。
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first)
            .resizeToAvoidBottomInset,
        isFalse,
        reason: '点书开读后应冻结键盘响应，收起动画期间布局稳定',
      );
    });
  });
}
