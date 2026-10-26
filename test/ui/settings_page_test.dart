// `test/ui/settings_page_test.dart`：设置页验收映射。
//
// 拍板口径 → 断言：
//   · ①卡片不透明             → 「外观」组用 [SettingsGroupCard]（Material 实心卡片）；
//   · ②顶栏 = 上游 [MiTopBar] → 受控折叠：`scrollOffset` 跟随滚动位移，大标题淡出 /
//     紧凑标题淡入两段式（期望值取 [MiTopBarMetrics] 纯函数同源计算）；
//   · 内容区顶部渐进模糊       → 顶栏材质自带（`showBlur` 内部复用 [MiGradientBlur]）；
//   · 顶部让位                 → 滚动容器 `padding.top == MiTopBarMetrics.contentTopInset`
//     （丢了它大标题区会被内容顶穿）；
//   · ③「外观」组             → 主题三态写入 `SettingsStore` 并原子落盘（`TYP-03`）；
//   · ④「玻璃效果」组**已移除** → 效果质量 / 降低视觉特效两行不再出现（档位能力仍在
//     `GlassRuntime`，只是没有 UI 入口）；
//   · ⑤「我的」页样式对齐上游（2026-10-27 拍板「全跟上游」）→ Mi 页底色、compact
//     页边距 11.9、卡片 #FFFFFF/#1E1E1E 圆角 20、行 56 / 图标块 38×38 r10、
//     主文案 16/w400、行尾 ForwardChevronIconPainter、按压整行高亮带 120ms。
//
// 两条测试口径：
// 1. **宿主钉「关」档**（`glass_off_fallback_test.dart` 的 `host(tier, …)` 同款）：玻璃档
//    在 `flutter test` 软件光栅下每帧数百 ms 真实开销（§2.26），用例一律在关档跑降耗。
//    选择弹框载体已换 mi_like_ui [MiDialog]（2026-10-27，档位无关、非玻璃），
//    关档宿主同时继续覆盖其余退化路径。
// 2. **顶栏是 mi_like_ui 移植体、不感知档位**：磨砂由顶栏材质自带，关 / 高档都在场，
//    不做档位特判。
//
// ⚠️ `find.text('我的')` 在本页恒为 **2 个**（[MiTopBar] 大标题与紧凑标题同文案、
// 各包一层 [Opacity] 此消彼长），精确定位必须用 `find.descendant` 限定范围。
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
    show
        ForwardChevronIconPainter,
        MiDialog,
        MiGradientBlur,
        MiTopBar,
        MiTopBarMetrics;
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

