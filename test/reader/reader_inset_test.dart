// 阅读页正文**不被常驻进度条遮挡**的布局契约。
//
// 归因（读 Flutter 源码核对后）：
//   · 「首行被 AppBar 压住」**不成立**——`Scaffold` 给 body 的 MediaQuery 做了
//     `removePadding(removeTop: appBar != null)`、body 放在 AppBar 之下，
//     正文区里 `mq.padding.top` 恒为 0（首行被切的真因在落位，见
//     `PagedScrollerState.offsetFor` 的「为什么按行顶」）。
//   · 「末行被进度条压住」**成立**：预留若加在正文 Stack **外面**，而指示条在
//     Stack **里面** `bottom: 0`，两者同步上移照旧重叠、还在控制条上方白留一条空带。
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
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

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
      //   content-area  top=44  bottom=794 h=750（= viewport − 58 让位）
      //   indicator     top=794 bottom=852 h=58（24 内容 + 34 导航条让位）
      //   ⇒ content.bottom(794) == indicator.top(794)：零空隙且不重叠。
      // 让位 = 24dp 指示条（实测内容高；无进度条 / 分界线）+ 34 手势条 = 58：
      // `AppBar` 不在树上、`extendBody*` 让 body 从 y=0 起画，顶部让位由**外层**
      // 系统 inset 的 `padding.top` 承担，底部 34 由外层 `systemMq.padding.bottom`
      // 显式交给正文 `reserve` 与读数行（与 chrome 状态无关）。
      final Rect viewport = tester.getRect(find.byKey(const Key('reader-viewport')));
      expect(viewport.top, moreOrLessEquals(44, epsilon: 0.5),
          reason: '全屏态正文顶让开状态栏');
      expect(viewport.height, 808, reason: '视口高实测基线（探针）');

      final Rect content =
          tester.getRect(find.byKey(const Key('reader-content-area')));
      expect(content.height, 750, reason: '正文可排版高 = 分页预算 usableHeight');
      expect(viewport.bottom - content.bottom, moreOrLessEquals(58, epsilon: 0.5),
          reason: '正文区应让开「指示条高 24 + 导航条 34」');

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
      expect(content.bottom, moreOrLessEquals(indicator.top, epsilon: 0.5),
          reason: '去掉 2px 条后不留空隙：正文底应紧贴读数区顶');
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
      expect(content0.height, 750, reason: '正文可排版高 = 分页预算');
      expect(content0.bottom, 794, reason: '正文底贴住读数区（24 + 导航条 34）');

      await tester.tap(find.byKey(const Key('reader-chrome-toggle-status')));
      await tester.pump();
      await settle(tester, rounds: 20);
      // 入场是 250ms 滑入：`settle(20)` 只推 160ms，量几何前先播到位。
      await tester.pumpAndSettle();
      expect(find.byType(ReaderControlBar), findsOneWidget,
          reason: '前置：chrome 已唤出');

      expect(tester.getRect(find.byKey(const Key('reader-viewport'))), viewport0,
          reason: '视口矩形两态必须逐边相同');
      expect(tester.getRect(find.byKey(const Key('reader-content-area'))),
          content0,
          reason: '正文排版区两态必须逐边相同（高度 + 顶边都不许动）');
      expect(tester.getRect(chapterHeading('第一章')), heading0,
          reason: '正文里的字两态不许挪位（用户可见口径）');

      // §2.121（沿用 §2.120 口径）：**胶囊保持原位**（不上移 24dp），唤出态
      // 读数 `Opacity(0)` 隐藏；正文上下都不叠渐进模糊带。
      // 判据 = 工具栏盒底与胶囊底都贴回 §2.118 的坐标；重新上移 24dp 会在此判红。
      final Rect indicator =
          tester.getRect(find.byKey(const Key('reader-progress-indicator')));
      final Rect bar = tester.getRect(find.byType(ReaderControlBar));
      final Rect pill = tester.getRect(find.byType(MiFloatingToolbar));
      expect(indicator.bottom, moreOrLessEquals(viewport0.bottom, epsilon: 0.5),
          reason: '读数应贴屏幕底（indicator.bottom=${indicator.bottom}）');
      expect(bar.bottom, moreOrLessEquals(viewport0.bottom, epsilon: 0.5),
          reason: '工具栏盒底应贴屏幕下缘（bar.bottom=${bar.bottom}）');
      expect(pill.bottom, moreOrLessEquals(viewport0.bottom - 34, epsilon: 0.5),
          reason: '胶囊底应停在 SafeArea 让位处（屏底 − 34），不得再上移 24dp'
              '（pill.bottom=${pill.bottom}）');

      // 读数隐藏但仍**恒在树上**（`TYP-09` 验收①）：`Opacity` 不拦指针。
      final Finder hiddenReadout = find.byWidgetPredicate(
        (Widget w) =>
            w is Opacity &&
            w.opacity == 0 &&
            w.child?.key == const Key('reader-chrome-toggle-status'),
      );
      expect(hiddenReadout, findsOneWidget,
          reason: '唤出态读数应由一层 Opacity(0) 收起');

      // 读数文字几何仍让开 34dp 手势条（隐藏只改绘制、不改布局）。
      final Rect readout =
          tester.getRect(find.byKey(const Key('reader-progress-text')));
      expect(readout.bottom, lessThanOrEqualTo(indicator.bottom - 34 + 0.5),
          reason: '读数文字必须让开 34dp 手势条（readout.bottom=${readout.bottom}）');
      expect(readout.top, greaterThanOrEqualTo(indicator.top - 0.5),
          reason: '读数文字应在读数条内容段内（readout.top=${readout.top}）');

      // 收起：几何回到与初始完全一致。
      //
      // 手势条那 34dp 上铺着同语义的透明命中层
      //（`reader-chrome-toggle-status-gap`）——按读数行中心落点即命中那层 =
      // 同一个收起入口。用 `tapAt` 而非 `tap(finder)`：命中的不是 finder
      // 自己那个 widget，后者会报 "would not hit test" 警告。
      await tester.tapAt(tester
          .getCenter(find.byKey(const Key('reader-chrome-toggle-status'))));
      await tester.pump();
      await settle(tester, rounds: 20);
      // 退场 250ms 滑出播完才摘树（160ms 的 settle 不够）。
      await tester.pumpAndSettle();
      expect(find.byType(ReaderControlBar), findsNothing);
      expect(tester.getRect(find.byKey(const Key('reader-viewport'))), viewport0);
      expect(tester.getRect(find.byKey(const Key('reader-content-area'))),
          content0);
      expect(tester.getRect(chapterHeading('第一章')), heading0);
      expect(tester.takeException(), isNull);
    });
  });
}
