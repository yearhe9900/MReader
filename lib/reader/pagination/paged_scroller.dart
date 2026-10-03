// 分页滚动容器（T05-c c2）：三章窗口页拼接 + 惯性 + 停手防抖采样 +
// charOffset 一次落位。
//
// 滚动模式（选型 §2.3 ①）：页纵向拼接成连续长卷——布局表（章顶 / 章内页顶 /
// 扁平页序 / 总高）一次算清；滚动只改**可见区间**（前后各扩
// `config.pageHeight` 的 overscan 缓冲），Stack 里只挂可见页。页框 =
// `PageSlice.height`（内容自然高，非 `config.pageHeight`——否则页间留白缝）。
//
// 跨页段间距：切页口径「页内加、跨页不加」（`page_breaker.dart`），滚动拼接
// 必须补——相邻页分属不同段时补 `paragraphSpacing`，否则跨页两段黏连；
// 同段续页不补（正文连续）。章间不加额外间距（标题 widget 自带留白）。
// 标题占位与页同窗口：按**章几何与可见带相交**判定（有页章 = 章顶到下章
// 顶；无页占位章 = headingHeight 块）——标题区进入缓冲带即挂载，无页
// 占位章（页表未就绪）的「载入中」标题也能上屏。
//
// 采样（选型 §2.3 ④「停手 200ms 防抖」）：ScrollUpdate / ScrollEnd 不断重置
// 计时器——滚动期不采，静默 [kScrollSampleDebounce] 后取**视口顶**所在页换算
// 章内字符偏移（复用 `sampleCharOffset`，与保存口径同源；标题区 → 页 0 页首）。
//
// 落位（保证④）：`offsetForCharOffset` = 找章（不在窗口 / 页表未覆盖 →
// `null`，占位语义）→ `findPageByCharOffset` 二分 → 页顶 + 页内比例折算；
// [PagedScrollerState.jumpToCharOffset] 单次 `jumpTo`（clamp 上界）——**一次
// 落位、无校正环**（≤8 帧校正环 / `detectChapterAt` / 章高模型随 c3 退役）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../selection_overlay.dart';
import 'page_breaker.dart';
import 'page_paginator.dart';
import 'page_renderer.dart';
import 'progress_pages.dart';

/// 停手防抖采样延迟（选型 §2.3 ④：停手 200ms 后采样）。
const Duration kScrollSampleDebounce = Duration(milliseconds: 200);

/// 一章的分页视图（滚动容器的输入单元）。
class PagedChapterView {
  const PagedChapterView({
    required this.href,
    required this.paragraphs,
    required this.lines,
    required this.pages,
    this.headingHeight = 0,
    this.heading,
  });

  /// 章标识（采样 / 落位按它定位章）。
  final String href;

  /// 章节原文段落（与测量输入同一列表；`PageContent` 渲染用）。
  final List<String> paragraphs;

  /// 章行表（与 [pages] 同一快照；`PageContent` 平移量与渲染同源）。
  final List<MeasuredLine> lines;

  /// 章页表（`IncrementalPaginator` / `PaginationCache` 产物，只读）。
  final List<PageSlice> pages;

  /// 章标题占高（与页 0 预算裁剪同一值；布局 = 标题占位 + 页序拼接）。
  final double headingHeight;

  /// 章标题 widget；null = 不渲染（[headingHeight] 空间仍占——高度与分页
  /// 预算同源，渲染与否不改布局）。
  final Widget? heading;
}

/// 滚动采样（停手防抖后上抛；保存进度用）。
class ScrollSample {
  const ScrollSample({
    required this.href,
    required this.charOffset,
    required this.pageIndex,
    required this.withinPageFraction,
  });

  /// 章标识。
  final String href;

  /// 视口顶折算的章内字符偏移（`sampleCharOffset` 口径）。
  final int charOffset;

  /// 视口顶所在章内页码。
  final int pageIndex;

  /// 页内比例（几何：视口顶在页内的位置；换算字符时按字符均匀折算）。
  final double withinPageFraction;

  @override
  String toString() => 'ScrollSample($href, #$pageIndex, char=$charOffset, '
      'f=${withinPageFraction.toStringAsFixed(3)})';
}

/// 扁平页条目（可见区间二分的单元）。
class FlatPage {
  const FlatPage({
    required this.chapterIndex,
    required this.pageIndex,
    required this.top,
    required this.height,
  });

