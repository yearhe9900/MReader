// §2.121：阅读页**取消渐进模糊**。本文件从「钉住模糊带」改为钉「不许回来」——
// 该效果两版口径（§2.119 上下 119dp / §2.120 轻档收窄）均已下线，行为消失后
// 原用例若不改写会退化成恒绿护栏，故整组换成负向契约。
//
// 逐条钉成可判红的护栏：
//  ① 全屏 / 唤出 / 收起三态：都不存在 `reader-chrome-blur-*` 模糊带；
//  ② `Scaffold.body` 恒是正文本体 `LayoutBuilder`，不许再套承载模糊层的
//     `Stack(Positioned.fill(...), 模糊带)`（两版旧实现都是这么接的）；
//  ③ 阅读页整棵树零 `BackdropFilter`（正文两态必须全清晰、不糊）；
//  ④ 顶栏回到**不透明** Material 底（透明底原为顶部模糊让路，模糊撤掉后
//     标题会直接压在正文首行上）；
//  ⑤ §2.120 两条用户口径保留：唤出态读数 `Opacity(0)` 隐藏且**恒在树上**
//    （`TYP-09` 验收①）、胶囊**不上移 24dp**。
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

const Key _topBlur = ValueKey<String>('reader-chrome-blur-top');
const Key _bottomBlur = ValueKey<String>('reader-chrome-blur-bottom');

void main() {
  capTestTimeout();

  group('§2.121 阅读页 chrome 无渐进模糊', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_chrome_no_blur_');
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

    Future<void> hideChrome(WidgetTester tester) async {
      await tester.tapAt(
          tester.getCenter(find.byKey(const Key('reader-chrome-toggle-status'))));
      await tester.pump();
      await settle(tester, rounds: 20);
    }

    Finder hiddenReadout() => find.byWidgetPredicate(
          (Widget w) =>
              w is Opacity &&
              w.opacity == 0 &&
              w.child?.key == const Key('reader-chrome-toggle-status'),
        );

    /// 三态共用的干净判据：无模糊带 key、无 `BackdropFilter`、body 不套 Stack。
    void expectCleanBody(WidgetTester tester) {
      expect(find.byKey(_topBlur), findsNothing,
          reason: '顶部渐进模糊带已取消，加回来即判红');
      expect(find.byKey(_bottomBlur), findsNothing,
          reason: '底部渐进模糊带已取消，加回来即判红');
      expect(find.byType(BackdropFilter), findsNothing,
          reason: '阅读页正文两态都不糊，BackdropFilter 不该上树');
      final Scaffold scaffold =
          tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.body, isA<LayoutBuilder>(),
          reason: 'body 应直接是 _buildBody 的 LayoutBuilder；'
              '再套 Stack(Positioned.fill(...), 模糊带) 会在此判红');
    }

    testWidgets('默认沉浸全屏：零模糊带、正文全清晰', (WidgetTester tester) async {
      await pumpPhone(tester);

      expectCleanBody(tester);
      expect(find.byKey(const Key('reader-progress-indicator')), findsOneWidget);
      expect(hiddenReadout(), findsNothing,
          reason: '全屏态读数必须照常可见');
      await closeBook(tester);
    });

    testWidgets('唤出 chrome：仍零模糊带，顶栏回到不透明底',
        (WidgetTester tester) async {
      await pumpPhone(tester);
      await showChrome(tester);

      expect(find.byType(ReaderControlBar), findsOneWidget,
          reason: '前置：chrome 已唤出');
      expectCleanBody(tester);

      final AppBar appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, isNull,
          reason: '顶栏用默认不透明 Material 底；改回 Colors.transparent '
              '会让标题压在正文首行上');
      expect(appBar.elevation, isNull);
      await closeBook(tester);
    });

    testWidgets('收起 chrome 后：正文同样全清晰（两态都不叠层）',
        (WidgetTester tester) async {
      await pumpPhone(tester);
      await showChrome(tester);
      await hideChrome(tester);

      expect(find.byType(ReaderControlBar), findsNothing);
      expectCleanBody(tester);
      expect(hiddenReadout(), findsNothing,
          reason: '收起后读数恢复可见');
      await closeBook(tester);
    });

    testWidgets('§2.120 两条口径保留：读数隐藏但恒在树上、胶囊不上移 24dp',
        (WidgetTester tester) async {
      await pumpPhone(tester);
      await showChrome(tester);

      expect(hiddenReadout(), findsOneWidget,
          reason: '读数应由一层 Opacity(0) 收起；去掉它读数会重新显示');
      expect(find.byKey(const Key('reader-progress-indicator')), findsOneWidget,
          reason: '`TYP-09` 验收①：读数恒在，隐藏只改绘制不改树');

      final Rect bar = tester.getRect(find.byType(ReaderControlBar));
      final Rect pill = tester.getRect(find.byType(MiFloatingToolbar));
      expect(bar.bottom, moreOrLessEquals(852, epsilon: 0.5),
          reason: '工具栏盒底应贴屏幕下缘（bar.bottom=${bar.bottom}）');
      expect(pill.bottom, moreOrLessEquals(852 - 34, epsilon: 0.5),
          reason: '胶囊底应停在屏底 − 34，重新上移会在此判红'
              '（pill.bottom=${pill.bottom}）');
      await closeBook(tester);
    });
  });
}
