// 开书转场「先按住、就绪后再翻」（`ReaderOpenRoute`，右下角斜向掀页）的 widget 测试。
//
// 形态来源：参考动效的逐帧量化见 §2.77；「打开书闪一下」的诊断与修法
// （**点书后按住、等阅读页就绪再放行**）见 §2.78；斜向掀开（铰链过右下角、沿反对角线）
// 见 §2.113。放行门闸（路线 A §7③「排到目标页才上屏」，见 路线 A §7）：分页模式的
// 「就绪」= **目标语义坐标精确落位收敛**，不是「首帧上屏」——估算落位只是过渡帧，
// `_pendingLand` 二次精确落位完成前转场必须继续按住（否则翻页中视口大跳 =「开书闪动」主链）。
// §7②「占位换血出视口」：放行时刻视口必须是**真身**——可见区间内**不许**残留
// 「载入中…」占位带（`pages.isEmpty` 的 96dp 带），否则邻章「占位→真」换血的
// 高度突变发生在翻页中（开书闪动链②）。
// §2.110 补第三条「锚点布局定稿」：视口顶之前的前序章页表未定稿不放行——
// 上方高度再涨会触发超域补跳的「1 帧滑移」（落位后闪一下别的正文 = 闪屏）。
// 本文件钉住六件事：
//   ① **等待期绝对静止**：就绪信号到达之前，纸恒立在屏外（四角共线于右下角外的
//      铰链线 = 一像素不露）、暗化恒为 0、书架锚点一个像素都不动（「闪一下」的修法本身）；
//   ② **就绪之后才动**：信号一到，纸立刻起掀——两者有先后，不能混在同时；
//   ③ **右下角是翻折原点**：掀开各时点该点都钉在屏幕右下角、其余三角离位（「斜向
//      掀开」而非「整页平移 / 绕左缘翻板」），书架坐标不变；
//   ④ **圆角口径**：全程保持 70dp，只在落位那一下收到 0（禁「随进度线性收角」）；
//   ⑤ **暗化口径**：背景黑色遮罩随翻页进度涨到 54%；
//   ⑥ **漏报就绪不卡死**：超时兜底无条件放行；按住期间返回也不能把页反着翻出来。
//
// 测量纪律：量的是纸页四角 `localToGlobal` 的结果（会叠加 `Transform` 的旋转 +
// 透视除法），即「屏幕上纸的角落在哪」，而不是读某个 widget 参数——后者会把
//「参数对了但渲染没应用」的缺陷放过去（§2.71 探针自建的教训）。
// 翻页形态下**右下角钉住**、其余三角随进度归位，故「四角投影」才是掀开进度的读数。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/pagination_scheduler.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_open_transition.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/ui/default_book_cover.dart';

import '../test_config.dart';
import 'reader_harness.dart';

const ValueKey<String> _kShelfKey = ValueKey<String>('shelf-anchor');
const ValueKey<String> _kPaperKey = ValueKey<String>('paper-body');
const ValueKey<String> _kOpenKey = ValueKey<String>('open-button');

/// 一个最小宿主：下层是「书架」页（带一个位置固定的锚点），push [ReaderOpenRoute]。
class _Host extends StatelessWidget {
  const _Host({this.busy = false, this.readyFrames = 0, this.route});

  /// 纸张内容是否「永远不就绪」（兜底用例）：从不报就绪。
  final bool busy;

  /// 纸张建立后第几帧才报就绪（0 = 建立的那一帧结束后就报）。
  final int readyFrames;

  /// 外部造好的路由（要查 `overlayEntries.first.opaque` 时由用例传入）；
  /// 为 null 时按 [busy] / [readyFrames] 现场造一个。
  final ReaderOpenRoute? route;

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
                    route ??
                        ReaderOpenRoute(
                          builder: (_) =>
                              _Paper(busy: busy, readyFrames: readyFrames),
                        ),
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
class _Paper extends StatefulWidget {
  const _Paper({this.busy = false, this.readyFrames = 0});

  final bool busy;
  final int readyFrames;

  @override
  State<_Paper> createState() => _PaperState();
}

class _PaperState extends State<_Paper> {
  int _frames = 0;

  @override
  void initState() {
    super.initState();
    // 与生产**同形**：`ReaderPage` 也是在**帧后回调**里报就绪（`_signalOpenReady`），
    // 不是建立的那一刻——那正是「闪一下」的成因。生产门闸更严（分页模式要**精确
    // 落位收敛**才放行，见「真阅读页接线」组）；替身只钉「帧后才报、不早于自己那一帧」。
    if (!widget.busy) _armNextFrame();
  }

  /// 每过一帧记一次数，第 `readyFrames + 1` 帧结束时报就绪。
  ///
  /// 用 `addPostFrameCallback` 而不是 `Future.delayed`：`testWidgets` 跑在
  /// `FakeAsync` 里，定时器会在页面 dispose 后留下未清挂起物。
  void _armNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _frames++;
      if (_frames > widget.readyFrames) {
        ReaderOpenTransition.signalReady();
        return;
      }
      _armNextFrame();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      key: _kPaperKey,
      child: ColoredBox(
        color: const Color(0xFFDDCC88),
        child: Center(child: Text(widget.busy ? '载入中' : '正文已上屏')),
      ),
    );
  }
}

/// 纸页四角在屏幕上的**投影**坐标（`localToGlobal` 已含旋转 + 透视除法）。
///
/// 测量纪律：量的是「屏幕上纸的四个角落在哪」，而不是读某个 widget 参数——后者会把
/// 「参数对了但渲染没应用」的缺陷放过去（§2.71 探针自建的教训）。
List<Offset> paperCorners(WidgetTester tester) => <Offset>[
      tester.getTopLeft(find.byKey(_kPaperKey)),
      tester.getTopRight(find.byKey(_kPaperKey)),
      tester.getBottomLeft(find.byKey(_kPaperKey)),
      tester.getBottomRight(find.byKey(_kPaperKey)),
    ];

