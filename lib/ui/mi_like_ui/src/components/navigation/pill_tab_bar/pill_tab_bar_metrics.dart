/// [MiPillTabBar] 的几何 / 文字参数：1:1 实测自完整分类 tab 截图。
///
/// Source: 1220x2656 px full screenshots of the theme-store 分类 tab
/// (light & dark — geometry identical). Scale to a 393 dp design width:
/// s = 393 / 1220 = 0.32213.
///
/// | item                    | shot px | dp        |
/// |-------------------------|---------|-----------|
/// | pill size               | 272 x 124 | 87.6 x 39.9 |
/// | pill gap                | 37      | 11.9      |
/// | strip edge inset        | 37      | 11.9      |
/// | label pitch (CJK em)    | 43      | 13.85     |
///
/// 实测要点：
///  * 4 个胶囊等宽定宽（2 字与 3 字标签同宽），不随标签字数变化；
///  * 标签行横向可滚动 —— 第 4 个胶囊被屏幕右缘裁切 16px（行内容宽
///    11.9 + n×87.6 + (n-1)×11.9 + 11.9 = 410dp 超出 393dp 视口）；
///  * 胶囊为 stadium 形：圆角外缘拟合 R=63px ≈ 高/2(62px)，取
///    [MiDimens.radiusPill]（半径钳位后渲染即 stadium）；纯平填充，
///    无描边无投影；
///  * 标签字重 Medium（笔画核心 3~4px @ 43px em ≈ 0.08em）。
///
/// 注：初版按 1220x266 裁剪图实测（276x125 / 32.5 / 34.5 / 裁切 17.5），
/// 该裁剪图被编辑放大 ~1.5%，数值整体偏大且间距失真，已废弃；
/// 本表以完整原图为准（881x1920 副本等比复核一致）。
///
/// 文字样式见 `theme/typography.dart`，配色见 `theme/pill_tab_tokens.dart`。
class MiPillTabMetrics {
  MiPillTabMetrics._();

  /// 单个胶囊宽度（定宽，不随标签字数变化）。
  static const double itemWidth = 87.6;

  /// 胶囊高度。
  static const double pillHeight = 39.9;

  /// 相邻胶囊间距。
  static const double gap = 11.9;

  /// 标签行首/尾内边距（横滑内容区，与搜索框等页面内容同为 37px 页边距）。
  static const double edgeInset = 11.9;

  /// 选中态填充切换过渡 200ms `easeOut`（**推导值**：素材无切换帧；与
  /// `MiButton` 按压同值同曲线，构成胶囊类控件的统一淡变档）。
  static const int fillFadeMs = 200;

  // ── 自适应宽度档（issue #3，全部为**推导值**：素材只有定宽形态）────────
  //
  // 下游 MReader 书架头部用「全部 + 分组名」展示，分组名长短不一：定宽下
  // 短标签两侧大量留白、长标签只能省略号截断。自适应档按下式取宽：
  //
  //   胶囊宽 = clamp(标签文字自然宽 + 2×[adaptiveTextInset],
  //                  minItemWidth, maxItemWidth)

  /// 自适应档胶囊宽度上限 = 2×[itemWidth] = 175.2（推导：下游目测档，短标签
  /// 留白与长标签可读性的折中；超过则省略号截断）。
  static const double adaptiveMaxWidth = 2 * itemWidth;

  /// 自适应档标签两侧内缩 16（推导，下游同款）。
  static const double adaptiveTextInset = 16.0;

  // ── 胶囊行区膜带（issue #4①，推导值）────────────────────────────────

  /// `overContent` 膜带的上下缘羽化高（0 = 均匀铺满）。
  ///
  /// 曾取 8dp（推导：与头部磨砂羽化同语言），**实机截图否定**：8dp 羽化
  /// 吃掉 40dp 胶囊的上下各 1/3，膜几乎不在——彩色内容从胶囊上下三分之
  /// 一直接透出（实测文字带之外局部 t≈0.4+），胶囊像透明窗口（
  /// 2026-10-28 实机反馈「顶部胶囊透明磨砂异常」）。参考的胶囊膜是
  /// **均匀铺满**的（原逐胶囊预合成 `veiledFill` 无羽化，胶囊边缘是
  /// 4…6px 的干净压暗阶跃）→ 归零，保留 token 以便后续拿到膜带样张
  /// 后再开羽化。
  static const double veilFeatherHeight = 0.0;
}

/// 胶囊宽度模式（issue #3）。
enum MiPillItemWidth {
  /// 定宽（默认）：全部胶囊 = [MiPillTabMetrics.itemWidth]（度量 87.6，
  /// 现有行为逐像素不变）。
  fixed,

  /// 自适应：`clamp(标签文字自然宽 + 2×textInset, minItemWidth,
  /// maxItemWidth)`，超过上限以省略号截断；多胶囊仍同一栅格
  /// （填充 / 磨砂裁形 / 内缘亮边三遍对齐同一宽序列）。
  adaptive,
}
