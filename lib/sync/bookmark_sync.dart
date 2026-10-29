// 书签同步（`SYNC-03`，PRD §10.1「书签 / 笔记：按条目合并」）。
//
// 每本书一个远端文件 `bookmarks/{bookId}.json`（与本地同构，格式同
// `BookmarkStore`，下载复用 `parseBookmarks` 防御式解析，不另造第二套格式）。
//
// 合并 = 并集（`entry_sync.mergeById`）：key = [Bookmark.createdAt]（`TYP-06`：
// 兼作条目身份）；两侧各加一条 → 同步后都在（验收②），一侧加 → 对端可见
// （验收①）；同 key 冲突取内容字典序大者（[byContent]，双侧对称收敛）。
//
// 口径：**删除不跨设备传播**（并集无墓碑，PRD 未定义删除同步——一端删除后
// 再同步会被对端并回）；「笔记」当前无存储（占位页），待落地后并入同机制。
import 'dart:convert';

import '../reader/bookmark.dart';
import '../reader/bookmark_store.dart';
import 'entry_sync.dart';
import 'sync_config.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

/// 书签同步引擎（进程内共享，显式注入；触发时机由同步触发编排调用）。
class BookmarkSync {
  /// 创建引擎（组合根注入，见 `lib/main.dart`）。
  BookmarkSync({
    required WebdavClient client,
    required BookmarkStore store,
    required SyncConfigStore configStore,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _client = client, // ignore: prefer_initializing_formals
        _store = store, // ignore: prefer_initializing_formals
        _configStore = configStore; // ignore: prefer_initializing_formals

  /// 远端书签子目录（PRD §10.3 未点名，贴本地 `bookmarks/` 命名）。
  static const String remoteDir = 'bookmarks';

  final WebdavClient _client;
  final BookmarkStore _store;
  final SyncConfigStore _configStore;
  final RemoteDirCache _dirs = RemoteDirCache();

  /// 单本书的远端书签路径：`bookmarks/{bookId}.json`
  /// （bookId 过 `BookmarkStore` 白名单，天然路径安全）。
  static String remotePathFor(String bookId) => '$remoteDir/$bookId.json';

  /// 同步一批书的书签（「退出 App 上报全部变更」入口）：[bookIds] 取在库书籍
  /// （无书则无可读对象，跳过对端书签）；配置缺失 → 全部 failed，单本失败
  /// 不中断整体（`SYNC-07`）。
  Future<EntrySyncReport> syncAll({required List<String> bookIds}) async {
    final ({SyncConfig config, String password})? ctx =
        await _tryContext();
    if (ctx == null) {
      final String reason = _configStore.config == null
          ? '尚未配置 WebDAV 同步'
          : '尚未保存 WebDAV 密码';
      return EntrySyncReport(<EntrySyncOutcome>[
        for (final String bookId in bookIds)
          _failed(_collection(bookId), reason),
      ]);
    }
    final List<EntrySyncOutcome> outcomes = <EntrySyncOutcome>[];
    for (final String bookId in bookIds) {
      outcomes.add(await _syncOne(ctx, bookId));
    }
    return EntrySyncReport(outcomes);
  }

  /// 同步单本书的书签（退出阅读页等单书时机）；不抛业务异常：通道 / 配置 /
  /// 数据问题一律返回 failed + 可读 reason。
  Future<EntrySyncOutcome> syncBook(String bookId) async {
    final ({SyncConfig config, String password})? ctx = await _tryContext();
    if (ctx == null) {
      return _failed(
        _collection(bookId),
        _configStore.config == null ? '尚未配置 WebDAV 同步' : '尚未保存 WebDAV 密码',
      );
    }
    return _syncOne(ctx, bookId);
  }

  /// 解析连接上下文；未就绪返 `null`（可读原因见调用方）。
  Future<({SyncConfig config, String password})?> _tryContext() async {
    try {
      return await requireWebdav(_configStore);
    } on SyncException {
      return null;
    }
  }

  /// 单本同步主流程（并集合并 + 双向按需写入）。
  Future<EntrySyncOutcome> _syncOne(
    ({SyncConfig config, String password}) ctx,
    String bookId,
  ) async {
    final String collection = _collection(bookId);
    final String path = remotePathFor(bookId);
    try {
      final List<Bookmark> local = await _store.load(bookId);
      final WebdavEntry? entry = await _client.stat(ctx.config, ctx.password, path);
      if (entry == null) {
        // 远端无该书书签：本地有 → 首传；双无 → 无事可做。
        if (local.isEmpty) {
          return EntrySyncOutcome(
            collection: collection,
            localChanged: false,
            remoteChanged: false,
          );
        }
        await _dirs.ensure(_client, ctx.config, ctx.password, remoteDir);
        await _upload(ctx.config, ctx.password, path, bookId, local);
        return EntrySyncOutcome(
          collection: collection,
          localChanged: false,
          remoteChanged: true,
          addedFromLocal: local.length,
        );
      }

      final List<Bookmark>? remote = _decode(
        await _client.download(ctx.config, ctx.password, path),
        bookId,
      );
      if (remote == null) {
        return _failed(collection, '远端书签文件损坏，已跳过');
      }

      final MergeResult<Bookmark> result = mergeById<Bookmark>(
        local: local,
        remote: remote,
        idOf: (Bookmark b) => '${b.createdAt}',
        encode: (Bookmark b) => jsonEncode(b.toJson()),
        resolve: byContent<Bookmark>((Bookmark b) => jsonEncode(b.toJson())),
      );
      final List<Bookmark> merged = result.merged
        ..sort((Bookmark a, Bookmark b) => a.createdAt.compareTo(b.createdAt));
      if (result.localChanged) {
        await _store.save(bookId, merged);
      }
      if (result.remoteChanged) {
        await _upload(ctx.config, ctx.password, path, bookId, merged);
      }
      return EntrySyncOutcome(
        collection: collection,
        localChanged: result.localChanged,
        remoteChanged: result.remoteChanged,
        addedFromRemote: result.addedFromRemote,
        addedFromLocal: result.addedFromLocal,
      );
    } on SyncException catch (e) {
      return _failed(collection, e.message);
    }
  }

  /// 远端字节 → 书签列表；坏 JSON / 非 Map / `bookId` 串档 → `null`（损坏）；
  /// 结构合法但列表为空是**合法空集**（返空表，交并集处理）。
  List<Bookmark>? _decode(List<int> bytes, String bookId) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
    if (json is! Map || json['bookId'] != bookId) {
      return null;
    }
    return parseBookmarks(json, bookId);
  }

  Future<void> _upload(
    SyncConfig config,
    String password,
    String path,
    String bookId,
    List<Bookmark> bookmarks,
  ) {
    final List<int> bytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'bookId': bookId,
        'bookmarks': <Object?>[
          for (final Bookmark b in bookmarks) b.toJson(),
        ],
      }),
    );
    return _client.upload(config, password, path, bytes);
  }

  String _collection(String bookId) => remotePathFor(bookId).replaceAll('.json', '');

  EntrySyncOutcome _failed(String collection, String reason) =>
      EntrySyncOutcome(
        collection: collection,
        localChanged: false,
        remoteChanged: false,
        reason: reason,
      );
}
