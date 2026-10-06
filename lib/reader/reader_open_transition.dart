// 开书转场：书架封面 → 阅读页的**遮罩交叉淡入**（2026-10-06）。
//
// ## 为什么需要它（性能背景，见 docs/tech-usage.md §2.69 附一~附七）
//
// 真机release 档实测：点书卡到正文上屏约 335~509ms，其中「首帧那一帧的框架
// 任务插队」占~230~290ms（探针已证明**不是**解析：`content()` 内部四段合计
// 0ms）。这段等待**无法消除**（它就是引擎侧首触：字体 / 图片解码器 / Skia 管线），
// 只能被**藏起来**。
//
// 做法：push 一个自定义 [PageRoute]，转场期间在阅读页之上盖一层「封面 + 书名 +
// 载入指示」的遮罩；等阅读页**首帧真正上屏**（`open.firstFrame` 那一刻）再把遮罩
// 淡出。于是：
//   · 用户点下的瞬间就有**连续动效**（封面从书架原位放大淡出），不是白屏 300ms；
//   · 引擎热身插在遮罩**背后**，用户看不见；
//   · 遮罩淡出与正文首帧对齐，不出现「先空一下再出字」的闪跳。
//
// ## 与既有链路的关系
//
// · 路由仍是 [Navigator.push]，返回手势 / 预测性返回行为**完全不变**
//   （不用 [PageRouteBuilder] 的自定义 builder，故不接管系统返回手势）；
// · 阅读页内部逻辑**零改动**：本转场只在**上层**加遮罩；
// · 阅读页通过 [ReaderOpenTransition] 的静态 [hold]/[release] 与本转场通信
//   （阅读页不该反过来 import 书架的转场实现，故走一个独立的门闸对象）。
//
// ## 动画曲线
//
// 遮罩淡出 260ms `easeOutCubic`；封面轻微上移 12px（`transform`，不触发布局）。
// 均为 GPU 合成属性，不引起额外 layout。

import 'package:flutter/material.dart';

/// 开书遮罩的**门闸**（阅读页 ⇄ 转场之间的唯一通信面）。
///
/// 为什么要门闸而不是把回调塞进 `ReaderPage` 构造：阅读页**不应该**知道
/// 「自己是从书架推过来的」——它只负责「我准备好了没有」。门闸让两者解耦，
/// 且深链 / 测试直接进阅读页时门闸为 [disabled]（零开销、行为不变）。
abstract final class ReaderOpenTransition {
  static VoidCallback? _release;

  /// 当前是否有转场在等待（供阅读页判断要不要报「我好了」）。
  static bool get isActive => _release != null;

  /// 门闸已关闭（无转场）：[ReaderPage] 的就绪上报退化为no-op。
  static const VoidCallback disabled = _noop;

  static void _noop() {}

  /// 由转场创建：登记「可以淡出遮罩了」的回调。
  static void arm(VoidCallback onReady) => _release = onReady;

  /// 阅读页首帧就绪时调用；无门闸时是no-op。
  static void signalReady() {
    final VoidCallback? release = _release;
    _release = null; // 一次性，避免重复淡出
    release?.call();
  }

  /// 转场被 dispose（用户立刻返回）时撤销登记，防止泄漏。
  static void disarm() => _release = null;
}

/// 开书转场路由：进入时盖遮罩，[ReaderPage] 首帧就绪后淡出。
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

  /// 遮罩上显示的副标题（通常是「载入中…」之类，可为空）。
  final String? subtitle;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);

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
    // 进入：child（阅读页）本身**不做任何额外动画**——遮罩在上层淡出即可，
    // 免得两层动效打架（参考图式「交叉淡入」的关键是只有遮罩在动）。
    // 阅读页的转场动效由 [kAppPageTransitions] 的平台 builder 提供（主题侧统一
    // 口径，见 app_theme.dart），此处不重复实现。
    return _OpenCoverCurtain(
      route: this,
      animation: animation,
      cover: cover,
      title: title,
      subtitle: subtitle,
      child: child,
    );
  }
}

/// 遮罩层：封面 + 书名 + 细进度指示；就绪后淡出。
class _OpenCoverCurtain extends StatefulWidget {
  const _OpenCoverCurtain({
    required this.route,
    required this.animation,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final ReaderOpenRoute route;
  final Animation<double> animation;
  final Widget cover;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  State<_OpenCoverCurtain> createState() => _OpenCoverCurtainState();
}

class _OpenCoverCurtainState extends State<_OpenCoverCurtain>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    // 遮罩最少停留这么久，避免「闪一下就没」的廉价感。
    duration: const Duration(milliseconds: 260),
  );

  late final Animation<double> _fadeAnim = CurvedAnimation(
    parent: _fade,
    curve: Curves.easeOutCubic,
  );

  /// 进入动画前段（0~0.5）用于封面微上移，纯 transform。
  late final Animation<double> _lift = Tween<double>(begin: 0, end: 1).animate(
    CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.6, curve: Curves.easeOutCubic),
    ),
  );

  @override
  void initState() {
    super.initState();
    // 收到阅读页「首帧就绪」信号后淡出遮罩。
    ReaderOpenTransition.arm(_dismiss);
    // 兜底：若阅读页因异常路径永不上报（如解析失败），转场动画播完也必须撤遮罩，
    // 否则用户会盯着一张封面卡死。
    widget.animation.addStatusListener(_onRouteAnimationStatus);
  }

  @override
  void dispose() {
    ReaderOpenTransition.disarm();
    _fade.dispose();
    super.dispose();
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 首帧就绪信号可能因异常路径缺失；此时仍要撤遮罩。
    _dismiss();
  }

  void _dismiss() {
    if (!mounted) return;
    if (_fade.isCompleted || _fade.isAnimating) return;
    _fade.forward();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Stack(
      children: <Widget>[
        widget.child,
        // 遮罩在阅读页**之上**、在转场进度未完成时始终盖住（progress < 1），
        // 就绪信号到达或转场结束后淡出。
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _fadeAnim,
              builder: (BuildContext context, Widget? inner) {
                final double opacity =
                    (1 - _fadeAnim.value) * widget.animation.value;
                if (opacity <= 0.001) return const SizedBox.shrink();
                return Opacity(opacity: opacity, child: inner);
              },
              child: _CurtainBody(
                lift: _lift,
                cover: widget.cover,
                title: widget.title,
                subtitle: widget.subtitle,
                theme: theme,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 遮罩内容：居中封面 + 书名 + 载入指示。
class _CurtainBody extends StatelessWidget {
  const _CurtainBody({
    required this.lift,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.theme,
  });

  final Animation<double> lift;
  final Widget cover;
  final String title;
  final String? subtitle;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final double t = lift.value;
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: Transform.translate(
          // 轻微上移（transform，不触发布局）。
          offset: Offset(0, -12 * t),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(width: 132, height: 186, child: cover),
              const SizedBox(height: 20),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: 96,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor:
                      theme.colorScheme.onSurface.withValues(alpha: 0.12),
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
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
    );
  }
}
