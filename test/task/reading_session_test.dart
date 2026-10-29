// `STAT-01` / `STAT-02`：会话采集内核单测（纯 Dart `test()`，无 widget / FakeAsync / IO）。
//
// 覆盖：空闲切会话、跨 0 点拆天、聚合正确性、JSON 往返防御。
// 断言预期值均先**人工推演**（各用例注释给出推演式），时间一律用本地
// `DateTime(y, m, d, ...)` 构造，故 `day_key` 字面量在任何时区都成立。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/stats/reading_session.dart';

/// 本地时刻 → Unix 毫秒。
int _ts(int y, int mo, int d, [int h = 0, int mi = 0, int s = 0, int ms = 0]) =>
    DateTime(y, mo, d, h, mi, s, ms).millisecondsSinceEpoch;

SessionTracker _tracker(String bookId) => SessionTracker(bookId: bookId);

void main() {
  group('SessionTracker 空闲切会话（STAT-01）', () {
    test('空闲 ≤ 3 分钟不切会话，全程计入', () {
      // 20:00 活跃、20:02 活跃、20:04 收尾：
      // 段 [20:00, min(20:04, 20:02+3min=20:05)] = [20:00, 20:04] = 240s。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.1);
      t.noteActivity(at: _ts(2026, 9, 24, 20, 2), chapterHref: 'ch2', chapterPos: 0.5);
      final List<ReadingSession> out =
          t.finish(at: _ts(2026, 9, 24, 20, 4));

      expect(out, hasLength(1));
      final ReadingSession r = out.single;
      expect(r.id, '${_ts(2026, 9, 24, 20, 0)}_bookA');
      expect(r.bookId, 'bookA');
      expect(r.dayKey, '2026-09-24');
      expect(r.startedAt, _ts(2026, 9, 24, 20, 0));
      expect(r.endedAt, _ts(2026, 9, 24, 20, 4));
      expect(r.duration, 240);
      expect(r.start.chapterHref, 'ch1');
      expect(r.start.chapterPos, closeTo(0.1, 1e-9));
      // 终点坐标 = 边界前最后一次活跃（20:02 的 ch2/0.5）。
      expect(r.end.chapterHref, 'ch2');
      expect(r.end.chapterPos, closeTo(0.5, 1e-9));
    });

    test('空闲超过 3 分钟即切会话，前段只计到最后活跃 + 3 分钟宽限', () {
      // 20:00 / 20:02（间隔 2min ≤ 3min 同段）/ 20:07（间隔 5min > 3min 切段）：
      // 段1 = [20:00, 20:02+3min=20:05] = 300s；
      // 段2 = [20:07, min(20:08, 20:07+3min=20:10)] = [20:07, 20:08] = 60s。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.1);
      t.noteActivity(at: _ts(2026, 9, 24, 20, 2), chapterHref: 'ch1', chapterPos: 0.3);
      t.noteActivity(at: _ts(2026, 9, 24, 20, 7), chapterHref: 'ch2', chapterPos: 0.2);
      final List<ReadingSession> out = t.finish(
        at: _ts(2026, 9, 24, 20, 8),
        chapterHref: 'ch3',
        chapterPos: 0.9,
      );

      expect(out, hasLength(2));
      final ReadingSession r1 = out[0];
      expect(r1.id, '${_ts(2026, 9, 24, 20, 0)}_bookA');
      expect(r1.startedAt, _ts(2026, 9, 24, 20, 0));
      expect(r1.endedAt, _ts(2026, 9, 24, 20, 5));
      expect(r1.duration, 300);
      expect(r1.start.chapterHref, 'ch1');
      expect(r1.start.chapterPos, closeTo(0.1, 1e-9));
      expect(r1.end.chapterHref, 'ch1');
      expect(r1.end.chapterPos, closeTo(0.3, 1e-9));

      final ReadingSession r2 = out[1];
      expect(r2.id, '${_ts(2026, 9, 24, 20, 7)}_bookA');
      expect(r2.startedAt, _ts(2026, 9, 24, 20, 7));
      expect(r2.endedAt, _ts(2026, 9, 24, 20, 8));
      expect(r2.duration, 60);
      expect(r2.start.chapterHref, 'ch2');
      // 显式收尾坐标覆盖末条记录终点。
      expect(r2.end.chapterHref, 'ch3');
      expect(r2.end.chapterPos, closeTo(0.9, 1e-9));
    });

    test('收尾前空闲 10 分钟只计 3 分钟宽限（STAT-01 ②）', () {
      // 20:00 活跃一次、20:10 收尾：
      // [20:00, min(20:10, 20:00+3min=20:03)] = [20:00, 20:03] = 180s（≈3 分钟，
      // 而非 600s）。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.0);
      final List<ReadingSession> out =
          t.finish(at: _ts(2026, 9, 24, 20, 10));

      expect(out, hasLength(1));
      expect(out.single.duration, 180);
      expect(out.single.endedAt, _ts(2026, 9, 24, 20, 3));
    });

    test('finish 不带收尾时刻：按最后活跃 + 3 分钟宽限收口', () {
      // 20:00 / 20:01 活跃，无收尾时刻 → [20:00, 20:01+3min=20:04] = 240s。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.0);
      t.noteActivity(at: _ts(2026, 9, 24, 20, 1), chapterHref: 'ch1', chapterPos: 0.2);
      final List<ReadingSession> out = t.finish();

      expect(out, hasLength(1));
      expect(out.single.startedAt, _ts(2026, 9, 24, 20, 0));
      expect(out.single.endedAt, _ts(2026, 9, 24, 20, 4));
      expect(out.single.duration, 240);
    });

    test('空闲切会话后恢复活跃，后续时长继续累计（STAT-01 ③）', () {
      // 20:00 / 20:10（间隔 10min > 3min 切段）/ 20:12 / 20:14 收尾：
      // 段1 = [20:00, 20:00+3min=20:03] = 180s；
      // 段2 = [20:10, min(20:14, 20:12+3min=20:15)] = [20:10, 20:14] = 240s；
      // 合计 420s（切会话不丢时长）。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.0);
      t.noteActivity(at: _ts(2026, 9, 24, 20, 10), chapterHref: 'ch1', chapterPos: 0.6);
      t.noteActivity(at: _ts(2026, 9, 24, 20, 12), chapterHref: 'ch2', chapterPos: 0.1);
      final List<ReadingSession> out =
          t.finish(at: _ts(2026, 9, 24, 20, 14));

      expect(out, hasLength(2));
      expect(out[0].duration, 180);
      expect(out[1].duration, 240);
      expect(out[0].duration + out[1].duration, 420);
    });

    test('空闲恰好 3 分钟不切会话（「超过」口径）', () {
      // 20:00 / 20:03（间隔恰 3min，不超过 → 同段，整段计入）/ 20:05 收尾：
      // [20:00, min(20:05, 20:03+3min=20:06)] = [20:00, 20:05] = 300s。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.0);
      t.noteActivity(at: _ts(2026, 9, 24, 20, 3), chapterHref: 'ch1', chapterPos: 0.5);
      final List<ReadingSession> out =
          t.finish(at: _ts(2026, 9, 24, 20, 5));

      expect(out, hasLength(1));
      expect(out.single.duration, 300);
    });

    test('finish 幂等（不清空事件，可重复调用结果一致）', () {
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.0);
      final List<ReadingSession> first = t.finish(at: _ts(2026, 9, 24, 20, 2));
      final List<ReadingSession> second = t.finish(at: _ts(2026, 9, 24, 20, 2));
      expect(second, first);
      expect(first.single.duration, 120);
    });
  });

  group('跨 0 点拆天（STAT-02）', () {
    test('跨 0 点的一次会话按实际秒数拆成两条（STAT-02 ①）', () {
      // 23:50 起每 2 分钟一次活跃直至 00:28（间隔均 ≤ 3min → 全程同一会话），
      // 00:30 收尾：段 = [23:50, min(00:30, 00:28+3min=00:31)] = [23:50, 00:30]
      // 共 2400s，按 0 点拆：
      //   条1 = [23:50, 24:00] = 600s → 2026-09-24；
      //   条2 = [00:00, 00:30] = 1800s → 2026-09-25；
      // 合计 2400s = 真实时长（PRD 验收口径：+600s / +1800s）。
      final SessionTracker t = _tracker('bookA');
      final int base = _ts(2026, 9, 24, 23, 50);
      for (int m = 0; m <= 38; m += 2) {
        t.noteActivity(
          at: base + m * 60 * 1000,
          chapterHref: 'ch1',
          chapterPos: 0.5,
        );
      }
      final List<ReadingSession> out =
          t.finish(at: _ts(2026, 9, 25, 0, 30));

      expect(out, hasLength(2));
      final ReadingSession d1 = out[0];
      expect(d1.dayKey, '2026-09-24');
      expect(d1.startedAt, _ts(2026, 9, 24, 23, 50));
      expect(d1.endedAt, _ts(2026, 9, 25, 0, 0));
      expect(d1.duration, 600);

      final ReadingSession d2 = out[1];
      expect(d2.dayKey, '2026-09-25');
      expect(d2.startedAt, _ts(2026, 9, 25, 0, 0));
      expect(d2.endedAt, _ts(2026, 9, 25, 0, 30));
      expect(d2.duration, 1800);

      expect(d1.duration + d2.duration, 2400);
      // 两条各自拥有稳定唯一 id（续条从 0 点起算）。
      expect(d1.id, '${_ts(2026, 9, 24, 23, 50)}_bookA');
      expect(d2.id, '${_ts(2026, 9, 25, 0, 0)}_bookA');
    });

    test('空闲宽限跨 0 点同样拆天', () {
      // 23:58 活跃一次、00:10 收尾：段 = [23:58, min(00:10, 00:01)] = [23:58, 00:01]
      // 共 180s，拆为 [23:58, 24:00] = 120s（24 日）与 [00:00, 00:01] = 60s（25 日）。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 23, 58), chapterHref: 'ch1', chapterPos: 0.0);
      final List<ReadingSession> out =
          t.finish(at: _ts(2026, 9, 25, 0, 10));

      expect(out, hasLength(2));
      expect(out[0].dayKey, '2026-09-24');
      expect(out[0].duration, 120);
      expect(out[1].dayKey, '2026-09-25');
      expect(out[1].duration, 60);
      expect(out[0].duration + out[1].duration, 180);
    });

    test('拆天接缝两侧坐标一致（取边界前最后一次活跃）', () {
      // 23:55 (ch1, 0.5) / 23:58 (ch2, 0.8)，00:05 收尾：
      // 段 = [23:55, min(00:05, 00:01)] = [23:55, 00:01] = 360s → 300s + 60s；
      // 0 点接缝前最后一次活跃是 23:58 → 条1.end == 条2.start == (ch2, 0.8)。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 23, 55), chapterHref: 'ch1', chapterPos: 0.5);
      t.noteActivity(at: _ts(2026, 9, 24, 23, 58), chapterHref: 'ch2', chapterPos: 0.8);
      final List<ReadingSession> out =
          t.finish(at: _ts(2026, 9, 25, 0, 5));

      expect(out, hasLength(2));
      expect(out[0].duration, 300);
      expect(out[1].duration, 60);
      expect(out[0].start.chapterHref, 'ch1');
      expect(out[0].end.chapterHref, 'ch2');
      expect(out[0].end.chapterPos, closeTo(0.8, 1e-9));
      expect(out[1].start.chapterHref, 'ch2');
      expect(out[1].start.chapterPos, closeTo(0.8, 1e-9));
      expect(out[1].end.chapterPos, closeTo(0.8, 1e-9));
    });

    test('不足 1 秒的碎片不产出记录（禁止 duration ≤ 0）', () {
      // 23:59:59.500 活跃、00:00:00.400 收尾：段长 900ms，拆为 500ms + 400ms，
      // 整秒下取整均为 0 → 一条都不落（STAT-02 ②）。
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(
        at: _ts(2026, 9, 24, 23, 59, 59, 500),
        chapterHref: 'ch1',
        chapterPos: 0.0,
      );
      final List<ReadingSession> out = t.finish(
        at: _ts(2026, 9, 25, 0, 0, 0, 400),
      );
      expect(out, isEmpty);
    });

    test('无活跃事件 → 空结果', () {
      expect(_tracker('bookA').finish(at: _ts(2026, 9, 24, 20, 0)), isEmpty);
    });
  });

  group('ReadingSession JSON 往返与防御', () {
    test('toJson / fromJson 往返等价', () {
      final SessionTracker t = _tracker('bookA');
      t.noteActivity(at: _ts(2026, 9, 24, 20, 0), chapterHref: 'ch1', chapterPos: 0.25);
      final ReadingSession r = t.finish(at: _ts(2026, 9, 24, 20, 2)).single;
      expect(ReadingSession.fromJson(r.toJson()), r);
    });

    test('fromJson 非法输入 → null（不抛）', () {
      expect(ReadingSession.fromJson(null), isNull);
      expect(ReadingSession.fromJson('oops'), isNull);
      expect(ReadingSession.fromJson(<String, Object?>{'id': 1}), isNull);
      expect(SessionPosition.fromJson(<String, Object?>{'chapterHref': 1}), isNull);
    });
  });

  group('StatsIndex 聚合正确性', () {
    ReadingSession session(
      String bookId,
      String dayKey,
      int startedAt,
      int duration,
    ) {
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

    test('按日 / 按书逐秒汇总（手工推演 480 / 180 / 540 / 120 / 660）', () {
      // s1 bookA 09-01 300s；s2 bookA 09-01 60s；s3 bookB 09-01 120s；
      // s4 bookA 09-02 180s；s5 duration 0 → 跳过（禁写口径同源）。
      // day: 09-01 = 300+60+120 = 480；09-02 = 180
      // book: bookA = 300+60+180 = 540；bookB = 120
      // total = 300+60+120+180 = 660
      final StatsIndex index = StatsIndex.of(<ReadingSession>[
        session('bookA', '2026-09-01', _ts(2026, 9, 1, 8, 0), 300),
        session('bookA', '2026-09-01', _ts(2026, 9, 1, 9, 0), 60),
        session('bookB', '2026-09-01', _ts(2026, 9, 1, 10, 0), 120),
        session('bookA', '2026-09-02', _ts(2026, 9, 2, 8, 0), 180),
        session('bookA', '2026-09-02', _ts(2026, 9, 2, 9, 0), 0),
      ]);

      expect(index.secondsByDay, <String, int>{
        '2026-09-01': 480,
        '2026-09-02': 180,
      });
      expect(index.secondsByBook, <String, int>{
        'bookA': 540,
        'bookB': 120,
      });
      expect(index.totalSeconds, 660);
    });

    test('空输入 → 空索引', () {
      final StatsIndex index = StatsIndex.of(const <ReadingSession>[]);
      expect(index.secondsByDay, isEmpty);
      expect(index.secondsByBook, isEmpty);
      expect(index.totalSeconds, 0);
    });
  });
}
