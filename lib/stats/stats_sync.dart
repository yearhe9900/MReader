// 阅读统计跨设备同步（`STAT-08`，PRD §10.1/§10.2/§10.3）。
//
// 口径（`STAT-08`）：**按会话 `id` 并集**（跨设备按 id 并集幂等）——远端
// `stats/sessions-YYYY-MM.json` **按月分片**镜像本地 [SessionStore] 布局
// （PRD §10.3）；新 id 追加、同 id 时长不一致**取较大值**（[mergeById] 对称
// 裁决 → 收敛不震荡）；同一批数据重复同步总时长不变（幂等，收敛后零写入）。
// **默认开启、可单独关闭**（[StatsSyncPrefsStore] 落 `stats_sync.json`，**缺失
// 即 `true`**，fail-open）；开关判定在一切网络请求**之前**（关闭 = 零请求），
// 且关闭**不影响**进度 / 书签 / 设置 / 备份的同步。
//
// 为什么不用「取更新」（PRD §10.2 明文）：统计数据是**可累加的事实**而非可
// 回退的状态——按 id 并集 + 同 id 取大天然双向收敛。
//
// 触发范围（PRD §10.4）：与索引 / 书签 / 设置同批（退出 App 与手动「立即
// 同步」）；启动仅拉进度、退出阅读页只报进度。
import 'dart:convert';
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import '../sync/entry_sync.dart';
import '../sync/sync_config.dart';
import '../sync/sync_config_store.dart';
import '../sync/webdav_client.dart';
import 'reading_session.dart';
import 'session_store.dart';

/// 阅读统计同步开关持久化（`stats_sync.json`；**默认开**）。
/// 形制与 `BookUploadPrefsStore` 同款但**默认值相反**（`STAT-08` ③）：缺失 /
/// 损坏 / 结构不符一律视为开启（fail-open），显式 `enabled == false` 才关闭。
class StatsSyncPrefsStore {
  /// 用数据目录构造（组合根注入，见 `lib/main.dart`）。
  StatsSyncPrefsStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}stats_sync.json',
          ),
        );

  final JsonStore _store;

  bool _enabled = true;

  /// 是否允许统计同步（默认 `true`，`STAT-08` ③）。
  bool get enabled => _enabled;

  /// 从磁盘加载；缺失 / 损坏 / 结构不符 → 保持 `true`。
  Future<void> load() async {
    final Object? json = await _store.read();
    _enabled = json is! Map || json['enabled'] != false;
  }

  /// 保存开关（原子写入）。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _store.write(<String, Object?>{'enabled': value});
  }
}

