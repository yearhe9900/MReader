// 设置页的视觉组件集 —— **对齐上游 mi_like_ui demo「我的」页**（上游 `a12d6f3`
// 「我的」页改版为系统设置页风格 + `5fb8199` 行尾前进箭头，2026-10-27 拍板
// 「全跟上游」）。参考素材：系统设置页明暗截图（1220×2656）；卡片 / 按压色与
// 几何是上游**目测推导值**，逐项收在 [SettingsKitMetrics]（改那里前先核对上游
// `demo/mock_pages.dart` 的 `_SettingsStyle`，两边不得悄悄分叉）。
//
// 四条口径：
// 1. **卡片与行一律不透明**（PRD §11.2 实心卡片拍板仍有效）：库的设计哲学是
//    「导航层用玻璃、内容层不透明」，且 `premium` 禁进滚动区。
//    **单选弹层已换 mi_like_ui [MiDialog]**（2026-10-27 拍板「主题模式弹框也
//    改为 mi_like_ui 弹框」，与书架长按操作弹框同款、档位无关）；其余浮层仍走玻璃。
// 2. 行的形态照上游：leading **38×38 圆角 10 彩色图标块** + 主文案 16/w400
//    （+ 副标题 13）+ 右侧「当前值 14 + 前进箭头」，或右侧直接放 Switch
//   （二选一，见 [SettingsTile.trailing]）；行最小高 56。
// 3. **点击反馈 = 整行满铺高亮带**（亮 #E7E7E7 / 暗 #3A3A3A、120ms 渐变渐隐，
//    上游同款），**不再是 `InkWell` 水波纹**。图标底色仍是**装饰性**的（上游
//    每行一色），不进 `ColorScheme`；图标一律白色描边，明暗主题下都可读。
// 4. 本文件的公开出口共五个：[SettingsKitMetrics]（度量）、[SettingsAccents]
//    （色板）、[SettingsGroupCard] / [SettingsTile]（卡片与行）、
//    [showSettingsPicker]（选择弹框，内部走 [MiDialog]，旧 [SettingsPickerSheet]
//    已退场）。
//
// 卡片仍用 [Material]（而不是上游的 `ClipRRect + ColoredBox`）：卡片内部有
// [ListTile] / [Switch]（AI 设置与同步页），它们要求最近处有 Material 祖先；
// 圆角裁剪由 `clipBehavior: Clip.antiAlias` 承担，观感与上游一致，行高亮带
// 随卡片圆角被裁（与素材一致）。
import 'package:flutter/material.dart';

import 'mi_like_ui/mi_like_ui.dart'
    show
        ForwardChevronIconPainter,
        MiDialog,
        MiDialogItem,
        MiDialogLayout,
        MiSquircleBorder,
        MiThemeMode;

/// 行图标的装饰色板（**上游「我的」页取色**；**无语义**，勿当状态色用）。
abstract final class SettingsAccents {
  /// 蓝（网络 / 通用，上游 WLAN / 蓝牙行同色）。
  static const Color blue = Color(0xFF2F9BFF);

  /// 紫（外观 / 主题，上游「外观模式」行同色）。
  static const Color purple = Color(0xFF7A5CFA);

  /// 绿（开关 / 绿色状态，上游「移动网络」行同色）。
  static const Color green = Color(0xFF34C759);

  /// 橙（性能 / 警示，上游「居中弹框」行同色）。
  static const Color orange = Color(0xFFFF9500);

  /// 灰（次要 / 禁用项，上游「我的设备」行同色）。
  static const Color gray = Color(0xFF8E8E93);
}

/// 设置页风格度量（**上游 demo「我的」页 `_SettingsStyle` 逐项照抄**，上游
/// `a12d6f3`；参考素材：系统设置页明暗截图 1220×2656，色值与几何为上游
/// **目测推导值**）。
///
/// 改这里 = 与上游观感分叉；先回核上游 `demo/mock_pages.dart`。
abstract final class SettingsKitMetrics {
  SettingsKitMetrics._();

  /// 分组卡片圆角。
  static const double cardRadius = 20;

