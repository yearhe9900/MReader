// `M2b-T07`：档位生效接线的**验收映射**测试（`UI-05` ③ / `UI-06` ②）。
//
// ⚠️ **2026-10-12：本文件只覆盖「库玻璃」那条线**。产品窄屏底栏已换成自研
// [FrostedNavBar]（磨砂伪玻璃，不经`GlassTabBar`），其契约测试见
// `test/ui/frosted_nav_bar_test.dart`。本文件保留的原因：`GlassNavBar` 仍在库
// 里且仍被 `glass_nav_form_test` / `glass_material_test` 覆盖，删掉会让库的
// 档位链失去唯一防线。**真机若见到底栏不随档位变化，以`frosted_nav_bar_test`
// 为准**（自研底栏不依赖着色器，档位只影响「关档退化」这一件事）。
//
// PRD 验收条目 → 断言：
//   · `UI-06` ②「关闭特效后 UI 仍完整可用（退化为纯色）」→ 关档下无任何玻璃控件
//     （GlassScaffold / GlassAppBar / GlassTabBar / GlassDialog / GlassSheet），
//     Material 全家桶（Scaffold / AppBar / NavigationBar / AlertDialog / BottomSheet）在场；
//   · `UI-05` ③「降低视觉特效强制 minimal」→ 低档 [GlassIsolationScope.defaultQuality]
//     与 [GlassTabBar.quality] 均为 minimal；
//   · 中档钉 `standard`（取消 premium 提升）；高档不覆盖（`null`，交库自动提升）。
//
// 玻璃档的 GlassDialog / GlassSheet 弹层**不在此渲染**——flutter test 软件光栅下
// 每帧数百 ms 真实异步开销（tech-usage §2.26）；关档退化弹层是纯 Material，可测。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../test_config.dart';

/// 两个最小标签页（[GlassTab] 至少要有 icon 或 label；标签文案避开标题「书架」，
/// 防 `find.text` 撞车）。
const List<GlassTab> kTabs = <GlassTab>[
  GlassTab(icon: Icon(Icons.list), label: '目录'),
  GlassTab(icon: Icon(Icons.settings), label: '设置'),
];

/// 钉档宿主：[MaterialApp] + [GlassScopeProvider]（`config` 覆盖 = 测试钉档）。
Widget host(GlassQualityTier tier, Widget home) {
  return MaterialApp(
    home: GlassScopeProvider(
      config: glassTierConfigFor(tier),
      child: home,
    ),
  );
}

