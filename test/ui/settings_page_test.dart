// `test/ui/settings_page_test.dart`：设置页验收映射（2026-09-29 改版 +
// 2026-10-19 上游顶栏批 + 2026-10-20 移除玻璃效果组）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 拍板口径 → 断言
// ══════════════════════════════════════════════════════════════════════════════
//   · ①卡片不透明             → 「外观」组用 [SettingsGroupCard]（Material 实心卡片）；
//   · ②顶栏 = 上游 [MiTopBar] → 受控折叠：`scrollOffset` 跟随滚动位移，大标题
//     淡出 / 紧凑标题淡入两段式（期望值取 [MiTopBarMetrics] 纯函数同源计算）；
//   · 内容区顶部渐进模糊       → 顶栏材质自带（`showBlur` 内部复用 [MiGradientBlur]）
//     ——上游设计：磨砂本体属于内容区，页面不单独叠模糊层；
//   · 顶部让位                 → 滚动容器 `padding.top == MiTopBarMetrics.contentTopInset`
//     （上游「我的」页同款 183；丢了它大标题区会被内容顶穿）；
//   · ③「外观」组             → 主题三态写入 `SettingsStore` 并原子落盘（`TYP-03`）；
//   · ④「玻璃效果」组**已移除** → 效果质量 / 降低视觉特效两行不再出现（2026-10-20
//     负责人口径；档位能力仍在 `GlassRuntime`，只是没有 UI 入口）。
//
// 2026-09-29 拍板④的搜索占位已随顶栏批移除（上游「我的」页顶栏无搜索头部），
// 其「只给轻提示、不进搜索态」的用例随之退场。
//
// ══════════════════════════════════════════════════════════════════════════════
// 两条测试口径（沿用既有测试的既定做法）
// ══════════════════════════════════════════════════════════════════════════════
// 1. **宿主钉「关」档**（`glass_off_fallback_test.dart` 的 `host(tier, …)` 同款）：
//    玻璃档的 `GlassDialog` / `GlassSheet` 在 `flutter test` 软件光栅下每帧数百 ms 真实
//    异步开销（tech-usage §2.26），故**需要弹层交互的用例一律在关档跑**——关档退化走
//    Material 底部弹窗，既便宜又恰好覆盖 `UI-06` ② 的退化路径。
// 2. **顶栏是 mi_like_ui 移植体、不感知档位**（与书架页 `MiSearchBar` /
//    `MiGradientBlur` 同口径）：磨砂由顶栏材质自带，关 / 高档都在场，
//    不做档位特判。
//
// ⚠️ `find.text('我的')` 在本页恒为 **2 个**：[MiTopBar] 的大标题与紧凑标题
//    同文案（组件设计如此，各包一层 [Opacity] 由滚动位移驱动此消彼长）。
//    需要精确定位时必须用 `find.descendant` 限定范围。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart'
    show MiGradientBlur, MiTopBar, MiTopBarMetrics;
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

/// 顶栏本体（上游 [MiTopBar] 受控组件）。
Finder _topBar() => find.byType(MiTopBar);

/// [MiTopBar] 内两条标题（大 / 紧凑）各自的 [Opacity] 包装，顺序 = 大、紧凑。
///
/// 组件设计：`title` 非 null 时两条 `Text` 同时在场、文案相同，各包一层
/// [Opacity]（`largeTitleOpacity` / `compactTitleOpacity` 驱动，此消彼长）。
/// 顶栏内部除这两层外没有任何 [Opacity]（磨砂走 `BackdropFilter`），
/// 故直接取顶栏内全部 [Opacity] 即得到这两层。
List<Opacity> _titleOpacities(WidgetTester tester) {
  final List<Opacity> opacities = tester.widgetList<Opacity>(
    find.descendant(of: _topBar(), matching: find.byType(Opacity)),
  ).toList();
  expect(
    opacities.length,
    2,
    reason: 'MiTopBar 两条标题必须各有一层 Opacity（两段式收起的驱动层）',
  );
  return opacities;
}

