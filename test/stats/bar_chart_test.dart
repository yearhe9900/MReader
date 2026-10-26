// `STAT-04`：周期柱状图 + 下钻明细测试。
//
// 纯聚合用**固定 now = 2026-09-16（周三）**断言柱数 / 标签 / 高亮 / since 过滤 /
// 「下钻求和 = 柱高」；widget 级用真实时钟只断言结构（周恒 7 柱 / 月当月天数 /
// 年 12 柱）与命中回调，避免对真实日期的脆弱依赖。
// ⚠️ FakeAsync 铁律：widget 体内的真异步 IO（repository.loadBooks）用 [settle]
// （runAsync + pump 交替）排空，禁 `pumpAndSettle` 收尾。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/stats/aggregator.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/ui/stats/bar_chart.dart';
import 'package:mreader/ui/stats/drill_down_page.dart';

import '../reader/reader_harness.dart';
import '../test_config.dart';

/// 构造一条记录（id 派生口径同采集器；startedAt 取当日真实钟点）。
ReadingSession _session({
  required String bookId,
  required String dayKey,
  required int duration,
  int hour = 9,
  int minute = 0,
}) {
  final DateTime day = DateTime.parse(dayKey);
  final int startedAt = DateTime(
    day.year,
    day.month,
    day.day,
    hour,
    minute,
  ).millisecondsSinceEpoch;
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

/// 固定锚点：2026-09-16 是周三（week → 09-14 ~ 09-20）。
final DateTime _now = DateTime(2026, 9, 16);

/// 固定种子（跨周 / 月 / 年 + 一条 0 秒应被剔除）。
List<ReadingSession> _seed() => <ReadingSession>[
      _session(bookId: 'bookA', dayKey: '2026-09-14', duration: 600),
      _session(bookId: 'bookA', dayKey: '2026-09-16', duration: 300),
      _session(bookId: 'bookB', dayKey: '2026-09-16', duration: 0, hour: 10),
      _session(bookId: 'bookB', dayKey: '2026-09-20', duration: 120),
      _session(bookId: 'bookB', dayKey: '2026-08-15', duration: 1800),
      _session(bookId: 'bookA', dayKey: '2026-01-05', duration: 600),
    ];

/// 柱序列合计（与下钻求和对照）。
int _barsTotal(List<PeriodBar> bars) =>
    bars.fold<int>(0, (int s, PeriodBar b) => s + b.seconds);

/// 逐柱「下钻求和 = 柱高」核对（共享谓词的结构性验证）。
void _expectDrillEqualsBars(
  List<PeriodBar> bars,
  List<ReadingSession> sessions, {
  String? sinceDay,
}) {
  for (final PeriodBar b in bars) {
    final List<ReadingSession> inRange = sessionsInRange(
      sessions,
      fromDay: b.startDay,
      toDay: b.endDay,
      sinceDay: sinceDay,
    );
    final int sum =
        inRange.fold<int>(0, (int s, ReadingSession x) => s + x.duration);
    expect(sum, b.seconds, reason: '下钻求和应等于柱高（${b.label}）');
  }
}

void main() {
  capTestTimeout();

  group('纯聚合（固定 now = 2026-09-16 周三）', () {
    test('周视图：恒 7 根、标签 一…日、区间 09-14 ~ 09-20、今天高亮', () {
      final List<PeriodBar> bars = aggregateBars(
        _seed(),
        period: StatsPeriod.week,
        now: _now,
      );
      expect(bars, hasLength(7));
      expect(
        bars.map((PeriodBar b) => b.label).toList(),
        <String>['一', '二', '三', '四', '五', '六', '日'],
      );
      expect(bars.first.startDay, '2026-09-14');
      expect(bars.last.endDay, '2026-09-20');
      // 柱高：09-14=600、09-16=300（0 秒那条被剔除）、09-20=120。
      expect(
        bars.map((PeriodBar b) => b.seconds).toList(),
        <int>[600, 0, 300, 0, 0, 0, 120],
      );
      expect(
        bars.where((PeriodBar b) => b.isCurrent).map((PeriodBar b) => b.label)
            .toList(),
        <String>['三'],
      );
    });

    test('月视图：柱数 = 当月天数（9 月 30 根）、日号标签、16 日高亮、合计只含 9 月', () {
      final List<PeriodBar> bars = aggregateBars(
        _seed(),
        period: StatsPeriod.month,
        now: _now,
      );
      expect(bars, hasLength(30));
      expect(bars.first.label, '1');
      expect(bars.last.label, '30');
      expect(_barsTotal(bars), 600 + 300 + 120); // 8 月 / 1 月不进 9 月柱。
      expect(bars[15].label, '16');
      expect(bars[15].isCurrent, isTrue);
      expect(bars.where((PeriodBar b) => b.isCurrent), hasLength(1));
    });

    test('年视图：恒 12 根、标签 N月、各月合计、当月高亮', () {
      final List<PeriodBar> bars = aggregateBars(
        _seed(),
        period: StatsPeriod.year,
        now: _now,
      );
      expect(bars, hasLength(12));
      expect(bars.first.label, '1月');
      expect(bars.last.label, '12月');
      expect(bars[0].seconds, 600); // 1 月
      expect(bars[7].seconds, 1800); // 8 月
      expect(bars[8].seconds, 1020); // 9 月 = 600+300+120
      expect(bars[8].isCurrent, isTrue);
      expect(bars.where((PeriodBar b) => b.isCurrent), hasLength(1));
      expect(_barsTotal(bars), 600 + 1800 + 1020);
    });

    test('since 过滤：起始日期后才计入（与 overview 同口径）', () {
      for (final StatsPeriod period in StatsPeriod.values) {
        final List<PeriodBar> bars = aggregateBars(
          _seed(),
          period: period,
          now: _now,
          sinceDay: '2026-09-01',
        );
        expect(_barsTotal(bars), 1020, reason: '$period 应只剩 9 月记录');
      }
      // 0 秒记录在任何口径下都不产生柱高。
      final List<PeriodBar> day = aggregateBars(
        _seed(),
        period: StatsPeriod.week,
        now: _now,
      );
      expect(day[2].seconds, 300);
    });

    test('下钻求和 = 柱高：三段视图逐柱核对（共享谓词）', () {
      final List<ReadingSession> sessions = _seed();
      for (final StatsPeriod period in StatsPeriod.values) {
        final List<PeriodBar> bars = aggregateBars(
          sessions,
          period: period,
          now: _now,
        );
        _expectDrillEqualsBars(bars, sessions);
        final List<PeriodBar> since = aggregateBars(
          sessions,
          period: period,
          now: _now,
          sinceDay: '2026-09-01',
        );
        _expectDrillEqualsBars(since, sessions, sinceDay: '2026-09-01');
      }
    });
  });

  group('PeriodBarChart widget', () {
    testWidgets('段切换：周恒 7 柱 → 月当月天数 → 年 12 柱（同步 setState 无空白帧）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PeriodBarChart(sessions: _seed())),
          ),
        ),
      );
      PeriodBarChartState state = tester.state<PeriodBarChartState>(
        find.byType(PeriodBarChart),
      );
      expect(state.bars, hasLength(7));

      await tester.tap(find.text('月'));
      await tester.pump(); // 同步重算，一帧内出新柱。
      state = tester.state<PeriodBarChartState>(find.byType(PeriodBarChart));
      final DateTime now = DateTime.now();
      expect(state.bars, hasLength(DateTime(now.year, now.month + 1, 0).day));

      await tester.tap(find.text('年'));
      await tester.pump();
      state = tester.state<PeriodBarChartState>(find.byType(PeriodBarChart));
      expect(state.bars, hasLength(12));
    });

    testWidgets('点柱回调：按 slot 命中，首 / 末柱返回对应区间',
        (WidgetTester tester) async {
      PeriodBar? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PeriodBarChart(
                sessions: _seed(),
                onTapBar: (PeriodBar b) => tapped = b,
              ),
            ),
          ),
        ),
      );
      final PeriodBarChartState state = tester.state<PeriodBarChartState>(
        find.byType(PeriodBarChart),
      );
      final Rect plot = tester.getRect(
        find.byKey(const ValueKey<String>('period-chart-plot')),
      );

      // 周视图 7 槽：首槽中心 → bars[0]。
      await tester.tapAt(Offset(plot.left + plot.width / 14, plot.center.dy));
      await tester.pump();
      expect(tapped, isNotNull);
      expect(tapped!.startDay, state.bars.first.startDay);
      expect(tapped!.seconds, state.bars.first.seconds);

      // 末槽中心 → bars[6]。
      tapped = null;
      await tester.tapAt(Offset(plot.left + plot.width * 13 / 14, plot.center.dy));
      await tester.pump();
      expect(tapped!.endDay, state.bars.last.endDay);
    });
  });

  group('DrillDownPage 下钻明细', () {
    testWidgets('单日柱：会话行（书名降级 bookId）+ 时长，无按天分组头',
        (WidgetTester tester) async {
      final List<ReadingSession> sessions = <ReadingSession>[
        _session(bookId: 'bookA', dayKey: '2026-09-10', duration: 600, hour: 9),
        _session(bookId: 'bookA', dayKey: '2026-09-10', duration: 120, hour: 10),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: DrillDownPage(
            bar: const PeriodBar(
              startDay: '2026-09-10',
              endDay: '2026-09-10',
              label: '10',
              seconds: 720,
              isCurrent: false,
            ),
            sessions: sessions,
          ),
        ),
      );
      await settle(tester, rounds: 10);

      expect(find.text('9月10日'), findsOneWidget); // 标题派生
      expect(find.text('10 分钟'), findsOneWidget);
      expect(find.text('2 分钟'), findsOneWidget);
      expect(find.text('bookA'), findsNWidgets(2)); // 无 repository → 降级
      expect(find.textContaining('· 合计'), findsNothing); // 单日不显分组头
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('月柱：按天分组行 + 分组头合计（9月10日/11日）',
        (WidgetTester tester) async {
      final List<ReadingSession> sessions = <ReadingSession>[
        _session(bookId: 'bookA', dayKey: '2026-09-10', duration: 600),
        _session(bookId: 'bookB', dayKey: '2026-09-11', duration: 300),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: DrillDownPage(
            bar: const PeriodBar(
              startDay: '2026-09-01',
              endDay: '2026-09-30',
              label: '9月',
              seconds: 900,
              isCurrent: true,
            ),
            sessions: sessions,
          ),
        ),
      );
      await settle(tester, rounds: 10);

      expect(find.text('9月'), findsOneWidget); // 标题 = 月
      expect(find.text('9月10日 · 合计 10 分钟'), findsOneWidget);
      expect(find.text('9月11日 · 合计 5 分钟'), findsOneWidget);
      expect(find.text('bookA'), findsOneWidget);
      expect(find.text('bookB'), findsOneWidget);
    });

    testWidgets('空态：该时段无阅读记录', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DrillDownPage(
            bar: const PeriodBar(
              startDay: '2026-09-15',
              endDay: '2026-09-15',
              label: '15',
              seconds: 0,
              isCurrent: true,
            ),
            sessions: const <ReadingSession>[],
          ),
        ),
      );
      await settle(tester, rounds: 10);
      expect(find.text('该时段无阅读记录'), findsOneWidget);
    });

    testWidgets('书名经 repository 解析（loadBooks 异步映射）',
        (WidgetTester tester) async {
      final Directory tempDir =
          Directory.systemTemp.createTempSync('mreader_drill_');
      final AppPaths paths = TestAppPaths(tempDir);
      final LibraryRepository repo = fakeRepository(paths);
      try {
        // 测试体在 FakeAsync 区：真 IO 必须包 runAsync（否则永不完成 → 超时）。
        final ImportResult imported = await tester.runAsync(
          () => repo.importFile(
            bytes: Uint8List.fromList(utf8.encode('甲书正文内容。' * 20)),
            fileName: '甲书.txt',
          ),
        ) as ImportResult;

        await tester.pumpWidget(
          MaterialApp(
            home: DrillDownPage(
              bar: const PeriodBar(
                startDay: '2026-09-10',
                endDay: '2026-09-10',
                label: '10',
                seconds: 600,
                isCurrent: false,
              ),
              sessions: <ReadingSession>[
                _session(
                  bookId: imported.record.bookId,
                  dayKey: '2026-09-10',
                  duration: 600,
                ),
              ],
              repository: repo,
            ),
          ),
        );
        await settle(tester); // initState 的 loadBooks 是真 IO。

        expect(find.text(imported.record.title), findsOneWidget);
        expect(find.text(imported.record.bookId), findsNothing);
      } finally {
        // 防「后台写盘 vs 删目录」竞态，§2.81）。
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
