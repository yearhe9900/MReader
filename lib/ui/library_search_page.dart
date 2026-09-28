// 书库搜索页：按**书名 / 作者 / 文件名**过滤本地书架。
//
// 与阅读页内的 `CNT-06`（`SearchSheet`）分工不同：那个是**正文级**全书搜索，
// 走格式层的 `search()`，可能解压、可能进后台 isolate；本页只过滤**元数据**，
// 纯内存、零 IO，因此可以边输入边出结果。
//
// 结果点击后 `Navigator.pop(record)` 把选中的书交回调用方（书架页），
// 由书架页走它自己的开书管道——本页**不复制**开书逻辑。
//
// 视觉红线（`UI-04`）：结果列表用 [OpaqueContentSurface] 承载，玻璃只在顶栏。
import 'package:flutter/material.dart';

import '../library/book_record.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;

/// 书库搜索页（元数据过滤）。
class LibrarySearchPage extends StatefulWidget {
  /// 创建搜索页。
  const LibrarySearchPage({super.key, required this.books});

  /// 待过滤的书目（由书架页传入当前列表，不再读盘）。
  final List<BookRecord> books;

  @override
  State<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

class _LibrarySearchPageState extends State<LibrarySearchPage> {
  final TextEditingController _controller = TextEditingController();

  /// 当前查询串（已 trim、已转小写）。
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 命中判定：书名 / 作者 / 原始文件名任一包含查询串（大小写不敏感）。
  List<BookRecord> get _results {
    if (_query.isEmpty) return const <BookRecord>[];
    return widget.books.where((BookRecord b) {
      final String q = _query;
      return b.title.toLowerCase().contains(q) ||
          b.author.toLowerCase().contains(q) ||
          b.fileName.toLowerCase().contains(q);
    }).toList();
  }

  void _onChanged(String raw) {
    setState(() => _query = raw.trim().toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<BookRecord> results = _results;

    return GlassNavScaffold(
      appBar: GlassTopBar(
        centerTitle: false,
        // 玻璃库没有 Material 祖先，输入类控件需自带一个透明 Material 地基
        // （PRD §11.4）；透明 Material 不绘制底色，玻璃观感不受影响。
        title: Material(
          type: MaterialType.transparency,
          child: TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            decoration: const InputDecoration(
              hintText: '搜索书名、作者或文件名',
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        actions: <Widget>[
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '清除',
              onPressed: () {
                _controller.clear();
                _onChanged('');
              },
            ),
        ],
      ),
      body: OpaqueContentSurface(
        child: _query.isEmpty
            ? _buildHint(theme)
            : (results.isEmpty ? _buildNoMatch(theme) : _buildResults(theme, results)),
      ),
    );
  }

  /// 未输入时的提示。
  Widget _buildHint(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.search,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '输入关键字开始搜索',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 无命中。
  Widget _buildNoMatch(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          '没有匹配「$_query」的书籍',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 结果列表。
  Widget _buildResults(ThemeData theme, List<BookRecord> results) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: kShellBottomInset),
      itemCount: results.length,
      itemBuilder: (BuildContext context, int index) {
        final BookRecord record = results[index];
        return ListTile(
          leading: Icon(
            Icons.menu_book_outlined,
            color: theme.colorScheme.primary,
          ),
          title: Text(
            record.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            record.author.isEmpty ? record.fileName : record.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            record.format.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () => Navigator.of(context).pop<BookRecord>(record),
        );
      },
    );
  }
}
