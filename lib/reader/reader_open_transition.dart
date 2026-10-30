// 开书转场（§2.77，翻页形态修订）：书架 → 阅读页的**书页翻开**。
//
// 形态：阅读页作为**一整页书页**，绕屏幕左缘（书脊）从立着（-90°，投影宽 0
// = 视觉不可见）转到平铺（0°），320ms easeOutCubic + 透视；翻开中页面带背光
// 压暗（立着时最暗、平铺时透明），书架在后被 scrim 压暗至 54%。返回即页面
// 合回书脊（反向旋转，同一转场）。
//
// ⚠️ §2.78 §5 订正：参考动效里书架其实同向**左移**并伴压暗（本实现按「静止」做了），
// **是否补这条视差待拍板**（挂账 #10）。
//
// 「先按住，就绪后再翻」：若转场播完时阅读页首帧未渲染，「页」是透明的，屏幕上
// 只剩被 scrim 压暗的书架 ⇒ 实测会整屏先暗后亮闪一下。故点书后先把转场按住
// （页立在书脊上、投影宽恒 0 = 视觉不可见、不压暗书架），等阅读页首帧真正上屏
// 再放行——没有空页期。
//
// 门闸（`ReaderOpenTransition`）只回答「阅读页好了没有」，与遮罩无关：**按住的是
// 路由动画本身**（作用在 `PageRoute` 的 `AnimationController` 上），所以等待期
// `ModalRoute.opaque` 一直是 false——下层书架继续绘制（「覆盖式」而非「推出式」
// 转场的基础）。就绪信号由 `ReaderPage` 在**正文那一帧的帧后回调**里发出（不是
// `_ready` 的 `setState` 那一刻）；另有 [kReaderOpenHoldTimeout] 兜底防漏报卡死。
//
// 「点击即开书」路径（书架延迟书源 [ReaderPage.sourceFuture]）：阅读页先铺骨架屏
// （`_OpenSkeleton`），**骨架首帧上屏即放行翻页**——页不透明（骨架即画），等待
// 全程在翻开后的阅读页里进行；正文就绪后仍被骨架幕布盖到落位收敛才揭幕
//（`ReaderPage._skeletonCover`，防闪屏）。直供书源（深链 / 详情页 / 生词本）
// 仍走「精确落位收敛才放行」的旧口径，本文件的按住语义对它不变。
//
// 路由仍是 [Navigator.push] + [PageRoute]，返回手势 / 预测性返回行为**完全不变**；
// 阅读页内部逻辑**零改动**，本转场只在**上层**加旋转、光影与遮罩。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 翻页动画时长：§2.109 提速拍板——参考动效 11 帧 ≈ 460ms，用户实测「观感偏慢」。
///
/// §2.78 改「先按住、就绪后再翻」后，等待期已不再被动画盖住，翻页只剩「内容
/// 已就绪的登场」——长时长失去「盖住等待」的收益，只贡献拖沓；提速到 320ms
///（约 0.7×）曲线形态（easeOutCubic）不变。
const Duration kReaderOpenDuration = Duration(milliseconds: 320);

/// 返回（页面合回书脊）时长：比进入略快，收得干脆。
const Duration kReaderOpenReverseDuration = Duration(milliseconds: 240);

/// 页面圆角半径：参考动效实测 70px（屏宽的 15.8%）。
const double kReaderPaperRadius = 70;

/// 背景书架被压暗的**终值** alpha（参考动效实测 0.54）。
const double kReaderOpenScrimAlpha = 0.54;

/// 透视强度（`Matrix4` (3,2) 位）：值越大翻开中段的页面被压得越扁（近大远小）。
///
/// 0.0008 是屏宽千 dp 量级下的折中：中段有明显的「页立起来」立体感又不像被
/// 拍扁；0（正交）会让翻开退化成纯 2D 缩放，失去翻页观感。
const double kReaderOpenPerspective = 0.0008;

/// 翻开中页面的**背光压暗**终值 alpha（平铺到位时归 0）：页立着时背光最暗、
/// 翻开渐亮——翻页立体感的主要来源之一。
const double kReaderPageShadeMax = 0.28;

/// 圆角收回的起点进度。
///
/// 圆角**保持 70px 直到平铺到位才突收到 0**，**不能**用「圆角随进度线性收」
///（翻页中段圆弧会一路变小）。这里把收回压在进度最后 1% 之内，
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

  /// 由转场创建：登记「可以放行翻页了」的回调。
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

/// 开书转场路由：阅读页作为一整页书绕左缘书脊翻开铺满，书架静止在后被压暗。
///
/// 与常规路由的区别是**初始不起跑**：路由入栈后动画会被 [hold] 按住，页面立在
/// 书脊上（投影宽 0、不可见）、也不压暗书架；阅读页首帧上屏后由 [release] 放行
/// 才播翻页。
class ReaderOpenRoute extends PageRoute<void> {
  /// 创建开书转场。
  ReaderOpenRoute({required this.builder, this.onPopStarted});

