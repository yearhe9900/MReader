// `M3-T13`：连续阅读天数（`STAT-07` / `Q13`）——**纯 Dart 数据层**，
// 输入会话明细（`STAT-02` 落盘模型），口径与聚合层同源
// （`duration > 0` + 起始日期过滤，天 = `day_key`）。
//
// 归零口径（以 `STAT-07` 验收 ①②③ 定案，比字面条文多容忍 1 天——
// 验收②「周四未读、周五打开仍显示 3 天」要求单日缺口不归零）：
//   · **连续缺失 ≥2 个完整天才归零**（「今天」未过完不计入缺失天）；
//   · 今天尚未阅读**不清零**，界面标注「今日待读」（`Q13`）；
//   · 当前段 = 最后记录日往回的逐日连续段；
//   · 历史最长 = 全部记录内最长连续段（断开后不回退，验收④）。
// 跨 0 点归属天然一致（验收⑤）：天集合直接来自 `STAT-02` 拆天后的 `day_key`。
import 'aggregator.dart';
import 'reading_session.dart';

/// 连续阅读天数统计结果。
class StreakStats {
  const StreakStats({
    required this.current,
    required this.longest,
    required this.todayPending,
  });

  /// 空数据（清空后）。
  static const StreakStats empty = StreakStats(
    current: 0,
    longest: 0,
    todayPending: true,
  );

  /// 当前连续天数（0 = 已归零）。
  final int current;

  /// 历史最长连续天数（断开不回退）。
  final int longest;

  /// 今天还没读（「今日待读」标注；与是否归零无关）。
  final bool todayPending;
}

/// 计算连续阅读天数（[now] 定锚，本地时区自然日）。
StreakStats computeStreak(
  Iterable<ReadingSession> sessions, {
  String? sinceDay,
  required DateTime now,
}) {
  final Map<String, int> secondsByDay = daySeconds(sessions, sinceDay: sinceDay);
  if (secondsByDay.isEmpty) {
    return StreakStats.empty;
  }
  final List<String> days = secondsByDay.keys.toList()..sort();

  // 历史最长：按日序单遍扫描连续段。
  int longest = 0;
  int run = 0;
  String? prev;
  for (final String day in days) {
    if (prev != null && _nextDay(prev) == day) {
      run++;
    } else {
      run = 1;
    }
    if (run > longest) {
      longest = run;
    }
    prev = day;
  }

  // 当前段：最后记录日距今 ≤2 天（昨、前天有记录或今天有）才延续，
  // 否则归零（缺失完整天 ≥2：昨天与前天都无记录；今天不参与判定）。
  final String last = days.last;
  final String today = _dayKeyOf(now);
  final String yesterday = _dayKeyOf(now.subtract(const Duration(days: 1)));
  final String dayBefore = _dayKeyOf(now.subtract(const Duration(days: 2)));
  int current = 0;
  if (last == today || last == yesterday || last == dayBefore) {
    current = 1;
    String cursor = last;
    while (secondsByDay.containsKey(_prevDay(cursor))) {
      cursor = _prevDay(cursor);
      current++;
    }
  }

  return StreakStats(
    current: current,
    longest: longest,
    todayPending: !secondsByDay.containsKey(today),
  );
}

// —— dayKey 工具（`YYYY-MM-DD` 字典序 = 日期序）——

String _dayKeyOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _nextDay(String dayKey) {
  final DateTime d = DateTime.parse(dayKey);
  return _dayKeyOf(DateTime(d.year, d.month, d.day + 1));
}

String _prevDay(String dayKey) {
  final DateTime d = DateTime.parse(dayKey);
  return _dayKeyOf(DateTime(d.year, d.month, d.day - 1));
}
