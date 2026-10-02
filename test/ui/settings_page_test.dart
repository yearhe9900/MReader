// `test/ui/settings_page_test.dart`：设置页 2026-09-29 改版的验收映射。
//
// ══════════════════════════════════════════════════════════════════════════════
// 本批拍板口径 → 断言
// ══════════════════════════════════════════════════════════════════════════════
//   · ①卡片不透明             → 「外观」「玻璃效果」两组用 [SettingsGroupCard]（Material 实心卡片）；
//   · ②内容层大标题（两段式） → 大标题与顶栏标题**共用同一个** `GlassLargeTitleController`；
//     首帧顶栏标题不可见，滚到底完全可见；前半段（progress < 0.5）恒不可见；
//   · ③「外观」组             → 主题三态写入 `SettingsStore` 并原子落盘（`TYP-03`）；
//   · ④搜索框只做占位         → 点击只给轻提示，不出现任何输入框 / 结果列表。
//
// ══════════════════════════════════════════════════════════════════════════════
// 两条测试口径（沿用既有测试的既定做法）
// ══════════════════════════════════════════════════════════════════════════════
// 1. **宿主钉「关」档**（`glass_off_fallback_test.dart` 的 `host(tier, …)` 同款）：
//    玻璃档的 `GlassDialog` / `GlassSheet` 在 `flutter test` 软件光栅下每帧数百 ms 真实
//    异步开销（tech-usage §2.26），故**需要弹层交互的用例一律在关档跑**——关档退化走
//    Material 底部弹窗，既便宜又恰好覆盖 `UI-06` ② 的退化路径。玻璃档只做「在场 +
//    控制器同一实例」的静态断言，不弹层。
// 2. **大标题在关档同样在场**：`GlassLargeTitle` 只画 `Text` + `Transform.scale`
//    （`glass_large_title.dart:398-458`，**零玻璃质感**），是布局 / 动画组件而非质感组件，
//    故不违反 `UI-06` ② 的「纯色退化」。本文件把这条口径**显式断言**下来，
//    免得后人以为它是漏网之鱼。
//
// ⚠️ `find.text('设置')` 在本页恒为 **2 个**：内容层大标题 + 顶栏标题（两者文案相同，
//    库文档要求如此）。需要精确定位时必须用 `find.descendant` 限定范围。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/settings_kit.dart';
import 'package:mreader/ui/settings_page.dart';

import '../test_config.dart';

/// 钉档宿主：[MaterialApp] + [GlassScopeProvider]（`config` 覆盖 = 测试钉档）。
Widget host(GlassQualityTier tier, Widget home) {
  return MaterialApp(
    home: GlassScopeProvider(
      config: glassTierConfigFor(tier),
      child: home,
    ),
  );
}

/// 让 widget 内发起的**真异步 IO** 完成，并推进若干帧。
///
/// `testWidgets` 的测试体在 FakeAsync 区：偏好写入（`JsonStore` → `AtomicFile`）落到
/// 真文件系统，其完成回调排进 fake 队列、不会自行推进。`runAsync` 让出到真实事件循环
/// 排空 IO，`pump` 排空 fake 队列——两者必须交替（同 `shelf_page_test.dart`）。
Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// 内容层大标题的控制器（库要求它与顶栏标题共用同一实例）。
GlassLargeTitleController _titleControllerOf(WidgetTester tester) =>
    tester.widget<GlassLargeTitle>(find.byType(GlassLargeTitle)).controller;

/// 顶栏（[AppBar]）里那条「设置」标题。
Finder _barTitle() => find.descendant(
      of: find.byType(AppBar),
      matching: find.text('设置'),
    );

/// 顶栏标题当前的淡入不透明度。
///
/// 取**最近的** [Opacity] 祖先：我们的 `_fadeInBarTitle` 是包在标题外的那一层，
/// 且其 `child` 就是标题本身——故最近的 `Opacity` 必定是它
/// （`find.ancestor` 按「由近及远」返回，见 flutter_test `_AncestorWidgetFinder`）。
double _barTitleOpacity(WidgetTester tester) {
  final Finder barTitle = _barTitle();
  expect(barTitle, findsOneWidget);
  final Iterable<Opacity> opacities = tester.widgetList<Opacity>(
    find.ancestor(of: barTitle, matching: find.byType(Opacity)),
  );
  expect(opacities, isNotEmpty, reason: '顶栏标题必须由淡入包装（关档路径需自补）');
  return opacities.first.opacity;
}

