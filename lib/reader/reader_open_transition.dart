// 开书转场（§2.77 起，§2.113 斜向掀开，§2.114 补「页面弯曲 + 逐渐展开」）：
// 书架 → 阅读页的**翻书**。
//
// ── 四个几何口径（改这块前先把这四条对齐）────────────────────────────
//  ① 触发点（起点）= 屏幕**右下角**：点书即从这一角起势，整张纸钉在这点附近。
//  ② 旋转轴（装订边）= 过触发点、沿**反对角线**（屏幕「右上」45°）的直线。选它
//     不是随手：轴线另一半落在**屏幕下方之外**，纸立起来时整个投影退化成那条屏外
//     直线（只擦到右下角一点）⇒ 屏内一像素不露，这是「先按住、等就绪再翻」的前提。
//  ③ 展开方向 = 自右下角向屏幕**左上**铺开：纸从屏外翻进来，自由角（左上，离铰链
//     最远）沿斜向扫进屏内，其余三角随后归位。
//  ④ 结束状态 = **恒等矩阵**：四边贴屏幕四边、圆角收到 0、纸完全平直 ⇒ 与静态阅读
//     页逐像素一致（布局与正文排版全程不受影响，`Transform`/`ClipPath` 只碰绘制）。
//
// ── 「像真书被翻开」而不是「一块板从角上扇出来」─────────────────────
// 只有刚性旋转时，纸是一块没有厚度的板——这就是「生硬」的另一半。真实纸页翻开时
// 会**弯曲**：离铰链最远的自由角先卷起，中段卷得最狠，落位时被拉平。本实现把这条
// 单列出来（[readerOpenCurl]）：
//   · 卷曲量走 `sin(π·进度)`：起手 0（纸是直的、且整张不可见）、中段最大、落位回 0
//     ⇒ 「逐渐展开」就是这条曲线，不是另加的一段动画。
//   · 卷曲作用在**自由角 + 相邻两条边**上（[readerOpenCurlPath]）：圆角被撑大、
//     两条边向内收，轮廓自己弯，配角落的背光渐变（[kReaderCurlShadeMax]）读出「纸角
//     被卷起来」。
//   · ⚠️ 真正的柱面弯曲需要把阅读页抓成纹理再按网格变形（`toImage` + `drawVertices`），
//     那会给开书关键路径再加一次全屏快照，与「开书不卡」的既有红线冲突，故用
//     「轮廓 + 光影」的等价近似：观感一致，零额外光栅化。
//
// ⚠️ §2.78 §5 订正：参考动效里书架其实同向**左移**并伴压暗（本实现按「静止」做了），
// **是否补这条视差待拍板**（挂账 #10）。
//
// 「先按住，就绪后再翻」：若转场播完时阅读页首帧未渲染，「页」是透明的，屏幕上
// 只剩被 scrim 压暗的书架 ⇒ 实测会整屏先暗后亮闪一下。故点书后先把转场按住
// （页立在屏外、不压暗书架），等阅读页首帧真正上屏再放行——没有空页期。
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
// （`ReaderPage._skeletonCover`，防闪屏）。直供书源（深链 / 详情页 / 生词本）
// 仍走「精确落位收敛才放行」的旧口径，本文件的按住语义对它不变。
//
// 路由仍是 [Navigator.push] + [PageRoute]，返回手势 / 预测性返回行为**完全不变**；
// 阅读页内部逻辑**零改动**，本转场只在**上层**加旋转、卷曲、光影与遮罩。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 翻页动画时长。
///
/// §2.109 曾从 460ms 提速到 320ms（当时翻页还在盖住等待）。§2.113 改斜向掀开：
/// 行程变成「从屏外斜着展开」而非「一块板横扫」，曲线也换成两端都收力的形态
/// （[kReaderOpenCurve]），同样的观感需要更多时间走完 → 380ms。等待期仍由门闸
/// 兜着（不靠动画盖），故时长只服务「翻得自然」，不影响开书快慢。
const Duration kReaderOpenDuration = Duration(milliseconds: 380);

