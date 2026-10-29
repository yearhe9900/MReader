// `OverlayStyle` 契约测试（弹层共有参数统一配置）。
//
// 为什么单列：[OverlayStyle] 是浮层（对话框 / 底部弹窗 / 轻提示）参数的**唯一事实源**，
// 一旦被改动**四个入口的观感会同时变**——必须是「看得见」的动作而不是顺手改个数字。
// 故这里把每个值**硬编码字面量**（引用本仓常量 = 同义反复、永远红不了，与
// `shelf_geometry_contract_test.dart` 同口径）。
//
// 这些值 vs 玻璃库 / Material 的默认值：
//   · `interactionScale`  库默认 **1.01** → 本项目 1.0（无点击放大）
//   · `interactionGlow`   库默认 **true** → false（无跟随手指的高光）
//   · `saturationGlow`    库默认 **true** → false（无触摸饱和度脉冲）
//   · `dragIndicator`     库默认 **true** → false（无顶部小横条）
//   · `enableDrag`        库默认 **true** → false（禁拖拽关闭手势）
//   · `barrier`           库默认 `0x8A000000`（α0.541）/ Material `DialogRoute` 默认
//                         `Colors.black54`（**同一个 `0x8A000000`**）/ Cupertino 自适应
//                         `0x33000000`(亮) `0x7A000000`(暗) → 三源统一为 `0x3D000000`（α≈0.239）
//   · `dialogMaxWidth` / `sheetTopBorderRadius` / `sheetMargin`
//                         → 与库 `GlassDialog`(280) / `GlassSheet`(32 / 8,8) 默认**同值**。
//     「同值」不是冗余：**显式化**后库升级若改默认值，不会静默改掉本项目观感。
//
// 「透传是否真的生效」不在这里测——由 `glass_sheet_form_test.dart`（玻璃档）与
// `glass_off_fallback_test.dart`（关档）负责。本文件只钉常量本身。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ui/glass_kit.dart';

void main() {
  test('OverlayStyle 契约：遮罩色（四个入口共用一颗）', () {
    expect(OverlayStyle.barrier, const Color(0x3D000000));
    // α = 61/255 ≈ 0.239 —— 硬编码 61：远淡于被否定的 0x8A000000（α 138）。
    expect((OverlayStyle.barrier.a * 255).round(), 61);
  });

  test('OverlayStyle 契约：形态（触摸反馈 + 拖拽）', () {
    // 无点击放大 / 高光 / 小横条 / 上划拖拽。
    expect(OverlayStyle.interactionScale, 1.0);
    expect(OverlayStyle.interactionGlow, isFalse);
    expect(OverlayStyle.saturationGlow, isFalse);
    expect(OverlayStyle.dragIndicator, isFalse);
    expect(OverlayStyle.enableDrag, isFalse);
  });

  test('OverlayStyle 契约：尺寸与时长', () {
    expect(OverlayStyle.dialogMaxWidth, 280);
    expect(OverlayStyle.sheetTopBorderRadius, 32);
    expect(
      OverlayStyle.sheetMargin,
      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    );
    expect(OverlayStyle.toastDuration, const Duration(seconds: 2));
  });
}