/// [GlassTopBar] 内**本项目加的**固定表面钉档作用域。
///
/// 双重限定（「GlassTopBar 后代」∩「GlassAppBar 祖先」）防撞玻璃库内部
/// 同类型作用域（如 `GlassScaffold` 给条面包的 premium 提示层）。
Finder pinnedScope() => find.descendant(
      of: find.byType(GlassTopBar),
      matching: find.ancestor(
        of: find.byType(GlassAppBar),
        matching: find.byType(GlassIsolationScope),
      ),
    );

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  testWidgets('关档：导航壳层退化为 Material 纯色（UI-06 ②）', (WidgetTester tester) async {
    await tester.pumpWidget(host(
      GlassQualityTier.off,
      GlassNavScaffold(
        appBar: const GlassTopBar(title: Text('书架')),
        bottomBar: GlassNavBar(
          tabs: kTabs,
          selectedIndex: 0,
          onTabSelected: (_) {},
        ),
        body: const SizedBox.expand(),
      ),
    ));

    // 推演：off → 壳层换 Material Scaffold、顶栏 AppBar、底栏 NavigationBar；
    // 全树不得出现任何玻璃控件；标题照常渲染（功能完整可用）。
    expect(find.byType(GlassScaffold), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(GlassAppBar), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(GlassTabBar), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('书架'), findsOneWidget);
  });

  testWidgets('高档：不覆盖固定表面（库自动提升 premium，UI-05 ①）', (WidgetTester tester) async {
    await tester.pumpWidget(host(
      GlassQualityTier.high,
      Scaffold(
        appBar: const GlassTopBar(title: Text('书架')),
        bottomNavigationBar: GlassNavBar(
          tabs: kTabs,
          selectedIndex: 0,
          onTabSelected: (_) {},
        ),
      ),
    ));

    // 推演：高档 fixedSurfaceQualityOverride = null → 不包钉档作用域
    // （GlassScaffold 提供的 premium 提示不受阻碍）；GlassTabBar.quality = null。
    expect(pinnedScope(), findsNothing);
    expect(
      tester.widget<GlassTabBar>(find.byType(GlassTabBar)).quality,
      isNull,
    );
  });

  testWidgets('中档：固定表面钉 standard（取消 premium 提升）', (WidgetTester tester) async {
    await tester.pumpWidget(host(
      GlassQualityTier.medium,
      Scaffold(
        appBar: const GlassTopBar(title: Text('书架')),
        bottomNavigationBar: GlassNavBar(
          tabs: kTabs,
          selectedIndex: 0,
          onTabSelected: (_) {},
        ),
      ),
    ));

    // 推演：中档 override = standard → 钉档作用域 defaultQuality = standard
    // （最近作用域压过 GlassScaffold 内层 premium 提示）；GlassTabBar.quality
    // = standard。
    expect(pinnedScope(), findsOneWidget);
    expect(
      tester.widget<GlassIsolationScope>(pinnedScope()).defaultQuality,
      GlassQuality.standard,
    );
    expect(
      tester.widget<GlassTabBar>(find.byType(GlassTabBar)).quality,
      GlassQuality.standard,
    );
  });

  testWidgets('低档：全部 minimal（UI-05 ③ 降低视觉特效）', (WidgetTester tester) async {
    await tester.pumpWidget(host(
      GlassQualityTier.low,
      Scaffold(
        appBar: const GlassTopBar(title: Text('书架')),
        bottomNavigationBar: GlassNavBar(
          tabs: kTabs,
          selectedIndex: 0,
          onTabSelected: (_) {},
        ),
      ),
    ));

    // 推演：低档 override = minimal → 钉档作用域与 GlassTabBar.quality 均 minimal。
    expect(
      tester.widget<GlassIsolationScope>(pinnedScope()).defaultQuality,
      GlassQuality.minimal,
    );
    expect(
      tester.widget<GlassTabBar>(find.byType(GlassTabBar)).quality,
      GlassQuality.minimal,
    );
  });

  testWidgets('玻璃档导航壳层 = GlassScaffold（玻璃永在正文之上）', (WidgetTester tester) async {
    await tester.pumpWidget(host(
      GlassQualityTier.high,
      const GlassNavScaffold(
        appBar: GlassTopBar(title: Text('书架')),
        body: SizedBox.expand(),
      ),
    ));

    // 推演：玻璃档壳层走 GlassScaffold（玻璃永远绘制在正文之上）；与关档互补。
    expect(find.byType(GlassScaffold), findsOneWidget);
  });

  testWidgets('关档：showAlert 退化为 AlertDialog（返回值语义同 showDialog）', (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(host(
      GlassQualityTier.off,
      Scaffold(
        body: Builder(
          builder: (BuildContext context) {
            ctx = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ));

    final Future<String?> future = GlassOverlays.showAlert<String>(
      context: ctx,
      title: '删除书籍',
      message: '确认删除《测试》？',
      actions: <GlassDialogAction>[
        GlassDialogAction(label: '删除', isDestructive: true, onPressed: () {}),
        GlassDialogAction(
          label: '取消',
          isPrimary: true,
          onPressed: () => Navigator.pop(ctx, 'cancel'),
        ),
      ],
    );
    await tester.pumpAndSettle();

    // 推演：关档走 showDialog + AlertDialog，无 GlassDialog；标题 / 动作照常渲染。
    expect(find.byType(GlassDialog), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('删除书籍'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 遮罩统一（2026-09-30 批）：关档确认框原先吃 Material `DialogRoute` 的默认
    // `super.barrierColor = Colors.black54`（`material/dialog.dart:1825`，
    // `0x8A000000`、**α0.541**）——正是 2026-09-29 已判为「太重」的那个值，
    // 当时只改了底部弹窗、**漏了确认框**。现与弹窗共用 `OverlayStyle.barrier`。
    // 断言读遮罩自己渲染出的色，不引用薄封装常量（与弹窗用例同口径）。
    final Animation<Color?> alertBarrierAnim = tester
        .widget<AnimatedModalBarrier>(find.byType(AnimatedModalBarrier))
        .color;
    expect(
      (alertBarrierAnim.value!.a * 255).round(),
      0x3D,
      reason: '关档确认框遮罩也须用统一色源（0x3D000000），不得吃 Material 默认的 0x8A000000',
    );

    // 返回值语义：动作回调里 Navigator.pop(ctx, value) → future 收到 value。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await future, 'cancel');
  });

  testWidgets('关档：showSheet 退化为 Material BottomSheet（无 GlassSheet）', (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(host(
      GlassQualityTier.off,
      Scaffold(
        body: Builder(
          builder: (BuildContext context) {
            ctx = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ));

    final Future<String?> future = GlassOverlays.showSheet<String>(
      context: ctx,
      isScrollable: false,
      builder: (BuildContext sheetContext) => TextButton(
        onPressed: () => Navigator.pop(sheetContext, 'closed'),
        child: const Text('关闭'),
      ),
    );
    await tester.pumpAndSettle();

    // 推演：关档走 showModalBottomSheet（BottomSheet 在树），内容照常渲染，无 GlassSheet。
    // 2026-09-29 拍板（`glass_kit.dart` `showSheet` 形态口径）：本项目弹层一律
    // **不可拖拽关闭、无拖拽指示条**，关档同步——原先那条自绘的 36×4 横条已删。
    expect(find.byType(GlassSheet), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).enableDrag,
      isFalse,
      reason: '关档弹层也必须禁止上划拖拽关闭（与玻璃档口径一致）',
    );
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.constraints?.maxHeight == 4 &&
              w.constraints?.maxWidth == 36,
        ),
      ),
      findsNothing,
      reason: '弹层不显示拖拽指示条',
    );
    expect(find.text('关闭'), findsOneWidget);

    // 遮罩色源（2026-09-29 修「长按书卡，在操作单出现之前先蒙一层灰」）：
    // `showModalBottomSheet` 的 `barrierColor` 默认 `Colors.black54`（= `0x8A000000`），
    // 与玻璃库默认**同一个值**——两档共用 `OverlayStyle.barrier`（`0x3D000000`）。
    // 断言读遮罩自己渲染出的色，不引用薄封装常量（与玻璃档用例同口径）。
    final Animation<Color?> barrierAnim = tester
        .widget<AnimatedModalBarrier>(find.byType(AnimatedModalBarrier))
        .color;
    expect(
      (barrierAnim.value!.a * 255).round(),
      0x3D,
      reason: '关档弹层遮罩也须用压淡后的色源（0x3D000000），不得吃 Material 默认的 0x8A000000',
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(await future, 'closed');
  });

  testWidgets('关档：showToast 退化为纯色浮层（不依赖 Material Scaffold）',
      (WidgetTester tester) async {
    late BuildContext ctx;
    // 故意**不放 `Scaffold`**：玻璃壳层（`GlassScaffold` → `CupertinoPageScaffold`）
    // 与窄屏浮动底栏布局本就没有 Material `Scaffold`，`showSnackBar` 会因
    // `_scaffolds` 为空断言失败 —— 轻提示必须走 Overlay。
    await tester.pumpWidget(host(
      GlassQualityTier.off,
      Builder(
        builder: (BuildContext context) {
          ctx = context;
          return const SizedBox.expand();
        },
      ),
    ));

    GlassOverlays.showToast(context: ctx, message: '已保存设置');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 推演：关档无玻璃 → 无 GlassToast；纯色浮层照常渲染文案。
    expect(find.byType(GlassToast), findsNothing);
    expect(find.text('已保存设置'), findsOneWidget);

    // 到时自动移除（计时器到点 → 移除 entry → 重建一帧）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('已保存设置'), findsNothing);
  });
}
