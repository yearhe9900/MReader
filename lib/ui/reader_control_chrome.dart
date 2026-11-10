// 阅读页顶栏（§2.122 截图形态）：一枚圆角胶囊，两端各一枚
// `MiFloatingActionButton` 圆钮，中间只显示「当前章节名 · 进度」。
//
// ⚠️ 红线：胶囊用**半透明纯色**叠在宿主 AppBar 的不透明页面底色上，
// **不套 `BackdropFilter`**（§2.121 正文两态全清晰），也不让正文首行
// 从标题背后透出来——盖住正文的是 AppBar 那层不透明底，不是胶囊。
// ⚠️ 中间文案由宿主给，不在这里拼书名：书名已按负责人口径从顶栏下线。
import 'package:flutter/material.dart';

import 'mi_like_ui/mi_like_ui.dart';

/// 顶栏胶囊高度（dp；放进 56dp 的 `AppBar` 工具行里垂直居中）。
const double kReaderTopBarHeight = 48;

/// 顶栏圆钮直径（dp）。
const double kReaderTopBarButtonSize = 36;

/// 顶 / 底 chrome 滑入滑出时长（250ms）。
///
/// 取 Material 顶底层级的典型时长：足够看清「从边缘滑进来」的位移方向，
/// 又不拖沓（再长工具栏会显得迟到、再短位移看不清）。
const Duration kReaderChromeSlideDuration = Duration(milliseconds: 250);

/// 入场曲线（forward = 唤出）：起步快、落位缓 —— 「到位」的观感。
const Curve kReaderChromeEnterCurve = Curves.easeOutCubic;

/// 退出曲线（reverse = 收起）：起步缓、加速滑出 —— 「离场」的观感。
const Curve kReaderChromeExitCurve = Curves.easeInCubic;

/// 阅读页顶部胶囊导航。
class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    super.key,
    required this.statusText,
    required this.onBack,
    required this.ttsButton,
    required this.mode,
  });

  /// 中间状态文案（「当前章节名 · 进度」）。
  final String statusText;

  /// 返回（与 `BackButton` 同语义：`maybePop`，不是硬 pop）。
  final VoidCallback onBack;

  /// 右侧听书圆钮（由宿主构造的 `MiFloatingActionButton`，key 沿用旧听钮）。
  final Widget ttsButton;

  final MiThemeMode mode;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MiFloatingToolbarPalette palette =
        MiFloatingToolbarPalette.of(mode);
    final Color ink = MiColors.foregroundFor(mode);

    return DecoratedBox(
      key: const Key('reader-top-bar'),
      decoration: ShapeDecoration(
        // 半透明表面 = 导航层的玻璃观感；底下是宿主 AppBar 的不透明底色。
        color: palette.surface.withValues(alpha: 0.92),
        shape: StadiumBorder(
          side: BorderSide(
            color: palette.divider,
            width: MiFloatingToolbarMetrics.dividerWidth,
          ),
        ),
      ),
      child: SizedBox(
        height: kReaderTopBarHeight,
        child: Row(
          children: <Widget>[
            const SizedBox(width: 6),
            MiFloatingActionButton(
              key: const Key('reader-top-back'),
              size: kReaderTopBarButtonSize,
              showShadow: false,
              color: theme.colorScheme.surfaceContainerHighest,
              themeMode: mode,
              onPressed: onBack,
              child: const Icon(Icons.arrow_back_ios_new, size: 17),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  statusText,
                  key: const Key('reader-top-title'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: ink, fontWeight: FontWeight.w500),
                ),
              ),
            ),
            ttsButton,
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// `appBar:` 槽的滑动包装（槽要求 `PreferredSizeWidget`）：把子件沿
/// [position] 滑入 / 滑出（`SlideTransition`，位移按子件自身尺寸的比例）。
///
/// **纯绘制变换**：不触发布局 ⇒ 正文排版区几何一像素不动（`extendBody*`
/// 覆盖层语义的延伸）；命中测试随变换走，滑出屏幕外的部分不拦指针。
class SlidingPreferredSize extends StatelessWidget
    implements PreferredSizeWidget {
  const SlidingPreferredSize({
    super.key,
    required this.child,
    required this.position,
  });

  final Widget child;
  final Animation<Offset> position;

  @override
  Size get preferredSize => (child as PreferredSizeWidget).preferredSize;

  @override
  Widget build(BuildContext context) =>
      SlideTransition(position: position, child: child);
}
