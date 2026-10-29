// 翻页控制器：模式集合 + 跟手拖拽 commit/cancel + 页图层几何 + 相邻页预排窗口
// （纯 Dart，无 Flutter 依赖，可单测）。选型 §6 ①③：slide + cover 首批、none 随后；
// `scroll` 归滚动容器、`curl` P2 不阻塞。
// 保证③：动画期只回放页图层——几何与判定都在这里算好，视图层只做 Transform
// （见 `page_turn_layers.dart`）。commit/cancel 在 [PageTurnController.endDrag]
// **一处判定**（0.3 距离阈值 / 800 甩动阈值），视图无权改判。

/// 翻页模式（§6 ③：slide + cover 首批、none 随后）。
///
/// `scroll`（页纵向拼接）由阅读页滚动容器承载、不进本控制器；`curl`（仿真翻页）
/// P2 不阻塞，落地时在此追加枚举值并补几何分支。
enum PageTurnMode {
  /// 左右滑动：两页并排平移。
  slide,

  /// 左右覆盖：移动页盖住静止页 + 翻页线阴影（prev 方向为当前页掀起）。
  cover,

  /// 无动画：直接切页（几何恒 0，`endDrag` 不进 settling 阶段）。
  none,
}

/// 翻页方向（手势/几何的符号约定）。
enum TurnDirection {
  /// 向后翻（进下一页）。手势 = 内容向左滑。
  next,

  /// 向前翻（回上一页）。手势 = 内容向右滑。
  prev,
}

/// 控制器阶段。
enum PageTurnPhase {
  /// 静止（无手势、无动画）。
  idle,

  /// 手指按住拖动中（progress 跟手）。
  dragging,

  /// 松手后收尾动画中（commit → 补到 1 / cancel → 退回 0，由视图驱动）。
  settling,
}

/// `endDrag` 判定结果。
enum TurnCommit {
  commit,

  cancel,
}

/// 距离阈值：拖过页宽 30% 即翻页（anx `snap()` 同款 0.3）。
const double kCommitDistance = 0.3;

/// 甩动速度阈值（px/s，沿翻页方向为正）。超过则无视距离直接 commit/cancel
/// （正向甩 = 意图明确的快速翻页；反向甩 = 中途反悔，即使已拖过 0.3 也退回）。
const double kFlingVelocity = 800.0;

/// cover 模式翻页线阴影强度（alpha，0..1）。仅 `progress ∈ (0,1)` 时生效。
const double kEdgeShadow = 0.3;

/// 预排页窗口大小：prev / cur / next / nextPlus 共 4 页
/// （567Reader `preRenderPage` 4 页窗口的对应物；边界去重后可能更少）。
const int kPrebuildWindowAhead = 2;

/// 一页的图层变换（几何比例值；调用方乘实际页宽得像素）。
///
/// 页宽归一化为 1.0：`dx = 0` 页完全盖住视口，`dx = ±1` 页完全移出。
/// 纯数据，`==` 按值——契约测试直接比字面量。
class PageLayerGeometry {
  const PageLayerGeometry({
    required this.currentDx,
    required this.incomingDx,
    required this.incomingOnTop,
    required this.edgeShadow,
    required this.shadowOnIncoming,
  });

  /// 当前页水平位移（页宽比例；负 = 向左移出视口）。
  final double currentDx;

  /// 目标页（incoming）水平位移（页宽比例）。
  final double incomingDx;

  /// 目标页是否压在当前页之上（Stack 页序：true = 目标页在上）。
  final bool incomingOnTop;

  /// 翻页线阴影强度（0 = 无；cover 过渡期 = [kEdgeShadow]）。
  final double edgeShadow;

  /// 阴影挂在哪一页（true = 目标页左缘，false = 当前页左缘）。
  ///
  /// 翻页线恒为**移动页的左缘**：cover next 移动页 = 目标页；
  /// cover prev 移动页 = 当前页（掀起露出下层）。
  final bool shadowOnIncoming;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PageLayerGeometry &&
          runtimeType == other.runtimeType &&
          currentDx == other.currentDx &&
          incomingDx == other.incomingDx &&
          incomingOnTop == other.incomingOnTop &&
          edgeShadow == other.edgeShadow &&
          shadowOnIncoming == other.shadowOnIncoming;

