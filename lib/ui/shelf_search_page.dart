// 书架搜索页（上游「页面推入转场」形态，独立整页搜索）。
//
// 为什么是独立页而不是就地搜索态：就地展开（搜索栏原地变输入框 + 胶囊行淡出）
// 做不到参考素材那种**整屏无 App 级导航**（浮动底栏还在）；上游是「整页推入搜索
// 页」+ 配套转场 [MiCardPageRoute]（新页从右缘滑入带大圆角、下层页左移 0.25 屏宽
// + 压暗）。故书架点搜索栏 → 卡片式推入本页 → 返回圆钮出栈。
//
// 头部几何（上游度量，1220×2656 素材，s = 1220 / 393 = 3.104 px/dp）
//
// | 项目                 | 素材 px        | dp          |
// |----------------------|----------------|-------------|
// | 头部行顶缘           | 162            | 52.2        |
// | 返回圆钮             | ⌀137 / 左 38   | ⌀44.1 / 11.9 |
// | 圆钮 ↔ 输入框        | 34             | 11.0        |
// | 输入框               | 777 × 137      | 250.3 × 44.1（弹性占满） |
// | 输入框 ↔ 搜索钮      | 34             | 11.0        |
// | 搜索钮               | 166 × 127      | 53.5 × 40.9 |
// | 搜索钮右缘距屏幕右缘 | 39             | 12.6 ≈ 11.9 |
//
// 头部顶缘取 `max(52.2, 安全区 + 12)`：52.2 是素材绝对值，叠加安全区是推导
// （素材状态栏约 40dp，头部在其下 ~12dp），保证真机不被状态栏压住。
//
// 正文**不复刻示例内容**（示例是主题卡网格）：这里是宿主自己的搜索结果——
// 与书架同一套书卡网格（[ShelfGrid]），点结果与点书架书卡走同一个开书管道
// （「同一手势一种结果」）。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../library/book_record.dart';
import '../meta/cover_store.dart';
import 'mi_like_ui/mi_like_ui.dart';
import 'shelf_grid.dart';

/// 书架搜索页：推入转场见调用方（[MiCardPageRoute]）。
class ShelfSearchPage extends StatefulWidget {
  const ShelfSearchPage({
    super.key,
    required this.books,
    required this.coverStore,
    required this.themeMode,
    required this.onOpenBook,
    required this.onBookActions,
    this.hint = '搜索书名、作者',
  });

  /// 待搜索的书（书架全量；本页自己按书名 / 作者 / 原始文件名过滤）。
  final List<BookRecord> books;

  /// 封面存储（书卡取缩略图）。
  final CoverStore coverStore;

  /// 明暗配方（调用方按 `GlassScope` 解析一次传进来）。
  final MiThemeMode themeMode;

  /// 点结果（宿主负责关掉本页并开书）。
  final void Function(BookRecord record) onOpenBook;

  /// 长按结果（复用书架的长按弹框 `MiDialog`）。
  final Future<void> Function(BookRecord record) onBookActions;

  /// 输入框占位文案（与书架搜索胶囊同文案）。
  final String hint;

  @override
  State<ShelfSearchPage> createState() => _ShelfSearchPageState();
}

class _ShelfSearchPageState extends State<ShelfSearchPage> {
  // ── 头部几何（上游度量，见文件头）──
  static const double _headerTop = 52.2;
  static const double _headerInset = 11.9;
  static const double _controlGap = 11.0;
  static const double _actionWidth = 53.5;
  static const double _actionHeight = 40.9;
  static const double _controlHeight = MiSearchBarMetrics.barHeight;
  static const double _fieldTextInset = 12.6;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 当前查询串（已 trim、已小写；中文不受影响）。
  String _query = '';

  /// 点结果开书后冻结布局（实测输入法收起动画与开书转场叠加会丢帧）：
  /// 键盘收起动画期间 body 若继续跟随 `viewInsets` 逐帧变高，结果网格会逐帧
  /// 重排——正是阅读页已修过的「外因改排版区」病灶，只是发生在背景上。
  /// **只在点书那一刻冻结**：打字时照常随键盘适配（结果区可见性不变）；
  /// 冻结瞬间 body 撑回全高的那一次重排发生在键盘下方（可见区无跳变）。
  bool _openingFrozen = false;

