// `M2b-T08`：会话持久化单测（`STAT-02` / `STAT-08`；纯 Dart `test()`，
// 临时目录真异步 IO，**不用** `testWidgets`——FakeAsync 区会挂死真 IO）。
//
// 覆盖：按月分片落盘、按 id 并集合并、重复合并幂等、同 id 取较大时长、
// 禁止 `duration <= 0` 落盘、聚合正确性（经存储往返后仍逐秒一致）。
// 断言预期值均先**人工推演**（各用例注释给出推演式）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/stats/session_store.dart';

/// 临时目录实现 [AppPaths]，仅用于测试（与 `test/reader/progress_store_test.dart` 同款）。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);
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

/// 本地时刻 → Unix 毫秒。
int _ts(int y, int mo, int d, [int h = 0, int mi = 0]) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch;

/// 构造一条记录：id 由 (bookId, startedAt) 确定性派生（同采集器口径），
/// `endedAt = startedAt + duration`，坐标固定。
ReadingSession _session({
  required String bookId,
  required String dayKey,
  required int startedAt,
  required int duration,
}) {
  return ReadingSession(
    id: ReadingSession.makeId(bookId, startedAt),
    bookId: bookId,
    dayKey: dayKey,
    startedAt: startedAt,
    endedAt: startedAt + duration * 1000,
    duration: duration,
    start: SessionPosition(chapterHref: 'txt:1', chapterPos: 0.1),
    end: SessionPosition(chapterHref: 'txt:1', chapterPos: 0.9),
  );
}

