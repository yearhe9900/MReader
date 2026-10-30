// 阅读页**顶栏分组** chrome：组内按钮 + 组间竖分隔线。
//
// 底部控制条已按截图形态简化为 mi_like_ui 风格菜单（`control_bar.dart`），
// 原「分组盒 / 统一图标按钮」组件随之退场；本文件只保留顶栏仍在用的
// [ReaderAppBarGroup]——AppBar 自身已有底色，不画底色盒子，只用分隔线表达
// 「哪几个按钮是一组」。第一个分组不画左侧分隔线（否则紧贴返回键，像多出
// 一道无来由的刻度）。
import 'package:flutter/material.dart';

/// 顶栏的一个功能分组：组内按钮 + 组间竖分隔线。
class ReaderAppBarGroup extends StatelessWidget {
  /// 创建一个顶栏分组。
  const ReaderAppBarGroup({
    super.key,
    required this.children,
    this.leadingDivider = true,
  });

  /// 组内按钮。
  final List<Widget> children;

  /// 是否在组左侧画分隔线；整条 `actions` 的**首组**应传 `false`。
  final bool leadingDivider;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).dividerColor.withValues(alpha: 0.45);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (leadingDivider)
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: color,
          ),
        ...children,
      ],
    );
  }
}
