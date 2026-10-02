// 翻页体接线契约（`M-PAGE T05-d`）：`PageTurnBody` 手势状态机 → 页图层
// 几何 → settle 收尾 → commit 上抛 的端到端行为（配 `PageTurnLayers` +
// `PaginationScheduler`）。期望值一律硬编码（探针 `_probe_drag_test`
// 实跑回填，用完即删）。
//
// 手势数学（实证）：`tester.drag` 分两段 moveBy(-20)/moveBy(余量)，
// acceptance 在 down 的微任务期完成 → **两个 delta 都作为 update 投递**，
// progress 按全位移累计 = |offset| / 180（起手发生在首个非零 delta = -20，
// 该 20px 同样计入）。`tester.drag` 时间戳全零 → endVx = 0 → 只走距离
// 规则（阈值 0.3；54/180 的 double 恰等于字面量 0.3、53/180 ≈ 0.2944）。
// `fling(-50, 2000)`：51 段匀速、sum = -50 → progress 50/180 ≈ 0.278
// < 0.3、endVx ≈ -2000 → 规则1（≥800）commit。
//
// 夹具同 `paged_scroller_test`：fontSize 18 / height 1.6、pageWidth 180、
// pageHeight 200、段间距 8、firstPageHeight 160；两章各 2 段 100 字、
// 页表同构 4 页（字符区间 [0,48)/[48,100)/[100,158)/[158,200)）。容器
// 180×400（`Align(topLeft)`），手势中心 = PageTurnBody 中心 (90, 200)。
// 层几何（slide next，宽度 180）：current dx = −|位移|、incoming dx = 180−|位移|。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/page_renderer.dart';
import 'package:mreader/reader/pagination/page_turn_controller.dart';
import 'package:mreader/reader/pagination/paged_turn_body.dart';
import 'package:mreader/reader/pagination/pagination_scheduler.dart';

import '../test_config.dart';

/// 构建计数观察器（零 rebuild 契约的量尺；同 `page_turn_layers_test`）。
class _BuildHolder {
  int builds = 0;
}

/// 计数页：每次 build 给 [holder] +1。
class _CountedPage extends StatelessWidget {
  const _CountedPage(this.holder, this.child);

  final _BuildHolder holder;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    holder.builds++;
    return child;
  }
}

/// 静止层 / 目标层 key（`page_turn_layers.dart` 单双层同款）。
const ValueKey<String> currentKey = ValueKey<String>('mreader-layer-current');
const ValueKey<String> incomingKey = ValueKey<String>('mreader-layer-incoming');

/// 默认 `canTurn`：两向皆可翻。
bool _turnAll(TurnDirection _) => true;

/// commit 后父层换页的宿主（⑨ 零 rebuild：current 从 A 换成 B）。
class _SwapHost extends StatefulWidget {
  const _SwapHost({
    required this.current,
    required this.incoming,
    required this.commits,
    required this.activeLog,
    required this.scheduler,
  });

  final Widget current;
  final Widget incoming;
  final List<TurnDirection> commits;
  final List<bool> activeLog;
  final PaginationScheduler scheduler;

  @override
  State<_SwapHost> createState() => _SwapHostState();
}

class _SwapHostState extends State<_SwapHost> {
  late Widget _current = widget.current;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 180,
          height: 400,
          child: PageTurnBody(
            mode: PageTurnMode.slide,
            current: _current,
            buildIncoming: (TurnDirection _) => widget.incoming,
            canTurn: _turnAll,
            onGestureActive: widget.activeLog.add,
            onCommit: (TurnDirection dir) {
              widget.commits.add(dir);
              setState(() => _current = widget.incoming);
            },
            scheduler: widget.scheduler,
          ),
        ),
      ),
    );
  }
}

