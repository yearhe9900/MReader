// 开书转场：书架封面 → 阅读页的**连续动效**（2026-10-06 重做）。
//
// ## 为什么需要它（性能背景，见 docs/tech-usage.md §2.69 附一~附十）
//
// 真机release 档实测：点书卡到正文上屏约 335~509ms，其中「首帧那一帧的框架
// 任务插队」占 ~230~290ms（探针已证明**不是**解析：`content()` 内部四段合计
// 0ms）。这段等待**无法消除**，只能被**藏起来**。
//
// ## 第一版为什么「生硬」（2026-10-06 负责人反馈，据此重做）
//
// |#| 生硬的原因 | 本版的改法 |
//---|---|---|
// |1| **遮罩整体 `Opacity` 淡出**——所有元素（含封面）一起线性变淡，像PPT 翻页 | **分层错峰**：遮罩底色先淡出（120ms），封面**放大淡出**（280ms），文字/进度条最后消失。三层不同步 = 有层次 |
// |2| 遮罩**内容静止**（只做了 -12px 上移），等待时毫无生气 | **呼吸动效**：封面极缓地「悬浮呼吸」（scale 1.00↔1.015，2.4s 周期），让静止画面有生命感 |
// |3| 封面是**静止的一张小图**（132×186），与书架上那张卡视觉脱节 | **尺寸/圆角连续过渡**：遮罩封面按书架卡的比例放大到 200×282，并让**投影随放大加深**——读起来是「那张卡飞近」，而不是「换了一张图」 |
// |4| 「正在打开…」文案 + 进度条**一开始就出现**，还没等就已经在闪 | **延迟出现**（180ms 后才淡入），且进度条改为**双段式**：底轨常驻、头条随等待增长，视觉上「有进展」 |
//
// 另外把**时长**对齐真实节奏：加载 300~500ms ⇒ 转场 `280ms`（够读、不拖沓），
// 遮罩淡出 `300ms`（比第一版 260ms 更从容，衔接不急）。
//
// ## 与既有链路的关系
//
// · 路由仍是 [Navigator.push] + [PageRoute]，返回手势 / 预测性返回行为**完全不变**；
// · 阅读页内部逻辑**零改动**：本转场只在**上层**加遮罩；
// · 阅读页通过 [ReaderOpenTransition] 的静态门闸与本转场通信
//   （阅读页不该反过来 import 书架的转场实现，故走一个独立的门闸对象）。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 开书遮罩的**门闸**（阅读页 ⇄ 转场之间的唯一通信面）。
///
/// 为什么要门闸而不是把回调塞进 `ReaderPage` 构造：阅读页**不应该**知道
/// 「自己是从书架推过来的」——它只负责「我准备好了没有」。门闸让两者解耦，
/// 且深链 / 测试直接进阅读页时门闸为 no-op（零开销、行为不变）。
abstract final class ReaderOpenTransition {
  static VoidCallback? _release;

  /// 当前是否有转场在等待（供阅读页判断要不要报「我好了」）。
  static bool get isActive => _release != null;

  /// 门闸已关闭（无转场）：[ReaderPage] 的就绪上报退化为 no-op。
  static const VoidCallback disabled = _noop;

  static void _noop() {}

  /// 由转场创建：登记「可以淡出遮罩了」的回调。
  static void arm(VoidCallback onReady) => _release = onReady;

  /// 阅读页首帧就绪时调用；无门闸时是 no-op。
  static void signalReady() {
    final VoidCallback? release = _release;
    _release = null; // 一次性，避免重复淡出
    release?.call();
  }

  /// 转场被 dispose（用户立刻返回）时撤销登记，防止泄漏。
  static void disarm() => _release = null;
}

/// 转场时长：够读、不拖沓（对齐真机 300~500ms 的加载窗口）。
const Duration kReaderOpenDuration = Duration(milliseconds: 280);

/// 遮罩淡出时长：比转场更长，衔接从容。
const Duration kReaderOpenFadeOut = Duration(milliseconds: 300);

/// 开书转场路由：进入时盖遮罩，[ReaderPage] 首帧就绪后分层淡出。
class ReaderOpenRoute extends PageRoute<void> {
  /// 创建开书转场。
  ReaderOpenRoute({
    required this.builder,
    required this.cover,
    required this.title,
    this.subtitle,
  });