/// 某一行的 [SettingsTile]（按行标题文本定位）。
Finder _tile(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(SettingsTile),
    );

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  late Directory tempDir;
  late PerfPrefsStore perfPrefs;
  late SettingsStore settings;
  late ProviderStore aiStore;

  setUp(() async {
    // `setUp` 在 FakeAsync 之外，可照常 await（含真异步 IO）。
    tempDir = await Directory.systemTemp.createTemp('mreader_settings_');
    perfPrefs = PerfPrefsStore(tempDir);
    settings = SettingsStore(tempDir);
    aiStore = ProviderStore(
      tempDir,
      AiKeyVault(FileSecureStore(directory: tempDir)),
    );
    await perfPrefs.load();
    await settings.load();
    await aiStore.load();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget buildPage() => SettingsPage(
        perfPrefs: perfPrefs,
        settings: settings,
        aiStore: aiStore,
        aiClient: AiClient(),
      );

  group('设置页 · 壳层与档位退化', () {
    testWidgets('关档：壳层 / 顶栏走 Material，大标题仍在场（UI-06 ②）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      // 壳层与顶栏退化（同 `glass_off_fallback_test.dart` 的关档断言）。
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(GlassScaffold), findsNothing);
      expect(find.byType(GlassAppBar), findsNothing);

      // 大标题**在场**：它是布局 / 动画组件（只画文本与 Transform.scale），
      // 不是玻璃质感组件——关档的「纯色退化」不受影响（见文件头口径 2）。
      expect(find.byType(GlassLargeTitle), findsOneWidget);

      // 内容层不透明容器仍在（`UI-04` 红线的唯一出口）。
      expect(find.byType(OpaqueContentSurface), findsOneWidget);
    });

    testWidgets('高档：玻璃壳层在场，顶栏与大标题共用同一控制器实例',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.high, buildPage()));
      await tester.pumpAndSettle();

      expect(find.byType(GlassScaffold), findsOneWidget);
      expect(find.byType(GlassAppBar), findsOneWidget);

      // 硬要求（库 `glass_large_title.dart:53-173`）：大标题与顶栏标题必须订阅
      // **同一个**控制器，否则两段式收起各走各的、标题会重叠或闪跳。
      final GlassLargeTitle largeTitle =
          tester.widget<GlassLargeTitle>(find.byType(GlassLargeTitle));
      final GlassAppBar bar =
          tester.widget<GlassAppBar>(find.byType(GlassAppBar));
      expect(bar.largeTitleController, isNotNull);
      expect(bar.largeTitleController, same(largeTitle.controller));
    });
  });

  group('设置页 · 大标题两段式收起', () {
    testWidgets('首帧：内容层与顶栏各有一条「设置」，顶栏标题不可见',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      // 两条「设置」= 大标题 + 顶栏标题（同文案是库的设计）。
      expect(find.text('设置'), findsNWidgets(2));
      expect(find.byType(GlassLargeTitle), findsOneWidget);

      // 首帧进度为 0 → 顶栏标题必须不可见（只靠位置不靠透明度会「两条同时可见」）。
      final GlassLargeTitleController controller = _titleControllerOf(tester);
      expect(controller.collapseProgress, 0.0);
      expect(_barTitleOpacity(tester), 0.0);
    });

    testWidgets('滚动：前半段顶栏标题仍不可见，滚到底完全可见',
        (WidgetTester tester) async {
      // 视口调小才有滚动余量（内容天然不足一屏）。
      // **必须同时钉 `devicePixelRatio = 1`**：默认 3 会把逻辑高度算成 1/3，
      // 「是否可滚动」的结论完全反过来（两级 MEMORY 已记此坑）。
      tester.view.physicalSize = const Size(400, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      final GlassLargeTitleController controller = _titleControllerOf(tester);
      final ScrollController scroll = controller.scrollController;
      expect(scroll.hasClients, isTrue);
      // 内容高约 500、正文视口约 316 → 确有滚动余量（否则下面的断言全是假绿）。
      expect(scroll.position.maxScrollExtent, greaterThan(50));

      // 前半段：进度已 > 0（确实在收起）但未过 0.5 → 顶栏标题**恒不可见**。
      scroll.jumpTo(10);
      await tester.pump();
      expect(controller.collapseProgress, greaterThan(0.0));
      expect(controller.collapseProgress, lessThan(0.5));
      expect(_barTitleOpacity(tester), 0.0);

      // 一路滚到底（拖拽量远大于总滚动余量 → 偏移被钳到 maxScrollExtent，
      // 必然越过完整收起距离，与标定出的标题高度无关）。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(controller.collapseProgress, 1.0);
      expect(_barTitleOpacity(tester), 1.0);
    });
  });

  group('设置页 · 「外观」组（主题三态）', () {
    testWidgets('默认跟随系统；弹层选「夜间」写入设置并落盘（TYP-03）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      // 行与当前值。
      expect(_tile('主题模式'), findsOneWidget);
      expect(find.text('跟随系统'), findsOneWidget);

      // 点行 → 关档退化为 Material 底部弹窗（`UI-06` ②）。
      await tester.tap(_tile('主题模式'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      // 三个候选项（顺序 = 枚举声明顺序：日间 / 夜间 / 跟随系统）。
      expect(find.text('日间'), findsOneWidget);
      expect(find.text('夜间'), findsOneWidget);

      await tester.tap(find.text('夜间'));
      await tester.pumpAndSettle();
      await _settle(tester); // 写入是真异步 IO（`JsonStore` → `AtomicFile`）

      // 内存状态 + 行回显（行文案从此只剩一个「夜间」——弹层已关）。
      expect(settings.settings.themeMode, AppThemeMode.dark);
      expect(find.text('夜间'), findsOneWidget);
      expect(find.text('跟随系统'), findsNothing);

      // 落盘校验（`DATA-01` 原子写入的实际结果，不是只看内存）。
      final String raw = await tester.runAsync(
            () => File('${tempDir.path}${Platform.pathSeparator}settings.json')
                .readAsString(),
          ) ??
          '';
      expect(raw, contains('"themeMode":"dark"'));
    });

    testWidgets('弹层取消（点遮罩）不改动设置', (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      await tester.tap(_tile('主题模式'));
      await tester.pumpAndSettle();
      // 点遮罩关闭（关档的 Material 弹窗默认可点遮罩关闭）。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(settings.settings.themeMode, AppThemeMode.system);
      expect(find.text('跟随系统'), findsOneWidget);
    });
  });

  group('设置页 · 「玻璃效果」组', () {
    testWidgets('两行在场：效果质量显示当前档位，脚注为生效档位说明',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      expect(find.text('玻璃效果'), findsOneWidget);
      expect(find.text('效果质量'), findsOneWidget);
      expect(find.text('降低视觉特效'), findsOneWidget);

      // 默认高档：行右侧显示档位名，脚注是**生效档位**的说明（高 = 用户档位）。
      expect(tester.widget<SettingsTile>(_tile('效果质量')).value, '高');
      expect(
        find.textContaining('顶栏 / 底栏 premium（自动提升）'),
        findsOneWidget,
      );
    });

    testWidgets('弹层选「中」→ 写入偏好并回显', (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      await tester.tap(_tile('效果质量'));
      await tester.pumpAndSettle();
      // 四个候选项（高 / 中 / 低 / 关），描述取档位配置摘要。
      expect(find.text('中'), findsOneWidget);
      expect(find.textContaining('省掉 premium 着色器开销'), findsOneWidget);

      await tester.tap(find.text('中'));
      await tester.pumpAndSettle();
      await _settle(tester);

      expect(perfPrefs.prefs.glassTier, GlassQualityTier.medium);
      expect(tester.widget<SettingsTile>(_tile('效果质量')).value, '中');

      final String raw = await tester.runAsync(
            () => File('${tempDir.path}${Platform.pathSeparator}perf_prefs.json')
                .readAsString(),
          ) ??
          '';
      expect(raw, contains('"glassTier":"medium"'));
    });

    testWidgets('降低视觉特效：点整行即切换，脚注追加钳制说明（UI-05 ③）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      // 默认关：脚注只有生效档位说明。
      expect(perfPrefs.prefs.reduceVisualEffects, isFalse);
      expect(find.textContaining('已按「降低视觉特效」钳制'), findsNothing);

      // 整行可点（触控面积大于开关本体），开关同步反映状态。
      await tester.tap(_tile('降低视觉特效'));
      await tester.pumpAndSettle();
      await _settle(tester);

      expect(perfPrefs.prefs.reduceVisualEffects, isTrue);
      expect(
        tester
            .widget<Switch>(find.descendant(
              of: _tile('降低视觉特效'),
              matching: find.byType(Switch),
            ))
            .value,
        isTrue,
      );
      // 生效档位被钳到低档：脚注说明 + 保留「所选档位」。
      expect(find.textContaining('全部 minimal'), findsWidgets);
      expect(
        find.textContaining('已按「降低视觉特效」钳制，所选档位：高'),
        findsOneWidget,
      );
    });

    testWidgets('关档下「降低视觉特效」行置灰且不可点', (WidgetTester tester) async {
      // 用户档位先落成「关」（`runAsync` 让真异步写入得以完成）。
      await tester.runAsync(
        () => perfPrefs.setGlassTier(GlassQualityTier.off),
      );

      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      final Finder row = _tile('降低视觉特效');
      expect(tester.widget<SettingsTile>(row).enabled, isFalse);
      // 开关与整行同时禁用（两个入口一致，不留半禁用状态）。
      expect(
        tester
            .widget<Switch>(find.descendant(
              of: row,
              matching: find.byType(Switch),
            ))
            .onChanged,
        isNull,
      );

      await tester.tap(row, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(perfPrefs.prefs.reduceVisualEffects, isFalse);
    });
  });

  group('设置页 · 搜索框占位', () {
    testWidgets('点击只给轻提示，不进入任何搜索态（本批不实现搜索）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      expect(find.text('搜索系统设置项'), findsOneWidget);
      // 只是占位：不得有任何真实输入框。
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text('搜索系统设置项'));
      await tester.pumpAndSettle();

      // 明确的「未实现」提示（不是静默无反应，也不是假结果列表）。
      expect(find.text('设置搜索尚未实现'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      // 轻提示 2s 后自动消失；把时钟推过去，免得留下 pending Timer。
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('设置搜索尚未实现'), findsNothing);
    });
  });
}