  /// 所属章下标（`chapters` 列表序）。
  final int chapterIndex;

  /// 章内页码。
  final int pageIndex;

  /// 页顶绝对偏移（卷轴坐标）。
  final double top;

  /// 页框高（`PageSlice.height` 内容自然高）。
  final double height;

  double get bottom => top + height;
}

/// 可见扁平页区间（[first] > [last] = 空；已含 overscan 缓冲）。
class VisibleRange {
  const VisibleRange(this.first, this.last);

  /// 首个可见扁平页下标。
  final int first;

  /// 末个可见扁平页下标（含）。
  final int last;

  bool get isEmpty => first > last;

  @override
  bool operator ==(Object other) =>
      other is VisibleRange && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => 'VisibleRange($first..$last)';
}

/// 滚动布局表（纯函数产物 + 查询；`build` 一次算清，滚动只做二分）。
class PagedLayout {
  PagedLayout._({
    required this.chapterTops,
    required this.pageTops,
    required this.flatPages,
    required this.chapterFlatStart,
    required this.chapterFlatEnd,
    required this.totalHeight,
  }) : _flatTops = List<double>.unmodifiable(
          List<double>.generate(
            flatPages.length,
            (int i) => flatPages[i].top,
            growable: false,
          ),
        );

  /// 各章章顶（卷轴坐标；章 0 恒 0）。
  final List<double> chapterTops;

  /// 章内页顶（绝对坐标；`pageTops[c][p]` = 章 c 第 p 页页顶）。
  final List<List<double>> pageTops;

  /// 扁平页序（章序 × 页序；顶严格不减）。
  final List<FlatPage> flatPages;

  /// 章 c 的扁平页区间 `[chapterFlatStart[c], chapterFlatEnd[c]]`。
  final List<int> chapterFlatStart;
  final List<int> chapterFlatEnd;

  /// 卷轴总高（末章末页底）。
  final double totalHeight;

  /// [flatPages] 页顶的平行表（二分用）。
  final List<double> _flatTops;

  /// 布局表：按章序拼接「标题占位 + 页序」，跨页段间距按相邻页段落归属补齐。
  static PagedLayout build(
    List<PagedChapterView> chapters, {
    required double paragraphSpacing,
  }) {
    final List<double> chapterTops = <double>[];
    final List<List<double>> pageTops = <List<double>>[];
    final List<FlatPage> flat = <FlatPage>[];
    final List<int> flatStart = <int>[];
    final List<int> flatEnd = <int>[];
    double top = 0;

    for (int c = 0; c < chapters.length; c++) {
      final PagedChapterView chapter = chapters[c];
      chapterTops.add(top);
      flatStart.add(flat.length);

      double pageTop = top + chapter.headingHeight;
      final List<double> tops = <double>[];
      for (int p = 0; p < chapter.pages.length; p++) {
        final PageSlice page = chapter.pages[p];
        tops.add(pageTop);
        flat.add(FlatPage(
          chapterIndex: c,
          pageIndex: p,
          top: pageTop,
          height: page.height,
        ));
        pageTop += page.height;
        if (p + 1 < chapter.pages.length) {
          pageTop += _crossPageGap(chapter, page, paragraphSpacing);
        }
      }

      pageTops.add(tops);
      flatEnd.add(flat.length - 1);
      top = pageTop;
    }

    return PagedLayout._(
      chapterTops: chapterTops,
      pageTops: pageTops,
      flatPages: flat,
      chapterFlatStart: flatStart,
      chapterFlatEnd: flatEnd,
      totalHeight: top,
    );
  }

  /// 相邻页跨页段间距：切页不加、滚动补——[page] 与下一页分属不同段时补
  /// [paragraphSpacing]（同段续页 = 0）。行表越界 / 空页防御性 0。
  static double _crossPageGap(
    PagedChapterView chapter,
    PageSlice page,
    double paragraphSpacing,
  ) {
    final int lastLine = page.firstLine + page.lineCount - 1;
    final int nextFirst = chapter.pages[page.index + 1].firstLine;
    if (page.lineCount == 0 ||
        lastLine >= chapter.lines.length ||
        nextFirst >= chapter.lines.length) {
      return 0;
    }
    return chapter.lines[lastLine].paragraphIndex ==
            chapter.lines[nextFirst].paragraphIndex
        ? 0
        : paragraphSpacing;
  }

