// `NAV-01`：目录底部弹窗——列出全部章节，当前章高亮并自动滚入可见区。
//
// 用**固定行高** + `initialScrollOffset` 让「当前章滚入可见区」可用简单算术定位，
// 不依赖逐项 `GlobalKey`（后者对懒构建的 `ListView.builder` 不可靠）。
import 'package:flutter/material.dart';

import '../model/chapter.dart';

/// 目录底部弹窗。
///
/// 传入 [onSelect] 即把点击的章节索引回传调用方（由调用方负责关闭弹窗并跳章）。
class TocSheet extends StatefulWidget {
  const TocSheet({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.onSelect,
  });

  /// 全部章节（与 `chapters()` 同序）。
  final List<Chapter> chapters;

  /// 当前章索引（用于高亮 + 打开时滚入可见区）。
  final int currentIndex;

  /// 选中回调（回传章节索引）。
  final ValueChanged<int> onSelect;

  @override
  State<TocSheet> createState() => _TocSheetState();
}

class _TocSheetState extends State<TocSheet> {
  /// 固定行高：一行目录项占用的像素高度。
  ///
  /// 取 56（`ListTile` 单行默认高度）以保证内容不被 `itemExtent` 裁掉。
  static const double _itemExtent = 56;

  /// 打开时当前章上方预留的空行数（便于看到上下文）。
  static const int _leadingRows = 1;

  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    // 打开时把当前章滚入可见区；越界会被 ScrollPosition 依据内容尺寸自动 clamp。
    final double offset =
        (widget.currentIndex - _leadingRows) * _itemExtent;
    _controller = ScrollController(initialScrollOffset: offset < 0 ? 0 : offset);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('目录', style: theme.textTheme.titleMedium),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              controller: _controller,
              itemExtent: _itemExtent,
              itemCount: widget.chapters.length,
              itemBuilder: (BuildContext context, int index) {
                final Chapter chapter = widget.chapters[index];
                return ListTile(
                  selected: index == widget.currentIndex,
                  contentPadding: EdgeInsets.only(
                    left: (16 + chapter.level * 16).toDouble(),
                    right: 16,
                  ),
                  title: Text(
                    chapter.title.isNotEmpty
                        ? chapter.title
                        : '第 ${index + 1} 节',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => widget.onSelect(index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
