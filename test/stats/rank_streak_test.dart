// `M3-T13`：按书排行（`STAT-06`）+ 连续阅读天数（`STAT-07` / `Q13`）测试。
//
// 纯逻辑用固定 [now] 断言窗口 / 排序 / 百分比补余 / 归零口径五验收；
// widget 级用「全部」周期避开真实时钟（seed 全为固定过去日期）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/stats/aggregator.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/stats/streak.dart';
import 'package:mreader/ui/stats/rank_list.dart';

import '../test_config.dart';

/// 构造一条记录（id 派生口径同采集器）。
ReadingSession _session({
  required String bookId,
  required String dayKey,
  required int duration,
}) {
  final DateTime day = DateTime.parse(dayKey);
  final int startedAt =
      DateTime(day.year, day.month, day.day, 9).millisecondsSinceEpoch;
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

/// 固定锚点：2026-09-17 是周四。
final DateTime _now = DateTime(2026, 9, 17);

void main() {
  capTestTimeout();

  group('computeStreak（STAT-07 验收 ①~⑤）', () {
    test('①周一至周三各读一次，周四打开显示连续 3 天（今日待读）', () {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'a', dayKey: '2026-09-14', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-15', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-16', duration: 60),
      ];
      final StreakStats s = computeStreak(seed, now: _now); // 09-17 周四
      expect(s.current, 3);
      expect(s.longest, 3);
      expect(s.todayPending, isTrue);
    });

    test('②周四全天未读、周五打开仍显示 3 天（单日缺口不归零）', () {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'a', dayKey: '2026-09-14', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-15', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-16', duration: 60),
      ];
      final StreakStats s = computeStreak(seed, now: DateTime(2026, 9, 18));
      expect(s.current, 3);
      expect(s.todayPending, isTrue);
    });

    test('③周五也未读、周六打开归零（连续缺 2 个完整天才归零）', () {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'a', dayKey: '2026-09-14', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-15', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-16', duration: 60),
      ];
      final StreakStats s = computeStreak(seed, now: DateTime(2026, 9, 19));
      expect(s.current, 0);
      expect(s.longest, 3); // ④ 断开后历史最长不回退
      expect(s.todayPending, isTrue);
    });

    test('④历史最长不回退 + 今天有记录时今日已读', () {
      final List<ReadingSession> seed = <ReadingSession>[
        for (int d = 1; d <= 9; d++)
          _session(
            bookId: 'a',
            dayKey: '2026-09-${d.toString().padLeft(2, '0')}',
            duration: 60,
          ),
        _session(bookId: 'a', dayKey: '2026-09-16', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-17', duration: 60),
      ];
      final StreakStats s = computeStreak(seed, now: _now); // 今天 09-17 已读
      expect(s.longest, 9);
      expect(s.current, 2); // 17 → 16，15 缺口
      expect(s.todayPending, isFalse);
    });

    test('⑤跨 0 点拆天的两条 dayKey 相邻 → 连续计入（同 STAT-02 拆天）', () {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'a', dayKey: '2026-09-16', duration: 600),
        _session(bookId: 'a', dayKey: '2026-09-17', duration: 60),
      ];
      final StreakStats s = computeStreak(seed, now: _now);
      expect(s.current, 2);
      expect(s.longest, 2);
    });

    test('空数据 / since 过滤', () {
      final StreakStats empty = computeStreak(
        const <ReadingSession>[],
        now: _now,
      );
      expect(empty.current, 0);
      expect(empty.longest, 0);
      expect(empty.todayPending, isTrue);

      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'a', dayKey: '2026-07-01', duration: 60),
        _session(bookId: 'a', dayKey: '2026-07-02', duration: 60),
        _session(bookId: 'a', dayKey: '2026-07-03', duration: 60),
        _session(bookId: 'a', dayKey: '2026-09-16', duration: 60),
      ];
      final StreakStats since = computeStreak(
        seed,
        sinceDay: '2026-09-01',
        now: _now,
      );
      expect(since.longest, 1); // 7 月段被起始日期过滤
      expect(since.current, 1);
    });
  });

  group('rankByBook（STAT-06 验收 ①②③）', () {
    test('①A 10 分钟在 B 5 分钟前；②百分比之和恰 100%（最大项补余）', () {
      final RankResult r = rankByBook(
        <ReadingSession>[
          _session(bookId: 'bookA', dayKey: '2026-09-17', duration: 600),
          _session(bookId: 'bookB', dayKey: '2026-09-17', duration: 300),
          _session(bookId: 'bookC', dayKey: '2026-09-17', duration: 111),
        ],
        period: RankPeriod.day,
        now: _now,
      );
      expect(r.entries.first.bookId, 'bookA');
      expect(r.entries[1].bookId, 'bookB');
      expect(r.totalSeconds, 1011);
      // floor：59 + 29 + 10 = 98 → 余数 2 补给第一名 → 61。
      expect(r.entries[0].percent, 61);
      expect(
        r.entries.fold<int>(0, (int s, RankEntry e) => s + e.percent),
        100,
      );
    });

    test('③切换周期后列表内容与数字同步变化（日/周/月/全部窗口）', () {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'bookA', dayKey: '2026-09-17', duration: 600),
        _session(bookId: 'bookB', dayKey: '2026-09-10', duration: 300),
        _session(bookId: 'bookB', dayKey: '2026-08-15', duration: 1800),
      ];
      final RankResult day = rankByBook(
        seed,
        period: RankPeriod.day,
        now: _now,
      );
      expect(day.entries.map((RankEntry e) => e.bookId), <String>['bookA']);
      expect(day.totalSeconds, 600);

      final RankResult week = rankByBook(
        seed,
        period: RankPeriod.week,
        now: _now,
      ); // 本周 = 09-14 ~ 09-20
      expect(week.entries.map((RankEntry e) => e.bookId), <String>['bookA']);

      final RankResult month = rankByBook(
        seed,
        period: RankPeriod.month,
        now: _now,
      );
      expect(
        month.entries.map((RankEntry e) => e.bookId).toList(),
        <String>['bookA', 'bookB'], // 09-10 与 09-16 都在 9 月
      );
      expect(month.totalSeconds, 900);

      final RankResult all = rankByBook(seed, period: RankPeriod.all, now: _now);
      expect(all.totalSeconds, 600 + 300 + 1800);
      expect(
        all.entries.fold<int>(0, (int s, RankEntry e) => s + e.percent),
        100,
      );
    });

    test('空态 + since 过滤 + 无记录不产百分比', () {
      final RankResult empty = rankByBook(
        const <ReadingSession>[],
        period: RankPeriod.week,
        now: _now,
      );
      expect(empty, RankResult.empty);

      final RankResult since = rankByBook(
        <ReadingSession>[
          _session(bookId: 'bookB', dayKey: '2026-08-15', duration: 1800),
          _session(bookId: 'bookA', dayKey: '2026-09-16', duration: 600),
        ],
        period: RankPeriod.all,
        now: _now,
        sinceDay: '2026-09-01',
      );
      expect(since.entries.map((RankEntry e) => e.bookId), <String>['bookA']);
      expect(since.totalSeconds, 600);
    });
  });

  group('widget（排行卡 + 连续卡）', () {
    testWidgets('切换周期：空态 ↔ 列表；排序、百分比与行文案',
        (WidgetTester tester) async {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'bookA', dayKey: '2026-09-10', duration: 600),
        _session(bookId: 'bookB', dayKey: '2026-08-15', duration: 300),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: BookRankCard(sessions: seed)),
          ),
        ),
      );
      BookRankCardState state =
          tester.state<BookRankCardState>(find.byType(BookRankCard));
      // 默认「周」：seed 全是过去固定日期，多半不在本周 → 空态。
      expect(find.text('该周期无阅读记录'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pump();
      state = tester.state<BookRankCardState>(find.byType(BookRankCard));
      expect(state.result.entries, hasLength(2));
      expect(state.result.entries.first.bookId, 'bookA'); // 600 > 300
      expect(
        state.result.entries.fold<int>(0, (int s, RankEntry e) => s + e.percent),
        100,
      );
      // 行文案（无 repository → 降级 bookId）+ 百分比。
      expect(find.text('bookA'), findsOneWidget);
      expect(find.text('bookB'), findsOneWidget);
      expect(find.text('67%'), findsOneWidget); // 600/900 补余后
      expect(find.text('33%'), findsOneWidget);
      expect(find.text('该周期无阅读记录'), findsNothing);
    });

    testWidgets('点击行 → 单书统计页（总时长 + 会话行 + 返回）',
        (WidgetTester tester) async {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'bookA', dayKey: '2026-09-10', duration: 600),
        _session(bookId: 'bookB', dayKey: '2026-08-15', duration: 300),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BookRankCard(
                sessions: seed,
                onTapBook: (String bookId, String title, RankPeriod period) {
                  Navigator.of(tester.element(find.byType(BookRankCard))).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BookStatsPage(
                        bookId: bookId,
                        title: title,
                        sessions: seed,
                        period: period,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('全部'));
      await tester.pump();
      await tester.tap(find.text('bookA'));
      await tester.pumpAndSettle();

      expect(find.text('bookA'), findsOneWidget); // 顶栏书名
      expect(find.text('周期内总时长'), findsOneWidget);
      // 两处：总时长 headline + 会话行时长（都是 600s = 10 分钟）。
      expect(find.text('10 分钟'), findsNWidgets(2));
      expect(find.text('9月10日 09:00 – 09:10'), findsOneWidget); // 600s
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('StreakCard：今日待读后缀 + 历史最长 + 口径常驻文案（Q13）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StreakCard(
                streak: StreakStats(
                  current: 3,
                  longest: 9,
                  todayPending: true,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('累计 3 天 · 今日待读'), findsOneWidget);
      expect(find.text('历史最长 9 天'), findsOneWidget);
      expect(find.textContaining('连续 2 天未读才重新计算'), findsOneWidget);
      expect(find.textContaining('历史最长不回退'), findsOneWidget);
    });

    testWidgets('StreakCard：今日已读后缀消失', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StreakCard(
                streak: StreakStats(
                  current: 5,
                  longest: 9,
                  todayPending: false,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('累计 5 天'), findsOneWidget);
      expect(find.textContaining('今日待读'), findsNothing);
    });
  });
}
