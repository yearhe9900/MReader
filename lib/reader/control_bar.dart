// 阅读页底部 chrome：六格悬浮工具栏（`MiFloatingToolbar` 胶囊）。
//
// 自下而上只有一枚胶囊，横排 目录 / 书签 / 外观 / 操作 / 查找 / 日间（夜间）。
// 章节选择行（上一章 — 章节滑条 — 下一章）与拖动预览气泡已按负责人口径
// **下线**（2026-11-10）：章节跳转走「目录」，上/下一章另有通知栏与
// TTS 耳机键入口。
//
// ⚠️ 红线：整层是**覆盖层**（`extendBody*`），盒高不进正文排版预算；
// 唤出 chrome 时读数由宿主用 `Opacity(0)` 收起、胶囊**保持原位**不上移。
// ⚠️ 六格按屏宽自适应（`_cellWidth`），320dp 窄屏不得溢出；格数固定，
// 「操作」无可收纳项时只降禁用态、**不许从树上摘掉**（截图是六格）。
import 'package:flutter/material.dart';

import '../ui/mi_like_ui/mi_like_ui.dart';

/// 悬浮工具栏单格**最大宽**（dp）：宽屏不把胶囊拉成一条横幅。
const double kReaderToolbarCellWidth = 64;

/// 悬浮工具栏单格**最小宽**（dp）：320dp 屏六格仍能放下「图标 + 两字」。
const double kReaderToolbarMinCellWidth = 44;

/// 悬浮工具栏单格高（dp）：与上游度量同源，避免两处漂移。
const double kReaderToolbarCellHeight = MiActionEntryMetrics.rowHeight;

/// 胶囊外侧留白（左右各一份）。
const double kReaderChromeOuterMargin = 12;

/// 阅读页底部 chrome（六格胶囊）。
class ReaderControlBar extends StatelessWidget {
  const ReaderControlBar({
    super.key,
    required this.onToc,
    required this.onBookmarks,
    required this.onAppearance,
    required this.onActions,
    required this.onSearch,
    required this.onNight,
    required this.nightActive,
  });

  final VoidCallback onToc;
  final VoidCallback onBookmarks;
  final VoidCallback onAppearance;

  /// 「操作」入口；null = 无可收纳项 ⇒ 该格降禁用态（不消失）。
  final VoidCallback? onActions;

  final VoidCallback onSearch;
  final VoidCallback onNight;

  /// 夜间是否已开：决定末格图标与「日间 / 夜间」文案（**动作**语义）。
  final bool nightActive;

  /// 六格自适应格宽：胶囊总宽 = 屏宽 − 24（宽屏封顶 64/格，保持胶囊轮廓）。
  static double _cellWidth(BuildContext context) {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double available = screenWidth -
        2 * kReaderChromeOuterMargin -
        MiFloatingToolbarMetrics.outsidePadding.horizontal;
    return (available / 6)
        .clamp(kReaderToolbarMinCellWidth, kReaderToolbarCellWidth);
  }

  @override
  Widget build(BuildContext context) {
    final MiThemeMode mode =
        Theme.of(context).brightness == Brightness.dark
            ? MiThemeMode.dark
            : MiThemeMode.light;
    // ⚠️ 必须显式给高：`bottomNavigationBar` 槽位是有界约束，`Center` 会
    // 撑满槽位把胶囊居中到屏幕中央（实测 pill.bottom=445，挡住正文点击）。
    // 高 = 胶囊 72 + 系统手势条 inset（`SafeArea` 在盒内吃 inset ⇒
    // 胶囊贴屏底让位，盒高随 inset 变——「withInset = plain + N」口径不变）。
    final double inset = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: MiFloatingToolbarMetrics.outsidePadding.vertical +
          kReaderToolbarCellHeight +
          inset,
      child: SafeArea(top: false, child: _toolbar(context, mode)),
    );
  }

  /// 六格胶囊。
  ///
  /// 不用 `MiActionEntryRow`（它每格 `Expanded` 会撑满父宽）—— 这里父宽由
  /// `MiFloatingToolbar` 的内容决定，用 `Row(min)` + 定宽格把胶囊轮廓钉住。
  Widget _toolbar(BuildContext context, MiThemeMode mode) {
    final double cell = _cellWidth(context);
    final List<MiActionEntry> entries = <MiActionEntry>[
      MiActionEntry(
        key: const Key('reader-toc'),
        icon: Icons.format_list_bulleted,
        label: '目录',
        themeMode: mode,
        onPressed: onToc,
      ),
      MiActionEntry(
        key: const Key('reader-bookmarks'),
        icon: Icons.bookmark_border,
        label: '书签',
        themeMode: mode,
        onPressed: onBookmarks,
      ),
      MiActionEntry(
        key: const Key('reader-appearance'),
        icon: Icons.text_format,
        label: '外观',
        themeMode: mode,
        onPressed: onAppearance,
      ),
      MiActionEntry(
        key: const Key('reader-more'),
        icon: Icons.tune,
        label: '操作',
        themeMode: mode,
        onPressed: onActions,
      ),
      MiActionEntry(
        key: const Key('reader-search'),
        icon: Icons.search,
        label: '查找',
        themeMode: mode,
        onPressed: onSearch,
      ),
      MiActionEntry(
        key: const Key('reader-night'),
        icon: nightActive ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        label: nightActive ? '日间' : '夜间',
        active: nightActive,
        themeMode: mode,
        onPressed: onNight,
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
}
