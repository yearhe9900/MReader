// `test/ui/adaptive_pill_tab_bar_test.dart`：宽度自适应胶囊标签行的**宽度规则**契约。
//
// 2026-10-16 功能迁移批拍板：
//   · 最小宽度 = 当前宽度 87.6（`MiPillTabMetrics.itemWidth`）；
//   · 最大宽度 = 当前宽度 × 2 = 175.2；
//   · 超过最大宽度以省略号截断。
// 宽度公式：`clamp(文字自然宽 + 2×textInset, minWidth, maxWidth)`。
//
// 断言口径：几何用**字面量**（引用常量等于同义反复）；文字侧用
// `胶囊宽 − 32` 钉 textInset=16 双侧（不重实现 TextPainter 测宽）。
// 测试字体（Ahem 式）下每字宽 = 字号 13.85，故 2 字 ≈ 59.7、6 字 ≈ 115.1、
// 20 字 ≈ 309（+32 内距后分别落在 min 内 / 自然段 / max 外）。
//
// 结构契约（2026-10-16 跟随上游两遍绘制批，§2.102）：末组用例钉
// 「磨砂取景框层先画于填充层 + 填充不包 ClipRRect」——改回单遍绘制即红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ui/adaptive_pill_tab_bar.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

import '../test_config.dart';

/// 单个胶囊（label 的 Text 上级 [AnimatedContainer]）。
Finder _pillOf(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(AnimatedContainer),
    );

/// 把标签行挂进 [MaterialApp]（供 [MediaQuery] / [Directionality]）。
Widget _harness(List<String> labels) => MaterialApp(
      home: Scaffold(
        body: AdaptivePillTabBar(
          labels: labels,
          selectedIndex: 0,
          onTap: (_) {},
          themeMode: MiThemeMode.light,
        ),
      ),
    );

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  testWidgets('min 钳位：短标签胶囊宽恰为 87.6（当前宽度）', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(const <String>['全部', '玄幻']));

    // 2 字标签自然宽 +32 < 87.6 → 钳到最小宽。
    expect(tester.getSize(_pillOf('全部')).width, closeTo(87.6, 0.001));
    expect(tester.getSize(_pillOf('玄幻')).width, closeTo(87.6, 0.001));
  });

  testWidgets('自然段：中等标签宽随文字增长、文字两侧内距恰 32', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(const <String>['全部', '科幻小说精选']));

    final double pillW = tester.getSize(_pillOf('科幻小说精选')).width;
    // 严格落在 (87.6, 175.2)——退回定宽或 max 规则失效立刻红。
    expect(pillW, greaterThan(87.6));
    expect(pillW, lessThan(175.2));
    // 随文字增长（2 字在 min、6 字在自然段，宽度必须不同）。
    expect(pillW, greaterThan(tester.getSize(_pillOf('全部')).width));
    // 内容槽 = 胶囊宽 − 2×16（钉 textInset=16）：文字在自然段恰好铺满内容槽。
    expect(
      tester.getSize(find.text('科幻小说精选')).width,
      closeTo(pillW - 32, 0.001),
    );
  });

  testWidgets('max 钳位 + 省略号：超长标签宽恰为 175.2，单行 ellipsis 截断',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 200);
    addTearDown(tester.view.reset);

    const String longLabel = '这是一个非常非常长的分组标签名称';
    await tester.pumpWidget(_harness(const <String>[longLabel]));

    // 15 字自然宽 +32 ≫ 175.2 → 钳到最大宽（当前宽度 × 2）。
    expect(tester.getSize(_pillOf(longLabel)).width, closeTo(175.2, 0.001));
    // 文字被钳进内容槽（175.2 − 32 = 143.2），渲染层省略号生效。
    expect(
      tester.getSize(find.text(longLabel)).width,
      closeTo(143.2, 0.001),
    );
    // 截断契约：单行 + ellipsis（省略了任一项 → 长标签溢出胶囊）。
    final Text text = tester.widget<Text>(find.text(longLabel));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('点按回调带下标（接口与 MiPillTabBar 对齐，整组互换口径）',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 200);
    addTearDown(tester.view.reset);

    final List<int> taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptivePillTabBar(
            labels: const <String>['全部', '玄幻', '科幻'],
            selectedIndex: 0,
            onTap: taps.add,
            themeMode: MiThemeMode.light,
          ),
        ),
      ),
    );

    await tester.tap(find.text('科幻'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, <int>[2]);
  });

  testWidgets('两遍绘制：磨砂层先画于填充层、填充不包 ClipRRect（§2.102）',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(const <String>['全部', '玄幻']));

    // 两遍绘制的容器 = 组件内「恰两层 Positioned」的 Stack；
    // 找不到（改回单遍直排 Row）→ firstWhere 抛错 → 用例红。
    final Stack stack = tester
        .widgetList<Stack>(
          find.descendant(
            of: find.byType(AdaptivePillTabBar),
            matching: find.byType(Stack),
          ),
        )
        .firstWhere(
          (Stack s) =>
              s.children.length == 2 &&
              s.children.every((Widget c) => c is Positioned),
        );
    expect(stack.children, hasLength(2));
    final Widget platesLayer = stack.children[0]; // 先画（paint 顺序 = children 序）
    final Widget fillsLayer = stack.children[1];

    // pass 1（下层）：每胶囊一个磨砂取景框；层内无文案/填充——
    // 画布上一旦有填充先进模糊源，相邻胶囊就会串色。
    expect(
      find.descendant(of: find.byWidget(platesLayer), matching: find.byType(ClipRRect)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: find.byWidget(platesLayer), matching: find.byType(BackdropFilter)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: find.byWidget(platesLayer), matching: find.byType(Text)),
      findsNothing,
    );

    // pass 2（上层）：填充/文案/手势各 2；不包 ClipRRect、不叠 BackdropFilter
    // （单层边缘 AA；两层 AA 叠乘会把边缘覆盖率压成 c²）。
    expect(
      find.descendant(of: find.byWidget(fillsLayer), matching: find.byType(AnimatedContainer)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: find.byWidget(fillsLayer), matching: find.byType(ClipRRect)),
      findsNothing,
    );
    expect(
      find.descendant(of: find.byWidget(fillsLayer), matching: find.byType(BackdropFilter)),
      findsNothing,
    );
  });

  test('const construction stays available', () {
    // 构造断言若含 .length / 参数字段求值会封死 const 构造（回归锁，同移植体）。
    const bar = AdaptivePillTabBar(
      labels: <String>['a', 'b'],
      selectedIndex: 1,
      onTap: _noop,
    );
    expect(bar.labels, hasLength(2));
    expect(bar.selectedIndex, 1);
  });
}

void _noop(int _) {}