/// 返回（合回右下角）时长：比进入略快，收得干脆。
const Duration kReaderOpenReverseDuration = Duration(milliseconds: 260);

/// 纸页**基础**圆角半径（自由角之外的三只角）：参考动效实测 70px。
///
/// 只有基础值；自由角（左上）的圆角随卷曲被撑大，见 [readerOpenCurlPath]。
const double kReaderPaperRadius = 70;

/// 背景书架被压暗的**终值** alpha（参考动效实测 0.54）。
const double kReaderOpenScrimAlpha = 0.54;

/// 观察距离（以屏幕**对角线**为单位）：透视强度 = `1 / (本倍数 × 对角线)`。
///
/// 必须按视口尺寸反比缩放才**同时适配手机与桌面**：固定常数（旧 0.0008）在
/// 1600dp 的桌面窗口上会退化成正交（看不出立体），在窄屏上又把纸压扁。
/// 按对角线取而不是按宽/高：纸页离铰链最远的角到眼的距离恒有 3.75−0.94 倍
/// 对角线的余量（`w ∈ [0.75, 1.25]`），任何比例、任何倾角都不会「穿到眼后」炸开。
const double kReaderOpenEyeDistance = 3.75;

/// 对角线夹取区间（dp）：防止极端窗口把纸拍扁 / 拉爆。
const double _kPerspectiveMinDiagonal = 400;
const double _kPerspectiveMaxDiagonal = 2200;

/// 掀页起手倾角：-90° = 纸页立起到「与屏幕垂直」。负号 = 纸从屏幕**远离观察者**
/// 的一侧翻上来（近大远小 ⇒ 起手时视觉面积≈0，不会先糊一大片在屏上）。
const double kReaderPeelAngle = -math.pi / 2;

/// 铰链轴在屏幕平面内的方向角（`Rz` 角）：-45° ⇒ 轴方向 (√2/2, -√2/2)，即屏幕上
/// 「右上」的反对角线。过右下角时轴线另一半落在屏幕**下方之外**（见文件头 ②）。
const double kReaderPeelAxisAngle = -math.pi / 4;

/// 翻页时间曲线：两端都收力（起手从静止加速 → 中段快速翻过 → 尾巴长减速软落位）。
///
/// 旧形态用 `easeOutCubic`（t=0 就是全速、末段硬刹）——「生硬」的一半来自曲线本身。
/// 本条在 t=0 与 t=1 的斜率都是 0：纸页像被手掀起来、又被惯性轻轻放平。
const Curve kReaderOpenCurve = Cubic(0.20, 0.0, 0.25, 1.0);

/// 整页受光衰减终值（alpha）：纸立起来时背光最暗、平铺归 0。
const double kReaderPageShadeMax = 0.20;

/// 卷曲背光终值（alpha）：贴自由角两侧边的渐变，读出「纸角卷起后转离光源」的暗面。
///
/// 太弱（旧 0.18）在真机上几乎看不见，纸会读成一块平卡片；0.30 是「一眼看出纸边
/// 卷起来了」又不至于像挖了个洞的量级。
const double kReaderCurlShadeMax = 0.42;

/// 卷曲幅度的上限：自由角的圆角外延 = 本比例 × 屏幕短边。
///
/// 0.16 的量级：手机（393 短边）≈ 63dp、桌面（900 短边）≈ 144dp——大到一眼看出
/// 「纸卷起来了」，又不至于把角落挖掉一块。
const double kReaderCurlMaxRatio = 0.16;

/// 圆角收回的起点进度。
///
/// 圆角**保持满值直到平铺到位才突收到 0**，**不能**用「圆角随进度线性收」
/// （翻页中段圆弧会一路变小）。这里把收回压在进度最后 1% 之内，
/// 观感即「落位瞬间收角」。
const double _kRadiusSettleFrom = 0.99;

