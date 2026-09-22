// `RD-04` / `NAV-01`：阅读页底部控制条。
//
// 组成：上/下一章 + 全书进度 + 排版设置（复用 [ReaderSettingsBar]）。
// 目录入口**统一放在 AppBar**（`NAV-01` 明确要求「AppBar 目录按钮」），故本控制条
// 不再重复放目录按钮，避免同一页出现两个功能相同的入口。
import 'package:flutter/material.dart';

import '../ui/reader_settings_bar.dart';

/// 阅读页底部控制条。
class ReaderControlBar extends StatelessWidget {
  const ReaderControlBar({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    required this.chapterNumber,
    required this.chapterCount,
    required this.percent,
    required this.canGoPrev,
    required this.canGoNext,
    required this.onPrevChapter,
    required this.onNextChapter,
  });

  /// 当前排版设置（字号 / 行距）。
  final ReaderSettings settings;

  /// 排版设置变更回调。
  final ValueChanged<ReaderSettings> onSettingsChanged;

  /// 当前章序号（1 基）。
  final int chapterNumber;

  /// 总章数。
  final int chapterCount;

  /// 全书进度百分比（整数，0~100）。
  final int percent;

  /// 是否可回上一章（首章时为 false）。
  final bool canGoPrev;

  /// 是否可去下一章（末章时为 false）。
  final bool canGoNext;

  /// 回上一章。
  final VoidCallback onPrevChapter;

  /// 去下一章。
  final VoidCallback onNextChapter;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: 48,
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '上一章',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: canGoPrev ? onPrevChapter : null,
                  ),
                  IconButton(
                    tooltip: '下一章',
                    icon: const Icon(Icons.skip_next),
                    onPressed: canGoNext ? onNextChapter : null,
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(
                      '第 $chapterNumber/$chapterCount 章 · $percent%',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            ReaderSettingsBar(settings: settings, onChanged: onSettingsChanged),
          ],
        ),
      ),
    );
  }
}