  @override
  void initState() {
    super.initState();
    // 进页即聚焦（参考素材：推入过程中键盘已经在弹）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 命中的书（书名 / 作者 / 原始文件名任一包含查询串）。
  List<BookRecord> get _results {
    if (_query.isEmpty) return const <BookRecord>[];
    final String q = _query;
    return widget.books
        .where((BookRecord b) =>
            b.title.toLowerCase().contains(q) ||
            b.author.toLowerCase().contains(q) ||
            b.fileName.toLowerCase().contains(q))
        .toList();
  }

  void _onChanged(String raw) {
    final String next = raw.trim().toLowerCase();
    if (next == _query) return;
    setState(() => _query = next);
  }

  @override
  Widget build(BuildContext context) {
    final MiThemeMode mode = widget.themeMode;
    final MiSearchBarPalette palette = MiSearchBarPalette.of(mode);
    final Color ink = MiColors.foregroundFor(mode);
    final double safeTop = MediaQuery.paddingOf(context).top;
    final double headerTop = math.max(_headerTop, safeTop + 12);
    final double inset = MiViewport.of(context).isCompact
        ? _headerInset
        : MiDimens.spaceXxl;

    return Scaffold(
      backgroundColor: MiColors.pageBackgroundFor(mode),
      // 点书开读后冻结键盘响应（[_openingFrozen]）：收起动画不得逐帧改写
      // body 高度——打字期间照常适配，点书那刻起布局稳定。
      resizeToAvoidBottomInset: !_openingFrozen,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(inset, headerTop, inset, 0),
            child: SizedBox(
              height: _controlHeight,
              child: Row(
                children: <Widget>[
                  _BackCircle(ink: ink, palette: palette),
                  const SizedBox(width: _controlGap),
                  Expanded(child: _field(palette)),
                  const SizedBox(width: _controlGap),
                  _searchAction(ink: ink, palette: palette),
                ],
              ),
            ),
          ),
          Expanded(child: _body(palette, inset)),
        ],
      ),
    );
  }

  /// 正文：未输入 → 引导；无命中 → 提示；有结果 → 书卡网格。
  Widget _body(MiSearchBarPalette palette, double inset) {
    if (_query.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.search, size: 56, color: palette.hint),
              const SizedBox(height: 12),
              Text(
                '输入关键字开始搜索',
                style: MiTypography.searchHint.copyWith(color: palette.hint),
              ),
            ],
          ),
        ),
      );
    }
    final List<BookRecord> results = _results;
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '没有匹配「$_query」的书籍',
            textAlign: TextAlign.center,
            style: MiTypography.searchHint.copyWith(color: palette.hint),
          ),
        ),
      );
    }
    return ShelfGrid(
      books: results,
      coverStore: widget.coverStore,
      // 头部行底缘 → 结果列表：上游示例同一档（`MiDimens.spaceXl`）。
      padding: EdgeInsets.fromLTRB(inset, MiDimens.spaceXl, inset, 20),
      onOpenBook: (BookRecord record) {
        // 点结果先收键盘 + 冻结布局（实测输入法收起动画与开书转场叠加会掉帧；
        // 阅读页侧已置 `resizeToAvoidBottomInset: false` 免疫键盘）：本页在点书
        // 这一刻冻结布局（见 [_openingFrozen]），键盘收起不再逐帧重排背景。
        setState(() => _openingFrozen = true);
        FocusScope.of(context).unfocus();
        widget.onOpenBook(record);
      },
      onBookActions: widget.onBookActions,
    );
  }

  /// 输入框：stadium + 半透明表面填充（与静态搜索栏同一档填充色）。
  ///
  /// 参考素材这一页的输入框**没有放大镜**、占位左缩进 12.6dp —— 与首页那条
  /// 搜索栏（放大镜 + 15.4dp 缩进）不是同一个零件，故不复用 [MiSearchBar]。
  Widget _field(MiSearchBarPalette palette) {
    return DecoratedBox(
      key: const ValueKey<String>('shelf-search-field'),
      decoration: BoxDecoration(
        color: palette.fill,
        borderRadius: BorderRadius.circular(_controlHeight / 2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _fieldTextInset),
        child: Center(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            onChanged: _onChanged,
            style: MiTypography.searchHint.copyWith(color: palette.cancelInk),
            cursorColor: palette.caret,
            cursorHeight: MiSearchBarMetrics.caretHeight,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration.collapsed(
              hintText: widget.hint,
              hintStyle: MiTypography.searchHint.copyWith(color: palette.hint),
            ),
          ),
        ),
      ),
    );
  }

  /// 搜索钮：度量 53.5×40.9 的浅灰圆角块 + 纯前景墨色标签。
  Widget _searchAction({
    required Color ink,
    required MiSearchBarPalette palette,
  }) {
    return GestureDetector(
      key: const ValueKey<String>('shelf-search-action'),
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Container(
        width: _actionWidth,
        height: _actionHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.fill,
          borderRadius: BorderRadius.circular(_actionHeight / 2),
        ),
        child: Text(
          '搜索',
          style: MiTypography.searchHint.copyWith(
            color: ink,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 返回圆钮：⌀44.1 圆盘 + 顶栏同一枚箭头墨迹（度量与光学偏置同顶栏回退钮）。
class _BackCircle extends StatelessWidget {
  const _BackCircle({required this.ink, required this.palette});

  final Color ink;
  final MiSearchBarPalette palette;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey<String>('shelf-search-back'),
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(
        width: MiSearchBarMetrics.barHeight,
        height: MiSearchBarMetrics.barHeight,
        decoration: BoxDecoration(
          color: palette.fill,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Transform.translate(
            // 箭头墨心左偏一档（顶栏回退钮同一套光学偏置，度量）。
            offset: const Offset(MiTopBarMetrics.chevronCenterDx, 0),
            child: CustomPaint(
              painter: BackChevronIconPainter(palette.cancelInk),
              size: const Size(
                MiTopBarMetrics.chevronWidth,
                MiTopBarMetrics.chevronHeight,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