/// 「按住」的最长等待：超过就无条件放行。
///
/// 转场被按住时没有任何其他退出路径，漏报 = 书永远打不开，故超时兜底。
const Duration kReaderOpenHoldTimeout = Duration(seconds: 3);

/// 视口对应的透视强度（`Matrix4` 的 (3,2) 位）：见 [kReaderOpenEyeDistance]。
double readerOpenPerspective(Size size) {
  final double diagonal = math.sqrt(
    size.width * size.width + size.height * size.height,
  ).clamp(_kPerspectiveMinDiagonal, _kPerspectiveMaxDiagonal);
  return 1 / (kReaderOpenEyeDistance * diagonal);
}

/// 掀页变换：绕「过右下角、沿反对角线」的装订边，把纸页从立起转到平铺。
///
/// [tilt]：1 = 完全立起（[kReaderPeelAngle]，投影退化成屏外一条线），
/// 0 = 平铺（**恒等矩阵**，落位与静态阅读页完全一致）。
///
/// 矩阵 = `T(右下角) · P · Rz(φ) · Rx(θ) · Rz(-φ) · T(-右下角)`：
/// 把 [kReaderPeelAxisAngle] 方向的轴转到 x 轴再绕它转 [tilt]（绕任意平面内轴翻折），
/// 原点钉在右下角（该点在轴上 ⇒ 全程不动，纸像沿装订边翻开）。
///
/// ⚠️ **透视中心必须一起搬到右下角**（`T(pivot) · P · T(-pivot)`，而不是把
/// `P` 放在最外层）：投影中心是 `(0, 0, -1/k)`，只有它落在「过铰链点、含 z 轴的
/// 平面」里，纸立起到 90° 时整张纸才会**退化成一条线**（= 屏内看不见）。按旧写法
/// （眼睛在左上角）90° 的纸会在屏上摊成一大块楔形——「按住期一像素不露」直接失效。
Matrix4 readerOpenPeelTransform(Size size, double tilt) {
  final Offset pivot = Offset(size.width, size.height);
  return Matrix4.identity()
    ..translateByDouble(pivot.dx, pivot.dy, 0, 1)
    ..multiply(Matrix4.identity()..setEntry(3, 2, readerOpenPerspective(size)))
    ..rotateZ(kReaderPeelAxisAngle)
    ..rotateX(kReaderPeelAngle * tilt)
    ..rotateZ(-kReaderPeelAxisAngle)
    ..translateByDouble(-pivot.dx, -pivot.dy, 0, 1);
}

/// 卷曲曲线：进度的 0 → 1 → 0（`sin(π·turn)`）。
///
/// [turn] = 0（纸立在屏外）→ 1（平铺）。两端都必须为 0：
/// 起手时纸是**直的**（否则立着的那张纸边缘会弯，屏外反而漏出弯边）；
/// 落位时必须**完全平**（否则屏幕角上留一条弧线缺口 = 与静态阅读页不一致）。
/// 中段取满 = 「先把纸卷起来翻过来、再铺平」，这就是「逐渐展开」。
double readerOpenCurl(double turn) {
  final double t = turn.clamp(0.0, 1.0);
  // 端点**必须精确为 0**：`sin(π)` 在浮点下是 1.2e-16，不夹掉的话落位那一帧的
  // 轮廓仍会带一丝卷曲（与静态阅读页差一个亚像素缺口）。
  if (t <= 0 || t >= 1) return 0;
  return math.sin(math.pi * t);
}

/// 卷曲幅度（dp）：0 = 纸是平直的一张，> 0 = 自由角（左上）被卷起多少。
double readerOpenCurlAmount(Size size, double turn) =>
    kReaderCurlMaxRatio * math.min(size.width, size.height) *
    readerOpenCurl(turn);