/// 阅读统计同步引擎（`STAT-08`；进程内共享，组合根注入；退出 App 与手动
/// 「立即同步」经 `SyncTrigger._syncEntries` 调用）。
class StatsSync {
  /// 创建引擎（依赖由组合根注入，见 `lib/main.dart`）。
  StatsSync({
    required WebdavClient client,
    required SessionStore sessionStore,
    required SyncConfigStore configStore,
    required StatsSyncPrefsStore prefs,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _client = client, // ignore: prefer_initializing_formals
        _sessionStore = sessionStore, // ignore: prefer_initializing_formals
        _configStore = configStore, // ignore: prefer_initializing_formals
        _prefs = prefs; // ignore: prefer_initializing_formals

  /// 远端统计子目录（PRD §10.3 `stats/`；贴本地 [SessionStore.dirName]）。
  static const String remoteDir = SessionStore.dirName;

  final WebdavClient _client;
  final SessionStore _sessionStore;
  final SyncConfigStore _configStore;
  final StatsSyncPrefsStore _prefs;
  final RemoteDirCache _dirs = RemoteDirCache();

  /// 同步阅读统计（按月分片双向并集）；不抛业务异常：关闭 = 无事发生，
  /// 其余问题返回 failed + 可读 reason（`SYNC-07` 不静默）。
  Future<EntrySyncOutcome> sync() async {
    if (!_prefs.enabled) {
      // `STAT-08` ③：判定先于一切网络请求——关闭 = 零请求。
      return _outcome(localChanged: false, remoteChanged: false);
    }
    try {
      final ({SyncConfig config, String password}) ctx =
          await requireWebdav(_configStore);
      return await _sync(ctx.config, ctx.password);
    } on SyncException catch (e) {
      return _failed(e.message);
    }
  }

  Future<EntrySyncOutcome> _sync(SyncConfig config, String password) async {
    final List<ReadingSession> local = await _sessionStore.loadAll();
    final Map<String, ReadingSession> localById = <String, ReadingSession>{
      for (final ReadingSession s in local) s.id: s,
    };
    final Map<String, List<ReadingSession>> localByShard =
        <String, List<ReadingSession>>{};
    for (final ReadingSession s in local) {
      localByShard
          .putIfAbsent(
            SessionStore.shardKeyOf(s.startedAt),
            () => <ReadingSession>[],
          )
          .add(s);
    }

    // 分片全集 = 本地有记录的月份 ∪ 远端存在的分片（远端独有月份要能拉下来）。
    final Set<String> remoteKeys = await _remoteShardKeys(config, password);
    final Set<String> keys = <String>{...localByShard.keys, ...remoteKeys};
    if (keys.isEmpty) {
      return _outcome(localChanged: false, remoteChanged: false);
    }

    bool localChanged = false;
    bool remoteChanged = false;
    int addedFromRemote = 0;
    int addedFromLocal = 0;
    for (final String key in keys.toList()..sort()) {
      final String path = _shardPath(key);
      final List<ReadingSession> localShard =
          localByShard[key] ?? const <ReadingSession>[];
      final List<ReadingSession> remoteShard;
      if (remoteKeys.contains(key)) {
        final List<ReadingSession>? decoded =
            _decodeShard(await _client.download(config, password, path));
        if (decoded == null) {
          // 单分片损坏：整轮跳过且不动远端（不拿本地覆盖未知内容）。
          return _failed('远端统计文件损坏，已跳过');
        }
        remoteShard = decoded;
      } else {
        remoteShard = const <ReadingSession>[];
      }

      final MergeResult<ReadingSession> result = mergeById<ReadingSession>(
        local: localShard,
        remote: remoteShard,
        idOf: (ReadingSession s) => s.id,
        encode: (ReadingSession s) => jsonEncode(s.toJson()),
        resolve: _resolve,
      );

      // 本地写入交回 [SessionStore.merge]（并集 + 幂等 + 无变化不落盘）；
      // 变更按 store 实际写入条件判（同 id 取**较大** duration 才写）——
      // `mergeById` 的内容级 localChanged 在「同 id 同时长坐标略异」时会多报。
      if (_storeWouldChange(result.merged, localById)) {
        localChanged = true;
        await _sessionStore.merge(result.merged);
      }
      if (result.remoteChanged) {
        await _dirs.ensure(_client, config, password, remoteDir);
        await _client.upload(
          config,
          password,
          path,
          utf8.encode(_encodeShard(result.merged)),
        );
        remoteChanged = true;
      }
      addedFromRemote += result.addedFromRemote;
      addedFromLocal += result.addedFromLocal;
    }
    return _outcome(
      localChanged: localChanged,
      remoteChanged: remoteChanged,
      addedFromRemote: addedFromRemote,
      addedFromLocal: addedFromLocal,
    );
  }

  /// 远端 `stats/` 下的分片键集合；目录不存在（404）→ 空集。
  Future<Set<String>> _remoteShardKeys(
    SyncConfig config,
    String password,
  ) async {
    final List<WebdavEntry> entries;
    try {
      entries = await _client.list(config, password, remoteDir);
    } on SyncException catch (e) {
      if (e.kind == SyncErrorKind.notFound) {
        return <String>{};
      }
      rethrow;
    }
    final Set<String> keys = <String>{};
    for (final WebdavEntry entry in entries) {
      if (entry.isCollection) {
        continue;
      }
      final String name = entry.path.split('/').last;
      if (SessionStore.isShardName(name)) {
        keys.add(
          name.substring(
            SessionStore.filePrefix.length,
            name.length - SessionStore.fileSuffix.length,
          ),
        );
      }
    }
    return keys;
  }

  /// 分片键 → 远端路径（`stats/sessions-YYYY-MM.json`，镜像本地布局）。
  String _shardPath(String key) =>
      '$remoteDir/${SessionStore.filePrefix}$key${SessionStore.fileSuffix}';

  /// 同 id 冲突裁决（`STAT-08`：时长不一致取**较大值**；平局按内容字典序
  /// 取大——纯内容、双侧同判 → 收敛，同 [byContent] 口径）。
  static ReadingSession _resolve(ReadingSession local, ReadingSession remote) {
    if (local.duration != remote.duration) {
      return local.duration > remote.duration ? local : remote;
    }
    return _tieBreak(local, remote);
  }

  static final ReadingSession Function(ReadingSession, ReadingSession)
      _tieBreak = byContent<ReadingSession>(
    (ReadingSession s) => jsonEncode(s.toJson()),
  );

  /// [SessionStore.merge] 的实际写入条件（同 id 取**较大** duration 才写）。
  static bool _storeWouldChange(
    List<ReadingSession> merged,
    Map<String, ReadingSession> localById,
  ) {
    for (final ReadingSession s in merged) {
      final ReadingSession? old = localById[s.id];
      if (old == null || s.duration > old.duration) {
        return true;
      }
    }
    return false;
  }

  /// 远端分片字节 → 会话列表；**顶层结构不符 → `null`（损坏）**；坏条目 /
  /// `duration <= 0` 条目跳过；同 id 取较大 `duration`（口径同 [SessionStore]）。
  List<ReadingSession>? _decodeShard(List<int> bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
    if (raw is! Map) {
      return null;
    }
    final Object? list = raw['sessions'];
    if (list is! List) {
      return null;
    }
    final Map<String, ReadingSession> out = <String, ReadingSession>{};
    for (final Object? item in list) {
      final ReadingSession? s = ReadingSession.fromJson(item);
      if (s == null || s.duration <= 0) {
        continue;
      }
      final ReadingSession? old = out[s.id];
      if (old == null || s.duration > old.duration) {
        out[s.id] = s;
      }
    }
    return out.values.toList();
  }

  /// 会话列表 → 分片 JSON（与本地落盘同构 `{"sessions": [...]}`，
  /// 排序口径同 [SessionStore.byStart]——同内容恒同字节）。
  String _encodeShard(List<ReadingSession> sessions) {
    final List<ReadingSession> sorted = List<ReadingSession>.of(sessions)
      ..sort(SessionStore.byStart);
    return jsonEncode(<String, Object?>{
      'sessions': <Object?>[for (final ReadingSession s in sorted) s.toJson()],
    });
  }

  EntrySyncOutcome _outcome({
    required bool localChanged,
    required bool remoteChanged,
    int addedFromRemote = 0,
    int addedFromLocal = 0,
  }) =>
      EntrySyncOutcome(
        collection: remoteDir,
        localChanged: localChanged,
        remoteChanged: remoteChanged,
        addedFromRemote: addedFromRemote,
        addedFromLocal: addedFromLocal,
      );

  EntrySyncOutcome _failed(String reason) => EntrySyncOutcome(
        collection: remoteDir,
        localChanged: false,
        remoteChanged: false,
        reason: reason,
      );
}
