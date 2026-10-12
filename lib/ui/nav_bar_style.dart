// 底部导航栏的**几何 + 材质**唯一事实源（2026-10-12 参考图复刻批）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么弃用 `GlassTabBar` 改自磨砂伪玻璃（负责人 2026-10-12拍板）
// ══════════════════════════════════════════════════════════════════════════════
// 参考图（HyperOS 主题商店）实测下来，它那一档玻璃**没有**液态玻璃的折射 /
// 色散：抓底栏上边缘能看到的只是「内容被磨砂 + 表面一层亮白纱罩 + 上边缘一道
// 高光」。也就是 `BackdropFilter` + 半透明白层就能 1:1 复刻。
//
// 而 `liquid_glass_widgets` 为导航栏付出的代价是：加载 2574 行 GLSL（折射 /
// 色散 / Fresnel），外加一整套本项目已记录在案的限制（PRD §11.4 九条+ tech-usage
// 十一个玻璃专项小节）。**用不上它的核心，却要承担它的全部重量**——于是自研：
//
//   拿到的│ 代价
//   ────┼──────────────────────────────────────────────
//   几何 100% 可控 │约 400 行自研代码（本文件 + frosted_nav_bar.dart）
//   形变可精确复刻  │ 少一个依赖（本项目 `UI-04` 档位链需重新接线）
//   选中块宽度可定  │ 浮层 / 弹窗仍用库（那里的折射是真需要的）
//   测试开销归零    │
//
// ⚠️ **范围边界**：本文件只管**导航栏**。弹层（Sheet / Dialog / Toast）与顶栏
// 仍走 `GlassKit` / `OverlayStyle` / `GlassMaterial`（那些场景折射是真需求）。
// 两套并存不冲突——导航栏从`GlassNavBar` 一个调用点接入，档位退化链仍复用
// [GlassScope] / [GlassRuntime]（纯项目逻辑，与库解耦，见 tech-usage §2.86）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 实测数据（2026-10-12，video 原生 592×1280 未缩放，非目测）
// ══════════════════════════════════════════════════════════════════════════════
// 抽帧后按列能量投影定位 4 个标签的文字簇（每个标签两个字，故先合并双字峰）：
//
//   标签中心x = 115 / 244 / 373 / 502   相邻间距 **129 / 129 / 129**（严格等分）
//   首尾边距  = 左 115 / 右 90（不对称 ⇒ 参考图左侧有额外留白，见下）
//
// **标签严格等分**是最可靠的锚点（3 段间距完全相同，排除了测量噪声），
// 由它反推布局：**4 等分，间距 = 可用宽 / 4**。
//
// **左右不对称 25px 的处置**：不照抄。参考图第1 项是「全部分类」这类宽标签，
// 且整条偏左；MReader 五 tab 且标签均为双字，强行复刻不对称会让选中块位置
// 在不同屏宽下更难看。**取等分居中**——「等分」这个实测特征被保留，
// 「不对称」视作该 app 的内容特例。
//
// ⚠️⚠️ **「141px = 选中块宽」这条是错的，已作废**（2026-10-12 真机复验发现）。
// 那个 141px 量到的是**图标 + 文字簇的外沿**，不是选中块本身。
// 真机截图与参考图**同法**重测（横向扫 y 避开文字行，读选中块内稳定亮度段）：
//
//   参考图   选中块 x 68~164  ⇒宽  96，格宽 ≈140 ⇒ **占格宽 69%**
//            块内 rgb(47,52,58)  lum 52   栏体 lum 19   比值 2.7×
//            边界 x164→168：48→42→34→30→26（4~5px **渐变**）
//
//   原实现   选中块 x 40~205  ⇒ 宽 165，格宽 ≈176 ⇒ 占格宽 94%（**过宽**）
//            块内 rgb(58,59,64)  lum 60   栏体 lum 18   比值 3.3×
//            边界 x202→206：130→112→17（2px **硬切**，因为白描边 0.34）
//
// 三条修正（各自都有实测依据，见对应常量注释）：宽度 1.09→**0.69**、
// 描边 0.34→**0**、纱罩色中性白→**冷灰蓝**（hue 230 偏紫 → 210）。
//
// ⚠️ **圆角未能量出**：选中块与栏体在这张二次压缩的录屏里都是低对比度大面积
// 色块，逐行亮度梯度法取不到干净的内收曲线。圆角采用**规范值**（选中块 =
// 胶囊 `高/2`，栏体 = `24`），在源码中标注为「设计值」而非「实测值」，便于真机
// 复验后一处调整。
import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import 'glass_scope.dart' show GlassScope;

