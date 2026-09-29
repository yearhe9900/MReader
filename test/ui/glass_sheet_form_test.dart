// `GlassOverlays.showSheet` 弹层**形态口径**的契约测试（2026-09-29 拍板）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 背景
// ══════════════════════════════════════════════════════════════════════════════
// 负责人原话：「去除弹框点击会有放大高亮特效，不需要上划的弹框，去除小横条」。
// `AskUserQuestion` 两项拍板：①「上划」= **禁止拖拽关闭手势**（底部滑入的入场
// 动画保留）；② **全部弹层统一生效**（改 `GlassOverlays.showSheet` 一处即
// 6 处弹层同时生效：设置页选择 ×2、书架长按操作单、详情页分组、阅读页目录 /
// 书签 / 搜索 / 外观）。
//
// 四项症状 ↔ 玻璃库参数（本薄封装原先全吃库默认值，与 `GlassNavScaffold.extendBody`
// 默认 `true` 一类坑——薄封装没透传的参数会静默生效）：
//   · 「点击放大」 = `interactionScale`（库默认 **1.01**）
//   · 「点击高亮」 = `enableInteractionGlow` + `enableSaturationGlow`（库默认均 true）
//   · 「小横条」   = `showDragIndicator`（库默认 true）
//   · 「上划」     = `enableDrag`（库默认 true）
//
// ══════════════════════════════════════════════════════════════════════════════
// 两条测试口径
// ══════════════════════════════════════════════════════════════════════════════
// 1. 期望值一律**硬编码字面量**，且断言读的是**玻璃库 widget 自身的公开字段**
//    （`GlassSheet.showDragIndicator` / `.interactionScale` / `.enableInteractionGlow` /
//    `.enableSaturationGlow`）——不引用薄封装暴露的任何常量，否则就是同义反复、
//    永远红不了。这样能同时抓「参数没透传」与「透传了错值」两类错。
// 2. 本文件**故意**是唯一渲染**玻璃档**弹层的地方（其余弹层用例一律在关档跑，
//    见 `glass_off_fallback_test.dart` 头注释：玻璃档在 `flutter test` 软件光栅下
//    每帧数百 ms）。故这里**只用 `pump(Duration)` 推进固定帧数**、不用
//    `pumpAndSettle`，把开销压在可接受范围。
//
// 「关档」（Material `showModalBottomSheet`）的同口径断言在
// `glass_off_fallback_test.dart` 的「showSheet 退化」用例里（`BottomSheet.enableDrag`
// 为公开字段，可直接断言），本文件不重复。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

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

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  testWidgets('弹层形态：无横条 / 禁上划拖拽 / 无点击放大 / 无点击光晕与脉冲',
      (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(host(
      GlassQualityTier.high, // 高档：浮层走 standard 玻璃档（永不 premium）
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
    // 推进入场动画：`GlassSheet.show` 的 transitionDuration 是 350ms。
    // 不用 `pumpAndSettle` —— 玻璃档在软件光栅下每帧数百 ms（见文件头口径 2）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final GlassSheet sheet = tester.widget<GlassSheet>(find.byType(GlassSheet));

    // 「小横条」——库默认 true。
    expect(sheet.showDragIndicator, isFalse);
    // 「点击放大」——库默认 1.01（按下时 `pressed ? interactionScale : 1.0`）。
    expect(sheet.interactionScale, 1.0);
    // 「点击高亮」——两条独立的高亮通路，都要关。
    expect(sheet.enableInteractionGlow, isFalse);
    expect(sheet.enableSaturationGlow, isFalse);

    // 「上划」= `enableDrag`。它落在库私有的 `_DismissibleSheetWrapper` 上、
    // **无公开字段可读**，故用**行为**验证：对弹层做一次下滑手势，
    // 若仍允许拖拽关闭，弹层会消失（库的阈值 = 弹层高度 25% 或下滑速度 > 500）。
    await tester.drag(find.byType(GlassSheet), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byType(GlassSheet),
      findsOneWidget,
      reason: '禁止上划拖拽关闭：下滑 300px 后弹层必须仍在',
    );

    // 收尾：弹层仍可用（点内容按钮即 pop）——「禁止拖拽关闭」不得影响正常关闭路径。
    await tester.tap(find.text('关闭'));
    await tester.pump();
    expect(await future, 'closed');
  });
}
