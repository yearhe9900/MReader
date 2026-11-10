// 阅读页底部 chrome（§2.122 截图形态）：章节选择行 + 六格悬浮工具栏。
//
// 自下而上：① 一枚 `MiFloatingToolbar` 胶囊，横排 目录 / 书签 / 外观 /
// 操作 / 查找 / 日间（夜间）六格；② 其上方一条圆角章节行（上一章 —
// 按章吸附的 `MiSlider` — 下一章），**高宽复用胶囊参数**（等高 72、
// 宽 = 屏宽 − 24 封顶 408，两行等宽同轴）；③ 拖动滑条时章节行上方浮出
// 「章节名 · 进度」预览气泡（16 加粗，明显显示）。
//
// ⚠️ 红线：整层是**覆盖层**（`extendBody*`），盒高不进正文排版预算；
// 唤出 chrome 时读数由宿主用 `Opacity(0)` 收起、胶囊**保持原位**不上移。
// ⚠️ 六格按屏宽自适应（`_cellWidth`），320dp 窄屏不得溢出；格数固定，
// 「操作」无可收纳项时只降禁用态、**不许从树上摘掉**（截图是六格）。
// ⚠️ 预览气泡常驻 24dp 高的预留区（不画在盒外）：`Stack` 的命中测试只认
// 自身 bounds，浮层探出盒外会穿透到正文；气泡本体 `IgnorePointer`。
import 'package:flutter/material.dart';

import '../ui/mi_like_ui/mi_like_ui.dart';

/// 悬浮工具栏单格**最大宽**（dp）：宽屏不把胶囊拉成一条横幅。
const double kReaderToolbarCellWidth = 64;

/// 悬浮工具栏单格**最小宽**（dp）：320dp 屏六格仍能放下「图标 + 两字」。
const double kReaderToolbarMinCellWidth = 44;

/// 悬浮工具栏单格高（dp）：与上游度量同源，避免两处漂移。
const double kReaderToolbarCellHeight = MiActionEntryMetrics.rowHeight;

/// 胶囊外侧留白（左右各一份；与章节行同边距）。
const double kReaderChromeOuterMargin = 12;

/// 章节选择行高（dp）：**复用悬浮工具栏胶囊总高**（纵向外留白 + 单格高），
/// 与胶囊等高堆叠；两处不得各写一套数（`final` 运行期取值，`const` 上下文
/// 取不到 `EdgeInsets` 属性）。
final double kReaderChapterRowHeight =
    MiFloatingToolbarMetrics.outsidePadding.vertical + kReaderToolbarCellHeight;

/// 章节行与工具栏的间隙（dp）：11 = 8 + 上抬 3（2026-11-09 定稿视觉）。
const double kReaderChapterRowGap = 11;

/// 章节行上方预留给预览气泡的高度（dp）。
const double kReaderPreviewHeight = 24;

/// 阅读页底部 chrome。
class ReaderControlBar extends StatefulWidget {
  const ReaderControlBar({
    super.key,
    required this.chapterIndex,
    required this.chapterCount,
    required this.canGoPrev,
    required this.canGoNext,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onSeek,
    required this.previewLabel,
    required this.onToc,
    required this.onBookmarks,
    required this.onAppearance,
    required this.onActions,
    required this.onSearch,
    required this.onNight,
    required this.nightActive,
  });

  /// 当前章下标（0 基；滑条受控值）。
  final int chapterIndex;

  /// 总章数（滑条按章吸附的档数）。
  final int chapterCount;

  final bool canGoPrev;
  final bool canGoNext;

  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;

  /// 滑条落点跳章（逐帧上抛**吸附后**的章下标；防抖由调用方负责）。
  final ValueChanged<int> onSeek;

  /// 拖动到某章时气泡文案（「章节名 · 进度」由宿主按权重口径生成）。
  final String Function(int index) previewLabel;

  final VoidCallback onToc;
  final VoidCallback onBookmarks;
  final VoidCallback onAppearance;

  /// 「操作」入口；null = 无可收纳项 ⇒ 该格降禁用态（不消失）。
  final VoidCallback? onActions;

  final VoidCallback onSearch;
  final VoidCallback onNight;

  /// 夜间是否已开：决定末格图标与「日间 / 夜间」文案（**动作**语义）。
  final bool nightActive;

