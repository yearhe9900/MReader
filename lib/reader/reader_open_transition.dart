// 开书转场：书架 → 阅读页的**整页「纸张滑入」**（2026-10-09 重做）。
//
// ## 形态（对参考动效逐帧量化，见 §2.77）
//
// | 项 | 实测（参考动效 444×960 @24fps，共 105 帧） |
// |---|---|---|
// | 形态 | 阅读页作为**一整张纸从右侧平移**到左，铺满屏幕 |
// | 时长 | 11 帧 ≈ **460ms** |
// | 曲线 | **easeOutCubic**（半程已走 87.5%，后段只剩收尾） |
// | 圆角 | 全程恒定 **70px**（占屏宽 15.8%），**平移到位的那一帧**才收到 0 |
// | 高度 | 满高（纸顶 == 屏幕顶，盖住状态栏） |
// | 背景 | 书架**静止不动**，被黑色遮罩按滑入进度压暗，终值 **54%** ⚠️见下 |
// | 纸上 | 直接是阅读页本体（**正文已经就绪**） |
//
// ⚠️ **「书架静止」一条已订正（§2.78 §5）**：回头抽帧复核原始参考视频的量测显示，
// 参考动效里书架是**左移**的（tab 行两处特征独立量得 −69 / −76px ≈ 屏宽 16~17%，
// 未读徽标同向 −68px），并伴随压暗。本实现当时按「静止」做了，**是否补这条视差
// 待拍板**（挂账 #10）。另：该动效更可能是**系统窗口动画**而非 App 代码——
// 本地四份 legado 系源码里开书一律 `startActivity`，零应用层动画。
//
// ## 为什么是「先按住，就绪后再滑」（同日修「打开书闪一下」）
//
// 第一版是「点书立刻滑入」，真机录屏逐帧量出**必现的亮度过冲**：
//
// ```
// 书架 97.3 → 57.0 → 37.5 → 31.3（比阅读页稳态还暗）→ 46.1 → 44.6（稳态）
// ```
//
// 根因：转场那 460ms 里**阅读页还没完成首帧渲染**，`ClipRRect` 里那张「纸」是
// **空的（透明的）**——屏幕上只剩「被 scrim 压暗的书架」，于是整屏先暗后亮 = 闪一下。
// 两条独立证据：① 最暗那帧里书卡 / tab **全部完整可见、却又整体变暗** ⇒ 没有任何
// 东西盖住书架；而由 scrim alpha 反推纸张当时**已铺 77%**，却看不见 ⇒ 它就是空的。
// ② 纸铺满后仍是「深色空白 + 白 spinner」（亮度 ≈18），正文一来就跳到 ≈42。
//
// 参考动效之所以不闪，是因为它的纸上**已经有正文**（浅色主题：纸 180 / 书架 97，
// 亮度接近）；MReader 深色主题下书架 97 / 阅读页 44 / 空纸 18，同样的做法就把
// 「旧页面退后」放大成了「整屏变暗」。
//
// 所以：**点书后先把转场按住**（纸张停在屏幕右侧之外、一点都不压暗书架），等阅读页
// 首帧真正上屏再放行——纸滑进来时上面已经是正文，没有空纸期。
//
// ## 门闸（`ReaderOpenTransition`）的语义
//
// 它只回答「阅读页好了没有」，与遮罩无关：**按住的是路由动画本身**
// （`hold()` / `release()` 作用在 `PageRoute` 的 `AnimationController` 上），
// 所以等待期 `ModalRoute.opaque` 一直是 false —— 下层书架继续绘制，而我们
// **一行代码都没碰它**（这正是「覆盖式」而非「推出式」转场的实现基础）。
//
// 就绪信号由 `ReaderPage` 在**正文那一帧的帧后回调**里发出（不是 `_ready`
// 的 `setState` 那一刻：那时正文还没 paint）；转场侧另有 [kReaderOpenHoldTimeout]
// 兜底，防某条异常路径漏报把书卡在打不开的状态。
//
// ## 与既有链路的关系
//
// · 路由仍是 [Navigator.push] + [PageRoute]，返回手势 / 预测性返回行为**完全不变**；
// · 阅读页内部逻辑**零改动**，本转场只在**上层**加位移与遮罩。

import 'dart:async';

import 'package:flutter/material.dart';

/// 纸张滑入时长：对齐参考动效的 11 帧 ≈ 460ms。
const Duration kReaderOpenDuration = Duration(milliseconds: 460);

/// 返回（纸张右移滑出）时长：比进入略快，收得干脆。
const Duration kReaderOpenReverseDuration = Duration(milliseconds: 320);

/// 纸张圆角半径：参考动效实测 70px（屏宽 444px 的 15.8%）。
const double kReaderPaperRadius = 70;

/// 背景书架被压暗的**终值** alpha：参考动效实测 0.54（白光 247 → 118）。
const double kReaderOpenScrimAlpha = 0.54;

/// 圆角收回的起点进度。
///
/// 参考动效里圆角是**一直保持 70px 直到平移到位**的：第 65 帧纸张左缘已贴屏幕左边
/// （x=2）而圆角仍是 72px，第 66 帧突变为 0。所以**不能**用「圆角随进度线性收」——
/// 那会让滑入中段的左上角圆弧一路变小，与参考动效不符。这里把收回压缩在进度最后
/// 1% 之内，观感即「落位瞬间收角」。
const double _kRadiusSettleFrom = 0.99;

/// 「按住」的最长等待：超过就无条件放行。
///
/// 阅读页正常 300ms 内就会上报就绪；这条只防「某条异常路径漏报」——
/// 转场被按住时没有任何其他退出路径，漏报 = 书永远打不开。
const Duration kReaderOpenHoldTimeout = Duration(seconds: 3);