/// 底部导航栏的几何与材质（单位：逻辑像素 dp）。
abstract final class NavBarStyle {
  // ── 栏体 ────────────────────────────────────────────────────────────────────
  /// 胶囊高度。
  ///
  /// 参考图实测选中块高约 53px（@592 宽屏），加上 `iconLabelSpacing` 与上下留白
  /// ⇒ 栏体约 64~70。取 **68**，比库默认的 64 略高（容得下参考图比例）。
  static const double barHeight = 68;

  /// 胶囊左右外边距（`>0` 即「悬浮」；实测左右留白都远大于 0）。
  ///
  /// 取 **16**：悬浮感明确，同时不浪费横向空间（5 tab 每格可用宽仍 > 100）。
  static const double horizontalPadding = 16;

  /// 胶囊浮起高度（屏幕底边到胶囊底的距离）。
  ///
  /// 实测选中块底边在 1230 / 屏高 1280 ⇒ 底边距约 50px（@2x ≈ 25dp）。取
  /// **18** 叠加系统安全区——保证手势条区不被压。
  static const double verticalPadding = 18;

  /// 胶囊圆角（设计值，实测取不到，见文件头说明）。
  static const double barRadius = 24;

  // ── 标签 ────────────────────────────────────────────────────────────────────
  /// 标签间的额外间距（`>0` 会挤占每格宽度，故取 0）。
  ///
  /// 实测标签中心严格等分 ⇒ 格子**不额外留缝**，每格占 `可用宽 / n`。库默认的
  /// `spacing: 8` 正是破坏等分的元凶，这也是自研的一个直接收益。
  static const double tabSpacing = 0;

  /// 图标尺寸。
  static const double iconSize = 24;

  /// 图标与文字之间的间距。
  static const double iconLabelSpacing = 4;

  /// 标签文字字号。
  static const double labelFontSize = 11;

  // ── 选中块 ──────────────────────────────────────────────────────────────────
  /// 选中块宽度 = 格子宽的 **69%**。
  ///
  /// ⚠️ **2026-10-12 真机复验修正**：原值 1.09（依据「实测 141 / 129」）**量错了
  /// 对象**——141px 那个尺寸量到的是**图标文字簇的外沿**，不是选中块本身。真机
  /// 截图与参考图同法重测（横向扫 y=1236 避开文字行）：
  ///
  /// ```text
  ///   参考图  选中块 x 68~164  ⇒ 宽 96，格宽 ≈140 ⇒ 69%
  ///   真机    选中块 x 40~205  ⇒ 宽 165，格宽 ≈176 ⇒ 94%（做成这样 ⇒ 丑）
  /// ```
  ///
  /// 近乎撑满整格 + 0.16 白纱 ⇒ 观感是「灰白大药丸压住图标」而非「底衬」。
  static const double pillWidthFactor = 0.69;

  /// 选中块高度（占栏体高的比例）。
  ///
  /// 实测选中块高 53 / 栏体约 68 ≈ 0.78。取 **0.72** 并居中——留一点上下呼吸，
  /// 避免贴边显得拥挤（实测值含图标本身高度，直接照搬会让底衬显矮）。
  static const double pillHeightFactor = 0.72;

  /// 选中块圆角（设计值）：胶囊形 = 高的一半。
  static double pillRadius(double height) => height / 2;

  // ── 形变（切换时的液态拉伸）───────────────────────────────────────────────
  /// 切换动画时长（设计值；实测切换在 5.0s 前完成，视频 24fps 无法定毫秒级）。
  static const Duration switchDuration = Duration(milliseconds: 420);

  /// 切换曲线：`easeOutBack` 尾段回弹 ⇒ 选中块到位时有一次轻微过冲。
  ///
  /// 这是参考图「弹一下」的手感来源；纯 `easeOutCubic` 会显得死板。
  static const Curve switchCurve = Curves.easeOutBack;

  /// 拖动跟手形变的最大拉伸比例（选中块被拖动时横向拉宽）。
  static const double dragStretch = 0.18;

  // ── 材质（磨砂伪玻璃）──────────────────────────────────────────────────────
  /// 磨砂模糊sigma。
  ///
  /// 参考图的磨砂强度观感接近 iOS 的 `UIView` 毛玻璃档。Flutter 的 `sigma` 与
  /// 平台实现相关，取 **18** 是跨平台观感较稳的值（12~24 区间内差异不大）。
  static const double blurSigma = 18;

