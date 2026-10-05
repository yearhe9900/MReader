// `M2b-T08`：阅读会话持久化（`STAT-02`）——**按月分片 JSON + 原子写入**，
// 不引入任何第三方持久化库（`STAT-02` ⑤ / §15.4 / `Q11`）。
//
// 落点：`<dataDir>/stats/sessions-YYYY-MM.json`（分片键 = 记录 `startedAt`
// 的**本地**年月；跨 0 点拆出的续条随其 `startedAt` 落入对应月份）。
// ⚠️ 命名口径：PRD `STAT-02` 写作 `stats/session-{yyyy-MM}.json`，本实现按任务书
// 用 `sessions-`（复数）；如需对齐 PRD 只改 [SessionStore.filePrefix] 一处常量。
//
// 落盘一律经 [JsonStore] → [AtomicFile]（`DATA-01` 原子写入 + 备份回退）：
// 写入中强杀进程，当月分片仍是一份完整可解析文件（`STAT-02` ③）；单本分片损坏
// （`JsonStore` 隔离为 `.corrupt`）不影响其它月份。
//
// 合并规则（`STAT-08`）：按记录 `id` **并集**——新 id 追加、同 id 取**较大
// `duration`**；**幂等**（同一批反复合并结果不变，且无变化不重写文件）。
// **禁止写入 `duration <= 0` 的记录**（`STAT-02` ②），合并入口统一过滤。
//
// 聚合：[loadIndex] 一次性加载全部分片并建立 `day_key` / `book_id` 两组内存
// 索引（[StatsIndex]，单遍扫描）——4 万条量级下毫秒级，实测见 `tool/stats_bench.dart`。
//
// `M4-T06`：[shardKeyOf] / [isShardName] / [byStart] 为公开静态——统计同步
// （`stats/stats_sync.dart`）复用同一套分片命名与排序口径（单一事实源）。
import 'dart:io';

import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'reading_session.dart';

/// 阅读会话持久化服务（进程内共享；存储访问的**统一入口**，替换实现不改上层）。
class SessionStore {
  SessionStore(this._paths);

  final AppPaths _paths;

  /// 统计子目录名（落在 `<dataDir>/stats/`）。
  static const String dirName = 'stats';

  /// 分片文件名前缀（`sessions-` + `YYYY-MM`）。
  static const String filePrefix = 'sessions-';

  /// 文件名后缀。
  static const String fileSuffix = '.json';

  /// 分片文件名白名单：`sessions-YYYY-MM.json`（顺带排除 `.bak` / `.corrupt`
  /// / `.tmp` 兄弟文件与无关文件）。
  static final RegExp _shardName = RegExp(r'^sessions-\d{4}-\d{2}\.json$');

  /// [name] 是否为合法分片文件名（`M4-T06` 远端 `stats/` 列举过滤复用——
  /// 本地与远端同一条白名单）。
  static bool isShardName(String name) => _shardName.hasMatch(name);

  /// 合并写入（按 id 并集、幂等，`STAT-08`）。
  ///
  /// `duration <= 0` 的记录**直接丢弃**（`STAT-02` ② 禁止落盘）；
  /// 只重写**涉及月份**的分片；无实际变化的分片不重写（反复合并不产生写放大）。
  Future<void> merge(Iterable<ReadingSession> sessions) async {
    final Map<String, List<ReadingSession>> byShard = <String, List<ReadingSession>>{};
    for (final ReadingSession s in sessions) {
      if (s.duration <= 0) {
        continue;
      }
      byShard
          .putIfAbsent(shardKeyOf(s.startedAt), () => <ReadingSession>[])
          .add(s);
    }
    for (final MapEntry<String, List<ReadingSession>> entry in byShard.entries) {
      await _mergeShard(entry.key, entry.value);
    }
  }

  /// 加载全部分片记录（按 `startedAt` 升序、同刻按 `id` 稳定排序）。
  Future<List<ReadingSession>> loadAll() async {
    final Directory dir = await _paths.subDir(dirName);
    final List<ReadingSession> out = <ReadingSession>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (!_shardName.hasMatch(name)) {
        continue;
      }
      final JsonStore store = JsonStore(AtomicFile(entity.path));
      out.addAll(_decodeShard(await store.read()).values);
    }
    out.sort(byStart);
    return out;
  }

  /// 加载全部分片并建立 `day_key` / `book_id` 双索引（`STAT-02` 聚合入口）。
  Future<StatsIndex> loadIndex() async => StatsIndex.of(await loadAll());

  /// 清空全部会话分片（`STAT-03` ④「清空统计数据」的存储侧）。
  ///
  /// 删除所有 `sessions-` 前缀文件（主文件 + `.bak` / `.corrupt` / `.tmp` 兄弟）；
  /// **不动**同目录其它文件（如起始日期配置 `stats-config.json`），也**不涉及**
  /// 书架 / 进度 / 书签 / 笔记（那些各有其存储与清理链）。单文件删除失败静默
  /// （清理语义，best-effort）。
  Future<void> clearAll() async {
    final Directory dir = await _paths.subDir(dirName);
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith(filePrefix)) {
        continue;
      }
      try {
        await entity.delete();
      } catch (_) {
        // 删不掉的分片留给下次 clearAll 重试；不阻断本次清空流程。
      }
    }
  }

  /// 单分片合并：`_decodeShard` 先把坏条目 / 禁写条目滤掉、同 id 归并，
  /// 再按并集规则合入 [incoming]；**无变化则不落盘**（幂等）。
  Future<void> _mergeShard(
    String shardKey,
    List<ReadingSession> incoming,
  ) async {
    final JsonStore store = await _storeFor(shardKey);
    final Map<String, ReadingSession> merged = _decodeShard(await store.read());
    bool changed = false;
    for (final ReadingSession s in incoming) {
      final ReadingSession? old = merged[s.id];
      if (old == null || s.duration > old.duration) {
        merged[s.id] = s;
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    final List<ReadingSession> list = merged.values.toList()..sort(byStart);
    await store.write(<String, Object?>{
      'sessions': list.map((ReadingSession s) => s.toJson()).toList(),
    });
  }

  /// 解析分片 JSON 为 `id -> 记录`：非 `Map` / 无 `sessions` 列表 → 空；
  /// 坏条目 / `duration <= 0` 条目跳过；同 id 取较大 `duration`（与合并同规则）。
  Map<String, ReadingSession> _decodeShard(Object? json) {
    final Map<String, ReadingSession> out = <String, ReadingSession>{};
    if (json is! Map) {
      return out;
    }
    final Object? list = json['sessions'];
    if (list is! List) {
      return out;
    }
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
    return out;
  }

  /// 分片键：`startedAt` 的本地 `YYYY-MM`（`M4-T06` 统计同步按同一键
  /// 分组本地记录、拼远端路径）。
  static String shardKeyOf(int startedAtMs) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}';
  }

  Future<JsonStore> _storeFor(String shardKey) async {
    final Directory dir = await _paths.subDir(dirName);
    return JsonStore(AtomicFile(
      '${dir.path}${Platform.pathSeparator}'
      '$filePrefix$shardKey$fileSuffix',
    ));
  }

  /// 会话排序（`startedAt` 升序、同刻按 `id`；`M4-T06` 上传分片对齐本地
  /// 落盘序——同内容恒同字节）。
  static int byStart(ReadingSession a, ReadingSession b) {
    final int byTime = a.startedAt.compareTo(b.startedAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }
}
