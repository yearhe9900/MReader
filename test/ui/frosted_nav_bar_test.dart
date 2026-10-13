// 自磨砂伪玻璃底栏 [FrostedNavBar] 的契约测试（2026-10-12 参考图复刻批）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 本文件钉什么
// ══════════════════════════════════════════════════════════════════════════════
// 参考图**原生截图**实测值换算出的几何（实测记录见 `nav_bar_style.dart` 文件头）：
//   · 标签中心**严格等分**（实测间距 184 / 185 / 183）⇒ 按`可用宽 / n` 均分；
//   · 选中块宽 = 格宽的 **114%**（实测 x 57..266 ⇒ 宽 210/ 格宽 184），
//     即**向两侧溢出**格子；选中块中心与标签中心对齐（实测差 1.5px）；
//   · 选中块高 = 栏体高的 **0.93**（实测 115/ 124），圆角 = 高 / 2（胶囊）；
//   · 栏体 62 高 / 左右外边距 13 / 浮起 27。
//
// ⚠️ 几何值在 2026-10-12 → 10-13 之间**返工过一次**：10-12 用**二次压缩的
// 录屏帧**测得「选中块占格宽 69%」并据此判定更早的 109% 是量错对象；10-13 用
// **原生截图**重测发现压缩帧不可靠（原生图里选中块宽 210 > 格宽 184，目视也
// 明显是占满一格的宽块）。⇒ 测量参考图**必须用原生截图**，压缩帧会抹平边界。
//
// 这些是「用库时拿不到」的部分（库的指示块宽度由内部计算、`spacing: 8` 还会
// 破坏等分），所以必须钉死——回潮即红。
//
// 断言一律**硬编码字面量**，不引用 `NavBarStyle` 的常量：引用即同义反复、
// 永远红不了（同 `overlay_style_test` / `glass_material_test` 的口径）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/frosted_nav_bar.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/nav_bar_style.dart';

import '../test_config.dart';

/// 三个最小标签（文案避开「书架」防撞车）。
const List<NavTab> _kTabs = <NavTab>[
  NavTab(icon: Icons.list, activeIcon: Icons.list, label: '目录'),
  NavTab(icon: Icons.settings, activeIcon: Icons.settings, label: '设置'),
  NavTab(icon: Icons.star, activeIcon: Icons.star, label: '收藏'),
];

