// `M3-T12`：热力图测试（`STAT-05`）。
//
// 纯聚合断言分档阈值与「点击明细 = `STAT-04` 下钻 = 柱高」三口径一致；
// widget 级断言年块连续、档位映射、点格回调（经 `centerOf` 观测口命中）。
// ⚠️ FakeAsync 铁律：本文件 widget 无真异步 IO，`pump` 即可；不走 pumpAndSettle。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/stats/aggregator.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/ui/stats/heatmap.dart';

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

/// widget 级种子：跨年 3 天（档 4 / 档 2 / 档 1），09-15 无记录。
List<ReadingSession> _seed() => <ReadingSession>[
      _session(bookId: 'bookA', dayKey: '2025-12-31', duration: 5000),
      _session(bookId: 'bookA', dayKey: '2026-09-14', duration: 600),
      _session(bookId: 'bookA', dayKey: '2026-09-16', duration: 30),
    ];

void main() {
  capTestTimeout();

  group('分档与口径（纯函数）', () {
    test('STAT-05 ①：1 分钟进最低档，时长增加档位单调加深', () {
      expect(heatLevel(0), 0); // 无记录 = 空白格
      expect(heatLevel(-1), 0);
      expect(heatLevel(30), 1); // 有记录不足 1 分钟也在最低档（不空白）
      expect(heatLevel(60), 1); // 恰 1 分钟 = 最低档上界
      expect(heatLevel(61), 2);
      expect(heatLevel(1800), 2);
      expect(heatLevel(1801), 3);
      expect(heatLevel(3600), 3);
      expect(heatLevel(3601), 4);
      expect(heatLevel(86400), 4);
      // 单调不减。
      int prev = 0;
      for (int s = 0; s <= 7200; s += 30) {
        final int level = heatLevel(s);
        expect(level >= prev, isTrue, reason: '$s 秒不应降档');
        prev = level;
      }
    });

    test('daySeconds：按天求和 + since 过滤 + duration<=0 剔除', () {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'a', dayKey: '2026-09-10', duration: 600),
        _session(bookId: 'a', dayKey: '2026-09-10', duration: 120),
        _session(bookId: 'b', dayKey: '2026-09-11', duration: 0),
        _session(bookId: 'b', dayKey: '2026-08-15', duration: 1800),
      ];
      final Map<String, int> days = daySeconds(seed);
      expect(days['2026-09-10'], 720);
      expect(days.containsKey('2026-09-11'), isFalse); // 0 秒不进表
      expect(days['2026-08-15'], 1800);
      final Map<String, int> since = daySeconds(seed, sinceDay: '2026-09-01');
      expect(since.keys, <String>['2026-09-10']);
    });

    test('STAT-05 ②：点击明细 = STAT-04 下钻 = 柱高（三口径一致）', () {
      final List<ReadingSession> seed = <ReadingSession>[
        _session(bookId: 'a', dayKey: '2026-09-14', duration: 600),
        _session(bookId: 'b', dayKey: '2026-09-14', duration: 300),
        _session(bookId: 'a', dayKey: '2026-09-16', duration: 30),
      ];
      final DateTime now = DateTime(2026, 9, 16);
      final Map<String, int> days = daySeconds(seed);
      final List<PeriodBar> week = aggregateBars(
        seed,
        period: StatsPeriod.week,
        now: now,
      );
      for (final PeriodBar bar in week) {
        // 下钻（单日 sessionsInRange）求和。
        final List<ReadingSession> drill = sessionsInRange(
          seed,
          fromDay: bar.startDay,
          toDay: bar.endDay,
        );
        final int drillSum =
            drill.fold<int>(0, (int s, ReadingSession x) => s + x.duration);
        // 热力图数据源（daySeconds，周视图两单日柱）。
        final int daySum = days[bar.startDay] ?? 0;
        expect(drillSum, bar.seconds, reason: '下钻 = 柱高（${bar.label}）');
        if (bar.startDay == bar.endDay) {
          expect(daySum, bar.seconds, reason: '热力图数据 = 柱高（${bar.label}）');
        }
      }
      expect(days['2026-09-14'], 900);
    });
  });

  group('ReadingHeatmap widget', () {
    testWidgets('年块连续且含今年；档位映射正确；无记录天为空白格',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReadingHeatmap(sessions: _seed()),
            ),
          ),
        ),
      );
      final ReadingHeatmapState state =
          tester.state<ReadingHeatmapState>(find.byType(ReadingHeatmap));

      // 年份连续、最后一年 = 今年（含 2025/2026 两个种子年）。
      expect(state.years.last, DateTime.now().year);
      expect(state.years, containsAll(<int>[2025, 2026]));
      for (int i = 1; i < state.years.length; i++) {
        expect(state.years[i] - state.years[i - 1], 1, reason: '年份应连续');
      }
      // 档位：5000s→4、600s→2、30s→1。
      expect(state.levels['2025-12-31'], 4);
      expect(state.levels['2026-09-14'], 2);
      expect(state.levels['2026-09-16'], 1);
      // 无记录天不在 levels（= 空白格，STAT-05 ③）。
      expect(state.levels.containsKey('2026-09-15'), isFalse);
      // 两个年份区块在场（跨年）。
      expect(find.byKey(const ValueKey<String>('heatmap-year-2025')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('heatmap-year-2026')), findsOneWidget);
    });

    testWidgets('点格回调：centerOf 命中返回对应 dayKey',
        (WidgetTester tester) async {
      String? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReadingHeatmap(
                sessions: _seed(),
                onTapDay: (String day) => tapped = day,
              ),
            ),
          ),
        ),
      );
      final ReadingHeatmapState state =
          tester.state<ReadingHeatmapState>(find.byType(ReadingHeatmap));
      final Offset center = state.centerOf('2026-09-14')!;
      final Rect plot = tester.getRect(
        find.byKey(const ValueKey<String>('heatmap-plot-2026')),
      );

      await tester.tapAt(plot.topLeft + center);
      await tester.pump();
      expect(tapped, '2026-09-14');
    });

    testWidgets('空数据：只显示今年区块、levels 全空、不报错',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReadingHeatmap(sessions: const <ReadingSession>[]),
            ),
          ),
        ),
      );
      final ReadingHeatmapState state =
          tester.state<ReadingHeatmapState>(find.byType(ReadingHeatmap));
      expect(state.years, <int>[DateTime.now().year]);
      expect(state.levels, isEmpty);
      expect(find.text('${DateTime.now().year}年'), findsOneWidget);
    });
  });
}