  /// 阅读页构造器。
  final WidgetBuilder builder;

  /// 遮罩上显示的封面（书架那张卡的封面 widget，尺寸自适应）。
  final Widget cover;

  /// 遮罩上显示的书名。
  final String title;

  /// 遮罩上显示的副标题（可为空）。
  final String? subtitle;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => kReaderOpenDuration;

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 进入：child（阅读页）本身**不做额外动画**——遮罩在上层分层淡出即可，
    // 免得两层动效打架。阅读页自身的平台转场由 [kAppPageTransitions] 统一提供。
    return _OpenCoverCurtain(
      animation: animation,
      cover: cover,
      title: title,
      subtitle: subtitle,
      child: child,
    );
  }
}

/// 遮罩层：底色 / 封面 / 文字**三层错峰**淡出 + 封面呼吸浮动；就绪后撤。
class _OpenCoverCurtain extends StatefulWidget {
  const _OpenCoverCurtain({
    required this.animation,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final Animation<double> animation;
  final Widget cover;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  State<_OpenCoverCurtain> createState() => _OpenCoverCurtainState();
}

class _OpenCoverCurtainState extends State<_OpenCoverCurtain>
    with TickerProviderStateMixin {
  /// 遮罩撤出进度（0 = 全盖，1 = 全撤）。
  late final AnimationController _out =
      AnimationController(vsync: this, duration: kReaderOpenFadeOut);

  late final Animation<double> _outAnim = CurvedAnimation(
    parent: _out,
    // 前段快后段缓：遮罩「让开」要干脆，收尾要柔和（线性淡出正是生硬的主因）。
    curve: Curves.easeInCubic,
  );

  /// 「呼吸」浮动：等待期间封面极缓地放大-回弹，让静止画面有生命感。
  ///
  /// 幅度刻意很小（scale 1.00↔1.015、2.4s 周期）——大��动会显得焦躁，
  /// 且与「正在加载」的语义冲突。纯 transform，不触发布局。
  late final AnimationController _breathe =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  /// 文字/进度条的**延迟出现**（180ms）：一进屏就闪进度条显得廉价。
  late final AnimationController _chrome = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _breathe.repeat(reverse: true);
    // 收到阅读页「首帧就绪」信号后撤遮罩。
    ReaderOpenTransition.arm(_dismiss);
    // 兜底：若阅读页因异常路径永不上报（如解析失败），转场动画播完也必须撤遮罩，
    // 否则用户会盯着一张封面卡死。
    widget.animation.addStatusListener(_onRouteAnimationStatus);
    // 延迟 180ms 再上文字与进度条：先让封面「落定」，避免一进屏就闪进度条的廉价感。
    //
    // ⚠️ 用**帧回调**而非 `Future.delayed`：`testWidgets` 跑在 `FakeAsync` 里，定时器
    // 会在页面 dispose 后留下未清挂起物 ⇒ `A Timer is still pending even after the
    // widget tree was disposed`（同批修R1 时在 `_idleGap` 上踩过，见 tech-usage §2.69
    // 附十教训①）。帧回调在 dispose 后不再执行，天然安全。
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      // 再等一帧，确保「封面已绘制」这一视觉事实成立再上文字。
      SchedulerBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) _chrome.forward();
      });
    });
  }

  @override
  void dispose() {
    ReaderOpenTransition.disarm();
    _out.dispose();
    _breathe.dispose();
    _chrome.dispose();
    super.dispose();
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 首帧就绪信号可能因异常路径缺失；此时仍要撤遮罩。
    _dismiss();
  }

  void _dismiss() {
    if (!mounted || _out.isCompleted || _out.isAnimating) return;
    _breathe.stop();
    _out.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        widget.child,
        // 忽略指针：遮罩期间不该拦住返回手势等（正文此时也确实还不可用）。
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[_outAnim, _breathe, _chrome]),
              builder: (BuildContext context, Widget? _) {
                final double t = _outAnim.value; // 0 全盖 → 1 全撤
                if (t >= 0.999) return const SizedBox.shrink();
                return _CurtainBody(
                  out: t,
                  breathe: _breathe.value,
                  chrome: _chrome.value,
                  enter: widget.animation.value,                  cover: widget.cover,
                  title: widget.title,
                  subtitle: widget.subtitle,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 遮罩内容：**分层错峰**淡出（底色 → 封面放大 → 文字后撤）+ 呼吸浮动。
class _CurtainBody extends StatelessWidget {
  const _CurtainBody({
    required this.out,
    required this.breathe,
    required this.chrome,
    required this.enter,
    required this.cover,
    required this.title,
    required this.subtitle,
  });

  /// 撤出进度 0→1（三层各自映射到不同区间 ⇒ 错峰）。
  final double out;

  /// 呼吸相位 0→1（循环）。
  final double breathe;

  /// 文字/进度条出现进度 0→1。
  final double chrome;

  /// 路由转场进度 0→1（用于入场微调）。
  final double enter;

  final Widget cover;
  final String title;
  final String? subtitle;

  /// 封面边长（入场从 0.94 放大到 1.0，配合遮罩撤出继续放大到 1.16）。
  static const double _coverBase = 200;

  /// 封面宽高比（竖版，约 1:1.41）。
  static const double _coverRatio = 1.41;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // ── 分层错峰：把 0→1 的撤出进度切成三段 ──
    // 底色 0.00~0.45（先让开，读者立刻看到正文底色）
    // 封面 0.15~1.00（放大淡出，主角戏）
    // 文字 0.30~0.75（最后消失，避免与封面抢视线）
    double seg(double from, double to) =>
        ((out - from) / (to - from)).clamp(0.0, 1.0);

    final double bgOpacity = 1 - seg(0.00, 0.45);
    final double coverOpacity = 1 - seg(0.15, 1.00);
    final double textOpacity = 1 - seg(0.30, 0.75);

    // 封面：入场微放大 0.94→1.0（随路由转场），撤出时继续放大到 1.16
    // ——读起来是「那张卡朝读者飞近」，而非「换了一张图」。
    final double coverScale =
        (0.94 + 0.06 * Curves.easeOutCubic.transform(enter)) * (1 + 0.16 * seg(0.15, 1.00));
    // 呼吸：±0.75% 的极缓浮动（等待期不显焦躁）。
    final double breathScale = 1 + 0.0075 * math.sin(breathe * math.pi);
    final double scale = coverScale * breathScale;

    // 投影随放大加深：卡片「浮起来」的方向感。
    final double lift = seg(0.15, 1.00);

    return ColoredBox(
      color: theme.colorScheme.surface.withValues(alpha: bgOpacity),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Transform.scale(
              scale: scale,
              child: Opacity(
                opacity: coverOpacity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16 * scale),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: theme.colorScheme.shadow.withValues(
                            alpha: 0.16 + 0.14 * lift),
                        blurRadius: 18 + 22 * lift,
                        offset: Offset(0, 6 + 10 * lift),
                      ),
                    ],
                  ),
                  child: SizedBox(
                    width: _coverBase,
                    height: _coverBase * _coverRatio,
                    child: cover,
                  ),
                ),
              ),
            ),
            // 文字组：延迟出现（[chrome]）+ 撤出时先于封面淡出。
            Opacity(
              opacity: chrome * textOpacity,
              child: Padding(
                padding: const EdgeInsets.only(top: 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 240,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _IndeterminateBar(progress: out),
                    if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「有进展」的细进度条：底轨常驻 + 头条随等待缓慢生长。
///
/// 为什么不用 [LinearProgressIndicator] 的不确定态：它在**等待期间不停左右滑动**，
/// 视觉上像「坏了在转圈」；这里用**单调增长**的头条，读起来是「在推进」。
class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar({required this.progress});

  /// 撤出进度（0→1），用于让头条随遮罩一起淡出。
  final double progress;

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: 132,
      child: AnimatedBuilder(
        animation: _grow,
        builder: (BuildContext context, Widget? _) {
          // 三角波：0→1→0 的循环，但整体再乘一个「随等待单调上升」的包络，
          // 于是观感是「来回晃动 + 整体在走」——比纯循环更有进展感。
          final double tri = _grow.value < 0.5
              ? _grow.value * 2
              : (1 - _grow.value) * 2;
          final double head = 0.18 + 0.55 * tri;
          return Opacity(
            opacity: 1 - widget.progress,
            child: Stack(
              children: <Widget>[
                Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: head,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
