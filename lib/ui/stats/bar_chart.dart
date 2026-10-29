// 周期柱状图卡片（`STAT-04`：周 / 月 / 年切换、当前周期高亮、
// 下钻求和 = 柱高、切换无空白帧）。
//
// 形制（`UI-04` 红线）：实心 `Material` 圆角卡片（同 `overview_card.dart`），
// 柱体与轴标签用 [CustomPainter] 自绘（§15.4 不引图表包）。
// 分段状态内含本 widget：切换即同步 `setState` 重算 → 同一帧出新柱，无空白帧。
// 下钻回调把整根柱（区间 + 秒数）交给调用方——明细页用 [sessionsInRange]
// 按**同一区间**过滤，「下钻求和 = 柱高」由共享谓词结构性保证。
import 'package:flutter/material.dart';

import '../../stats/aggregator.dart';
import '../../stats/reading_session.dart';

/// 周期柱状图卡片（周 / 月 / 年三段；数据随父级重建即时刷新）。
class PeriodBarChart extends StatefulWidget {
  /// 创建柱状图卡片。
  const PeriodBarChart({
    super.key,
    required this.sessions,
    this.sinceDay,
    this.onTapBar,
  });

  /// 会话明细（统计服务内存态，随通知重建）。
  final Iterable<ReadingSession> sessions;

  /// 起始日期（`YYYY-MM-DD`）；`null` = 不限。
  final String? sinceDay;

  /// 点击某根柱 → 下钻明细页；`null` = 不可点。
  final ValueChanged<PeriodBar>? onTapBar;

  @override
  PeriodBarChartState createState() => PeriodBarChartState();
}

/// 柱状图状态（public：[bars] 是测试观测口——断言柱数 / 柱高 / 高亮）。
class PeriodBarChartState extends State<PeriodBarChart> {
  StatsPeriod _period = StatsPeriod.week;

  /// 当前分段的柱序列（build 时重算；测试经 `tester.state<>` 读取）。
  List<PeriodBar> bars = const <PeriodBar>[];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle caption = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    bars = aggregateBars(
      widget.sessions,
      period: _period,
      now: DateTime.now(),
      sinceDay: widget.sinceDay,
    );
    int total = 0;
    for (final PeriodBar b in bars) {
      total += b.seconds;
    }
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('阅读时长', style: caption),
                const Spacer(),
                SegmentedButton<StatsPeriod>(
                  segments: const <ButtonSegment<StatsPeriod>>[
                    ButtonSegment<StatsPeriod>(
                      value: StatsPeriod.week,
                      label: Text('周'),
                    ),
                    ButtonSegment<StatsPeriod>(
                      value: StatsPeriod.month,
                      label: Text('月'),
                    ),
                    ButtonSegment<StatsPeriod>(
                      value: StatsPeriod.year,
                      label: Text('年'),
                    ),
                  ],
                  selected: <StatsPeriod>{_period},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  onSelectionChanged: (Set<StatsPeriod> next) {
                    setState(() => _period = next.first);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 区间 + 合计（周 / 月 / 年都由首末柱派生，口径唯一）。
            Text(
              '${bars.first.startDay} 至 ${bars.last.endDay}'
              ' · 合计 ${formatReadingDuration(total)}',
              style: caption,
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: widget.onTapBar == null
                      ? null
                      : (TapUpDetails d) => _hitBar(width, d),
                  child: SizedBox(
                    height: 168,
                    width: width,
                    child: CustomPaint(
                      key: const ValueKey<String>('period-chart-plot'),
                      painter: _BarsPainter(
                        bars: bars,
                        period: _period,
                        scheme: theme.colorScheme,
                        labelStyle: caption,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 按 slot 宽命中柱（整列含标签都可点），越界钳到端柱。
  void _hitBar(double width, TapUpDetails d) {
    if (bars.isEmpty) {
      return;
    }
    final double slot = width / bars.length;
    int i = d.localPosition.dx ~/ slot;
    if (i < 0) {
      i = 0;
    }
    if (i >= bars.length) {
      i = bars.length - 1;
    }
    widget.onTapBar!(bars[i]);
  }
}

/// 柱体 + 轴标签自绘（0 秒不绘制柱体；当前周期柱用主色高亮）。
class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.bars,
    required this.period,
    required this.scheme,
    required this.labelStyle,
  });

  final List<PeriodBar> bars;
  final StatsPeriod period;
  final ColorScheme scheme;
  final TextStyle labelStyle;

  /// 轴标签行高（柱区 = 总高 - 标签行）。
  static const double _labelRow = 18;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) {
      return;
    }
    final double chartH = size.height - _labelRow;
    // 基线（所有柱坐落其上）。
    final Paint base = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, chartH), Offset(size.width, chartH), base);

    final int maxSeconds =
        bars.fold<int>(0, (int m, PeriodBar b) => b.seconds > m ? b.seconds : m);
    final double slot = size.width / bars.length;
    final double barW = (slot * 0.6).clamp(3.0, 36.0);
    final int lastDay = int.tryParse(bars.last.label) ?? -1;

    for (int i = 0; i < bars.length; i++) {
      final PeriodBar bar = bars[i];
      final double x = i * slot + (slot - barW) / 2;
      if (bar.seconds > 0) {
        final double h = (chartH * bar.seconds / maxSeconds).clamp(3.0, chartH);
        final RRect r = RRect.fromRectAndCorners(
          Rect.fromLTWH(x, chartH - h, barW, h),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        );
        canvas.drawRRect(
          r,
          Paint()
            ..color = bar.isCurrent
                ? scheme.primary
                : scheme.primary.withValues(alpha: 0.4),
        );
      }
      if (_showLabel(bar, lastDay)) {
        _drawLabel(canvas, bar.label, i * slot, slot, chartH);
      }
    }
  }

  /// 轴标签：周 / 年全标；月只标 1 / 10 / 20 / 30 / 末日（免拥挤）。
  bool _showLabel(PeriodBar bar, int lastDay) {
    if (period != StatsPeriod.month) {
      return true;
    }
    final int day = int.tryParse(bar.label) ?? 0;
    return day == 1 || day == 10 || day == 20 || day == 30 || day == lastDay;
  }

  void _drawLabel(Canvas canvas, String text, double x, double slot, double chartH) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(x + (slot - tp.width) / 2, chartH + 4),
    );
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.bars != bars ||
      old.period != period ||
      old.scheme != scheme ||
      old.labelStyle != labelStyle;
}