void main() {
  capTestTimeout();

  const TextStyle base = TextStyle(fontSize: 18, height: 1.6);
  const PaginationConfig config = PaginationConfig(
    pageWidth: 180,
    pageHeight: 200,
    textStyle: base,
  );

  final List<String> parasA = <String>['0123456789' * 10, 'abcdefghij' * 10];
  final List<String> parasB = <String>['0123456789' * 10, 'abcdefghij' * 10];

  late List<MeasuredLine> linesA;
  late List<PageSlice> pagesA;
  late List<MeasuredLine> linesB;
  late List<PageSlice> pagesB;

  Future<Uint8List?> resolve(String _) async => null;

  setUp(() {
    linesA = PagePaginator.measureParagraphs(paragraphs: parasA, config: config);
    pagesA = PageBreaker.paginate(
      linesA,
      pageHeight: 200,
      paragraphSpacing: 8,
      firstPageHeight: 160,
    );
    linesB = PagePaginator.measureParagraphs(paragraphs: parasB, config: config);
    pagesB = PageBreaker.paginate(
      linesB,
      pageHeight: 200,
      paragraphSpacing: 8,
      firstPageHeight: 160,
    );
  });

  Widget pageA() => Align(
        alignment: Alignment.topCenter,
        child: PageContent(
          paragraphs: parasA,
          lines: linesA,
          page: pagesA[0],
          config: config,
          resolveImage: resolve,
        ),
      );

  Widget pageB() => Align(
        alignment: Alignment.topCenter,
        child: PageContent(
          paragraphs: parasB,
          lines: linesB,
          page: pagesB[0],
          config: config,
          resolveImage: resolve,
        ),
      );

  /// 静态宿主：`PageTurnBody` 恒定 180×400，事件分类记录到三个列表。
  Widget host({
    required Widget current,
    required Widget incoming,
    PageTurnMode mode = PageTurnMode.slide,
    bool Function(TurnDirection dir)? canTurn,
    required List<TurnDirection> incomingCalls,
    required List<bool> activeLog,
    required List<TurnDirection> commits,
    required PaginationScheduler scheduler,
  }) =>
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 180,
            height: 400,
            child: PageTurnBody(
              mode: mode,
              current: current,
              buildIncoming: (TurnDirection dir) {
                incomingCalls.add(dir);
                return incoming;
              },
              canTurn: canTurn ?? _turnAll,
              onGestureActive: activeLog.add,
              onCommit: commits.add,
              scheduler: scheduler,
            ),
          ),
        ),
      );

  group('T05-d 翻页体接线', () {
    testWidgets('① 静止单层：currentKey 在场、incomingKey 无、零手势事件',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      expect(find.byKey(currentKey), findsOneWidget);
      expect(find.byKey(incomingKey), findsNothing);
      expect(holderA.builds, 1);
      expect(holderB.builds, 0, reason: '目标页起手前零 build');
      expect(incomingCalls, isEmpty);
      expect(activeLog, isEmpty);
      expect(commits, isEmpty);
      expect(scheduler.frozen, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('② 手动两段拖：首个 delta 起手 + 冻结 + 图层跟手；松手 settle 补满 commit',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      final TestGesture gesture = await tester
          .startGesture(tester.getCenter(find.byType(PageTurnBody)));

      // 首个 delta = -20（acceptance 在 down 微任务期完成，段不被吞）→ 起手。
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(incomingCalls, <TurnDirection>[TurnDirection.next],
          reason: '目标页惰性构建恰一次');
      expect(activeLog, <bool>[true]);
      expect(scheduler.frozen, isTrue, reason: '起手即冻结排版（T04 保证③）');
      expect(holderB.builds, 1);
      // p = 20/180：current -20、incoming +160（180 − 20）。
      expect(
        tester
            .widget<Transform>(find.byKey(currentKey))
            .transform
            .getTranslation()
            .x,
        closeTo(-20, 0.01),
      );
      expect(
        tester
            .widget<Transform>(find.byKey(incomingKey))
            .transform
            .getTranslation()
            .x,
        closeTo(160, 0.01),
      );

      // 第二段 -80 → 累计 100/180 ≈ 0.5556，图层跟手推进。
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(incomingCalls, <TurnDirection>[TurnDirection.next],
          reason: '后续 update 不重复构建');
      expect(holderB.builds, 1, reason: '同实例 → 页 build 不增');
      expect(
        tester
            .widget<Transform>(find.byKey(currentKey))
            .transform
            .getTranslation()
            .x,
        closeTo(-100, 0.01),
      );
      expect(
        tester
            .widget<Transform>(find.byKey(incomingKey))
            .transform
            .getTranslation()
            .x,
        closeTo(80, 0.01),
      );

      // 松手 → settle 启动（107ms）：一帧内不 commit、不解冻。
      await gesture.up();
      await tester.pump();
      expect(commits, isEmpty, reason: 'settle 未完不 commit');
      expect(activeLog, <bool>[true]);
      expect(scheduler.frozen, isTrue);

      await tester.pumpAndSettle();
      expect(commits, <TurnDirection>[TurnDirection.next]);
      expect(activeLog, <bool>[true, false]);
      expect(scheduler.frozen, isFalse, reason: '收尾解冻');
      expect(find.byKey(incomingKey), findsNothing, reason: '收尾回单层');
      expect(holderA.builds, 1, reason: 'current 页全程零 rebuild');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('③ 距离不足：drag(-40) → 40/180 ≈ 0.222 < 0.3 取消回位',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      await tester.drag(find.byType(PageTurnBody), const Offset(-40, 0));
      await tester.pump();
      // 松手即进 settle 退回：此刻仍在途中（-40 → 0）。
      expect(
        tester
            .widget<Transform>(find.byKey(currentKey))
            .transform
            .getTranslation()
            .x,
        closeTo(-40, 0.01),
      );

      await tester.pumpAndSettle();
      expect(commits, isEmpty, reason: '未过 0.3 不翻页');
      expect(activeLog, <bool>[true, false]);
      expect(scheduler.frozen, isFalse);
      expect(find.byKey(incomingKey), findsNothing, reason: '取消回单层');
      expect(
        tester
            .widget<Transform>(find.byKey(currentKey))
            .transform
            .getTranslation()
            .x,
        0.0,
        reason: '回位零平移',
      );
      expect(holderA.builds, 1);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('④ 阈值边界：drag(-54) → 54/180 == 0.3 翻页；drag(-53) → 0.2944 取消',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      // 54/180 的 double 恰等于字面量 0.3 → `>=` 成立 → commit。
      await tester.drag(find.byType(PageTurnBody), const Offset(-54, 0));
      await tester.pumpAndSettle();
      expect(commits, <TurnDirection>[TurnDirection.next]);

      // 53/180 ≈ 0.2944 < 0.3 → cancel（endVx = 0 → 距离规则）。
      await tester.drag(find.byType(PageTurnBody), const Offset(-53, 0));
      await tester.pumpAndSettle();
      expect(commits, <TurnDirection>[TurnDirection.next],
          reason: '边界外不追加 commit');
      expect(activeLog, <bool>[true, false, true, false]);
      expect(scheduler.frozen, isFalse);
      expect(holderA.builds, 1, reason: '两轮手势 current 页零 rebuild');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('⑤ 甩动速度规则：fling(-50, 2000) 距离 0.278 不足仍翻页（规则1）',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      // 实证：sum = -50 → progress 50/180 ≈ 0.278 < 0.3（距离不够），
      // endVx ≈ -2000 → 沿 next 方向 +2000 ≥ 800 → 规则1 commit。
      await tester.fling(find.byType(PageTurnBody), const Offset(-50, 0), 2000);
      expect(commits, isEmpty, reason: 'settle 已启动未完成');
      expect(activeLog, <bool>[true]);
      expect(scheduler.frozen, isTrue);
      expect(incomingCalls, <TurnDirection>[TurnDirection.next]);
      expect(holderB.builds, 1);

      await tester.pumpAndSettle();
      expect(commits, <TurnDirection>[TurnDirection.next],
          reason: '速度规则越过距离阈值');
      expect(activeLog, <bool>[true, false]);
      expect(scheduler.frozen, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('⑥ none 模式：松手同步 commit（不经 settle、无帧也生效）',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        mode: PageTurnMode.none,
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      await tester.drag(find.byType(PageTurnBody), const Offset(-100, 0));
      // drag 全程无 pump：up 同步判定 → commit 已在回调里发生。
      expect(commits, <TurnDirection>[TurnDirection.next]);
      expect(activeLog, <bool>[true, false]);
      expect(scheduler.frozen, isFalse, reason: 'none 同步收尾即解冻');

      await tester.pump();
      expect(find.byKey(incomingKey), findsNothing,
          reason: 'none 几何恒 null → 只渲染当前页');
      expect(holderA.builds, 1);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('⑦ canTurn false：不起手、不构建、不冻结、无 commit',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        canTurn: (TurnDirection _) => false,
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      await tester.drag(find.byType(PageTurnBody), const Offset(-100, 0));
      await tester.pump();
      expect(incomingCalls, isEmpty);
      expect(activeLog, isEmpty, reason: '边缘被阻不通知手势会话');
      expect(scheduler.frozen, isFalse, reason: '不冻结');
      expect(commits, isEmpty);
      expect(holderB.builds, 0);
      expect(find.byKey(incomingKey), findsNothing);
      expect(
        tester
            .widget<Transform>(find.byKey(currentKey))
            .transform
            .getTranslation()
            .x,
        0.0,
        reason: '几何未动',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('⑧ prev 方向：drag(+100) → 累计 100/180 翻回上一页',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> incomingCalls = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final List<TurnDirection> commits = <TurnDirection>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(host(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        incomingCalls: incomingCalls,
        activeLog: activeLog,
        commits: commits,
        scheduler: scheduler,
      ));

      await tester.drag(find.byType(PageTurnBody), const Offset(100, 0));
      await tester.pump();
      expect(incomingCalls, <TurnDirection>[TurnDirection.prev],
          reason: '首个 delta > 0 → prev');
      // slide prev：current +100、incoming −80。
      expect(
        tester
            .widget<Transform>(find.byKey(currentKey))
            .transform
            .getTranslation()
            .x,
        closeTo(100, 0.01),
      );
      expect(
        tester
            .widget<Transform>(find.byKey(incomingKey))
            .transform
            .getTranslation()
            .x,
        closeTo(-80, 0.01),
      );

      await tester.pumpAndSettle();
      expect(commits, <TurnDirection>[TurnDirection.prev]);
      expect(activeLog, <bool>[true, false]);
      expect(scheduler.frozen, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('⑨ 零 rebuild：手势全程 current 不重建；commit 后父换页目标题目',
        (WidgetTester tester) async {
      final _BuildHolder holderA = _BuildHolder();
      final _BuildHolder holderB = _BuildHolder();
      final List<TurnDirection> commits = <TurnDirection>[];
      final List<bool> activeLog = <bool>[];
      final PaginationScheduler scheduler = PaginationScheduler();

      await tester.pumpWidget(_SwapHost(
        current: _CountedPage(holderA, pageA()),
        incoming: _CountedPage(holderB, pageB()),
        commits: commits,
        activeLog: activeLog,
        scheduler: scheduler,
      ));
      expect(holderA.builds, 1);
      expect(find.byWidgetPredicate(
        (Widget w) => w is PageContent && identical(w.paragraphs, parasA),
      ), findsOneWidget);

      // 手势：起手（首 delta -20）→ 推进 → 松手。
      final TestGesture gesture = await tester
          .startGesture(tester.getCenter(find.byType(PageTurnBody)));
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(holderB.builds, 1, reason: 'incoming 首 build');
      expect(holderA.builds, 1, reason: '起手不重建 current');

      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(holderA.builds, 1, reason: '拖拽期不重建 current');
      expect(holderB.builds, 1, reason: '同实例 → 页 build 不增');

      await gesture.up();
      await tester.pump();
      expect(holderA.builds, 1, reason: 'settle 期不重建 current');

      await tester.pumpAndSettle();
      expect(commits, <TurnDirection>[TurnDirection.next]);
      expect(holderA.builds, 1, reason: '全程零 rebuild（1 → 换页后退出）');
      expect(holderB.builds, 2, reason: 'incoming 1 次 + 父换页为 current 1 次');
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is PageContent && identical(w.paragraphs, parasB),
        ),
        findsOneWidget,
        reason: '父换页后目标页上屏',
      );
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is PageContent && identical(w.paragraphs, parasA),
        ),
        findsNothing,
        reason: '旧页退场',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });
}
