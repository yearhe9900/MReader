// 朗读设置持久化（语速 / 音色 / 跟随系统语速 / 定时停止）。
//
// 与 [ShelfPrefsStore] **同一形制**，勿另创写法：落盘一律经 `JsonStore` → `AtomicFile`
// （`DATA-01` 原子写入）；跨页面共享用「进程内共享实例 + 监听回调」（页面 `initState`
// 订阅、`dispose` 退订、回调内 `setState`，**不引入 Provider / Riverpod**）；
// **不使用可变全局单例**（实例在 `main()` 显式创建并构造注入）。
//
// 为什么单独一个文件：进度联动（TTS-06）**不在此**——朗读进度复用 `ReadingProgress`
// 单一模型，本文件只管「怎么读」（多快、哪个音色、读多久停）。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 朗读引擎选择（`TTS-07` 双引擎，PRD §9.1）。
enum TtsEngineKind {
  /// 系统 TTS（默认，零配置离线可用）。
  system('系统 TTS'),

  /// 在线 TTS（配置见 `OnlineTtsStore`；声音不满意时的补救）。
  online('在线 TTS');

  const TtsEngineKind(this.label);

  /// 中文展示名。
  final String label;

  /// 由持久化解析；未知值回落系统引擎。
  static TtsEngineKind tryParse(String? name) {
    for (final TtsEngineKind k in TtsEngineKind.values) {
      if (k.name == name) return k;
    }
    return TtsEngineKind.system;
  }
}

/// 朗读设置值对象（不可变）。
class TtsSettings {
  /// 创建朗读设置。
  const TtsSettings({
    this.engine = TtsEngineKind.system,
    this.rate = defaultRate,
    this.followSystemRate = false,
    this.voiceName,
    this.voiceLocale,
    this.sleepMinutes = 0,
  });

  /// 朗读引擎（`TTS-07`；默认系统 TTS）。
  final TtsEngineKind engine;

  /// 语速，flutter_tts 口径 0~1.5（0.5 = 系统正常速；Android 插件
  /// `setSpeechRate(rate * 2)`，故 0.5 → Android 1.0）。越界回退/夹紧。
  final double rate;

  /// 跟随系统语速：开启时忽略 [rate]，应用侧写回默认 0.5（flutter_tts
  /// 初始语速即系统正常速）——开关切换立即回到正常速（TTS-04）。
  final bool followSystemRate;

  /// 音色名（`getVoices` 的 `name`）；`null` = 系统默认音色（TTS-04②）。
  final String? voiceName;

  /// 音色 locale（`getVoices` 的 `locale`）；与 [voiceName] 成对提交。
  final String? voiceLocale;

  /// 定时停止分钟数：`0` = 关闭；否则 10~180 且为 10 的倍数（TTS-05）。
  final int sleepMinutes;

  /// 默认语速（= 系统正常速）。
  static const double defaultRate = 0.5;

  /// 语速下界（flutter_tts 0.0~1.0，Android validRange 0~1.5 取宽者）。
  static const double minRate = 0.0;

  /// 语速上界（Android `getSpeechRateValidRange` max = 1.5）。
  static const double maxRate = 1.5;

  /// 定时停止下界（分钟）。
  static const int minSleepMinutes = 10;

  /// 定时停止上界（分钟，PRD §9.5「上限 180 分钟」）。
  static const int maxSleepMinutes = 180;

  /// 定时停止步进（分钟）。
  static const int sleepStepMinutes = 10;

  /// 复制并覆盖部分字段。可空字段（[voiceName] / [voiceLocale]）**无法用它显式
  /// 置空**（`null` = 不修改）；回到默认音色走 [TtsSettingsStore.setVoice] 传
  /// `null`，它直接构造新值对象。
  TtsSettings copyWith({
    TtsEngineKind? engine,
    double? rate,
    bool? followSystemRate,
    String? voiceName,
    String? voiceLocale,
    int? sleepMinutes,
  }) {
    return TtsSettings(
      engine: engine ?? this.engine,
      rate: rate ?? this.rate,
      followSystemRate: followSystemRate ?? this.followSystemRate,
      voiceName: voiceName ?? this.voiceName,
      voiceLocale: voiceLocale ?? this.voiceLocale,
      sleepMinutes: sleepMinutes ?? this.sleepMinutes,
    );
  }

  /// 序列化；等于默认值的键**省略**，保持文件最小形态。
  Map<String, Object?> toJson() => <String, Object?>{
        if (engine != TtsEngineKind.system) 'engine': engine.name,
        if (rate != defaultRate) 'rate': rate,
        if (followSystemRate) 'followSystemRate': followSystemRate,
        if (voiceName != null) 'voiceName': voiceName,
        if (voiceLocale != null) 'voiceLocale': voiceLocale,
        if (sleepMinutes != 0) 'sleepMinutes': sleepMinutes,
      };

