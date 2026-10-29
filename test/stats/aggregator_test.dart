// `STAT-03`：统计聚合单测（纯函数，无 IO，普通 `test()`）。
//
// 断言值人工推演（文件内各处给出推演式）；`sinceDay` 过滤对应
// `STAT-03` ③「起始日期设为 2026-09-01 后，8 月的记录不再计入」。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/stats/aggregator.dart';
import 'package:mreader/stats/reading_session.dart';

/// 构造一条记录（id 派生口径同采集器；坐标固定）。
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
    start: SessionPosition(chapterHref: 'c1', chapterPos: 0.1),
    end: SessionPosition(chapterHref: 'c1', chapterPos: 0.9),
  );
}

void main() {
  // 推演样本：
  //   A: bookA 2026-09-10 600s
  //   B: bookA 2026-09-10 120s（同天同书，去重计 1 天 1 本）
  //   C: bookB 2026-09-11 300s
  //   D: bookB 2026-08-15 1800s（8 月，sinceDay 过滤用）
  //   E: bookC 2026-09-11 0s（duration<=0 聚合跳过）
  final List<ReadingSession> sessions = <ReadingSession>[
    _session(bookId: 'bookA', dayKey: '2026-09-10', startedAt: 1, duration: 600),
    _session(bookId: 'bookA', dayKey: '2026-09-10', startedAt: 2, duration: 120),
    _session(bookId: 'bookB', dayKey: '2026-09-11', startedAt: 3, duration: 300),
    _session(bookId: 'bookB', dayKey: '2026-08-15', startedAt: 4, duration: 1800),
    _session(bookId: 'bookC', dayKey: '2026-09-11', startedAt: 5, duration: 0),
  ];

  group('aggregateOverview（STAT-03 三指标）', () {
    test('全部记录：总时长逐秒、天数 / 书籍去重、duration<=0 跳过', () {
      final OverviewStats o = aggregateOverview(sessions);
      // 总时长 = 600+120+300+1800（0s 的 E 不计）= 2820。
      expect(o.totalSeconds, 2820);
      // 天：09-10 / 09-11 / 08-15 = 3（E 与 C 同天，去重）。
      expect(o.activeDays, 3);
      // 本：bookA / bookB = 2（bookC 只有 0s 记录，不计）。
      expect(o.bookCount, 2);
    });

    test('STAT-03 ③：sinceDay=2026-09-01 后 8 月记录不计入', () {
      final OverviewStats o = aggregateOverview(sessions, sinceDay: '2026-09-01');
      // 去掉 8 月的 1800s：2820-1800 = 1020。
      expect(o.totalSeconds, 1020);
      // 天：09-10 / 09-11 = 2。
      expect(o.activeDays, 2);
      // 本：bookA / bookB = 2（bookB 的 9 月记录仍在）。
      expect(o.bookCount, 2);
    });

    test('起始日期晚于全部记录 → 全 0（清空态同形）', () {
      final OverviewStats o = aggregateOverview(sessions, sinceDay: '2027-01-01');
      expect(o.totalSeconds, 0);
      expect(o.activeDays, 0);
      expect(o.bookCount, 0);
      expect(aggregateOverview(const <ReadingSession>[]).totalSeconds, 0);
      expect(aggregateOverview(const <ReadingSession>[]).activeDays, 0);
      expect(aggregateOverview(const <ReadingSession>[]).bookCount, 0);
    });

    test('filterSince 不改动入参，空 sinceDay = 不限', () {
      final List<ReadingSession> input = List<ReadingSession>.of(sessions);
      final List<ReadingSession> filtered =
          filterSince(input, '2026-09-01');
      expect(filtered.length, 4); // 去掉 8 月那条
      expect(input.length, 5); // 原列表未被改动
      expect(filterSince(input, null).length, 5);
      expect(filterSince(input, '').length, 5);
    });
  });

  group('formatReadingDuration（展示口径）', () {
    test('秒 → 「X 小时 Y 分」/「X 分钟」/ 边界', () {
      expect(formatReadingDuration(0), '0 分钟');
      expect(formatReadingDuration(-5), '0 分钟');
      expect(formatReadingDuration(30), '不足 1 分钟');
      expect(formatReadingDuration(59), '不足 1 分钟');
      expect(formatReadingDuration(60), '1 分钟');
      expect(formatReadingDuration(600), '10 分钟');
      expect(formatReadingDuration(3599), '59 分钟');
      expect(formatReadingDuration(3600), '1 小时');
      expect(formatReadingDuration(5460), '1 小时 31 分'); // 1h31m
      expect(formatReadingDuration(7200), '2 小时');
    });
  });
}
