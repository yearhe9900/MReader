// 开书转场「纸张滑入」（`ReaderOpenRoute`）的 widget 测试。
//
// 形态来源：负责人 2026-10-09 给的参考动效，逐帧量化结果见 docs/tech-usage.md §2.77。
// 本文件钉住四件事：
//   ① **纸张在动、书架不动**：滑入各时点，纸张左边缘从屏宽递减到 0，而书架锚点
//      坐标**一个像素都不变**（参考动效里书架是静止被压暗的，不是被推走的）；
//   ② **圆角口径**：全程保持 70dp，只在落位那一下收到 0（禁「随进度线性收角」）；
//   ③ **暗化口径**：背景黑色遮罩随滑入进度涨到 54%；
//   ④ **不依赖任何就绪信号**：内容永远不就绪，纸张也必须铺满（旧版门闸已删除）。
//
// 测量纪律：`paperLeft` 量的是 `localToGlobal` 结果（会叠加 `Transform` 的位移），
// 即「屏幕上纸在哪」，而不是读某个 widget 参数——后者会把「参数对了但渲染没应用」
// 的缺陷放过去（§2.71 探针自建的教训）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/reader_open_transition.dart';

import '../test_config.dart';

const ValueKey<String> _kShelfKey = ValueKey<String>('shelf-anchor');
const ValueKey<String> _kPaperKey = ValueKey<String>('paper-body');
const ValueKey<String> _kOpenKey = ValueKey<String>('open-button');

/// 一个最小宿主：下层是「书架」页（带一个位置固定的锚点），push [ReaderOpenRoute]。
class _Host extends StatelessWidget {
  const _Host({this.busy = false});

