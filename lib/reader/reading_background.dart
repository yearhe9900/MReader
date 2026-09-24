// `TYP-08`：预设背景色的调色板（语义色板 → 具体颜色值）。
//
// 放在 UI 层（依赖 `dart:ui` 的 [Color]），`reading_prefs.dart` 的
// [ReaderBackground] 枚举保持纯 Dart（可进 isolate、可单测）。
//
// **夜间映射**（`TYP-08` 验收③「夜间模式不产生白底」）：应用主题为暗色时，
// 亮色预设（白 / 米黄 / 灰）一律映射到各自的深色变体——背景预设表达的是
// 「纸感偏好」，但**夜间绝不产生白底**是硬验收，故夜间以暗色为准；
// 纯黑预设昼夜恒为 `#000000`。
import 'dart:ui';

import 'reading_prefs.dart';

/// [ReaderBackground] → 颜色值。
extension ReaderBackgroundPalette on ReaderBackground {
  /// 白天（亮色主题）页面底色。
  Color get dayColor {
    switch (this) {
      case ReaderBackground.white:
        return const Color(0xFFFFFFFF);
      case ReaderBackground.sepia:
        // 米黄（暖纸色）：与正文色 #1F1F1F 对比度约 13:1（`TYP-08` 验收②）。
        return const Color(0xFFF2E7D3);
      case ReaderBackground.gray:
        return const Color(0xFFD6D6D6);
      case ReaderBackground.black:
        return const Color(0xFF000000);
    }
  }

  /// 夜间（暗色主题）页面底色（`TYP-08` 验收③：夜间一律暗底，无白底）。
  Color get nightColor {
    switch (this) {
      case ReaderBackground.white:
        return const Color(0xFF121212);
      case ReaderBackground.sepia:
        return const Color(0xFF2B2419);
      case ReaderBackground.gray:
        return const Color(0xFF2E2E2E);
      case ReaderBackground.black:
        return const Color(0xFF000000);
    }
  }

  /// 页面底色（[night] = 当前是否夜间 / 暗色主题）。
  Color pageColor({required bool night}) => night ? nightColor : dayColor;

  /// 正文文字颜色（与页面底色配对，保证对比度）。
  ///
  /// 白天亮底用近黑 `#1F1F1F`；夜间暗底用近白 `#E6E6E6`；
  /// 纯黑预设昼夜都用 `#D9D9D9`（不用纯白，减轻暗光炫目）。
  Color textColor({required bool night}) {
    if (this == ReaderBackground.black) {
      return const Color(0xFFD9D9D9);
    }
    return night ? const Color(0xFFE6E6E6) : const Color(0xFF1F1F1F);
  }

  /// 色板展示名（外观面板）。
  String get label {
    switch (this) {
      case ReaderBackground.white:
        return '白色';
      case ReaderBackground.sepia:
        return '米黄';
      case ReaderBackground.gray:
        return '灰色';
      case ReaderBackground.black:
        return '纯黑';
    }
  }
}