/// 纸页轮廓：三只角正常圆角，**自由角（左上）随卷曲被撑大 + 相邻两边向内收**。
///
/// 只用「轮廓」表达弯曲而不是把纸真的掰弯：一个 `Matrix4` 是投影变换，
/// 保直线、掰不弯曲面；真网格要么抓纹理、要么上着色器，都会在开书关键路径上加
/// 一次全屏快照（见文件头 ⚠️）。卷曲量 [curl] = 0 时本函数退化成普通圆角矩形。
Path readerOpenCurlPath(
  Size size, {
  required double radius,
  required double curl,
}) {
  final double w = size.width;
  final double h = size.height;
  final double short = math.min(w, h);
  final double r = radius.clamp(0.0, short / 2);
  // 自由角的外延：基础圆角 + 卷曲量。卷起来的那一圈纸「占」掉角上的这段边。
  final double c = (r + curl).clamp(0.0, short * 0.42);
  // 卷曲把相邻两边带进来的量（也让两边的起弧点错开，不显得是纯圆角）。
  final double sag = curl * 0.45;
  return Path()
    ..moveTo(0, h - r)
    ..lineTo(0, c + sag)
    // 自由角：三次贝塞尔。控制点贴着两条边 ⇒ 凸圆角；卷曲越大弧越「厚」。
    ..cubicTo(sag * 0.9, c * 0.55, c * 0.55, sag * 0.9, c, 0)
    // 顶边：紧跟自由角的一小段随卷曲向内凹（纸被卷离屏面，轮廓跟着塌一点）。
    ..quadraticBezierTo(c * 1.6, sag * 1.6, c + sag, 0)
    ..lineTo(w - r, 0)
    ..quadraticBezierTo(w, 0, w, r)
    ..lineTo(w, h - r)
    // 右下角就是铰链点：留圆角但角度不变（这点全程钉住，不能挖掉）。
    ..quadraticBezierTo(w, h, w - r, h)
    ..lineTo(r, h)
    ..quadraticBezierTo(0, h, 0, h - r)
    ..close();
}

/// 纸页轮廓的剪切器（公开以便测试读回口径：基础圆角 / 卷曲量）。
class ReaderOpenCurlClipper extends CustomClipper<Path> {
  /// 创建剪切器。
  const ReaderOpenCurlClipper({required this.radius, required this.curl});

  /// 三只角的基础圆角（自由角在此之上再加 [curl]）。
  final double radius;

  /// 卷曲幅度（dp）：0 = 平直。
  final double curl;

  @override
  Path getClip(Size size) =>
      readerOpenCurlPath(size, radius: radius, curl: curl);

  @override
  bool shouldReclip(ReaderOpenCurlClipper oldClipper) =>
      oldClipper.radius != radius || oldClipper.curl != curl;
}

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

/// 开书转场路由：阅读页作为一整页书从**右下角沿装订边翻开**铺满，书架静止在后被压暗。
///
/// 与常规路由的区别是**初始不起跑**：路由入栈后动画会被 [hold] 按住，页面立在
/// 屏外（投影退化成右下角外的一条线、不可见）、也不压暗书架；阅读页首帧上屏后
/// 由 [release] 放行才播翻页。
class ReaderOpenRoute extends PageRoute<void> {
  /// 创建开书转场。
  ReaderOpenRoute({required this.builder, this.onPopStarted});

  /// 阅读页构造器。
  final WidgetBuilder builder;

  /// 返回手势 / 系统返回**发起**那一刻的回调（`didPop`，动画起步即调）。
  ///
  /// 书架开书守卫用它在退场**开始**就释放（而非等 `popped` 要等的反向动画落定）：
  /// 页面合回右下角期间书架已可点，守卫晚放 = 关书后首点被吞（见 `shelf_page._openBook`）。
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

  /// 放行：页面带着**已经渲染好的内容**从右下角翻开（完整 [kReaderOpenDuration]）。
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
    // 进入：阅读页**自己**沿装订边翻开，不再另加平台转场（两层动效会打架）。
    return _PageFlipTransition(
      route: this,
      animation: animation,
      child: child,
    );
  }
}

/// 转场本体：底层一块压在书架上的暗化层 + 上层一页从右下角翻开的卷曲纸页。
class _PageFlipTransition extends StatefulWidget {
  const _PageFlipTransition({
    required this.route,
    required this.animation,
    required this.child,
  });

