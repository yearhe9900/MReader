// chrome 出入场滑动动画契约（`reader_control_chrome.dart` 三常量 +
// `reader_page._setChromeShown`）：
//
//   ① 时长 / 曲线钉字面量：250ms、入 easeOutCubic、出 easeInCubic；
//   ② 唤出 = 顶栏从屏幕上方滑入、底栏从屏幕下方滑入：**入场首帧仍在屏外**
//      （底栏 bottom > 屏底、顶栏 top < 0），播完贴边（底栏贴屏底、顶栏贴 0）；
//   ③ 收起 = 反向滑出：**退场途中仍挂树**（`_chromeMounted` 播到 dismissed
//      才摘），播完 `AppBar` / `ReaderControlBar` 从树上消失；
//   ④ **动效全程正文几何一像素不动**（`extendBody*` 覆盖层语义在动画中的延伸）。
//
// 中途帧的断言同时是「非瞬时」判据：改成瞬时显隐（去掉动画）②③ 会判红。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/ui/reader_control_chrome.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('chrome 滑入滑出动画', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_anim_');
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

    /// 点常驻读数行左缘唤出 / 收起（与 harness `showChrome` 同落点，但**不
    /// settle**——本文件要抓的就是动画中途帧）。
    Future<void> tapStatusEdge(WidgetTester tester) async {
      final Rect status =
          tester.getRect(find.byKey(const Key('reader-chrome-toggle-status')));
      await tester.tapAt(Offset(status.left + 4, status.center.dy));
    }

    Rect contentArea(WidgetTester tester) => tester
        .getRect(find.byKey(const ValueKey<String>('reader-content-area')));

    testWidgets('① 时长与曲线钉字面量（250ms / easeOut 入 / easeIn 出）',
        (WidgetTester tester) async {
      expect(kReaderChromeSlideDuration,
          const Duration(milliseconds: 250),
          reason: '改时长要显式改这里，别悄悄挪');
      expect(kReaderChromeEnterCurve, Curves.easeOutCubic);
      expect(kReaderChromeExitCurve, Curves.easeInCubic);
    });

    testWidgets('② 唤出：顶栏自上滑入、底栏自下滑入，播完贴边；正文不动',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      expect(find.byType(ReaderControlBar), findsNothing,
          reason: '前置：默认沉浸全屏');
      final Rect content0 = contentArea(tester);
      final double screenH = tester.getSize(find.byType(Scaffold)).height;

      await tapStatusEdge(tester);
      await tester.pump(); // 挂树帧：动画起步中

      final Rect barMid = tester.getRect(find.byType(ReaderControlBar));
      expect(barMid.bottom, greaterThan(screenH),
          reason: '入场首帧底栏应从屏幕下方滑入（bottom=${barMid.bottom}）');
      final Rect topMid = tester.getRect(find.byType(AppBar));
      expect(topMid.top, lessThan(0),
          reason: '入场首帧顶栏应从屏幕上方滑入（top=${topMid.top}）');
      expect(contentArea(tester), content0,
          reason: '动效中正文几何不许动（覆盖层 + 纯绘制变换）');

      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(ReaderControlBar)).bottom,
          moreOrLessEquals(screenH, epsilon: 0.5),
          reason: '播完底栏盒底应贴屏幕下缘');
      expect(tester.getRect(find.byType(AppBar)).top,
          moreOrLessEquals(0, epsilon: 0.5),
          reason: '播完顶栏应贴屏幕上缘');
      expect(contentArea(tester), content0, reason: '唤出态正文几何同静息态');

      await closeBook(tester);
    });

    testWidgets('③ 收起：反向滑出至屏外，播完摘树；正文不动',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      await showChrome(tester); // harness 内含 settle ⇒ 停在完全唤出态

      final Rect content0 = contentArea(tester);
      final double screenH = tester.getSize(find.byType(Scaffold)).height;

      await tapStatusEdge(tester);
      // 首 tick 把起始时间归零（value 仍在 1、原位）——再推 40ms 出可见位移。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(find.byType(ReaderControlBar), findsOneWidget,
          reason: '退场途中仍挂树（播到 dismissed 才摘，中途可续播）');
      final Rect barMid = tester.getRect(find.byType(ReaderControlBar));
      expect(barMid.bottom, greaterThan(screenH),
          reason: '退场帧底栏应向屏幕下方滑出（bottom=${barMid.bottom}）');
      expect(contentArea(tester), content0, reason: '动效中正文几何不许动');

      await tester.pumpAndSettle();
      expect(find.byType(ReaderControlBar), findsNothing,
          reason: '播完才摘树（稳态树上无控制条）');
      expect(find.byType(AppBar), findsNothing, reason: '顶栏同步摘除');
      expect(contentArea(tester), content0, reason: '收起态正文几何同静息态');

      await closeBook(tester);
    });
  });
}
