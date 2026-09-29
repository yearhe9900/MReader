// 设置页的视觉组件集（2026-09-29 参考 HyperOS / 小米系统设置页风格重做）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 四条口径
// ══════════════════════════════════════════════════════════════════════════════
// 1. **卡片与行一律不透明**。PRD §11.2 原把「设置页内的控件」「设置页的分组卡片」
//    列为玻璃；本批落**实心卡片**（与参考图一致，也让设置页能继续滚动）。
//    依据与边界（已上报负责人并拍板，PRD §11.2 随 v2.10 改文）：
//      · 同节理由①「库的设计哲学是『导航层用玻璃、内容层不透明』」与理由③
//        「`premium` 禁进滚动区、放进滚动区有渲染成本」都指向实心卡片——
//        整屏滚动的玻璃卡片正落在理由③的成本论据里；
//      · `UI-04` ②「玻璃控件不出现在任何滚动列表行内」条文上是**任何**行，
//        但其枚举范围限于内容层行（书架 / 目录 / 搜索 / 统计 / 正文），
//        故本条**不是**「原文自相矛盾」，而是取向相左 → 由负责人裁量。
//    **浮层仍走玻璃**（§11.2「浮层 = 玻璃」不变，本页的选择弹层经
//    [GlassOverlays.showSheet] 弹出）。
// 2. 行的形态照参考图：leading **40×40 圆角方形彩色图标** + 标题（+ 可选副标题）+
//    右侧「当前值 + 箭头」，或右侧直接放 Switch（二选一，见 [SettingsTile.trailing]）。
// 3. 图标底色是**装饰性**的（参考图每行一色），不承担语义，故不进 `ColorScheme`；
//    图标一律白色描边，保证浅色 / 深色主题下都可读。
// 4. 本文件的公开出口共五个：[SettingsAccents]（色板）、[SettingsGroupCard] /
//    [SettingsTile]（卡片与行）、[SettingsPickerSheet] / [showSettingsPicker]
//    （选择弹层，与 [GlassOverlays] 同一档位口径）。
//
// 卡片用 [Material] 而不是 `Container + BoxDecoration`：`InkWell` 的水波纹画在最近的
// `Material` 上，若卡片只是「画在 Material 之上的装饰」，水波纹会被卡片底色盖住。
import 'package:flutter/material.dart';

import 'glass_kit.dart';

/// 行图标的装饰色板（照参考图取色；**无语义**，勿当状态色用）。
abstract final class SettingsAccents {
  /// 蓝（网络 / 通用）。
  static const Color blue = Color(0xFF3B82F6);

  /// 紫（外观 / 主题）。
  static const Color purple = Color(0xFF8B5CF6);

  /// 绿（开关 / 绿色状态）。
  static const Color green = Color(0xFF22C55E);

  /// 橙（性能 / 警示）。
  static const Color orange = Color(0xFFF59E0B);

  /// 灰（次要 / 禁用项）。
  static const Color gray = Color(0xFF6B7280);
}

/// 设置分组卡片（不透明圆角容器 + 可选组标题 / 组脚注）。
///
/// 行与行之间**不画分隔线**（与参考图一致）；组标题与脚注都在卡片之外
/// （标题在上、脚注在下），这既保留了原本的分组语义，也不破坏卡片的干净轮廓。
class SettingsGroupCard extends StatelessWidget {
  /// 创建分组卡片。
  const SettingsGroupCard({
    super.key,
    this.header,
    this.footer,
    required this.children,
  });

  /// 组标题（次要色小字，卡片上方）。
  final String? header;

  /// 组脚注（次要色小字，卡片下方）——承载「当前生效档位」这类补充说明。
  final String? footer;

  /// 行（通常是一串 [SettingsTile]）。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle caption = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Text(header!, style: caption),
          ),
        Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text(footer!, style: caption),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// 设置行：彩色圆角方形图标 + 标题（+ 副标题）+ 右侧「值 + 箭头」或自定义控件。
class SettingsTile extends StatelessWidget {
  /// 创建设置行。
  const SettingsTile({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailing,
    this.enabled = true,
  });

  /// leading 图标。
  final IconData icon;

  /// 图标底色（取 [SettingsAccents]）。
  final Color accent;

  /// 主标题。
  final String title;

  /// 副标题（可选，最多两行）。
  final String? subtitle;