  /// 卡片填充（亮 #FFFFFF / 暗 #1E1E1E）。
  ///
  /// ⚠️ 这对色值依赖 **Mi 页底色**（亮 #F3F3F3 / 暗 #000000）才有对比——
  /// 用它们的页面底色须取 `MiColors.pageBackgroundFor`（`我的` 页即如此，
  /// 与 `shelf_search_page` 同先例），不能用近白的 M3 surface。
  static Color cardFor(Brightness brightness) => brightness == Brightness.light
      ? const Color(0xFFFFFFFF)
      : const Color(0xFF1E1E1E);

  /// 整行按压高亮带（亮 #E7E7E7 / 暗 #3A3A3A；与搜索框填充同语言）。
  static Color pressFor(Brightness brightness) => brightness == Brightness.light
      ? const Color(0xFFE7E7E7)
      : const Color(0xFF3A3A3A);

  /// 按压渐变时长（上游推导：MIUI 行按压为快闪档，~120ms）。
  static const Duration pressDuration = Duration(milliseconds: 120);

  /// 行最小高度（副标题行随内容增高）。
  static const double rowMinHeight = 56;

  /// 前导图标块边长 / 圆角。
  static const double tileSide = 38;
  static const double tileRadius = 10;

  /// 行尾前进箭头墨盒（`ForwardChevronIconPainter`，返回箭头的水平镜像）。
  static const double chevronWidth = 11.7;
  static const double chevronHeight = 21.3;
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
          // 卡片填充随明暗（上游 #FFFFFF / #1E1E1E，见 [SettingsKitMetrics.cardFor]）。
          color: SettingsKitMetrics.cardFor(theme.brightness),
          // Squircle 连续圆角（上游全库批 `78588a8`）：`Material.shape` 走
          // squircle，裁切（Clip.antiAlias）与外形同源，ListTile/Switch 等
          // 仍拿到 Material 祖先。半径不变（分组卡仍 20）。
          shape: const MiSquircleBorder(SettingsKitMetrics.cardRadius),
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
        // 卡间距 = 上游「我的」页的 14（组标题不在卡内时，分组间距全由它承担）。
        const SizedBox(height: 14),
      ],
    );
  }
}

/// 设置行：彩色圆角方形图标块 + 主文案（+ 副标题）+ 右侧「值 + 前进箭头」或
/// 自定义控件。形态与点击反馈**对齐上游「我的」页**（见 [SettingsKitMetrics]）。
///
/// **点击反馈 = 整行满铺高亮带**（`AnimatedContainer` 底色，120ms easeOut 渐隐，
/// 方角、与卡片同宽、压在图标与文字之下、随卡片圆角裁切）——上游同款，
/// **不是 `InkWell` 水波纹**。
class SettingsTile extends StatefulWidget {
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

  /// 主标题（上游口径：16 / w400）。
  final String title;

  /// 副标题（可选；13，前景 55% 墨）。
  final String? subtitle;

  /// 右侧当前值（可选，14，前景 55% 墨）；有 [onTap] 时表示「可点进选择」。
  final String? value;

  /// 整行点击；为空则本行不可点（此时右侧画前进箭头——除非给了 [trailing]）。
  ///
  /// 可与 [trailing] 同时给（如「开关行」：点开关或点整行都能切换）；
  /// 但不能与 [value] 同时给（「值 + 箭头」与「自定义右侧控件」互斥）。
  final VoidCallback? onTap;

  /// 完全自定义的右侧控件（如 Switch）。**与 [value] 互斥**；给了它就不画箭头。
  final Widget? trailing;

  /// 是否可用；不可用时整体降透明度且不响应点击 / 不起高亮带。
  final bool enabled;

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  /// 按压态（驱动整行高亮带；松开 / 取消后渐隐）。
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onTap == null || !widget.enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    assert(
      widget.trailing == null || widget.value == null,
      'SettingsTile：trailing（自定义右侧）与 value（「值 + 箭头」）互斥。',
    );
    final ThemeData theme = Theme.of(context);
    final Color fg = theme.colorScheme.onSurface;
    // 不可用态：与 Material 的 disabled 口径一致（0.38 不透明度）。
    final Color titleColor = widget.enabled
        ? fg
        : fg.withValues(alpha: 0.38);
    final Color sub = widget.enabled
        ? fg.withValues(alpha: 0.55)
        : fg.withValues(alpha: 0.38);
    final Color chevronColor = fg.withValues(alpha: 0.30);

