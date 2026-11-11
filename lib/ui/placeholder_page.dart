// 尚未落地的页面占位（统计 / AI / 笔记）。
//
// 存在的意义有两层：
// ① 骨架期——底部导航的五项**都可达**，切换体验在导航批次内就能验收；
// ② 长期——把「空态」形制（图标 + 标题 + 说明 + 可选行动）统一在一处，
//    页面做实后仍可复用为「无数据」态，不必各页重写。
//
// 视觉红线（`UI-04`）：内容不透明（页底取 Mi 页底色），浮层与导航层才用玻璃。
import 'package:flutter/material.dart';

import 'mi_like_ui/mi_like_ui.dart'
    show MiColors, MiThemeMode, MiTopBar, MiTopBarMetrics;

/// 通用空态页（mi_like 顶栏 + 居中图标 / 标题 / 说明）。
///
/// 壳为 `settings_page` 同款（ColoredBox 页底 + 钉顶 [MiTopBar]）：占位页
/// 无滚动（大标题常显）、无返回（tab 页降级态），直接放进导航壳层的页面位。
class PlaceholderPage extends StatelessWidget {
  /// 创建空态页。
  const PlaceholderPage({
    super.key,
    required this.title,
    required this.icon,
    required this.message,
    this.hint,
    this.action,
  });

  /// 顶栏标题（同时作为页面语义名）。
  final String title;

  /// 居中图标。
  final IconData icon;

  /// 一句话说明「本页将会是什么」。
  final String message;

  /// 补充提示（如排期说明）；`null` 则不占位。
  final String? hint;

  /// 可选行动按钮；`null` 则不占位。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MiThemeMode mode = Theme.of(context).brightness == Brightness.light
        ? MiThemeMode.light
        : MiThemeMode.dark;
    // 壳换 mi_like（`settings_page` 同款）：页底不透明（`UI-04`），顶栏
    // [MiTopBar] 大标题常显（占位页无滚动）；内容空态形制（图标 + 标题 +
    // 说明）原样保留——与顶栏标题并存，同原「GlassTopBar + 内容标题」口径。
    return ColoredBox(
      color: MiColors.pageBackgroundFor(mode),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  32,
                  MiTopBarMetrics.contentTopInset + 32,
                  32,
                  32,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        icon,
                        size: 64,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (hint != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          hint!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                      if (action != null) ...<Widget>[
                        const SizedBox(height: 24),
                        action!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: MiTopBar(title: title),
            ),
          ],
        ),
      ),
    );
  }
}
