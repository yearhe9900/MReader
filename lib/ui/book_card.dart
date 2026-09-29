// `LIB-01`：书架上的单本书卡片。
//
// 视觉（2026-09-28 改版，参考 anx-reader `widgets/bookshelf/book_item.dart`）：
// **不用卡片底板**——封面直接浮在书架渐变背景上，靠 `BoxShadow` 投出层次
// （投影**色源随主题**：浅色照抄 anx 的固定灰、深色用主题阴影色，2026-09-29 拍板
// 「跟主题走」，见 `bookCoverShadowOf`）；
// 封面右下角一枚**格式标签角标**（PRD US-06 / LIB-01 要求，anx 原版没有，
// 拍板「挪到封面上做角标」）；下方信息区为「书名（两行加粗）+ 作者 · 阅读进度」，
// **高度固定 55**（照搬 anx `book_item.dart:89-90`）。
//
// 无封面书 → **默认封面**（`lib/ui/default_book_cover.dart`；2026-09-29 拍板
// 「采用 anx 无封面书籍的默认封面」= 书名哈希取色的浅色底 + 顶部书名 + 底部作者
// + 右下角旋转 15° 书本水印，尺寸按封面宽度成比例）。
//
// 手势：`Card(child: InkWell(...))` 结构**保留**——按压有 ripple 反馈，
// 且能缓解 GridView 滚动/拖拽识别器在手势竞技场吞点（既有实证结论）。
// 只是把 `Card` 本身做成「无色、无 elevation、不裁剪、零外边距」，
// 于是观感上没有卡片，但手势链路不变。
//
// 封面（真封面 / 占位）与角标一律画在**子树内**、且不透明——**不要**用 `Ink` /
// `Ink.image`：它们由上层 `Material` 绘制（`material.dart:621-634` 的 ink 特性先于
// 子树绘制），于是会 ① 逃逸封面外框的 `ClipRRect`（方角）② 被外框投影的**填充**
// 盖住而染色（变暗）。两条均为 2026-09-29 的像素级实证，见 §2.54。
// 代价：`InkWell` 的水波纹/高亮不再压在封面之上，只在透明的信息区可见（anx 同此形态，
// 其封面用 `Container(color:)` / `Container(decoration: image)`）。
//
// 打开准备中（[BookCard.loading]）：整卡蒙层 + 转圈，让用户看得见「在响应」。
//
// 长按抬起反馈（2026-09-29 拍板「采用 anx 的书卡长按动画和效果」）：
// 长按成立即**放大 1.05 + 浮起阴影**（数值出处见 [kBookLiftScale] 等常量的注释），
// 操作单关闭后复位。与 anx 的唯一差别是**不跟手**——anx 的抬起反馈来自
// `flutter_reorderable_grid_view` 的拖拽反馈（会复制一份跟着手指飞），
// 而本项目书架已去拖拽化，只保留「抬起来」这一半视觉。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import '../model/book_meta.dart';
import 'default_book_cover.dart';
import 'shelf_geometry.dart';

/// **浅色主题**下的封面投影（= anx 原样；深色主题见 [bookCoverShadowOf]）。
///
/// anx 出处：`book_item.dart:66-77` 的 `Container.decoration.boxShadow`——
/// `Colors.grey.withAlpha(100)` / spread 5 / blur 10 / offset (0, 2)
/// （anx 只在**非**电子墨水模式下画它，本项目无该开关，浅色恒画）。
///
/// 颜色写 `0x649E9E9E` 字面量：`Colors.grey.withAlpha(100)` 不是 const，
/// 而 `0x64` = 100、`0x9E9E9E` = `Colors.grey` 的 RGB，两者等价（契约测试锁死）。
const BoxShadow kBookCoverShadow = BoxShadow(
  color: Color(0x649E9E9E),
  spreadRadius: 5,
  blurRadius: 10,
  offset: Offset(0, 2),
);