  @override
  State<ReaderControlBar> createState() => _ReaderControlBarState();
}

class _ReaderControlBarState extends State<ReaderControlBar> {
  /// 拖拽中的滑条预览值（0..1）；null = 跟随 [widget.chapterIndex]。
  ///
  /// 滑条受控，而落点跳章经宿主防抖异步执行 —— 拖拽期间必须本地预览，
  /// 否则拇指被旧章号弹回、跟不了手。外部章下标变化（跳章落地）即清空。
  double? _drag;

  int _previewIndex = 0;
  bool _previewVisible = false;

  void _onSlide(double t) {
    final int count = widget.chapterCount;
    final int target = count > 1
        ? (t * (count - 1)).round().clamp(0, count - 1)
        : 0;
    setState(() {
      _drag = t;
      _previewIndex = target;
      _previewVisible = true;
    });
    if (target != widget.chapterIndex) widget.onSeek(target);
  }

  void _onSlideEnd() {
    if (!_previewVisible) return;
    setState(() => _previewVisible = false);
  }

  @override
  void didUpdateWidget(covariant ReaderControlBar old) {
    super.didUpdateWidget(old);
    // 跳章已落地（实时章下标动了）→ 清预览；拖拽途中实时值不动、预览保留。
    if (old.chapterIndex != widget.chapterIndex) _drag = null;
  }

  /// 六格自适应格宽：胶囊总宽 = 屏宽 − 24（宽屏封顶 64/格，保持胶囊轮廓）。
  static double _cellWidth(BuildContext context) {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double available = screenWidth -
        2 * kReaderChromeOuterMargin -
        MiFloatingToolbarMetrics.outsidePadding.horizontal;
    return (available / 6)
        .clamp(kReaderToolbarMinCellWidth, kReaderToolbarCellWidth);
  }

  /// 胶囊宽（dp）：屏宽 − 24、宽屏封顶 6 × 64 + 24 = 408。
  ///
  /// 与 `_cellWidth` 同一公式，章节行直接复用 ⇒ 两行等宽同轴。
  static double _pillWidth(BuildContext context) => 6 * _cellWidth(context) +
      MiFloatingToolbarMetrics.outsidePadding.horizontal;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MiThemeMode mode = theme.brightness == Brightness.dark
        ? MiThemeMode.dark
        : MiThemeMode.light;
    final int count = widget.chapterCount;
    final double t = _drag ??
        (count > 1
            ? widget.chapterIndex.clamp(0, count - 1) / (count - 1)
            : 0);
    final double toolbarHeight =
        MiFloatingToolbarMetrics.outsidePadding.vertical +
            kReaderToolbarCellHeight;
    final double inset = MediaQuery.paddingOf(context).bottom;
    final double chapterBottom = inset + toolbarHeight + kReaderChapterRowGap;

