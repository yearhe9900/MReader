// 阅读页控制条的**分组 chrome**：分组盒 / 分隔线 / 统一尺寸的图标按钮 / 顶栏分组。
//
// 三个文件共用（`control_bar.dart` 的「章节」「朗读与 AI」两组 + `reader_settings_bar.dart`
// 的「排版」组 + `reader_page.dart` 顶栏三组），以保证「同一层级的控件同尺寸、
// 同分组样式」——分组依据与布局口径见 §2.68。
//
// 尺寸取舍（为什么不是 Material 默认 48）：控制条一行要塞「章节 / 朗读与 AI」两组共
// 5 个按钮，48dp 时一行放不下（实测窄屏溢出）、按钮被压、组标签被挤没。改 44dp
// （Material 紧凑档下限，仍满足最小可点区域）后同一行留出余量；顶栏按钮保持默认 48。
import 'package:flutter/material.dart';

/// 控制条图标按钮的统一边长（dp）。
///
/// 44 = Material 紧凑档下限。**不要改回 48**：`control_bar.dart` 的第一行放不下
/// （5 个按钮 + 2 个分组盒内边距），改回会把分组标签挤出可视区。
const double kReaderControlButton = 44;

/// 控制条图标的统一字号（dp）。
///
/// 20 = 与 44dp 按钮同比例；比 Material 默认 24 轻，避免一排图标「黑压压」一片。
const double kReaderControlGlyph = 20;

/// 控制条每行上下的**外**留白（dp）。
///
/// 合计 4dp + [kReaderControlButton] 44 = 每行 48dp，**不增加控制条总高**：
/// 控制条是 `bottomNavigationBar`，长高会直接吃掉正文可视高度，让整页图的点击中心
/// 落到条下面（`test/reader/image_pages_test.dart` 验收②因此找不到缩放查看器）。
const double kReaderControlRowPadding = 2;

/// 组标题的**最小可用宽度**（dp）：窄于此宽度时调用方应隐藏文字标题。
///
/// 第一行要放「章节」2 键 + 「朗读与 AI」3 键，两个文字标题各需 ~62dp，加上 5 个
/// 44dp 按钮、两个分组盒内边距与进度读数后**总需求 ≈ 420dp**；低于该宽度仍强留
/// 标题则 `Row` 必然溢出（`test/ui/reader_chrome_layout_test.dart` 宽度阶梯实测）。
///
/// 故窄屏由调用方（[ReaderControlBar] / [ReaderSettingsBar]）按此阈值隐藏**文字**
/// 标题——分组的视觉边界仍由**淡底盒子 + 分隔线**表达（`UI-02` 口径下这才是主手段，
/// 文字标题是锦上添花），符合「空间不足时优先保证层级清晰与内容不重叠」。
const double kReaderControlLabelMinWidth = 420;

/// 控制条内**进度读数**的最小可用宽度（dp），窄于此则不渲染。
///
/// 读数「第 N/M 章 · P%」与控制条**正上方**常驻的 [ReaderProgressIndicator]
/// （`TYP-09`，全屏时也在）是同一串文字。极窄屏上第一行两个分组盒的固定内容已占满
/// （实测会溢出），此时让读数让位、由上方指示器承担同一信息，优于让整行溢出或把
/// 文字压到不可读。
const double kReaderControlProgressMinWidth = 348;

/// 控制条分组盒内的组标题样式（次要色小字）。
TextStyle readerControlLabelStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall!.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.1,
        );

/// 控制条的一个功能分组：淡底圆角盒 + 左侧组标题。
///
/// 「同一用途的控件归到同一个盒子」是本控件的唯一职责——盒子即分组边界，
/// 组标题即层级标识（[label] 缺省时只留盒子，用于宽度紧张的排版组）。
class ReaderControlGroup extends StatelessWidget {
  /// 创建一个分组盒。
  const ReaderControlGroup({
    super.key,
    required this.children,
    this.label,
    this.expand = false,
  });

  /// 组内控件。
  final List<Widget> children;

  /// 组标题（如「章节」「朗读」「排版」）；`null` = 不画标题，只画分组盒。
  final String? label;

