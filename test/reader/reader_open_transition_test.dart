// 开书转场遮罩（`ReaderOpenTransition` / `ReaderOpenRoute`）的 widget 测试。
//
// 钉住三件事：
//   ① **门闸语义**：阅读页首帧就绪 → 遮罩淡出；无门闸（深链/测试直进）→ no-op；
//   ② **兜底**：阅读页永不上报（异常路径）→ 转场动画播完也必须撤遮罩，
//      否则用户盯着一张封面卡死；
//   ③ **不改既有行为**：阅读页内部逻辑零改动，直进阅读页的既有测试全绿
//      （本文件只测转场层）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/reader_open_transition.dart';

import '../test_config.dart';

/// 一个最小宿主：push [ReaderOpenRoute]，页面内容是一个可被信号替换的占位。
class _Host extends StatelessWidget {
  const _Host({required this.cover});

  final Widget cover;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  ReaderOpenRoute(
                    cover: cover,
                    title: '测试书名',
                    subtitle: '正在打开…',
                    builder: (_) => const _ReaderStub(),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
}

/// 阅读页替身：首帧后发就绪信号（真实 `ReaderPage` 在 `addPostFrameCallback` 里发）。
class _ReaderStub extends StatefulWidget {
  const _ReaderStub();

  @override
  State<_ReaderStub> createState() => _ReaderStubState();
}

class _ReaderStubState extends State<_ReaderStub> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      ReaderOpenTransition.signalReady();
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('正文已上屏')));
}

void main() {
  capTestTimeout();

  group('开书转场遮罩', () {
    testWidgets('推入后遮罩在位（盖住正文），发就绪信号后淡出',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host(
        cover: ColoredBox(color: Color(0xFF888888)),
      ));
      await tester.tap(find.text('open'));
      await tester.pump(); // 推入动画第一帧
      await tester.pump(const Duration(milliseconds: 100));

      // 转场中：阅读页内容已建，但遮罩仍在上层（正文文字被遮住看不见）。
      expect(find.text('正文已上屏'), findsOneWidget);

      // 播完转场 + 淡出动画。
      await tester.pumpAndSettle();

      // 遮罩撤了：书名不再出现于遮罩层。
      expect(find.text('测试书名'), findsNothing);
      expect(find.text('正文已上屏'), findsOneWidget);
    });

    testWidgets('文字与进度条延迟出现：刚推入时书名不可见',
        (WidgetTester tester) async {
      // 若一进屏就显示书名 + 闪进度条，观感即「廉价」（第一版的 complaints 之一）。
      await tester.pumpWidget(const _Host(
        cover: ColoredBox(color: Color(0xFF888888)),
      ));
      await tester.tap(find.text('open'));
      List<double> ops() => tester
          .widgetList<Opacity>(find.byType(Opacity))
          .map((Opacity o) => o.opacity)
          .toList();

      // 推入帧：遮罩刚建（首帧可能还没建出 Opacity 节点），推进几帧到遮罩成形。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // 成形帧里必须存在一层 Opacity=0 的文字组（延迟出现，不一进屏就闪）。
      expect(ops(), contains(0.0),
          reason: '遮罩成形帧文字组应 Opacity=0（延迟出现）');

      // 随后渐入（0<v<1）——延迟确实走完了，而非永不出现。
      await tester.pump(const Duration(milliseconds: 60));
      expect(ops().any((double v) => v > 0 && v < 1), isTrue,
          reason: '文字组应处于渐入中间态');

      await tester.pumpAndSettle();
      expect(find.text('测试书名'), findsNothing, reason: '就绪后遮罩撤除');
    });

    testWidgets('无残留定时器：撤遮罩后不留下 pending timer',
        (WidgetTester tester) async {
      // 回归 R1 踩过的坑（tech-usage §2.69 附十 教训①）：`Future.delayed` 在
      // FakeAsync 下会留未清挂起物 ⇒ `A Timer is still pending` 断言。
      // 本转场的「延迟出现」用帧回调实现，故这里必须干净通过。
      await tester.pumpWidget(const _Host(
        cover: ColoredBox(color: Color(0xFF888888)),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('兜底：阅读页永不发信号，转场播完也撤遮罩',
        (WidgetTester tester) async {
      // 直接构造路由但 builder 里**不发**信号（模拟解析失败等异常路径）。
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    ReaderOpenRoute(
                      cover: const ColoredBox(color: Color(0xFF888888)),
                      title: '卡死测试',
                      builder: (_) => const Scaffold(
                        body: Center(child: Text('永不就绪')),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      // 只 pump 不 settle 到底（模拟用户盯着看），再手动推进到转场结束。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320)); // 转场时长
      await tester.pump(const Duration(milliseconds: 300)); // 淡出
      await tester.pumpAndSettle();

      // 关键：遮罩必须已撤（否则用户盯着一张封面卡死）。
      expect(find.text('卡死测试'), findsNothing);
      expect(find.text('永不就绪'), findsOneWidget);
    });

    testWidgets('无门闸时 signalReady 是 no-op（深链/直进阅读页不炸）',
        (WidgetTester tester) async {
      // 未 push 任何转场 ⇒ 无门闸；直接发信号不应抛异常。
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('x'))));
      expect(() => ReaderOpenTransition.signalReady(), returnsNormally);
      expect(ReaderOpenTransition.isActive, isFalse);
    });

    testWidgets('门闸一次性：重复发信号不重复淡出', (WidgetTester tester) async {
      var released = 0;
      ReaderOpenTransition.arm(() => released++);
      expect(ReaderOpenTransition.isActive, isTrue);

      ReaderOpenTransition.signalReady();
      expect(released, 1);
      // 一次性：闸门已清空，第二次是 no-op。
      ReaderOpenTransition.signalReady();
      expect(released, 1);
      expect(ReaderOpenTransition.isActive, isFalse);
    });

    testWidgets('disarm 撤销登记（用户立刻返回时不留悬挂回调）',
        (WidgetTester tester) async {
      var released = 0;
      ReaderOpenTransition.arm(() => released++);
      ReaderOpenTransition.disarm();
      ReaderOpenTransition.signalReady();
      expect(released, 0, reason: 'disarm 后不应再回调');
      expect(ReaderOpenTransition.isActive, isFalse);
    });
  });
}