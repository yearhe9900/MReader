// 开书转场（§2.77）：书架 → 阅读页的**整页「纸张滑入」**。
//
// 形态：整页纸从右侧平移铺满屏，320ms easeOutCubic，圆角恒定 70px、平移到位才收 0，
// 书架在后被 scrim 压暗至 54%，纸上直接是已就绪的阅读页。
//
// ⚠️ §2.78 §5 订正：参考动效里书架其实同向**左移**并伴压暗（本实现按「静止」做了），
// **是否补这条视差待拍板**（挂账 #10）。
//
// 「先按住，就绪后再滑」：若转场播完时阅读页首帧未渲染，「纸」是透明的，屏幕上只剩
// 被 scrim 压暗的书架 ⇒ 实测会整屏先暗后亮闪一下。故点书后先把转场按住（纸停在
// 屏幕右侧之外、不压暗书架），等阅读页首帧真正上屏再放行——没有空纸期。
//
// 门闸（`ReaderOpenTransition`）只回答「阅读页好了没有」，与遮罩无关：**按住的是
// 路由动画本身**（作用在 `PageRoute` 的 `AnimationController` 上），所以等待期
// `ModalRoute.opaque` 一直是 false——下层书架继续绘制（「覆盖式」而非「推出式」
// 转场的基础）。就绪信号由 `ReaderPage` 在**正文那一帧的帧后回调**里发出（不是
// `_ready` 的 `setState` 那一刻）；另有 [kReaderOpenHoldTimeout] 兜底防漏报卡死。
//
// 路由仍是 [Navigator.push] + [PageRoute]，返回手势 / 预测性返回行为**完全不变**；
// 阅读页内部逻辑**零改动**，本转场只在**上层**加位移与遮罩。

import 'dart:async';

import 'package:flutter/material.dart';

/// 纸张滑入时长：§2.109 提速拍板——参考动效 11 帧 ≈ 460ms，用户实测「观感偏慢」。
///
/// §2.78 改「先按住、就绪后再滑」后，等待期已不再被滑入盖住，滑入只剩「内容
/// 已就绪的登场」——长时长失去「盖住等待」的收益，只贡献拖沓；提速到 320ms
/// （约 0.7×）曲线形态（easeOutCubic）不变。
const Duration kReaderOpenDuration = Duration(milliseconds: 320);

/// 返回（纸张右移滑出）时长：比进入略快，收得干脆。
const Duration kReaderOpenReverseDuration = Duration(milliseconds: 240);

/// 纸张圆角半径：参考动效实测 70px（屏宽的 15.8%）。
const double kReaderPaperRadius = 70;

/// 背景书架被压暗的**终值** alpha（参考动效实测 0.54）。
const double kReaderOpenScrimAlpha = 0.54;

/// 圆角收回的起点进度。
///
/// 参考动效圆角**保持 70px 直到平移到位才突收到 0**，**不能**用「圆角随进度线性收」
/// （滑入中段圆弧会一路变小，与参考不符）。这里把收回压在进度最后 1% 之内，
/// 观感即「落位瞬间收角」。
const double _kRadiusSettleFrom = 0.99;

/// 「按住」的最长等待：超过就无条件放行。
///
/// 转场被按住时没有任何其他退出路径，漏报 = 书永远打不开，故超时兜底。
const Duration kReaderOpenHoldTimeout = Duration(seconds: 3);

/// 开书转场的**门闸**：阅读页 ⇄ 转场之间的唯一通信面（只回答「好了没有」）。
///
/// 深链 / 测试直进阅读页时门闸是 no-op。登记带 **owner 令牌**：撤销时只清自己那一份，
/// 避免后一个 dispose 抹掉前一个的登记（那会让前一本书一直按到超时才开）。
abstract final class ReaderOpenTransition {
  static Object? _owner;
  static VoidCallback? _release;

  /// 当前是否有转场在等（供阅读页判断要不要报「我好了」）。
  static bool get isActive => _release != null;

  /// 由转场创建：登记「可以放行滑入了」的回调。
  static void arm(Object owner, VoidCallback onReady) {
    _owner = owner;
    _release = onReady;
  }

  /// 阅读页首帧真正上屏时调用；无门闸时是 no-op。
  static void signalReady() {
    final VoidCallback? release = _release;
    _owner = null;
    _release = null; // 一次性，避免重复放行
    release?.call();
  }

  /// 转场被 dispose（用户立刻返回）时撤销登记，防止泄漏。
  static void disarm(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _release = null;
  }
}

/// 开书转场路由：阅读页作为一整张纸从右侧滑入铺满，书架静止在后被压暗。
///
/// 与常规路由的区别是**初始不起跑**：路由入栈后动画会被 [hold] 按住，纸张停在
/// 屏幕右侧之外、也不压暗书架；阅读页首帧上屏后由 [release] 放行才播滑入。
class ReaderOpenRoute extends PageRoute<void> {
  /// 创建开书转场。
  ReaderOpenRoute({required this.builder});

  /// 阅读页构造器。
  final WidgetBuilder builder;

  AnimationController? _controller;

  @override
  AnimationController createAnimationController() {
    final AnimationController controller = super.createAnimationController();
    _controller = controller;
    return controller;
  }