/// 当前主题下的封面投影（**2026-09-29 拍板「跟主题走」**）。
///
/// 浅色 → [kBookCoverShadow]（anx 原样）；深色 → `colorScheme.shadow`
/// （M3 下恒为不透明黑，`color_scheme.dart:1304` 的 `_shadow ?? const Color(0xff000000)`）。
///
/// **为什么深色必须换**（负责人真机截图反馈「阴影太强烈，影响观感」）：anx 的投影是
/// **固定灰**，在深色背景上比背景**亮**——`spread 5 + blur 10` 的一圈灰晕观感就是
/// **一道浅色描边**，相邻书卡的光晕还会互相叠成亮带，于是「投影」变成了「发光」。
///
/// **只换色源**：透明度（anx 的 `withAlpha(100)` = 100/255）与几何
/// （spread 5 / blur 10 / offset (0,2)）**一字不动**——深浅两主题只差一个色源，
/// 既保住浅色下照抄 anx 得到的浮起层次，又让深色回到「靠暗投影分层」。
/// 要再调强度，深浅两档都只动这一个函数。
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
// 长按抬起反馈（2026-09-29 拍板「采用 anx 的长按动画和效果」）
// ---------------------------------------------------------------------------
// anx 的「长按动画」不在它自己的代码里：`book_item.dart:54-56` 的 `onLongPress`
// 是裸的 `showModalBottomSheet`，无任何动画。真身在 `bookshelf_page.dart:388-395`
// ——它用 pub 包 `flutter_reorderable_grid_view` 的 `ReorderableBuilder` **借长按
// 拖拽拿抬起反馈**（`enableDraggable: true`、`longPressDelay: 300ms`、`onDragStarted`
// 里开操作单，而 **`onReorder` 是空实现**：只为反馈、不为重排）。
//
// 本项目书架已去拖拽化（既有结论），不引该包，**照抄该包的数值自己实现**：
//   · 放大 1.05 —— 包内 `reorderable_builder.dart:41`
//     `static const _defaultFeedbackScaleFactor = 1.05;`
//   · 放大时长 150ms —— `reorderable_animation_config.dart:76` 默认
//     `dragFeedbackDuration`，曲线兜底 `Curves.linear`（其 `:120-121`）
//   · 阴影渐入 250ms —— `reorderable_draggable.dart:79` 的
//     `AnimationController(duration: 250ms)`（`forward()` 不传曲线 → 也是 linear）
//   · 阴影四参数 —— `reorderable_draggable.dart:61-71` 的 `_defaultBoxDecoration`
//     （anx 没传 `dragChildBoxDecoration`，故吃这个默认值）
// ---------------------------------------------------------------------------

/// 长按抬起时的放大倍数（出处见上方总注：包内 `reorderable_builder.dart:41`）。
const double kBookLiftScale = 1.05;

/// 放大动画时长（出处见上方总注：包内 `dragFeedbackDuration` 默认 150ms）。
const Duration kBookLiftScaleDuration = Duration(milliseconds: 150);

/// 抬起阴影的渐入时长（出处见上方总注：包内 `AnimationController` 250ms）。
const Duration kBookLiftShadowDuration = Duration(milliseconds: 250);

