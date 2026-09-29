// `GlassNavBar`（导航层底栏）**触摸反馈口径**的契约测试（2026-09-29 拍板）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 背景
// ══════════════════════════════════════════════════════════════════════════════
// 负责人「移除导航栏放大特效」。库 `GlassTabBar` 的 `interactionBehavior` 缺省是
// **`GlassInteractionBehavior.full`**（= 方向光晕 **+** 物理弹簧缩放；doc 自述
// "the glass **inflates** subtly (bottom-anchored spring) on touch"），而本项目
// `GlassNavBar` 原先**未透传**该参数 → 点击底栏时整个胶囊会膨胀。这与
// `showSheet` 未透传 `interactionScale`（§2.49）是**同一类坑**：薄封装没暴露的
// 库参数会以库默认值静默生效。
//
// 现显式传 `glowOnly`（去形变、保留手指位置的柔和高光）——库 doc 正是把这个档位
// 推荐给「flat navigation bars that should remain spatially stable」。
//
// ══════════════════════════════════════════════════════════════════════════════
// 两条测试口径（与 `glass_sheet_form_test.dart` 一致）
// ══════════════════════════════════════════════════════════════════════════════
// 1. 断言读的是**玻璃库 widget 自身字段**（`GlassTabBar.interactionBehavior`），
//    期望值**硬编码字面量**——不引用薄封装暴露的常量，否则就是同义反复、
//    永远红不了。这样能同时抓「参数没透传」与「透传了错值」两类错。
// 2. 按 §2.49 的实测结论：**玻璃档不是不能测、是不能用 `pumpAndSettle` 测**。
//    本文件宿主无入场动画，`pumpWidget` 后直接断言即可（同
//    `glass_off_fallback_test.dart` 的档位用例）。
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
}
