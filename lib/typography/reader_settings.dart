// 阅读设置值对象（`TYP-01` ~ `TYP-04`）。
//
// 从 `lib/ui/reader_settings_bar.dart` 提取并扩展：字号 / 行距 / 字体 / 主题 / 页边距。
// 纯数据模型：**不依赖 Flutter、不依赖 dart:io**（可进 isolate、可单测）。
import '../settings/settings_store.dart';

/// 页边距档位（`TYP-01`）。
enum PageMargin {
  /// 窄：左右各 12 逻辑像素。
  narrow(12),

  /// 正常：左右各 16 逻辑像素。
  normal(16),

  /// 宽：左右各 24 逻辑像素。
  wide(24);

  const PageMargin(this.horizontal);

  /// 左右两侧的水平内边距（逻辑像素）。
  final double horizontal;
}

/// 阅读设置（不可变）。
///
/// 字号单位是逻辑像素，行距是倍数（Flutter 的 `TextStyle.height`）。
/// 字体可选 `'serif'` / `'sans-serif'` / `null`（系统默认）。
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = _defaultFontSize,
    this.lineHeight = _defaultLineHeight,
    this.fontFamily,
    this.themeMode = AppThemeMode.system,
    this.pageMargin = PageMargin.normal,
  });

  // — 取值常量（与 PRD `TYP-01` / `Settings` 口径一致） —
  static const double _defaultFontSize = 18;
  static const double _defaultLineHeight = 1.6;
  static const double minFontSize = 12;
  static const double maxFontSize = 36;
  static const double fontStep = 1;
  static const double minLineHeight = 1.0;
  static const double maxLineHeight = 2.6;

  /// 字号（逻辑像素，12~36，步进 1）。
  final double fontSize;

  /// 行距倍数（1.0~2.6）。
  final double lineHeight;

  /// 字体族（`null` = 系统默认；可选 `'serif'` / `'sans-serif'`）。
  ///
  /// 不内嵌字体文件（`TYP-07`），由平台自行匹配。
  final String? fontFamily;

  /// 主题模式三态（`TYP-03`）。
  final AppThemeMode themeMode;

  /// 页边距档位（`TYP-01`）。
  final PageMargin pageMargin;

  /// 生成一份新副本（`null` 表示不改该字段）。
  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    String? fontFamily,
    AppThemeMode? themeMode,
    PageMargin? pageMargin,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      fontFamily: fontFamily, // 允许显式传 null 重置
      themeMode: themeMode ?? this.themeMode,
      pageMargin: pageMargin ?? this.pageMargin,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderSettings &&
          runtimeType == other.runtimeType &&
          fontSize == other.fontSize &&
          lineHeight == other.lineHeight &&
          fontFamily == other.fontFamily &&
          themeMode == other.themeMode &&
          pageMargin == other.pageMargin;

  @override
  int get hashCode => Object.hash(
        fontSize,
        lineHeight,
        fontFamily,
        themeMode,
        pageMargin,
      );

  @override
  String toString() =>
      'ReaderSettings(font: $fontSize, line: $lineHeight, '
      'family: $fontFamily, theme: $themeMode, margin: $pageMargin)';
}
