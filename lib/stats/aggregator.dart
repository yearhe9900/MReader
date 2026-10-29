// 统计聚合（`STAT-03` 总览三指标；**纯函数**，无状态无 IO）。
//
// 输入是会话明细（`STAT-02` 落盘模型），输出是页面消费的聚合值——柱状图 /
// 热力图 / 排行 + 连续天数的周期聚合也在本文件落地，共用同一套过滤口径：
// **`duration <= 0` 一律跳过**（与 `StatsIndex.of` / 落盘禁写同源，`STAT-03`
// ②「与全部 duration > 0 记录求和逐秒一致」）；**起始日期过滤** `dayKey >=
// sinceDay`（`YYYY-MM-DD` 字典序即日期序；`null` = 不限）。
import 'reading_session.dart';

/// 起始日期过滤（`STAT-03` ③）：保留 `dayKey >= sinceDay` 的记录；
/// [sinceDay] 为 `null` / 空串时原样返回（不限）。入参不改动。
List<ReadingSession> filterSince(
  Iterable<ReadingSession> sessions,
  String? sinceDay,
) {
  if (sinceDay == null || sinceDay.isEmpty) {
    return sessions is List<ReadingSession>
        ? sessions
        : List<ReadingSession>.of(sessions);
  }
  return List<ReadingSession>.of(
    // `String` 没有 `>=` 运算符（Dart 不从 Comparable 推导运算符）：
    // compareTo >= 0 即字典序「不早于」，与 `YYYY-MM-DD` 的日期序一致。
    sessions.where(
      (ReadingSession s) => s.dayKey.compareTo(sinceDay) >= 0,
    ),
  );
}

/// 总览三指标（`STAT-03` 首屏：累计总时长 / 活跃天数 / 书籍数）。
class OverviewStats {
  const OverviewStats({
    required this.totalSeconds,
    required this.activeDays,
    required this.bookCount,
  });

  /// 空数据（清空后）三指标全 0（`STAT-03` ④）。
  static const OverviewStats empty = OverviewStats(
    totalSeconds: 0,
    activeDays: 0,
    bookCount: 0,
  );

  /// 累计有效阅读秒数（逐秒精确，`STAT-03` ②）。
  final int totalSeconds;

  /// 有记录的天数（`day_key` 去重）。
  final int activeDays;

  /// 有阅读时长的书籍数（`book_id` 去重）。
  final int bookCount;
}

/// 单遍聚合出总览三指标（起始日期过滤后；`duration <= 0` 跳过）。
OverviewStats aggregateOverview(
  Iterable<ReadingSession> sessions, {
  String? sinceDay,
}) {
  int total = 0;
  final Set<String> days = <String>{};
  final Set<String> books = <String>{};
  for (final ReadingSession s in filterSince(sessions, sinceDay)) {
    if (s.duration <= 0) {
      continue;
    }
    total += s.duration;
    days.add(s.dayKey);
    books.add(s.bookId);
  }
  return OverviewStats(
    totalSeconds: total,
    activeDays: days.length,
    bookCount: books.length,
  );
}

/// 人类可读时长（统计页展示用；秒 → 「X 小时 Y 分」/「X 分钟」）。
/// 取整口径：整秒向下取整到分（不足 1 分显示「不足 1 分钟」，不虚报 0 也不
/// 虚报 1 分钟）；聚合值仍以 [OverviewStats.totalSeconds] 逐秒精确为准。
String formatReadingDuration(int seconds) {
  if (seconds <= 0) {
    return '0 分钟';
  }
  final int minutes = seconds ~/ 60;
  if (minutes == 0) {
    return '不足 1 分钟';
  }
  final int hours = minutes ~/ 60;
  final int rest = minutes % 60;
  if (hours == 0) {
    return '$minutes 分钟';
  }
  if (rest == 0) {
    return '$hours 小时';
  }
  return '$hours 小时 $rest 分';
}

// ------------------------------------------------------------------
// 周期柱状图聚合（`STAT-04`）
// ------------------------------------------------------------------

/// 柱状图周期分段（`STAT-04`：周 / 月 / 年三段切换）。
enum StatsPeriod { week, month, year }

/// 周期视图的一根柱（纯数据；`STAT-04`）。
/// [startDay] / [endDay] 为柱覆盖的自然日区间（`YYYY-MM-DD`，含两端）——
/// 下钻明细用 [sessionsInRange] 按同一区间过滤，**「下钻求和 = 柱高」由此保证**。
class PeriodBar {
  const PeriodBar({
    required this.startDay,
    required this.endDay,
    required this.label,
    required this.seconds,
    required this.isCurrent,
  });

  /// 区间首日（`YYYY-MM-DD`）。
  final String startDay;

  /// 区间末日（`YYYY-MM-DD`，含）。
  final String endDay;

  /// 轴标签（周「一…日」/ 月「1…31」/ 年「1月…12月」）。
  final String label;