void main() {
  group('SessionStore', () {
    late Directory tempDir;
    late _TestAppPaths paths;
    late SessionStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_stats_');
      paths = _TestAppPaths(tempDir);
      store = SessionStore(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('merge 后按月分片落盘，loadAll / loadIndex 取回逐秒一致', () async {
      // s1 bookA 09-05 300s；s2 bookB 09-06 60s；s3 bookA 10-01 120s（跨月）。
      // 分片：s1/s2 → sessions-2026-09.json；s3 → sessions-2026-10.json。
      // 索引：day {09-05: 300, 09-06: 60, 10-01: 120}；
      //       book {bookA: 300+120 = 420, bookB: 60}；total = 480。
      final ReadingSession s1 = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 10), duration: 300);
      final ReadingSession s2 = _session(
          bookId: 'bookB', dayKey: '2026-09-06', startedAt: _ts(2026, 9, 6, 11), duration: 60);
      final ReadingSession s3 = _session(
          bookId: 'bookA', dayKey: '2026-10-01', startedAt: _ts(2026, 10, 1, 9), duration: 120);

      await store.merge(<ReadingSession>[s3, s1, s2]);

      final Directory statsDir = await paths.subDir(SessionStore.dirName);
      expect(
        File('${statsDir.path}${Platform.pathSeparator}sessions-2026-09.json')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${statsDir.path}${Platform.pathSeparator}sessions-2026-10.json')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${statsDir.path}${Platform.pathSeparator}sessions-2026-08.json')
            .existsSync(),
        isFalse,
      );

      // loadAll 按 startedAt 升序（与合入顺序无关）。
      expect(await store.loadAll(), <ReadingSession>[s1, s2, s3]);

      final StatsIndex index = await store.loadIndex();
      expect(index.secondsByDay, <String, int>{
        '2026-09-05': 300,
        '2026-09-06': 60,
        '2026-10-01': 120,
      });
      expect(index.secondsByBook, <String, int>{'bookA': 420, 'bookB': 60});
      expect(index.totalSeconds, 480);
    });

    test('按 id 并集合并、重复合并不双计（幂等，STAT-08 ③）', () async {
      // a1 bookA 300s、b1 bookB 60s、a2 bookA 120s（同日不同刻 → 不同 id）。
      // merge1 [a1, b1]        → bookA 300, bookB 60, total 360, 2 条
      // merge2 [a1, a2]（a1 重复）→ bookA 300+120 = 420, total 480, 3 条（a1 不双计）
      // merge3 [a1, a2] 再来一遍 → 结果不变（480 / 3 条）
      final ReadingSession a1 = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 10), duration: 300);
      final ReadingSession b1 = _session(
          bookId: 'bookB', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 11), duration: 60);
      final ReadingSession a2 = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 14), duration: 120);

      await store.merge(<ReadingSession>[a1, b1]);
      StatsIndex index = await store.loadIndex();
      expect(index.secondsByBook, <String, int>{'bookA': 300, 'bookB': 60});
      expect(index.totalSeconds, 360);
      expect(await store.loadAll(), hasLength(2));

      await store.merge(<ReadingSession>[a1, a2]);
      index = await store.loadIndex();
      expect(index.secondsByBook, <String, int>{'bookA': 420, 'bookB': 60});
      expect(index.totalSeconds, 480);
      expect(await store.loadAll(), hasLength(3));

      await store.merge(<ReadingSession>[a1, a2]);
      index = await store.loadIndex();
      expect(index.secondsByBook, <String, int>{'bookA': 420, 'bookB': 60});
      expect(index.totalSeconds, 480);
      expect(await store.loadAll(), hasLength(3));
    });

    test('同 id 取较大 duration、较小时不回退（STAT-08）', () async {
      // 同 (bookA, 10:00) 的 id：200 → 500 → 100，最终 500、仅 1 条。
      final ReadingSession d200 = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 10), duration: 200);
      final ReadingSession d500 = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 10), duration: 500);
      final ReadingSession d100 = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 10), duration: 100);

      await store.merge(<ReadingSession>[d200]);
      expect((await store.loadIndex()).totalSeconds, 200);

      await store.merge(<ReadingSession>[d500]);
      expect((await store.loadIndex()).totalSeconds, 500);

      await store.merge(<ReadingSession>[d100]);
      expect((await store.loadIndex()).totalSeconds, 500);
      expect(await store.loadAll(), hasLength(1));
    });

    test('禁止写入 duration ≤ 0 的记录（STAT-02 ②）', () async {
      // 0s / -5s 两条被拒之门外，只留 60s 一条；分片文件里搜不到它们。
      final ReadingSession zero = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 10), duration: 0);
      final ReadingSession neg = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 11), duration: -5);
      final ReadingSession ok = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 12), duration: 60);

      await store.merge(<ReadingSession>[zero, neg, ok]);
      expect(await store.loadAll(), <ReadingSession>[ok]);

      final Directory statsDir = await paths.subDir(SessionStore.dirName);
      final String raw = File(
        '${statsDir.path}${Platform.pathSeparator}sessions-2026-09.json',
      ).readAsStringSync();
      expect(raw.contains('"duration":0'), isFalse);
      expect(raw.contains('"duration":-5'), isFalse);

      // 只合入禁写记录 → 连分片文件都不产生：用**未写过的 8 月** zeroAug
      // （若过滤失效它会建 sessions-2026-08.json）——原断言误测了从未触碰的
      // 月份，平凡真，这里换成真正「本会被创建」的分片键。
      final ReadingSession zeroAug = _session(
          bookId: 'bookA', dayKey: '2026-08-05', startedAt: _ts(2026, 8, 5, 10), duration: 0);
      await store.merge(<ReadingSession>[zeroAug]);
      expect(
        File('${statsDir.path}${Platform.pathSeparator}sessions-2026-08.json')
            .existsSync(),
        isFalse,
      );
    });

    test('损坏分片被隔离为 .corrupt，其它月份不受影响', () async {
      // 9 月分片写坏 → 读取时隔离，10 月记录照常可读、可继续合并。
      final ReadingSession sep = _session(
          bookId: 'bookA', dayKey: '2026-09-05', startedAt: _ts(2026, 9, 5, 10), duration: 300);
      final ReadingSession oct = _session(
          bookId: 'bookB', dayKey: '2026-10-01', startedAt: _ts(2026, 10, 1, 9), duration: 60);

      await store.merge(<ReadingSession>[sep, oct]);
      final Directory statsDir = await paths.subDir(SessionStore.dirName);
      File(
        '${statsDir.path}${Platform.pathSeparator}sessions-2026-09.json',
      ).writeAsStringSync('not json at all');

      final List<ReadingSession> all = await store.loadAll();
      expect(all, <ReadingSession>[oct]);
      expect(
        File('${statsDir.path}${Platform.pathSeparator}'
                'sessions-2026-09.json.corrupt')
            .existsSync(),
        isTrue,
      );

      await store.merge(<ReadingSession>[sep]);
      expect((await store.loadIndex()).totalSeconds, 360);
    });

    test('空库 → 空列表 / 空索引', () async {
      expect(await store.loadAll(), isEmpty);
      final StatsIndex index = await store.loadIndex();
      expect(index.totalSeconds, 0);
    });
  });
}
