// 全时段阅读热力图（`STAT-05`：贡献图形态、跨年滚动、点击某天下钻）。
//
// 形制（`UI-04` 红线）：实心 `Material` 圆角卡片（同 `overview_card.dart`），
// 格子 / 月份标签用 [CustomPainter] 自绘（§15.4 不引图表包）。
// 跨年滚动 = 页面级（本卡片输出多年区块的纵向 Column，由统计页 ListView 承载）。
// 分档见 [heatLevel]（`STAT-05` ①：1 分钟进最低档、加深单调）；
// 无记录天 = 档 0 空白格（③，绝不画成 0 值深色）。点击某天把 dayKey 交给
// 调用方弹明细——明细数据与 `STAT-04` 下钻同走 [sessionsInRange]，天然一致。
import 'package:flutter/material.dart';

import '../../stats/aggregator.dart';
import '../../stats/reading_session.dart';

/// 全时段阅读热力图卡片。
class ReadingHeatmap extends StatefulWidget {
  /// 创建热力图卡片。
  const ReadingHeatmap({
    super.key,
    required this.sessions,
    this.sinceDay,
    this.onTapDay,
  });

  /// 会话明细（统计服务内存态，随父级重建即时刷新）。
  final Iterable<ReadingSession> sessions;

  /// 起始日期（`YYYY-MM-DD`）；`null` = 不限。
  final String? sinceDay;

  /// 点击某天 → 调用方弹当天明细（入参 `dayKey`）；`null` = 不可点。
  final ValueChanged<String>? onTapDay;

  @override
  ReadingHeatmapState createState() => ReadingHeatmapState();
}

/// 热力图状态（public：[years] / [levels] / [centerOf] 是测试观测口）。
class ReadingHeatmapState extends State<ReadingHeatmap> {
  /// 展示的年份（连续：最早记录年 ~ 今年；至少含今年）。
  List<int> years = const <int>[];

  /// dayKey → 档位 1..4（有记录的天；无记录的天不在表内 = 空白格）。
  Map<String, int> levels = const <String, int>{};

  /// 各年网格（layout 前即可算，centerOf 依赖）。
  final Map<int, _HeatYearGrid> _grids = <int, _HeatYearGrid>{};

  /// 绘图区宽（各年区块同宽；首个 LayoutBuilder 回填）。
  double? _plotWidth;

  /// 某天格子中心在**其年份区块绘图区**内的偏移（测试命中用；未布局返 null）。
  Offset? centerOf(String dayKey) {
    final double? width = _plotWidth;
    if (width == null) {
      return null;
    }
    final DateTime day = DateTime.parse(dayKey);
    final _HeatYearGrid? grid = _grids[day.year];
    if (grid == null) {
      return null;
    }
    final double pitch = width / grid.weeks;
    return Offset(
      grid.columnOf(day) * pitch + pitch / 2,
      _HeatPainter.labelRow + (day.weekday - 1) * pitch + pitch / 2,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle caption = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final Map<String, int> secondsByDay = daySeconds(
      widget.sessions,
      sinceDay: widget.sinceDay,
    );
    levels = <String, int>{
      for (final MapEntry<String, int> e in secondsByDay.entries)
        e.key: heatLevel(e.value),
    };
    final DateTime now = DateTime.now();
    int firstYear = now.year;
    for (final String day in secondsByDay.keys) {
      final int year = int.parse(day.substring(0, 4));
      if (year < firstYear) {
        firstYear = year;
      }
    }
    years = <int>[for (int y = firstYear; y <= now.year; y++) y];
    _grids
      ..clear()
      ..addEntries(<MapEntry<int, _HeatYearGrid>>[
        for (final int y in years)
          MapEntry<int, _HeatYearGrid>(y, _HeatYearGrid(y)),
      ]);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('阅读热力图', style: caption),
            const SizedBox(height: 4),
            for (int i = 0; i < years.length; i++)
              _YearBlock(
                key: ValueKey<String>('heatmap-year-${years[i]}'),
                grid: _grids[years[i]]!,
                levels: levels,
                isFirst: i == 0,
                onTapDay: widget.onTapDay,
                onLayout: (double w) => _plotWidth ??= w,
              ),
          ],
        ),
      ),
    );
  }
}

/// 一年的网格几何（周一为列首；列 = 含年初/年末的周，恒 53 或 52）。
class _HeatYearGrid {
  _HeatYearGrid(this.year) {
    firstMonday = _mondayOf(DateTime(year, 1, 1));
    final DateTime lastWeek = _mondayOf(DateTime(year, 12, 31));
    weeks = lastWeek.difference(firstMonday).inDays ~/ 7 + 1;
  }

  final int year;
  late final DateTime firstMonday;
  late final int weeks;

