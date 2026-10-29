// 统计总览卡片（`STAT-03` 首屏三指标）。
//
// 视觉红线（`UI-04` ④）：统计图表 / 卡片 / 列表行**一律不透明**——本卡片是
// 实心 `Material` 圆角容器（形制与 `settings_kit.dart` 的分组卡片一致），
// 绝不套玻璃（玻璃只在导航层与浮层）。
import 'package:flutter/material.dart';

import '../../stats/aggregator.dart';

/// 总览卡片：累计总时长（「X 至今」）+ 活跃天数 + 书籍数。
class OverviewCard extends StatelessWidget {
  /// 创建总览卡片。
  const OverviewCard({
    super.key,
    required this.overview,
    this.sinceDay,
  });

  /// 聚合结果（`STAT-03` 三指标）。
  final OverviewStats overview;

  /// 起始日期（`YYYY-MM-DD`）；`null` = 不限。
  final String? sinceDay;

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
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('累计总时长', style: caption),
            const SizedBox(height: 4),
            // `STAT-03`：总时长显示为「X 至今」。
            Text(
              '${formatReadingDuration(overview.totalSeconds)} 至今',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: _Metric(
                    label: '活跃天数',
                    value: '${overview.activeDays}',
                    unit: '天',
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: '阅读书籍',
                    value: '${overview.bookCount}',
                    unit: '本',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              sinceDay == null ? '统计全部记录' : '起始日期：$sinceDay',
              style: caption,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个指标（大数字 + 单位 + 标签）。
class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '$value $unit',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
