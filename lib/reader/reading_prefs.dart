// `TYP-06~09`：阅读偏好值对象（排版 + 亮度 + 背景色）。
//
// 组成：
//   · **排版**（`TYP-01~04` / `TYP-07`）：直接复用 [ReaderSettings]（字号 / 行距 /
//     字体族 / 主题三态 / 页边距），**不另造第二套排版模型**——排版语义只有一份；
//   · **亮度**（`TYP-08`）：应用内亮度遮罩的亮度值 `0.2 ~ 1.0`（1.0 = 不加遮罩）；
//   · **背景色**（`TYP-08`）：预设背景色板（白 / 米黄 / 灰 / 纯黑）。
//
// 全局偏好（**不分书**）：与 PRD §10.1「阅读设置：字号/行距/边距/主题/字体/亮度，
// 取最近修改」同一语义域，所有书共用一份。落盘经 `ReadingPrefsStore`。
import '../settings/settings_store.dart';
import '../typography/reader_settings.dart';

/// 预设背景色板（`TYP-08`：米黄 / 灰 / 纯黑等）。
///
/// 只表达**语义**（纯 Dart）；具体颜色值由 UI 层的调色板扩展给出
/// （`reading_background.dart`，含夜间映射——`TYP-08` 验收③「夜间模式不产生白底」）。
enum ReaderBackground {
  /// 白色（默认）。
  white,

  /// 米黄（暖色纸感，`TYP-08` 验收②要求对比度足够）。
  sepia,

  /// 灰色。
  gray,

  /// 纯黑（夜间阅读）。
  black;

  /// 由持久化字符串解析；未知或缺失时回退 [ReaderBackground.white]。
  static ReaderBackground fromName(String? name) {
    for (final ReaderBackground value in ReaderBackground.values) {
      if (value.name == name) {
        return value;
      }
    }
    return ReaderBackground.white;
  }
}

/// 翻页方式（选型拍板①「`pageMode` 模式切换由用户可选」、拍板③「slide + cover
/// 先行，scroll/none 跟上，curl 后置 P2」）。
///
/// [scroll] 纵向滚动（既有默认）；[slide] 左右滑动整页平移；[cover] 覆盖翻页；
/// [none] 点划即翻、无动画。
enum ReaderPageMode {
  scroll,
  slide,
  cover,
  none;

  /// 由持久化字符串解析；未知或缺失时回退 [ReaderPageMode.scroll]
  /// （滚动是既有默认，旧数据无该键也落在这里）。
  static ReaderPageMode fromName(String? name) {
    for (final ReaderPageMode value in ReaderPageMode.values) {
      if (value.name == name) {
        return value;
      }
    }
    return ReaderPageMode.scroll;
  }
}

/// 阅读偏好（不可变）：排版 [settings] + 亮度 [brightness] + 背景 [background]。
class ReadingPrefs {
  ReadingPrefs({
    this.settings = const ReaderSettings(),
    double brightness = maxBrightness,
    this.background = ReaderBackground.white,
    this.pageMode = ReaderPageMode.scroll,
  }) : brightness = brightness.clamp(minBrightness, maxBrightness).toDouble();

  /// 亮度下限（`TYP-08`：遮罩最深仍需可读，不提供全黑遮罩）。
  static const double minBrightness = 0.2;

  /// 亮度上限（= 不加遮罩）。
  static const double maxBrightness = 1.0;

  /// 排版设置（字号 / 行距 / 字体族 / 主题 / 页边距）。
  final ReaderSettings settings;

  /// 应用内亮度 `0.2 ~ 1.0`（构造时自动 clamp；遮罩不透明度 = `1 - brightness`）。
  final double brightness;

  /// 默认排版（取 [ReaderSettings] 的默认值，单一事实来源）。
  static final ReaderSettings defaultSettings = const ReaderSettings();

  /// 预设背景色板。
  final ReaderBackground background;

  /// 翻页方式（默认滚动 = 既有行为）。
  final ReaderPageMode pageMode;

  /// 生成一份新副本（`null` 表示不改该字段）。
  ///
  /// [settings] / [background] 允许显式传 `null` 时**保持原值**（与
  /// [ReaderSettings.copyWith] 的「fontFamily 允许传 null 重置」语义不同——
  /// 这里没有「清空」需求，`null` 一律表示不变）。
  ReadingPrefs copyWith({
    ReaderSettings? settings,
    double? brightness,
    ReaderBackground? background,
    ReaderPageMode? pageMode,
  }) {
    return ReadingPrefs(
      settings: settings ?? this.settings,
      brightness: brightness ?? this.brightness,
      background: background ?? this.background,
      pageMode: pageMode ?? this.pageMode,
    );
  }

  /// 序列化为 JSON Map（排版五项**平铺**，与 `Settings.toJson` 同风格）。
  Map<String, Object?> toJson() => <String, Object?>{
        'fontSize': settings.fontSize,
        'lineHeight': settings.lineHeight,
        if (settings.fontFamily != null) 'fontFamily': settings.fontFamily,
        'themeMode': settings.themeMode.name,
        'pageMargin': settings.pageMargin.name,
        'brightness': brightness,
        'background': background.name,
        'pageMode': pageMode.name,
      };

  /// 防御式反序列化：非 `Map` → 整体默认值；字段缺失 / 类型异常**逐项**回退默认
  /// （与 `Settings.fromJson` 同风格——偏好是「越新越好」的小文件，单项坏不该
  /// 连坐全部）。数值越界自动 clamp。
  static ReadingPrefs fromJson(Object? json) {
    if (json is! Map) {
      return ReadingPrefs();
    }
    final Object? fontFamily = json['fontFamily'];
    return ReadingPrefs(
      settings: ReaderSettings(
        fontSize: _asDouble(json['fontSize'], defaultSettings.fontSize)
            .clamp(ReaderSettings.minFontSize, ReaderSettings.maxFontSize)
            .toDouble(),
        lineHeight: _asDouble(json['lineHeight'], defaultSettings.lineHeight)
            .clamp(ReaderSettings.minLineHeight, ReaderSettings.maxLineHeight)
            .toDouble(),
        fontFamily: fontFamily is String ? fontFamily : null,
        themeMode: AppThemeMode.fromName(json['themeMode'] as String?),
        pageMargin: _pageMarginFromName(json['pageMargin'] as String?),
      ),
      brightness: _asDouble(json['brightness'], maxBrightness),
      background: ReaderBackground.fromName(json['background'] as String?),
      pageMode: ReaderPageMode.fromName(json['pageMode'] as String?),
    );
  }

  static double _asDouble(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;

  /// 页边距按名字解析；未知或缺失回退 [PageMargin.normal]。
  static PageMargin _pageMarginFromName(String? name) {
    for (final PageMargin value in PageMargin.values) {
      if (value.name == name) {
        return value;
      }
    }
    return PageMargin.normal;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReadingPrefs &&
          runtimeType == other.runtimeType &&
          settings == other.settings &&
          brightness == other.brightness &&
          background == other.background &&
          pageMode == other.pageMode;

  @override
  int get hashCode => Object.hash(settings, brightness, background, pageMode);

  @override
  String toString() => 'ReadingPrefs($settings, brightness: $brightness, '
      'bg: $background, pageMode: $pageMode)';
}
