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
