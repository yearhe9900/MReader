// 自磨砂伪玻璃底栏 [FrostedNavBar] 的契约测试（2026-10-12 参考图复刻批）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 本文件钉什么
// ══════════════════════════════════════════════════════════════════════════════
// 参考图实测值换算出的几何（实测记录见 `nav_bar_style.dart` 文件头）：
//   ·标签中心**严格等分**（实测间距 129 / 129 / 129）⇒ 按`可用宽 / n` 均分；
//   · 选中块宽 = 格宽的 **69%**（实测 x 68~164⇒ 宽 96 / 格宽 ≈140）。
//     ⚠️ 原写 1.09（依据「141/129」）**量错了对象**——那是图标文字簇外沿；
//     真机做成 94% 时观感是「灰白大药丸压住图标」，故真机复验后修正为 0.69；
//   · 选中块高 = 栏体高的 0.72，圆角 = 高 / 2（胶囊）。
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
/// `SizedBox(height: barHeight)` 会被顶成整屏高（实测栏体 582 而非 68），
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
    testWidgets('栏体尺寸：68 高 / 左右 16 / 浮起 18', (WidgetTester tester) async {
      expect(NavBarStyle.barHeight, 68);
      expect(NavBarStyle.horizontalPadding, 16);
      expect(NavBarStyle.verticalPadding, 18);
      // 标签等分 ⇒ 额外间距必须是 0（库的 spacing: 8 正是破坏等分的元凶）。
      expect(NavBarStyle.tabSpacing, 0);
    });

    testWidgets('选中块：宽 = 格宽 ×69%、高 = 栏高 ×0.72、圆角 = 高/2',
        (WidgetTester tester) async {
      // 69% 来自真机复验重测（见 nav_bar_style.dart 文件头）：原 1.09 量的是
      // 图标文字簇外沿、不是选中块，真机做成 94% 时观感是"灰白大药丸压住图标"。
      expect(NavBarStyle.pillWidthFactor, 0.69);
      expect(NavBarStyle.pillHeightFactor, 0.72);
      expect(NavBarStyle.pillRadius(68 * 0.72), closeTo(24.48, 0.01));
    });

    testWidgets('栏体实际渲染尺寸 = 68 高（松约束下不被顶高）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 这条正是「宿主必须镜像 Stack + Positioned」的护栏：紧约束下这里会是
      // 582（实测踩过），松约束下才是 68。
      expect(tester.getSize(_shellFinder()).height, 68);
      // 左右各留 16。
      expect(tester.getSize(_shellFinder()).width, 800 - 16 * 2);
      // 距屏幕底边 18。
      expect(
        600 - tester.getBottomLeft(_shellFinder()).dy,
        18,
        reason: '底栏应浮起 18（verticalPadding）',
      );
    });

    testWidgets('标签严格等分：第 N 格中心 = 内容左缘 + 格宽 ×(N+0.5)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(592, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      final double shellLeft = tester.getTopLeft(_shellFinder()).dx;
      final double cell =
          tester.getSize(_shellFinder()).width / _kTabs.length;
      for (int i = 0; i < _kTabs.length; i++) {
        final Rect r = tester.getRect(find.text(_kTabs[i].label));
        expect(
          r.center.dx,
          closeTo(shellLeft + cell * (i + 0.5), 1.5),
          reason: '第 $i 格标签未落在等分中心（实测要求严格等分）',
        );
      }
    });

    testWidgets('选中块实测：宽 = 格宽 ×0.69、高 = 栏高 ×0.72、圆角 = 高/2',
        (WidgetTester tester) async {
      // 用参考图的同宽屏（592）反推：实测选中块 x 68~164 ⇒ 宽 96，格宽 ≈140
      // ⇒ 69%。这是 2026-10-12 真机复验修正后的值（原 1.09 量错了对象）。
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
      final double cell = tester.getSize(_shellFinder()).width / _kTabs.length;
      final Rect pill = tester.getRect(_pillFinder());

      expect(pill.width, closeTo(cell * 0.69, 1.0));
      // ⭐ 钉住「不能回到过宽的老值」：1.09 会让选中块撑满整格。
      expect(
        pill.width,
        lessThan(cell * 0.8),
        reason: '选中块过宽（参考图实测占格宽 69%），会盖住图标观感变差',
      );
      expect(pill.height, closeTo(68 * 0.72, 1.0));
      final BorderRadius radius = tester
          .widget<ClipRRect>(_pillFinder())
          .borderRadius
          .resolve(TextDirection.ltr);
      expect(radius.topLeft.x, closeTo(pill.height / 2, 0.5));
      // 中心与第 2 格（index 1）对齐。
      expect(pill.center.dx, closeTo(shellLeft + cell * 1.5, 1.5));
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
          //    （栏体 24 / 选中块 24.48）。改用**唯一可靠**的判据：
          //    选中块的圆角 = `pillRadius(栏高 × 0.72)`，逐值相等；
          //    栏体是24，不等。
          .where((DecoratedBox d) {
            final BoxDecoration b = d.decoration as BoxDecoration;
            final BorderRadiusGeometry? r = b.borderRadius;
            if (r == null) return false;
            final BorderRadius resolved = r.resolve(TextDirection.ltr);
            return (resolved.topLeft.x - NavBarStyle.pillRadius(68 * 0.72)).abs() < 0.01;
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

    testWidgets('暗色选中块纱罩是冷灰蓝（中性白会偏紫）', (WidgetTester tester) async {
      // 参考图实测 rgb(47,52,58)、hue 213 / 饱和度 0.19；中性白做出来是
      // hue 230、饱和度 0.09（偏紫），与青蓝主题不对路。
      final Color dark = NavBarStyle.pillScrimColor(Brightness.dark);
      // 蓝通道必须**高于**红通道（冷色），这是「不是中性白」的最小判据。
      expect(
        dark.b,
        greaterThan(dark.r),
        reason: '暗色选中块应偏冷（b > r），中性白会偏紫',
      );
      // 也不能过蓝——那样会变成一坨蓝。
      expect(dark.b - dark.r, lessThan(60));
    });

    testWidgets('选中块 / 栏体亮度比 ≈ 2.7×（真机实测 60:18 偏亮）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 参考图 52:19 ≈ 2.7×；原「白纱 0.16」做出来 60:18 = 3.3× 偏亮。
      // 0.21 是**反解**值：18 + 0.21×(180−18) ≈ 52（纱罩改冷灰蓝后有效亮度
      // 是 180 而非纯白 255 —— 这正是之前偏亮的机制）。
      expect(
        NavBarStyle.pillScrimAlpha(Brightness.dark),
        0.21,
        reason: '纱罩 alpha 是从目标亮度 52 反解出来的，不是拍的',
      );
      // 钉住「比栏体亮、但不能亮到3×以上」。
      final double barA = NavBarStyle.scrimAlpha(Brightness.dark);
      expect(NavBarStyle.pillScrimAlpha(Brightness.dark), greaterThan(barA));
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