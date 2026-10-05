// `M4-T03`：阅读设置同步（`SYNC-03`，PRD §10.1「阅读设置：字号/行距/边距/
// 主题/字体/亮度 —— 增量，取最近修改」）。
//
// 单文件双向同步 `settings/reading_prefs.json`（内容 = 本地
// `prefs/reading_prefs.json` 同构，即 `ReadingPrefs.toJson()`）。判定顺序：
//   ① 远端缺失 → 本地有则上传，双无 → 无事；
//   ② 内容相等 → 不写任何一侧（防「下载→本地 mtime 变新→再上传」回声）；
//   ③ 内容不同 → 比**修改时间**，新者胜（验收③「设置冲突以最近修改为准」）；
//      时间戳缺失的一方视为最旧（对端胜）；完全同刻 → 远端胜（云端为准，
//      双侧同判 → 收敛）。
//
// 本地修改时间取偏好**文件 mtime**（原子写入的时间即用户改动时刻），不给
// `ReadingPrefs` 加时间字段——不动 `TYP-06` 数据模型。
import 'dart:convert';
import 'dart:io';

import '../reader/reading_prefs.dart';
import '../reader/reading_prefs_store.dart';
import 'entry_sync.dart';
import 'sync_config.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

/// 阅读设置同步引擎（进程内共享，显式注入；触发时机由 `M4-T05` 编排）。
class SettingsSync {
  /// 创建引擎（组合根注入，见 `lib/main.dart`）。
  SettingsSync({
    required WebdavClient client,
    required ReadingPrefsStore prefsStore,
    required SyncConfigStore configStore,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _client = client, // ignore: prefer_initializing_formals
        _prefsStore = prefsStore, // ignore: prefer_initializing_formals
        _configStore = configStore; // ignore: prefer_initializing_formals

  /// 远端设置路径（相对远端根；贴本地 `prefs/` 语义）。
  static const String remotePath = 'settings/reading_prefs.json';

  final WebdavClient _client;
  final ReadingPrefsStore _prefsStore;
  final SyncConfigStore _configStore;
  final RemoteDirCache _dirs = RemoteDirCache();

  /// 同步阅读设置（单文件，「取最近修改」）。
  ///
  /// 不抛业务异常：通道 / 配置 / 数据问题一律返回 failed + 可读 reason。
  Future<EntrySyncOutcome> sync() async {
    try {
      final ({SyncConfig config, String password}) ctx =
          await requireWebdav(_configStore);
      return await _sync(ctx.config, ctx.password);
    } on SyncException catch (e) {
      return _failed(e.message);
    }
  }

  Future<EntrySyncOutcome> _sync(SyncConfig config, String password) async {
    final ReadingPrefs? local = await _prefsStore.load();
    final WebdavEntry? entry = await _client.stat(config, password, remotePath);

    if (entry == null) {
      if (local == null) {
        return _outcome(localChanged: false, remoteChanged: false);
      }
      await _dirs.ensure(_client, config, password, 'settings');
      await _upload(config, password, local);
      return _outcome(
        localChanged: false,
        remoteChanged: true,
        addedFromLocal: 1,
      );
    }

    // 下载放 try 外：通道失败（SyncException）要走外层收编，不能误报「损坏」。
    final List<int> bytes =
        await _client.download(config, password, remotePath);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return _failed('远端设置文件损坏，已跳过');
    }
    if (decoded is! Map) {
      return _failed('远端设置文件损坏，已跳过');
    }
    final ReadingPrefs remote = ReadingPrefs.fromJson(decoded);

    if (local == null) {
      await _prefsStore.save(remote);
      return _outcome(
        localChanged: true,
        remoteChanged: false,
        addedFromRemote: 1,
      );
    }
    if (local == remote) {
      // 内容一致：双侧无事（防回声——任何一侧落盘都会让 mtime 变新）。
      return _outcome(localChanged: false, remoteChanged: false);
    }

    // ③ 取最近修改：时间戳缺失 / 本地文件丢失的一方视为最旧 → 对端胜。
    final DateTime? remoteModified = entry.lastModified;
    if (remoteModified == null) {
      await _upload(config, password, local);
      return _outcome(
        localChanged: false,
        remoteChanged: true,
        addedFromLocal: 1,
      );
    }
    final int? localModified = await _localModifiedMs();
    if (localModified != null &&
        localModified > remoteModified.toUtc().millisecondsSinceEpoch) {
      await _upload(config, password, local);
      return _outcome(
        localChanged: false,
        remoteChanged: true,
        addedFromLocal: 1,
      );
    }
    await _prefsStore.save(remote);
    return _outcome(
      localChanged: true,
      remoteChanged: false,
      addedFromRemote: 1,
    );
  }

  /// 本地偏好文件的修改时间（Unix 毫秒）；文件丢失 / stat 失败 → `null`。
  Future<int?> _localModifiedMs() async {
    try {
      final File file = await _prefsStore.file();
      if (!await file.exists()) {
        return null;
      }
      final FileStat stat = await file.stat();
      return stat.modified.toUtc().millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  Future<void> _upload(SyncConfig config, String password, ReadingPrefs prefs) {
    final List<int> bytes = utf8.encode(jsonEncode(prefs.toJson()));
    return _client.upload(config, password, remotePath, bytes);
  }

  EntrySyncOutcome _outcome({
    required bool localChanged,
    required bool remoteChanged,
    int addedFromRemote = 0,
    int addedFromLocal = 0,
    String? reason,
  }) =>
      EntrySyncOutcome(
        collection: remotePath.replaceAll('.json', ''),
        localChanged: localChanged,
        remoteChanged: remoteChanged,
        addedFromRemote: addedFromRemote,
        addedFromLocal: addedFromLocal,
        reason: reason,
      );

  EntrySyncOutcome _failed(String reason) => _outcome(
        localChanged: false,
        remoteChanged: false,
        reason: reason,
      );
}
