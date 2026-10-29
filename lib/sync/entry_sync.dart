// 按条目合并的同步机制 + 书库索引同步（`SYNC-03`，PRD §10.1/§10.2）。
//
// `SYNC-03` 核心是「**按条目合并而非整包覆盖**」：两侧各有的条目都保留，同 key
// 冲突按内容裁决（双侧对称 → 收敛不震荡）。本文件提供：[mergeById] 通用并集
// 合并（纯函数）、[byContent] 同 key 对称裁决器、[IndexSync] 书库索引
// `library/index.json` 同步（统计并集亦复用 [mergeById]）、[requireWebdav] /
// [RemoteDirCache] 各引擎共用件。
//
// 远端路径约定（PRD §10.3 只点名 `bookProgress/`，其余命名贴本地布局）：
// 书签 `bookmarks/{bookId}.json`、设置 `settings/reading_prefs.json`、
// 索引 `library/index.json`、统计 `stats/sessions-YYYY-MM.json`（按月分片）。
//
// 范围注记（诚实降级，`NF-C8`）：「笔记」当前只有占位页、无存储，待落地后并入
// [mergeById] 同机制；书签**删除不跨设备传播**（并集语义下无墓碑，PRD 未定义
// 删除同步）——一端删除后再次同步会被对端并回，属已知口径。
import 'dart:convert';

import '../library/book_index.dart';
import '../library/book_record.dart';
import '../model/book_meta.dart';
import 'sync_config.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 通用按条目合并（纯函数）
// ─────────────────────────────────────────────────────────────────────────────

/// 并集合并的结果。
class MergeResult<T> {
  /// 创建结果。
  const MergeResult({
    required this.merged,
    required this.localChanged,
    required this.remoteChanged,
    required this.addedFromRemote,
    required this.addedFromLocal,
  });

  /// 合并后全集（本地顺序在前，远端独有条目追加在后；同侧同 key 保留首条）。
  final List<T> merged;

  /// `merged` 与本地内容不同（有远端新增、或冲突判给了远端）→ 本地需落盘。
  final bool localChanged;

  /// `merged` 与远端内容不同 → 远端需上传。
  final bool remoteChanged;

  /// 本次从远端并入本地的新条目数（key 只在远端出现）。
  final int addedFromRemote;

  /// 本次可推上远端的新条目数（key 只在本地出现）。
  final int addedFromLocal;
}

/// 按 key 并集合并（`SYNC-03`「按条目合并」的通用实现，纯函数）。
///
/// - [idOf]：条目身份（书签 `createdAt`、索引 `bookId`）；
/// - [encode]：内容指纹（通常 `jsonEncode(item.toJson())`）——变更按内容判定，
///   同内容不同引用不计变更（**防无谓回写**）；
/// - [resolve]：同 key 裁决——**必须双侧对称**（见 [byContent]），否则双侧
///   各判各赢、每次同步来回覆盖。
///
/// 变更口径：`localChanged` = 本地有「远端独有 key」或「冲突后内容不同」，
/// `remoteChanged` 对称；两侧一致时皆 `false`（幂等）。
MergeResult<T> mergeById<T>({
  required List<T> local,
  required List<T> remote,
  required String Function(T) idOf,
  required String Function(T) encode,
  required T Function(T local, T remote) resolve,
}) {
  final Map<String, T> localMap = <String, T>{};
  for (final T item in local) {
    localMap.putIfAbsent(idOf(item), () => item);
  }
  final Map<String, T> remoteMap = <String, T>{};
  for (final T item in remote) {
    remoteMap.putIfAbsent(idOf(item), () => item);
  }

  final List<T> merged = <T>[];
  final Map<String, String> mergedContent = <String, String>{};
  for (final MapEntry<String, T> entry in localMap.entries) {
    final T? other = remoteMap[entry.key];
    final T winner = other == null ? entry.value : resolve(entry.value, other);
    merged.add(winner);
    mergedContent[entry.key] = encode(winner);
  }
  int addedFromLocal = 0;
  for (final MapEntry<String, T> entry in remoteMap.entries) {
    if (localMap.containsKey(entry.key)) {
      continue;
    }
    merged.add(entry.value);
    mergedContent[entry.key] = encode(entry.value);
  }

  final Map<String, String> localContent = <String, String>{
    for (final MapEntry<String, T> e in localMap.entries) e.key: encode(e.value),
  };
  final Map<String, String> remoteContent = <String, String>{
    for (final MapEntry<String, T> e in remoteMap.entries)
      e.key: encode(e.value),
  };
  int addedFromRemote = 0;
  for (final String key in mergedContent.keys) {
    if (!localContent.containsKey(key)) {
      addedFromRemote += 1;
    }
  }
  for (final String key in localContent.keys) {
    if (!remoteContent.containsKey(key)) {
      addedFromLocal += 1;
    }
  }
  final bool localChanged = mergedContent.entries.any(
    (MapEntry<String, String> e) => localContent[e.key] != e.value,
  );
  final bool remoteChanged = mergedContent.entries.any(
    (MapEntry<String, String> e) => remoteContent[e.key] != e.value,
  );

  return MergeResult<T>(
    merged: merged,
    localChanged: localChanged,
    remoteChanged: remoteChanged,
    addedFromRemote: addedFromRemote,
    addedFromLocal: addedFromLocal,
  );
}

