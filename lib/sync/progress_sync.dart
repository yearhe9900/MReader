// `M4-T02`：阅读进度同步引擎（`SYNC-02`，PRD §10.2「取更新」/ §10.3 目录约定 / F7）。
//
// 每本书一个远端进度文件，**增量**双向收敛：
//   · 远端缺失            → 上传本地（两侧都无 → unchanged）；
//   · 远端 mtime <= 同步时间 → 不下载：本地在上次同步后有新阅读 → 上传
//     （`SYNC-06` 退出阅读页上报的时机）；否则直接跳过（验收③）；
//   · 远端更靠后          → 覆盖本地（验收①「后读覆盖先读」）；
//   · 本地更靠后          → 不回退本地，并把本地推上远端（验收②）；
//   · 完全相同            → 不写入进度，仅更新同步时间（§10.2 ④）。
//
// 冲突判定是纯函数（`conflict.dart`），本文件只做：读写 `ProgressStore`、
// 经 `WebdavClient` 传输、维护「本地同步时间」总账 [ProgressSyncState]、
// 汇总失败清单（`SYNC-07`：单本失败不中断整体，原因可读可重试）。
//
// 跨设备序列化纪律（`RD-04`）：上传**丢弃 localHint**（设备本地版面快照）；
// 下载落盘同样重建为无 hint 的进度（远端带来的 hint 是别的设备的版面）。
import 'dart:convert';
import 'dart:io';

import '../library/book_record.dart';
import '../reader/progress_store.dart';
import '../reader/reading_progress.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'conflict.dart';
import 'sync_config.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

/// 远端进度子目录名（PRD §10.3：`{url}/{dir}/bookProgress/`）。
const String progressRemoteDir = 'bookProgress';

/// 单本书的远端进度路径（相对远端根）：`bookProgress/{书名}_{作者}.json`。
///
/// 书名 / 作者做文件名净化：路径分隔符与 Windows 非法字符替换为 `_`
/// （`/` 若不处理会被 `WebdavClient` 拆成多级目录），空白折叠、去首尾；
/// 净化后为空回退 `未知`。段编码（中文 / 空格 → percent-encoding）由
/// `WebdavClient` 统一处理，这里只给**已解码**的路径。
String progressRemotePath(BookRecord book) =>
    '$progressRemoteDir/${_safeSegment(book.title)}_${_safeSegment(book.author)}.json';

/// 文件名段净化（见 [progressRemotePath]）。
String _safeSegment(String raw) {
  final String cleaned = raw
      .trim()
      .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? '未知' : cleaned;
}

/// 本地「同步时间」总账——`SYNC-02` 步骤① 闸门的本地事实源。
///
/// 落盘 `<dataDir>/sync_state.json`（形制同 `SyncConfigStore`：
/// [JsonStore] → [AtomicFile]，`DATA-01` 原子写入），结构：
/// ```json
/// { "progress": { "<bookId>": <Unix 毫秒> } }
/// ```
/// 顶层留扩展位（`M4-T05` 的「上次全量备份时间」等并列新键即可，勿改形制）。
///
/// 语义：该 bookId 上次**与远端完成一次同步交互**（上传 / 下载 / 判同）
/// 的时刻；从未同步为 0。跳过（远端更旧）**不更新**——否则闸门会把
/// 「远端之后的新版本」也一并跳过。
class ProgressSyncState {
  /// 用数据目录构造（组合根注入，见 `lib/main.dart`）。
  ProgressSyncState(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}sync_state.json',
          ),
        );

  final JsonStore _store;

  /// bookId → 上次同步时间（Unix 毫秒）。
  final Map<String, int> _syncedAt = <String, int>{};

  bool _loaded = false;

  /// 从磁盘加载（**幂等**：已加载则直接返回）。缺失 / 损坏 → 视作从未同步。
  Future<void> load() async {
    if (_loaded) {
      return;
    }
    final Object? json = await _store.read();
    if (json is Map && json['progress'] is Map) {
      for (final MapEntry<Object?, Object?> entry
          in (json['progress'] as Map).entries) {
        if (entry.key is String && entry.value is num) {
          _syncedAt[entry.key! as String] = (entry.value! as num).toInt();
        }
      }
    }
    _loaded = true;
  }

  /// 某本书的上次同步时间；从未同步返 `0`。
  int syncedAt(String bookId) => _syncedAt[bookId] ?? 0;

  /// 记录 [bookId] 刚完成一次同步（[atMs] = Unix 毫秒）并落盘。
  Future<void> markSynced(String bookId, int atMs) async {
    _syncedAt[bookId] = atMs;
    await _store.write(<String, Object?>{
      'progress': <String, Object?>{..._syncedAt},
    });
  }
}