/// 屏幕矩形（与生产代码同口径取 `MediaQuery`）。
Rect screenBox(WidgetTester tester) =>
    Offset.zero & MediaQuery.sizeOf(tester.element(find.byKey(_kPaperKey)));

/// 「纸立在屏外」判据：四角投影**全部**落在屏幕右缘 / 下缘之外。
///
/// 掀页的铰链轴过右下角、沿反对角线，其另一半在屏幕**下方之外** ⇒ 纸立起来时整张
/// 纸的投影退化成那条屏外直线（四角共线），屏内一像素不露。纸是凸四边形、投影
/// 保持共线性（直线仍映射成直线），故「四角都在屏外」= 屏内看不见任何纸。
bool paperOffScreen(WidgetTester tester) {
  final Rect box = screenBox(tester);
  return paperCorners(tester).every((Offset c) =>
      c.dx >= box.right - 0.5 || c.dy >= box.bottom - 0.5);
}

/// 纸页左上角的投影：掀开时它是**最先探进屏内**的那个角（离开屏外的铰链线）。
Offset paperHead(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_kPaperKey));

/// 铰链点（屏幕右下角）在纸上的投影：绕它翻折 ⇒ 全程钉住不动。
Offset paperPivot(WidgetTester tester) =>
    tester.getBottomRight(find.byKey(_kPaperKey));

/// 书架锚点的屏幕坐标。
Offset shelfAt(WidgetTester tester) => tester.getTopLeft(find.byKey(_kShelfKey));

/// 落位判据：四角投影各自贴到屏幕四角（= 与静态阅读页**完全一致**）。
///
/// 逐个角断言而不是比外接矩形：纸一转起来外接矩形就没意义了，落位时也只有
/// 「四个角各自归位」才说明矩阵真的收到恒等（排除「中间留了一条 1px 缝」这类）。
void expectPaperFillsScreen(WidgetTester tester) {
  final Rect box = screenBox(tester);
  final List<Offset> target = <Offset>[
    box.topLeft,
    box.topRight,
    box.bottomLeft,
    box.bottomRight,
  ];
  final List<Offset> actual = paperCorners(tester);
  for (int i = 0; i < target.length; i++) {
    expect((actual[i] - target[i]).distance, lessThan(0.5),
        reason: '第 $i 个角没贴到屏幕角（实际 ${actual[i]}，应 ${target[i]}）');
  }
}

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

/// 推 [frames] 帧（无时长 ⇒ 假时钟不动，只落帧）。
Future<void> pumpFrames(WidgetTester tester, int frames) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump();
  }
}

/// 点开书，并推进到**翻页开始的那一帧**。
///
/// 帧序（`readyFrames = r`）两个坑：**点书后第 1 帧纸张还没进树**（`Navigator.push`
/// 只是让 `Overlay` 重排，转场层与纸张要到下一帧才建）；第 r+2 帧的**帧后回调**
/// 才报就绪 ⇒ 放行。故共推 `r + 2` 帧；此刻再 `pump(时长)` 才能量到翻开进度。
Future<void> openAndStart(WidgetTester tester, {int readyFrames = 0}) async {
  await tester.tap(find.byKey(_kOpenKey));
  await pumpFrames(tester, readyFrames + 2);
}