  /// 区间内有效阅读秒数（`duration > 0` 求和，柱高真值）。
  final int seconds;

  /// 当前自然日（周 / 月视图）或当前月份（年视图）→ 高亮（`STAT-04`）。
  final bool isCurrent;
}

/// 区间内有效会话：`duration > 0` + 起始日期过滤 + `dayKey ∈ [fromDay, toDay]`
/// （两端含）——柱聚合与下钻明细**共用同一谓词**，求和天然与柱高一致。
List<ReadingSession> sessionsInRange(
  Iterable<ReadingSession> sessions, {
  required String fromDay,
  required String toDay,
  String? sinceDay,
}) {
  final List<ReadingSession> out = <ReadingSession>[];
  for (final ReadingSession s in filterSince(sessions, sinceDay)) {
    if (s.duration <= 0) {
      continue;
    }
    if (s.dayKey.compareTo(fromDay) < 0 || s.dayKey.compareTo(toDay) > 0) {
      continue;
    }
    out.add(s);
  }
  return out;
}

/// 聚合出 [period] 视图的柱序列（`STAT-04` ①②；纯函数、单遍）。
/// 周期口径（本地时区自然周期，[now] 定锚）：周 = 本周**周一 ~ 周日**恒 7 根
/// （标签 一…日）；月 = 当月 1 日 ~ 月末（柱数 = 当月天数，标签 日号）；
/// 年 = 当年 1~12 月恒 12 根（标签 `N月`）。
List<PeriodBar> aggregateBars(
  Iterable<ReadingSession> sessions, {
  required StatsPeriod period,
  required DateTime now,
  String? sinceDay,
}) {
  // dayKey → 当日有效秒数（与 overview 同口径：since 过滤 + duration > 0）。
  final Map<String, int> secondsByDay = daySeconds(sessions, sinceDay: sinceDay);
  final String today = _dayKey(now);

  switch (period) {
    case StatsPeriod.week:
      final DateTime monday = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: now.weekday - 1));
      const List<String> labels = <String>['一', '二', '三', '四', '五', '六', '日'];
      final List<PeriodBar> week = <PeriodBar>[];
      for (int i = 0; i < 7; i++) {
        final String day = _dayKey(monday.add(Duration(days: i)));
        week.add(_dayBar(day, labels[i], today, secondsByDay));
      }
      return week;
    case StatsPeriod.month:
      final int days = DateTime(now.year, now.month + 1, 0).day;
      final List<PeriodBar> month = <PeriodBar>[];
      for (int d = 1; d <= days; d++) {
        final String day = _dayKey(DateTime(now.year, now.month, d));
        month.add(_dayBar(day, '$d', today, secondsByDay));
      }
      return month;
    case StatsPeriod.year:
      final String todayMonthPrefix = today.substring(0, 8); // `YYYY-MM-`
      final List<PeriodBar> out = <PeriodBar>[];
      for (int m = 1; m <= 12; m++) {
        final String prefix =
            '${now.year.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-';
        int seconds = 0;
        secondsByDay.forEach((String day, int sec) {
          if (day.startsWith(prefix)) seconds += sec;
        });
        final int lastDay = DateTime(now.year, m + 1, 0).day;
        out.add(PeriodBar(
          startDay: '${prefix}01',
          endDay: '$prefix$lastDay',
          label: '$m月',
          seconds: seconds,
          isCurrent: prefix == todayMonthPrefix,
        ));
      }
      return out;
  }
}

/// 单日柱（周 / 月视图）：区间 = 该自然日自身。
PeriodBar _dayBar(
  String day,
  String label,
  String today,
  Map<String, int> secondsByDay,
) {
  return PeriodBar(
    startDay: day,
    endDay: day,
    label: label,
    seconds: secondsByDay[day] ?? 0,
    isCurrent: day == today,
  );
}

/// 本地自然日键（`YYYY-MM-DD`；与 [sessionDayKey] 同形，直接格式化免经毫秒）。
String _dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

// ------------------------------------------------------------------
// 热力图分档（`STAT-05`）
// ------------------------------------------------------------------

/// dayKey → 当天有效阅读秒数（`duration > 0` 求和 + 起始日期过滤，
/// 与 [aggregateOverview] / [aggregateBars] 同口径；单遍）。
Map<String, int> daySeconds(
  Iterable<ReadingSession> sessions, {
  String? sinceDay,
}) {
  final Map<String, int> out = <String, int>{};
  for (final ReadingSession s in filterSince(sessions, sinceDay)) {
    if (s.duration <= 0) {
      continue;
    }
    out[s.dayKey] = (out[s.dayKey] ?? 0) + s.duration;
  }
  return out;
}