  @override
  int get hashCode =>
      Object.hash(currentDx, incomingDx, incomingOnTop, edgeShadow, shadowOnIncoming);

  @override
  String toString() => 'PageLayerGeometry(cur: $currentDx, in: $incomingDx, '
      'top: $incomingOnTop, shadow: $edgeShadow'
      '${shadowOnIncoming ? ' onIncoming' : ''})';
}

/// 计算给定状态下的页图层几何（视图层的唯一输入；纯函数）。
///
/// [progress] clamp 到 `[0,1]`；页宽归一化（0 = 盖住视口，±1 = 完全移出）：
/// slide 两页对开平移（目标页在上）；cover next 目标页从右盖上、prev 当前页向右
/// 掀起（当前页在上）；none 全 0 = 目标页原位盖住当前页（直接切页，无中间态）。
/// 阴影仅 cover 过渡期 `p∈(0,1)` 出现，恒挂**移动页**的左缘。
PageLayerGeometry computeLayerGeometry({
  required PageTurnMode mode,
  required TurnDirection direction,
  required double progress,
}) {
  final double p = progress.clamp(0.0, 1.0).toDouble();
  final bool forward = direction == TurnDirection.next;

  switch (mode) {
    case PageTurnMode.slide:
      return PageLayerGeometry(
        currentDx: forward ? -p : p,
        incomingDx: forward ? 1 - p : -(1 - p),
        incomingOnTop: true,
        edgeShadow: 0.0,
        shadowOnIncoming: true,
      );
    case PageTurnMode.cover:
      // 阴影只在过渡中出现（p=0 未起翻、p=1 已落定 → 0）。
      final double shadow = (p > 0.0 && p < 1.0) ? kEdgeShadow : 0.0;
      if (forward) {
        // 目标页从右盖到当前页上；翻页线 = 目标页左缘。
        return PageLayerGeometry(
          currentDx: 0.0,
          incomingDx: 1 - p,
          incomingOnTop: true,
          edgeShadow: shadow,
          shadowOnIncoming: true,
        );
      }
      // 当前页向右掀起、露出静止的目标页；翻页线 = 当前页左缘；
      // 当前页必须压在目标页之上（否则露出的就不是「掀起」而是被盖住）。
      return PageLayerGeometry(
        currentDx: p,
        incomingDx: 0.0,
        incomingOnTop: false,
        edgeShadow: shadow,
        shadowOnIncoming: false,
      );
    case PageTurnMode.none:
      return const PageLayerGeometry(
        currentDx: 0.0,
        incomingDx: 0.0,
        incomingOnTop: true,
        edgeShadow: 0.0,
        shadowOnIncoming: true,
      );
  }
}

/// 相邻页预排窗口（保证③「相邻页预排」的原料）：返回
/// `[current-1, current, current+1, current+2]` 经 clamp / 去重后的**升序**页码列表
/// （共 4 页，边界只少不多）。[total] ≤ 0 → 空列表；[current] 越界 clamp。
List<int> prebuildWindow({required int current, required int total}) {
  if (total <= 0) return const <int>[];
  final int cur = current.clamp(0, total - 1);
  final int start = cur - 1 < 0 ? 0 : cur - 1;
  final int end = cur + kPrebuildWindowAhead >= total
      ? total - 1
      : cur + kPrebuildWindowAhead;
  return <int>[for (int i = start; i <= end; i++) i];
}

/// 翻页控制器：手势状态机 + commit/cancel 判定 + 图层几何入口。
///
/// **只管一页跨度的翻页**（不碰章节/页码推进——由接线层负责，`finishSettle()` 后
/// 调用方换页）。判定与几何都是纯函数的薄封装，便于状态机整体走契约测试。
class PageTurnController {
  PageTurnController({this.mode = PageTurnMode.slide});

  /// 当前翻页模式（静止时可换；拖拽/收尾中切换属调用方误用，不设防护）。
  PageTurnMode mode;

