// §2.119：阅读页 chrome 唤出时**读数行不隐藏** + 顶部 / 底部渐进模糊带契约。
//
// 旧口径（§2.118「唤出态读数 `Opacity(0)` 不绘制」）作废，本文件把新行为
// 逐条钉成可判红的护栏：
//  ① 默认沉浸全屏：一条模糊带都没有、读数行可见；
//  ② 唤出 chrome：上下各一条 [ReaderChromeEdgeBlur]，收起后同时消失；
//  ③ 读数行唤出态**不再**被 `Opacity(0)` 包住（重新包回去即判红）；
//  ④ 模糊带贴「内容边界」、底部是顶部的 y 镜像，每段 σ 走 `MiFilterCache`；
//  ⑤ 模糊层禁 `Opacity` / `ShaderMask` 祖层（会切断 `BackdropFilter` 的
//     backdrop，磨砂整段消失）——移植体里已踩过的坑。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_chrome_blur.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

import 'reader_harness.dart';
import '../test_config.dart';

const ValueKey<String> _topBlur = ValueKey<String>('reader-chrome-blur-top');
const ValueKey<String> _bottomBlur =
    ValueKey<String>('reader-chrome-blur-bottom');

void main() {
  capTestTimeout();

  group('§2.119 阅读页 chrome 渐进模糊', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_chrome_blur_');
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

    testWidgets('默认沉浸全屏：零模糊带，读数行在场且可见',
        (WidgetTester tester) async {
      await pumpPhone(tester);

      expect(find.byType(ReaderChromeEdgeBlur), findsNothing,
          reason: '沉浸阅读时正文必须干净，不挂任何模糊层');
      expect(find.byKey(_topBlur), findsNothing);
      expect(find.byKey(_bottomBlur), findsNothing);
      expect(find.byKey(const Key('reader-progress-indicator')), findsOneWidget);
      expect(
          _hasForbiddenAncestor(
              tester, find.byKey(const Key('reader-progress-indicator'))),
          isFalse,
          reason: '读数行不得被 Opacity 包住');
      await closeBook(tester);
    });

    testWidgets('唤出 chrome：上下各一条渐进模糊带；收起后同时消失',
        (WidgetTester tester) async {
      await pumpPhone(tester);
      await showChrome(tester);

      expect(find.byType(ReaderChromeEdgeBlur), findsNWidgets(2));
      expect(find.byKey(_topBlur), findsOneWidget);
      expect(find.byKey(_bottomBlur), findsOneWidget);
      expect(tester.widget<ReaderChromeEdgeBlur>(find.byKey(_topBlur)).fromTop,
          isTrue);
      expect(
          tester.widget<ReaderChromeEdgeBlur>(find.byKey(_bottomBlur)).fromTop,
          isFalse);

      await hideChrome(tester);
      expect(find.byType(ReaderControlBar), findsNothing);
      expect(find.byType(ReaderChromeEdgeBlur), findsNothing,
          reason: '收起后模糊带必须一并撤掉');
      await closeBook(tester);
    });

    testWidgets('读数行唤出态照常可见（不再 Opacity(0)）',
        (WidgetTester tester) async {
      await pumpPhone(tester);
      await showChrome(tester);

      expect(find.byKey(const Key('reader-progress-indicator')), findsOneWidget);
      expect(
          _hasForbiddenAncestor(
              tester, find.byKey(const Key('reader-progress-indicator'))),
          isFalse,
          reason: '旧 §2.118 的 Opacity(0) 会让读数消失，重新包回去必须判红');
      // 读数文字仍在树上、且让开 34dp 手势条（两态同一个 bottomInset）。
      final Rect readout =
          tester.getRect(find.byKey(const Key('reader-progress-text')));
      expect(readout.bottom, lessThanOrEqualTo(852 - 34 + 0.5),
          reason: '可见后文字不得落进手势条');
      await closeBook(tester);
    });

    testWidgets('模糊带贴内容边界、高 119dp、底部曲线是顶部镜像',
        (WidgetTester tester) async {
      await pumpPhone(tester);
      await showChrome(tester);

      const double extent = MiGradientBlurProfile.nominalExtent; // 119dp
      final Rect top = tester.getRect(find.byKey(_topBlur));
      final Rect bottom = tester.getRect(find.byKey(_bottomBlur));
      final Rect indicator =
          tester.getRect(find.byKey(const Key('reader-progress-indicator')));

      // 上带从状态栏下沿起（那里才是正文首行），下带底缘接上读数行顶缘。
      expect(top.top, moreOrLessEquals(44, epsilon: 0.5));
      expect(top.height, moreOrLessEquals(extent, epsilon: 0.5));
      expect(bottom.bottom, moreOrLessEquals(indicator.top, epsilon: 0.5),
          reason: '下带不应糊到读数行自己（它是 chrome，不是正文）');
      expect(bottom.height, moreOrLessEquals(extent, epsilon: 0.5));
      expect(top.width, moreOrLessEquals(393, epsilon: 0.5));
      expect(bottom.width, moreOrLessEquals(393, epsilon: 0.5));

      // 首段（σ 最大、平台段）贴边缘：上带在带顶、下带在带底 ⇒ 镜像关系。
      final List<BackdropFilter> topFilters = tester
          .widgetList<BackdropFilter>(find.descendant(
            of: find.byKey(_topBlur),
            matching: find.byType(BackdropFilter),
          ))
          .toList();
      final List<BackdropFilter> bottomFilters = tester
          .widgetList<BackdropFilter>(find.descendant(
            of: find.byKey(_bottomBlur),
            matching: find.byType(BackdropFilter),
          ))
          .toList();
      final int bandCount = MiGradientBlur.bandsFor(
        extent: extent,
        underSurface: false,
      ).length;
      expect(topFilters, hasLength(bandCount));
      expect(bottomFilters, hasLength(bandCount));
      expect(bandCount, greaterThanOrEqualTo(4));

      final Rect firstTop = tester.getRect(find.descendant(
        of: find.byKey(_topBlur),
        matching: find.byType(BackdropFilter),
      ).first);
      final Rect firstBottom = tester.getRect(find.descendant(
        of: find.byKey(_bottomBlur),
        matching: find.byType(BackdropFilter),
      ).first);
      expect(firstTop.top, moreOrLessEquals(top.top, epsilon: 0.5),
          reason: '顶部曲线首段应贴带顶');
      expect(firstBottom.bottom, moreOrLessEquals(bottom.bottom, epsilon: 0.5),
          reason: '底部曲线首段应贴带底（y 镜像）');

      // 每段 σ 都来自缓存的 native filter（滚动时不得逐帧新建）。
      final List<MiTopBarBlurBand> bands = MiGradientBlur.bandsFor(
        extent: extent,
        underSurface: false,
      );
      for (int i = 0; i < bandCount; i++) {
        expect(identical(topFilters[i].filter, MiFilterCache.blur(bands[i].sigma)),
            isTrue, reason: '顶部第 $i 段未复用 MiFilterCache');
        expect(
            identical(bottomFilters[i].filter,
                MiFilterCache.blur(bands[i].sigma)),
            isTrue, reason: '底部第 $i 段未复用 MiFilterCache');
      }
      await closeBook(tester);
    });

    testWidgets('模糊层不得被 Opacity / ShaderMask 包住（backdrop 会变空）',
        (WidgetTester tester) async {
      await pumpPhone(tester);
      await showChrome(tester);

      expect(_hasForbiddenAncestor(tester, find.byKey(_topBlur)), isFalse,
          reason: '顶部模糊带不得被 Opacity / ShaderMask / FadeTransition 包住');
      expect(_hasForbiddenAncestor(tester, find.byKey(_bottomBlur)), isFalse,
          reason: '底部模糊带不得被 Opacity / ShaderMask / FadeTransition 包住');
      expect(
        find.descendant(
          of: find.byKey(_topBlur),
          matching: find.byType(DecoratedBox),
        ),
        findsOneWidget,
        reason: '压色是模糊之上的独立兄弟层（不是模糊的父层）',
      );
      await closeBook(tester);
    });
  });
}

/// 从 [finder] 往上走到 `Scaffold` 为止，查有没有会切断 backdrop 的祖层。
///
/// 只查阅读页这一层：`MaterialApp` 的路由转场 / `Overlay` 也可能带 `Opacity`，
/// 但那不在 `Scaffold` 之内、不影响本页磨砂（用整树 `find.ancestor` 会误报）。
bool _hasForbiddenAncestor(WidgetTester tester, Finder finder) {
  bool found = false;
  tester.element(finder).visitAncestorElements((Element ancestor) {
    if (ancestor.widget is Scaffold) return false; // 到 Scaffold 即止
    final Widget widget = ancestor.widget;
    if (widget is Opacity ||
        widget is ShaderMask ||
        widget is FadeTransition) {
      found = true;
    }
    return true;
  });
  return found;
}
