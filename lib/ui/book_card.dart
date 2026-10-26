// `LIB-01`：书架上的单本书卡片。
//
// 布局**对齐 mi_like_ui 首页卡片**（拍板「整体全换 Mi 度量」，2026-10-27）：
// 封面区按 [kBookCoverAspectRatio]（书本比例 2:3，比 Mi 卡的锁屏比例 259:472
// 更矮、更像一本书）随列宽等比定高、圆角 [MiDimens.radiusLg]（20）、封面与信息区
// 间距 8、书名用 `MiTypography.cardTitle` 并左内缩 8.8（与 Mi 首页卡标题同列起排）——几何数值集中在 `shelf_geometry.dart`
//（事实源）。**四项保留**（PRD US-06 / LIB-01，不随 Mi 换掉）：默认封面、
// 真封面（缩略图）、封面右下角格式角标、底部书名·作者·进度。
//
// 以下机制与 anx 时代一致、本次不动：**不用卡片底板**——
// 封面直接浮在书架渐变背景上，靠 `BoxShadow` 投出层次（投影**色源随主题**：
// 浅色 = anx 固定灰、深色 = 主题阴影色，见 `bookCoverShadowOf`）；
// 下方信息区高度固定 [kBookInfoHeight]。
//
// 手势：`Card(child: InkWell(...))` 结构**保留**——按压有 ripple 反馈，且能缓解
// GridView 滚动/拖拽识别器在手势竞技场吞点（既有实证结论）；`Card` 本身做成
// 无色、无 elevation、不裁剪、零外边距 ⇒ 观感无卡片、手势链路不变。
//
// 封面（真封面 / 占位）与角标一律画在**子树内**、且不透明——**不要**用 `Ink` /
// `Ink.image`（墨迹特性由上层 `Material` 先于子树绘制）：会 ① 逃逸封面外框的
// `ClipRRect`（方角）② 被外框投影的**填充**盖住而染色变暗。见 §2.54。
//
// **墨迹（高亮 + 水波纹）整体关闭**（`highlightColor` / `splashColor` 全透明 +
// `NoSplash`）：ink 特性画在子树**之下**，而卡片上只有「信息区」与「封面圆角缺口」
// 是透明的 ⇒ 任何墨迹都只会以「文字与圆角被糊一层灰」的形态露出。见 §2.56。
//
// 打开准备中（[BookCard.loading]）：**封面区**蒙层 + 转圈，让用户看得见「在响应」；
// 蒙层只盖封面、随封面圆角裁切、**不盖信息区**（书名/作者/进度保持可读）。见 §2.55。
//
// 长按抬起反馈：长按成立即**放大 1.05 + 浮起阴影**（数值出处见 [kBookLiftScale]），
// 长按弹框（书架 `MiDialog`）关闭后复位；与 anx 的唯一差别是**不跟手**——anx 的跟手来自拖拽反馈
// （会复制一份跟着手指飞），本项目书架已去拖拽化，只保留「抬起来」这一半视觉。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import '../model/book_meta.dart';
import 'default_book_cover.dart';
// Mi 卡片排版 token（标题样式 / 墨色 / 明暗模式）；几何常量仍走 `shelf_geometry.dart`。
import 'mi_like_ui/mi_like_ui.dart' show MiColors, MiThemeMode, MiTypography;
import 'shelf_geometry.dart';

/// **浅色主题**下的封面投影（= anx 原样；深色见 [bookCoverShadowOf]）：
/// `Colors.grey.withAlpha(100)` / spread 5 / blur 10 / offset (0, 2)。
/// 颜色写 `0x649E9E9E` 字面量（`Colors.grey.withAlpha(100)` 不是 const，
/// `0x64` = 100、`0x9E9E9E` = `Colors.grey` 的 RGB，契约测试锁死等价）。
const BoxShadow kBookCoverShadow = BoxShadow(
  color: Color(0x649E9E9E),
  spreadRadius: 5,
  blurRadius: 10,
  offset: Offset(0, 2),
);

/// 当前主题下的封面投影（拍板「跟主题走」）：浅色 → [kBookCoverShadow]；
/// 深色 → `colorScheme.shadow`（M3 下恒为不透明黑）。
///
/// **为什么深色必须换**：anx 的投影是**固定灰**，深色背景上比背景**亮**，
/// 一圈灰晕观感就是**浅色描边**、相邻卡光晕互相叠成亮带 ⇒「投影」变「发光」。
/// **只换色源**：透明度（100/255）与几何（spread 5 / blur 10 / offset (0,2)）
/// **一字不动**——要调强度，深浅两档都只动这一个函数。
BoxShadow bookCoverShadowOf(ThemeData theme) =>
    theme.brightness == Brightness.dark
    ? BoxShadow(
        color: theme.colorScheme.shadow.withValues(alpha: 100 / 255),
        spreadRadius: 5,
        blurRadius: 10,
        offset: const Offset(0, 2),
      )
    : kBookCoverShadow;

