// 阅读页 chrome 分组收纳的**布局契约**。
//
// 背景：顶栏曾平铺 9 个图标按钮（9 × 48dp > 手机屏宽）把书名与副标题挤掉；底部控制条
// 两行 11 个控件无分组边界，窄屏彼此贴死。本测试把「分组 + 尺寸 + 窄屏降级 + 不吞正文
// 高度」四条结论钉死。
//
// 实测基线（`tester.view.physicalSize` 宽度阶梯，改动布局必须重取）：
//   | 屏宽 | 控制条高 | 行距滑块宽 | 文字组标题 | 进度读数 |
//   |------|---------|-----------|-----------|---------|
//   | 800  | 107dp| 充足| 有| 有        |
//   | 393  | 107dp    | 79dp     | 无        | 有        |
//   | 360  | 157dp    | 298dp    | 无        | 有        |
//   | 320  | 161dp    | 258dp    | 无        | 无        |
// 三条降级规则（均在 `reader_control_chrome.dart` 有常量与依据）：
//   ① < 420dp 隐藏**文字**组标题（盒子 + 分隔线仍在，分组边界不丢）；
//   ② < 348dp 隐藏控制条内进度读数（同一串文字由正上方 `ReaderProgressIndicator`
//      常驻显示，`TYP-09` 要求它全屏时也在）；
//   ③ < 340dp 行距滑块换行独占一行（宁可多一行高度，也不把滑块压成不可用）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/typography/reader_settings.dart';
import 'package:mreader/ui/reader_control_chrome.dart';

