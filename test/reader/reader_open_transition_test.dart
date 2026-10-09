// 开书转场「先按住、就绪后再滑」（`ReaderOpenRoute`）的 widget 测试。
//
// 形态来源：负责人 2026-10-09 给的参考动效，逐帧量化结果见 docs/tech-usage.md §2.77；
// 「打开书闪一下」的诊断与修法（**点书后按住、等阅读页首帧上屏再放行**）见 §2.78。
// 本文件钉住六件事：
//   ① **等待期绝对静止**：就绪信号到达之前，纸张恒停在屏幕右侧之外、暗化恒为 0、
//      书架锚点一个像素都不动（这就是「闪一下」的修法本身）；
//   ② **就绪之后才动**：信号一到，纸张立刻起滑——两者有先后，不能混在同时；
//   ③ **纸张在动、书架不动**：滑入各时点纸张左边缘从屏宽递减到 0，书架坐标不变；
//   ④ **圆角口径**：全程保持 70dp，只在落位那一下收到 0（禁「随进度线性收角」）；
//   ⑤ **暗化口径**：背景黑色遮罩随滑入进度涨到 54%；
//   ⑥ **漏报就绪不卡死**：超时兜底无条件放行；按住期间返回也不能把纸反着滑进来。
//
// 测量纪律：`paperLeft` 量的是 `localToGlobal` 结果（会叠加 `Transform` 的位移），
// 即「屏幕上纸在哪」，而不是读某个 widget 参数——后者会把「参数对了但渲染没应用」
// 的缺陷放过去（§2.71 探针自建的教训）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_open_transition.dart';
import 'package:mreader/reader/reader_page.dart';

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
    // 与生产**同形**：`ReaderPage` 也是在「正文那一帧」的**帧后回调**里报就绪的
    // （`_signalOpenReady`），不是在自己建立的那一刻——那正是「闪一下」的成因。
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

/// 纸张左边缘的**屏幕**坐标（含 `Transform` 位移）。
double paperLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_kPaperKey)).dx;

/// 「纸张完全停在屏幕右侧之外」的判据：左边缘正好在**一整张纸宽**（= 屏宽）处。
///
/// 用纸自身宽度做基准而不是 `MediaQuery`：纸是 `StackFit.expand` 铺满的一屏，
/// 两个口径应当相等，这里顺带把「纸没铺满」这类问题也钉住。
Matcher offscreenRight(WidgetTester tester) => moreOrLessEquals(
      tester.getSize(find.byKey(_kPaperKey)).width,
      epsilon: 0.01,
    );

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

/// 推 [frames] 帧（无时长 ⇒ 假时钟不动，只落帧）。
Future<void> pumpFrames(WidgetTester tester, int frames) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump();
  }
}

/// 点开书，并推进到**滑入开始的那一帧**。
///
/// 帧序（`readyFrames = r`）——两个容易踩的坑：
/// · **点书后第 1 帧纸张还没进树**：`Navigator.push` 只是让 `Overlay` 重排，
///   转场层与纸张要到**下一帧**才建起来（`initState` 里的 `hold()` 也在那一帧）；
/// · 之后第 r+2 帧的**帧后回调**才报就绪 ⇒ 放行。
/// 所以共推 `r + 2` 帧；此刻再 `pump(时长)` 才能量到位移。
Future<void> openAndStart(WidgetTester tester, {int readyFrames = 0}) async {
  await tester.tap(find.byKey(_kOpenKey));
  await pumpFrames(tester, readyFrames + 2);
}