/// 让 widget 内发起的**真异步 IO** 完成并推进若干帧。
///
/// ⚠️ FakeAsync 区里偏好写入（`JsonStore` → `AtomicFile`）的完成回调排进 fake 队列不会
/// 自行推进——`runAsync` 让出真事件循环与 `pump` **必须交替**（同 `shelf_page_test.dart`）。
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
/// `title` 非 null 时两条 `Text` 同文案同时在场、各包一层 [Opacity]（`largeTitleOpacity`
/// / `compactTitleOpacity` 驱动，此消彼长）；顶栏内部除这两层外没有别的 [Opacity]
/// （磨砂走 `BackdropFilter`），故直接取顶栏内全部 [Opacity] 即得到这两层。
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
      // 视口调小才有滚动余量（内容天然不足一屏）。**必须同时钉 `devicePixelRatio = 1`**：
      // 默认 3 会把逻辑高度算成 1/3，「是否可滚动」的结论完全反过来。
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

      // 点行 → mi_like_ui [MiDialog] 单选弹框（与书架长按弹框同款；档位无关）。
      await tester.tap(_tile('主题模式'));
      await tester.pumpAndSettle();
      expect(find.byType(MiDialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing, reason: '旧玻璃底部弹窗载体已退场');
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
      // 点遮罩关闭（MiDialog 自绘遮罩，onScrimTap pop 无值）。
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

      // 分组标题与两行全不在场。
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

  group('设置页 · 「我的」页样式对齐上游（2026-10-27 拍板「全跟上游」）', () {
    testWidgets('compact 档：页底 = Mi 页底色、页边距 11.9、卡片亮 #FFFFFF 圆角 20', (
      WidgetTester tester,
    ) async {
      // compact 档（宽 < 600）才有素材度量边距 11.9（默认 800 宽是 medium 档 → 32）。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      // ① 页底 = Mi 页底色（亮 #F3F3F3）：上游卡片色 #FFFFFF/#1E1E1E 依赖它才有对比。
      final ColoredBox page = tester.widget<ColoredBox>(
        find.byKey(const ValueKey<String>('settings-page-background')),
      );
      expect(
        page.color,
        const Color(0xFFF3F3F3),
        reason: '页底须为 Mi 页底色，不能再用近白的 M3 surface',
      );

      // ② 页边距 = 上游手机档 11.9（卡片列左缘）。
      expect(
        tester.getTopLeft(find.byType(SettingsGroupCard).first).dx,
        moreOrLessEquals(11.9, epsilon: 0.01),
      );

      // ③ 卡片：亮 #FFFFFF、圆角 20（读渲染用的 Material，不是回来引用常量）。
      final Material card = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(SettingsGroupCard).first,
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.color, const Color(0xFFFFFFFF));
      expect(card.borderRadius, BorderRadius.circular(20));
    });

    testWidgets('行几何与排版：无副标题行 56 高、图标块 38×38 r10、主文案 16/w400、值 14、前进箭头', (
      WidgetTester tester,
    ) async {
      // 裸行 harness：本页的行**都带副标题**（副标题行随内容增高是上游设计），
      // 行最小高 56 的契约只能在无副标题的行上量。
      await tester.pumpWidget(
        MaterialApp(
          home: GlassScopeProvider(
            config: glassTierConfigFor(GlassQualityTier.off),
            child: ColoredBox(
              color: const Color(0xFFF3F3F3),
              child: SettingsGroupCard(
                children: <Widget>[
                  SettingsTile(
                    icon: Icons.wifi,
                    accent: SettingsAccents.blue,
                    title: '行标题',
                    value: '值',
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder row = find.byType(SettingsTile);

      // 行高 = 上游 56（无副标题时 padding 垂直 0，高度由 minHeight 给定）。
      expect(tester.getSize(row).height, moreOrLessEquals(56, epsilon: 0.01));

      // 前导图标块 38×38、圆角 10（图标本身 22 白色字形）。
      // 定位口径：行内**最后一个 [Container]** —— 行首那个全宽 Container 是
      // `AnimatedContainer` 自己 build 出来的（高亮带层），图标块是更内层的
      // 那个（Row 子序第一、渲染树更深）。
      final Finder tileInRow = find
          .descendant(of: row, matching: find.byType(Container))
          .last;
      final Size tile = tester.getSize(tileInRow);
      expect(tile.width, moreOrLessEquals(38, epsilon: 0.01));
      expect(tile.height, moreOrLessEquals(38, epsilon: 0.01));
      final BoxDecoration tileDeco =
          (tileInRow.evaluate().single.widget as Container).decoration!
              as BoxDecoration;
      expect(tileDeco.borderRadius, BorderRadius.circular(10));

      // 文案排版（上游口径：主 16/w400、值 14）。
      final Text label = tester.widget<Text>(find.text('行标题'));
      expect(label.style!.fontSize, 16);
      expect(label.style!.fontWeight, FontWeight.w400);
      final Text value = tester.widget<Text>(find.text('值'));
      expect(value.style!.fontSize, 14);

      // 行尾饰 = 前进箭头 painter（上游 `5fb8199` 修正：不是顶栏返回箭头、
      // 也不是 Material 自带的 chevron 图标）。
      final Iterable<CustomPaint> paints = tester.widgetList<CustomPaint>(
        find.descendant(of: row, matching: find.byType(CustomPaint)),
      );
      expect(
        paints.any((CustomPaint p) => p.painter is ForwardChevronIconPainter),
        isTrue,
        reason: '行尾饰须为 ForwardChevronIconPainter（›），回潮 Icons.chevron_right 即红',
      );
      expect(
        find.descendant(of: row, matching: find.byType(Icon)),
        findsOneWidget,
        reason: '行内只剩前导图标块的 Icon（箭头不再是 Icon）',
      );
    });

    testWidgets('按压：整行满铺高亮带（亮 #E7E7E7），松开 120ms 渐隐', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(GlassQualityTier.off, buildPage()));
      await tester.pumpAndSettle();

      final Finder row = _tile('主题模式');
      Color bandColor() =>
          (tester.widget<AnimatedContainer>(
                    find.descendant(
                      of: row,
                      matching: find.byType(AnimatedContainer),
                    ),
                  ).decoration!
              as BoxDecoration)
              .color!;

      expect(bandColor(), Colors.transparent, reason: '静止态高亮带透明');

      // 按下：高亮带立刻切到压色（AnimatedContainer 120ms 渐变过去）。
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(row),
      );
      await tester.pump();
      expect(
        bandColor(),
        const Color(0xFFE7E7E7),
        reason: '按压高亮带须为上游亮色压色 #E7E7E7（整行满铺，非 InkWell 水波纹）',
      );

      // 松开：120ms 后回透明（渐隐完成）。
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 120));
      expect(bandColor(), Colors.transparent);
      // 回调照常触发（换反馈形式不得改点击语义）。
      // 「主题模式」点行弹选择弹框——MiDialog 在场即证明 onTap 未丢。
      expect(find.byType(MiDialog), findsOneWidget);
    });

    testWidgets('暗色：卡片 #1E1E1E、按压带 #3A3A3A、页底纯黑（上游暗色目测值）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: GlassScopeProvider(
            config: glassTierConfigFor(GlassQualityTier.off),
            child: buildPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Material card = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(SettingsGroupCard).first,
              matching: find.byType(Material),
            )
            .first,
      );
      expect(card.color, const Color(0xFF1E1E1E));

      final ColoredBox page = tester.widget<ColoredBox>(
        find.byKey(const ValueKey<String>('settings-page-background')),
      );
      expect(page.color, const Color(0xFF000000));

      final Finder row = _tile('主题模式');
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(row),
      );
      await tester.pump();
      expect(
        (tester.widget<AnimatedContainer>(
                  find.descendant(
                    of: row,
                    matching: find.byType(AnimatedContainer),
                  ),
                ).decoration!
            as BoxDecoration)
            .color,
        const Color(0xFF3A3A3A),
      );
      await gesture.up();
    });
  });
}