// ---------------------------------------------------------------------------
// 长按抬起反馈（拍板「采用 anx 的长按动画和效果」）
// ---------------------------------------------------------------------------
// anx 的「长按动画」真身是 pub 包 `flutter_reorderable_grid_view` 的
// `ReorderableBuilder`——**借长按拖拽拿抬起反馈**（`onReorder` 是空实现：
// 只为反馈、不为重排）。本项目书架已去拖拽化（既有结论），不引该包，
// **照抄该包的数值自己实现**：
//   · 放大 1.05（包内 `_defaultFeedbackScaleFactor`）；
//   · 放大时长 150ms（默认 `dragFeedbackDuration`，曲线兜底 `Curves.linear`）；
//   · 阴影渐入 250ms（`AnimationController`，`forward()` 不传曲线 → 也是 linear）；
//   · 阴影四参数 = 包内 `_defaultBoxDecoration` 默认值（anx 未传自定义装饰）。
// ---------------------------------------------------------------------------

/// 长按抬起时的放大倍数（出处见上方总注：包内 `reorderable_builder.dart:41`）。
const double kBookLiftScale = 1.05;

/// 放大动画时长（出处见上方总注：包内 `dragFeedbackDuration` 默认 150ms）。
const Duration kBookLiftScaleDuration = Duration(milliseconds: 150);

/// 抬起阴影的渐入时长（出处见上方总注：包内 `AnimationController` 250ms）。
const Duration kBookLiftShadowDuration = Duration(milliseconds: 250);

/// 抬起时浮现的阴影（出处见上方总注），与静止态投影（[bookCoverShadowOf]）
/// **叠加**（anx 也是两层同时在场）。`0x33000000` = `Colors.black.withOpacity(0.2)`。
///
/// ⚠️ **画在封面外框上、形状取封面圆角**（`_buildCoverSurface` 的 `AnimatedContainer`）：
/// `BoxShadow` 是**填充形状**，画在整张卡外面而卡片又没有底板（`Card` 透明、
/// 信息区透明）时，看到的会是一张**方角灰板**——既盖住封面圆角、又让长按时整卡变暗。
///
/// **不随主题**（anx 原样）：深色下这颗黑投影与深色背景几乎同值，抬起时主要靠
/// **放大 1.05** 传达反馈、阴影那半贡献很小——如实登记，**不去补**「深色下也
/// 看得见的亮边」（亮边正是从常驻投影上**去掉**的东西）。
const BoxShadow kBookLiftShadow = BoxShadow(
  color: Color(0x33000000),
  spreadRadius: 5,
  blurRadius: 6,
  offset: Offset(0, 3),
);

/// 封面外框的定位键（契约测试读它的渲染对象取圆角与投影）。
const ValueKey<String> kBookCoverSurfaceKey = ValueKey<String>(
  'book-cover-surface',
);

/// 抬起容器的定位键（契约测试读它的 `AnimatedScale` / `AnimatedContainer`）。
const ValueKey<String> kBookLiftKey = ValueKey<String>('book-card-lift');

/// 抬起阴影容器的定位键。
const ValueKey<String> kBookLiftShadowKey = ValueKey<String>(
  'book-card-lift-shadow',
);

