// M3-T13：按书排行卡片 + 连续天数卡片 + 单书统计页
// （`STAT-06` / `STAT-07`）。
//
// 形制（`UI-04` 红线）：均为实心 `Material` 圆角卡片 / 不透明正文，
// 绝不进玻璃（玻璃只在导航层与浮层）。
// 口径（`Q13`）：连续天数的归零规则**必须写在界面上**——[StreakCard] 底部
// 有常驻口径说明行。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../library/library_repository.dart';
import '../../stats/aggregator.dart';
import '../../stats/reading_session.dart';
import '../../stats/streak.dart';
import '../glass_kit.dart';
import '../home_shell.dart' show kShellBottomInset;

/// 按书时长排行卡片（`STAT-06`：日 / 周 / 月 / 年 / 全部切换）。
class BookRankCard extends StatefulWidget {
  /// 创建排行卡片。
  const BookRankCard({
    super.key,
    required this.sessions,
    this.sinceDay,
    this.repository,
    this.onTapBook,
  });

  /// 会话明细（统计服务内存态，随父级重建即时刷新）。
  final Iterable<ReadingSession> sessions;

  /// 起始日期（`YYYY-MM-DD`）；`null` = 不限。
  final String? sinceDay;

  /// 书库仓库（可选：解析书名；`null` 降级显示 bookId）。
  final LibraryRepository? repository;

  /// 点击某书 → 单书统计（入参：bookId + 已解析书名 + 当前排行周期）。
  final void Function(String bookId, String title, RankPeriod period)?
      onTapBook;

  @override
  BookRankCardState createState() => BookRankCardState();
}

/// 排行卡状态（public：[result] 是测试观测口）。
class BookRankCardState extends State<BookRankCard> {
  RankPeriod _period = RankPeriod.week;

  /// 当前周期的排行结果（build 时重算；测试经 `tester.state<>` 读取）。
  RankResult result = RankResult.empty;

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
        _titles = <String, String>{for (final b in books) b.bookId: b.title};
      });
    } catch (_) {
      // 书名解析失败：保持降级显示 bookId，不炸页面。
    }
  }

  String _titleOf(String bookId) => _titles[bookId] ?? bookId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle caption = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    result = rankByBook(
      widget.sessions,
      period: _period,
      now: DateTime.now(),
      sinceDay: widget.sinceDay,
    );
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('按书排行', style: caption),
            const SizedBox(height: 8),
            SegmentedButton<RankPeriod>(
              segments: const <ButtonSegment<RankPeriod>>[
                ButtonSegment<RankPeriod>(
                  value: RankPeriod.day,
                  label: Text('日'),
                ),
                ButtonSegment<RankPeriod>(
                  value: RankPeriod.week,
                  label: Text('周'),
                ),
                ButtonSegment<RankPeriod>(
                  value: RankPeriod.month,
                  label: Text('月'),
                ),
                ButtonSegment<RankPeriod>(
                  value: RankPeriod.year,
                  label: Text('年'),
                ),
                ButtonSegment<RankPeriod>(
                  value: RankPeriod.all,
                  label: Text('全部'),
                ),
              ],
              selected: <RankPeriod>{_period},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (Set<RankPeriod> next) {
                setState(() => _period = next.first);
              },
            ),
            const SizedBox(height: 4),
            if (result.entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(child: Text('该周期无阅读记录', style: caption)),
              )
            else
              for (final RankEntry e in result.entries)
                _RankRow(
                  title: _titleOf(e.bookId),
                  duration: formatReadingDuration(e.seconds),
                  percent: '${e.percent}%',
                  onTap: widget.onTapBook == null
                      ? null
                      : () => widget.onTapBook!(
                            e.bookId,
                            _titleOf(e.bookId),
                            _period,
                          ),
                ),
          ],
        ),
      ),
    );
  }
}

/// 排行行（左：书名；右：时长 + 百分比）。
class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.title,
    required this.duration,
    required this.percent,
    this.onTap,
  });

  final String title;
  final String duration;
  final String percent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              duration,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: Text(
                percent,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 连续阅读天数卡片（`STAT-07`；口径常驻界面，`Q13`）。
class StreakCard extends StatelessWidget {
  /// 创建连续天数卡片。
  const StreakCard({super.key, required this.streak});

  /// 统计结果（[computeStreak] 产出）。
  final StreakStats streak;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle caption = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('连续阅读', style: caption),
            const SizedBox(height: 4),
            // `STAT-07`：今天尚未阅读 → 「今日待读」（不清零，`Q13`）。
            Text(
              '累计 ${streak.current} 天'
              '${streak.todayPending ? ' · 今日待读' : ''}',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text('历史最长 ${streak.longest} 天', style: caption),
            const SizedBox(height: 10),
            // `Q13`：归零口径必须写清，否则会被反复提 bug。
            Text(
              '口径：今天未读不清零；连续 2 天未读才重新计算，'
              '断开后历史最长不回退。',
              style: caption,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单书统计页（`STAT-06` 点击进入；窗口与排行同周期）。
class BookStatsPage extends StatelessWidget {
  /// 创建单书统计页。
  const BookStatsPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.sessions,
    required this.period,
    this.sinceDay,
  });

  /// 书籍 id。
  final String bookId;

  /// 展示书名（排行卡解析后的标题）。
  final String title;

  /// 会话明细（统计服务内存态）。
  final Iterable<ReadingSession> sessions;

  /// 排行周期（窗口与排行卡一致）。
  final RankPeriod period;

  /// 起始日期（`YYYY-MM-DD`）；`null` = 不限。
  final String? sinceDay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime now = DateTime.now();
    final (String from, String to) = rankWindow(period, now);
    final List<ReadingSession> list = sessionsInRange(
      sessions,
      fromDay: from,
      toDay: to,
      sinceDay: sinceDay,
    ).where((ReadingSession s) => s.bookId == bookId).toList()
      ..sort(
        (ReadingSession a, ReadingSession b) =>
            a.startedAt.compareTo(b.startedAt),
      );
    int total = 0;
    for (final ReadingSession s in list) {
      total += s.duration;
    }
    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: OpaqueContentSurface(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, kShellBottomInset),
          children: <Widget>[
            Material(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '周期内总时长',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatReadingDuration(total),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (list.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    '该周期无阅读记录',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              for (final ReadingSession s in list)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${_dateLabel(s.dayKey)} ${_hm(s.startedAt)}'
                          ' – ${_hm(s.endedAt)}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        formatReadingDuration(s.duration),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 「2026-09-10」→「9月10日」。
  static String _dateLabel(String dayKey) {
    final DateTime d = DateTime.parse(dayKey);
    return '${d.month}月${d.day}日';
  }

  /// 「HH:mm」（本地时区）。
  static String _hm(int ms) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}