  /// 把转场按住在起点，返回**是否真的按住了**。
  ///
  /// 「按住」= **冻住进度**（否则纸带着空白滑进来）+ **状态停在 `forward`**（`opaque`
  /// 只在动画 `completed` 时才置回 true，一旦 completed 下层书架不再绘制、屏幕空掉）。
  /// 返回 `false`：控制器还没建，或进度已到 1（那时 `opaque` 已 true，挪回屏幕外只会
  /// 露空白）。另：`canceled: false` **不是**「让 future 悬着」——`whenCompleteOrCancel`
  /// 在 `_complete()` / `_cancel()` 下都会结算，只是避免 `orCancel` 多一条错误路径。
  bool hold() {
    final AnimationController? controller = _controller;
    if (controller == null || controller.value >= 1) return false;
    controller.stop(canceled: false);
    return true;
  }

  /// 放行：纸张带着**已经渲染好的正文**从起点滑入（完整 320ms）。
  /// 返回**是否真的起跑了**；被返回手势打断时不跑，返回 `false`。
  bool release() {
    final AnimationController? controller = _controller;
    // 已被返回手势打断（状态不再是 `forward`）就不要再起跑：路由正在退出，起跑会把
    // 返回收不了尾，并在一个正在拆卸的路由上点着 ticker——`dispose` 的「disposed with
    // an active Ticker」断言会炸。现有上报点都自带 mounted/dispose 闸，此处防以后
    // 新增上报点绕过那道闸。
    if (controller == null || controller.status != AnimationStatus.forward) {
      return false;
    }
    // `from: 0` 而不是空参：把控制器拉回起点，与按住期间「视觉恒为 p == 0」对齐。
    controller.forward(from: 0);
    return true;
  }

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => kReaderOpenDuration;

  @override
  Duration get reverseTransitionDuration => kReaderOpenReverseDuration;

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
    // 进入：阅读页**自己**平移进来，不再另加平台转场（两层动效会打架）。
    return _PaperSlideTransition(
      route: this,
      animation: animation,
      child: child,
    );
  }
}

/// 转场本体：底层一块压在书架上的暗化层 + 上层一张从右平移进来的圆角纸。
class _PaperSlideTransition extends StatefulWidget {
  const _PaperSlideTransition({
    required this.route,
    required this.animation,
    required this.child,
  });

  /// 宿主路由（用于 [ReaderOpenRoute.hold] / [ReaderOpenRoute.release]）。
  final ReaderOpenRoute route;

  /// 路由转场进度 0→1（0 = 纸张完全在屏幕右侧之外）。
  final Animation<double> animation;

  /// 阅读页本体（即那张「纸」）。
  final Widget child;

  @override
  State<_PaperSlideTransition> createState() => _PaperSlideTransitionState();
}

class _PaperSlideTransitionState extends State<_PaperSlideTransition> {
  /// 本层是否正被「按住」：按住期间**视觉恒为 p == 0**。
  ///
  /// 用标志位而不是把控制器 `value` 写 0：`value` setter 会 `notifyListeners()`，
  /// 而 `initState` 跑在 build 相位，标记祖先 `_ModalScope` 重建会抛「setState() or
  /// markNeedsBuild() called during build」。放行时 `forward(from: 0)` 再拉回起点即一致。
  bool _held = false;

  /// 是否登记进了 [ReaderOpenTransition]（只撤销自己登记的那一份）。
  bool _armed = false;

  /// 漏报就绪信号的兜底闹钟。
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    // 先按住。等待期屏幕上**只有书架本身**——不会先出现一个变暗的空屏（「打开书
    // 闪一下」的修法，见文件头注）。
    _held = widget.route.hold();
    if (!_held) return;
    _armed = true;
    ReaderOpenTransition.arm(this, _release);
    // `Timer` 而不是 `Future.delayed`：`dispose` 里必须能撤掉它（`testWidgets` 跑在
    // `FakeAsync` 里，未清的挂起物会把测试判红）。
    _timeout = Timer(kReaderOpenHoldTimeout, _release);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _timeout = null;
    if (_armed) {
      _armed = false;
      ReaderOpenTransition.disarm(this);
    }
    super.dispose();
  }

  void _release() {
    if (!mounted || !_held) return;
    // 先让路由决定要不要起跑：被返回手势打断时它会拒绝，此时**保持按住**，视觉继续
    // 停在 p == 0（别把纸从半路露出来），超时兜底也继续留着。
    if (!widget.route.release()) return;
    _timeout?.cancel();
    _timeout = null;
    // 不需要为进度 setState（`AnimatedBuilder` 自己会重建），但 `_held` 变了须重建。
    setState(() => _held = false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.child,
      builder: (BuildContext context, Widget? paper) {
        // 参考动效的位移曲线是 easeOutCubic：半程已走 87.5%。
        final double p =
            Curves.easeOutCubic.transform(_held ? 0 : widget.animation.value);
        final double width = MediaQuery.sizeOf(context).width;
        // 圆角：全程 70，仅在落位的一瞬间收回（见 [_kRadiusSettleFrom]）。
        final double settle =
            ((p - _kRadiusSettleFrom) / (1 - _kRadiusSettleFrom)).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 背景：书架**不动**，只被压暗（alpha 线性增到 54%）；等待期 p == 0 ⇒ 不先暗。
            ColoredBox(
              color: Colors.black.withValues(alpha: kReaderOpenScrimAlpha * p),
            ),
            // 纸张：整页平移 + 圆角。`Transform` 只影响绘制与命中测试，不触发布局。
            // `Stack` 默认 `Clip.hardEdge` ⇒ 纸在屏幕外时天然不可见，但 build / layout /
            // paint 照常发生（阅读页首帧渲染依赖这一点）。
            Transform.translate(
              offset: Offset(width * (1 - p), 0),
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(kReaderPaperRadius * (1 - settle)),
                child: paper,
              ),
            ),
          ],
        );
      },
    );
  }
}