/// 真阅读页宿主：书架页一个按钮 push [ReaderOpenRoute] 包着 [buildReader] 的阅读页
/// （与「真阅读页接线」组同构；两条门闸用例共用）。
Widget _realHost(Widget Function() buildReader) => MaterialApp(
      home: Builder(
        builder: (BuildContext navContext) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: _kOpenKey,
              onPressed: () => Navigator.of(navContext).push(
                ReaderOpenRoute(builder: (_) => buildReader()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

/// 一轮一轮推（`runAsync` + `pump` 交替，与 [settle] 单轮同构）直到 [found] 为真。
///
/// 逐轮检查而不是一口气 `settle`：门闸用例要在「正文首帧上屏的那一轮」当场断言
/// `isActive`——整批推进会让断言错过现场。
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() found, {
  int maxRounds = 60,
}) async {
  for (int i = 0; i < maxRounds; i++) {
    if (found()) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump(const Duration(milliseconds: 8));
  }
  return found();
}

/// 正文视口（`reader-content-area`）内**可见**的「载入中…」占位带文本 rect。
///
/// 判据是占位文本 rect 与视口 rect 有面积交叠（`Rect.overlaps`：贴边不算）——
/// 「带在视口里」才是用户看得见的换血现场。逐个 `at(i)` 量 rect 而不是读
/// widget 参数（与本文件头「测量纪律」同理：量屏幕上真的渲染出什么）。
///
/// 正文区还没建（开书头几轮 IO 未回）→ 返回空：冷启动前几轮无从判占位，
/// 由调用方的「前提积累」（放行前是否**见过**带）兜住空转绿。
List<Rect> loadingBandsInViewport(WidgetTester tester) {
  final Finder area = find.byKey(const ValueKey<String>('reader-content-area'));
  if (area.evaluate().isEmpty) return const <Rect>[];
  final Rect viewport = tester.getRect(area);
  final Finder bands = find.textContaining('载入中');
  final List<Rect> out = <Rect>[];
  for (int i = 0; i < bands.evaluate().length; i++) {
    final Rect rect = tester.getRect(bands.at(i));
    if (rect.overlaps(viewport)) out.add(rect);
  }
  return out;
}

void main() {
  capTestTimeout();

  group('开书转场「先按住、就绪后再翻」', () {
    testWidgets('未就绪就一动不动：纸立在屏外（一像素不露）、一点不压暗书架',
        (WidgetTester tester) async {
      // 保留路由引用：下面要直接问 `opaque`（见循环末的断言）。
      final ReaderOpenRoute route = ReaderOpenRoute(
        builder: (_) => const _Paper(busy: true),
      );
      await tester.pumpWidget(_Host(route: route));
      final Offset shelf = shelfAt(tester);

      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump(); // 帧 1：纸张建立 ⇒ 被按住
      // 再推 40 帧（≈ 640ms，**刻意超过 380ms 的翻页时长**）：按住期间一帧都不能动。
      // 超过时长是有意的——若 `hold()` 没真的冻住进度，控制器会在这一窗口里跑完。
      for (int i = 1; i <= 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(paperOffScreen(tester), isTrue,
            reason: '第 $i 帧纸的投影回到屏内了（四角 ${paperCorners(tester)}）'
                '——按住期间它必须一动不动、一像素不露');
        expect(scrimAlpha(tester), 0,
            reason: '第 $i 帧书架已被压暗——等待期必须先看到书架原样（这就是「闪一下」的成因）');
        expect(shelfAt(tester), shelf, reason: '第 $i 帧书架被动过');
        // 「按住了」的真正含义是**下层继续被绘制**：`opaque` 只在动画走到 `completed`
        // 时才置回 true（`TransitionRoute._handleStatusChanged`），一旦置回，书架就
        // 不再被画、屏幕会空掉。树坐标量不到这件事，只能直接问 overlay entry。
        expect(route.overlayEntries.first.opaque, isFalse,
            reason: '第 $i 帧 opaque 被置回 true = 书架不再绘制（只冻结进度还不够）');
      }
      // 纸仍在树上：它照常 build/layout/paint，这正是「等就绪」能拿到已渲染正文的前提。
      expect(find.byKey(_kPaperKey), findsOneWidget);
    });

    testWidgets('先按住、就绪后才翻：信号之前页不动，信号一到立刻起翻',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host(readyFrames: 2));
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump(); // 帧 1：路由入栈（纸张还没建）

      // 帧 2~4 = 纸张的第 1~3 帧：第 3 帧的**帧后**才报就绪 ⇒ 之前一帧都不许动。
      for (int i = 1; i <= 3; i++) {
        await tester.pump();
        expect(paperOffScreen(tester), isTrue,
            reason: '纸张第 $i 帧就动了？就绪信号只能在自己那一帧的帧后才发');
      }

      // 就绪信号已到 ⇒ 下一帧起真的在掀：纸的左上角离开屏外的铰链线、探进屏内。
      final Rect box = screenBox(tester);
      await tester.pump(const Duration(milliseconds: 120));
      final Offset head = paperHead(tester);
      expect(head.dx, lessThan(box.right - 20),
          reason: '就绪信号之后纸必须掀开（左上角仍贴在屏外铰链线上）');
      expect(head.dy, lessThan(box.bottom - 20),
          reason: '就绪信号之后纸必须掀开（左上角还没进屏）');
      expect(scrimAlpha(tester), greaterThan(0),
          reason: '翻页开始后书架才被压暗');
    });

    testWidgets('翻页中：纸从右下角斜向展开、右下角钉住、书架纹丝不动、圆角还是满值',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      final double shelfX0 = shelfAt(tester).dx;

      await openAndStart(tester);
      await tester.pump(const Duration(milliseconds: 120)); // 掀页中段

      final Rect box = screenBox(tester);
      // 铰链原点 = 屏幕右下角：绕它翻折 ⇒ 这个点全程不动（「从右下角掀开」的判据）。
      expect((paperPivot(tester) - box.bottomRight).distance, lessThan(0.5),
          reason: '右下角必须钉在屏幕右下角——那是翻折原点，动了就是「整页平移」而非「掀开」');
      // 另三角都已离位：纸还没铺满（左上角在屏内 = 正在斜着展开）。
      final Offset head = paperHead(tester);
      expect(head.dx, lessThan(box.right - 20), reason: '中段纸还没铺满');
      expect(head.dy, lessThan(box.bottom - 20), reason: '中段纸还没铺满');
      expect(head, isNot(box.topLeft), reason: '中段不该已经落位（那就没有掀页过程了）');

      expect(shelfAt(tester).dx, shelfX0,
          reason: '书架应纹丝不动——动的是页，不是书架（参考动效里书架静止被压暗）');
      expect(scrimAlpha(tester), greaterThan(0));
      expect(scrimAlpha(tester), lessThan(kReaderOpenScrimAlpha),
          reason: '暗化随翻页进度推进，中段还没到终值');
      expect(paperRadius(tester), kReaderPaperRadius,
          reason: '圆角中段应保持满值——圆角一直 70px 直到平铺到位');
    });

    testWidgets('书架全程静止：翻页各时点锚点坐标零位移', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      final Offset base = shelfAt(tester);

      await openAndStart(tester);

      int elapsed = 0;
      // 采样点全部落在 380ms 掀页**之内**：落位后书架随路由 `opaque` 转 offstage，
      // 锚点就量不到了（`find` 默认跳过 offstage）。
      for (final int target in <int>[60, 120, 180, 240, 300, 360]) {
        await tester.pump(Duration(milliseconds: target - elapsed));
        elapsed = target;
        expect(shelfAt(tester), base, reason: '$target ms 时书架锚点动了');
      }
    });

    testWidgets('掀页曲线：起手从静止加速、半程已走掉大部分行程',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await openAndStart(tester);
      await tester.pump(kReaderOpenDuration ~/ 2); // 半程时间点

      // 暗化层 alpha = 54% × p，直接反映缓动后的进度。
      expect(scrimAlpha(tester), greaterThan(kReaderOpenScrimAlpha * 0.7),
          reason: '前半程必须走掉大部分行程（线性 / easeIn 曲线会判红）');
    });

    test('曲线两端都收力：起手不是全速、落位不硬刹（旧 easeOutCubic 生硬的一半）',
        () {
      expect(kReaderOpenCurve.transform(0), 0);
      expect(kReaderOpenCurve.transform(1), 1);
      expect(kReaderOpenCurve.transform(0.5), greaterThan(0.7),
          reason: '半程要走掉大部分行程（前快后慢的观感）');
      // 起手 5% 的时间几乎不走行程：easeOutCubic 在这里已走掉 14%（起手即全速 = 突兀）。
      expect(kReaderOpenCurve.transform(0.05), lessThan(0.05),
          reason: '起手必须从静止加速，不能一上来就全速');
      expect(kReaderOpenCurve.transform(0.95), greaterThan(0.99),
          reason: '尾段已贴住终点：软落位，不在最后一帧硬刹');
    });

    testWidgets('落位：四角贴住屏幕四角（与静态阅读页一致）、圆角收回 0、暗化达终值',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await openAndStart(tester);
      await tester.pumpAndSettle();

      expectPaperFillsScreen(tester);
      expect(paperRadius(tester), 0,
          reason: '落位后圆角必须收掉——否则屏幕角上会缺一块');
      expect(scrimAlpha(tester), closeTo(kReaderOpenScrimAlpha, 0.001));
      expect(find.text('正文已上屏'), findsOneWidget);
    });

    testWidgets('漏报就绪也不卡死：超时兜底无条件放行', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host(busy: true));
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(paperOffScreen(tester), isTrue,
          reason: '300ms 时还没到超时，纸仍应立在屏外（一像素不露）');

      await tester.pump(kReaderOpenHoldTimeout); // 闹钟到点
      await tester.pumpAndSettle();

      expectPaperFillsScreen(tester);
      expect(paperRadius(tester), 0);
      expect(scrimAlpha(tester), closeTo(kReaderOpenScrimAlpha, 0.001));
    });

    testWidgets('按住期间返回：立刻回书架（值停在 0 ⇒ 返回是零时长的），门闸撤销',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host(busy: true)); // 永不就绪 = 一直按着
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump(); // 帧 1：纸张建立 + 被按住
      await tester.pump(); // 帧 2：`find` 从这一帧起能看到纸
      expect(paperOffScreen(tester), isTrue);

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      // 进度一直停在 0 ⇒ `reverse()` 的剩余比例是 0 ⇒ 零时长返回（`dismissed` 当场
      // 命中）⇒ 纸随路由一起退场，不该出现「页合回去」的动画。卡住则是状态没到
      // `dismissed`、路由永远不被 finalize。
      expect(find.byKey(_kPaperKey), findsNothing, reason: '返回后纸张应随路由退场');
      expect(ReaderOpenTransition.isActive, isFalse,
          reason: '返回后门闸必须撤销——否则超时闹钟会替一个已经不存在的转场放行');
    });

    testWidgets('返回：纸沿斜向收回右下角（反向用同一转场，铰链不动）',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await openAndStart(tester);
      await tester.pumpAndSettle();
      expectPaperFillsScreen(tester);

      final Rect box = screenBox(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(kReaderOpenReverseDuration ~/ 2); // 反向半程

      // 纸往右下角收：左上角离开屏幕左上角（> 50px 才算真的在动）。
      final Offset head = paperHead(tester);
      expect(head.dx, greaterThan(50),
          reason: '返回时纸应沿斜向收回右下角（左上角离开屏角）');
      expect(head.dy, greaterThan(50),
          reason: '返回时纸应沿斜向收回右下角（左上角离开屏角）');
      expect((paperPivot(tester) - box.bottomRight).distance, lessThan(0.5),
          reason: '铰链钉在右下角，收合全程不动');
      expect(paperOffScreen(tester), isFalse,
          reason: '反向还没播完，纸不应已经整张退回屏外');
    });

    testWidgets('时长口径 = 380ms / 260ms（斜向掀开行程更长，曲线两端收力）',
        (WidgetTester tester) async {
      expect(kReaderOpenDuration.inMilliseconds, 380);
      expect(kReaderOpenReverseDuration.inMilliseconds, 260);
      expect(kReaderPaperRadius, 70);
      expect(kReaderOpenScrimAlpha, 0.54);
      final ReaderOpenRoute route =
          ReaderOpenRoute(builder: (_) => const SizedBox.shrink());
      expect(route.transitionDuration, kReaderOpenDuration);
      expect(route.reverseTransitionDuration, kReaderOpenReverseDuration);
    });
  });

  // 掀页几何不含任何写死的分辨率：铰链原点 = 视口右下角、轴向 = 反对角线、透视 =
  // 深度常数 / 视口边长。这一组直接量矩阵（不建 widget 树），把「竖屏手机与横屏
  // 桌面同一套观感」钉在最便宜的一层；上面那组 widget 用例跑在默认 800×600。
  group('掀页几何（纯矩阵，手机 ⇄ 桌面）', () {
    /// 把纸页局部坐标经 [m] 投影到屏幕坐标（含透视除法，与 `Transform` 渲染同口径）。
    ///
    /// 齐次坐标 w = m30·x + m31·y + m32·z + m33，纸页在 z = 0 平面上故省掉 z 项；
    /// (3,2) 位就是透视项（`m32`），不除它就等于正交投影 = 量不出「立起来」。
    Offset project(Matrix4 m, Offset p) {
      final double w = m.storage[3] * p.dx + m.storage[7] * p.dy + m.storage[15];
      return Offset(
        (m.storage[0] * p.dx + m.storage[4] * p.dy + m.storage[12]) / w,
        (m.storage[1] * p.dx + m.storage[5] * p.dy + m.storage[13]) / w,
      );
    }

    for (final Size size in <Size>[
      const Size(393, 852), // 竖屏手机
      const Size(1440, 900), // 横屏桌面窗口
    ]) {
      final String tag = '${size.width.toInt()}×${size.height.toInt()}';
      final List<Offset> corners = <Offset>[
        Offset.zero,
        Offset(size.width, 0),
        Offset(0, size.height),
        Offset(size.width, size.height),
      ];

      test('$tag：立起时四角全在屏外（一像素不露）', () {
        final Matrix4 m = readerOpenPeelTransform(size, 1);
        for (final Offset c in corners) {
          final Offset q = project(m, c);
          expect(q.dx >= size.width - 0.5 || q.dy >= size.height - 0.5, isTrue,
              reason: '$tag 下 $c 投影到 $q：落在屏内 = 立起时漏出纸边');
        }
      });

      test('$tag：右下角是翻折原点，全程钉住', () {
        final Offset pivot = Offset(size.width, size.height);
        for (final double tilt in <double>[1, 0.5, 0]) {
          final Offset q = project(readerOpenPeelTransform(size, tilt), pivot);
          expect((q - pivot).distance, lessThan(0.01),
              reason: '$tag 下 tilt=$tilt 时右下角跑了 —— 铰链不在右下角（会退化成整页平移）');
        }
      });

      test('$tag：平铺 = 恒等（四角各归屏幕角，布局与正文一丝不动）', () {
        final Matrix4 m = readerOpenPeelTransform(size, 0);
        for (final Offset c in corners) {
          expect((project(m, c) - c).distance, lessThan(0.01),
              reason: '$tag 下 $c 落位到 ${project(m, c)}：落位后必须与静态阅读页一致');
        }
      });
    }

    test('透视随视口反比缩放：窄屏不压扁、大窗口不退化成正交', () {
      final double phone = readerOpenPerspective(const Size(393, 852));
      final double desktop = readerOpenPerspective(const Size(1440, 900));
      expect(phone, greaterThan(desktop),
          reason: '窄屏需要更强的透视才看得出「纸立起来」');
      // 「透视项 × 视口边长」是同一常数 ⇒ 两种尺寸下的立体感同量级。
      expect(phone * 852, closeTo(desktop * 1440, 0.05));
    });
  });

  // 转场的门闸要真的被阅读页推开——上面那些用例都自己发就绪信号，
  // 这一组覆盖「`ReaderPage` 会不会报就绪、**什么时候**报就绪」
  // （拆掉 `_signalOpenReady` 就没人判红；门闸改「精确落位收敛才放行」后，
  // 「长章深位恢复」那条钉住放行时机——首帧上屏不许放）。
  group('开书转场 ⇄ 真阅读页接线', () {
    late Directory tempDir;
    late TestAppPaths paths;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_open_gate_');
      paths = TestAppPaths(tempDir);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    testWidgets('真阅读页经 ReaderOpenRoute 打开：就绪信号会到，不是靠 3 秒兜底',
        (WidgetTester tester) async {
      final ProgressStore progressStore = ProgressStore(paths);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext navContext) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: _kOpenKey,
                  onPressed: () => Navigator.of(navContext).push(
                    ReaderOpenRoute(
                      builder: (_) => ReaderPage(
                        source: FakeBookSource(),
                        record: fakeRecord(),
                        progressStore: progressStore,
                        repository: fakeRepository(paths),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(_kOpenKey));
      // 帧 2 起阅读页与转场层才建起来（`Overlay` 重排要一帧）；
      // 此刻 `_open()` 的真 IO 还没跑完 ⇒ 门闸已被按住，就绪信号还没到。
      await settle(tester, rounds: 2);
      expect(ReaderOpenTransition.isActive, isTrue,
          reason: '点书后转场应当先按住等阅读页就绪');

      // 阅读页里的真异步 IO（进度 / 偏好 / 书源解析）在 FakeAsync 区不会自行推进，
      // 必须用 harness 的 `settle` 交替「真实事件循环 + 帧」。
      // 上限 300 帧 × 8ms ≈ 2.4s 假时钟，仍**短于** 3s 兜底闸——超时放行的话
      // 下面那条断言就会红，不会被兜底掩盖。
      for (int i = 0; i < 15 && ReaderOpenTransition.isActive; i++) {
        await settle(tester, rounds: 20);
      }

      expect(ReaderOpenTransition.isActive, isFalse,
          reason: '阅读页没报就绪：纸张会被按到 3 秒超时才滑进来（书打开慢三秒）');
      // 真阅读页上没有测试用的 `_kPaperKey`，量 `ReaderPage` 自身的位置。
      // 推两次 600ms：放行若恰好落在「第一次 tick」上，那一帧的 elapsed 是 0。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.getTopLeft(find.byType(ReaderPage)).dx,
          moreOrLessEquals(0, epsilon: 0.01),
          reason: '放行之后纸张应正常落位');

      await closeBook(tester);
    });

    testWidgets('延迟书源（点击即开书）：骨架首帧放行滑入，落位收敛后才揭幕',
        (WidgetTester tester) async {
      // 书架「点击即开书」管道：push 时不等建源（`sourceFuture` 挂闸），阅读页
      // 先铺骨架屏、首帧放行纸张滑入；但正文仍被骨架**盖住**（揭幕闩），
      // 落位门闸通过才揭——否则「估算→精确」大跳发生在可见纸面上 = 闪屏。
      final ProgressStore progressStore = ProgressStore(paths);
      final Completer<BookSource> gate = Completer<BookSource>();
      await tester.pumpWidget(_realHost(() => ReaderPage(
            sourceFuture: gate.future,
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));
      // 推几帧（不给 runAsync）：书源闸未放，正文区应是骨架屏。
      await settle(tester, rounds: 4);
      expect(
        find.byKey(const ValueKey<String>('reader-skeleton')),
        findsOneWidget,
        reason: '书源未就绪时正文区应铺骨架屏（点击即开书的视觉主体）',
      );
      // 幕布内容 = 本书封面：无封面书用占位封面（书名哈希取色，零 IO 首帧即出）。
      expect(find.byType(DefaultBookCover), findsOneWidget,
          reason: '骨架幕布应显示图书封面（无封面书用占位封面）');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('reader-skeleton')),
          matching: find.text(fakeRecord().title),
        ),
        findsOneWidget,
        reason: '占位封面上应有本书书名（点击即开书第一眼：这是哪本书）',
      );
      // 骨架首帧即放行滑入：转场不该按到 3s 兜底，此刻已不在等待。
      expect(ReaderOpenTransition.isActive, isFalse,
          reason: '骨架屏首帧上屏即应放行纸张滑入（不再等正文就绪）');

      // 放开书源闸 → 既有开书链路接管；正文在骨架**之下**构建、落位，
      // 收敛揭幕后骨架退场。
      gate.complete(FakeBookSource());
      final bool revealed = await pumpUntil(tester,
          () => find.byKey(const ValueKey<String>('reader-skeleton')).evaluate().isEmpty &&
              find.textContaining('第1章正文').evaluate().isNotEmpty);
      expect(revealed, isTrue,
          reason: '书源到手 + 落位收敛后应揭幕（骨架退场、正文可见）');

      await closeBook(tester);
    });

    testWidgets('延迟书源揭幕闩：正文首现于骨架之下（估算落位大跳不发生在可见纸面）',
        (WidgetTester tester) async {
      // 「点击即开书」的闪屏回归防线：长章 + 恢复到 90% ⇒ 二次精确落位必然晚于
      // 正文首现。揭幕闩必须在这段窗口里**仍然盖着**——正文 widget 已在树上
      // （构建 / 落位照跑），但骨架幕布不得撤。
      final ProgressStore progressStore = ProgressStore(paths);
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h1',
            chapterIndex: 0,
            chapterPos: 0.9,
            updatedAt: 1,
          ),
        ),
      );
      final Completer<BookSource> gate = Completer<BookSource>();
      await tester.pumpWidget(_realHost(() => ReaderPage(
            sourceFuture: gate.future,
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));
      await settle(tester, rounds: 2);
      expect(ReaderOpenTransition.isActive, isFalse, reason: '骨架首帧已放行滑入');

      gate.complete(FakeBookSource(paragraphCounts: const <int>[3000]));
      // 逐轮推进，盯「正文 widget 首次进树」那一刻：幕布必须仍在。
      // ⚠️ 先等幕布**出现**（书源就绪 → `_ready` 才起幕）再等它撤——直接盯
      // 「幕布已撤」会在起幕前的空窗里误判为真、用例空转绿。
      bool sawCoveredContent = false;
      final bool covered = await pumpUntil(tester,
          () => find
              .byKey(const ValueKey<String>('reader-skeleton-cover'))
              .evaluate()
              .isNotEmpty,
          maxRounds: 100);
      expect(covered, isTrue, reason: '书源就绪后应起骨架幕布（前提）');
      final bool revealed = await pumpUntil(tester, () {
        if (!sawCoveredContent &&
            find.textContaining('第1章正文').evaluate().isNotEmpty) {
          sawCoveredContent = true;
        }
        return find
            .byKey(const ValueKey<String>('reader-skeleton-cover'))
            .evaluate()
            .isEmpty;
      }, maxRounds: 300);
      expect(sawCoveredContent, isTrue,
          reason: '正文应在骨架幕布**之下**首现（否则本用例什么都没测到）');
      expect(revealed, isTrue,
          reason: '落位收敛后幕布必须撤（拖到 3s 兑底才揭会判红）');
      // 揭幕后视口已稳：再推几轮不再跳。
      final PagedScrollerState scroller =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      final double landed = scroller.offset;
      await settle(tester, rounds: 10);
      final PagedScrollerState after =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      expect(after.offset, moreOrLessEquals(landed, epsilon: 0.5),
          reason: '揭幕后视口不允许再跳——二次精确落位必须发生在揭幕之前');

      await closeBook(tester);
    });

    testWidgets('延迟书源失败：骨架屏换错误提示（而非白屏 / 转圈）',
        (WidgetTester tester) async {
      final ProgressStore progressStore = ProgressStore(paths);
      final Completer<BookSource> gate = Completer<BookSource>();
      await tester.pumpWidget(_realHost(() => ReaderPage(
            sourceFuture: gate.future,
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));
      await settle(tester, rounds: 4);
      expect(find.byKey(const ValueKey<String>('reader-skeleton')),
          findsOneWidget);

      gate.completeError(const MReaderFormatException(FormatErrorCode.fileMissing));
      // `find` 不管可见性（幕布只是绘制层）——盯**骨架退场**（揭幕闩撤除）才是
      //「错误提示真的可见」的判据；顺带积累前提：错误文本确已进树。
      bool sawErrorText = false;
      final bool revealed = await pumpUntil(tester, () {
        if (find.textContaining('文件已丢失').evaluate().isNotEmpty) {
          sawErrorText = true;
        }
        return sawErrorText &&
            find.byKey(const ValueKey<String>('reader-skeleton')).evaluate().isEmpty;
      });
      expect(sawErrorText, isTrue,
          reason: '准备失败应落到阅读页错误态（用户可见中文提示）');
      expect(revealed, isTrue,
          reason: '错误态不得残留骨架屏（揭幕闩须在错误路径上也撤除）');

      await closeBook(tester);
    });

    testWidgets('放行门闸=精确落位：估算落位期间按住不放，落位收敛后才放行',
        (WidgetTester tester) async {
      // 3000 段长章 + 恢复到 90%：prime 突发（kFirstPaintBudget 16ms）够不到
      // 目标 ⇒ `_primeOpenSync` 走**估算分支**挂 `_pendingLand`（两段式落位），
      // 二次精确落位要等空闲帧排完长尾段落。这正是「开书闪动」机制链①的现场。
      final ProgressStore progressStore = ProgressStore(paths);
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h1',
            chapterIndex: 0,
            chapterPos: 0.9,
            updatedAt: 1,
          ),
        ),
      );
      await tester.pumpWidget(_realHost(() => ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[3000]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));

      // ① 正文段落首次上屏时，二次精确落位必然还没完成（长章要排到 90% 处）——
      // 转场必须**仍被按住**。「首帧上屏即放行」会在这之前就放，估算位置 → 精确
      // 位置的大跳发生在纸张滑入中（闪动主链）。
      final bool seen = await pumpUntil(
          tester, () => find.textContaining('第1章正文').evaluate().isNotEmpty);
      expect(seen, isTrue, reason: '正文段落应已上屏（估算落位过渡帧）');
      expect(ReaderOpenTransition.isActive, isTrue,
          reason: '首帧上屏≠可放行：估算落位只是过渡帧，'
              '精确落位（_pendingLand 收敛）未完成前转场必须继续按住');

      // ② 放行必须来自落位收敛、不是 3s 兜底（循环上限 2.4s 假时钟 < 3s 兜底闸）。
      for (int i = 0; i < 15 && ReaderOpenTransition.isActive; i++) {
        await settle(tester, rounds: 20);
      }
      expect(ReaderOpenTransition.isActive, isFalse,
          reason: '精确落位收敛后必须放行（拖到 3s 兜底才放行会判红）');

      // ③ 放行时视口已在目标语义坐标并稳：采样贴住 0.9×总字数，之后不再跳。
      final PagedScrollerState scroller =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      int total = 0;
      for (int p = 1; p <= 3000; p++) {
        total += '第1章正文$p'.length;
      }
      final int targetChar = (0.9 * total).round();
      final sample = scroller.sampleNow();
      expect(sample, isNotNull);
      expect(sample!.charOffset, inInclusiveRange(targetChar - 40, targetChar + 40),
          reason: '放行时视口顶应落在目标语义坐标行'
              '（估算位置在章头一带，与目标差约两万字符）');
      final double landed = scroller.offset;
      await settle(tester, rounds: 10);
      final PagedScrollerState after =
          tester.state<PagedScrollerState>(find.byType(PagedScroller));
      expect(after.offset, moreOrLessEquals(landed, epsilon: 0.5),
          reason: '放行后视口不允许再跳——二次精确落位必须发生在放行之前');

      await closeBook(tester);
    });

    testWidgets('放行门闸=视口真身：放行帧不许残留「载入中」占位带',
        (WidgetTester tester) async {
      // 开书闪动机制链②：放行帧视口内残留「载入中…」占位带时，随后邻章
      // 「占位→真」换血的高度突变就发生在纸张滑入中。夹具刻意把**首章压到 2 段**
      // （远小于视口）⇒ 第 2/3 章占位带必然落进首屏；「收敛即放行」会在它们
      // 排完页表之前就放行（换血 pop-in 发生在滑入中）。
      final ProgressStore progressStore = ProgressStore(paths);
      await tester.pumpWidget(_realHost(() => ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[2, 20, 20]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));
      // 先推 2 轮让转场 arm 起来（同「空段章」用例：`tap` 后不 pump 的话
      // `isActive` 恒 false、「等放行」循环一次都不跑、用例空转绿）。
      await settle(tester, rounds: 2);
      expect(ReaderOpenTransition.isActive, isTrue,
          reason: '转场应已 arm 并按住（本用例的前提，防断言空转）');

      // 逐轮推进盯**放行的那一轮**当场量（一口气 settle 会让断言错过现场：
      // 放行后数轮占位带就换真了）。顺带积累前提：放行前视口里真出现过
      // 占位带——夹具几何不对时前提判红，防「什么都没测到」的空转绿。
      // 上限 200 轮 × 8ms ≈ 1.6s 假时钟 < 3s 兜底——靠兜底放行会判红。
      bool sawBand = false;
      final bool released = await pumpUntil(tester, () {
        if (loadingBandsInViewport(tester).isNotEmpty) sawBand = true;
        return !ReaderOpenTransition.isActive;
      }, maxRounds: 200);
      expect(sawBand, isTrue,
          reason: '前提：放行前视口内应出现过「载入中」占位带（夹具几何）');
      expect(released, isTrue,
          reason: '门闸应放行（且不是 3s 兜底——上限 1.6s 假时钟）');
      expect(loadingBandsInViewport(tester), isEmpty,
          reason: '放行帧视口内残留「载入中」占位带：随后「占位→真」换血的'
              '高度突变发生在纸张滑入中（开书闪动链②）');

      await closeBook(tester);
    });

    testWidgets('空段章开书：无可落位内容=已在目标位，门闸及时放行不等 3s 兜底',
        (WidgetTester tester) async {
      // 门闸的防回归护栏：空段章没有可滚动内容，`_pagedJumpTo` 载正文后即到
      // 目标位（无可落位）——若门闸只认「精确落位收敛」而忘了这条空路，
      // 空段章开书会一直按到 3s 兜底（书打开慢三秒）。
      final ProgressStore progressStore = ProgressStore(paths);
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h1',
            chapterIndex: 0,
            chapterPos: 0.0,
            updatedAt: 1,
          ),
        ),
      );
      await tester.pumpWidget(_realHost(() => ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[0]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));
      // 先推 2 轮让转场 arm 起来——`tap` 后不 pump 的话 `isActive` 恒 false，
      // 「等放行」循环一次都不跑、用例空转绿。
      await settle(tester, rounds: 2);
      expect(ReaderOpenTransition.isActive, isTrue,
          reason: '转场应已 arm 并按住（本用例的前提，防断言空转）');
      // 上限 15×20 轮 ≈ 2.4s 假时钟，仍短于 3s 兜底——靠兜底放行会判红。
      for (int i = 0; i < 15 && ReaderOpenTransition.isActive; i++) {
        await settle(tester, rounds: 20);
      }
      expect(ReaderOpenTransition.isActive, isFalse,
          reason: '空段章无可落位内容（语义坐标即达），门闸必须及时放行');

      await closeBook(tester);
    });

    testWidgets('开书滑入期零排版：放行即冻结排版，落定解冻且预热自动续跑',
        (WidgetTester tester) async {
      // 保证③「动画期零排版」覆盖开书滑入（§2.109）：滑入的每一帧都贵（整页纸
      // 合成），空闲分页切片 / 补齐批挤进动画帧就是丢帧（用户实测「打开图书
      // 过程丢帧」）。钉住冻结配对（与 `page_turn_wiring_test` 保证③同款口径）
      // + 落定后的续跑：帧链在窗内就地停摆，漏了重启会把排版永久挂死。
      final ProgressStore progressStore = ProgressStore(paths);
      await tester.pumpWidget(_realHost(() => ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[2, 200, 20]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));
      // 先推 2 轮让转场 arm 起来（同上：不 pump 的话 `isActive` 恒 false，
      // 「等放行」循环一次都不跑、用例空转绿）。
      await settle(tester, rounds: 2);
      expect(ReaderOpenTransition.isActive, isTrue,
          reason: '转场应已 arm 并按住（本用例的前提，防断言空转）');
      final PaginationScheduler scheduler =
          sharedPaginationSchedulers.forBook(fakeRecord().bookId);

      // 等放行（逐轮 8ms；上限 200 轮 ≈ 1.6s 假时钟 < 3s 兜底）。
      final bool released =
          await pumpUntil(tester, () => !ReaderOpenTransition.isActive,
              maxRounds: 200);
      expect(released, isTrue, reason: '门闸应放行（且不是 3s 兜底）');
      expect(scheduler.frozen, isTrue,
          reason: '放行即冻结排版（动画期零排版，保证③）');

      // 滑入中段（320ms 动画的前 ~56ms）推进几帧仍须冻着。
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scheduler.frozen, isTrue, reason: '滑入未落定不许解冻');

      // 落定（路由动画 completed）解冻（同翻页动画的「收尾解冻」）。
      final bool settled =
          await pumpUntil(tester, () => !scheduler.frozen, maxRounds: 100);
      expect(settled, isTrue, reason: '转场落定必须解冻');

      // 落定后预热管线自动续跑直至排干（重启漏了 = hasWork 永挂，这里判红）。
      final bool drained = await pumpUntil(
          tester,
          () => !scheduler.hasWork && loadingBandsInViewport(tester).isEmpty,
          maxRounds: 400);
      expect(drained, isTrue, reason: '落定后分页 / 补齐须自动续跑排干');

      await closeBook(tester);
    });

    testWidgets('门闸第三条=锚点布局定稿：前序章页表未定稿不放行（防落位后闪屏）',
        (WidgetTester tester) async {
      // 落位后闪屏定案（§2.110）：前序章页表还在补时上方高度会继续涨，同一
      // 语义坐标的像素偏移跟着涨（真机 d≈8518px），`_jumpPaged` 超域补跳
      // 「接受 1 帧滑移」——那一帧视口顶是**完全另一段正文**，随后猛跳回来。
      // 故门闸补第三条：放行时前序章页表必须已定稿。夹具：恢复到第 2 章
      // （书首之后），第 1 章 2000 段压在视口顶之上、要补很多帧——它定稿前
      // 门闸必须按住，定稿后才放行。
      final ProgressStore progressStore = ProgressStore(paths);
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h2',
            chapterIndex: 1,
            chapterPos: 0.0,
            updatedAt: 1,
          ),
        ),
      );
      await tester.pumpWidget(_realHost(() => ReaderPage(
            source: FakeBookSource(paragraphCounts: const <int>[2000, 2, 2]),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          )));
      await tester.tap(find.byKey(_kOpenKey));
      await settle(tester, rounds: 2);
      expect(ReaderOpenTransition.isActive, isTrue,
          reason: '转场应已 arm 并按住（本用例的前提）');
      final PaginationScheduler scheduler =
          sharedPaginationSchedulers.forBook(fakeRecord().bookId);

      // 逐轮推进：正文（第 2 章）已上屏 = 落位已成；只要前序章（h1）页表
      // 未定稿就仍须按住——这个现场必须真实出现过，防夹具几何不对的空转绿。
      bool sawHolding = false;
      final bool released = await pumpUntil(tester, () {
        final PaginationConfig? cfg = scheduler.config;
        if (cfg != null &&
            scheduler.cache.peek('h1', cfg) == null &&
            find.textContaining('第2章正文').evaluate().isNotEmpty) {
          sawHolding = true;
        }
        return !ReaderOpenTransition.isActive;
      }, maxRounds: 300);
      expect(sawHolding, isTrue,
          reason: '前提：正文已上屏而前序章页表未定稿的现场应出现过（防空转绿）');
      expect(released, isTrue, reason: '前序章定稿后门闸应放行（且不是 3s 兜底）');
      expect(scheduler.config, isNotNull);
      expect(scheduler.cache.peek('h1', scheduler.config!), isNotNull,
          reason: '放行时刻前序章页表必须已定稿——否则落位后上方高度再涨 = 闪屏');

      await closeBook(tester);
    });
  });
}