  /// 最后一个 `top <= y` 的下标（无则 −1）。
  static int _lastAtOrBefore(List<double> tops, double y) {
    int lo = 0;
    int hi = tops.length - 1;
    int ans = -1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      if (tops[mid] <= y) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 最后一个章顶 ≤ [y] 的章下标（无则 −1）。
  int chapterAtOrBefore(double y) => _lastAtOrBefore(chapterTops, y);

  /// 章 [c] 内最后一个页顶 ≤ [y] 的页下标（无则 −1；标题区返回 −1）。
  int pageAtOrBefore(int c, double y) => _lastAtOrBefore(pageTops[c], y);

  /// 最后一个页顶 ≤ [y] 的扁平页下标（无则 −1）。
  int flatAtOrBefore(double y) => _lastAtOrBefore(_flatTops, y);

  /// 可见扁平页区间：`[offset − overscan, offset + 视口高 + overscan]` 相交区。
  /// 首 = 首个底 > 下界者（页顶 ≤ 下界但已整体越过的跳过）；末 = 末个顶 ≤
  /// 上界者；无命中返回空区间（`first > last`）。
  VisibleRange visibleRange(
    double offset,
    double viewportHeight,
    double overscan,
  ) {
    if (flatPages.isEmpty) return const VisibleRange(0, -1);
    final double lo = offset - overscan;
    final double hi = offset + viewportHeight + overscan;
    int first = flatAtOrBefore(lo);
    if (first < 0) {
      first = 0;
    } else if (flatPages[first].bottom <= lo) {
      first += 1;
    }
    final int last = flatAtOrBefore(hi);
    if (last < first) return VisibleRange(first, first - 1);
    return VisibleRange(first, last);
  }
}

/// 分页滚动容器：页纵向拼接的连续滚动视图（滚动模式的唯一上屏通道）。
class PagedScroller extends StatefulWidget {
  const PagedScroller({
    super.key,
    required this.chapters,
    required this.config,
    required this.resolveImage,
    this.controller,
    this.onSampled,
    this.onLinkTap,
    this.highlightQuery,
    this.selection,
    this.speaking,
    this.sampleDebounce = kScrollSampleDebounce,
  });

  /// 窗口内的章视图（c3 传 ±1 章窗口；列表须换新引用以触发布局重算）。
  final List<PagedChapterView> chapters;

  /// 排版参数（页宽 / 页高 / 样式 / 段间距 / 缩放，与测量同一实例）。
  final PaginationConfig config;

  /// 图片加载回调（透传 `PageContent` → `InlineParagraph`）。
  final Future<Uint8List?> Function(String href) resolveImage;

  /// 外部滚动控制器（c3 持有以便同页其它入口共用；null = 自建自管）。
  final ScrollController? controller;

  /// 停手防抖采样回调；null = 不采样（不建计时器）。
  final void Function(ScrollSample sample)? onSampled;

  /// 链接点击回调；null = 链接仅下划线不可点。
  final void Function(String href)? onLinkTap;

  /// 搜索高亮关键词；null / 空 = 不高亮。
  final String? highlightQuery;

  /// 划词选区（`AI-02`/`AI-03`）：只对 [ParaSelection.chapterHref] 命中的章
  /// 生效（跨章滚动时其它章不受影响）；null = 无选区。
  final ParaSelection? selection;

  /// 当前朗读段（`TTS-02` 高亮跟随）：按 href 过滤后把段下标传给
  /// [PageContent]；null = 未在朗读。
  final ({String href, int paraIndex})? speaking;

  /// 采样防抖时长（默认 [kScrollSampleDebounce]；测试可注入短值）。
  final Duration sampleDebounce;

  @override
  PagedScrollerState createState() => PagedScrollerState();
}

/// [PagedScroller] 状态（public：测试经 `tester.state<PagedScrollerState>()`
/// 直取采样 / 落位口）。
///
/// 调用约束：[jumpToCharOffset] 须在**首帧后**的事件 / 帧回调中调用
/// （不在 build / didUpdateWidget 内——落位会同步 setState）。
class PagedScrollerState extends State<PagedScroller> {
  late ScrollController _scroll;
  bool _ownsScroll = false;
  late PagedLayout _layout;
  VisibleRange _visible = const VisibleRange(0, -1);
  double? _viewportHeight;
  Timer? _sampleTimer;

