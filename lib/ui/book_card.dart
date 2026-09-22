// `LIB-01`：书架上的单本书卡片（封面缩略图 + 书名 + 作者 + 格式标签）。
//
// 手势：`Card(child: InkWell(...))`——按压有 ripple 反馈（缓解 GridView 滚动拖拽
// 识别器在手势竞技场吞点）；封面等不透明内容用 `Ink.image` / `Ink` 画在 Card 的
// Material 上，ripple 才不会被不透明子组件盖住。
// 打开准备中（[BookCard.loading]）：整卡蒙层 + 转圈，让用户看得见「在响应」。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import '../model/book_meta.dart';

/// 书架上的单本书卡片。
///
/// 封面来源：
/// - [StoredCover]：从 [CoverStore.readThumb] 异步加载（`Ink.image` 保 ripple 可见）；
/// - [NoCover] / [SyntheticCover]：显示占位色块 + 书名首字。
class BookCard extends StatefulWidget {
  const BookCard({
    super.key,
    required this.record,
    required this.coverStore,
    required this.onTap,
    required this.onLongPress,
    this.loading = false,
  });

  final BookRecord record;
  final CoverStore coverStore;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 是否处于「打开准备中」：显示 loading 覆盖层（转圈），提示卡片正在响应。
  final bool loading;

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  Uint8List? _thumbBytes;
  bool _loadingThumb = false;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  Future<void> _loadThumb() async {
    if (widget.record.cover is StoredCover) {
      _loadingThumb = true;
      final Uint8List? bytes =
          await widget.coverStore.readThumb(widget.record.cover);
      if (mounted && bytes != null) {
        setState(() {
          _thumbBytes = bytes;
          _loadingThumb = false;
        });
      } else if (mounted) {
        setState(() => _loadingThumb = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 封面区域
                Expanded(child: _buildCover(theme)),
                // 信息区域
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.record.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.record.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _FormatTag(format: widget.record.format),
                    ],
                  ),
                ),
              ],
            ),
            // 打开准备中：整卡蒙层 + 转圈（per-card 可见反馈）。
            if (widget.loading)
              ColoredBox(
                key: const ValueKey<String>('book-opening-overlay'),
                color: theme.colorScheme.surface.withValues(alpha: 0.6),
                child: const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(ThemeData theme) {
    if (_thumbBytes != null) {
      // `Ink.image`（而非 `Image.memory`）：封面画在 Card 的 Material 上，
      // InkWell 的 ripple 才能压在封面之上显示。
      return Ink.image(
        image: MemoryImage(_thumbBytes!),
        fit: BoxFit.cover,
        onImageError: (_, _) {
          if (mounted) setState(() => _thumbBytes = null);
        },
      );
    }
    if (_loadingThumb) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return _buildPlaceholder(theme);
  }

  /// 占位封面：书名首字居中 + 主题色背景（`Ink` 保 ripple 可见）。
  Widget _buildPlaceholder(ThemeData theme) {
    final String initial = widget.record.title.isNotEmpty
        ? widget.record.title.characters.first
        : '?';
    return Ink(
      color: theme.colorScheme.primaryContainer,
      child: Center(
        child: Text(
          initial,
          style: theme.textTheme.headlineLarge?.copyWith(
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// 格式标签（EPUB / TXT）。
class _FormatTag extends StatelessWidget {
  const _FormatTag({required this.format});
  final String format;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        format.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