/// 单本书的同步动作（`SYNC-02` 双向收敛的结果分类）。
enum ProgressSyncAction {
  /// 远端更靠后（或本地首次有进度而远端缺失）→ 已覆盖 / 首传。
  downloaded,

  /// 本地更靠后（或远端缺失）→ 已上传远端。
  uploaded,

  /// 远端时间戳不晚于本地同步时间且本地无新阅读 → 直接跳过（验收③）。
  skipped,

  /// 两侧语义完全相同 → 未写进度，仅更新同步时间（§10.2 ④）。
  identical,

  /// 两侧都无进度 → 无事可做。
  unchanged,

  /// 本本失败；[ProgressSyncOutcome.reason] 给出可读原因（`SYNC-07`）。
  failed,
}

/// 单本书的同步结果。
class ProgressSyncOutcome {
  /// 创建结果。
  const ProgressSyncOutcome({
    required this.bookId,
    required this.title,
    required this.action,
    this.reason,
  });

  /// 归属书籍 bookId。
  final String bookId;

  /// 书名（失败清单展示用）。
  final String title;

  /// 动作分类。
  final ProgressSyncAction action;

  /// 失败时的中文可读原因（成功时为 `null`）。
  final String? reason;

  @override
  String toString() =>
      'ProgressSyncOutcome($bookId, $action${reason == null ? '' : ': $reason'})';
}

/// 一轮同步的汇总（`SYNC-07`：失败项汇总提示，可重试）。
class ProgressSyncReport {
  /// 创建汇总。
  const ProgressSyncReport(this.outcomes);

  /// 逐本结果。
  final List<ProgressSyncOutcome> outcomes;

  /// 是否无失败本。
  bool get ok => outcomes.every(
        (ProgressSyncOutcome o) => o.action != ProgressSyncAction.failed,
      );

  /// 某动作的本数。
  int count(ProgressSyncAction action) => outcomes
      .where((ProgressSyncOutcome o) => o.action == action)
      .length;

  /// 失败本清单（含可读原因）。
  List<ProgressSyncOutcome> get failures => outcomes
      .where((ProgressSyncOutcome o) => o.action == ProgressSyncAction.failed)
      .toList(growable: false);

  /// 中文汇总行（UI / 日志直接回显）。
  String get summary => '下载 ${count(ProgressSyncAction.downloaded)} 本 · '
      '上传 ${count(ProgressSyncAction.uploaded)} 本 · '
      '跳过 ${count(ProgressSyncAction.skipped)} 本 · '
      '相同 ${count(ProgressSyncAction.identical)} 本 · '
      '失败 ${count(ProgressSyncAction.failed)} 本';
}