void main() {
  capTestTimeout();

  group('开书转场「先按住、就绪后再滑」', () {
    testWidgets('未就绪就一动不动：纸停在屏幕右侧之外、一点不压暗书架',
        (WidgetTester tester) async {
      // 保留路由引用：下面要直接问 `opaque`（见循环末的断言）。
      final ReaderOpenRoute route = ReaderOpenRoute(
        builder: (_) => const _Paper(busy: true),
      );
      await tester.pumpWidget(_Host(route: route));
      final Offset shelf = shelfAt(tester);

      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump(); // 帧 1：纸张建立 ⇒ 被按住
      // 再推 40 帧（≈ 640ms，**刻意超过 460ms 的滑入时长**）：按住期间一帧都不能动。
      // 超过时长是有意的——若 `hold()` 没真的冻住进度，控制器会在这一窗口里跑完。
      for (int i = 1; i <= 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(paperLeft(tester), offscreenRight(tester),
            reason: '第 $i 帧纸张不在屏幕右侧之外了——按住期间它必须一动不动');
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

    testWidgets('先按住、就绪后才滑：信号之前纸不动，信号一到立刻起滑',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host(readyFrames: 2));
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump(); // 帧 1：路由入栈（纸张还没建）

      // 帧 2~4 = 纸张的第 1~3 帧：第 3 帧的**帧后**才报就绪 ⇒ 之前一帧都不许动。
      for (int i = 1; i <= 3; i++) {
        await tester.pump();
        expect(paperLeft(tester), offscreenRight(tester),
            reason: '纸张第 $i 帧就动了？就绪信号只能在自己那一帧的帧后才发');
      }

      // 就绪信号已到 ⇒ 下一帧起真的在滑。
      final double width = screenWidth(tester);
      await tester.pump(const Duration(milliseconds: 120));
      expect(paperLeft(tester), lessThan(width - 50),
          reason: '就绪信号之后纸张必须动起来');
      expect(scrimAlpha(tester), greaterThan(0),
          reason: '滑入开始后书架才被压暗');
    });

    testWidgets('推入中：纸张从右侧进来、书架纹丝不动、背景被压暗、圆角还是满值',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      final double shelfX0 = shelfAt(tester).dx;

      await openAndStart(tester);
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

      await openAndStart(tester);

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
      await openAndStart(tester);
      await tester.pump(const Duration(milliseconds: 230)); // 460ms 的一半

      final double width = screenWidth(tester);
      final double moved = width - paperLeft(tester);
      // easeOutCubic 半程走 87.5%；线性只有 50%，easeIn 只有 12.5%。
      expect(moved / width, greaterThan(0.7),
          reason: '前半程必须走掉大部分位移（线性 / easeIn 曲线会判红）');
    });

    testWidgets('落位：纸张铺满、圆角收回 0、暗化达终值', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await openAndStart(tester);
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

    testWidgets('漏报就绪也不卡死：超时兜底无条件放行', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host(busy: true));
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(paperLeft(tester), offscreenRight(tester),
          reason: '300ms 时还没到超时，纸仍应停在屏幕外');

      await tester.pump(kReaderOpenHoldTimeout); // 闹钟到点
      await tester.pumpAndSettle();

      expect(paperLeft(tester), moreOrLessEquals(0, epsilon: 0.01),
          reason: '超时必须无条件放行——否则漏报就绪 = 书永远打不开');
      expect(paperRadius(tester), 0);
      expect(scrimAlpha(tester), closeTo(kReaderOpenScrimAlpha, 0.001));
    });

    testWidgets('按住期间返回：立刻回书架（值停在 0 ⇒ 返回是零时长的），门闸撤销',
        (WidgetTester tester) async {
      await tester.pumpWidget(const _Host(busy: true)); // 永不就绪 = 一直按着
      await tester.tap(find.byKey(_kOpenKey));
      await tester.pump(); // 帧 1：纸张建立 + 被按住
      await tester.pump(); // 帧 2：`find` 从这一帧起能看到纸
      expect(paperLeft(tester), offscreenRight(tester));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      // 进度一直停在 0 ⇒ `reverse()` 的剩余比例是 0 ⇒ 零时长返回（`dismissed` 当场
      // 命中）⇒ 纸随路由一起退场，不该出现「纸从右侧滑出去」。卡住则是状态没到
      // `dismissed`、路由永远不被 finalize。
      expect(find.byKey(_kPaperKey), findsNothing, reason: '返回后纸张应随路由退场');
      expect(ReaderOpenTransition.isActive, isFalse,
          reason: '返回后门闸必须撤销——否则超时闹钟会替一个已经不存在的转场放行');
    });

    testWidgets('返回：纸张向右滑出（反向用同一转场）', (WidgetTester tester) async {
      await tester.pumpWidget(const _Host());
      await openAndStart(tester);
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

  // 转场的门闸要真的被阅读页推开——上面那些用例都自己发就绪信号，
  // 只有这一条覆盖「`ReaderPage` 会不会报就绪」（拆掉 `_signalOpenReady` 就没人判红）。
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
  });
}
