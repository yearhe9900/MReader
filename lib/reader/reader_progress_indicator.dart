// `TYP-09`：细粒度阅读进度指示——左「当前章标题」+ 右「章内页/本章总页 + 全书百分比」
// + 2px 细进度条。
//
// 格式（§2.72，负责人拍板口径）：左章节标题、右「8/20 22.2%」（章内页 / 本章总页 /
// 全书百分比**一位小数**）+ 2px 进度条。
//
// 独立于 AppBar / 控制条（`TYP-09` 验收①②：全屏时那两者都隐藏，本指示器必须仍在）；
// 由 `ReaderPage` 以**滚动实时采样**的显示值驱动（验收②「进度随滚动实时更新」）。
//
// 页读数在**页表未就绪**（增量分页首帧 / 占位章）时退化为只显示百分比——
// 不显示「0/0」这种没有信息量的读数。
import 'package:flutter/material.dart';

/// 阅读进度指示（细进度条 + 「章节标题 …… 页/总页 百分比」）。
class ReaderProgressIndicator extends StatelessWidget {
  const ReaderProgressIndicator({
    super.key,
    required this.chapterTitle,
    required this.pageNumber,
    required this.pageCount,
    required this.percent,
    this.bottomInset = 0,
  });

  /// 当前章标题（空串 = 未解析出标题 → 只显示右侧读数）。
  final String chapterTitle;

  /// 当前**章内**页码（1 基）；`0` = 页读数不可用。
  final int pageNumber;

  /// 当前**章内**总页数；`0` = 页读数不可用。
  final int pageCount;

  /// 全书进度百分比（0.0 ~ 100.0，一位小数）。
  final double percent;

  /// 底部系统栏让位（`MediaQuery.padding.bottom`）。
  ///
  /// **必须由本组件内部吃掉、而不是外面包 `SafeArea`**：包在外层时 `DecoratedBox`
  /// 底色也被顶上去，系统栏区域会露出正文（「进度条浮在文字上、底下漏一条」）。
  /// 调用方（`ReaderPage`）**必须**把同一个量加进正文的 reserve，否则正文会被多盖住。
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double fraction = (percent / 100).clamp(0.0, 1.0).toDouble();
    final bool hasPage = pageCount > 0 && pageNumber > 0;
    final String tail = hasPage
        ? '$pageNumber/$pageCount ${percent.toStringAsFixed(1)}%'
        : '${percent.toStringAsFixed(1)}%';

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
            // 水平 12：与正文的页边距对齐观感（避免贴边）。
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: <Widget>[
                // 章标题用 `Expanded` + ellipsis：长标题截断，右侧读数**永不被挤走**
                // （读数恒定显示，信息优先级高于标题全貌）。
                Expanded(
                  child: Text(
                    chapterTitle,
                    key: const Key('reader-progress-chapter'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  tail,
                  key: const Key('reader-progress-text'),
                  maxLines: 1,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (bottomInset > 0) SizedBox(height: bottomInset),
        ],
      ),
    );
  }
}
