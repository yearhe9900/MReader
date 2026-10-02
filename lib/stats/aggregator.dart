// M3-T10：统计聚合（`STAT-03` 总览三指标；**纯函数**，无状态无 IO）。
//
// 输入是会话明细（`STAT-02` 落盘模型），输出是页面消费的聚合值——后续
// `M3-T11`（柱状图）/ `T12`（热力图）/ `T13`（排行 + 连续天数）的周期聚合
// 也在本文件落地，共用同一套过滤口径：
//   · **`duration <= 0` 一律跳过**（与 `StatsIndex.of` / 落盘禁写同源，
//     `STAT-03` ②「与全部 duration > 0 记录求和逐秒一致」）；
//   · **起始日期过滤**：`dayKey >= sinceDay`（两者同形 `YYYY-MM-DD`，
//     字典序即日期序；`sinceDay == null` = 不限，统计全部）。
import 'reading_session.dart';

/// 起始日期过滤（`STAT-03` ③）：保留 `dayKey >= sinceDay` 的记录。
///
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
///
/// 取整口径：整秒向下取整到分（不足 1 分显示「不足 1 分钟」，不虚报 0 分钟
/// 也不虚报 1 分钟）。聚合值仍以 [OverviewStats.totalSeconds] 逐秒精确为准。
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
