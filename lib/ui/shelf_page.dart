// `LIB-01`：书架首页（替代 M0 验证台的 `HomePage`）。
//
// 空态：引导文案 + 导入按钮。
// 有书：网格展示 [BookCard]（封面缩略图 + 书名 + 作者 + 格式标签）。
// 导入：`FilePicker` 多选 → 逐个调 `importFile`，展示进度 + 失败清单。
// 删除：长按书卡 → 确认对话框 → `deleteBook`（`LIB-06` 二次确认）。
// 点击书卡 → 进入 `ReaderPage`（复用现有阅读页）。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider）。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format/book_registry.dart';
import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../meta/cover_store.dart';
import 'book_card.dart';
import 'reader_page.dart';

/// 书架首页。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key, required this.repository, required this.coverStore});

  /// 书库仓库。
  final LibraryRepository repository;

  /// 封面存储（传给 [BookCard] 加载缩略图）。
  final CoverStore coverStore;

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  List<BookRecord> _books = <BookRecord>[];
  bool _loading = true;
  bool _importing = false;
  List<String> _importErrors = <String>[];

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    final List<BookRecord> books = await widget.repository.loadBooks();
    if (mounted) {
      setState(() {
        _books = books;
        _loading = false;
      });
    }
  }

  Future<void> _pickAndImport() async {
    setState(() {
      _importErrors = <String>[];
    });

    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['epub', 'txt'],
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    if (!mounted) return;
    setState(() => _importing = true);

    int success = 0;
    final List<String> errors = <String>[];
    for (final PlatformFile file in result.files) {
      final Uint8List? bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        errors.add('${file.name}：未能读取文件内容');
        continue;
      }
      try {
        final ImportResult importResult = await widget.repository.importFile(
          bytes: bytes,
          fileName: file.name,
        );
        if (importResult.isNew) {
          success++;
        } else {
          errors.add('${file.name}：已存在（${importResult.record.title}）');
        }
      } catch (e) {
        errors.add('${file.name}：$e');
      }
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _importErrors = errors;
    });

    // 刷新列表
    await _loadBooks();

    // 显示导入结果摘要
    if (mounted && (success > 0 || errors.isNotEmpty)) {
      final String msg = errors.isEmpty
          ? '成功导入 $success 本'
          : '成功 $success 本，失败 ${errors.length} 本';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _deleteBook(BookRecord record) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定删除「${record.title}」？\n删除后书架不再列出，封面文件一并清理。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.repository.deleteBook(record);
      await _loadBooks();
    }
  }

  Future<void> _openBook(BookRecord record) async {
    final Uint8List? bytes = await widget.repository.readBookBytes(record);
    if (bytes == null || bytes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件已丢失：${record.fileName}')),
        );
      }
      return;
    }

    final BookSource source = await openBook(
      fileName: record.fileName,
      bytes: bytes,
    );
    // 触发一次解析（格式错误暴露在首页，RD-05）
    await source.load();

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderPage(source: source)),
    );

    // 阅读页关闭后刷新（lastReadAt 会在 M1-T04 更新）
    await _loadBooks();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('书架')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: <Widget>[
          if (_importing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '导入书籍',
              onPressed: _pickAndImport,
            ),
        ],
      ),
      body: _books.isEmpty ? _buildEmptyState(theme) : _buildBookGrid(theme),
    );
  }

  /// 空态（LIB-01 验收要点 ②）。
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.menu_book_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              '书架空空如也',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '导入 EPUB / TXT 文件开始阅读',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickAndImport,
              icon: const Icon(Icons.folder_open),
              label: const Text('导入书籍'),
            ),
            if (_importErrors.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _buildErrorList(theme),
            ],
          ],
        ),
      ),
    );
  }

  /// 有书：网格展示。
  Widget _buildBookGrid(ThemeData theme) {
    return Column(
      children: <Widget>[
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              childAspectRatio: 0.55,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _books.length,
            itemBuilder: (BuildContext context, int index) {
              final BookRecord record = _books[index];
              return BookCard(
                record: record,
                coverStore: widget.coverStore,
                onTap: () => _openBook(record),
                onLongPress: () => _deleteBook(record),
              );
            },
          ),
        ),
        if (_importErrors.isNotEmpty) _buildErrorList(theme),
      ],
    );
  }

  /// 导入失败清单（LIB-04 验收要点 ②）。
  Widget _buildErrorList(ThemeData theme) {
    return Container(
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '导入失败 ${_importErrors.length} 项',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          ..._importErrors.map((String e) => Text(
                e,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              )),
        ],
      ),
    );
  }
}
