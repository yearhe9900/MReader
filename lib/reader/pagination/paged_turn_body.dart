// 翻页体（选型 §2.3 方案 A）：隐藏滚动体 + 翻页图层叠层。
//
// 分工：本组件只管**一页跨度**的手势状态机与收尾动画——方向在第一个非零 drag delta
// 决定 → 跟手累积 progress → 松手一处判定（`PageTurnController` 0.3 距离 / 800 甩动
// 阈值）→ settle 收尾 → commit 交回调换页。语义坐标推进 / 窗口收敛 / 落盘都在调用方。
//
// 冻结配对（保证③「动画期零排版」）：beginDrag 成功即 `scheduler.freeze()` +
// `onGestureActive(true)`（调用方借此作废在途停稳流、挡 reprime）；settle 完成 /
// 取消 / none 同步 commit / 拖拽取消 / dispose 统一走 [_endActive] 解冻 +
// `onGestureActive(false)`。**边缘被阻**（`canTurn` false）不 begin、不冻结。
//
// 零 rebuild 契约：incoming 页**起手惰性构建**存 state 字段；current 来自 props；
// 动画期调用方不 rebuild → 两页实例稳定 → 图层只换 Transform 矩阵。
import 'package:flutter/widgets.dart';

import 'page_turn_controller.dart';
import 'page_turn_layers.dart';
import 'pagination_scheduler.dart';

/// 收尾动画全程时长（progress 走满 1.0 的毫秒数；实际按剩余距离折算并
/// clamp 到 `[80, 240]`）。
const int _kSettleFullMs = 240;

/// 最短收尾时长（距离极小时不至于一帧闪没）。
const int _kSettleMinMs = 80;

/// 翻页体：单页跨度的拖拽 / 收尾动画 / commit 上抛。
class PageTurnBody extends StatefulWidget {
  const PageTurnBody({
    super.key,
    required this.mode,
    required this.current,
    required this.buildIncoming,
    required this.canTurn,
    required this.onGestureActive,
    required this.onCommit,
    this.scheduler,
  });

  /// 翻页模式（`slide` / `cover` / `none`；`scroll` 不进本组件）。
  final PageTurnMode mode;

  /// 当前页（调用方预排好的静态页 widget；保持同一实例 = 页子树零 rebuild）。
  final Widget current;

  /// 目标页惰性构建（起手判定方向成功后调用**一次**，结果存 state 缓存）。
  final Widget Function(TurnDirection dir) buildIncoming;

  /// 方向可翻判定（跨章 / 书边阻塞 → false 时不起手、不冻结）。
  final bool Function(TurnDirection dir) canTurn;

  /// 手势会话起止（true = 起手：作废在途停稳流 + 挡 reprime；false = 收尾）。
  final ValueChanged<bool> onGestureActive;

  /// commit 上抛（settle 补满 / none 同步切页时；调用方换语义坐标 + 换页）。
  final ValueChanged<TurnDirection> onCommit;

  /// 分页调度器（起手 freeze / 收尾 unfreeze；null = 不冻结，测试可省）。
  final PaginationScheduler? scheduler;

  @override
  State<PageTurnBody> createState() => _PageTurnBodyState();
}