  PageTurnPhase _phase = PageTurnPhase.idle;
  TurnDirection? _direction;
  double _progress = 0.0;
  TurnCommit? _settleTarget;

  PageTurnPhase get phase => _phase;

  /// 当前手势/动画方向；idle 时 `null`。
  TurnDirection? get direction => _direction;

  /// 跟手进度 `0..1`（idle 恒 0）。
  double get progress => _progress;

  /// settling 阶段的收尾目标（dragging/idle 时 `null`）。
  TurnCommit? get settleTarget => _settleTarget;

  /// 静止中（既无手势也无动画）。
  bool get isIdle => _phase == PageTurnPhase.idle;

  /// 当前图层几何；`null` = 视图只渲染当前页。两种情形返回 null：idle
  /// （无方向）；`none` 模式（无过渡图层——commit 后由调用方立刻换实例，
  /// 这才是「直接切页」的正确渲染）。
  PageLayerGeometry? get geometry {
    final TurnDirection? dir = _direction;
    if (dir == null || mode == PageTurnMode.none) return null;
    return computeLayerGeometry(mode: mode, direction: dir, progress: _progress);
  }

  /// 按下起拖。返回 `false` = 非 idle 状态拒绝（连拖/动画中重复起手无效）。
  bool beginDrag(TurnDirection direction) {
    if (_phase != PageTurnPhase.idle) return false;
    _phase = PageTurnPhase.dragging;
    _direction = direction;
    _progress = 0.0;
    _settleTarget = null;
    return true;
  }

  /// 更新跟手进度（页宽比例；自动 clamp）。非 dragging 阶段忽略并原样返回。
  double updateDrag(double progress) {
    if (_phase != PageTurnPhase.dragging) return _progress;
    _progress = progress.clamp(0.0, 1.0).toDouble();
    return _progress;
  }

  /// 松手判定：[velocity] = 沿**翻页方向**的速度分量（px/s）。规则顺序判定（契约
  /// 测试钉死）：① `velocity ≥ kFlingVelocity` → **commit**（正向甩，无视距离）；
  /// ② `velocity ≤ -kFlingVelocity` → **cancel**（反向甩，已拖过 0.3 也退）；
  /// ③ 否则 `progress ≥ kCommitDistance` → commit，其余 cancel。
  ///
  /// 返回判定并进入 settling，**[progress] 停在松手值**（收尾动画由视图驱动）。
  /// `none` 模式无过渡 → 直接回 idle，调用方据返回值**立刻**换页。
  /// 非 dragging 阶段调用无效 → 返回 cancel。
  TurnCommit endDrag(double velocity) {
    if (_phase != PageTurnPhase.dragging) return TurnCommit.cancel;

    TurnCommit decision;
    if (velocity >= kFlingVelocity) {
      decision = TurnCommit.commit;
    } else if (velocity <= -kFlingVelocity) {
      decision = TurnCommit.cancel;
    } else {
      decision =
          _progress >= kCommitDistance ? TurnCommit.commit : TurnCommit.cancel;
    }

    if (mode == PageTurnMode.none) {
      // 无过渡：不进 settling，静止复位。
      _reset();
      return decision;
    }

    _phase = PageTurnPhase.settling;
    _settleTarget = decision;
    return decision;
  }

  /// settling 阶段驱动收尾动画进度（视图逐帧调用；commit 向 1、cancel 向 0）。
  /// 非 settling 阶段忽略并原样返回。
  double updateSettle(double progress) {
    if (_phase != PageTurnPhase.settling) return _progress;
    _progress = progress.clamp(0.0, 1.0).toDouble();
    return _progress;
  }

  /// 收尾动画结束（commit 后调用方已换页 / cancel 已退回起点）→ 回到 idle。
  /// 非 settling 阶段调用无效。
  void finishSettle() {
    if (_phase != PageTurnPhase.settling) return;
    _reset();
  }

  void _reset() {
    _phase = PageTurnPhase.idle;
    _direction = null;
    _progress = 0.0;
    _settleTarget = null;
  }
}
