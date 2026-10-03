// `M3-T02`：ReaderPage 划词选区接线 widget 测试（`AI-02`/`AI-03` 入口层）。
//
// 验收映射：
//   ① 三 AI 依赖齐备 + 全局开关开 → 长按正文出「翻译 / 释义 / 取消选择」操作条，
//      「取消选择」清选区；
//   ② 手势层（`reader-selection-gesture`）三态：齐备在场 / `aiEnabled` 关
//      （重建后求值消失）/ 三参数任一 null 不注册；
//   ③ 滚动起手清选区——操作条随滚动消失（`_onPagedScrollUpdate` → `_clearSelection`）；
//   ④ 点「翻译」开面板（store 无配置 → 面板给引导文案）。
//
// 口径：
//   · 装具复用 `reader_harness`（FakeBookSource 3 章 × 20 段 / settle / 假仓库）；
//   · 长按在**字形盒中心**起手（`getBoxesForSelection` 定位，同
//     `link_navigation_test._tapGlyph` 形制）+ `pump(kLongPressTimeout)` 过
//     长按阈值 → `onLongPressStart`；
//   · 玻璃钉「关」档走 `MaterialApp.builder`（生产 `app.dart` 同形制——路由
//     也在作用域内，点「翻译」开出的面板零玻璃开销、可 `pumpAndSettle`）；
//   · widget 内真异步 IO 用 [settle] 推进（FakeAsync 区不自行推进），载入
//     spinner 在场时不用 `pumpAndSettle`。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/ai/vocab_store.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/selection_overlay.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// 长按 [suffix] 所在字形：命中段落 → 词级选区 → 操作条。
///
/// 返回按住不放的手势（调用方决定何时 `up()`）。目标段落按**渲染文本后缀**
/// 唯一定位（`第1章正文2` 不被 `第1章正文12` 等包含——后缀等值比较）。
Future<TestGesture> _longPressGlyph(WidgetTester tester, String suffix) async {
  final Finder finder = find.byWidgetPredicate(
    (Widget w) => w is RichText && w.text.toPlainText().endsWith(suffix),
  );
  expect(finder, findsOneWidget, reason: '目标段落应唯一在场：$suffix');
  final RenderParagraph para = tester.renderObject<RenderParagraph>(finder);
  final String plain = para.text.toPlainText();
  final int start = plain.length - suffix.length;
  final List<TextBox> boxes = para.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + suffix.length),
  );
  expect(boxes, isNotEmpty);
  final TestGesture gesture = await tester.startGesture(
    para.localToGlobal(boxes.first.toRect().center),
  );
  await tester.pump(kLongPressTimeout); // 过长按阈值 → onLongPressStart
  await tester.pump();
  return gesture;
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  group('AI-02/AI-03 划词接线', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;
    late ProviderStore store;
    late VocabStore vocab;
    late AiClient client;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mreader_sel_ui_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
      store = ProviderStore(
        tempDir,
        AiKeyVault(FileSecureStore(directory: tempDir)),
      );
      await store.load();
      vocab = VocabStore(tempDir);
      await vocab.load();
      client = AiClient();
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// 关档宿主（builder 形制：provider 覆盖路由树——面板 / toast 零玻璃开销）。
    Widget buildApp({bool withAi = true}) => MaterialApp(
          builder: (BuildContext context, Widget? child) => GlassScopeProvider(
            config: glassTierConfigFor(GlassQualityTier.off),
            child: child ?? const SizedBox.shrink(),
          ),
          home: ReaderPage(
            source: FakeBookSource(),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: repo,
            aiStore: withAi ? store : null,
            aiClient: withAi ? client : null,
            vocabStore: withAi ? vocab : null,
          ),
        );

    testWidgets('① 长按出操作条；「取消选择」清选区', (tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // 三依赖齐备 + 开关开 → 手势层注册。
      expect(
        find.byKey(const Key('reader-selection-gesture')),
        findsOneWidget,
      );

      final TestGesture gesture = await _longPressGlyph(tester, '第1章正文2');
      expect(find.byType(SelectionActionBar), findsOneWidget);
      expect(find.text('翻译'), findsOneWidget);
      expect(find.text('释义'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      // 起手结束保留选区（操作条仍在）。
      expect(find.byType(SelectionActionBar), findsOneWidget);

      await tester.tap(find.byTooltip('取消选择'));
      await tester.pump();
      expect(find.byType(SelectionActionBar), findsNothing);
    });

    testWidgets('② 手势层：全局开关关 → 重建后不注册', (tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      expect(
        find.byKey(const Key('reader-selection-gesture')),
        findsOneWidget,
      );

      await tester.runAsync(() => store.setAiEnabled(false));
      // `_selectionEnabled` 在 build 期求值——重建 ReaderPage 元素即重新求值。
      tester.element(find.byType(ReaderPage)).markNeedsBuild();
      await tester.pump();
      expect(
        find.byKey(const Key('reader-selection-gesture')),
        findsNothing,
      );
    });

    testWidgets('② 手势层：三参数未注入 → 不注册，长按不出选区', (tester) async {
      await tester.pumpWidget(buildApp(withAi: false));
      await settle(tester);

      expect(
        find.byKey(const Key('reader-selection-gesture')),
        findsNothing,
      );

      // 无手势层：长按只剩滚动识别器参与 arena → 不产生选区与操作条。
      final TestGesture gesture = await _longPressGlyph(tester, '第1章正文2');
      await gesture.up();
      await tester.pump();
      expect(find.byType(SelectionActionBar), findsNothing);
    });

    testWidgets('③ 滚动起手清选区：操作条随滚动消失', (tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      final TestGesture gesture = await _longPressGlyph(tester, '第1章正文2');
      await gesture.up();
      await tester.pump();
      expect(find.byType(SelectionActionBar), findsOneWidget);

      // 起手点在操作条之外（视口中心），拖拽落到正文 → ScrollUpdate → 清选区。
      await tester.drag(find.byType(PagedScroller), const Offset(0, -240));
      await tester.pump();
      expect(find.byType(SelectionActionBar), findsNothing);
      // 只清选区，手势层不撤。
      expect(
        find.byKey(const Key('reader-selection-gesture')),
        findsOneWidget,
      );
    });

    testWidgets('④ 点「翻译」开面板：无配置给引导文案', (tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      final TestGesture gesture = await _longPressGlyph(tester, '第1章正文2');
      await gesture.up();
      await tester.pump();

      await tester.tap(find.text('翻译'));
      await tester.pumpAndSettle(); // 关档面板，无 spinner（同步出错态）

      expect(find.text('划词翻译'), findsOneWidget);
      expect(
        find.text('尚未配置 AI 服务：请先在「设置 → AI 服务」中添加配置并勾选用途'),
        findsOneWidget,
      );
    });
  });
}
