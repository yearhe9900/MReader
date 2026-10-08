// `TYP-07` / `TYP-08`：字体族选择 + 亮度遮罩 + 预设背景色 widget 测试。
//
// 验收映射：
//   · `TYP-07` ① 字体族可切换并**立即生效**（点 chip 后只 pump 一帧即换样式）；
//   · `TYP-07` ② 中文无豆腐块 —— 由平台族名 + 回退链兜底（断言 fontFamilyFallback
//     非空：Windows 不认通用族名，回退链是无豆腐块的实际保障）；
//   · `TYP-07` ③ `pubspec.yaml` 无 `fonts:` 资源段（不内嵌字体文件）；
//   · `TYP-08` ① 亮度遮罩**实时**生效（拖动回调后一帧）且**保留**（重进仍在）；
//   · `TYP-08` ② 米黄背景对比度足够 —— WCAG 对比度 ≥ 4.5（人工推演：#F2E7D3 底 ×
//     #1F1F1F 字 ≈ 13.5:1）；
//   · `TYP-08` ③ 夜间模式不产生白底 —— 暗色主题下底色恒为暗色
//     （#121212 / 纯黑 #000000），正文浅色。
//   · `M-PAGE T05-d` ① 翻页方式 chip 即时切换渲染形态 —— 滚动体只翻
//     `Offstage`、Element 全程同一（不重挂）；② 滑动模式下拖拽翻页推进
//     语义进度（章标题从页 0 消失），滚动体全程保活。
//
// 预期值人工推演（遮罩不透明度）：亮度 b → 遮罩黑层不透明度 `1 - b`；
// b = 0.5 时为 0.5（`Color.fromRGBO(0,0,0,·).a` 精确等于该值）。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/pagination/paged_turn_body.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_prefs.dart';
import 'package:mreader/reader/reading_prefs_store.dart';
import 'package:mreader/typography/typeset.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// WCAG 相对亮度（sRGB 通道 0~1，gamma 解码后加权）。
double _luminance(Color color) {
  double channel(double c) => c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 对比度（(L1 + 0.05) / (L2 + 0.05)，L1 ≥ L2）。
double _contrastRatio(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double light = math.max(la, lb);
  final double dark = math.min(la, lb);
  return (light + 0.05) / (dark + 0.05);
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('TYP-07 字体族 / TYP-08 亮度与背景色', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late ReadingPrefsStore prefsStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_appear_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      prefsStore = ReadingPrefsStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildApp({ReadingPrefsStore? prefs, ThemeData? theme}) => MaterialApp(
          theme: theme,
          home: ReaderPage(
            source: FakeBookSource(),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: repo,
            readingPrefsStore: prefs ?? prefsStore,
          ),
        );

    InlineParagraph paragraph(WidgetTester tester) =>
        tester.widget<InlineParagraph>(find.byType(InlineParagraph).first);

    testWidgets('TYP-07 验收①②：字体族可切换并立即生效，挂跨平台回退链',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 初始：系统默认（fontFamily 为 null）。
      expect(paragraph(tester).style.fontFamily, isNull);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-appearance')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('font-serif')));
      // 分页模式正文样式走 `PaginationConfig`：cfg 变化挂帧末 reprime 重分页
      // 后才换样式（`M-PAGE` 迁移；原滚动模式口径为单帧生效，观感仍即时）。
      await tester.pumpAndSettle();
      expect(paragraph(tester).style.fontFamily, 'serif');
      // 验收②：回退链非空（Windows 不认通用族名，靠回退链保中文无豆腐块）。
      expect(paragraph(tester).style.fontFamilyFallback, isNotEmpty);

      await tester.tap(find.byKey(const Key('font-sans')));
      await tester.pumpAndSettle();
      expect(paragraph(tester).style.fontFamily, 'sans-serif');
      expect(paragraph(tester).style.fontFamilyFallback, isNotEmpty);

      await tester.tap(find.byKey(const Key('font-default')));
      await tester.pumpAndSettle();
      expect(paragraph(tester).style.fontFamily, isNull);
    });

    test('TYP-07 验收③：pubspec.yaml 无 fonts: 资源段（不内嵌字体文件）', () {
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        RegExp(r'^\s*fonts:', multiLine: true).hasMatch(pubspec),
        isFalse,
        reason: 'pubspec.yaml 不得出现 fonts: 资源段（TYP-07 红线）',
      );
    });

    testWidgets('TYP-08 验收①：亮度遮罩实时生效且持久化保留',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 初始亮度 1.0：不加遮罩。
      expect(find.byKey(const Key('reader-brightness-mask')), findsNothing);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-appearance')));
      await tester.pumpAndSettle();

      // 滑块到 0.5（拖动路径即 onChanged 回调）→ 一帧生效（实时）。
      final Slider slider =
          tester.widget<Slider>(find.byKey(const Key('brightness-slider')));
      slider.onChanged!(0.5);
      await tester.pump();

      final Finder mask = find.byKey(const Key('reader-brightness-mask'));
      expect(mask, findsOneWidget);
      ColoredBox maskBox() => tester.widget<ColoredBox>(
            find.descendant(of: mask, matching: find.byType(ColoredBox)),
          );
      // 推演：遮罩不透明度 = 1 - 0.5 = 0.5。
      expect(maskBox().color.a, closeTo(0.5, 0.001));

      await settle(tester); // 排空落盘
      final ReadingPrefs? saved =
          await tester.runAsync<ReadingPrefs?>(() => prefsStore.load());
      expect(saved, isNotNull);
      expect(saved!.brightness, 0.5, reason: '亮度即时持久化');

      // 真·关书重进（换 store 实例模拟重启）：亮度保留。
      await closeBook(tester);
      await tester.pumpWidget(buildApp(prefs: ReadingPrefsStore(paths)));
      await settle(tester);

      final Finder mask2 = find.byKey(const Key('reader-brightness-mask'));
      expect(mask2, findsOneWidget, reason: '重进后遮罩仍在（亮度保留）');
      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(of: mask2, matching: find.byType(ColoredBox)),
            )
            .color
            .a,
        closeTo(0.5, 0.001),
      );
    });

    testWidgets('TYP-08 验收②：米黄背景对比度足够（WCAG ≥ 4.5）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-appearance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('background-sepia')));
      await tester.pump(); // 一帧生效。

      // 页面底色 = 米黄 #F2E7D3（日间映射）。
      final Scaffold scaffold =
          tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, const Color(0xFFF2E7D3));

      // 正文 #1F1F1F × 米黄 #F2E7D3 ≈ 13.5:1（推演）≥ 4.5（WCAG AA 正文阈值）。
      final InlineParagraph para = paragraph(tester);
      expect(para.style.color, const Color(0xFF1F1F1F));
      expect(
        _contrastRatio(const Color(0xFFF2E7D3), para.style.color!),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('TYP-08 验收③：夜间模式不产生白底', (WidgetTester tester) async {
      // 暗色主题 = 夜间模式（以实际生效的 brightness 为准）。
      await tester.pumpWidget(buildApp(theme: ThemeData.dark()));
      await settle(tester);

      // 白色预设在夜间映射为深色底 #121212：不得出现白底。
      final Scaffold scaffold =
          tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, const Color(0xFF121212));
      expect(paragraph(tester).style.color, const Color(0xFFE6E6E6));

      // 纯黑预设：页面底恰为 #000000，正文浅色（#D9D9D9）。
      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-appearance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('background-black')));
      // 底色单帧即生效（直接 build）；正文色在分页 cfg 下随帧末 reprime 收敛。
      await tester.pumpAndSettle();
      final Scaffold dark = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(dark.backgroundColor, const Color(0xFF000000));
      expect(paragraph(tester).style.color, const Color(0xFFD9D9D9));

      // 对比度同样足够：#000000 × #D9D9D9 ≈ 14.9:1（推演）≥ 4.5。
      expect(
        _contrastRatio(const Color(0xFF000000), const Color(0xFFD9D9D9)),
        greaterThanOrEqualTo(4.5),
      );
    });

    // ── `M-PAGE T05-d`：翻页方式接入外观面板 ─────────────────────────────

    testWidgets('T05-d 验收①：翻页 chip 即时切换渲染形态，滚动体 Element 不重挂',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      final Finder scrollerFinder =
          find.byType(PagedScroller, skipOffstage: false);
      final Finder turnFinder = find.byType(PageTurnBody);

      // 初始滚动模式：滚动体在场（未 offstage），无翻页体。
      expect(scrollerFinder, findsOneWidget);
      expect(find.byType(PagedScroller), findsOneWidget);
      expect(turnFinder, findsNothing);
      final Element scrollerBefore = tester.element(scrollerFinder);

      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-appearance')));
      await tester.pumpAndSettle();

      // 切「滑动」：翻页体出场；滚动体只翻 Offstage，Element 同一
      // （布局表 / ScrollController / GlobalKey 全保留 → 不重挂）。
      await tester.tap(find.byKey(const Key('pageMode-slide')));
      await tester.pumpAndSettle();
      expect(turnFinder, findsOneWidget);
      expect(scrollerFinder, findsOneWidget);
      expect(
        find.byType(PagedScroller),
        findsNothing,
        reason: '默认 finder 跳过 Offstage → 滚动体已出场但未卸载',
      );
      expect(
        tester.element(scrollerFinder),
        same(scrollerBefore),
        reason: 'scroll ↔ turn 只翻 Offstage，滚动体 Element 必须同一',
      );
      expect(
        tester.widget<ChoiceChip>(find.byKey(const Key('pageMode-slide'))).selected,
        isTrue,
        reason: 'chip 选中态随 prefs 即时刷新',
      );

      // 切回「滚动」：翻页体退场、滚动体复出，Element 仍同一。
      await tester.tap(find.byKey(const Key('pageMode-scroll')));
      await tester.pumpAndSettle();
      expect(turnFinder, findsNothing);
      expect(find.byType(PagedScroller), findsOneWidget);
      expect(tester.element(scrollerFinder), same(scrollerBefore));
      expect(
        tester.widget<ChoiceChip>(find.byKey(const Key('pageMode-scroll'))).selected,
        isTrue,
      );

      // 收尾：关面板（点遮罩）并排空采样 debounce / 落盘。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await settle(tester);
    });

    testWidgets('T05-d 验收②：滑动模式拖拽翻页推进语义进度，滚动体全程保活',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 开面板切「滑动」→ 点遮罩关面板回阅读页。
      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-appearance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pageMode-slide')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      final Finder scrollerFinder =
          find.byType(PagedScroller, skipOffstage: false);
      final Finder turnFinder = find.byType(PageTurnBody);
      expect(turnFinder, findsOneWidget);
      expect(scrollerFinder, findsOneWidget);
      expect(
        chapterHeading('第一章'),
        findsOneWidget,
        reason: '页 0 渲染章标题（翻页体内；滚动体 Offstage 被跳过）。'
            '只看正文区：底部读数左栏也显示当前章标题，不计入。',
      );

      // 翻页体宽度 = 阅读页 body 全宽 800 → 位移 300 → progress = 0.375
      // ≥ 0.3（kCommitDistance）→ commit 下一页。
      await tester.drag(turnFinder, const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(
        chapterHeading('第一章'),
        findsNothing,
        reason: '已翻到页 1：章标题只渲染在页 0',
      );
      expect(turnFinder, findsOneWidget, reason: '仍在翻页态');
      expect(scrollerFinder, findsOneWidget, reason: '滚动体全程保活（未重挂）');

      // 排空停稳采样 debounce / 进度落盘的真异步与 timer。
      await settle(tester);
    });
  });
}