  /// 日期所在列（相对 [firstMonday] 的整周偏移）。
  int columnOf(DateTime day) =>
      _mondayOf(day).difference(firstMonday).inDays ~/ 7;

  static DateTime _mondayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day - (d.weekday - 1));
}

/// 单个年份区块（年标题 + 自绘网格）。
class _YearBlock extends StatelessWidget {
  const _YearBlock({
    super.key,
    required this.grid,
    required this.levels,
    required this.isFirst,
    required this.onTapDay,
    required this.onLayout,
  });

  final _HeatYearGrid grid;
  final Map<String, int> levels;
  final bool isFirst;
  final ValueChanged<String>? onTapDay;
  final ValueChanged<double> onLayout;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 4 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${grid.year}年',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double width = constraints.maxWidth;
              onLayout(width);
              final double pitch = width / grid.weeks;
              final double height =
                  _HeatPainter.labelRow + 7 * pitch;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: onTapDay == null
                    ? null
                    : (TapUpDetails d) => _hitDay(width, d),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: CustomPaint(
                    key: ValueKey<String>('heatmap-plot-${grid.year}'),
                    painter: _HeatPainter(
                      grid: grid,
                      levels: levels,
                      today: DateTime.now(),
                      scheme: theme.colorScheme,
                      labelStyle: theme.textTheme.labelSmall!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 按格子命中日期（跳过年外填充与未来日期）。
  void _hitDay(double width, TapUpDetails d) {
    final double pitch = width / grid.weeks;
    final int col = d.localPosition.dx ~/ pitch;
    final int row = (d.localPosition.dy - _HeatPainter.labelRow) ~/ pitch;
    if (col < 0 || col >= grid.weeks || row < 0 || row > 6) {
      return;
    }
    final DateTime day =
        grid.firstMonday.add(Duration(days: col * 7 + row));
    final DateTime today = DateTime.now();
    if (day.year != grid.year ||
        day.isAfter(DateTime(today.year, today.month, today.day))) {
      return;
    }
    onTapDay!(
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}',
    );
  }
}

/// 网格自绘：月份标签行 + 7×weeks 格子。
class _HeatPainter extends CustomPainter {
  _HeatPainter({
    required this.grid,
    required this.levels,
    required this.today,
    required this.scheme,
    required this.labelStyle,
  });

  final _HeatYearGrid grid;
  final Map<String, int> levels;
  final DateTime today;
  final ColorScheme scheme;
  final TextStyle labelStyle;

  /// 顶部月份标签行高（格区从它下面开始）。
  static const double labelRow = 16;

  /// 档 1~4 的主色透明度（浅 → 深）。
  static const List<double> _levelAlpha = <double>[0.35, 0.55, 0.8, 1.0];

  @override
  void paint(Canvas canvas, Size size) {
    final double pitch = size.width / grid.weeks;
    final double cell = (pitch - 2).clamp(4.0, 14.0);
    _drawMonthLabels(canvas, size, pitch);

    final Paint blank = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.3);
    final List<Paint> filled = <Paint>[
      for (final double a in _levelAlpha)
        Paint()..color = scheme.primary.withValues(alpha: a),
    ];

    for (int col = 0; col < grid.weeks; col++) {
      for (int row = 0; row < 7; row++) {
        final DateTime day =
            grid.firstMonday.add(Duration(days: col * 7 + row));
        if (day.year != grid.year) {
          continue; // 年外填充不绘制（既非有记录也非空白格）。
        }
        final String key = _key(day);
        final int level = levels[key] ?? 0;
        final RRect r = RRect.fromRectAndRadius(
          Rect.fromLTWH(col * pitch, labelRow + row * pitch, cell, cell),
          const Radius.circular(2),
        );
        canvas.drawRRect(r, level == 0 ? blank : filled[level - 1]);
      }
    }
  }

  /// 月份标签：标在当月 1 日所在列；同列撞车（相隔恰 4 整周）只标先者。
  void _drawMonthLabels(Canvas canvas, Size size, double pitch) {
    int prevCol = -1;
    for (int m = 1; m <= 12; m++) {
      final DateTime first = DateTime(grid.year, m, 1);
      final int col = grid.columnOf(first);
      if (col == prevCol) {
        continue;
      }
      prevCol = col;
      final TextPainter tp = TextPainter(
        text: TextSpan(text: '$m月', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      double x = col * pitch;
      if (x + tp.width > size.width) {
        x = size.width - tp.width; // 年末标签贴右边不溢出。
      }
      tp.paint(canvas, Offset(x, 0));
    }
  }

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  bool shouldRepaint(_HeatPainter old) =>
      old.grid != grid ||
      old.levels != levels ||
      old.today != today ||
      old.scheme != scheme ||
      old.labelStyle != labelStyle;
}
