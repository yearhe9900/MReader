// `GlassOverlays.showSheet` 弹层**形态口径**的契约测试。
//
// 背景：①「上划」= **禁止拖拽关闭手势**（底部滑入入场动画保留）；② **全部弹层统一生效**
// （改 `GlassOverlays.showSheet` 一处即各处弹层同时生效）。四项症状 ↔ 玻璃库参数（薄封装
// 不透传的参数会**静默吃库默认值**，与 `GlassNavScaffold.extendBody` 默认 `true` 一类坑）：
//   · 「点击放大」 = `interactionScale`（库默认 1.01）
//   · 「点击高亮」 = `enableInteractionGlow` + `enableSaturationGlow`（库默认均 true）
//   · 「小横条」   = `showDragIndicator`（库默认 true）
//   · 「上划」     = `enableDrag`（库默认 true）
//
// 两条测试口径：
// 1. 期望值一律**硬编码字面量**，断言读**玻璃库 widget 自身的公开字段**——不引用薄封装
//    暴露的常量（同义反复、永远红不了），能同时抓「参数没透传」与「透传了错值」两类错。
// 2. 本文件**故意**是唯一渲染**玻璃档**弹层的地方（其余弹层用例一律关档，见
//    `glass_off_fallback_test.dart` 头注释：玻璃档软件光栅下每帧数百 ms）——**只用
//    `pump(Duration)` 推固定帧数、禁 `pumpAndSettle`**。
//
// 「关档」（Material `showModalBottomSheet`）的同口径断言在
// `glass_off_fallback_test.dart` 的「showSheet 退化」用例里，本文件不重复。
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

    // 尺寸：两项与库默认**同值**但显式取 `OverlayStyle` 的值——统一源后，库升级改默认值
    // 不会静默改掉观感。反向验证：把 `OverlayStyle.sheetTopBorderRadius` / `.sheetMargin`
    // 改成别的值，本断言即变红（证明它读的确实是那处配置）。
    expect(sheet.topBorderRadius, 32);
    expect(
      sheet.margin,
      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    );

    // 「上划」= `enableDrag`：它落在库私有的 `_DismissibleSheetWrapper` 上、**无公开字段
    // 可读**，故用**行为**验证——若仍允许拖拽关闭，下滑手势后弹层会消失（库阈值 = 弹层
    // 高度 25% 或下滑速度 > 500）。
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

  // 遮罩色源契约（弹层出现前不该先蒙一层深灰幕）。病灶：`GlassSheet.show` 的
  // `barrierColor` 没透传、吃库默认 0x8A000000（α≈0.541），而遮罩与弹窗共用 350ms
  // 淡入、弹窗从屏幕外滑上来 ⇒ 头一段是「灰幕到场、弹窗未到」。断言读**遮罩自己
  // 渲染出来的色**（`AnimatedModalBarrier` 的当前 `Color`）而非薄封装常量（同义反复）。
  testWidgets('弹层遮罩：色源已压淡（库默认 0x8A000000 太重，且先于弹窗可见）',
      (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(host(
      GlassQualityTier.high,
      Scaffold(
        body: Builder(
          builder: (BuildContext context) {
            ctx = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ));

    GlassOverlays.showSheet<String>(
      context: ctx,
      isScrollable: false,
      builder: (BuildContext sheetContext) => const Text('弹层内容'),
    ).ignore();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 走完 350ms 入场

    // 终态遮罩色 = 库默认 `0x8A000000`（见 `glass_defaults.dart:154`，α≈0.541）。
    final Color barrier = _finalBarrierColor(tester);
    const int kLibDefaultAlpha = 0x8A; // 138 / 255 ≈ 0.541
    expect(
      barrier.a * 255,
      lessThan(kLibDefaultAlpha),
      reason:
          '弹层遮罩必须比库默认（α $kLibDefaultAlpha ≈ 0.541）更淡——'
          '库默认会在弹窗滑入前先铺一条深灰幕（实测终态 ${barrier.a * 255}）',
    );
    // 硬编码期望值：`0x3D` = 61 / 255 ≈ 0.239。
    expect(
      (barrier.a * 255).round(),
      0x3D,
      reason: '遮罩色应为 `OverlayStyle.barrier` 的 `0x3D000000`（α 61/255 ≈ 0.239）',
    );
  });

  // 确认框（`showAlert` 玻璃档）的遮罩与宽度也统一收口到 `OverlayStyle`。
  // 病灶：库 `GlassDialog.show` 的 `barrierColor` 是**死参数**（声明了却没传给
  // `showCupertinoDialog`），实际吃 Cupertino 默认 `0x33000000`（α 51）——浅色宿主下
  // 与统一色源不同，故本用例能变红。
  // 处置：玻璃档 `showAlert` **绕开** `GlassDialog.show`，自行
  // `showCupertinoDialog(barrierColor: OverlayStyle.barrier)` + `GlassDialog(...)`
  // （同一个库 widget，不丢玻璃渲染）。
  testWidgets('确认框（玻璃档）：遮罩也统一到同一色源，宽度取自 OverlayStyle',
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

    GlassOverlays.showAlert<String>(
      context: ctx,
      title: '删除书籍',
      message: '确认删除《测试》？',
      actions: <GlassDialogAction>[
        GlassDialogAction(label: '删除', isDestructive: true, onPressed: () {}),
        GlassDialogAction(label: '取消', onPressed: () {}),
      ],
    ).ignore();
    // 推进入场动画：`CupertinoDialogRoute` 的 transitionDuration 是 250ms。
    // 不用 `pumpAndSettle` —— 玻璃档在软件光栅下每帧数百 ms（见文件头口径 2）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 仍是库的 GlassDialog（只是绕开了它的 `show` 静态方法），内容照常渲染。
    expect(find.byType(GlassDialog), findsOneWidget);
    expect(find.text('删除书籍'), findsOneWidget);
    // 宽度取自统一配置（`OverlayStyle.dialogMaxWidth`，硬编码 280）。
    expect(tester.widget<GlassDialog>(find.byType(GlassDialog)).maxWidth, 280);

    // 遮罩 = 统一色源。旧行为：Cupertino 自适应 `0x33000000`（α 51）。
    final Color barrier = _finalBarrierColor(tester);
    expect(
      (barrier.a * 255).round(),
      0x3D,
      reason: '玻璃档确认框遮罩须用统一色源 0x3D000000（α 61），'
          '不得吃 Cupertino 默认的 0x33000000（α 51）',
    );
  });
}

/// 读当前在场遮罩的**终态**颜色（`showGeneralDialog` 插入的是
/// [AnimatedModalBarrier]，其 `color` 是驱动动画 [Animation]`<Color?>`）。
///
/// ⚠️ `AnimatedModalBarrier` **不是** `ModalBarrier` 的子类（框架里是两个独立类，
/// `AnimatedModalBarrier extends StatefulWidget`），故不能按 `ModalBarrier` 取。
Color _finalBarrierColor(WidgetTester tester) {
  final Animation<Color?> anim = tester
      .widget<AnimatedModalBarrier>(find.byType(AnimatedModalBarrier))
      .color;
  final Color? c = anim.value;
  expect(c, isNotNull, reason: '遮罩必须在场（点外关闭依赖它）');
  return c!;
}