  /// 是否吃满可用宽度。
  ///
  /// **外层总分组必须传 `true`**：只有它 `MainAxisSize.max`，内层子组放进
  /// [Expanded]（行距滑块）才有界。传 `false`（默认）时盒子按内容收缩、宽度无界，
  /// 内层放 [Expanded] 会触发 `RenderFlex ... unbounded` 断言。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      // 水平 6 / 垂直 0：垂直内边距取 0 是为「不增加控制条总高」（见
      // [kReaderControlRowPadding]）；水平只留 6 是因为第一行两个分组盒的
      // 4×6=24dp 直接从行距滑块的横向预算里扣（实测窄屏滑块预算很紧）。
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        // 淡底 = 分组的视觉边界；用 `surfaceContainerHighest` 低透明，浅/深色都成立
        // （不指定深浅两套值，避免跟随主题时某一档失去边界）。
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          if (label != null) ...<Widget>[
            Text(label!, style: readerControlLabelStyle(context)),
            const SizedBox(width: 6),
          ],
          ...children,
        ],
      ),
    );
  }
}

/// 控制条内的**竖向**分隔线（同一行内相邻两组之间的边界）。
///
/// 高 28dp：比 44dp 按钮略矮，视觉上退居次要层，不与按钮争注意力。
class ReaderControlVDivider extends StatelessWidget {
  /// 创建一条竖分隔线。
  const ReaderControlVDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).dividerColor.withValues(alpha: 0.45);
    return Container(
      width: 1,
      // 32dp：略高于按钮的视觉重心（按钮 44 但图标只有 20），又不至于顶到行边。
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: color,
    );
  }
}

/// 控制条内的**横向**分隔线（上下两组之间的边界，如「章节/朗读」与「排版」之间）。
class ReaderControlHDivider extends StatelessWidget {
  /// 创建一条横分隔线。
  const ReaderControlHDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Theme.of(context).dividerColor.withValues(alpha: 0.45),
    );
  }
}

/// 控制条内统一尺寸的图标按钮（[kReaderControlButton] × [kReaderControlGlyph]）。
///
/// 全条所有图标按钮都走这里，「统一对齐方式与尺寸」是**构造即保证**的，不靠逐处
/// 记参数；[padding] 归零 + 固定边长，使图标中心在所有按钮间严格对齐。
/// ⚠️ **不要加 `visualDensity: compact`**：`IconButton` 会把它当作在 `constraints`
/// 之外的**额外**收缩量（实测 44 → 40），「常量声明 44、实际 40」尺寸契约与真值
/// 脱钩；紧凑效果已由 [kReaderControlButton] = 44 本身达成。
class ReaderControlIconButton extends StatelessWidget {
  /// 创建一个控制条图标按钮。
  const ReaderControlIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  /// 图标（统一 [kReaderControlGlyph]；动态图标传 [IconData]，本组件负责包 [Icon]）。
  final IconData icon;

  /// 无障碍与长按提示文案（= 原 tooltip，文案不变）。
  final String tooltip;

  /// 点击回调；`null` = 不可用（渲染为灰色，与 Material 口径一致）。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: kReaderControlGlyph),
      padding: EdgeInsets.zero,
      // ⚠️ `tapTargetSize` 只能经 [IconButton.style] 传（构造参数上没有）。
      // 必须 `shrinkWrap`：缺省 `padded` 会在 [constraints] 之外再强制最小 48dp
      // —— 于是「约束写 44、实测 48」，尺寸契约与真值脱钩。
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      constraints: const BoxConstraints.tightFor(
        width: kReaderControlButton,
        height: kReaderControlButton,
      ),
    );
  }
}

/// 顶栏的一个功能分组：组内按钮 + 组间竖分隔线。
///
/// 与控制条的 [ReaderControlGroup] 同一条分组思路，但**不画底色盒子**：AppBar 自身
/// 已有底色，再套一层盒会显得臃肿；这里只用分隔线表达「哪几个按钮是一组」。
/// 第一个分组不画左侧分隔线（否则紧贴返回键，像多出一道无来由的刻度）。
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
