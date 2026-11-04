// `TYP-09`：细粒度阅读进度指示——左「当前章标题」+ 右「章内页/本章总页 + 全书百分比」。
//
// 格式（§2.72）：左章节标题、右「8/20 22.2%」（章内页 / 本章总页 /
// 全书百分比**一位小数**）。**不画进度条、不画分界线**：进度全靠读数数字
// 表达，读数区与正文用同一块不透明底色连成一片，中间零空隙。
//
// 独立于 AppBar / 控制条（`TYP-09` 验收①②：全屏时那两者都隐藏，本指示器必须仍在）；
// 由 `ReaderPage` 以**滚动实时采样**的显示值驱动（验收②「进度随滚动实时更新」）。
//
// **配色随阅读背景**（`TYP-08`「一体化」）：底色 / 文字一律取调用方
// 传入的**页面色板**（`ReaderPage._pageColor` / `_textColor`），不取主题
// `colorScheme.surface`——否则换了米黄 / 纯黑背景，这条读数还挂着主题底色，
// 与正文割裂。色板成对传入（底色 + 正文色）是契约：单传底色会造出「黑底黑字」。
//
// 页读数在**页表未就绪**（增量分页首帧 / 占位章）时退化为只显示百分比——
// 不显示「0/0」这种没有信息量的读数。
import 'package:flutter/material.dart';

/// 阅读进度指示（「章节标题 …… 页/总页 百分比」一行读数，无进度条 / 分界线）。
class ReaderProgressIndicator extends StatelessWidget {
  const ReaderProgressIndicator({
    super.key,
    required this.chapterTitle,
    required this.pageNumber,
    required this.pageCount,
    required this.percent,
    required this.backgroundColor,
    required this.textColor,
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

  /// 读数条底色 = **页面底色**（`ReaderPage._pageColor`；与正文同源同色）。
  final Color backgroundColor;

  /// 读数条文字色 = **页面正文色**（`ReaderPage._textColor`）。
  final Color textColor;

  /// 底部系统栏让位（`MediaQuery.padding.bottom`）。
  ///
  /// **必须由本组件内部吃掉、而不是外面包 `SafeArea`**：包在外层时 `DecoratedBox`
  /// 底色也被顶上去，系统栏区域会露出正文（「进度条浮在文字上、底下漏一条」）。
  /// 调用方（`ReaderPage`）**必须**把同一个量加进正文的 reserve，否则正文会被多盖住。
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasPage = pageCount > 0 && pageNumber > 0;
    final String tail = hasPage
        ? '$pageNumber/$pageCount ${percent.toStringAsFixed(1)}%'
        : '${percent.toStringAsFixed(1)}%';

    return DecoratedBox(
      key: const Key('reader-progress-indicator'),
      decoration: BoxDecoration(
        // 页面底色原样铺满（不透明）：读数条与正文**同一块底**；⚠️ 不画进度条、
        // 不画任何横向分界线（含 `Border.top`），两者完全连成一片、零空隙。
        color: backgroundColor,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ⚠️ 不画进度条：进度只由右侧读数数字表达（禁 `LinearProgressIndicator`）。
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
                    style: theme.textTheme.bodySmall?.copyWith(color: textColor),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  tail,
                  key: const Key('reader-progress-text'),
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(color: textColor),
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