  /// 宿主路由（用于 [ReaderOpenRoute.hold] / [ReaderOpenRoute.release]）。
  final ReaderOpenRoute route;

  /// 路由转场进度 0→1（0 = 页立在屏外、不可见）。
  final Animation<double> animation;

  /// 阅读页本体（即那一页书）。
  final Widget child;

  @override
  State<_PageFlipTransition> createState() => _PageFlipTransitionState();
}

class _PageFlipTransitionState extends State<_PageFlipTransition> {
  /// 本层是否正被「按住」：按住期间**视觉恒为 p == 0**（页立在屏外、不可见）。
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
    // 铰链原点取**整页尺寸**（全屏路由 ⇒ 与视口一致）：桌面窗口改尺寸、平板分屏
    // 时右下角跟着变，不写死任何分辨率。
    final Size size = MediaQuery.sizeOf(context);
    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.child,
      builder: (BuildContext context, Widget? paper) {
        final double p =
            kReaderOpenCurve.transform(_held ? 0 : widget.animation.value);
        // 立起程度：1 = 立在屏外（不可见），0 = 平铺。翻折角只由它驱动。
        final double tilt = 1 - p;
        // 卷曲：0 → 1 → 0，与倾角是两条曲线（纸先被卷起来翻过去，最后才被拉平）。
        final double curl01 = readerOpenCurl(p);
        final double curl = readerOpenCurlAmount(size, p);
        // 圆角：全程满值，仅在落位的一瞬间收回（见 [_kRadiusSettleFrom]）。
        final double settle =
            ((p - _kRadiusSettleFrom) / (1 - _kRadiusSettleFrom)).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 背景：书架**不动**，只被压暗（alpha 到 54%）；等待期 p == 0 ⇒ 不先暗。
            ColoredBox(
              color: Colors.black.withValues(alpha: kReaderOpenScrimAlpha * p),
            ),
            // 页面：沿装订边翻折 + 透视 + 卷曲轮廓 + 光影。`Transform`/`ClipPath`
            // 只影响绘制与命中测试，不触发布局；按住期（页投影在屏外）`IgnorePointer`
            // 让点击照常落到下层书架（-90° 附近逆变换会把命中区映射成一条线，不可靠）。
            IgnorePointer(
              ignoring: _held,
              child: Transform(
                transform: readerOpenPeelTransform(size, tilt),
                child: ClipPath(
                  clipper: ReaderOpenCurlClipper(
                    radius: kReaderPaperRadius * (1 - settle),
                    curl: curl,
                  ),
                  child: DecoratedBox(
                    // ⚠️ 必须 `foreground`：`DecoratedBox` 默认把装饰画在**子节点下面**，
                    // 而纸页是不透明的一整块（阅读页自己铺底色）⇒ 默认位置上的背光
                    // 一丝都看不见（旧实现的「背光压暗」其实一直是空转）。
                    position: DecorationPosition.foreground,
                    // 受光衰减：纸立起来时整页压暗、平铺归 0。
                    decoration: BoxDecoration(
                      color: Color.fromRGBO(0, 0, 0, kReaderPageShadeMax * tilt),
                    ),
                    child: DecoratedBox(
                      // 卷曲背光：贴**自由角**（左上）的斜向渐变带（沿反对角线方向
                      // 淡出）。纸角卷离屏面后转离光源 ⇒ 角上一带压暗、向纸心迅速
                      // 化开，这是「这是一张纸、不是一个色块」最直接的读法。
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        gradient: curl01 <= 0.01
                            ? null
                            : LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: <Color>[
                                  Color.fromRGBO(
                                      0, 0, 0, kReaderCurlShadeMax * curl01),
                                  const Color.fromRGBO(0, 0, 0, 0),
                                ],
                                stops: const <double>[0, 0.24],
                              ),
                      ),
                      child: paper,
                    ),
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