/// 内容裁决器：同 key 冲突取**内容 JSON 字典序较大者**；纯内容决定 →
/// `resolve(l, r)` 与 `resolve(r, l)` 同一胜者（对称），双侧判出同内容 →
/// 收敛；内容相同不计变更、不产生回写。
T Function(T local, T remote) byContent<T>(String Function(T) encode) {
  return (T local, T remote) {
    final String left = encode(local);
    final String right = encode(remote);
    if (left == right) {
      return local;
    }
    return left.compareTo(right) > 0 ? local : remote;
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 共用件：连接上下文 / 远端目录确保 / 同步结果与汇总
// ─────────────────────────────────────────────────────────────────────────────

/// 解析 WebDAV 连接上下文；未配置 / 密码缺失 → 抛 [SyncException]
/// （可读中文，调用方收编为 failed 结果——`SYNC-07` 不静默）。
Future<({SyncConfig config, String password})> requireWebdav(
  SyncConfigStore store,
) async {
  final SyncConfig? config = store.config;
  if (config == null) {
    throw SyncException(SyncErrorKind.unknown, message: '尚未配置 WebDAV 同步');
  }
  final String? password = await store.readPassword();
  if (password == null || password.isEmpty) {
    throw SyncException(SyncErrorKind.unknown, message: '尚未保存 WebDAV 密码');
  }
  return (config: config, password: password);
}

/// 远端目录确保器：`ensureDirectory` 结果按 `url|dir|under` 记忆，
/// 同配置只 MKCOL 一次（失败不记忆，下次重试——形制同 `progress_sync`）。
class RemoteDirCache {
  final Set<String> _done = <String>{};

  /// 确保 `under` 目录存在（幂等）。
  Future<void> ensure(
    WebdavClient client,
    SyncConfig config,
    String password,
    String under,
  ) async {
    final String key = '${config.url}|${config.dir}|$under';
    if (_done.contains(key)) {
      return;
    }
    await client.ensureDirectory(config, password, under: under);
    _done.add(key);
  }
}

/// 单个集合的同步结果（`SYNC-07`：失败带可读原因）。
class EntrySyncOutcome {
  /// 创建结果。
  const EntrySyncOutcome({
    required this.collection,
    required this.localChanged,
    required this.remoteChanged,
    this.addedFromRemote = 0,
    this.addedFromLocal = 0,
    this.reason,
  });

  /// 集合标识（远端路径：`bookmarks/<bookId>` / `settings/reading_prefs` /
  /// `library/index` / `stats`）。
  final String collection;

  /// 本地是否发生写入。
  final bool localChanged;

  /// 远端是否发生写入。
  final bool remoteChanged;

  /// 并入本地的远端条目数（设置按 1 计）。
  final int addedFromRemote;

  /// 推上远端的本地条目数（设置按 1 计）。
  final int addedFromLocal;

  /// 失败时的中文可读原因（成功为 `null`）。
  final String? reason;

  /// 是否失败。
  bool get failed => reason != null;

  /// 是否有任何一侧写入。
  bool get changed => localChanged || remoteChanged;

  @override
  String toString() =>
      'EntrySyncOutcome($collection, local: $localChanged, '
      'remote: $remoteChanged${reason == null ? '' : ', $reason'})';
}

/// 一轮条目同步的汇总（`SYNC-07`：失败项汇总提示，可重试）。
class EntrySyncReport {
  /// 创建汇总。
  const EntrySyncReport(this.outcomes);

  /// 逐集合结果。
  final List<EntrySyncOutcome> outcomes;

  /// 是否无失败。
  bool get ok => outcomes.every((EntrySyncOutcome o) => !o.failed);

  /// 失败清单（含可读原因）。
  List<EntrySyncOutcome> get failures => outcomes
      .where((EntrySyncOutcome o) => o.failed)
      .toList(growable: false);

  /// 发生本地写入的集合数。
  int get localUpdated =>
      outcomes.where((EntrySyncOutcome o) => o.localChanged).length;

  /// 发生远端写入的集合数。
  int get remoteUpdated =>
      outcomes.where((EntrySyncOutcome o) => o.remoteChanged).length;

  /// 中文汇总行（UI / 日志直接回显）。
  String get summary => '本地更新 $localUpdated 项 · '
      '远端更新 $remoteUpdated 项 · '
      '失败 ${failures.length} 项';
}

// ─────────────────────────────────────────────────────────────────────────────
// 书库索引同步
// ─────────────────────────────────────────────────────────────────────────────

/// 书库索引同步（`SYNC-03` 四类范围之一：书名 / 作者 / 格式 / 路径 / 导入时间 /
/// 元数据来源标记与封面引用，按条目并集合并）。
///
/// 冲突（同 `bookId` 两侧内容不同）走 [resolveIndexConflict]：① `lastReadAt`
/// 新者胜（阅读活动是客观时序）；② 有用户手动编辑标记（任一 origin == `user`）
/// 者胜（`META-09` 用户编辑不被重新解析覆盖）；③ 内容 JSON 字典序大者胜
/// （纯内容、双侧同判 → 收敛）。
class IndexSync {
  /// 创建索引同步引擎（组合根注入，见 `lib/main.dart`）。
  IndexSync({
    required WebdavClient client,
    required BookIndex index,
    required SyncConfigStore configStore,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _client = client, // ignore: prefer_initializing_formals
        _index = index, // ignore: prefer_initializing_formals
        _configStore = configStore; // ignore: prefer_initializing_formals

  /// 远端索引路径（相对远端根；与本地 `library/index.json` 同名同形）。
  static const String remotePath = 'library/index.json';

  final WebdavClient _client;
  final BookIndex _index;
  final SyncConfigStore _configStore;
  final RemoteDirCache _dirs = RemoteDirCache();

  /// 同步书库索引（单文件，双向并集合并）；不抛业务异常：通道 / 配置 /
  /// 数据问题一律返回 failed + 可读 reason。
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
    final List<BookRecord> local = await _index.load();
    final WebdavEntry? entry = await _client.stat(config, password, remotePath);
    if (entry == null) {
      if (local.isEmpty) {
        return _outcome(localChanged: false, remoteChanged: false);
      }
      await _dirs.ensure(_client, config, password, 'library');
      await _upload(config, password, local);
      return _outcome(
        localChanged: false,
        remoteChanged: true,
        addedFromLocal: local.length,
      );
    }

    final List<BookRecord>? remote = _decodeRemote(
      await _client.download(config, password, remotePath),
    );
    if (remote == null) {
      return _failed('远端索引文件损坏，已跳过');
    }

    final MergeResult<BookRecord> result = mergeById<BookRecord>(
      local: local,
      remote: remote,
      idOf: (BookRecord r) => r.bookId,
      encode: (BookRecord r) => jsonEncode(r.toJson()),
      resolve: resolveIndexConflict,
    );
    if (result.localChanged) {
      await _index.save(result.merged);
    }
    if (result.remoteChanged) {
      await _upload(config, password, result.merged);
    }
    return _outcome(
      localChanged: result.localChanged,
      remoteChanged: result.remoteChanged,
      addedFromRemote: result.addedFromRemote,
      addedFromLocal: result.addedFromLocal,
    );
  }

  /// 远端索引字节 → 记录列表；**顶层非数组 → `null`（损坏）**；
  /// 数组内单条损坏 → 跳过该条（`LIB-03` 逐条降级同款）。
  List<BookRecord>? _decodeRemote(List<int> bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
    if (raw is! List) {
      return null;
    }
    final List<BookRecord> records = <BookRecord>[];
    for (final Object? item in raw) {
      try {
        if (item is Map<String, Object?>) {
          records.add(BookRecord.fromJson(Map<String, Object?>.from(item)));
        }
      } catch (_) {
        // 单条损坏跳过（不整包作废）。
      }
    }
    return records;
  }

  Future<void> _upload(
    SyncConfig config,
    String password,
    List<BookRecord> records,
  ) {
    final List<int> bytes = utf8.encode(
      jsonEncode(<Object?>[
        for (final BookRecord r in records) r.toJson(),
      ]),
    );
    return _client.upload(config, password, remotePath, bytes);
  }

  EntrySyncOutcome _outcome({
    required bool localChanged,
    required bool remoteChanged,
    int addedFromRemote = 0,
    int addedFromLocal = 0,
  }) =>
      EntrySyncOutcome(
        collection: remotePath.replaceAll('.json', ''),
        localChanged: localChanged,
        remoteChanged: remoteChanged,
        addedFromRemote: addedFromRemote,
        addedFromLocal: addedFromLocal,
      );

  EntrySyncOutcome _failed(String reason) => EntrySyncOutcome(
        collection: remotePath.replaceAll('.json', ''),
        localChanged: false,
        remoteChanged: false,
        reason: reason,
      );
}

/// 索引同 `bookId` 冲突裁决（见 [IndexSync] 类注释的三级规则）；**对称**：
/// `f(l, r)` 与 `f(r, l)` 返回同一对象（①② 比较与顺序无关，③ 字典序取大同理）。
BookRecord resolveIndexConflict(BookRecord local, BookRecord remote) {
  final int localRead = local.lastReadAt ?? -1;
  final int remoteRead = remote.lastReadAt ?? -1;
  if (localRead != remoteRead) {
    return remoteRead > localRead ? remote : local;
  }
  final bool localUser = _hasUserEdit(local);
  final bool remoteUser = _hasUserEdit(remote);
  if (localUser != remoteUser) {
    return localUser ? local : remote;
  }
  final String localJson = jsonEncode(local.toJson());
  final String remoteJson = jsonEncode(remote.toJson());
  if (localJson == remoteJson) {
    return local;
  }
  return localJson.compareTo(remoteJson) > 0 ? local : remote;
}

/// 是否存在用户手动编辑标记（`META-09`：`user` = 用户编辑过，不被重新解析覆盖）。
bool _hasUserEdit(BookRecord record) =>
    record.titleOrigin == MetaOrigin.user ||
    record.authorOrigin == MetaOrigin.user ||
    record.introOrigin == MetaOrigin.user ||
    record.coverOrigin == MetaOrigin.user;