  /// 右侧当前值（可选，次要色）；有 [onTap] 时表示「可点进选择」。
  final String? value;

  /// 整行点击；为空则本行不可点（此时右侧画箭头——除非给了 [trailing]）。
  ///
  /// 可与 [trailing] 同时给（如「开关行」：点开关或点整行都能切换）；
  /// 但不能与 [value] 同时给（「值 + 箭头」与「自定义右侧控件」互斥）。
  final VoidCallback? onTap;

  /// 完全自定义的右侧控件（如 Switch）。**与 [value] 互斥**；给了它就不画箭头。
  final Widget? trailing;

  /// 是否可用；不可用时整体降透明度且不响应点击（如关档下的「降低视觉特效」）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    assert(
      trailing == null || value == null,
      'SettingsTile：trailing（自定义右侧）与 value（「值 + 箭头」）互斥。',
    );
    final ThemeData theme = Theme.of(context);
    // 不可用态：与 Material 的 disabled 口径一致（0.38 不透明度）。
    final Color titleColor = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final Color subColor = theme.colorScheme.onSurfaceVariant;

    final Widget row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: enabled ? accent : accent.withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 22, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: enabled
                            ? subColor
                            : subColor.withValues(alpha: 0.38),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (value != null) ...<Widget>[
            const SizedBox(width: 8),
            Text(value!, style: theme.textTheme.bodyMedium?.copyWith(
              color: subColor,
            )),
          ],
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ] else if (onTap != null) ...<Widget>[
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 20, color: subColor),
          ],
        ],
      ),
    );

    if (onTap == null) return row;
    return InkWell(onTap: enabled ? onTap : null, child: row);
  }
}

/// 设置项单选弹层的一个候选项。
class SettingsPickerOption<T> {
  /// 创建候选项。
  const SettingsPickerOption({
    required this.value,
    required this.label,
    this.description,
  });

  /// 选中后回传的值。
  final T value;

  /// 候选项文案（也用作设置行右侧的「当前值」）。
  final String label;

  /// 候选项下的补充说明（可选，次要色小字）。
  final String? description;
}

/// 设置项单选弹层（玻璃浮层内容；点选即 pop 回值）。
///
/// 形态照搬既有的 `book_detail_page.dart` `_GroupPickerSheet`（同为本项目
/// **玻璃底部弹窗 + 单选列表**的唯一已验证写法）：
/// 标题常驻、`Divider` 分隔、当前值打勾、点选 `Navigator.pop(value)`。
///
/// 首层必须是 [Material]（`MaterialType.transparency`）——玻璃浮层**没有
/// Material 祖先**（PRD §11.4），缺了它 `ListTile` 的水波纹与文字会渲染异常
/// （黄色双下划线）。透明类型不画底色，不破坏玻璃观感。
class SettingsPickerSheet<T> extends StatelessWidget {
  /// 创建单选弹层内容。
  const SettingsPickerSheet({
    super.key,
    required this.title,
    required this.options,
    required this.current,
  });

  /// 弹层标题（如「主题模式」）。
  final String title;

  /// 候选项（顺序即渲染顺序）。
  final List<SettingsPickerOption<T>> options;

  /// 当前值（打勾的那一项）。
  final T current;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            const Divider(height: 1),
            for (final SettingsPickerOption<T> option in options)
              ListTile(
                title: Text(option.label),
                subtitle: option.description == null
                    ? null
                    : Text(option.description!),
                trailing: option.value == current
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(option.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 弹出设置项单选弹层；返回选中值（取消 / 点遮罩返回 `null`）。
///
/// **档位随环境**：玻璃档经 [GlassOverlays.showSheet] 出玻璃底部弹窗，
/// 「关」档自动退化为 Material `showModalBottomSheet`（`UI-06` ②）。
///
/// `isScrollable: false`：内容是不可滚动的 [Column]（候选项最多 4 个），
/// 关掉外层滚动包装可避免「纵向滚动视图嵌套」（见 [GlassOverlays.showSheet]
/// 对 `isScrollable` 的说明）。
Future<T?> showSettingsPicker<T>({
  required BuildContext context,
  required String title,
  required List<SettingsPickerOption<T>> options,
  required T current,
}) {
  return GlassOverlays.showSheet<T>(
    context: context,
    isScrollable: false,
    builder: (BuildContext sheetContext) => SettingsPickerSheet<T>(
      title: title,
      options: options,
      current: current,
    ),
  );
}