  /// 纸张内容是否「永远不就绪」（兜底用例）。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // 必须用 `Builder` 取一个**在 `Navigator` 之内**的 context：`_Host` 自己的
      // context 位于 `MaterialApp` 之上，`Navigator.of` 会抛
      //「context does not include a Navigator」。
      home: Builder(
        builder: (BuildContext navContext) => Scaffold(
          body: Stack(
            children: <Widget>[
              // 下层「书架」：位置写死的小锚点，用来量书架有没有被动过。
              const Positioned(
                left: 12,
                top: 80,
                child: SizedBox(key: _kShelfKey, width: 40, height: 40),
              ),
              Center(
                child: ElevatedButton(
                  key: _kOpenKey,
                  onPressed: () => Navigator.of(navContext).push(
                    ReaderOpenRoute(builder: (_) => _Paper(busy: busy)),
                  ),
                  child: const Text('open'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 阅读页替身：整屏不透明纸色（真身是 `ReaderPage`）。
class _Paper extends StatelessWidget {
  const _Paper({this.busy = false});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      key: _kPaperKey,
      child: ColoredBox(
        color: const Color(0xFFDDCC88),
        child: Center(child: Text(busy ? '载入中' : '正文已上屏')),
      ),
    );
  }
}

/// 纸张左边缘的**屏幕**坐标（含 `Transform` 位移）。
double paperLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_kPaperKey)).dx;

/// 书架锚点的屏幕坐标。
Offset shelfAt(WidgetTester tester) => tester.getTopLeft(find.byKey(_kShelfKey));

/// 屏幕逻辑宽度（与生产代码同口径取 `MediaQuery`）。
double screenWidth(WidgetTester tester) =>
    MediaQuery.sizeOf(tester.element(find.byKey(_kPaperKey))).width;

/// 纸张的圆角半径：转场层那个 `ClipRRect`（纸张的最近 `ClipRRect` 祖先）。
double paperRadius(WidgetTester tester) {
  final ClipRRect clip = tester.widget<ClipRRect>(
    find
        .ancestor(of: find.byKey(_kPaperKey), matching: find.byType(ClipRRect))
        .first,
  );
  return clip.borderRadius.resolve(TextDirection.ltr).topLeft.x;
}

/// 背景暗化层的 alpha：转场层 `Stack` 的第一个 child（`ColoredBox`）。
double scrimAlpha(WidgetTester tester) {
  final Stack stack = tester.widget<Stack>(
    find
        .ancestor(of: find.byKey(_kPaperKey), matching: find.byType(Stack))
        .first,
  );
  return (stack.children.first as ColoredBox).color.a;
}

void main() {
  capTestTimeout();

  group('开书转场「纸张滑入」', () {
    testWidgets('推入中：纸张从右侧进来、书架纹丝不动、背景被压暗、圆角还是满值',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      final double shelfX0 = shelfAt(tester).dx;

      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump(); // 起跑帧
      await tester.pump(const Duration(milliseconds: 120)); // 滑入中段

      final double paper = paperLeft(tester);
      expect(paper, greaterThan(0), reason: '中段纸张还没铺满');
      expect(paper, lessThan(screenWidth(tester)), reason: '中段纸张应已进入屏幕');

      expect(shelfAt(tester).dx, shelfX0,
          reason: '书架应纹丝不动——动的是纸，不是书架（参考动效里书架静止被压暗）');
      expect(scrimAlpha(tester), greaterThan(0));
      expect(scrimAlpha(tester), lessThan(kReaderOpenScrimAlpha),
          reason: '暗化随滑入进度推进，中段还没到终值');
      expect(paperRadius(tester), kReaderPaperRadius,
          reason: '圆角中段应保持满值——参考动效里圆角一直 70px 直到平移到位');
    });

    testWidgets('书架全程静止：滑入各时点锚点坐标零位移', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      final Offset base = shelfAt(tester);

      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump();

      int elapsed = 0;
      for (final int target in <int>[80, 160, 240, 340, 440]) {
        await tester.pump(Duration(milliseconds: target - elapsed));
        elapsed = target;
        expect(shelfAt(tester), base, reason: '$target ms 时书架锚点动了');
      }
    });

    testWidgets('位移曲线前快后慢：半程已走掉绝大部分位移（easeOutCubic）',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 230)); // 460ms 的一半

      final double width = screenWidth(tester);
      final double moved = width - paperLeft(tester);
      // easeOutCubic 半程走 87.5%；线性只有 50%，easeIn 只有 12.5%。
      expect(moved / width, greaterThan(0.7),
          reason: '前半程必须走掉大部分位移（线性 / easeIn 曲线会判红）');
    });

    testWidgets('落位：纸张铺满、圆角收回 0、暗化达终值', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pumpAndSettle();

      expect(paperLeft(tester), moreOrLessEquals(0, epsilon: 0.01));
      expect(tester.getTopLeft(find.byKey(_kPaperKey)).dy,
          moreOrLessEquals(0, epsilon: 0.01));
      expect(tester.getSize(find.byKey(_kPaperKey)).width, screenWidth(tester));
      expect(paperRadius(tester), 0,
          reason: '落位后圆角必须收掉——否则屏幕角上会缺一块（参考动效第 66 帧为 0）');
      expect(scrimAlpha(tester), closeTo(kReaderOpenScrimAlpha, 0.001));
      expect(find.text('正文已上屏'), findsOneWidget);
    });

    testWidgets('内容永远不就绪也不卡：纸张照常落位（旧门闸已删除）',
        (WidgetTester tester) async {
      // 旧版靠静态门闸等「阅读页首帧就绪」才撤遮罩；新版没有门闸——即使内容
      // 永远不报就绪，纸张也必须铺满、不留在半路翘着的状态。
      await tester.pumpWidget(const _Host(busy: true));
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pumpAndSettle();

      expect(paperLeft(tester), moreOrLessEquals(0, epsilon: 0.01));
      expect(paperRadius(tester), 0);
      expect(find.text('载入中'), findsOneWidget);
    });

    testWidgets('返回：纸张向右滑出（反向用同一转场）', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pumpAndSettle();
      expect(paperLeft(tester), moreOrLessEquals(0, epsilon: 0.01));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160)); // 反向 320ms 的一半

      expect(paperLeft(tester), greaterThan(0), reason: '返回时纸张应向右滑出');
    });

    testWidgets('时长口径 = 参考动效的 460ms', (WidgetTester tester) async {
      expect(kReaderOpenDuration.inMilliseconds, 460);
      expect(kReaderPaperRadius, 70);
      expect(kReaderOpenScrimAlpha, 0.54);
      final ReaderOpenRoute route =
          ReaderOpenRoute(builder: (_) => const SizedBox.shrink());
      expect(route.transitionDuration, kReaderOpenDuration);
    });
  });
}
