// AI Provider 配置持久化（PRD `AI-01` 多配置 + `AI-09` 全局开关 / 最保守模式）。
//
// 设计约定（与 SettingsStore 同形制，勿改）：进程内共享实例 + 监听回调（页面
// 订阅 / 退订，**禁** Provider/Riverpod）；实例在 `main()` 显式创建注入，不用
// 可变全局单例；落盘经 [JsonStore] → [AtomicFile]（`DATA-01` 原子写入）。
//
// `DATA-02` ①：**apiKey 结构性不进本文件**——配置 JSON 只存 [AiProviderConfig]
// （其 toJson 不含 key），密钥单独走 [AiKeyVault]（SecureStore）；持久化文件
// 整体搜不到任何密钥。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'provider_config.dart';
import 'secure_key_store.dart';

/// AI 偏好值对象（不可变）。[configs] 为配置列表快照。
class AiPrefs {
  const AiPrefs({
    this.configs = const <AiProviderConfig>[],
    this.aiEnabled = defaultAiEnabled,
    this.selectionOnly = defaultSelectionOnly,
  });

  /// AI 功能总开关默认值（`AI-09`：用户可全局关闭）。
  static const bool defaultAiEnabled = true;

  /// 最保守模式默认值（`AI-09`：仅发送选中文本，默认开启）。
  static const bool defaultSelectionOnly = true;

  final List<AiProviderConfig> configs;

  /// 全局开关：关闭后所有 AI 功能入口隐藏 / 不发请求。
  final bool aiEnabled;

  /// 最保守模式：只允许把**选中文本**发送给 AI，不带整书 / 章节上下文。
  final bool selectionOnly;

  AiPrefs copyWith({
    List<AiProviderConfig>? configs,
    bool? aiEnabled,
    bool? selectionOnly,
  }) {
    return AiPrefs(
      configs: configs ?? this.configs,
      aiEnabled: aiEnabled ?? this.aiEnabled,
      selectionOnly: selectionOnly ?? this.selectionOnly,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'configs': configs.map((AiProviderConfig c) => c.toJson()).toList(),
        'aiEnabled': aiEnabled,
        'selectionOnly': selectionOnly,
      };

  /// 由持久化 JSON 还原；坏条目跳过、字段缺失回退默认。
  static AiPrefs fromJson(Object? json) {
    if (json is! Map) {
      return const AiPrefs();
    }
    final List<AiProviderConfig> configs = <AiProviderConfig>[];
    final Object? list = json['configs'];
    if (list is List) {
      for (final Object? item in list) {
        final AiProviderConfig? c = AiProviderConfig.fromJson(item);
        if (c != null) {
          configs.add(c);
        }
      }
    }
    return AiPrefs(
      configs: configs,
      aiEnabled: json['aiEnabled'] is bool
          ? json['aiEnabled'] as bool
          : defaultAiEnabled,
      selectionOnly: json['selectionOnly'] is bool
          ? json['selectionOnly'] as bool
          : defaultSelectionOnly,
    );
  }
}

/// AI Provider 配置存储（进程内共享，显式注入；用法见 `lib/main.dart`）：
/// 构造后 [load]，注入设置页 / AI 页（构造参数）；页面 `initState` 订阅、
/// `dispose` 退订，回调内 `setState`。
class ProviderStore {
  ProviderStore(Directory dataDir, AiKeyVault vault)
      : _vault = vault,
        _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}ai_providers.json',
          ),
        );

  final JsonStore _store;
  final AiKeyVault _vault;

  AiPrefs _prefs = const AiPrefs();
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前偏好（只读快照）。未 [load] 时返回默认值。
  AiPrefs get prefs => _prefs;

  /// 配置列表快照（只读）。
  List<AiProviderConfig> get configs => _prefs.configs;

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 密钥门面（编辑页读 / 写当前 key、显示 `DATA-02` ③ 安全提示）。
  AiKeyVault get vault => _vault;

  /// 从磁盘加载；文件缺失或损坏回退默认。
  Future<void> load() async {
    final Object? json = await _store.read();
    _prefs = AiPrefs.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 新配置 id（微秒时间戳，进程内稳定唯一；id 稳定挂靠密钥）。
  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// 新增或按 id 替换配置（`AI-01` ③ 多套可分别保存）。
  Future<void> saveConfig(AiProviderConfig config) {
    final List<AiProviderConfig> next = List<AiProviderConfig>.of(_prefs.configs);
    final int i = next.indexWhere((AiProviderConfig c) => c.id == config.id);
    if (i >= 0) {
      next[i] = config;
    } else {
      next.add(config);
    }
    return _update(_prefs.copyWith(configs: next));
  }

  /// 删除配置（**连带删除其密钥**，避免孤儿 key 留在安全存储里）。
  Future<void> removeConfig(String id) async {
    final List<AiProviderConfig> next = List<AiProviderConfig>.of(_prefs.configs)
      ..removeWhere((AiProviderConfig c) => c.id == id);
    await _vault.delete(id);
    await _update(_prefs.copyWith(configs: next));
  }

  /// 用途 → 生效配置（`AI-01`：每套配置声明 useFor；多个命中取列表首个）。
  /// 无命中返回 null，由调用方给出「未配置」引导。
  AiProviderConfig? configFor(AiUseCase useCase) {
    for (final AiProviderConfig c in _prefs.configs) {
      if (c.useFor.contains(useCase)) {
        return c;
      }
    }
    return null;
  }

  /// 读取某配置的密钥（经 [AiKeyVault]，不落配置 JSON）。
  Future<String?> readApiKey(String configId) => _vault.read(configId);

  /// 全局开关（`AI-09`）。
  Future<void> setAiEnabled(bool value) {
    if (_prefs.aiEnabled == value) {
      return Future<void>.value();
    }
    return _update(_prefs.copyWith(aiEnabled: value));
  }

  /// 最保守模式（`AI-09`：仅发送选中文本）。
  Future<void> setSelectionOnly(bool value) {
    if (_prefs.selectionOnly == value) {
      return Future<void>.value();
    }
    return _update(_prefs.copyWith(selectionOnly: value));
  }

  /// 订阅变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 更新内存 → 通知 → 原子落盘。
  Future<void> _update(AiPrefs next) async {
    _prefs = next;
    _notify();
    await _store.write(next.toJson());
  }

  /// 通知所有监听者（遍历副本，容忍回调内订阅 / 退订）。
  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