  /// didUpdateWidget 内的布局重算走 `jumpTo` 收缩偏移——通知回调须跳过
  /// setState（build 期禁 setState；随后的自然 build 会用新偏移重算区间）。
  bool _suspendScrollHandling = false;

  @override
  void initState() {
    super.initState();
    _attachController();
    _layout = PagedLayout.build(
      widget.chapters,
      paragraphSpacing: widget.config.paragraphSpacing,
    );
  }

  void _attachController() {
    if (widget.controller != null) {
      _scroll = widget.controller!;
      _ownsScroll = false;
    } else {
      _scroll = ScrollController();
      _ownsScroll = true;
    }
  }

  @override
  void didUpdateWidget(PagedScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (_ownsScroll) _scroll.dispose();
      _attachController();
    }
    if (oldWidget.chapters != widget.chapters ||
        oldWidget.config != widget.config) {
      _layout = PagedLayout.build(
        widget.chapters,
        paragraphSpacing: widget.config.paragraphSpacing,
      );
      // 内容变矮后偏移越界：收进上界（物理层也会自校正，这里显式收保证
      // 本帧 build 的可见区间即正确）。
      if (_scroll.hasClients && offset > maxScrollExtent) {
        _suspendScrollHandling = true;
        _scroll.jumpTo(maxScrollExtent);
        _suspendScrollHandling = false;
      }
    }
  }

