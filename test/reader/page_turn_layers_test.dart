// 翻页图层契约测试（`M-PAGE` T04，保证 ③）：页即图层结构
// （Transform > RepaintBoundary > 页）、动画期零 rebuild（同实例 → 页
// build 不增、只更新变换矩阵）、页序、阴影条挂移动页。
//
// 期望值一律硬编码字面量。夹具页宽 100（几何比例 × 100 = 像素）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_turn_controller.dart';
import 'package:mreader/reader/pagination/page_turn_layers.dart';

import '../test_config.dart';

/// 构建计数观察器（零 rebuild 契约的量尺）。
class _BuildHolder {
  int builds = 0;
}

/// 计数页：每次 build 给 [holder] +1。
class _CountedPage extends StatelessWidget {
  const _CountedPage(this.holder, this.label);

  final _BuildHolder holder;
  final String label;

  @override
  Widget build(BuildContext context) {
    holder.builds++;
    return Text(label);
  }
}

const ValueKey<String> currentKey = ValueKey<String>('mreader-layer-current');
const ValueKey<String> incomingKey = ValueKey<String>('mreader-layer-incoming');

Future<void> pumpLayers(
  WidgetTester tester, {
  required PageLayerGeometry? geometry,
  required Widget current,
  required Widget incoming,
}) {
  return tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 100,
          height: 200,
          child: PageTurnLayers(
            geometry: geometry,
            current: current,
            incoming: incoming,
          ),
        ),
      ),
    ),
  );
}

PageLayerGeometry slideAt(double p) => computeLayerGeometry(
      mode: PageTurnMode.slide,
      direction: TurnDirection.next,
      progress: p,
    );

/// 阴影条（宽 20 的 Positioned）查找器。
Finder shadowStripIn(ValueKey<String> layerKey) => find.descendant(
      of: find.byKey(layerKey),
      matching: find.byWidgetPredicate(
        (Widget w) => w is Positioned && w.width == 20,
      ),
    );