    final Widget row = AnimatedContainer(
      duration: SettingsKitMetrics.pressDuration,
      curve: Curves.easeOut,
      // 高亮带经 `decoration` 传色（而不是 `color:`）：`AnimatedContainer` 不公开
      // `color` 字段，契约测试读不到——`decoration` 是公开字段，压色可被钉住。
      decoration: BoxDecoration(
        color: _pressed
            ? SettingsKitMetrics.pressFor(theme.brightness)
            : Colors.transparent,
      ),
      constraints: const BoxConstraints(
        minHeight: SettingsKitMetrics.rowMinHeight,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: widget.subtitle == null ? 0 : 10,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: SettingsKitMetrics.tileSide,
            height: SettingsKitMetrics.tileSide,
            decoration: BoxDecoration(
              color: widget.enabled
                  ? widget.accent
                  : widget.accent.withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(
                SettingsKitMetrics.tileRadius,
              ),
            ),
            child: Icon(widget.icon, size: 22, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: titleColor,
                  ),
                ),
                if (widget.subtitle != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    widget.subtitle!,
                    style: TextStyle(fontSize: 13, color: sub),
                  ),
                ],
              ],
            ),
          ),
          if (widget.value != null) ...<Widget>[
            const SizedBox(width: 8),
            Text(widget.value!, style: TextStyle(fontSize: 14, color: sub)),
          ],
          if (widget.trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            widget.trailing!,
          ] else if (widget.onTap != null) ...<Widget>[
            const SizedBox(width: 10),
            // chevron 墨盒 11.7×21.3（前进箭头 = 返回箭头的水平镜像，上游
            // `5fb8199` 修正：行尾饰不再误用顶栏返回箭头「‹」）。
            SizedBox(
              width: SettingsKitMetrics.chevronWidth,
              height: SettingsKitMetrics.chevronHeight,
              child: CustomPaint(
                painter: ForwardChevronIconPainter(chevronColor),
              ),
            ),
          ],
        ],
      ),
    );

    return Semantics(
      button: widget.onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: row,
      ),
    );
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

/// 弹出设置项单选弹框；返回选中值（取消 / 点遮罩 / 系统返回返回 `null`）。
///
/// 载体 = mi_like_ui [MiDialog]（**纵向操作列表形态**，2026-10-27 拍板「主题
/// 模式弹框也改为 mi_like_ui 弹框」）：与书架长按操作弹框同一形制 ——
/// `showDialog` + **透明路由遮罩**（遮罩由 MiDialog 自绘，两层不可叠加），
/// 当前项以行首 ✓ 标记（组件按「任一项带图标」给全员预留图标位，文字列
/// 对齐不参差），[SettingsPickerOption.description] 走行副标题，点遮罩 /
/// 系统返回 = 取消。
///
/// **档位无关**：MiDialog 不是玻璃件，玻璃开 / 关两档同形；旧的玻璃底部
/// 弹窗载体（`SettingsPickerSheet`）已随之退场 —— `UI-06` ② 的关档退化
/// 路径对本弹框不再适用（它本就不出玻璃）。
Future<T?> showSettingsPicker<T>({
  required BuildContext context,
  required String title,
  required List<SettingsPickerOption<T>> options,
  required T current,
}) {
  return showDialog<T>(
    context: context,
    // 路由遮罩透明：遮罩由 MiDialog 自绘（同 `shelf_page._showBookActions`）。
    barrierColor: Colors.transparent,
    builder: (BuildContext dialogContext) {
      final MiThemeMode mode =
          Theme.of(dialogContext).brightness == Brightness.light
          ? MiThemeMode.light
          : MiThemeMode.dark;
      return MiDialog(
        layout: MiDialogLayout.list,
        title: title,
        themeMode: mode,
        items: <MiDialogItem>[
          for (final SettingsPickerOption<T> option in options)
            MiDialogItem(
              label: option.label,
              subtitle: option.description,
              // 当前项行首 ✓（行组件无 trailing 槽，勾随行墨色，不另配强调色）。
              icon: option.value == current
                  ? const Icon(Icons.check, size: 22)
                  : null,
              onPressed: () => Navigator.of(dialogContext).pop(option.value),
            ),
        ],
        // 点遮罩 = 取消（pop 无值；与系统返回同路）。
        onScrimTap: () => Navigator.of(dialogContext).pop(),
      );
    },
  );
}
