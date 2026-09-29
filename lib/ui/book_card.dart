// `LIB-01`：书架上的单本书卡片。
//
// 视觉（2026-09-28 改版，参考 anx-reader `widgets/bookshelf/book_item.dart`）：
// **不用卡片底板**——封面直接浮在书架渐变背景上，靠 `BoxShadow` 投出层次；
// 封面右下角一枚**格式标签角标**（PRD US-06 / LIB-01 要求，anx 原版没有，
// 拍板「挪到封面上做角标」）；下方信息区为「书名（两行加粗）+ 作者 · 阅读进度」，
// **高度固定 55**（照搬 anx `book_item.dart:89-90`）。
//
// 手势：`Card(child: InkWell(...))` 结构**保留**——按压有 ripple 反馈，
// 且能缓解 GridView 滚动/拖拽识别器在手势竞技场吞点（既有实证结论）。
// 只是把 `Card` 本身做成「无色、无 elevation、不裁剪、零外边距」，
// 于是观感上没有卡片，但手势链路不变。
//
// 封面等不透明内容仍用 `Ink.image` / `Ink` 画在 `Card` 的 Material 上——
// ripple 才不会被不透明子组件盖住（信息区透明，封面区被盖属预期）。
//
// 打开准备中（[BookCard.loading]）：整卡蒙层 + 转圈，让用户看得见「在响应」。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import '../model/book_meta.dart';

/// 封面圆角（书卡与占位块共用，保证切换时不跳变）。
const double _kCoverRadius = 6;

/// 书架上的单本书卡片。
///
/// 封面来源：
/// - [StoredCover]：从 [CoverStore.readThumb] 异步加载（`Ink.image` 保 ripple 可见）；
/// - [NoCover] / [SyntheticCover]：显示占位色块 + 书名首字。
class BookCard extends StatefulWidget {
  /// 创建书卡。
  const BookCard({
    super.key,
    required this.record,
    required this.coverStore,
    required this.onTap,
    this.onLongPress,
    this.loading = false,
  });

  /// 书目记录。
  final BookRecord record;

  /// 封面存储（缩略图）。
  final CoverStore coverStore;

  /// 点击（进入详情页）。
  final VoidCallback onTap;

  /// 长按回调（弹底部操作单）。
  ///
  /// 为 `null` 时**不响应长按**——书架网格里由外层拖拽容器统一接管
  /// （`shelf_grid.dart`：长按不动 = 操作单，长按拖动 = 重排 / 建文件夹）。
  /// 若这里也认长按，会与 `LongPressDraggable` 在手势竞技场里互抢。
  final VoidCallback? onLongPress;

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
      // 无卡片观感：透明底 + 零 elevation + 不裁剪（阴影要画到卡片外）+ 零外边距。
      color: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.none,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 封面区：Hero 共享元素过渡（与详情页封面同 tag）。
                Expanded(
                  child: Hero(
                    tag: 'book-cover-${widget.record.bookId}',
                    child: _buildCoverSurface(theme),
                  ),
                ),
                // 封面与信息区的间距：5（照搬 anx `book_item.dart:88`）。
                const SizedBox(height: 5),
                _buildInfo(theme),
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

  /// 封面外框：投影 + 圆角裁剪（投影画在封面之外，故与封面本体分层）。
  Widget _buildCoverSurface(ThemeData theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_kCoverRadius),
        // 投影让封面「浮」在渐变背景上——这是本版视觉的主要层次来源
        // （anx-reader 同一手法：eInk 模式除外，本项目暂无该开关）。
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.28),
            blurRadius: 10,
            spreadRadius: 1,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_kCoverRadius),
        // 格式标签角标（PRD US-06 / LIB-01；anx 原版封面无此物）：
        // 放在 ClipRRect **内**，随封面圆角一起裁切，不会溢出圆角。
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _buildCover(theme),
            Positioned(
              right: 6,
              bottom: 6,
              child: _FormatTag(format: widget.record.format),
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

  /// 信息区：书名（两行）/ 作者 · 进度。
  ///
  /// **高度固定 55**（照搬 anx `book_item.dart:89-90` 的 `SizedBox(height: 55)`），
  /// 于是「一行为书名」与「两行为书名」的卡片等高、网格行距不跳。
  /// 格式标签已挪到封面上（见 [BookCard] 头注的 PRD 取舍）。
  Widget _buildInfo(ThemeData theme) {
    final double? progress = widget.record.readProgress;
    return SizedBox(
      height: 55,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.record.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.record.author.isEmpty
                        ? '未知作者'
                        : widget.record.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // 阅读进度（照搬 anx-reader 的右下角百分比）；未曾开书则为 null。
                if (progress != null)
                  Text(
                    '${(progress * 100).round()}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 格式标签（EPUB / TXT）——现作**封面右下角角标**。
///
/// PRD `US-06` / `LIB-01` 要求书架展示格式；anx-reader 原版卡片没有此物，
/// 拍板「挪到封面上做角标」，从而信息区能与 anx 一样对齐到固定 55px。
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
