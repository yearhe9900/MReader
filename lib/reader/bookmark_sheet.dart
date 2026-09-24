// `TYP-06`：书签底部弹窗——查看全部书签、跳回标记位置、逐条删除、添加当前位置。
//
// 验收映射：①「书签退出重进仍在」——列表由 `BookmarkStore` 按书持久化
// （增删即时落盘，见 `reader_page`）；②「点击跳回该位置」——点行 → [onJump]；
// ③「删除后列表实时更新」——删除**就地**移除本地列表项并 setState，
// 不等任何异步落盘结果。
//
// 行内容 = 添加时的标题快照 + 「第 N 章 · X%」（`chapterIndex` / `chapterPos`
// 是语义坐标，跨设备 / 重排后仍可跳）。
import 'package:flutter/material.dart';

import 'bookmark.dart';

/// 书签底部弹窗。
class BookmarkSheet extends StatefulWidget {
  const BookmarkSheet({
    super.key,
    required this.bookmarks,
    required this.onCreate,
    required this.onDelete,
    required this.onJump,
  });

  /// 当前书签（添加顺序）。
  final List<Bookmark> bookmarks;

  /// 抓「当前位置」创建书签；当前位置不可用（书未就绪）时返回 `null`。
  final Bookmark? Function() onCreate;

  /// 删除回调（持久化由调用方负责）。
  final ValueChanged<Bookmark> onDelete;

  /// 跳转回调（关闭弹窗 + 回跳该位置，由调用方负责）。
  final ValueChanged<Bookmark> onJump;

  @override
  State<BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<BookmarkSheet> {
  /// 弹窗内的书签列表副本：增删**就地**更新（验收③「实时更新」），
  /// 落盘失败也不回滚 UI（与阅读进度同策略：保存失败不影响阅读）。
  late final List<Bookmark> _items = List<Bookmark>.of(widget.bookmarks);

  /// 条目行的展示副标题：「第 N 章 · X%」。
  String _subtitle(Bookmark bookmark) {
    final int percent = (bookmark.chapterPos * 100).floor();
    return '第 ${bookmark.chapterIndex + 1} 章 · $percent%';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: <Widget>[
                Text('书签', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  key: const Key('bookmark-add'),
                  icon: const Icon(Icons.bookmark_add, size: 20),
                  label: const Text('添加当前书签'),
                  onPressed: () {
                    final Bookmark? bookmark = widget.onCreate();
                    if (bookmark != null) {
                      setState(() => _items.add(bookmark));
                    }
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '暂无书签，点「添加当前书签」记录当前位置。',
                style: theme.textTheme.bodyMedium,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _items.length,
                itemBuilder: (BuildContext context, int index) {
                  final Bookmark bookmark = _items[index];
                  return ListTile(
                    key: Key('bookmark-item-$index'),
                    title: Text(
                      bookmark.chapterTitle.isNotEmpty
                          ? bookmark.chapterTitle
                          : '书签 ${index + 1}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_subtitle(bookmark)),
                    trailing: IconButton(
                      key: Key('bookmark-delete-$index'),
                      tooltip: '删除书签',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        widget.onDelete(bookmark);
                        // 验收③：删除后列表**立即**更新，不等落盘。
                        setState(() => _items.removeAt(index));
                      },
                    ),
                    onTap: () => widget.onJump(bookmark),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