void main() {
  capTestTimeout();

  testWidgets('geometry null：单页直渲（incoming 零 build、单 Transform 零位移）',
      (WidgetTester tester) async {
    final _BuildHolder cur = _BuildHolder();
    final _BuildHolder inc = _BuildHolder();
    await pumpLayers(
      tester,
      geometry: null,
      current: _CountedPage(cur, 'cur'),
      incoming: _CountedPage(inc, 'inc'),
    );

    expect(find.text('cur'), findsOneWidget);
    expect(find.text('inc'), findsNothing);
    expect(inc.builds, 0, reason: 'incoming 不渲染');
    expect(cur.builds, 1);
    expect(find.byType(RepaintBoundary), findsOneWidget, reason: '单层');

    final Transform only =
        tester.widget<Transform>(find.byType(Transform));
    expect(only.transform.getTranslation().x, 0.0);
  });

  testWidgets('同实例换几何：页 build 不增、Transform 矩阵更新（零 rebuild 契约）',
      (WidgetTester tester) async {
    final _BuildHolder cur = _BuildHolder();
    final _BuildHolder inc = _BuildHolder();
    final _CountedPage currentPage = _CountedPage(cur, 'cur');
    final _CountedPage incomingPage = _CountedPage(inc, 'inc');

    await pumpLayers(
        tester, geometry: slideAt(0.1), current: currentPage, incoming: incomingPage);
    expect(cur.builds, 1);
    expect(inc.builds, 1);

    // 同一批页实例、换几何（拖拽推进）→ PageTurnLayers 重建，
    // 但页子树跳过重建，只更新变换矩阵。
    await pumpLayers(
        tester, geometry: slideAt(0.6), current: currentPage, incoming: incomingPage);
    expect(cur.builds, 1, reason: 'current 零 rebuild');
    expect(inc.builds, 1, reason: 'incoming 零 rebuild');
    expect(find.text('cur'), findsOneWidget);
    expect(find.text('inc'), findsOneWidget);

    // 矩阵已按 p=0.6 更新：cur -60、inc +40（页宽 100）。
    final Transform currentLayer =
        tester.widget<Transform>(find.byKey(currentKey));
    expect(currentLayer.transform.getTranslation().x, -60.0);
    final Transform incomingLayer =
        tester.widget<Transform>(find.byKey(incomingKey));
    expect(incomingLayer.transform.getTranslation().x, 40.0);
  });

  testWidgets('slide p=0.5：页序 current→incoming、平移 ±50、两层 RepaintBoundary',
      (WidgetTester tester) async {
    await pumpLayers(
      tester,
      geometry: slideAt(0.5),
      current: _CountedPage(_BuildHolder(), 'cur'),
      incoming: _CountedPage(_BuildHolder(), 'inc'),
    );

    // 平移：cur -50、inc +50（页宽 100）。
    expect(
      tester.widget<Transform>(find.byKey(currentKey)).transform.getTranslation().x,
      -50.0,
    );
    expect(
      tester.widget<Transform>(find.byKey(incomingKey)).transform.getTranslation().x,
      50.0,
    );

    // 页序：incomingOnTop → current 在下、incoming 在上（Stack 后者在上）。
    final Stack stack = tester.widget<Stack>(
      find
          .ancestor(of: find.byKey(currentKey), matching: find.byType(Stack))
          .first,
    );
    expect(stack.children.length, 2);
    expect((stack.children[0] as Transform).key, currentKey);
    expect((stack.children[1] as Transform).key, incomingKey);

    expect(find.byType(RepaintBoundary), findsNWidgets(2));
    // slide 无翻页线阴影。
    expect(
      find.byWidgetPredicate((Widget w) => w is Positioned && w.width == 20),
      findsNothing,
    );
  });

  testWidgets('cover prev p=0.5：当前页掀起在上（页序 incoming→current）',
      (WidgetTester tester) async {
    final PageLayerGeometry g = computeLayerGeometry(
      mode: PageTurnMode.cover,
      direction: TurnDirection.prev,
      progress: 0.5,
    );
    await pumpLayers(
      tester,
      geometry: g,
      current: _CountedPage(_BuildHolder(), 'cur'),
      incoming: _CountedPage(_BuildHolder(), 'inc'),
    );

    expect(
      tester.widget<Transform>(find.byKey(currentKey)).transform.getTranslation().x,
      50.0,
      reason: '当前页右掀 0.5 × 100',
    );
    expect(
      tester.widget<Transform>(find.byKey(incomingKey)).transform.getTranslation().x,
      0.0,
      reason: '目标页静止',
    );

    final Stack stack = tester.widget<Stack>(
      find
          .ancestor(of: find.byKey(currentKey), matching: find.byType(Stack))
          .first,
    );
    expect(stack.children.length, 2);
    expect((stack.children[0] as Transform).key, incomingKey,
        reason: '掀起页必须在上，否则露出的不是下层');
    expect((stack.children[1] as Transform).key, currentKey);
  });

  testWidgets('cover 阴影条：挂移动页左缘（next=incoming、prev=current）、宽 20',
      (WidgetTester tester) async {
    // cover next：移动页 = 目标页。
    await pumpLayers(
      tester,
      geometry: computeLayerGeometry(
          mode: PageTurnMode.cover,
          direction: TurnDirection.next,
          progress: 0.5),
      current: _CountedPage(_BuildHolder(), 'cur'),
      incoming: _CountedPage(_BuildHolder(), 'inc'),
    );
    expect(shadowStripIn(incomingKey), findsOneWidget);
    expect(shadowStripIn(currentKey), findsNothing);

    // 阴影渐变首色 = 黑 alpha 0.3、末色全透明。
    final DecoratedBox box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byKey(incomingKey),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final BoxDecoration decoration = box.decoration as BoxDecoration;
    final LinearGradient gradient = decoration.gradient! as LinearGradient;
    expect(gradient.colors.first, Colors.black.withValues(alpha: 0.3));
    expect(gradient.colors.last, Colors.black.withValues(alpha: 0));

    // cover prev：移动页 = 当前页。
    await pumpLayers(
      tester,
      geometry: computeLayerGeometry(
          mode: PageTurnMode.cover,
          direction: TurnDirection.prev,
          progress: 0.5),
      current: _CountedPage(_BuildHolder(), 'cur'),
      incoming: _CountedPage(_BuildHolder(), 'inc'),
    );
    expect(shadowStripIn(currentKey), findsOneWidget);
    expect(shadowStripIn(incomingKey), findsNothing);
  });

  testWidgets('cover 端点 p=1：阴影归 0（落定无残留阴影条）',
      (WidgetTester tester) async {
    await pumpLayers(
      tester,
      geometry: computeLayerGeometry(
          mode: PageTurnMode.cover,
          direction: TurnDirection.next,
          progress: 1.0),
      current: _CountedPage(_BuildHolder(), 'cur'),
      incoming: _CountedPage(_BuildHolder(), 'inc'),
    );
    expect(
      find.byWidgetPredicate((Widget w) => w is Positioned && w.width == 20),
      findsNothing,
    );
  });
}
