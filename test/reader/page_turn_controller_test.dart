// 翻页控制器契约测试（`M-PAGE` T04，里程碑 §1）：图层几何公式表、
// commit/cancel 三规则边界、状态机流转、预排窗口。
//
// 期望值一律**硬编码字面量**（引用常量 = 同义反复；常量本身的字面量
// 单独断言钉住）。纯 `test()` 文件（controller 无 Flutter 依赖），
// 无需 `capTestTimeout`。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_turn_controller.dart';

void main() {
  group('阈值常量字面量（钉死契约）', () {
    test('commit 距离 0.3 / 甩动速度 800 / 阴影 0.3 / 预排窗口 2', () {
      expect(kCommitDistance, 0.3);
      expect(kFlingVelocity, 800.0);
      expect(kEdgeShadow, 0.3);
      expect(kPrebuildWindowAhead, 2);
    });
  });

  group('computeLayerGeometry 公式表（p = 0 / 0.5 / 1 字面量）', () {
    test('slide next：双页平移，current -p、incoming 1-p、目标页在上、无阴影', () {
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.next,
            progress: 0.0),
        const PageLayerGeometry(
            currentDx: 0.0,
            incomingDx: 1.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.next,
            progress: 0.5),
        const PageLayerGeometry(
            currentDx: -0.5,
            incomingDx: 0.5,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.next,
            progress: 1.0),
        const PageLayerGeometry(
            currentDx: -1.0,
            incomingDx: 0.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
    });

    test('slide prev：符号翻转，current p、incoming -(1-p)', () {
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.prev,
            progress: 0.0),
        const PageLayerGeometry(
            currentDx: 0.0,
            incomingDx: -1.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.prev,
            progress: 0.5),
        const PageLayerGeometry(
            currentDx: 0.5,
            incomingDx: -0.5,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.prev,
            progress: 1.0),
        const PageLayerGeometry(
            currentDx: 1.0,
            incomingDx: 0.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
    });

    test('cover next：current 静止、incoming 盖入、阴影挂目标页、端点归 0', () {
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.cover,
            direction: TurnDirection.next,
            progress: 0.0),
        const PageLayerGeometry(
            currentDx: 0.0,
            incomingDx: 1.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.cover,
            direction: TurnDirection.next,
            progress: 0.5),
        const PageLayerGeometry(
            currentDx: 0.0,
            incomingDx: 0.5,
            incomingOnTop: true,
            edgeShadow: 0.3,
            shadowOnIncoming: true),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.cover,
            direction: TurnDirection.next,
            progress: 1.0),
        const PageLayerGeometry(
            currentDx: 0.0,
            incomingDx: 0.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
    });

    test('cover prev：当前页掀起（在上）、incoming 静止、阴影挂当前页', () {
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.cover,
            direction: TurnDirection.prev,
            progress: 0.0),
        const PageLayerGeometry(
            currentDx: 0.0,
            incomingDx: 0.0,
            incomingOnTop: false,
            edgeShadow: 0.0,
            shadowOnIncoming: false),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.cover,
            direction: TurnDirection.prev,
            progress: 0.5),
        const PageLayerGeometry(
            currentDx: 0.5,
            incomingDx: 0.0,
            incomingOnTop: false,
            edgeShadow: 0.3,
            shadowOnIncoming: false),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.cover,
            direction: TurnDirection.prev,
            progress: 1.0),
        const PageLayerGeometry(
            currentDx: 1.0,
            incomingDx: 0.0,
            incomingOnTop: false,
            edgeShadow: 0.0,
            shadowOnIncoming: false),
      );
    });

    test('none：任意方向恒全 0（直接切页，目标页原位盖上）', () {
      const PageLayerGeometry expected = PageLayerGeometry(
          currentDx: 0.0,
          incomingDx: 0.0,
          incomingOnTop: true,
          edgeShadow: 0.0,
          shadowOnIncoming: true);
      for (final TurnDirection dir in TurnDirection.values) {
        for (final double p in <double>[0.0, 0.5, 1.0]) {
          expect(
            computeLayerGeometry(
                mode: PageTurnMode.none, direction: dir, progress: p),
            expected,
            reason: '$dir p=$p',
          );
        }
      }
    });

    test('progress 越界 clamp 到 [0,1]', () {
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.next,
            progress: -3.0),
        const PageLayerGeometry(
            currentDx: 0.0,
            incomingDx: 1.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
      expect(
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.next,
            progress: 2.0),
        const PageLayerGeometry(
            currentDx: -1.0,
            incomingDx: 0.0,
            incomingOnTop: true,
            edgeShadow: 0.0,
            shadowOnIncoming: true),
      );
      // cover 越界 → 视同端点，阴影不出现。
      expect(
        computeLayerGeometry(
                mode: PageTurnMode.cover,
                direction: TurnDirection.next,
                progress: 2.0)
            .edgeShadow,
        0.0,
      );
    });
  });

  group('endDrag 三规则边界（顺序判定）', () {
    PageTurnController make({
      PageTurnMode mode = PageTurnMode.slide,
      required double progress,
    }) {
      final PageTurnController c = PageTurnController(mode: mode);
      c.beginDrag(TurnDirection.next);
      c.updateDrag(progress);
      return c;
    }

    test('规则1：velocity ≥ 800 → commit（无视距离，p=0 也翻）', () {
      final PageTurnController c = make(progress: 0.0);
      expect(c.endDrag(800.0), TurnCommit.commit);
      expect(c.phase, PageTurnPhase.settling);
      expect(c.settleTarget, TurnCommit.commit);
      expect(c.progress, 0.0, reason: '松手值原样保留，收尾由视图驱动');
    });

    test('规则1下边界：velocity 799.9 → 掉到距离规则 → p=0 cancel', () {
      final PageTurnController c = make(progress: 0.0);
      expect(c.endDrag(799.9), TurnCommit.cancel);
      expect(c.phase, PageTurnPhase.settling);
      expect(c.settleTarget, TurnCommit.cancel);
    });

    test('规则2：velocity ≤ -800 → cancel（反向甩，即使已拖过 0.3）', () {
      final PageTurnController c = make(progress: 0.9);
      expect(c.endDrag(-800.0), TurnCommit.cancel);
      expect(c.settleTarget, TurnCommit.cancel);
      expect(c.progress, 0.9, reason: 'cancel 也不立即归零（退让动画要回放）');
    });

    test('规则2下边界：velocity -799.9 → 掉到距离规则 → p=0.9 commit', () {
      final PageTurnController c = make(progress: 0.9);
      expect(c.endDrag(-799.9), TurnCommit.commit);
      expect(c.settleTarget, TurnCommit.commit);
    });

    test('规则3：速度不足时距离 ≥ 0.3 commit、< 0.3 cancel', () {
      final PageTurnController atThreshold = make(progress: 0.3);
      expect(atThreshold.endDrag(0.0), TurnCommit.commit);

      final PageTurnController below = make(progress: 0.29);
      expect(below.endDrag(0.0), TurnCommit.cancel);
    });
  });

  group('状态机流转', () {
    test('初始 idle：无方向、progress 0、geometry null', () {
      final PageTurnController c = PageTurnController();
      expect(c.isIdle, isTrue);
      expect(c.phase, PageTurnPhase.idle);
      expect(c.direction, isNull);
      expect(c.progress, 0.0);
      expect(c.settleTarget, isNull);
      expect(c.geometry, isNull);
    });

    test('beginDrag：建立 dragging；非 idle 一律拒绝（连拖/动画中无效）', () {
      final PageTurnController c = PageTurnController();
      expect(c.beginDrag(TurnDirection.next), isTrue);
      expect(c.phase, PageTurnPhase.dragging);
      expect(c.direction, TurnDirection.next);
      expect(c.progress, 0.0);
      expect(c.beginDrag(TurnDirection.prev), isFalse, reason: '拖拽中重复起手');
      expect(c.direction, TurnDirection.next, reason: '拒绝后状态不变');
      expect(
        c.geometry,
        computeLayerGeometry(
            mode: PageTurnMode.slide,
            direction: TurnDirection.next,
            progress: 0.0),
        reason: '拖拽起手即可渲染（几何非 null）',
      );
    });

    test('updateDrag clamp；非 dragging 阶段忽略', () {
      final PageTurnController c = PageTurnController();
      expect(c.updateDrag(0.5), 0.0, reason: 'idle 不接受');

      c.beginDrag(TurnDirection.next);
      expect(c.updateDrag(1.4), 1.0);
      expect(c.updateDrag(-0.6), 0.0);
      expect(c.updateDrag(0.42), 0.42);
    });

    test('endDrag 进 settling：progress 停松手值；非 dragging 返回 cancel 且不动', () {
      final PageTurnController c = PageTurnController();
      expect(c.endDrag(1000.0), TurnCommit.cancel, reason: 'idle 直接调 → cancel');
      expect(c.phase, PageTurnPhase.idle);

      c.beginDrag(TurnDirection.next);
      c.updateDrag(0.45);
      expect(c.endDrag(0.0), TurnCommit.commit);
      expect(c.phase, PageTurnPhase.settling);
      expect(c.progress, 0.45, reason: '松手值冻结，视图逐帧驱动补到 1');
      expect(c.beginDrag(TurnDirection.prev), isFalse, reason: 'settle 中不起手');
    });

    test('updateSettle 驱动收尾；非 settling 忽略；finishSettle 复位', () {
      final PageTurnController c = PageTurnController();
      expect(c.updateSettle(0.7), 0.0, reason: '非 settling 忽略');

      c.beginDrag(TurnDirection.next);
      c.updateDrag(0.4);
      c.endDrag(0.0); // commit → settling
      expect(c.updateSettle(0.7), 0.7);
      expect(c.updateSettle(1.4), 1.0, reason: 'clamp 到 1');
      c.finishSettle();

      expect(c.isIdle, isTrue);
      expect(c.progress, 0.0);
      expect(c.direction, isNull);
      expect(c.settleTarget, isNull);
      expect(c.geometry, isNull);

      c.finishSettle(); // idle 再调无副作用
      expect(c.isIdle, isTrue);
    });

    test('none 模式：几何 null（拖拽期只渲当前页）、endDrag 直接回 idle', () {
      final PageTurnController c = PageTurnController(mode: PageTurnMode.none);
      expect(c.beginDrag(TurnDirection.next), isTrue);
      expect(c.geometry, isNull, reason: 'none 无过渡图层');
      c.updateDrag(0.5);
      expect(c.endDrag(0.0), TurnCommit.commit, reason: '判定照常（0.5 ≥ 0.3）');
      expect(c.phase, PageTurnPhase.idle, reason: '不进 settling');
      expect(c.progress, 0.0, reason: '静止复位');
      expect(c.settleTarget, isNull);

      // cancel 路径同样直接回 idle。
      c.beginDrag(TurnDirection.next);
      c.updateDrag(0.1);
      expect(c.endDrag(0.0), TurnCommit.cancel);
      expect(c.phase, PageTurnPhase.idle);
    });
  });

  group('prebuildWindow（4 页窗口 [cur-1, cur, cur+1, cur+2]）', () {
    test('total ≤ 0 → 空列表', () {
      expect(prebuildWindow(current: 0, total: 0), isEmpty);
      expect(prebuildWindow(current: 3, total: -1), isEmpty);
    });

    test('窗口中段：恰 4 页升序', () {
      expect(prebuildWindow(current: 5, total: 10), <int>[4, 5, 6, 7]);
    });

    test('首边界：从 0 起（cur-1 被 clamp 掉）', () {
      expect(prebuildWindow(current: 0, total: 10), <int>[0, 1, 2]);
      expect(prebuildWindow(current: -5, total: 10), <int>[0, 1, 2],
          reason: 'current 越界下限按 clamp');
    });

    test('末边界：到 total-1 止', () {
      expect(prebuildWindow(current: 9, total: 10), <int>[8, 9]);
      expect(prebuildWindow(current: 99, total: 10), <int>[8, 9],
          reason: 'current 越界上限按 clamp');
    });

    test('窗口尺寸 2 的边界：total 小时窗口随 total 收缩', () {
      expect(prebuildWindow(current: 0, total: 1), <int>[0]);
      expect(prebuildWindow(current: 0, total: 2), <int>[0, 1]);
      expect(prebuildWindow(current: 1, total: 3), <int>[0, 1, 2]);
    });

    test('升序且无重复', () {
      final List<int> w = prebuildWindow(current: 5, total: 10);
      for (int i = 1; i < w.length; i++) {
        expect(w[i], greaterThan(w[i - 1]), reason: '严格升序去重');
      }
    });
  });
}