/// 本页滚动容器（[ListView]）的 [ScrollController]。
ScrollController _scrollOf(WidgetTester tester) {
  final ListView list = tester.widget<ListView>(find.byType(ListView));
  final ScrollController? controller = list.controller;
  expect(controller, isNotNull, reason: '设置页必须把控制器接到顶栏受控链上');
  expect(controller!.hasClients, isTrue);
  return controller;
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
  late SettingsStore settings;
  late ProviderStore aiStore;

  setUp(() async {
    // `setUp` 在 FakeAsync 之外，可照常 await（含真异步 IO）。
    tempDir = await Directory.systemTemp.createTemp('mreader_settings_');
    settings = SettingsStore(tempDir);
    aiStore = ProviderStore(
      tempDir,
      AiKeyVault(FileSecureStore(directory: tempDir)),
    );
    await settings.load();
    await aiStore.load();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget buildPage() => SettingsPage(
        settings: settings,
        aiStore: aiStore,
        aiClient: AiClient(),
      );

  group('设置页 · 顶栏 = 上游 MiTopBar', () {
    testWidgets('无旧玻璃壳层；顶栏钉顶、内容按 contentTopInset 让位（关 / 高档同款）',
        (WidgetTester tester) async {
      for (final GlassQualityTier tier in <GlassQualityTier>[
        GlassQualityTier.off,
        GlassQualityTier.high,
      ]) {
        await tester.pumpWidget(host(tier, buildPage()));
        await tester.pumpAndSettle();

        // ① 旧玻璃壳层体系整组退场（Scaffold / AppBar / 大标题 sliver / 不透明容器）。
        expect(find.byType(Scaffold), findsNothing, reason: '$tier');
        expect(find.byType(AppBar), findsNothing, reason: '$tier');
        expect(find.byType(GlassNavScaffold), findsNothing, reason: '$tier');
        expect(find.byType(GlassTopBar), findsNothing, reason: '$tier');
        expect(find.byType(GlassLargeTitle), findsNothing, reason: '$tier');
        expect(find.byType(OpaqueContentSurface), findsNothing, reason: '$tier');

        // ② 顶栏 = 上游移植体，且**不感知档位**（材质自带磨砂 + 压色）。
        final MiTopBar bar = tester.widget<MiTopBar>(_topBar());
        expect(bar.title, '我的');
        expect(bar.showBlur, isTrue, reason: '磨砂由顶栏材质自带（$tier）');
        expect(bar.showSurface, isTrue, reason: '大标题形态需要压色保证可读（$tier）');
        expect(bar.showBack, isFalse, reason: '顶层页无返回圆钮（$tier）');
        expect(
          find.descendant(of: _topBar(), matching: find.byType(MiGradientBlur)),
          findsOneWidget,
          reason: '内容区顶部渐进模糊必须由顶栏材质产出（$tier）',
        );

        // ③ 顶栏钉在屏顶（非定位子级会让 Stack 按它收缩、整页垂直居中）。
        expect(tester.getTopLeft(_topBar()).dy, 0.0, reason: '$tier');

        // ④ 滚动内容让位 = 上游实测 contentTopInset。
        final ListView list = tester.widget<ListView>(find.byType(ListView));
        expect(
          (list.padding as EdgeInsets).top,
          MiTopBarMetrics.contentTopInset,
          reason: '$tier',
        );
      }
    });

    testWidgets('大标题两段式：受控 scrollOffset 驱动大标题淡出、紧凑标题随后淡入',
        (WidgetTester tester) async {
      // 视口调小才有滚动余量（内容天然不足一屏）。
      // **必须同时钉 `devicePixelRatio = 1`**：默认 3 会把逻辑高度算成 1/3，
      // 「是否可滚动」的结论完全反过来（两级 MEMORY 已记此坑）。
      tester.view.physicalSize = const Size(400, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      // 首帧：大标题全显、紧凑标题全隐（两段式不重叠）。
      List<Opacity> opacities = _titleOpacities(tester);
      expect(opacities[0].opacity, 1.0);
      expect(opacities[1].opacity, 0.0);
      expect(tester.widget<MiTopBar>(_topBar()).scrollOffset, 0.0);

      final ScrollController scroll = _scrollOf(tester);
      // 真有滚动余量（否则下面的断言全是假绿）。
      expect(
        scroll.position.maxScrollExtent,
        greaterThan(MiTopBarMetrics.collapsedOffset),
      );

      // 中间态（10dp）：大标题衰减中、紧凑标题**还没起步**。
      scroll.jumpTo(10);
      await tester.pump();
      expect(
        tester.widget<MiTopBar>(_topBar()).scrollOffset,
        10.0,
        reason: '受控链：ScrollController 位移必须喂到顶栏 scrollOffset',
      );
      opacities = _titleOpacities(tester);
      expect(opacities[0].opacity, MiTopBarMetrics.largeTitleOpacity(10));
      expect(opacities[0].opacity, greaterThan(0.0));
      expect(opacities[0].opacity, lessThan(1.0));
      expect(opacities[1].opacity, 0.0, reason: '大标题归零前紧凑标题不得淡入');

      // 折叠完成位移之后：大标题归零、紧凑标题全显。
      scroll.jumpTo(MiTopBarMetrics.collapsedOffset + 5);
      await tester.pump();
      opacities = _titleOpacities(tester);
      expect(opacities[0].opacity, 0.0);
      expect(opacities[1].opacity, 1.0);
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

  group('设置页 · 「玻璃效果」组已移除（2026-10-20 负责人口径）', () {
    testWidgets('效果质量 / 降低视觉特效两行不再出现，页面无开关残留',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      // 分组标题与两行全不在场（改动前这三条都会红）。
      expect(find.text('玻璃效果'), findsNothing);
      expect(find.text('效果质量'), findsNothing);
      expect(find.text('降低视觉特效'), findsNothing);

      // 本页唯一的开关（降低视觉特效）已随组移除——不留孤立的 Switch。
      expect(find.byType(Switch), findsNothing);
    });
  });

  group('设置页 · 统计入口（2026-10-15 统计移出底栏）', () {
    testWidgets('接线时渲染「阅读统计」行，点击触发回调',
        (WidgetTester tester) async {
      var opened = 0;
      await tester.pumpWidget(host(
        GlassQualityTier.off,
        SettingsPage(
          settings: settings,
          aiStore: aiStore,
          aiClient: AiClient(),
          onOpenStats: () => opened += 1,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('阅读统计'), findsOneWidget);
      await tester.tap(_tile('阅读统计'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('未接线（null）时入口整体隐藏（同款降级口径）',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      expect(find.text('阅读统计'), findsNothing);
      expect(find.text('统计'), findsNothing);
    });
  });
}