  /// 由持久化 JSON 还原；字段缺失 / 类型异常时逐项回退默认值。
  static TtsSettings fromJson(Object? json) {
    if (json is! Map) {
      return const TtsSettings();
    }
    final Object? rawEngine = json['engine'];
    final Object? rawRate = json['rate'];
    final Object? rawSleep = json['sleepMinutes'];
    final Object? rawName = json['voiceName'];
    final Object? rawLocale = json['voiceLocale'];
    final Object? rawFollow = json['followSystemRate'];
    return TtsSettings(
      engine: TtsEngineKind.tryParse(rawEngine is String ? rawEngine : null),
      rate: rawRate is num ? clampRate(rawRate.toDouble()) : defaultRate,
      followSystemRate: rawFollow is bool ? rawFollow : false,
      voiceName: rawName is String && rawName.isNotEmpty ? rawName : null,
      voiceLocale: rawLocale is String && rawLocale.isNotEmpty ? rawLocale : null,
      sleepMinutes: rawSleep is int ? clampSleep(rawSleep) : 0,
    );
  }

  /// 把任意语速夹到 `[minRate, maxRate]`；NaN / Infinity 回退默认。
  static double clampRate(double value) {
    if (value.isNaN || value.isInfinite) {
      return defaultRate;
    }
    return value.clamp(minRate, maxRate);
  }

  /// 把任意分钟数归一到 `0`（关闭）或 `[10, 180]` 的 10 分钟档。
  ///
  /// 向下取整到最近档（`180` 封顶后仍落在档位上）。
  static int clampSleep(int value) {
    if (value <= 0) {
      return 0;
    }
    final int clamped = value > maxSleepMinutes ? maxSleepMinutes : value;
    final int stepped = (clamped ~/ sleepStepMinutes) * sleepStepMinutes;
    if (stepped < minSleepMinutes) {
      return minSleepMinutes;
    }
    return stepped > maxSleepMinutes ? maxSleepMinutes : stepped;
  }

  @override
  bool operator ==(Object other) =>
      other is TtsSettings &&
      other.engine == engine &&
      other.rate == rate &&
      other.followSystemRate == followSystemRate &&
      other.voiceName == voiceName &&
      other.voiceLocale == voiceLocale &&
      other.sleepMinutes == sleepMinutes;

  @override
  int get hashCode =>
      Object.hash(engine, rate, followSystemRate, voiceName, voiceLocale, sleepMinutes);
}

/// 朗读设置持久化服务（进程内共享，显式注入）。
class TtsSettingsStore {
  /// 创建存储（`dataDir` 通常来自 `AppPaths.dataDir()`）。
  TtsSettingsStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}tts_settings.json',
          ),
        );

  final JsonStore _store;

  TtsSettings _value = const TtsSettings();
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前设置（只读快照）。未 [load] 时返回默认值。
  TtsSettings get value => _value;

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 从磁盘加载；文件缺失或损坏时回退默认值（回退语义见 [JsonStore]）。
  Future<void> load() async {
    final Object? json = await _store.read();
    _value = TtsSettings.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 设朗读引擎（`TTS-07`：系统 / 在线）。
  Future<void> setEngine(TtsEngineKind engine) {
    if (_value.engine == engine) {
      return Future<void>.value();
    }
    return _update(_value.copyWith(engine: engine));
  }

  /// 设语速（自动夹到合法区间）。
  Future<void> setRate(double rate) {
    return _update(_value.copyWith(rate: TtsSettings.clampRate(rate)));
  }

  /// 开 / 关「跟随系统语速」。
  Future<void> setFollowSystemRate(bool follow) {
    if (_value.followSystemRate == follow) {
      return Future<void>.value();
    }
    return _update(_value.copyWith(followSystemRate: follow));
  }

  /// 选音色；`name` / `locale` 任一为 `null` 即回到系统默认（清音色）。`copyWith`
  /// 的可空参数无法显式置空 → 回默认路径直接构造新值对象。
  Future<void> setVoice({String? name, String? locale}) {
    if (name == null || name.isEmpty || locale == null || locale.isEmpty) {
      if (_value.voiceName == null && _value.voiceLocale == null) {
        return Future<void>.value();
      }
      return _update(
        TtsSettings(
          engine: _value.engine,
          rate: _value.rate,
          followSystemRate: _value.followSystemRate,
          voiceName: null,
          voiceLocale: null,
          sleepMinutes: _value.sleepMinutes,
        ),
      );
    }
    if (_value.voiceName == name && _value.voiceLocale == locale) {
      return Future<void>.value();
    }
    return _update(_value.copyWith(voiceName: name, voiceLocale: locale));
  }

  /// 设定时停止；`0` = 关闭，其余夹到 10~180 并对齐 10 分钟步进。
  Future<void> setSleepMinutes(int minutes) {
    return _update(
      _value.copyWith(sleepMinutes: TtsSettings.clampSleep(minutes)),
    );
  }

  /// 订阅设置变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订设置变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 更新内存状态 → 通知监听者 → 原子落盘。
  Future<void> _update(TtsSettings next) async {
    if (next == _value) {
      return;
    }
    _value = next;
    _notify();
    await _store.write(next.toJson());
  }

  /// 通知所有监听者；遍历副本以容忍回调内的订阅 / 退订。
  void _notify() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
