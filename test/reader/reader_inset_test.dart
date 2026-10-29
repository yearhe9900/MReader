// 阅读页正文**不被常驻进度条遮挡**的布局契约。
//
// 归因（读 Flutter 源码核对后）：
//   · 「首行被 AppBar 压住」**不成立**——`Scaffold` 给 body 的 MediaQuery 做了
//     `removePadding(removeTop: appBar != null)`、body 放在 AppBar 之下，
//     正文区里 `mq.padding.top` 恒为 0（首行被切的真因在落位，见
//     `PagedScrollerState.offsetFor` 的「为什么按行顶」）。
//   · 「末行被进度条压住」**成立**：预留若加在正文 Stack **外面**，而指示条在
//     Stack **里面** `bottom: 0`，两者同步上移照旧重叠、还在控制条上方白留 28dp。
//
// 本测试钉住三件事：正文排版区确实让开了指示条；正文区高 = 分页预算 `usableHeight`；
// **唤出 / 收起 chrome 不改变正文排版区**（`TYP-09` 契约）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout();

  group('阅读页正文避让常驻进度条', () {
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

    /// 刘海机：顶部 44（状态栏）、底部 34（手势条），屏高 852。
    Future<void> pumpPhone(WidgetTester tester) async {
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
    }

    testWidgets('全屏态视口几何：让开状态栏、视口 = 整个正文区，指示条贴屏幕底边',
        (WidgetTester tester) async {
      await pumpPhone(tester);

      // 几何基线（探针实测 393×852，top44/bottom34，**默认沉浸全屏**）：
      //   viewport      top=44  bottom=852 h=808（顶让开 44 状态栏）
      //   content-area  top=44  bottom=790 h=746（= viewport − 62 让位）
      //   indicator     top=792 bottom=852 h=60（26 内容 + 34 导航条让位）
      //   ⇒ content.bottom(790) ≤ indicator.top(792)，两者不重叠。
      // 让位 = 28dp 指示条 + 34 手势条 = 62：`AppBar` 不在树上、`extendBody*` 让
      // body 从 y=0 起画，顶部让位由**外层**系统 inset 的 `padding.top` 承担，底部
      // 34 由外层 `systemMq.padding.bottom` 显式交给正文 `reserve` 与读数行（与 chrome 状态无关）。
      final Rect viewport = tester.getRect(find.byKey(const Key('reader-viewport')));
      expect(viewport.top, moreOrLessEquals(44, epsilon: 0.5),
          reason: '全屏态正文顶让开状态栏');
      expect(viewport.height, 808, reason: '视口高实测基线（探针）');

      final Rect content =
          tester.getRect(find.byKey(const Key('reader-content-area')));
      expect(content.height, 746, reason: '正文可排版高 = 分页预算 usableHeight');
      expect(viewport.bottom - content.bottom, moreOrLessEquals(62, epsilon: 0.5),
          reason: '正文区应让开「指示条高 28 + 导航条 34」');

      // 指示条仍贴屏幕底边（它在 Stack 内 `bottom: 0`，不占布局）。
      final Rect indicator =
          tester.getRect(find.byKey(const Key('reader-progress-indicator')));
      expect(indicator.bottom, moreOrLessEquals(viewport.bottom, epsilon: 0.5));

      // 新增契约（默认全屏后才有意义）：**读数文字**必须让开手势导航条——
      // 改前指示条贴物理底边，读数会被系统手势条压住。
      final Rect readout =
          tester.getRect(find.byKey(const Key('reader-progress-text')));
      expect(readout.bottom, lessThanOrEqualTo(viewport.bottom - 34 + 0.5),
          reason: '读数底 ${readout.bottom} 应让开底部导航条（屏底 − 34）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('不遮挡契约：内容底 ≤ 指示条顶（变异即判红）',
        (WidgetTester tester) async {
      // **变异护栏**：删掉让位 Padding 或把它挪到 Stack 外 → `content.bottom`
      // 与 `indicator.top` 重叠 / 差值为 0 → 判红。
      await pumpPhone(tester);

      final Rect content =
          tester.getRect(find.byKey(const Key('reader-content-area')));
      final Rect indicator =
          tester.getRect(find.byKey(const Key('reader-progress-indicator')));

      expect(content.bottom, lessThanOrEqualTo(indicator.top + 0.5),
          reason: 'content.bottom=${content.bottom} indicator.top=${indicator.top}');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TYP-09：唤出 / 收起 chrome 不得改动正文排版区（变异即判红）',
        (WidgetTester tester) async {
      // 唤出 chrome 时若正文可排版高变化（`appBar`/`bottomNavigationBar` 是
      // Scaffold 占位槽会挤压 body），整页重排、阅读位置跳。修法 = 两个
      // `extendBody*` + 正文预算只吃 Scaffold **外层**的系统 inset。
      //
      // 变异判别力：去掉任一 `extendBody*` 或正文预算改回读 body 内 MediaQuery
      // → 正文区矩形变 → 红；把常驻读数挪回正文 Stack 的 `bottom: 0` → 控制条
      // 盖住它 → 判红。
      await pumpPhone(tester);

      // 用户可见口径放最前：**正文里的字**两态必须一像素不挪。
      final Rect heading0 = tester.getRect(chapterHeading('第一章'));
      final Rect viewport0 =
          tester.getRect(find.byKey(const Key('reader-viewport')));
      final Rect content0 =
          tester.getRect(find.byKey(const Key('reader-content-area')));

      // 字面量基线（硬编码，不用被测常量自证）。
      expect(content0.top, 44, reason: '正文顶让开状态栏');
      expect(content0.height, 746, reason: '正文可排版高 = 分页预算');
      expect(content0.bottom, 790, reason: '正文底让开读数（28 + 导航条 34）');

      await tester.tap(find.byKey(const Key('reader-chrome-toggle-status')));
      await tester.pump();
      await settle(tester, rounds: 20);
      expect(find.byType(ReaderControlBar), findsOneWidget,
          reason: '前置：chrome 已唤出');

      expect(tester.getRect(find.byKey(const Key('reader-viewport'))), viewport0,
          reason: '视口矩形两态必须逐边相同');
      expect(tester.getRect(find.byKey(const Key('reader-content-area'))),
          content0,
          reason: '正文排版区两态必须逐边相同（高度 + 顶边都不许动）');
      expect(tester.getRect(chapterHeading('第一章')), heading0,
          reason: '正文里的字两态不许挪位（用户可见口径）');

      // 常驻读数恒在，且正好落在控制条**正上方**——`control_bar.dart` 的窄屏
      // 让位（`kReaderControlProgressMinWidth`）明确依赖这一条。
      final Rect indicator =
          tester.getRect(find.byKey(const Key('reader-progress-indicator')));
      final Rect bar = tester.getRect(find.byType(ReaderControlBar));
      expect(indicator.bottom, moreOrLessEquals(bar.top, epsilon: 0.5),
          reason: '读数应在控制条正上方（indicator.bottom=${indicator.bottom} '
              'bar.top=${bar.top}）');
      expect(bar.bottom, moreOrLessEquals(viewport0.bottom, epsilon: 0.5),
          reason: '控制条应贴屏幕下缘');

      // 读数与控制条之间**不留空带**：控制条自带 `SafeArea(bottom: true)`，读数在
      // 它上方时不该再吃一遍系统 inset。变异判别力：`bottomInset` 恒传系统值
      // （不按 `_fullscreen` 分支）⇒ 多出 34dp 空白 → 判红。
      final Rect readout =
          tester.getRect(find.byKey(const Key('reader-progress-text')));
      expect(bar.top - readout.bottom, lessThanOrEqualTo(8),
          reason: '读数与控制条之间不得留空带'
              '（readout.bottom=${readout.bottom} bar.top=${bar.top}）');

      // 收起：几何回到与初始完全一致。
      await tester.tap(find.byKey(const Key('reader-chrome-toggle-status')));
      await tester.pump();
      await settle(tester, rounds: 20);
      expect(find.byType(ReaderControlBar), findsNothing);
      expect(tester.getRect(find.byKey(const Key('reader-viewport'))), viewport0);
      expect(tester.getRect(find.byKey(const Key('reader-content-area'))),
          content0);
      expect(tester.getRect(chapterHeading('第一章')), heading0);
      expect(tester.takeException(), isNull);
    });
  });
}
