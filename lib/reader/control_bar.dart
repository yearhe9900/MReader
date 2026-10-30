// 阅读页底部菜单（`RD-04` / `NAV-01`；mi_like_ui 风格）。
//
// 形态（对齐参考截图，替换旧版「章节 / 朗读与 AI / 排版」三分组控制条）：
//   第一行：上一章 —— 进度滑条（MiSlider，按章吸附）—— 下一章
//   第二行：目录 / 夜间 / 设置 / 更多（图标 + 文字，等分四格）
//
// 收纳去向（功能一个不丢，只换入口）：
//   · 朗读开关 = 菜单上方右侧的悬浮圆钮（[ReaderControlBar.floating]，由
//     `reader_page` 注入「听」钮）；
//   · 字号 / 行距 / 页边距 / 主题 = 「设置」面板（`reading_appearance_sheet.dart`
//     新增排版区）；
//   · AI 助手 / AI 摘要 / 朗读设置 = 「更多」操作列表（MiDialog 纵向列表形态）；
//   · 搜索 / 书签留顶栏（`NAV-01` 顶栏口径不变）。
//
// 尺寸契约：第一行 44（滑条命中高 32 + 上下 6）、第二行 56 ⇒ 菜单高 100
// （`test/ui/reader_chrome_layout_test.dart` 钉住上限）。菜单是覆盖层
// （`extendBody*`），高度不参与正文预算，但不得显著长高。
import 'package:flutter/material.dart';

import '../ui/mi_like_ui/mi_like_ui.dart';

/// 菜单第一行（章节导航 + 进度滑条）行高（dp）。
const double kReaderMenuNavRowHeight = 44;

/// 菜单第二行（目录 / 夜间 / 设置 / 更多）行高（dp）。
const double kReaderMenuActionRowHeight = 56;

/// 菜单总高（两行之和，不含 SafeArea）。
const double kReaderMenuHeight =
    kReaderMenuNavRowHeight + kReaderMenuActionRowHeight;

/// 悬浮「听」钮与菜单上缘的间隙（dp；参考截图的悬浮圆钮位置）。
const double kReaderMenuFloatingGap = 12;

/// 阅读页底部菜单。
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
    required this.onToc,
    required this.onNight,
    required this.nightActive,
    required this.onSettings,
    required this.onMore,
    this.floating,
  });

  /// 当前章下标（0 基；进度滑条的受控值）。
  final int chapterIndex;

  /// 总章数（滑条按章吸附的档数）。
  final int chapterCount;

  /// 是否可回上一章（首章时为 false → 按钮降禁用态，不消失）。
  final bool canGoPrev;

  /// 是否可去下一章（末章时为 false）。
  final bool canGoNext;

  /// 回上一章。
  final VoidCallback onPrevChapter;

  /// 去下一章。
  final VoidCallback onNextChapter;

  /// 进度滑条落点跳章（拖拽逐帧上抛**吸附后的章下标**；防抖由调用方负责）。
  final ValueChanged<int> onSeek;

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
  /// 放在本组件内是为了**不给菜单长高**：按钮绝对定位在菜单上方
  /// （`bottom: kReaderMenuHeight + gap`，`Clip.none` 出圈），行高契约不变。
  final Widget? floating;

  @override
  State<ReaderControlBar> createState() => _ReaderControlBarState();
}

class _ReaderControlBarState extends State<ReaderControlBar> {
  /// 拖拽中的滑条预览值（0..1 归一化）；`null` = 跟随 [widget.chapterIndex]。
  ///
  /// 滑条是受控组件，而落点跳章经 [_ReaderControlBarState] 外的防抖异步执行
  /// ——拖拽期间必须本地预览，否则拇指被旧章数弹回、跟不了手。外部
  /// [chapterIndex] 变化（跳章落地）即清空，显示权交还实时值。
  double? _drag;

  void _onSlide(double t) {
    final int count = widget.chapterCount;
    setState(() => _drag = t);
    final int target = (t * (count - 1)).round();
    if (target != widget.chapterIndex) widget.onSeek(target);
  }

  @override
  void didUpdateWidget(covariant ReaderControlBar old) {
    super.didUpdateWidget(old);
    // 跳章已落地（实时章下标动了）→ 清预览；拖拽途中实时值不动、预览保留。
    if (old.chapterIndex != widget.chapterIndex) _drag = null;
  }

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

