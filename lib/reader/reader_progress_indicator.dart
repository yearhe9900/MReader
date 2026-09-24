// `TYP-09`：细粒度阅读进度指示——「第 N/M 章 · X%」+ 细进度条。
//
// 独立于 AppBar / 控制条（全屏时那两者都隐藏，进度指示必须仍在，验收①②）；
// 由 `ReaderPage` 以**滚动实时采样**的显示值驱动（`TYP-09` 验收②「进度随滚动
// 实时更新」）。
import 'package:flutter/material.dart';

/// 阅读进度指示（细进度条 + 「第 N/M 章 · X%」文本）。
class ReaderProgressIndicator extends StatelessWidget {
  const ReaderProgressIndicator({
    super.key,
    required this.chapterNumber,
    required this.chapterCount,
    required this.percent,
  });

  /// 当前章序号（1 基）。
  final int chapterNumber;

  /// 总章数。
  final int chapterCount;

  /// 全书进度百分比（整数，0~100）。
  final int percent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double fraction = (percent / 100).clamp(0.0, 1.0).toDouble();

    return DecoratedBox(
      key: const Key('reader-progress-indicator'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 细进度条（2px）：全书进度。
          LinearProgressIndicator(
            key: const Key('reader-progress-bar'),
            value: fraction,
            minHeight: 2,
            backgroundColor: theme.dividerColor.withValues(alpha: 0.2),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '第 $chapterNumber/$chapterCount 章 · $percent%',
              key: const Key('reader-progress-text'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