class _PageTurnBodyState extends State<PageTurnBody>
    with TickerProviderStateMixin {
  /// 翻页控制器（手势状态机 + commit/cancel 判定；mode 由 props 同步）。
  late final PageTurnController _turn;

  /// 收尾动画驱动（value = progress；不设默认 duration——animateTo /
  /// animateBack 按剩余距离显式传）。
  late final AnimationController _settle;

  /// 目标页缓存（起手惰性构建；commit / 视图换新后清）。
  Widget? _incoming;

  /// 本次手势方向（beginDrag 成功时记；`endDrag` 对 none 模式会把
  /// controller 的 direction 清掉，commit 判定靠这份备份）。
  TurnDirection? _dir;

  /// 跟手进度累积基数（页宽比例；beginDrag 时清零）。
  double _drag = 0.0;

  /// 手势会话标志（onGestureActive 配对；防重复通知）。
  bool _active = false;

  /// 冻结配对标志（scheduler 非 null 时 begin 冻结、_endActive 解冻）。
  bool _frozen = false;

  /// settle 状态监听武装（`_settle.value = from` 的瞬时 status 变化不许
  /// 触发 finish；仅 animateTo / animateBack 启动后武装）。
  bool _settleArmed = false;

  /// 视口宽（LayoutBuilder 期记录；progress 换算用）。
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _turn = PageTurnController(mode: widget.mode);
    _settle = AnimationController(vsync: this)
      ..addListener(_onSettleTick)
      ..addStatusListener(_onSettleStatus);
  }

  @override
  void didUpdateWidget(covariant PageTurnBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) _turn.mode = widget.mode;
    // 视图 / 排版参数换新（current 新实例）→ 旧目标页作废。
    if (!identical(oldWidget.current, widget.current)) _incoming = null;
  }

  @override
  void dispose() {
    _settle.dispose();
    _endActive(); // 解冻 + notify(false)（调用方挂 mounted / 相位闸）
    super.dispose();
  }

  // ── 手势 ──────────────────────────────────────────────────────────────

  void _onDragUpdate(DragUpdateDetails details) {
    if (_width <= 0) return;
    final double delta = details.delta.dx;

    if (_turn.phase == PageTurnPhase.idle) {
      if (delta == 0) return;
      // 方向在第一个非零 delta 决定；边缘被阻则不起手（不冻结、不通知）。
      final TurnDirection dir =
          delta < 0 ? TurnDirection.next : TurnDirection.prev;
      if (!widget.canTurn(dir)) return;
      if (!_turn.beginDrag(dir)) return;
      _dir = dir;
      _incoming = widget.buildIncoming(dir);
      _drag = 0.0;
      _active = true;
      widget.onGestureActive(true);
      final PaginationScheduler? scheduler = widget.scheduler;
      if (scheduler != null) {
        _frozen = true;
        scheduler.freeze();
      }
    } else if (_turn.phase != PageTurnPhase.dragging) {
      return; // settling 中的新拖拽不打断收尾
    }

    final double sign = _dir == TurnDirection.next ? -1.0 : 1.0;
    _drag += sign * delta / _width;
    _turn.updateDrag(_drag);
    setState(() {});
  }

  void _onDragEnd(DragEndDetails details) {
    if (_turn.phase != PageTurnPhase.dragging) return;
    final TurnDirection dir = _dir!;
    // 甩动速度投影到翻页方向（沿方向为正）。
    final double vx = details.velocity.pixelsPerSecond.dx;
    final double along = dir == TurnDirection.next ? -vx : vx;
    _resolveRelease(_turn.endDrag(along));
  }

  void _onDragCancel() {
    if (_turn.phase != PageTurnPhase.dragging) return;
    _resolveRelease(_turn.endDrag(0.0)); // 按距离阈值判定
  }

  // ── 收尾 ──────────────────────────────────────────────────────────────

  /// 松手判定后分流：none（已回 idle）/ 起点即终点 → 同步 finish；
  /// 其余 → settle 收尾动画（commit 补到 1、cancel 退回 0）。
  void _resolveRelease(TurnCommit decision) {
    final bool commit = decision == TurnCommit.commit;
    if (_turn.phase == PageTurnPhase.idle) {
      _finish(commit: commit);
      return;
    }
    final double from = _turn.progress;
    final double to = commit ? 1.0 : 0.0;
    if ((to - from).abs() < 1e-6) {
      _finish(commit: commit);
      return;
    }
    _settleArmed = false;
    _settle.value = from; // 瞬时 status 变化被未武装的监听吞掉
    _settleArmed = true;
    final int ms =
        (_kSettleFullMs * (to - from).abs()).round().clamp(_kSettleMinMs, _kSettleFullMs).toInt();
    if (commit) {
      _settle.animateTo(to,
          duration: Duration(milliseconds: ms), curve: Curves.easeOutCubic);
    } else {
      _settle.animateBack(to,
          duration: Duration(milliseconds: ms), curve: Curves.easeOutCubic);
    }
  }

  void _onSettleTick() {
    if (_turn.phase != PageTurnPhase.settling) return;
    _turn.updateSettle(_settle.value);
    if (mounted) setState(() {});
  }

  void _onSettleStatus(AnimationStatus status) {
    if (!_settleArmed) return;
    if (status == AnimationStatus.completed) {
      _settleArmed = false;
      _finish(commit: true);
    } else if (status == AnimationStatus.dismissed) {
      _settleArmed = false;
      _finish(commit: false);
    }
  }

  /// 翻页收尾（commit 顺序保证「父先 build → 子拿新 current → 无闪帧」）：
  /// onCommit（父 setState 换页）→ finishSettle（几何回 null）→ mode 同步 →
  /// 解冻 + notify(false) → 清缓存 → 本组件 setState。
  void _finish({required bool commit}) {
    final TurnDirection dir = _dir ?? TurnDirection.next;
    _dir = null;
    if (commit) widget.onCommit(dir);
    _turn.finishSettle();
    _turn.mode = widget.mode;
    _endActive();
    _incoming = null;
    if (mounted) setState(() {});
  }

  /// 手势会话收尾：notify(false) + 解冻（幂等）。
  void _endActive() {
    if (!_active) return;
    _active = false;
    widget.onGestureActive(false);
    if (_frozen) {
      _frozen = false;
      widget.scheduler?.unfreeze();
    }
  }

  // ── 渲染 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        _width = w.isFinite && w > 0 ? w : 0;
        return GestureDetector(
          // opaque：页两侧边距空白区也可起手（child 仍正常命中，链接可点）。
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: _onDragCancel,
          child: PageTurnLayers(
            geometry: _turn.geometry,
            current: widget.current,
            incoming: _incoming ?? widget.current,
          ),
        );
      },
    );
  }
}
