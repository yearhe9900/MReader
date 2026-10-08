// 阅读页正文**不被常驻进度条遮挡**的布局契约（2026-10-06 起，2026-10-08 订正）。
//
// 起因：负责人真机截图「字没显示全」。当时归因成「首行被 AppBar 压住、
// 末行被常驻 [ReaderProgressIndicator] 压住」，据此做了两处改动；
// 2026-10-08 读 Flutter 源码核对后订正为：
//   · 「首行被 AppBar 压住」**不成立**——`Scaffold` 给 body 的 MediaQuery 做了
//     `removePadding(removeTop: appBar != null)`（`scaffold.dart:3030`），
//     并把 body 放在 AppBar 之下（`scaffold.dart:1114`）；正文区里的
//     `mq.padding.top` 恒为 0。（首行被切的真因在落位，见
//     `PagedScrollerState.offsetFor` 的「为什么按行顶」。）
//   · 「末行被进度条压住」**成立**，且改前**没修好**：28dp 预留被加在正文
//     Stack **外面**，而指示条在 Stack **里面** `bottom: 0`，两者同步上移、
//     照旧重叠，还在控制条上方白留 28dp。
//
// 本测试钉住两件事：正文排版区确实让开了指示条；正文区高 = 分页预算 `usableHeight`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
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

      // 探针实测基线（393×852，top44/bottom34，**默认沉浸全屏**）：
      //   viewport      top=44  bottom=852 h=808（顶让开 44 状态栏）
      //   content-area  top=44  bottom=790 h=746（= viewport − 62 让位）
      //   indicator     top=792 bottom=852 h=60（26 内容 + 34 导航条让位）
      //   ⇒ content.bottom(790) ≤ indicator.top(792)，两者不重叠。
      //
      // 注 1：2026-10-08 前 viewport 高是 587——28dp 让位加在视口**外面**、
      // 把整个视口连同指示条一起压扁了；现在让位挪到视口内部。
      // 注 2：同一批「默认全屏」变更后 `AppBar` 不在树上，body 从 y=0 起算，
      // 顶部让位由 `mq.padding.top`（44）承担；底部因 `bottomNavigationBar`
      // 不存在、`Scaffold` 不再 `removeBottomPadding`，多出一段 34 的导航条让位
      // （见 `reader_page` 的 `reserve`），故让位合计 28 + 34 = 62。
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
      // 这条同时是**变异护栏**：
      //   · 删掉让位 Padding      → `reader-content-area` 找不到 / 底边与指示条同高 → 红；
      //   · 把 Padding 挪到 Stack 外 → `viewport.bottom − content.bottom == 0` → 红
      //     （2026-10-08 改前就是这个形态，真机表现为末行被 85% 底色盖住发暗）。
      await pumpPhone(tester);

      final Rect content =
          tester.getRect(find.byKey(const Key('reader-content-area')));
      final Rect indicator =
          tester.getRect(find.byKey(const Key('reader-progress-indicator')));

      expect(content.bottom, lessThanOrEqualTo(indicator.top + 0.5),
          reason: 'content.bottom=${content.bottom} indicator.top=${indicator.top}');
      expect(tester.takeException(), isNull);
    });
  });
}