  @override
  void dispose() {
    _sampleTimer?.cancel();
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  /// 当前滚动偏移（未附着时回落控制器初始偏移）。
  double get offset {
    if (_scroll.hasClients) return _scroll.position.pixels;
    return _scroll.initialScrollOffset;
  }

  /// 可滚上界（`总高 − 视口高`；视口未布局时按 0 视口）。
  double get maxScrollExtent {
    final double vh = _viewportHeight ?? 0;
    return (_layout.totalHeight - vh).clamp(0.0, double.infinity).toDouble();
  }

  /// 布局表（测试观察窗口行为用）。
  PagedLayout get layout => _layout;

  /// 滚动控制器（c3 若需直读像素；落位走 [jumpToCharOffset]）。
  ScrollController get scrollController => _scroll;

  /// 立即采样：视口顶所在章 / 页 → 章内字符偏移（防抖到点也走这里）。
  /// 视口顶落在标题区 → 页 0 页首；空章列表 / 空页表 → null。
  ScrollSample? sampleNow() {
    if (widget.chapters.isEmpty) return null;
    final double y = offset;
    int c = _layout.chapterAtOrBefore(y);
    if (c < 0) c = 0;
    final PagedChapterView chapter = widget.chapters[c];
    if (chapter.pages.isEmpty) return null;

    int p = _layout.pageAtOrBefore(c, y);
    double fraction = 0;
    if (p < 0) {
      p = 0; // 标题区：页 0 页首
    } else {
      final double h = chapter.pages[p].height;
      if (h > 0) {
        fraction = ((y - _layout.pageTops[c][p]) / h).clamp(0.0, 1.0).toDouble();
      }
    }
    return ScrollSample(
      href: chapter.href,
      charOffset: sampleCharOffset(
        pages: chapter.pages,
        pageIndex: p,
        withinPageFraction: fraction,
      ),
      pageIndex: p,
      withinPageFraction: fraction,
    );
  }

  /// 字符偏移 → 滚动偏移（页顶 + 页内比例线性折算；静态版）。
  /// 章不在 [chapters] / 页表未覆盖（`charOffset >` 末页页尾）→ null（占位
  /// 语义）。c3 跳转流用它对**预计算新布局**先算偏移再 jump（单帧无闪）。
  static double? offsetFor(
    PagedLayout layout,
    List<PagedChapterView> chapters,
    String href,
    int charOffset,
  ) {
    final int c = chapters.indexWhere((PagedChapterView v) => v.href == href);
    if (c < 0) return null;
    final List<PageSlice> pages = chapters[c].pages;
    if (pages.isEmpty) return null;
    if (charOffset > pages.last.end) return null;
    final int p = PageBreaker.findPageByCharOffset(pages, charOffset);
    if (p < 0) return null;
    final PageSlice page = pages[p];
    final int span = page.end - page.start;
    final double fraction = span > 0
        ? ((charOffset - page.start) / span).clamp(0.0, 1.0).toDouble()
        : 0;
    return layout.pageTops[c][p] + fraction * page.height;
  }

  /// 实例委托（当前布局 + 当前窗口）。
  double? offsetForCharOffset(String href, int charOffset) =>
      offsetFor(_layout, widget.chapters, href, charOffset);

  /// 一次落位：算偏移 → clamp 上界 → 单跳（无校正环）。返回是否落位成功。
  /// 落位后按停手采样（`jumpTo` 是否发通知不作假设，显式重置计时器）。
  bool jumpToCharOffset(String href, int charOffset) {
    final double? target = offsetForCharOffset(href, charOffset);
    if (target == null || !_scroll.hasClients) return false;
    _scroll.jumpTo(target.clamp(0.0, maxScrollExtent).toDouble());
    _restartSampleTimer();
    if (mounted) setState(() {});
    return true;
  }

  bool _handleScroll(ScrollNotification notification) {
    if (_suspendScrollHandling) return false;
    if (notification.depth != 0) return false; // 只管本容器自己的滚动
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    // 滚动期不断重置计时器 → 只有静默 sampleDebounce 后才采（停手防抖）。
    _restartSampleTimer();
    final double vh =
        _viewportHeight ?? notification.metrics.viewportDimension;
    final VisibleRange next = _layout.visibleRange(
      notification.metrics.pixels,
      vh,
      widget.config.pageHeight,
    );
    if (next != _visible) {
      _visible = next;
      if (mounted) setState(() {});
    }
    return false;
  }

  void _restartSampleTimer() {
    if (widget.onSampled == null) return;
    _sampleTimer?.cancel();
    _sampleTimer = Timer(widget.sampleDebounce, () {
      if (!mounted) return;
      final ScrollSample? sample = sampleNow();
      if (sample != null) widget.onSampled!(sample);
    });
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double vh = constraints.maxHeight;
          _viewportHeight = vh;
          _visible = _layout.visibleRange(
            offset,
            vh,
            widget.config.pageHeight,
          );
          return SingleChildScrollView(
            controller: _scroll,
            physics: const ClampingScrollPhysics(),
            child: SizedBox(
              height: _layout.totalHeight,
              child: Stack(children: _buildLayer()),
            ),
          );
        },
      ),
    );
  }

  /// 可见层：章几何与可见带相交的标题（含无页占位章）+ 区间内各页
  /// （页框 = 内容自然高）。
  List<Widget> _buildLayer() {
    final VisibleRange range = _visible;
    final double bandLo = offset - widget.config.pageHeight;
    final double bandHi =
        offset + (_viewportHeight ?? 0) + widget.config.pageHeight;
    final List<Widget> out = <Widget>[];

    for (int c = 0; c < widget.chapters.length; c++) {
      final PagedChapterView chapter = widget.chapters[c];
      final Widget? heading = chapter.heading;
      if (heading == null || chapter.headingHeight <= 0) continue;
      final double top = _layout.chapterTops[c];
      final double bottom = c + 1 < _layout.chapterTops.length
          ? _layout.chapterTops[c + 1]
          : _layout.totalHeight;
      if (bottom <= bandLo || top >= bandHi) continue;
      out.add(Positioned(
        top: top,
        left: 0,
        right: 0,
        height: chapter.headingHeight,
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: widget.config.pageWidth,
            height: chapter.headingHeight,
            child: heading,
          ),
        ),
      ));
    }

    for (int i = range.first; i <= range.last; i++) {
      final FlatPage e = _layout.flatPages[i];
      final PagedChapterView chapter = widget.chapters[e.chapterIndex];
      final ParaSelection? sel = widget.selection;
      out.add(Positioned(
        top: e.top,
        left: 0,
        right: 0,
        height: e.height,
        child: Align(
          alignment: Alignment.topCenter,
          child: PageContent(
            paragraphs: chapter.paragraphs,
            lines: chapter.lines,
            page: chapter.pages[e.pageIndex],
            config: widget.config,
            resolveImage: widget.resolveImage,
            onLinkTap: widget.onLinkTap,
            highlightQuery: widget.highlightQuery,
            chapterHref: chapter.href,
            selection: sel != null && sel.chapterHref == chapter.href
                ? (paraIndex: sel.paraIndex, start: sel.start, end: sel.end)
                : null,
            speakingPara: widget.speaking != null &&
                    widget.speaking!.href == chapter.href
                ? widget.speaking!.paraIndex
                : null,
            clipHeight: e.height,
          ),
        ),
      ));
    }
    return out;
  }
}