/// **镜像真实调用方式**的宿主（2026-10-12 实测踩坑修正）。
///
/// 真机是 `home_shell` 的 `Stack + Positioned(bottom: 0)`——**松约束**。若测试
/// 直接把底栏当 `MaterialApp.home`（**紧约束**，整屏 800×600），里面的
/// `SizedBox(height: barHeight)` 会被顶成整屏高（实测栏体 582 而非 62），
/// 几何与拖动断言全部失真。故宿主必须复刻 `Stack + Positioned`。
///
/// 底栏下方垫一块深色——`BackdropFilter` 要有可采样的内容才看得出磨砂，且深色
/// 底能顺带验证「纱罩确实把背景提亮了一档」。
Widget _navHost(
  GlassQualityTier tier, {
  int selectedIndex = 0,
  required void Function(int) onTabSelected,
}) {
  return MaterialApp(
    home: GlassScopeProvider(
      config: glassTierConfigFor(tier),
      child: Stack(
        children: <Widget>[
          const Positioned.fill(child: ColoredBox(color: Color(0xFF303030))),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FrostedNavBar(
              tabs: _kTabs,
              selectedIndex: selectedIndex,
              onTabSelected: onTabSelected,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 栏体（外壳）的 rect——**第一个** [ClipRRect] 是外壳，`last` 是选中块。
Finder _shellFinder() => find.byType(ClipRRect).first;

/// 选中块（在内层）的 rect。
Finder _pillFinder() => find.byType(ClipRRect).last;

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  group('几何：实测值字面量契约', () {
    testWidgets('栏体尺寸：62 高 / 左右 13 / 浮起 27', (WidgetTester tester) async {
      expect(NavBarStyle.barHeight, 62);
      expect(NavBarStyle.horizontalPadding, 13);
      expect(NavBarStyle.verticalPadding, 27);
      expect(NavBarStyle.barRadius, 31);
      // 标签等分 ⇒ 额外间距必须是 0（库的 spacing: 8 正是破坏等分的元凶）。
      expect(NavBarStyle.tabSpacing, 0);
    });

    testWidgets('选中块：宽 = 格宽 ×114%、高 = 栏高 ×0.93、圆角 = 高/2',
        (WidgetTester tester) async {
      // 1.14 来自**原生截图**实测（宽 210 / 格宽 184），见文件头。
      expect(NavBarStyle.pillWidthFactor, 1.14);
      expect(NavBarStyle.pillHeightFactor, 0.93);
      expect(NavBarStyle.pillRadius(62 * 0.93), closeTo(28.83, 0.01));
    });

    testWidgets('栏体实际渲染尺寸 = 62 高（松约束下不被顶高）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 这条正是「宿主必须镜像 Stack + Positioned」的护栏：紧约束下这里会是
      // 582（实测踩过），松约束下才是 62。
      expect(tester.getSize(_shellFinder()).height, 62);
      // 左右各留 16。
      expect(tester.getSize(_shellFinder()).width, 800 - 13 * 2);
      // 距屏幕底边 18。
      expect(
        600 - tester.getBottomLeft(_shellFinder()).dy,
        27,
        reason: '底栏应浮起 18（verticalPadding）',
      );
    });

    testWidgets('标签区侧内缩 = 0.25 格宽（参考图实测侧留白/格宽 = 0.2446/0.25）',
        (WidgetTester tester) async {
      // 参考图原生截图：栏体 x 26..853（828）、标签区 x 71..807（736）
      // ⇒ 侧留白 45/46，除以格宽 184 得0.2446 / 0.2500。
      expect(
        NavBarStyle.sideInsetCellFactor,
        0.25,
        reason: '侧内缩是参考图真实特征；缺了它 114% 宽的选中块会贴栏体边框',
      );
      // 解方程：标签区宽 W = 可用宽 / (1 + 2k/n)
      const int n = 4;
      const double available = 828;
      final double w = available / (1 + 2 * 0.25 / n);
      expect(w, closeTo(736, 1));   // 实测标签区宽 736
      expect(w / n, closeTo(184, 1)); // 实测格宽 184
    });

    testWidgets('标签区居中 + 严格等分：第 N 格中心 = 标签区左缘 + 格宽×(N+0.5)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(592, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      final double shellLeft = tester.getTopLeft(_shellFinder()).dx;
      final double shellWidth = tester.getSize(_shellFinder()).width;
      final int n = _kTabs.length;
      // ⚠️ 标签区**不是**占满栏体：实测参考图标签区居中 + 侧留白 0.25 格宽。
      // 用`可用宽 / n` 当格宽会算错中心（这一条曾按旧公式写，漏掉了内缩）。
      final double labelAreaWidth =
          shellWidth / (1 + 2 * NavBarStyle.sideInsetCellFactor / n);
      final double sideInset = (shellWidth - labelAreaWidth) / 2;
      final double cell = labelAreaWidth / n;

      for (int i = 0; i < n; i++) {
        final Rect r = tester.getRect(find.text(_kTabs[i].label));
        expect(
          r.center.dx,
          closeTo(shellLeft + sideInset + cell * (i + 0.5), 1.5),
          reason: '第 $i 格标签未落在等分中心（实测要求严格等分）',
        );
      }
    });

    testWidgets('⭐ 首/末格选中块与栏体边框有间距（不触边）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(592, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 选第 1 格：114% 宽的选中块向两侧溢出，若无侧内缩就会贴到栏体边框。
      await tester.pumpWidget(_navHost(
        GlassQualityTier.high,
        selectedIndex: 0,
        onTabSelected: _noop,
      ));
      await tester.pumpAndSettle();

      final Rect shell = tester.getRect(_shellFinder());
      final Rect pill = tester.getRect(_pillFinder());

      expect(
        pill.left - shell.left,
        greaterThan(4.0),
        reason: '首格选中块左缘须离栏体边框留距离（实测参考图 15.5dp）',
      );
      // 首格选中块右缘也不该越过栏体中线太多（保证没跑偏）。
      expect(pill.left - shell.left, lessThan(shell.width / 4));

      // 末格同样。
      await tester.pumpWidget(_navHost(
        GlassQualityTier.high,
        selectedIndex: _kTabs.length - 1,
        onTabSelected: _noop,
      ));
      await tester.pumpAndSettle();
      final Rect lastPill = tester.getRect(_pillFinder());
      expect(
        shell.right - lastPill.right,
        greaterThan(4.0),
        reason: '末格选中块右缘须离栏体边框留距离',
      );
      // 左右边距应对称（标签区居中）。
      expect(
        (pill.left - shell.left) - (shell.right - lastPill.right),
        closeTo(0, 1.5),
        reason: '标签区居中 ⇒ 首末边距对称',
      );
    });

    testWidgets('选中块实测：宽 = 格宽 ×1.14、高 = 栏高 ×0.93、圆角 = 高/2',
        (WidgetTester tester) async {
      // 参考图**原生截图**（881×1920@2x）实测：选中块 x 57..266 ⇒ 宽 210；
      // 标签中心间距 184 ⇒ `210 / 184 = 1.14`。
      tester.view.physicalSize = const Size(592, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_navHost(
        GlassQualityTier.high,
        selectedIndex: 1,
        onTabSelected: _noop,
      ));
      await tester.pumpAndSettle();

      final double shellLeft = tester.getTopLeft(_shellFinder()).dx;
      // 标签区有侧内缩（0.25 格宽），格宽按标签区宽算，不是栏宽。
      final double shellWidth = tester.getSize(_shellFinder()).width;
      final double labelAreaWidth = shellWidth /
          (1 + 2 * NavBarStyle.sideInsetCellFactor / _kTabs.length);
      final double sideInset = (shellWidth - labelAreaWidth) / 2;
      final double cell = labelAreaWidth / _kTabs.length;
      final Rect pill = tester.getRect(_pillFinder());

      expect(pill.width, closeTo(cell * 1.14, 1.0));
      // ⭐ 钉住「选中块**向两侧溢出**格子」这个实测特征（宽 210 > 格宽 184）。
      // 曾经的 0.69（来自二次压缩的录屏帧）会让底衬明显偏窄，与参考图不符。
      expect(
        pill.width,
        greaterThan(cell),
        reason: '参考图实测选中块宽 210 > 格宽 184，即溢出格子',
      );
      expect(pill.height, closeTo(62 * 0.93, 1.0));
      final BorderRadius radius = tester
          .widget<ClipRRect>(_pillFinder())
          .borderRadius
          .resolve(TextDirection.ltr);
      expect(radius.topLeft.x, closeTo(pill.height / 2, 0.5));
      // 中心与第 2 格（index 1）对齐（须含侧内缩）。
      expect(pill.center.dx, closeTo(shellLeft + sideInset + cell * 1.5, 1.5));
    });
  });

  group('磨砂伪玻璃结构', () {
    testWidgets('两个 BackdropFilter（栏体 + 选中块）+ 半透纱罩',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 磨砂的关键证据：栏体与选中块各一层。
      expect(find.byType(BackdropFilter), findsNWidgets(2));
      // 纱罩必须半透（纯色 = 磨砂失效）。
      final Iterable<double> alphas = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((DecoratedBox d) => d.decoration is BoxDecoration)
          .map((DecoratedBox d) => (d.decoration as BoxDecoration).color?.a ?? 0)
          .where((double a) => a > 0);
      expect(alphas, isNotEmpty, reason: '纱罩必须半透（纯色 = 磨砂失效）');
      for (final double a in alphas) {
        expect(a, lessThan(1.0), reason: '纱罩不透明就不是玻璃了');
      }
    });

    testWidgets('切档到第 3 格：选中块随之移动', (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();
      final double before = tester.getRect(_pillFinder()).center.dx;

      await tester.pumpWidget(_navHost(
        GlassQualityTier.high,
        selectedIndex: 2,
        onTabSelected: _noop,
      ));
      await tester.pumpAndSettle();
      final double after = tester.getRect(_pillFinder()).center.dx;

      expect(after, greaterThan(before));
    });
  });

  group('材质对照真机复验修正（2026-10-12）', () {
    testWidgets('选中块描边 = 0：硬描边会把边界变成一根白线',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 真机实测边界柔度：参考图 4~5px 渐变(48→42→34→30→26)，原 0.34 描边
      // 变成 2px 硬切(130→112→17)。羽化交给磨砂 + 圆角，不叠描边。
      expect(
        NavBarStyle.pillBorderAlpha,
        0.0,
        reason: '描边会与磨砂羽化叠加成白线；实测 0.34 时边界只有 2px 硬切',
      );
      final Iterable<double> pillBorderAlphas = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((DecoratedBox d) => d.decoration is BoxDecoration)
          // ⭐ 只取**选中块**那一个DecoratedBox。两者都是
          //    `BorderRadius.circular`，光看类型分不开；而圆角值又太接近
          //    （栏体 31 / 选中块 28.83）。改用**唯一可靠**的判据：
          //    选中块的圆角 = `pillRadius(栏高 × 0.93)`，逐值相等；
          //    栏体是 31，不等。
          .where((DecoratedBox d) {
            final BoxDecoration b = d.decoration as BoxDecoration;
            final BorderRadiusGeometry? r = b.borderRadius;
            if (r == null) return false;
            final BorderRadius resolved = r.resolve(TextDirection.ltr);
            return (resolved.topLeft.x - NavBarStyle.pillRadius(62 * 0.93)).abs() < 0.01;
          })
          .map((DecoratedBox d) => (d.decoration as BoxDecoration).border)
          .whereType<Border>()
          .expand((Border b) => [b.top.color.a, b.bottom.color.a]);
      // 先确认筛到了东西（否则上面 for 循环空转= 判绿假象）。
      expect(pillBorderAlphas, isNotEmpty, reason: '未定位到选中块的 DecoratedBox');
      for (final double a in pillBorderAlphas) {
        expect(
          a,
          0.0,
          reason: '选中块不得有描边',
        );
      }
    });

    testWidgets('选中块纱罩是**纯中性灰**（实测 R=G=B，无色偏）',
        (WidgetTester tester) async {
      // 参考图**原生截图**实测选中块 rgb(74,74,74)—— R=G=B，饱和度为 0。
      //此前据二次压缩帧定的「冷灰蓝0x9FB4C8」是压缩色偏产物，已作废。
      for (final Brightness b in Brightness.values) {
        final Color c = NavBarStyle.pillScrimColor(b);
        expect(
          c.r,
          c.g,
          reason: '暗色选中块纱罩必须中性（R=G=B），实测 rgb(74,74,74)',
        );
        expect(c.g, c.b, reason: '中性灰：G=B');
      }
    });

    testWidgets('选中块 / 栏体亮度比 ≈ 3.2×（实测 74:23）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 原生截图实测：栏体空处 lum 23、选中块 lum 74。
      // 0.22 是**反解**值：23 + 0.22 × (255 − 23) ≈ 73.6 ≈ 74。
      expect(
        NavBarStyle.pillScrimAlpha(Brightness.dark),
        0.22,
        reason: '纱罩 alpha 由目标亮度 74 反解（栏体 23 → 74），不是拍的',
      );
      final double barA = NavBarStyle.scrimAlpha(Brightness.dark);
      expect(NavBarStyle.pillScrimAlpha(Brightness.dark), greaterThan(barA * 2));
    });
  });

  group('关档退化（UI-06 ②）', () {
    testWidgets('off 档退化为 Material NavigationBar，无任何 BackdropFilter',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.off, onTabSelected: _noop));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      // 标签照常渲染（功能完整可用）。
      expect(find.text('目录'), findsOneWidget);
    });
  });

  group('交互', () {
    testWidgets('点标签回调对应下标', (WidgetTester tester) async {
      int picked = -1;
      await tester.pumpWidget(
        _navHost(GlassQualityTier.high, onTabSelected: (int i) => picked = i),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(picked, 1);
    });

    testWidgets('横向拖动跟手形变 + 松手弹回', (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 起点取栏体内、避开标签文字（从标签上起拖会先被 `InkWell` 抢走手势）。
      //
      // ⚠️ **必须分步移动**（2026-10-12 实测）：单次 `moveBy(60, 0)` 一步跨
      // 60px 时，`HorizontalDragGestureRecognizer` 在这一帧内无法决胜（要等下一帧
      // 确认不是 tap），拖动回调根本没进——实测 pill 纹丝不动（探针：`-1.3` 前后
      // 同值）。分 6 步 × 10px（贴近真实手指轨迹）即正常。
      final Rect shell = tester.getRect(_shellFinder());
      final Rect pillBefore = tester.getRect(_pillFinder());
      final TestGesture g = await tester.startGesture(
        Offset(shell.left + 8, shell.top + 8),
      );
      for (int i = 0; i < 6; i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      final Rect pillDuring = tester.getRect(_pillFinder());
      final double moved = pillDuring.center.dx - pillBefore.center.dx;

      // ⚠️ **钉「位移远大于拉伸的附带偏移」而非只钉「变大了」**（2026-10-12 变异
      // 判红抓到）：`Transform.scale` 绕**中心**缩放，pill 变宽后多出的宽度一半
      // 在左一半在右，会把中心「拉回」`(宽增量 / 2)`；`getRect` 的中心因此被拉伸
      // 污染，只断言 `during > before` 的话把 `Transform.translate` 整个摘掉也
      // 判绿（实测拉伸就贡献 25px，掩盖位移为 0）。
      //
      // 期望值按几何算：位移 60 − 拉伸回拉 (宽增量/2 ≈ 20) = **40**。
      // 判红条件取 `>= 30`：摘掉 translate 时只剩 20 < 30 ⇒ 红；
      // 保留 translate 时 40 ≥ 30 ⇒ 绿。阈值远离两侧真实值，不怕抖动。
      expect(
        moved,
        greaterThanOrEqualTo(30),
        reason: '选中块须跟手：位移须显著大于拉伸附带偏移（约 20），'
            '摘掉 Transform.translate 时只剩 20 会红',
      );
      // 跟手的另一半：横向拉宽（液态形变）。
      expect(
        pillDuring.width,
        greaterThan(pillBefore.width),
        reason: '拖动时选中块应横向拉伸',
      );

      await g.up();
      await tester.pumpAndSettle();
      expect(
        tester.getRect(_pillFinder()).center.dx,
        closeTo(pillBefore.center.dx, 1.5),
        reason: '松手后应弹回目标格',
      );
    });

    testWidgets('拖动后的抬手不误触发切换', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        _navHost(GlassQualityTier.high, onTabSelected: (int _) => calls++),
      );
      await tester.pumpAndSettle();

      final Rect shell = tester.getRect(_shellFinder());
      final TestGesture g = await tester.startGesture(
        Offset(shell.left + 8, shell.top + 8),
      );
      // 分步移动（见上方用例注释：单步大位移无法决胜手势竞技场）。
      for (int i = 0; i < 6; i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '拖动是跟手形变，不等于切换 tab');
    });
  });
}

void _noop(int _) {}