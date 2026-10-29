// `GlassNavBar`（导航层底栏）**触摸反馈口径**的契约测试。
//
// 背景：库 `GlassTabBar` 的 `interactionBehavior` 缺省是 **`GlassInteractionBehavior.full`**
// （方向光晕 + 物理弹簧缩放），`GlassNavBar` 原先**未透传**该参数 → 点击底栏整个胶囊会
// 膨胀。与 `showSheet` 未透传 `interactionScale`（§2.49）是**同一类坑**：薄封装没暴露的
// 库参数会以库默认值静默生效。现显式传 `glowOnly`（去形变、保留手指位置的柔和高光）。
//
// 两条测试口径（与 `glass_sheet_form_test.dart` 一致）：
// 1. 断言读**玻璃库 widget 自身字段**（`GlassTabBar.interactionBehavior`），期望值
//    **硬编码字面量**——不引用薄封装暴露的常量（同义反复、永远红不了），能同时抓
//    「参数没透传」与「透传了错值」两类错。
// 2. 按 §2.49 的实测结论：**玻璃档不是不能测、是不能用 `pumpAndSettle` 测**。本文件
//    宿主无入场动画，`pumpWidget` 后直接断言即可。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../test_config.dart';

/// 两个最小标签页（[GlassTab] 至少要有 icon 或 label）。
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

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  testWidgets('玻璃档底栏：interactionBehavior = glowOnly（去「放大」、留手指高光）',
      (WidgetTester tester) async {
    await tester.pumpWidget(host(
      GlassQualityTier.high,
      Scaffold(
        bottomNavigationBar: GlassNavBar(
          tabs: kTabs,
          selectedIndex: 0,
          onTabSelected: (int _) {},
        ),
      ),
    ));

    final GlassTabBar bar =
        tester.widget<GlassTabBar>(find.byType(GlassTabBar));

    expect(bar.interactionBehavior, GlassInteractionBehavior.glowOnly);
    // 反向断言是本用例的真正价值：把「又被改回库默认的 full」直接测红
    // （`full` = 光晕 + 弹簧缩放 = 负责人要去掉的「放大」）。
    expect(
      bar.interactionBehavior,
      isNot(GlassInteractionBehavior.full),
      reason: '库默认 full 含弹簧缩放（「放大」），回潮即红',
    );
    expect(
      bar.interactionBehavior.hasScale,
      isFalse,
      reason: '不得有弹簧缩放（`tab_bar_bottom_layout.dart:390` 据此把 interactionScale 钉为 1.0）',
    );
    expect(
      bar.interactionBehavior.hasGlow,
      isTrue,
      reason: '保留手指位置的柔和高光（负责人只要求移除「放大」）',
    );
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 指示块形变：切换 tab 时拉宽 + 边缘 pinch + 静置磨砂
  // ══════════════════════════════════════════════════════════════════════════
  // 断言读玻璃库 widget 的**公开字段**、期望值硬编码字面量（不引用
  // `kNavPinchStrength` / `kNavRestingBlur`，否则同义反复、永远红不了）。
  group('底栏指示块形变（参考图口径）', () {
    testWidgets('pinch 0.75 / innerBlur 0.6：液态形变 + 静置磨砂',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        GlassQualityTier.high,
        Scaffold(
          bottomNavigationBar: GlassNavBar(
            tabs: kTabs,
            selectedIndex: 0,
            onTabSelected: (int _) {},
          ),
        ),
      ));

      final GlassTabBar bar =
          tester.widget<GlassTabBar>(find.byType(GlassTabBar));

      // 形变强度：库默认 0.4（iOS 26 折中档），参考图要更明显的液态。
      expect(bar.indicatorPinchStrength, 0.75);
      // 反向断言：退回库默认 0.4 即红（「形变不够明显」回潮）。
      expect(bar.indicatorPinchStrength, isNot(0.4));
      // 不取 1.0：满档时 pinch 深度会啃进图标（库 doc：幅度受 thickness 约束）。
      expect(bar.indicatorPinchStrength, lessThan(1.0));

      // 静置磨砂：库默认 0.0 = 不画，参考图的选中块需与底栏本体分层。
      expect(bar.innerBlur, 0.6);
      expect(bar.innerBlur, isNot(0.0));
    });

    testWidgets('形变与「按下缩放」互不干涉：glowOnly 不回潮',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        GlassQualityTier.high,
        Scaffold(
          bottomNavigationBar: GlassNavBar(
            tabs: kTabs,
            selectedIndex: 0,
            onTabSelected: (int _) {},
          ),
        ),
      ));

      final GlassTabBar bar =
          tester.widget<GlassTabBar>(find.byType(GlassTabBar));
      // 本组的意义就在这条：加了一整套指示块形变，**不得**把「移除放大」一起
      // 回潮——两套机制本就独立。
      expect(bar.interactionBehavior, GlassInteractionBehavior.glowOnly);
      expect(bar.interactionBehavior.hasScale, isFalse);
      // 指示块本身仍须显式开启（showIndicator 默认 true，防被误关）。
      expect(bar.showIndicator, isTrue);
    });

    testWidgets('参数可由调用点覆盖（不必改库）', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        GlassQualityTier.high,
        Scaffold(
          bottomNavigationBar: GlassNavBar(
            tabs: kTabs,
            selectedIndex: 0,
            onTabSelected: (int _) {},
            indicatorPinchStrength: 0.0,
            indicatorInnerBlur: 0.0,
          ),
        ),
      ));

      final GlassTabBar bar =
          tester.widget<GlassTabBar>(find.byType(GlassTabBar));
      // 传 0 = 完全关闭形变 / 磨砂（退化为纯平移），用于低端降级或调试。
      expect(bar.indicatorPinchStrength, 0.0);
      expect(bar.innerBlur, 0.0);
    });
  });
}