/// 阅读进度同步引擎（进程内共享，显式注入；触发时机由 `M4-T05` 编排）。
class ProgressSyncEngine {
  /// 创建引擎（四个依赖均由组合根注入，见 `lib/main.dart`）。
  ProgressSyncEngine({
    required WebdavClient client,
    required ProgressStore progressStore,
    required SyncConfigStore configStore,
    required ProgressSyncState state,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _client = client, // ignore: prefer_initializing_formals
        _progress = progressStore,
        _configStore = configStore, // ignore: prefer_initializing_formals
        _state = state; // ignore: prefer_initializing_formals

  final WebdavClient _client;
  final ProgressStore _progress;
  final SyncConfigStore _configStore;
  final ProgressSyncState _state;

  /// 已确认建好的远端目录键（`url|dir`）——同配置只 MKCOL 一次。
  String? _ensuredKey;

  /// 同步一批书（`M4-T05`「启动时拉取」的入口）。
  ///
  /// 配置 / 密码缺失 → 全部记为 failed；**单本失败不中断整体**
  /// （`SYNC-07`：失败项汇总进 [ProgressSyncReport]，可重试）。
  Future<ProgressSyncReport> syncAll({
    required List<BookRecord> books,
  }) async {
    final SyncConfig? config = _configStore.config;
    if (config == null) {
      return ProgressSyncReport(
        <ProgressSyncOutcome>[
          for (final BookRecord book in books)
            _failed(book, '尚未配置 WebDAV 同步'),
        ],
      );
    }
    final String? password = await _configStore.readPassword();
    if (password == null || password.isEmpty) {
      return ProgressSyncReport(
        <ProgressSyncOutcome>[
          for (final BookRecord book in books)
            _failed(book, '尚未保存 WebDAV 密码'),
        ],
      );
    }
    final List<ProgressSyncOutcome> outcomes = <ProgressSyncOutcome>[];
    for (final BookRecord book in books) {
      outcomes.add(await _sync(config, password, book));
    }
    return ProgressSyncReport(outcomes);
  }

  /// 同步单本书（`M4-T05`「退出阅读页上报」的入口）。
  ///
  /// 不抛业务异常：通道 / 配置 / 数据问题一律返回
  /// [ProgressSyncAction.failed] + 可读 reason（`SYNC-07`）。
  Future<ProgressSyncOutcome> syncBook(BookRecord book) async {
    final SyncConfig? config = _configStore.config;
    if (config == null) {
      return _failed(book, '尚未配置 WebDAV 同步');
    }
    final String? password = await _configStore.readPassword();
    if (password == null || password.isEmpty) {
      return _failed(book, '尚未保存 WebDAV 密码');
    }
    return _sync(config, password, book);
  }

  /// 执行同步并把 [SyncException] 收编为 failed 结果（`SYNC-07` 不静默）。
  Future<ProgressSyncOutcome> _sync(
    SyncConfig config,
    String password,
    BookRecord book,
  ) async {
    try {
      return await _syncOne(config, password, book);
    } on SyncException catch (e) {
      return _failed(book, e.message);
    }
  }

  /// 单本同步主流程（PRD F7「取更新」四步）。
  Future<ProgressSyncOutcome> _syncOne(
    SyncConfig config,
    String password,
    BookRecord book,
  ) async {
    await _state.load();
    final String remotePath = progressRemotePath(book);
    final ReadingProgress? local = await _progress.load(book.bookId);
    final int syncedAt = _state.syncedAt(book.bookId);

    final WebdavEntry? entry = await _client.stat(config, password, remotePath);
    if (entry == null) {
      // 远端缺失：本地有进度 → 首传；两侧都无 → 无事可做。
      if (local == null) {
        return _of(book, ProgressSyncAction.unchanged);
      }
      await _ensureDir(config, password);
      await _upload(config, password, remotePath, local);
      await _state.markSynced(book.bookId, _now());
      return _of(book, ProgressSyncAction.uploaded);
    }

    // ① 时间闸门（远端 mtime <= 本地同步时间 → 不下载，直接定夺）。
    if (isRemoteStale(
      remoteModified: entry.lastModified,
      localSyncedAt: syncedAt,
    )) {
      // 本地在上次同步后有新阅读（退出阅读页上报的时机）→ 推上去；
      // 否则远端无新信息、本地无新进度 → 直接跳过（验收③，不发 GET）。
      if (local != null && local.updatedAt > syncedAt) {
        await _upload(config, password, remotePath, local);
        await _state.markSynced(book.bookId, _now());
        return _of(book, ProgressSyncAction.uploaded);
      }
      return _of(book, ProgressSyncAction.skipped);
    }

    // 远端比上次同步新 → 下载后按索引 / 章内位置判定（②③④）。
    final ReadingProgress? remote = _decode(
      await _client.download(config, password, remotePath),
    );
    if (remote == null) {
      return _failed(book, '远端进度文件损坏，已跳过');
    }
    if (remote.bookId != book.bookId) {
      return _failed(book, '远端进度文件属于另一本书，已跳过');
    }

    if (local == null) {
      await _progress.save(_withoutHint(remote));
      await _state.markSynced(book.bookId, _now());
      return _of(book, ProgressSyncAction.downloaded);
    }

    final ConflictDecision decision = resolveProgressConflict(
      local: local,
      remote: remote,
      remoteModified: entry.lastModified,
      localSyncedAt: syncedAt,
    );
    switch (decision) {
      case ConflictDecision.takeRemote:
        // 验收①：远端更靠后 → 覆盖本地（hint 丢弃，恢复走估算校正）。
        await _progress.save(_withoutHint(remote));
        await _state.markSynced(book.bookId, _now());
        return _of(book, ProgressSyncAction.downloaded);
      case ConflictDecision.keepLocal:
        // 验收②：本地更靠后 → 不回退，并把本地推上远端让对端也能前进。
        await _upload(config, password, remotePath, local);
        await _state.markSynced(book.bookId, _now());
        return _of(book, ProgressSyncAction.uploaded);
      case ConflictDecision.identical:
        // §10.2 ④：不写入，仅更新时间戳。
        await _state.markSynced(book.bookId, _now());
        return _of(book, ProgressSyncAction.identical);
      case ConflictDecision.skipRemote:
        // 防御分支：闸门在下载前已判过且时间未变，正常流程不可达。
        return _of(book, ProgressSyncAction.skipped);
    }
  }

  /// 确保远端 `bookProgress/` 存在（仅在远端连文件都没有时调用；
  /// 文件已存在则其所在目录必然存在，省一轮 MKCOL）。
  Future<void> _ensureDir(SyncConfig config, String password) async {
    final String key = '${config.url}|${config.dir}';
    if (_ensuredKey == key) {
      return;
    }
    await _client.ensureDirectory(config, password, under: progressRemoteDir);
    _ensuredKey = key;
  }

  /// 上传单本进度（**上传前丢弃 localHint**——设备本地版面快照不跨设备）。
  Future<void> _upload(
    SyncConfig config,
    String password,
    String remotePath,
    ReadingProgress local,
  ) {
    final List<int> bytes = utf8.encode(
      jsonEncode(_withoutHint(local).toJson()),
    );
    return _client.upload(config, password, remotePath, bytes);
  }

  /// 下载字节 → 进度；坏 JSON / 结构不符 → `null`（不猜、不报错）。
  ReadingProgress? _decode(List<int> bytes) {
    try {
      return ReadingProgress.fromJson(
        jsonDecode(utf8.decode(bytes, allowMalformed: true)),
      );
    } catch (_) {
      return null;
    }
  }

  /// 重建为**无 localHint** 的进度（跨设备落盘纪律，`RD-04`）。
  ReadingProgress _withoutHint(ReadingProgress source) => ReadingProgress(
        bookId: source.bookId,
        chapterHref: source.chapterHref,
        chapterIndex: source.chapterIndex,
        chapterPos: source.chapterPos,
        updatedAt: source.updatedAt,
      );

  ProgressSyncOutcome _of(BookRecord book, ProgressSyncAction action) =>
      ProgressSyncOutcome(
        bookId: book.bookId,
        title: book.title,
        action: action,
      );

  ProgressSyncOutcome _failed(BookRecord book, String reason) =>
      ProgressSyncOutcome(
        bookId: book.bookId,
        title: book.title,
        action: ProgressSyncAction.failed,
        reason: reason,
      );

  /// 当前时刻（Unix 毫秒）。
  int _now() => DateTime.now().millisecondsSinceEpoch;
}
