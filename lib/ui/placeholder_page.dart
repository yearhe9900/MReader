// 尚未落地的页面占位（统计 / AI / 笔记）。
//
// 存在的意义有两层：
// ① 骨架期——底部导航的五项**都可达**，切换体验在导航批次内就能验收；
// ② 长期——把「空态」形制（图标 + 标题 + 说明 + 可选行动）统一在一处，
//    页面做实后仍可复用为「无数据」态，不必各页重写。
//
// 视觉红线（`UI-04`）：内容由 [OpaqueContentSurface] 承载（永不透明失效），
// 玻璃只出现在导航层（顶栏 / 底栏）。
import 'package:flutter/material.dart';

import 'glass_kit.dart';

/// 通用空态页（玻璃顶栏 + 居中图标 / 标题 / 说明）。
///
/// 本页自带 [GlassNavScaffold] 骨架，因此直接放进导航壳层的页面位即可；
/// **不要在 [GlassNavScaffold] 里再套一层**（玻璃不可嵌套）。
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
    return GlassNavScaffold(
      appBar: GlassTopBar(title: Text(title)),
      body: OpaqueContentSurface(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
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
    );
  }
}