/// 开书转场的**门闸**：阅读页 ⇄ 转场之间的唯一通信面（只回答「好了没有」）。
///
/// 阅读页不该知道「自己是从书架推过来的」，它只负责「我准备好了没有」；
/// 深链 / 测试直进阅读页时门闸是 no-op（零开销、行为不变）。
///
/// 登记带 **owner 令牌**：理论上可能有两个阅读页路由同时在转场（连点两次书卡），
/// 撤销时只清自己那一份，避免后一个 dispose 把前一个的登记抹掉（那会让前一本书
/// 一直按到超时才开）。
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
  /// 两件事一起做才叫「按住」：
  /// · **冻住进度**——否则那 460ms 会照常跑完，纸带着一张空白滑进来（旧缺陷）；
  /// · **让状态停在 `forward`**——`opaque` 只在动画走到 `completed` 时才被置回 true
  ///   （见 `TransitionRoute._handleStatusChanged`）。状态一旦 completed，下层书架
  ///   就不再绘制，屏幕会直接空掉。
  ///
  /// 返回 `false` 的两种情况：控制器还没建（理论上不会），或进度已经到 1——
  /// 那时 `opaque` 已经是 true，硬把纸挪回屏幕外只会露出一块空白，不如照常渲染。
  ///
  /// `canceled: false` 的作用**不是**「让 push 的 future 悬着」（这一点容易想错）：
  /// `whenCompleteOrCancel` 走的是 `TickerFuture.orCancel`，而 `_complete()` 与
  /// `_cancel()` 都会让它结算，`Navigator` 的 `pushing → idle` 两种取值下都会提前
  /// 发生。区别只在 `true` 会让 `orCancel` 以 `TickerCanceled` 收场（多一条错误
  /// 路径），`false` 干净地完成。
  bool hold() {
    final AnimationController? controller = _controller;
    if (controller == null || controller.value >= 1) return false;
    controller.stop(canceled: false);
    return true;
  }

  /// 放行：纸张带着**已经渲染好的正文**从起点滑入（完整 460ms）。
  ///
  /// 返回**是否真的起跑了**。被返回手势打断时不跑（见下），返回 `false`。
  bool release() {
    final AnimationController? controller = _controller;
    // 已经被返回手势打断（状态不再是 `forward`）就不要再起跑：那时路由正在退出，
    // 起跑会把这次返回永远收不了尾，并且在一个正在拆卸的路由上点着 ticker——
    // `AnimationController.dispose` 那句「disposed with an active Ticker」断言会直接炸。
    //
    // 本工作区构造不出这条路径（两个上报点——`ReaderPage._signalOpenReady` 与超时
    // 闹钟——都自带 mounted/dispose 闸，转场被拆时都先失效），留着是防以后新增
    // 上报点绕过那道闸。
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
  /// 用标志位而不是把控制器的 `value` 写成 0：`initState` 跑在 build 相位，而
  /// `value` 的 setter 会 `notifyListeners()`——转场层的祖先 `_ModalScope` 也在听
  /// 这个控制器，在 build 相位标记祖先需要重建会直接抛「setState() or
  /// markNeedsBuild() called during build」。放行时 `forward(from: 0)` 再把控制器
  /// 拉回起点，两边就一致了。
  ///
  /// 另：`hold()` 落在路由入栈后的**第一帧**，那时控制器的值本来就恰好是 0
  /// （`_startSimulation` 把值置为 `simulation.x(0)`，而 push 不在帧内 ⇒ 首次 tick
  /// 的 elapsed 也是 0），所以这一条在本工作区量不出与「直接读 `animation.value`」
  /// 的差别（见 §2.77）。留着它是为了把「按住期间 p 必须是 0」
  /// 这条口径写在代码里，而不是靠「恰好为 0」的推论。
  bool _held = false;

  /// 是否登记进了 [ReaderOpenTransition]（只撤销自己登记的那一份）。
  bool _armed = false;

  /// 漏报就绪信号的兜底闹钟。
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    // 先按住。等待期屏幕上**只有书架本身**——不会先出现一个变暗的空屏，
    // 这正是「打开书闪一下」的修法（见文件头注）。
    _held = widget.route.hold();
    if (!_held) return;
    _armed = true;
    ReaderOpenTransition.arm(this, _release);
    // `Timer` 而不是 `Future.delayed`：`dispose` 里必须能撤掉它——`testWidgets`
    // 跑在 `FakeAsync` 里，留着未清的挂起物会直接把测试判红。
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
    // 先让路由决定要不要起跑：被返回手势打断时它会拒绝，此时**保持按住**，
    // 视觉继续停在 p == 0（别把纸从半路露出来），超时兜底也继续留着。
    if (!widget.route.release()) return;
    _timeout?.cancel();
    _timeout = null;
    // 不需要为进度 setState（进度由 `animation` 驱动，`AnimatedBuilder` 自己会重建），
    // 但 `_held` 变了，必须重建这一层。
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
            // 背景：书架**不动**，只被压暗（alpha 随滑入进度线性增长到 54%）。
            // 等待期（p == 0）alpha 也是 0 ⇒ 一点都不会先暗下去。
            ColoredBox(
              color: Colors.black.withValues(alpha: kReaderOpenScrimAlpha * p),
            ),
            // 纸张：整页平移 + 圆角。`Transform` 只影响绘制与命中测试，不触发布局。
            // `Stack` 默认 `Clip.hardEdge` ⇒ 纸张还停在屏幕右侧之外时天然不可见，
            // 但它的 build / layout / paint 照常发生（阅读页首帧渲染依赖这一点，
            // 也是「等就绪再滑入」能拿到已渲染正文的前提）。
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