    return SizedBox(
      // 听钮区（透明）计入总高：`Stack` 的命中测试只认自身 bounds，
      // 钮子画在 bounds 外时事件会穿透到正文（tap 告警「would not hit
      // test」）。这里把钮区并进盒高，钮落在盒内即可点；钮区本身不放
      // 任何吸命中的子件，背后正文照旧可点（真悬浮语义）。
      height: kReaderMenuHeight +
          (widget.floating == null
              ? 0
              : 48 + kReaderMenuFloatingGap),
      child: Stack(
        // 悬浮「听」钮在菜单上方，出圈不裁剪。
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: theme.colorScheme.surface,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _navRow(context, mode, t),
                    _actionRow(context, mode),
                  ],
                ),
              ),
            ),
          ),
          if (widget.floating != null)
            Positioned(
              right: 16,
              bottom: kReaderMenuHeight + kReaderMenuFloatingGap,
              child: widget.floating!,
            ),
        ],
      ),
    );
  }

  /// 第一行：上一章 —— 进度滑条 —— 下一章。
  Widget _navRow(BuildContext context, MiThemeMode mode, double t) {
    final int count = widget.chapterCount;
    return SizedBox(
      height: kReaderMenuNavRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            _navButton(
              context: context,
              mode: mode,
              label: '上一章',
              key: const Key('reader-control-prev'),
              enabled: widget.canGoPrev,
              onTap: widget.onPrevChapter,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: MiSlider(
                  key: const Key('reader-control-progress'),
                  value: t,
                  min: 0,
                  max: 1,
                  // 按章吸附：一格一章；单章书退化为禁用（无处可跳）。
                  divisions: count > 1 ? count - 1 : null,
                  onChanged: count > 1 ? _onSlide : null,
                  themeMode: mode,
                ),
              ),
            ),
            _navButton(
              context: context,
              mode: mode,
              label: '下一章',
              key: const Key('reader-control-next'),
              enabled: widget.canGoNext,
              onTap: widget.onNextChapter,
            ),
          ],
        ),
      ),
    );
  }

  /// 章节文字钮（上 / 下一章）：按压淡出 + 禁用降透明，不缩放不变色。
  Widget _navButton({
    required BuildContext context,
    required MiThemeMode mode,
    required String label,
    required Key key,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      enabled: enabled,
      child: MiPressable(
        key: key,
        onPressed: enabled ? onTap : null,
        mode: mode,
        borderRadius: BorderRadius.circular(12),
        pressBuilder: (BuildContext context, bool pressed, Widget child) =>
            Opacity(
          opacity: enabled ? (pressed ? 0.55 : 1.0) : 0.38,
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: MiTypography.buttonLabel.copyWith(
              fontSize: 14,
              color: MiColors.foregroundFor(mode),
            ),
          ),
        ),
      ),
    );
  }

  /// 第二行：目录 / 夜间 / 设置 / 更多（图标 + 文字，等分四格）。
  ///
  /// 「图标 + 文字」纵向菜单条目在 mi_like_ui 里**没有对应组件**（已向上游
  /// 提 issue），暂以 MiPressable + 导航标签排版自拼；上游组件入库后换装。
  Widget _actionRow(BuildContext context, MiThemeMode mode) {
    return SizedBox(
      height: kReaderMenuActionRowHeight,
      child: Row(
        children: <Widget>[
          Expanded(
            child: _MenuEntry(
              key: const Key('reader-toc'),
              icon: Icons.menu_book_outlined,
              label: '目录',
              mode: mode,
              onPressed: widget.onToc,
            ),
          ),
          Expanded(
            child: _MenuEntry(
              key: const Key('reader-night'),
              icon: widget.nightActive
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
              label: '夜间',
              active: widget.nightActive,
              mode: mode,
              onPressed: widget.onNight,
            ),
          ),
          Expanded(
            child: _MenuEntry(
              key: const Key('reader-appearance'),
              icon: Icons.tune,
              label: '设置',
              mode: mode,
              onPressed: widget.onSettings,
            ),
          ),
          if (widget.onMore != null)
            Expanded(
              child: _MenuEntry(
                key: const Key('reader-more'),
                icon: Icons.more_horiz,
                label: '更多',
                mode: mode,
                onPressed: widget.onMore,
              ),
            ),
        ],
      ),
    );
  }
}

/// 底部菜单的一格「图标 + 文字」条目。
class _MenuEntry extends StatelessWidget {
  const _MenuEntry({
    super.key,
    required this.icon,
    required this.label,
    required this.mode,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final MiThemeMode mode;
  final VoidCallback? onPressed;

  /// 高亮态（夜间已开）：图标与文字走强调色。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final Color ink = active ? MiColors.accent : MiColors.foregroundFor(mode);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: MiPressable(
        onPressed: onPressed,
        mode: mode,
        borderRadius: BorderRadius.circular(12),
        pressBuilder: (BuildContext context, bool pressed, Widget child) =>
            Opacity(opacity: pressed ? 0.55 : 1.0, child: child),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 22, color: ink),
            const SizedBox(height: 3),
            Text(
              label,
              style: MiTypography.navLabelFor(mode).copyWith(color: ink),
            ),
          ],
        ),
      ),
    );
  }
}