  /// 阅读页构造器。
  final WidgetBuilder builder;

  /// 返回手势 / 系统返回**发起**那一刻的回调（`didPop`，动画起步即调）。
  ///
  /// 书架开书守卫用它在退场**开始**就释放（而非等 `popped` 要等的反向动画落定）：
  /// 页面合回书脊期间书架已可点，守卫晚放 = 关书后首点被吞（见 `shelf_page._openBook`）。
  final VoidCallback? onPopStarted;

  AnimationController? _controller;

  @override
  bool didPop(void result) {
    onPopStarted?.call();
    return super.didPop(result);
  }

  @override
  AnimationController createAnimationController() {
    final AnimationController controller = super.createAnimationController();
    _controller = controller;
    return controller;
  }

  /// 把转场按住在起点，返回**是否真的按住了**。
  ///
  /// 「按住」= **冻住进度**（否则页带着空白翻进来）+ **状态停在 `forward`**（`opaque`
  /// 只在动画 `completed` 时才置回 true，一旦 completed 下层书架不再绘制、屏幕空掉）。
  /// 返回 `false`：控制器还没建，或进度已到 1（那时 `opaque` 已 true）。
  /// 另：`canceled: false` **不是**「让 future 悬着」——`whenCompleteOrCancel`
  /// 在 `_complete()` / `_cancel()` 下都会结算，只是避免 `orCancel` 多一条错误路径。
  bool hold() {
    final AnimationController? controller = _controller;
    if (controller == null || controller.value >= 1) return false;
    controller.stop(canceled: false);
    return true;
  }

  /// 放行：页面带着**已经渲染好的内容**从书脊翻开（完整 320ms）。
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
    // 进入：阅读页**自己**绕书脊翻开，不再另加平台转场（两层动效会打架）。
    return _PageFlipTransition(
      route: this,
      animation: animation,
      child: child,
    );
  }
}

/// 转场本体：底层一块压在书架上的暗化层 + 上层一页绕左缘书脊翻开的圆角纸页。
class _PageFlipTransition extends StatefulWidget {
  const _PageFlipTransition({
    required this.route,
    required this.animation,
    required this.child,
  });

  /// 宿主路由（用于 [ReaderOpenRoute.hold] / [ReaderOpenRoute.release]）。
  final ReaderOpenRoute route;

  /// 路由转场进度 0→1（0 = 页立在书脊上、投影宽 0）。
  final Animation<double> animation;

  /// 阅读页本体（即那一页书）。
  final Widget child;

  @override
  State<_PageFlipTransition> createState() => _PageFlipTransitionState();
}

class _PageFlipTransitionState extends State<_PageFlipTransition> {
  /// 本层是否正被「按住」：按住期间**视觉恒为 p == 0**（页立书脊、不可见）。
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
    // 停在 p == 0（别把页从半路露出来），超时兜底也继续留着。
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
        // 翻页角：p = 0 → -90°（页立书脊、投影宽 0），p = 1 → 0°（平铺满屏）。
        final double angle = (1 - p) * -math.pi / 2;
        // 圆角：全程 70，仅在落位的一瞬间收回（见 [_kRadiusSettleFrom]）。
        final double settle =
            ((p - _kRadiusSettleFrom) / (1 - _kRadiusSettleFrom)).clamp(0.0, 1.0);
        // 背光压暗：页立着时最暗、平铺时透明（翻页立体感）。
        final double shade = kReaderPageShadeMax * (1 - p);
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 背景：书架**不动**，只被压暗（alpha 线性增到 54%）；等待期 p == 0 ⇒ 不先暗。
            ColoredBox(
              color: Colors.black.withValues(alpha: kReaderOpenScrimAlpha * p),
            ),
            // 页面：绕左缘书脊 rotateY + 透视 + 圆角 + 背光。`Transform` 只影响绘制
            // 与命中测试，不触发布局；按住期（页投影宽 0）`IgnorePointer` 让点击
            // 照常落到下层书架（逆变换在 -90° 附近会把命中区映射成一条线，不可靠）。
            IgnorePointer(
              ignoring: _held,
              child: Transform(
                alignment: Alignment.centerLeft,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, kReaderOpenPerspective)
                  ..rotateY(angle),
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(kReaderPaperRadius * (1 - settle)),
                  child: DecoratedBox(
                    // 背光层画在页**之上**、随 ClipRRect 一起被圆角裁切。
                    decoration: BoxDecoration(
                      color: Color.fromRGBO(0, 0, 0, shade),
                    ),
                    child: paper,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
