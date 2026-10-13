// 设置持久化服务（PRD `TYP-03`，含主题三态）。
//
// 设计约定（项目已固化，勿改）：
//   · 跨页面共享状态用「进程内共享实例 + 监听回调」，页面在 `initState` 订阅、
//     `dispose` 退订并在回调里 `setState`；**不引入 Provider / Riverpod**；
//   · **不使用可变全局单例**：实例在 `main()` 里显式创建，通过构造注入
//     `MReaderApp`（见 lib/app.dart）；[isLoaded] 作为显式初始化标志。
//   · 落盘一律经 [JsonStore] → [AtomicFile]，满足 `DATA-01` 原子写入。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 主题模式三态（PRD `TYP-03`）：日间 / 夜间 / 跟随系统。
enum AppThemeMode {
  /// 日间（浅色）。
  light,

  /// 夜间（深色）。
  dark,

  /// 跟随系统亮度。
  system;

  /// 由持久化字符串解析；未知或缺失时回退 [AppThemeMode.system]。
  static AppThemeMode fromName(String? name) {
    for (final AppThemeMode mode in AppThemeMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return AppThemeMode.system;
  }
}

/// 用户设置的值对象（不可变）。
class Settings {
  const Settings({
    this.themeMode = AppThemeMode.system,
    this.fontSize = defaultFontSize,
    this.lineHeight = defaultLineHeight,
  });

  /// 字号默认值（逻辑像素），与 PRD `TYP-01` 一致。
  static const double defaultFontSize = 20;

  /// 行距默认倍数，与 PRD `TYP-01` 一致。
  static const double defaultLineHeight = 1.6;

  /// 字号取值范围（PRD `TYP-01`：12~36，步进 1）。
  static const double minFontSize = 12;
  static const double maxFontSize = 36;

  /// 行距取值范围（PRD `TYP-01`：1.0~2.6）。
  static const double minLineHeight = 1.0;
  static const double maxLineHeight = 2.6;

  final AppThemeMode themeMode;
  final double fontSize;
  final double lineHeight;

  Settings copyWith({
    AppThemeMode? themeMode,
    double? fontSize,
    double? lineHeight,
  }) {
    return Settings(
      themeMode: themeMode ?? this.themeMode,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'themeMode': themeMode.name,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
      };

  /// 由持久化 JSON 还原；字段缺失 / 类型异常时逐项回退默认值。
  static Settings fromJson(Object? json) {
    if (json is! Map) {
      return const Settings();
    }
    return Settings(
      themeMode: AppThemeMode.fromName(json['themeMode'] as String?),
      fontSize: _asDouble(json['fontSize'], defaultFontSize).clamp(
        minFontSize,
        maxFontSize,
      ),
      lineHeight: _asDouble(json['lineHeight'], defaultLineHeight).clamp(
        minLineHeight,
        maxLineHeight,
      ),
    );
  }

  static double _asDouble(Object? value, double fallback) {
    if (value is num) {
      return value.toDouble();
    }
    return fallback;
  }
}

/// 设置持久化服务（进程内共享，显式注入）。
///
/// 用法（见 lib/main.dart）：
///   ① 启动时 `final store = SettingsStore(dataDir); await store.load();`
///   ② 把实例通过构造参数注入 `MReaderApp`（显式注入，不用全局变量）；
///   ③ 页面在 `initState` 里 `store.addListener(_onChanged)`、
///      在 `dispose` 里 `store.removeListener(_onChanged)`，回调内 `setState`。
class SettingsStore {
  SettingsStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}settings.json',
          ),
        );

  final JsonStore _store;

  Settings _settings = const Settings();
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前设置（只读快照）。未 [load] 时返回默认值。
  Settings get settings => _settings;

  /// 是否已完成一次加载（显式初始化标志，供 UI 判断首帧 / 骨架屏）。
  bool get isLoaded => _loaded;

  /// 从磁盘加载设置；文件缺失或损坏时回退默认值（回退语义见 [JsonStore]）。
  Future<void> load() async {
    final Object? json = await _store.read();
    _settings = Settings.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 设置主题三态（`TYP-03`）。
  Future<void> setThemeMode(AppThemeMode mode) {
    if (_settings.themeMode == mode) {
      return Future<void>.value();
    }
    return _update(_settings.copyWith(themeMode: mode));
  }

  /// 设置字号（自动钳制到 `TYP-01` 取值范围内）。
  Future<void> setFontSize(double value) {
    final double clamped = value.clamp(Settings.minFontSize, Settings.maxFontSize);
    if (_settings.fontSize == clamped) {
      return Future<void>.value();
    }
    return _update(_settings.copyWith(fontSize: clamped));
  }

  /// 设置行距（自动钳制到 `TYP-01` 取值范围内）。
  Future<void> setLineHeight(double value) {
    final double clamped =
        value.clamp(Settings.minLineHeight, Settings.maxLineHeight);
    if (_settings.lineHeight == clamped) {
      return Future<void>.value();
    }
    return _update(_settings.copyWith(lineHeight: clamped));
  }

  /// 恢复默认设置（`TYP-01`「恢复默认」：18 / 1.6 / 跟随系统）。
  Future<void> resetToDefaults() => _update(const Settings());

  /// 订阅设置变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订设置变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 更新内存状态 → 通知监听者 → 原子落盘。
  Future<void> _update(Settings next) async {
    _settings = next;
    _notify();
    await _store.write(next.toJson());
  }

  /// 通知所有监听者；遍历副本以容忍回调内的订阅 / 退订。
  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
