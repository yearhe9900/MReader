// `M2b-T08`：统计聚合性能实测（PRD `STAT-02` ④：**4 万条记录加载并按 `book_id`
// 聚合 ≤ 300ms**）。纯 Dart 命令行，与 `tool/perf_bench.dart` 同风格。
//
// 测量两件事：
//   ① `loadIndex()` —— 读**全部月分片** + JSON 解析 + 建 `day_key` / `book_id`
//      双索引（即 `STAT-02` ④「加载并聚合」的完整链路，含真磁盘 IO）；
//   ② `StatsIndex.of()` —— 记录已在内存时的**纯聚合**单遍扫描耗时。
//
// 数据：确定性合成 N 条会话（默认 40 000，约 5 年跨度、12 本书 → ≈ 60 个月分片），
// 先经 `SessionStore.merge` 真实落盘，再多轮测量取 min / median / max。
//
// 用法：
//   dart run tool/stats_bench.dart [条数] [轮数]
//     例：dart run tool/stats_bench.dart 40000 5
import 'dart:io';

import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/stats/session_store.dart';

/// 临时目录实现 [AppPaths]（与测试同款；基准独立进程，直接落系统临时目录）。
class _BenchAppPaths implements AppPaths {
  _BenchAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir = Directory(
      '${_root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}

/// 合成第 [i] 条会话（确定性：时刻 / 时长均闭式，无随机数）。
///
/// 跨度：2021-01-01 12:00 起 5 年均匀铺开（PRD 口径「约 5 年」）；
/// 时长 240~839 秒循环；12 本书轮转。
ReadingSession _synthetic(int i, int count, int spanMs) {
  final int startedAt =
      DateTime(2021, 1, 1, 12).millisecondsSinceEpoch + i * (spanMs ~/ count);
  final int duration = 240 + i % 600;
  final String bookId = 'book${(i % 12).toString().padLeft(2, '0')}';
  return ReadingSession(
    id: ReadingSession.makeId(bookId, startedAt),
    bookId: bookId,
    dayKey: sessionDayKey(startedAt),
    startedAt: startedAt,
    endedAt: startedAt + duration * 1000,
    duration: duration,
    start: SessionPosition(chapterHref: 'txt:1', chapterPos: 0.1),
    end: SessionPosition(chapterHref: 'txt:9', chapterPos: 0.9),
  );
}

/// 取一轮计时的 min / median / max（毫秒）。
String _stat(List<int> times) {
  final List<int> sorted = List<int>.of(times)..sort();
  final int median = sorted[sorted.length ~/ 2];
  return 'min=${sorted.first} median=$median max=${sorted.last}'
      ' (ms, n=${sorted.length})';
}

Future<void> main(List<String> args) async {
  final int count = args.isNotEmpty ? (int.tryParse(args[0]) ?? 40000) : 40000;
  final int rounds = args.length > 1 ? (int.tryParse(args[1]) ?? 5) : 5;

  final Directory tempDir =
      Directory.systemTemp.createTempSync('mreader_stats_bench_');
  final SessionStore store = SessionStore(_BenchAppPaths(tempDir));

  // 5 年跨度。
  final int spanMs = DateTime(2026, 1, 1).millisecondsSinceEpoch -
      DateTime(2021, 1, 1).millisecondsSinceEpoch;
  final List<ReadingSession> sessions = List<ReadingSession>.generate(
    count,
    (int i) => _synthetic(i, count, spanMs),
  );
  int expectedTotal = 0;
  for (final ReadingSession s in sessions) {
    expectedTotal += s.duration;
  }

  // ① 落盘：merge（按月分片 + 原子写入）。
  final Stopwatch writeWatch = Stopwatch()..start();
  await store.merge(sessions);
  writeWatch.stop();
  final int shardCount = (await Directory(
          '${tempDir.path}${Platform.pathSeparator}stats')
      .list()
      .where((FileSystemEntity e) =>
          e is File &&
          e.path.split(Platform.pathSeparator).last.startsWith('sessions-') &&
          e.path.endsWith('.json'))
      .length);

  // ② 加载并聚合（STAT-02 ④ 口径：读全部分片 + 双索引）。
  final List<int> loadIndexMs = <int>[];
  StatsIndex? index;
  for (int r = 0; r < rounds; r++) {
    final Stopwatch w = Stopwatch()..start();
    index = await store.loadIndex();
    w.stop();
    loadIndexMs.add(w.elapsedMicroseconds ~/ 1000);
  }

  // ③ 纯聚合（输入已在内存，单遍扫描）。
  final List<ReadingSession> loaded = await store.loadAll();
  final List<int> aggregateMs = <int>[];
  for (int r = 0; r < rounds; r++) {
    final Stopwatch w = Stopwatch()..start();
    final StatsIndex probe = StatsIndex.of(loaded);
    w.stop();
    aggregateMs.add(w.elapsedMicroseconds ~/ 1000);
    if (probe.totalSeconds != expectedTotal) {
      stdout.writeln('BENCH[stats] MISMATCH total=${probe.totalSeconds} '
          'expected=$expectedTotal');
    }
  }

  stdout.writeln('BENCH[stats] records=$count shards=$shardCount '
      'writeMs=${writeWatch.elapsedMilliseconds}');
  stdout.writeln('BENCH[stats] loadIndex  ${_stat(loadIndexMs)}');
  stdout.writeln('BENCH[stats] aggregate  ${_stat(aggregateMs)}');
  stdout.writeln('BENCH[stats] total=${index?.totalSeconds}s '
      'expected=${expectedTotal}s days=${index?.secondsByDay.length} '
      'books=${index?.secondsByBook.length}');
  stdout.writeln(
      'BENCH[stats] budget=300ms verdict=${loadIndexMs.reduce((int a, int b) => a < b ? a : b) <= 300 ? 'PASS' : 'FAIL'}');

  tempDir.deleteSync(recursive: true);
}