import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  // 按给定屏宽构建阅读页控制条（全控件可用）并 settle。
  Future<void> pumpBar(
    WidgetTester tester,
    int width, {
    bool withAi = true,
    bool withTts = true,
    bool withTtsSettings = true,
    bool canGoPrev = true,
    bool canGoNext = true,
  }) async {
    tester.view.physicalSize = Size(width.toDouble(), 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ReaderControlBar(
          settings: const ReaderSettings(),
          onSettingsChanged: (ReaderSettings _) {},
          chapterNumber: 43,
          chapterCount: 1152,
          percent: 3,
          canGoPrev: canGoPrev,
          canGoNext: canGoNext,
          onPrevChapter: () {},
          onNextChapter: () {},
          onAi: withAi ? () {} : null,
          onTts: withTts ? () {} : null,
          onTtsSettings: withTtsSettings ? () {} : null,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('阅读页控制条分组收纳', () {
    testWidgets('分组不吞正文高度：宽屏 107dp / 窄屏换行 ≤ 165dp',
        (WidgetTester tester) async {
      // 107dp 与改前的 96dp 只差一条分隔线（+1）与其余 10dp 呼吸空间；
      // 断言上限而非精确值——真值口径是「不得显著长高」，因为控制条是
      // `bottomNavigationBar`，长高 1dp 就是正文少 1dp。
      await pumpBar(tester, 800);
      expect(tester.getSize(find.byType(ReaderControlBar)).height,
          lessThanOrEqualTo(110));

      // 极窄屏允许换行（滑块换行独占），但仍须有上限。
      await pumpBar(tester, 320);
      expect(tester.getSize(find.byType(ReaderControlBar)).height,
          lessThanOrEqualTo(165));
    });

    testWidgets('四档屏宽（800/393/360/320）均无溢出、无重叠',
        (WidgetTester tester) async {
      for (final int width in <int>[800, 393, 360, 320]) {
        await pumpBar(tester, width);
        expect(tester.takeException(), isNull,
            reason: '${width}dp 宽下不得出现 RenderFlex 溢出');
      }
    });

    testWidgets('控件一个不少：全部分组按钮与滑块都在（窄屏也不吞控件）',
        (WidgetTester tester) async {
      for (final int width in <int>[393, 320]) {
        await pumpBar(tester, width);
        for (final String key in <String>[
          'reader-control-prev',
          'reader-control-next',
          'reader-control-ai',
          'reader-control-tts',
          'reader-control-tts-settings',
          'reader-setting-font-dec',
          'reader-setting-font-value',
          'reader-setting-font-inc',
          'reader-setting-line-height',
          'reader-setting-margin',
          'reader-setting-theme',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget,
              reason: '${width}dp 下 $key 不应消失');
        }
      }
    });

    testWidgets('行距滑块始终可用：窄屏宁可换行也不把滑块压到 20dp 以下',
        (WidgetTester tester) async {
      for (final int width in <int>[800, 393, 360, 320]) {
        await pumpBar(tester, width);
        final double sliderWidth =
            tester.getSize(find.byKey(const Key('reader-setting-line-height'))).width;
        expect(sliderWidth, greaterThan(60),
            reason: '${width}dp 下行距滑块宽 ${sliderWidth}dp，已不可用');
      }
    });

    testWidgets('分组标题按宽度降级（< 420dp 隐藏文字，但分组盒子仍在）',
        (WidgetTester tester) async {
      // 宽屏：三个文字标题全在场。
      await pumpBar(tester, 800);
      expect(find.text('章节'), findsOneWidget);
      expect(find.text('朗读与 AI'), findsOneWidget);
      expect(find.text('排版'), findsOneWidget);

      // 窄屏：文字标题让位（避免挤掉按钮），但**分组盒子仍在**——分组边界
      // 由淡底盒子 + 分隔线表达，不因隐藏文字而丢失。
      await pumpBar(tester, 393);
      expect(find.text('章节'), findsNothing);
      expect(find.text('朗读与 AI'), findsNothing);
      expect(find.text('排版'), findsNothing);
      expect(find.byType(ReaderControlGroup), findsWidgets,
          reason: '文字标题可隐藏，分组盒必须保留');
      expect(find.byType(ReaderControlHDivider), findsOneWidget);
    });

    testWidgets('进度读数按宽度降级（< 348dp 让位给常驻进度指示器）',
        (WidgetTester tester) async {
      await pumpBar(tester, 393);
      expect(find.byKey(const Key('reader-control-progress')), findsOneWidget);

      // 极窄屏：控制条内读数隐藏——同一串文字仍由正文底部常驻的
      // ReaderProgressIndicator 显示（`TYP-09`：全屏时也在），信息不丢。
      await pumpBar(tester, 320);
      expect(find.byKey(const Key('reader-control-progress')), findsNothing);
    });

    testWidgets('功能按可用性整体隐藏（AI/TTS 全关 → 组与按钮同时消失）',
        (WidgetTester tester) async {
      await pumpBar(tester, 800,
          withAi: false, withTts: false, withTtsSettings: false);

      expect(find.byKey(const Key('reader-control-ai')), findsNothing);
      expect(find.byKey(const Key('reader-control-tts')), findsNothing);
      expect(find.byKey(const Key('reader-control-tts-settings')), findsNothing);
      expect(find.text('朗读与 AI'), findsNothing,
          reason: '无任何可用能力时不留空盒子/空标题');
      // 其余分组不受影响。
      expect(find.byKey(const Key('reader-control-prev')), findsOneWidget);
      expect(find.byKey(const Key('reader-setting-line-height')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('首章 / 末章：按钮保留为禁用态（不跳组、不消失）',
        (WidgetTester tester) async {
      await pumpBar(tester, 800, canGoPrev: false, canGoNext: false);

      for (final String key in <String>[
        'reader-control-prev',
        'reader-control-next',
      ]) {
        // Key 挂在 [ReaderControlIconButton] 包装层上（它把 key 转发给内部
        // IconButton），故这里取包装层读 onPressed。
        final ReaderControlIconButton button =
            tester.widget<ReaderControlIconButton>(find.byKey(Key(key)));
        expect(button.onPressed, isNull, reason: '$key 应为禁用态而非消失');
      }
    });

    testWidgets('统一尺寸：所有控制条图标按钮同为 44×44', (WidgetTester tester) async {
      await pumpBar(tester, 800);

      for (final String key in <String>[
        'reader-control-prev',
        'reader-control-next',
        'reader-control-ai',
        'reader-control-tts',
        'reader-control-tts-settings',
        'reader-setting-font-dec',
        'reader-setting-font-inc',
        'reader-setting-margin',
        'reader-setting-theme',
      ]) {
        final Size size = tester.getSize(find.byKey(Key(key)));
        expect(size.width, kReaderControlButton, reason: '$key 宽度');
        expect(size.height, kReaderControlButton, reason: '$key 高度');
      }
      expect(find.byType(IconButton), findsNWidgets(9),
          reason: '按钮总数= 章节2 + 朗读AI3 + 排版4');
    });
  });
}