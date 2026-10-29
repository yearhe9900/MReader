// 柱状图下钻明细页（`STAT-04`：点柱进明细，「下钻求和 = 柱高」）。
//
// 过滤用 [sessionsInRange]——与柱聚合**同一谓词**（区间两端含 + since 过滤 +
// `duration > 0`），求和天然与柱高一致。
// 形制（`UI-04` 红线）：玻璃顶栏（导航层）+ [OpaqueContentSurface] 承载
// 不透明明细行；单日柱 → 会话行，年视图月柱 → 按天分组行。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../library/library_repository.dart';
import '../../stats/aggregator.dart';
import '../../stats/reading_session.dart';
import '../glass_kit.dart';
import '../home_shell.dart' show kShellBottomInset;

/// 柱下钻明细页。
class DrillDownPage extends StatefulWidget {
  /// 创建下钻明细页。
  const DrillDownPage({
    super.key,
    required this.bar,
    required this.sessions,
    this.sinceDay,
    this.repository,
    this.title,
  });

  /// 被点击的柱（区间 + 秒数真值）。
  final PeriodBar bar;

  /// 会话明细（统计服务内存态）。
  final Iterable<ReadingSession> sessions;

  /// 起始日期（`YYYY-MM-DD`）；`null` = 不限。
  final String? sinceDay;

  /// 书库仓库（可选：异步解析书名；`null` 降级显示 bookId）。
  final LibraryRepository? repository;

  /// 顶栏标题（缺省由 [PeriodBar] 派生：单日「M月D日」/ 月「M月」）。
  final String? title;

  @override
  State<DrillDownPage> createState() => _DrillDownPageState();
}

class _DrillDownPageState extends State<DrillDownPage> {
  /// bookId → 书名（载入完成前为空 = 降级显示 bookId）。
  Map<String, String> _titles = const <String, String>{};

  @override
  void initState() {
    super.initState();
    final LibraryRepository? repo = widget.repository;
    if (repo != null) {
      unawaited(_loadTitles(repo));
    }
  }

  Future<void> _loadTitles(LibraryRepository repo) async {
    try {
      final books = await repo.loadBooks();
      if (!mounted) {
        return;
      }
      setState(() {
        _titles = <String, String>{
          for (final b in books) b.bookId: b.title,
        };
      });
    } catch (_) {
      // 书名解析失败：保持降级显示 bookId，不炸页面。
    }
  }

  @override
  Widget build(BuildContext context) {
    final PeriodBar bar = widget.bar;
    // 与柱聚合同一谓词 → 求和恒等于柱高（`STAT-04`）。
    final List<ReadingSession> list = sessionsInRange(
      widget.sessions,
      fromDay: bar.startDay,
      toDay: bar.endDay,
      sinceDay: widget.sinceDay,
    )..sort((ReadingSession a, ReadingSession b) => a.startedAt.compareTo(b.startedAt));

    // 按天分组（已按时间升序 → 天序自然升序）。
    final Map<String, List<ReadingSession>> byDay =
        <String, List<ReadingSession>>{};
    for (final ReadingSession s in list) {
      byDay.putIfAbsent(s.dayKey, () => <ReadingSession>[]).add(s);
    }
    final bool singleDay = bar.startDay == bar.endDay;

    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: Text(widget.title ?? _deriveTitle(bar)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: OpaqueContentSurface(
        child: byDay.isEmpty
            ? const Center(child: Text('该时段无阅读记录'))
            : ListView(
                padding:
                    const EdgeInsets.fromLTRB(20, 16, 20, kShellBottomInset),
                children: <Widget>[
                  for (final MapEntry<String, List<ReadingSession>> e
                      in byDay.entries) ...<Widget>[
                    if (!singleDay) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        '${_dayLabel(e.key)} · 合计 '
                        '${formatReadingDuration(_sum(e.value))}',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    for (final ReadingSession s in e.value)
                      _SessionRow(
                        timeRange:
                            '${_hm(s.startedAt)} – ${_hm(s.endedAt)}',
                        title: _titles[s.bookId] ?? s.bookId,
                        duration: formatReadingDuration(s.duration),
                      ),
                    const Divider(height: 1),
                  ],
                ],
              ),
      ),
    );
  }

  /// 标题派生：单日「9月10日」/ 月柱「9月」。
  static String _deriveTitle(PeriodBar bar) {
    final DateTime d = DateTime.parse(bar.startDay);
    if (bar.startDay == bar.endDay) {
      return '${d.month}月${d.day}日';
    }
    return '${d.month}月';
  }

  /// 「2026-09-10」→「9月10日」。
  static String _dayLabel(String dayKey) {
    final DateTime d = DateTime.parse(dayKey);
    return '${d.month}月${d.day}日';
  }

  /// 「HH:mm」（本地时区）。
  static String _hm(int ms) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  static int _sum(List<ReadingSession> list) {
    int total = 0;
    for (final ReadingSession s in list) {
      total += s.duration;
    }
    return total;
  }
}

/// 一条会话明细行（左：书名 + 时间段；右：时长）。
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.timeRange,
    required this.title,
    required this.duration,
  });

  final String timeRange;
  final String title;
  final String duration;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeRange,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            duration,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