    return SizedBox(
      height: chapterBottom +
          kReaderChapterRowHeight +
          kReaderPreviewHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(top: false, child: _toolbar(mode)),
          ),
          // 高宽复用胶囊参数：宽 = `_pillWidth`（屏宽 − 24、封顶 408）居中，
          // 高 = `kReaderChapterRowHeight`（胶囊总高 72）。
          Positioned(
            left: 0,
            right: 0,
            bottom: chapterBottom,
            height: kReaderChapterRowHeight,
            child: Center(
              // 显式给高：`Center` 会把 Positioned 的紧约束放宽成松约束，
              // 不补高行会缩回内容高 48（居中后间隙漂 +12）。
              child: SizedBox(
                width: _pillWidth(context),
                height: kReaderChapterRowHeight,
                child: _chapterRow(mode, t),
              ),
            ),
          ),
          if (_previewVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: chapterBottom + kReaderChapterRowHeight + 4,
              height: kReaderPreviewHeight - 4,
              child: IgnorePointer(child: Center(child: _previewChip(mode))),
            ),
        ],
      ),
    );
  }

  /// 六格胶囊。
  ///
  /// 不用 `MiActionEntryRow`（它每格 `Expanded` 会撑满父宽）—— 这里父宽由
  /// `MiFloatingToolbar` 的内容决定，用 `Row(min)` + 定宽格把胶囊轮廓钉住。
  Widget _toolbar(MiThemeMode mode) {
    final double cell = _cellWidth(context);
    final List<MiActionEntry> entries = <MiActionEntry>[
      MiActionEntry(
        key: const Key('reader-toc'),
        icon: Icons.format_list_bulleted,
        label: '目录',
        themeMode: mode,
        onPressed: widget.onToc,
      ),
      MiActionEntry(
        key: const Key('reader-bookmarks'),
        icon: Icons.bookmark_border,
        label: '书签',
        themeMode: mode,
        onPressed: widget.onBookmarks,
      ),
      MiActionEntry(
        key: const Key('reader-appearance'),
        icon: Icons.text_format,
        label: '外观',
        themeMode: mode,
        onPressed: widget.onAppearance,
      ),
      MiActionEntry(
        key: const Key('reader-more'),
        icon: Icons.tune,
        label: '操作',
        themeMode: mode,
        onPressed: widget.onActions,
      ),
      MiActionEntry(
        key: const Key('reader-search'),
        icon: Icons.search,
        label: '查找',
        themeMode: mode,
        onPressed: widget.onSearch,
      ),
      MiActionEntry(
        key: const Key('reader-night'),
        icon: widget.nightActive
            ? Icons.light_mode_outlined
            : Icons.dark_mode_outlined,
        label: widget.nightActive ? '日间' : '夜间',
        active: widget.nightActive,
        themeMode: mode,
        onPressed: widget.onNight,
      ),
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kReaderChromeOuterMargin,
        ),
        child: MiFloatingToolbar(
          key: const Key('reader-toolbar-pill'),
          showDivider: true,
          themeMode: mode,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final MiActionEntry entry in entries)
                SizedBox(
                  width: cell,
                  height: kReaderToolbarCellHeight,
                  child: entry,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 章节选择行：上一章 — 滑条 — 下一章。
  Widget _chapterRow(MiThemeMode mode, double t) {
    final int count = widget.chapterCount;
    final Color ink = MiColors.foregroundFor(mode);
    final MiFloatingToolbarPalette palette =
        MiFloatingToolbarPalette.of(mode);
    return DecoratedBox(
      key: const Key('reader-chapter-row'),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(kReaderChapterRowHeight / 2),
        border: Border.all(
          color: palette.divider,
          width: MiFloatingToolbarMetrics.dividerWidth,
        ),
      ),
      child: Row(
        children: <Widget>[
          _chapterButton(
            key: const Key('reader-control-prev'),
            tooltip: '上一章',
            icon: Icons.skip_previous,
            enabled: widget.canGoPrev,
            ink: ink,
            onTap: widget.onPrevChapter,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: MiSlider(
                key: const Key('reader-control-progress'),
                value: t,
                min: 0,
                max: 1,
                // divisions = 档数（含两端）⇒ 取 count 才与章号逐档对齐。
                divisions: count > 1 ? count : null,
                onChanged: count > 1 ? _onSlide : null,
                onChangeEnd: _onSlideEnd,
                themeMode: mode,
              ),
            ),
          ),
          _chapterButton(
            key: const Key('reader-control-next'),
            tooltip: '下一章',
            icon: Icons.skip_next,
            enabled: widget.canGoNext,
            ink: ink,
            onTap: widget.onNextChapter,
          ),
        ],
      ),
    );
  }

  Widget _chapterButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required bool enabled,
    required Color ink,
    required VoidCallback onTap,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(icon, size: 24),
      color: enabled ? ink : ink.withValues(alpha: ink.a * 0.38),
      onPressed: enabled ? onTap : null,
    );
  }

  /// 拖动预览气泡（章节名 · 全书进度）。
  Widget _previewChip(MiThemeMode mode) {
    final MiFloatingToolbarPalette palette =
        MiFloatingToolbarPalette.of(mode);
    return DecoratedBox(
      key: const Key('reader-chapter-preview'),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: palette.divider,
          width: MiFloatingToolbarMetrics.dividerWidth,
        ),
      ),
      child: Padding(
        // 纵向 1：16 字号 + 描边后整片 19.5 ≤ 气泡预留 20，不越盒。
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
        child: Text(
          widget.previewLabel(_previewIndex),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 拖动预览要**一眼可见**：16 / 加粗（原 12 常规太弱）。
          style: MiTypography.navLabelFor(mode).copyWith(
            color: MiColors.foregroundFor(mode),
            fontSize: 16,
            height: 1.0,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