/// 热力图分档阈值（秒）：≤1 分钟 / ≤30 分钟 / ≤1 小时 / >1 小时 = 档 1~4。
/// PRD `STAT-05` ① 只约束「读 1 分钟进最低档、加深单调」未定数值——本阈值为
/// 实现口径（1 分钟恰在档 1 上界）。
const List<int> heatBucketSeconds = <int>[60, 1800, 3600];

/// 当天有效秒数 → 热力档位（`STAT-05`）：0 = 无记录空白格，1..4 由浅到深。
int heatLevel(int seconds) {
  if (seconds <= 0) {
    return 0;
  }
  for (int i = 0; i < heatBucketSeconds.length; i++) {
    if (seconds <= heatBucketSeconds[i]) {
      return i + 1;
    }
  }
  return heatBucketSeconds.length + 1;
}

// ------------------------------------------------------------------
// 按书排行（`STAT-06`）
// ------------------------------------------------------------------

/// 排行周期（`STAT-06`：日 / 周 / 月 / 年 / 全部；窗口 = [now] 定锚的自然周期）。
enum RankPeriod { day, week, month, year, all }

/// 单本书的排行条目（秒数降序）。
class RankEntry {
  const RankEntry({
    required this.bookId,
    required this.seconds,
    required this.percent,
  });

  /// 归属书籍。
  final String bookId;

  /// 周期内有效阅读秒数。
  final int seconds;

  /// 占该周期总时长的百分比（整数；**最大项补余**使各行之和恰为 100，
  /// 满足 `STAT-06` ②「百分比之和为 100%」）。
  final int percent;
}

/// 排行结果（[entries] 按秒数降序；无记录 = [RankResult.empty]）。
class RankResult {
  const RankResult({required this.entries, required this.totalSeconds});

  /// 空态（该周期无阅读记录）。
  static const RankResult empty = RankResult(
    entries: <RankEntry>[],
    totalSeconds: 0,
  );

  /// 排行条目（秒数降序，同秒按 bookId 升序保证稳定）。
  final List<RankEntry> entries;

  /// 周期内总有效秒数（百分比分母）。
  final int totalSeconds;
}

/// 排行周期窗口（含两端 `YYYY-MM-DD`；[RankPeriod.all] 用哨兵区间表「不限」，
/// 起始日期过滤仍由 [sinceDay] 承担）；排行与单书统计**共用**此窗口。
(String, String) rankWindow(RankPeriod period, DateTime now) {
  return switch (period) {
    RankPeriod.day => (_dayKey(now), _dayKey(now)),
    RankPeriod.week => _weekRange(now),
    RankPeriod.month => (
        _dayKey(DateTime(now.year, now.month, 1)),
        _dayKey(DateTime(now.year, now.month + 1, 0)),
      ),
    RankPeriod.year => (
        _dayKey(DateTime(now.year, 1, 1)),
        _dayKey(DateTime(now.year, 12, 31)),
      ),
    RankPeriod.all => ('0001-01-01', '9999-12-31'),
  };
}

/// 按书聚合排行（`STAT-06`；与全局同口径：[sessionsInRange] 过滤 +
/// `duration > 0`，窗口按 [period] 取自然周期）。
RankResult rankByBook(
  Iterable<ReadingSession> sessions, {
  required RankPeriod period,
  required DateTime now,
  String? sinceDay,
}) {
  final (String from, String to) = rankWindow(period, now);
  final List<ReadingSession> list = sessionsInRange(
    sessions,
    fromDay: from,
    toDay: to,
    sinceDay: sinceDay,
  );
  final Map<String, int> byBook = <String, int>{};
  int total = 0;
  for (final ReadingSession s in list) {
    byBook[s.bookId] = (byBook[s.bookId] ?? 0) + s.duration;
    total += s.duration;
  }
  if (total <= 0 || byBook.isEmpty) {
    return RankResult.empty;
  }
  final List<MapEntry<String, int>> sorted = byBook.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
      final int bySeconds = b.value.compareTo(a.value);
      return bySeconds != 0 ? bySeconds : a.key.compareTo(b.key);
    });
  final List<RankEntry> entries = <RankEntry>[];
  int assigned = 0;
  for (final MapEntry<String, int> e in sorted) {
    final int percent = e.value * 100 ~/ total; // 向下取整，余数补最大项。
    entries.add(RankEntry(bookId: e.key, seconds: e.value, percent: percent));
    assigned += percent;
  }
  final int rest = 100 - assigned;
  if (rest != 0) {
    final RankEntry top = entries.first;
    entries[0] = RankEntry(
      bookId: top.bookId,
      seconds: top.seconds,
      percent: top.percent + rest,
    );
  }
  return RankResult(entries: entries, totalSeconds: total);
}

/// 本周窗口（周一 ~ 周日，`YYYY-MM-DD` 含两端）。
(String, String) _weekRange(DateTime now) {
  final DateTime monday = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - 1));
  return (_dayKey(monday), _dayKey(monday.add(const Duration(days: 6))));
}
