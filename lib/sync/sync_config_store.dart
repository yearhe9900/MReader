// WebDAV 同步配置持久化（`SYNC-01` 连接配置 + `DATA-02` 凭据隔离）。
//
// 形制与 `ai/provider_store.dart` 完全同款（勿改）：进程内共享实例 + 监听回调
// （页面订阅 / 退订，**禁** Provider/Riverpod）；实例在 `main()` 显式创建注入，
// 不用可变全局单例；落盘经 [JsonStore] → [AtomicFile]（`DATA-01` 原子写入）。
//
// `DATA-02` ①：**密码结构性不进配置 JSON**——`sync_config.json` 只存
// [SyncConfig]（其 toJson 不含 password），密码单独走 [SyncPasswordVault]
// （SecureStore，前缀 `sync.password.`，与 `AiKeyVault` 的 `ai.key.` 命名空间
// 隔离）；备份包 / 日志里搜不到密码（`SYNC-04` / `DATA-02` ③）。
import 'dart:io';

import '../platform/secure_store.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'sync_config.dart';

/// WebDAV 密码门面（与 `AiKeyVault` 同形制：单一默认配置，一把密码）。
class SyncPasswordVault {
  /// 用底层 [SecureStore] 构造（组合根注入，见 `lib/main.dart`）。
  SyncPasswordVault(this._store);

  final SecureStore _store;

  /// 键前缀（与 `ai.key.` 等其它凭据隔离命名空间）。
  static const String prefix = 'sync.password.';

  /// 单配置槽位的存储键。
  static const String keyName = '${prefix}default';

  /// 读取 WebDAV 密码；未配置返 `null`。
  Future<String?> read() => _store.read(keyName);

  /// 写入（覆盖）密码；空串视作删除（不存空凭据）。
  Future<void> write(String password) async {
    if (password.isEmpty) {
      await _store.delete(keyName);
      return;
    }
    await _store.write(keyName, password);
  }

  /// 删除密码（幂等）。
  Future<void> delete() => _store.delete(keyName);

  /// 当前平台是否为**真正的系统安全存储**（`false` = 明文，UI 须标注）。
  bool get isSecure => _store.isSecure;

  /// 明文存储时的用户告知文案（`DATA-02` ③）。
  String get securityNotice => _store.securityNotice;
}

/// 同步配置存储（进程内共享，显式注入；用法见 `lib/main.dart`）：构造后
/// [load]，注入设置页 / 同步设置页（构造参数）；页面 `initState` 订阅、
/// `dispose` 退订，回调内 `setState`。
class SyncConfigStore {
  SyncConfigStore(Directory dataDir, SyncPasswordVault vault)
      : _vault = vault,
        _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}sync_config.json',
          ),
        );

  final JsonStore _store;
  final SyncPasswordVault _vault;

  SyncConfig? _config;
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前配置；未配置返 `null`（`SYNC-01`：配置后才能同步）。
  SyncConfig? get config => _config;

  /// 是否已完成一次配置。
  bool get isConfigured => _config != null;

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 密码门面（编辑页读 / 写密码、显示 `DATA-02` ③ 安全提示）。
  SyncPasswordVault get vault => _vault;

  /// 从磁盘加载；文件缺失或结构异常回退「未配置」。
  Future<void> load() async {
    final Object? json = await _store.read();
    _config = SyncConfig.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 保存（新增或替换唯一的连接配置）。
  Future<void> save(SyncConfig config) async {
    _config = config;
    _notify();
    await _store.write(config.toJson());
  }

  /// 删除配置（**连带删除密码**，避免孤儿凭据留在安全存储里）。
  Future<void> remove() async {
    _config = null;
    await _vault.delete();
    _notify();
    await _store.write(<String, Object?>{});
  }

  /// 读取密码（经 [SyncPasswordVault]，不落配置 JSON）。
  Future<String?> readPassword() => _vault.read();

  /// 写入密码（空串 = 删除，同 [SyncPasswordVault.write]）。
  Future<void> writePassword(String password) => _vault.write(password);

  /// 订阅变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 通知所有监听者（遍历副本，容忍回调内订阅 / 退订）。
  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