/// 书架上的单本书卡片。
///
/// 封面来源：
/// - [StoredCover]：从 [CoverStore.readThumb] 异步加载（`Image.memory`）；
/// - [NoCover] / [SyntheticCover]：显示**默认封面**（[DefaultBookCover]，视觉照抄
///   anx —— 见该文件的头注）。
///
/// 三条封面路径**都画在子树内且不透明**（理由见 `_buildCover` 头注）。
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

  /// 点击（**直接进阅读页**）。
  final VoidCallback onTap;

  /// 长按回调（弹操作弹框，`LIB-06`）。类型是**异步**的：返回的 Future 表示
  /// 「这次长按的交互走完了」——书卡用它当**抬起反馈的复位时机**（先抬起 →
  /// `await` → 再复位）。书架侧的 `ShelfGrid.onBookActions` 在**弹框关闭时**
  /// 即完成、不等选定动作走完，否则用户点「继续阅读」后卡片会一直悬着。
  /// 为 `null` 时**既不响应长按也不抬起**。
  final Future<void> Function()? onLongPress;

  /// 「打开准备中」：在**封面区**显示蒙层 + 转圈（只盖封面、随封面圆角裁切，
  /// **不盖信息区**，书名/作者/进度照常可读）。
  final bool loading;

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  Uint8List? _thumbBytes;
  bool _loadingThumb = false;

  /// 是否处于「长按抬起」状态（放大 + 浮起阴影，见 [kBookLiftScale]）。
  bool _lifted = false;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  /// 长按：先抬起，等回调的 Future 完成（书架侧语义 = 操作弹框已关闭）再复位。
  ///
  /// `finally` 保证「弹框正常关闭」与「回调抛错」两条路上卡片都会落回原位，
  /// 不会永久悬着。
  Future<void> _handleLongPress() async {
    final Future<void> Function()? onLongPress = widget.onLongPress;
    if (onLongPress == null) return;
    setState(() => _lifted = true);
    try {
      await onLongPress();
    } finally {
      if (mounted) setState(() => _lifted = false);
    }
  }

  Future<void> _loadThumb() async {
    if (widget.record.cover is StoredCover) {
      _loadingThumb = true;
      final Uint8List? bytes = await widget.coverStore.readThumb(
        widget.record.cover,
      );
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
    return AnimatedScale(
      key: kBookLiftKey,
      // 放大倍数 / 时长 / 曲线 = anx 抬起反馈的数值（见 [kBookLiftScale] 上方总注）。
      scale: _lifted ? kBookLiftScale : 1.0,
      duration: kBookLiftScaleDuration,
      curve: Curves.linear,
      // 抬起阴影**不在这里**——已挪到封面外框内（`_buildCoverSurface`）：卡片
      // 本身没有底板（`Card` 透明、信息区透明），把箱式阴影画在卡片这一层等于
      // 给整卡铺一张**方角灰板**（阴影是填充形状），盖住封面圆角、长按时整块变暗。
      // 详见 [kBookLiftShadow]。
      child: Card(
        // 无卡片观感：透明底 + 零 elevation + 不裁剪（阴影要画到卡片外）+ 零外边距。
        color: Colors.transparent,
        elevation: 0,
        clipBehavior: Clip.none,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: widget.onTap,
          // 按压/长按的**一切墨迹**一律关掉（见 §2.56）：
          //
          // ① 按下/长按**整块高亮** → `highlightColor: Colors.transparent`
          //    （墨迹特性填满整个卡片、方角含透明信息区，且长按时**一直挂着**
          //    不清 pressed 高亮）。
          // ② **水波纹** → `splashColor: Colors.transparent` +
          //    `splashFactory: NoSplash.splashFactory`。墨迹层画在**子树之下**、
          //    只会从卡片上仅有的透明区（文字区 + 封面圆角缺口）露出灰底，
          //    所以「灰」永远只以这种形态出现。
          //
          // **反馈仍在**：点书卡 → 阅读页转场；长按 → 放大 1.05 + 浮起阴影
          // （`_lifted`，见 [kBookLiftScale]）。
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          // 异步回调（见 [BookCard.onLongPress]）：这里只点火，Future 由
          // `_handleLongPress` 内部 `await`。
          onLongPress: widget.onLongPress == null ? null : _handleLongPress,
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
                      // 打开准备中的蒙层画在**封面外框内**（`_buildCoverSurface`），
                      // 随封面圆角一起裁、且不盖信息区——见该方法与类头注。
                      child: _buildCoverSurface(theme),
                    ),
                  ),
                  // 封面与信息区的间距（几何事实源，anx `book_item.dart:88`）。
                  const SizedBox(height: kBookCoverToInfoGap),
                  _buildInfo(theme),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面外框：**两层投影 + 圆角裁剪**。层次（自外向内）：
  /// ① [kBookLiftShadowKey] 的 `AnimatedContainer`——长按抬起时浮现的暗影，形状
  ///    **取封面的圆角**（不是卡片外框的方角）。画在整张卡外面时，因卡片没有底板
  ///    （`Card` 透明、信息区透明）而 `BoxShadow` 又是**填充形状**，长按会看到
  ///    一张**方角灰板**：既盖住封面圆角、又让整卡变暗。
  /// ② [kBookCoverSurfaceKey] 的 `DecoratedBox`——静止态投影（见 [bookCoverShadowOf]）。
  ///    画在封面内容**之下**，故封面内容必须是**子树内**不透明绘制（见 `_buildCover`），
  ///    否则这颗填充阴影会盖在封面上把它染暗。
  /// ③ `ClipRRect`——裁掉封面内容（含自带裁切的 `DefaultBookCover`）保证圆角生效；
  ///    角标与加载蒙层都放在它**内**，随圆角一起裁。
  Widget _buildCoverSurface(ThemeData theme) {
    return AnimatedContainer(
      key: kBookLiftShadowKey,
      duration: kBookLiftShadowDuration,
      curve: Curves.linear,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kBookCoverRadius),
        // 抬起时新增、与静止投影**叠加**（anx 同为两层：灰投影 + 拖拽反馈黑投影）。
        boxShadow: _lifted
            ? const <BoxShadow>[kBookLiftShadow]
            : const <BoxShadow>[],
      ),
      child: DecoratedBox(
        key: kBookCoverSurfaceKey,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kBookCoverRadius),
          // 投影让封面「浮」在渐变背景上——本版视觉的主要层次来源；
          // 色源**随主题**（见 [bookCoverShadowOf]）。
          boxShadow: <BoxShadow>[bookCoverShadowOf(theme)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kBookCoverRadius),
          // 格式标签角标（PRD US-06 / LIB-01）与加载蒙层都放在 ClipRRect **内**，
          // 随封面圆角一起裁切，不会溢出圆角。
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _buildCover(theme),
              Positioned(
                right: kBookFormatBadgeInset,
                bottom: kBookFormatBadgeInset,
                child: _FormatTag(format: widget.record.format),
              ),
              // 打开准备中：**只蒙封面**（见类头注「打开准备中」与 [BookCard.loading]）。
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
      ),
    );
  }

  /// 封面三态：真封面 / 加载中 / 默认封面。
  ///
  /// ⚠️ **一律画在子树内、且必须是不透明的**（见 §2.54）：
  /// - 用 `Ink` / `Ink.image`（**墨迹特性**，由上层 `Material` 绘制）会 ① **逃逸外层
  ///   `ClipRRect`**（裁切只作用于 Material 的子**树**）⇒ 封面是方角；② 落在封面
  ///   外框投影填充**之下** ⇒ 整张封面被染色变暗。
  /// - 若某一态是**透明**的（如只有转圈的加载态），两层投影会直接透出来变成一块底色。
  Widget _buildCover(ThemeData theme) {
    final Uint8List? bytes = _thumbBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        // 解码失败退回默认封面（`Image` 会缓存失败态，不会每帧重试）。
        errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
            _buildPlaceholder(),
      );
    }
    if (_loadingThumb) {
      // 不透明底板：见方法头注最后一条。
      return ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return _buildPlaceholder();
  }

  /// 占位封面 = **默认封面**。视觉全部照抄 anx：底色 = 书名哈希取色浅底
  /// （每本书一张）、顶部书名（3 行）+ 底部作者、右下角旋转 15° 的书本水印、
  /// 尺寸按封面宽度成比例——逐条出处见 `default_book_cover.dart` 的头注。
  /// 底色由 [DefaultBookCover] 自己在子树内画。
  Widget _buildPlaceholder() => DefaultBookCover(
    title: widget.record.title,
    author: widget.record.author,
    radius: kBookCoverRadius,
  );

  /// 信息区：书名（单行省略，Mi 卡口径）/ 作者 · 进度。高度固定 [kBookInfoHeight]（= 30），
  /// 于是书名长短不同的卡片都等高、网格行距不跳；格式标签已挪到封面上（见
  /// [BookCard] 头注的保留项清单）。几何数值取自 `shelf_geometry.dart`（事实源）。
  ///
  /// ⚠️ 两行文字的 `height` **显式钉死**（1.0 / 1.18），否则 [kBookInfoHeight] 的
  /// 推导（13.85 + 2 + 13 ≤ 30）会随主题字体的默认行距漂移，信息区溢出或留白。
  Widget _buildInfo(ThemeData theme) {
    final double? progress = widget.record.readProgress;
    // 标题墨色随明暗取框架前景色（与 `MiThemeCard` 同口径）。
    final MiThemeMode mode = theme.brightness == Brightness.light
        ? MiThemeMode.light
        : MiThemeMode.dark;
    return SizedBox(
      height: kBookInfoHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kBookInfoIndent),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.record.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MiTypography.cardTitle.copyWith(
                color: MiColors.foregroundFor(mode),
              ),
            ),
            const SizedBox(height: kBookTitleToAuthorGap),
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
                      height: 1.18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // 阅读进度（保留自 anx-reader 的右下角百分比）；未曾开书则为 null。
                if (progress != null)
                  Text(
                    '${(progress * 100).round()}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      height: 1.18,
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

/// 格式标签（EPUB / TXT）——现作**封面右下角角标**。PRD `US-06` / `LIB-01` 要求
/// 书架展示格式；拍板「挪到封面上做角标」，从而信息区只留书名与作者·进度、
/// 对齐到固定 [kBookInfoHeight]。
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