/// 抬起时浮现的阴影（出处见上方总注：包内 `_defaultBoxDecoration`）。
///
/// 与静止态投影（[bookCoverShadowOf]）**叠加**——anx 也是两层同时在场：其书卡自带
/// 灰投影，拖拽期间再把这一层黑投影画在卡片背景上（包内 `DecorationPosition.background`；
/// **本项目画在封面外框这一层**，落点见下 ⚠️）。
/// `0x33000000` = `Colors.black.withOpacity(0.2)`（`0x33` = 51 = 0.2 × 255）。
///
/// ⚠️ **画在封面外框上、形状取封面圆角**（`_buildCoverSurface` 的 `AnimatedContainer`）：
/// `BoxShadow` 是**填充形状**，若像原先那样画在整张卡外面，而卡片又没有底板
/// （`Card` 透明、信息区透明），看到的会是一张**方角灰板**——既盖住封面圆角、
/// 又让长按时整卡变暗（负责人 2026-09-29 反馈「长按会有灰色背景，且书籍封面没有圆角，
/// 太暗了」）。
///
/// **不随主题**（anx 原样，即包内默认值）：深色主题下这颗黑投影与深色背景几乎同值，
/// 抬起时主要靠**放大 1.05** 传达反馈、阴影那半贡献很小——如实登记，不去补
/// 「深色下也看得见的亮边」：亮边正是 2026-09-29 从常驻投影上**去掉**的东西。
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

  /// 点击（**直接进阅读页**；2026-09-29 改道，原先进详情页）。
  final VoidCallback onTap;

  /// 长按回调（弹底部操作单，`LIB-06`）。
  ///
  /// 类型是**异步**的：返回的 Future 表示「这次长按的交互走完了」——书卡用它当
  /// **抬起反馈的复位时机**（先抬起 → `await` → 再复位）。书架侧传进来的
  /// `ShelfGrid.onBookActions` 在**操作单关闭时**即完成，不等操作单里选定的动作
  /// （开书 / 详情 / 删除）走完；否则用户点「继续阅读」后卡片会一直悬着。
  ///
  /// 为 `null` 时**既不响应长按也不抬起**（书卡只在有回调时才挂长按处理）。
  final Future<void> Function()? onLongPress;

  /// 是否处于「打开准备中」：显示 loading 覆盖层（转圈），提示卡片正在响应。
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

  /// 长按：先抬起，等回调的 Future 完成（书架侧语义 = 操作单已关闭）再复位。
  ///
  /// `finally` 保证「操作单正常关闭」与「回调抛错」两条路上卡片都会落回原位，
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
      // 抬起阴影**不在这里**——它已挪到封面外框内（`_buildCoverSurface`）：
      // 卡片本身没有底板（`Card` 透明、信息区透明），把箱式阴影画在卡片这一层
      // 等于给整卡铺一张**方角灰板**（阴影是填充形状），既盖住封面的圆角、
      // 又让长按时整块变暗。详见 [kBookLiftShadow] 与 `_buildCoverSurface`。
      child: Card(
        // 无卡片观感：透明底 + 零 elevation + 不裁剪（阴影要画到卡片外）+ 零外边距。
        color: Colors.transparent,
        elevation: 0,
        clipBehavior: Clip.none,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: widget.onTap,
          // 按压/长按的**整块高亮**一律关掉：它是 Material 的墨迹特性，自己会填满
          // 整个卡片（方角、含透明的信息区与封面圆角缺口），长按时会一直挂着
          // （`ink_well.dart:1242-1251` 的 `handleLongPress` 不清 pressed 高亮），
          // 观感就是「长按出现一块灰色背景」。**保留**水波纹（`splashColor` 用默认）
          // ——它自行淡出（M3 的 `InkSparkle` 617ms 走完归零），不构成常驻底色。
          highlightColor: Colors.transparent,
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
                      child: _buildCoverSurface(theme),
                    ),
                  ),
                  // 封面与信息区的间距（几何事实源，anx `book_item.dart:88`）。
                  const SizedBox(height: kBookCoverToInfoGap),
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
      ),
    );
  }

  /// 封面外框：**两层投影 + 圆角裁剪**。
  ///
  /// 层次（自外向内）与理由：
  /// ① [kBookLiftShadowKey] 的 `AnimatedContainer`——长按抬起时浮现的暗影，
  ///    形状**取封面的圆角**（不是卡片外框的方角）。原先它包在整张卡外面，
  ///    而卡片没有底板（`Card` 透明、信息区透明），`BoxShadow` 又是**填充形状**
  ///    （`box_decoration.dart:448-470` 的 `_paintBox` 直接 `drawRRect` 填充），
  ///    于是长按时看到的是一张**方角灰板**：既盖住封面圆角、又让整卡变暗。
  /// ② [kBookCoverSurfaceKey] 的 `DecoratedBox`——静止态投影（见 [bookCoverShadowOf]）。
  ///    它画在封面内容**之下**，所以封面内容必须是**子树内**不透明绘制（见 `_buildCover`），
  ///    否则这颗填充阴影会盖在封面上把它染暗。
  /// ③ `ClipRRect`——裁掉封面内容（含本组件自带裁切的 `DefaultBookCover`），
  ///    保证圆角生效；角标放在它**内**，随圆角一起裁。
  Widget _buildCoverSurface(ThemeData theme) {
    return AnimatedContainer(
      key: kBookLiftShadowKey,
      duration: kBookLiftShadowDuration,
      curve: Curves.linear,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kBookCoverRadius),
        // 抬起时新增、与静止投影**叠加**（anx 同为两层：书卡自带灰投影 + 拖拽反馈黑投影）。
        boxShadow: _lifted
            ? const <BoxShadow>[kBookLiftShadow]
            : const <BoxShadow>[],
      ),
      child: DecoratedBox(
        key: kBookCoverSurfaceKey,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kBookCoverRadius),
          // 投影让封面「浮」在渐变背景上——这是本版视觉的主要层次来源。
          // 色源**随主题**（浅色 = anx 原样，深色 = 主题阴影色，见 [bookCoverShadowOf]）。
          boxShadow: <BoxShadow>[bookCoverShadowOf(theme)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kBookCoverRadius),
          // 格式标签角标（PRD US-06 / LIB-01；anx 原版封面无此物）：
          // 放在 ClipRRect **内**，随封面圆角一起裁切，不会溢出圆角。
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _buildCover(theme),
              Positioned(
                right: kBookFormatBadgeInset,
                bottom: kBookFormatBadgeInset,
                child: _FormatTag(format: widget.record.format),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面三态：真封面 / 加载中 / 默认封面。
  ///
  /// ⚠️ **一律画在子树内、且必须是不透明的**——这是 2026-09-29 用像素探针查出来的
  /// 两条铁律（见 §2.54，附实测数值）：
  /// - 用 `Ink` / `Ink.image`（**墨迹特性**，由上层 `Material` 绘制）会 ① **逃逸外层
  ///   `ClipRRect`**（裁切只作用于 Material 的子**树**）⇒ 封面是方角；② 落在封面外框
  ///   投影填充**之下** ⇒ 整张封面被染上一层 α0.39 的色（浅色=灰、深色=黑）⇒「太暗」。
  /// - 若某一态是**透明**的（如只有转圈的加载态），这两层投影会直接透出来变成一块底色。
  /// 代价：`InkWell` 的水波纹不再压在封面之上，只在透明的信息区可见（anx 同此形态）。
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

  /// 占位封面 = **默认封面**（2026-09-29 拍板「采用 anx 无封面书籍的默认封面」）。
  ///
  /// 视觉全部照抄 anx：底色 = `Colors.primaries[书名.hashCode % 18].shade200`
  /// （每本书一张浅色）、顶部书名（3 行）+ 底部作者、右下角旋转 15° 的书本水印、
  /// 尺寸按封面宽度成比例——逐条出处见 `default_book_cover.dart` 的头注。
  /// 原先的「主题色底 + 书名首字」已废弃。底色由 [DefaultBookCover] 自己在子树内画。
  Widget _buildPlaceholder() => DefaultBookCover(
    title: widget.record.title,
    author: widget.record.author,
    radius: kBookCoverRadius,
  );

  /// 信息区：书名（两行）/ 作者 · 进度。
  ///
  /// 高度固定 [kBookInfoHeight]（= 55，照搬 anx `book_item.dart:89-90`），
  /// 于是「一行为书名」与「两行为书名」的卡片等高、网格行距不跳。
  /// 格式标签已挪到封面上（见 [BookCard] 头注的 PRD 取舍）。
  ///
  /// 所有几何数值取自 `shelf_geometry.dart`（事实源，每条附 anx 出处行号）。
  Widget _buildInfo(ThemeData theme) {
    final double? progress = widget.record.readProgress;
    return SizedBox(
      height: kBookInfoHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kBookInfoHorizontalPadding,
        ),
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
