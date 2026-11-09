// 阅读页底部工具栏（`RD-04` / `NAV-01`；mi_like_ui 悬浮工具栏）。
//
// 形态（负责人 2026-11-06 拍板）：一枚 [MiFloatingToolbar] **胶囊**，横排
// 目录 / 夜间 / 设置 / 更多 四格（`MiActionEntry`，64×56 定宽格），居中浮在
// 页底之上、靠 `SafeArea` 让开系统手势条 —— 不再是全宽贴底 surface。
//
// 进度滑条（上一章 / 进度滑条 / 下一章）**暂时移除**：章节跳转走「目录」。
// 要恢复时把原「上一章—滑条—下一章」那一档加回胶囊上方（原实现在 git 历史）。
//
// 收纳去向（功能一个不丢，只换入口）：
//   · 朗读开关 = 胶囊右上方的悬浮圆钮（[ReaderControlBar.floating]，由
//     `reader_page` 注入「听」钮）；
//   · 字号 / 行距 / 页边距 / 主题 = 「设置」面板（`reading_appearance_sheet.dart`）；
//   · AI 助手 / AI 摘要 / 朗读设置 = 「更多」操作列表；
//   · 章节跳转 = 「目录」抽屉；
//   · 搜索 / 书签留顶栏（`NAV-01` 顶栏口径不变）。
//
// 尺寸契约：胶囊 = 外留白 8×2 + 格高 56 = 72dp（**不含**系统 inset）⇒ 覆盖层
// 不参与正文预算；上限由 `test/ui/reader_chrome_layout_test.dart` 钉住。
//
// 与底部读数行的关系（§2.121）：本组件**保持原位**、不上移 24dp（仍靠自身
// `SafeArea(bottom: true)` 让开手势条）；唤出 chrome 时读数行 `Opacity(0)`
// 不绘制，正文上下**不叠任何渐进模糊层**。胶囊只覆盖自己那 280×72，
// 其余透到正文。
import 'package:flutter/material.dart';

import '../ui/mi_like_ui/mi_like_ui.dart';

/// 悬浮工具栏单格**宽**（dp）：与上游 showcase 同档（64×56）。
///
/// 4 格 × 64 + 外留白 12×2 = 280dp，320dp 窄屏也放得下（四档屏宽无溢出
/// 由 `reader_chrome_layout_test` 钉住）。
const double kReaderToolbarCellWidth = 64;

/// 悬浮工具栏单格**高**（dp）：与上游度量同源，避免两处漂移。
const double kReaderToolbarCellHeight = MiActionEntryMetrics.rowHeight;

/// 悬浮「听」钮与胶囊上缘的间隙（dp）。
const double kReaderToolbarFloatingGap = 12;

/// 阅读页底部工具栏。
///
/// 无状态：滑条移除后本组件只剩四格 + 一枚悬浮钮，没有拖拽预览要存。
class ReaderControlBar extends StatelessWidget {
  const ReaderControlBar({
    super.key,
    required this.onToc,
    required this.onNight,
    required this.nightActive,
    required this.onSettings,
    required this.onMore,
    this.floating,
  });

  /// 目录入口。
  final VoidCallback onToc;

  /// 夜间模式开关。
  final VoidCallback onNight;

  /// 夜间模式是否已开（图标与高亮态）。
  final bool nightActive;

  /// 设置面板入口（字号 / 行距 / 页边距 / 主题）。
  final VoidCallback onSettings;

  /// 更多操作列表入口；`null` = 无任何可收纳项 → 该格不渲染。
  final VoidCallback? onMore;

  /// 悬浮圆钮（「听」= 朗读开关）；`null` = 不渲染。
  ///
  /// 放在本组件内是为了**不给工具栏长高**：按钮绝对定位在胶囊上方
  /// （`bottom: inset + 胶囊高 + gap`，`Clip.none` 出圈），盒高契约不变。
  final Widget? floating;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MiThemeMode mode = theme.brightness == Brightness.dark
        ? MiThemeMode.dark
        : MiThemeMode.light;
    // 胶囊高 = 上游外留白（8×2）+ 格高（56）。**必须从 metrics 取**：
    // 写死 72 会在上游改外留白时静默漂移（胶囊会露出底板外一截）。
    final double toolbarHeight =
        MiFloatingToolbarMetrics.outsidePadding.vertical + kReaderToolbarCellHeight;
    // 听钮区（48 + 间隙）计入总高：`Stack` 的命中测试只认自身 bounds，
    // 钮子画在 bounds 外时事件会穿透到正文（tap 告警「would not hit
    // test」）。这里把钮区并进盒高，钮落在盒内即可点；钮区本身不放
    // 任何吸命中的子件，背后正文照旧可点（真悬浮语义）。
    final double floatingHeight =
        floating == null ? 0 : 48 + kReaderToolbarFloatingGap;
    // 系统手势条 inset 也计入：胶囊靠 `SafeArea` 抬到 inset 之上，盒高不加
    // 这一段的话，`Stack` 的 `Clip.hardEdge` 会把探出盒顶的半截胶囊削掉。
    final double inset = MediaQuery.paddingOf(context).bottom;

    return SizedBox(
      height: inset + toolbarHeight + floatingHeight,
      child: Stack(
        // 悬浮「听」钮在胶囊上方，出圈不裁剪。
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Center(child: _toolbar(mode)),
            ),
          ),
          if (floating != null)
            Positioned(
              right: 16,
              bottom: inset + toolbarHeight + kReaderToolbarFloatingGap,
              child: floating!,
            ),
        ],
      ),
    );
  }

  /// 四格胶囊。
  ///
  /// 不用 [MiActionEntryRow]（它每格 `Expanded` 等分 ⇒ 会被撑满整宽，失去
  /// 「胶囊」轮廓）：上游 showcase 的口径就是 `Row(min)` + 定宽格。
  /// 按压淡出 / 禁用降透明 / 高亮强调色 / 键盘可达性全部由 [MiActionEntry]
  /// 承担，本层只传入语义回调与 key。
  Widget _toolbar(MiThemeMode mode) {
    return MiFloatingToolbar(
      // 描边 0.75dp 把「表面」从同色的卡片里划出来（上游 showcase 同档）。
      showDivider: true,
      themeMode: mode,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final MiActionEntry entry in <MiActionEntry>[
            MiActionEntry(
              key: const Key('reader-toc'),
              icon: Icons.menu_book_outlined,
              label: '目录',
              themeMode: mode,
              onPressed: onToc,
            ),
            MiActionEntry(
              key: const Key('reader-night'),
              icon: nightActive ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              label: '夜间',
              active: nightActive,
              themeMode: mode,
              onPressed: onNight,
            ),
            MiActionEntry(
              key: const Key('reader-appearance'),
              icon: Icons.tune,
              label: '设置',
              themeMode: mode,
              onPressed: onSettings,
            ),
            if (onMore != null)
              MiActionEntry(
                key: const Key('reader-more'),
                icon: Icons.more_horiz,
                label: '更多',
                themeMode: mode,
                onPressed: onMore,
              ),
          ])
            // 定宽定高格：宽 64 见 [kReaderToolbarCellWidth]，高 = 行高度量。
            SizedBox(
              width: kReaderToolbarCellWidth,
              height: kReaderToolbarCellHeight,
              child: entry,
            ),
        ],
      ),
    );
  }
}