  /// 栏体纱罩不透明度（亮色下压到背景上的**白**）。
  ///
  /// 参考图底栏明显比背后内容「亮一档」——磨砂 + 白纱双叠加。亮色 **0.42**、
  /// 暗色 **0.10**（暗下面本已发亮，白纱要少）。
  static double scrimAlpha(Brightness brightness) =>
      brightness == Brightness.dark ? 0.10 : 0.42;

  /// 栏体边框不透明度（上缘一道亮边，是「玻璃有厚度」的关键视觉线索）。
  static const double barBorderAlpha = 0.28;

  /// 选中块纱罩不透明度。
  ///
  /// ⚠️ **2026-10-12 真机复验修正**：原值暗色 0.16 配**中性白**，实测做出来
  /// lum **60**；参考图实测 lum **52**，偏亮 15%。
  ///
  /// 值是**反解**出来的，不是拍的——暗色栏体实测 lum 18，纱罩色改冷灰蓝后
  /// 有效亮度 180（不再是纯白 255）：
  ///
  /// ```text
  ///   18 + a × (180 − 18) = 52  ⇒  a = 0.21
  /// ```
  ///
  /// 若沿用纯白（255），同样的目标只需 0.14——**这正是之前偏亮的机制**：
  /// 中性白太亮，同alpha 下叠出来更亮。
  static double pillScrimAlpha(Brightness brightness) =>
      brightness == Brightness.dark ? 0.21 : 0.62;

  /// 选中块**描边**不透明度。
  ///
  /// ⚠️ **2026-10-12 真机复验修正**：原值 0.34 的白描边是「边界像根白线」的
  /// 元凶。边界柔度实测（横向逐px）：
  ///
  /// ```text
  ///   参考图  52 → 48 → 42 → 34 → 30 → 26   (4~5px 渐变，磨砂+圆角自然羽化)
  ///   原实现  …130 → 112 → 17                 (2px 硬切)
  /// ```
  ///
  /// 玻璃羽化本该由「磨砂 + 圆角」自然产生，硬描边与之**叠加成一根白线**。取
  /// **0**（关掉），边界柔化改由 [pillFilter] 的 sigma 承担。
  static const double pillBorderAlpha = 0.0;

  /// 标签文字颜色不透明度：选中 / 未选中。
  static const double selectedLabelAlpha = 0.95;
  static const double unselectedLabelAlpha = 0.62;

  /// 栏体的磨砂+纱罩合成（亮色主题下用）。
  ///
  /// 暗色下纱罩换成**黑色**提亮对比（暗面玻璃的正确做法：压黑而非加白）。
  static Color scrimColor(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF000000).withValues(alpha: scrimAlpha(Brightness.dark))
      : const Color(0xFFFFFFFF).withValues(alpha: scrimAlpha(Brightness.light));

  /// 选中块纱罩色。
  ///
  /// ⚠️ **2026-10-12 真机复验修正**：原值用**中性白** `0xFFFFFFFF`，真机实测色相
  /// hue **230**（偏紫）、饱和度仅 0.09——中性白纱叠在蓝调背景上必然带紫，与 App
  /// 主题的青蓝玻璃调完全不对路。参考图实测选中块 `rgb(47,52,58)`、hue **213**、
  /// 饱和度 **0.19**（**冷灰蓝**）。
  ///
  /// ⇒ 暗色下改用**冷灰蓝** `0xFF9FB4C8`（hue 210）向背景调靠拢；亮色下仍用白
  /// （亮底上白纱才提亮，用蓝会脏）。
  static Color pillScrimColor(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0xFF9FB4C8).withValues(
              alpha: pillScrimAlpha(Brightness.dark),
            )
          : const Color(0xFFFFFFFF).withValues(
              alpha: pillScrimAlpha(Brightness.light),
            );

  /// 栏体磨砂滤镜。
  static ImageFilter barFilter(Brightness brightness) =>
      ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma);

  /// 选中块磨砂滤镜。
  ///
  /// 比栏体**更强**（参考图选中块背后内容更糊一档）⇒ sigma ×1.5。
  static ImageFilter pillFilter(Brightness brightness) => ImageFilter.blur(
        sigmaX: blurSigma * 1.5,
        sigmaY: blurSigma * 1.5,
      );

  /// 按当前亮度解析材质。
  ///
  /// 亮度走 [GlassScope.brightnessOf]（本作用域 → 库四级级联），与玻璃控件内部
  /// 同源（`UI-01` ②）。
  static Brightness brightnessOf(BuildContext context) =>
      GlassScope.brightnessOf(context);
}