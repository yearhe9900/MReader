// 自磨砂伪玻璃底栏 [FrostedNavBar] 的契约测试（2026-10-12 参考图复刻批）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 本文件钉什么
// ══════════════════════════════════════════════════════════════════════════════
// 参考图**原生截图**实测值换算出的几何（实测记录见 `nav_bar_style.dart` 文件头）：
//   · 标签中心**严格等分**（实测间距 254 / 254.5 / 254.5）⇒ 按 `标签区宽 / n` 均分；
//     标签区**居中 + 左右侧留白 0.10 格宽**（实测侧留白 25.75/25.75）；
//   · 选中块宽 = 格宽的 **112%**（实测 x 850..1135 ⇒ 宽 286 / 格宽 255），
//     即**向两侧溢出**格子；选中块中心与标签中心对齐；
//   · 选中块高 = 栏体高的 **0.89**（实测 152/171），圆角 = 高 / 2（胶囊）；
//   · 栏体 62 高 / 左右外边距 28 / 浮起 27 / **圆角 31 = 高/2（胶囊）**。
//
// ⚠️ 测量口径的教训（三轮返工，**各有不同的坑**）：
//   ① 10-12 用**二次压缩的录屏帧**测得「选中块占格宽 69%」⇒ 压缩会抹平低对比度
//      色块边界，必须用原生截图。
//   ② 10-13 上午把屏幕**手势指示条**（x 297..578、y 1887..1899）当成选中块，
//      据此得出「通栏贴边 / 13px 细条 / 选中项是第 3 格」三个错误结论。
//      教训：**先定位栏体的上下缘，再在栏体内部找特征**。
//   ③ 10-13 下午**把栏体左右缘测错**（把 881 宽图上的 x26/x853 当成栏体边缘，
//      实际应是 x54/x826），据此得出「圆角 15（不是胶囊）」「侧内缩 0.25」两个
//      错误结论。识别方法是**交叉验证**：同一张图的栏体上下缘、标签中心、格宽
//      在本轮（1220×2656 源图）与上一轮（881×1920）**逐像素吻合**，只有左右缘
//      一项对不上 ⇒ 错的就是那一项。教训：**同一份素材的不同分辨率版本必须
//      交叉验证，单项异常先怀疑该项测量而非推翻整份结论**。
//
// 这些是「用库时拿不到」的部分（库的指示块宽度由内部计算、`spacing: 8` 还会
// 破坏等分），所以必须钉死——回潮即红。
//
// ⭐ **断言一律硬编码字面量，且必须钉「实际渲染出来的值」而非仅常量**：
// 2026-10-13 变异③ 实测——把未选中图标改回 `onSurfaceVariant` 而四个 alpha
// 常量全部不动时，只钉常量的用例**依然全绿**。故图标/圆角/渐变三类特征都额外
// 钉了 widget 树里的真实取值。
// 断言不引用 `NavBarStyle` 的常量作为**唯一**判据（引用即同义反复、永远红不了，
// 同 `overlay_style_test` / `glass_material_test` 的口径）。
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
    testWidgets('栏体尺寸：62 高 / 左右 28 / 浮起 27 / 圆角 31',
        (WidgetTester tester) async {
      expect(NavBarStyle.barHeight, 62);
      expect(NavBarStyle.horizontalPadding, 28);
      expect(NavBarStyle.verticalPadding, 27);
      // 标签等分 ⇒ 额外间距必须是 0（库的 spacing: 8 正是破坏等分的元凶）。
      expect(NavBarStyle.tabSpacing, 0);
    });

    testWidgets('⭐ 栏体圆角 = 31 = 高/2 ⇒ **是胶囊**',
        (WidgetTester tester) async {
      // 参考图 1220×2656 实测：左缘剪影逐行拟合，圆心 (161.5, 2495.5)、R=85.5px；
      // y2410/2444/2476/2514/2574 处预测 158/93/78/80/128 vs 实测 158/92/77/78/129
      // （偏差 ≤2px）⇒ 栏体左右缘是**圆弧**，形态是胶囊。
      expect(NavBarStyle.barRadius, 31);
      //这条是「是胶囊」的判据：圆角必须等于高的一半。上一版把它定成 15
      // （圆角矩形），栏体两侧收不成半圆，正是「还是没一比一复刻」的主因。
      expect(NavBarStyle.barRadius * 2, closeTo(NavBarStyle.barHeight, 0.01));
      // ⭐ 实际渲染的 ClipRRect 圆角也须是 31（常量改了但布局没跟上会红）。
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();
      final BorderRadius shellRadius = tester
          .widget<ClipRRect>(_shellFinder())
          .borderRadius
          .resolve(TextDirection.ltr);
      expect(shellRadius.topLeft.x, 31);
    });

    testWidgets('选中块：宽 = 格宽 ×112%、高 = 栏高 ×0.89、圆角 = 高/2',
        (WidgetTester tester) async {
      // 1.12 来自实测（宽 286 / 格宽 255），见文件头。
      expect(NavBarStyle.pillWidthFactor, 1.12);
      expect(NavBarStyle.pillHeightFactor, 0.89);
      expect(NavBarStyle.pillRadius(62 * 0.89), closeTo(27.59, 0.01));
    });

    testWidgets('栏体实际渲染尺寸 = 62 高（松约束下不被顶高）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 这条正是「宿主必须镜像 Stack + Positioned」的护栏：紧约束下这里会是
      // 582（实测踩过），松约束下才是 62。
      expect(tester.getSize(_shellFinder()).height, 62);
      // 左右各留 28。
      expect(tester.getSize(_shellFinder()).width, 800 - 28 * 2);
      // 距屏幕底边 27。
      expect(
        600 - tester.getBottomLeft(_shellFinder()).dy,
        27,
        reason: '底栏应浮起 27（verticalPadding）',
      );
    });

    testWidgets('标签区侧内缩 = 0.10 格宽（参考图实测侧留白/格宽 = 26.25/255）',
        (WidgetTester tester) async {
      // 参考图实测：栏体 x 75..1144（1070）、标签区 x 100.75..1118.25（1017.5）
      // ⇒ 侧留白 26.25，除以格宽 255 得 0.1029。
      expect(
        NavBarStyle.sideInsetCellFactor,
        0.10,
        reason: '侧内缩是参考图真实特征；缺了它 112% 宽的选中块会贴栏体边框',
      );
      // 解方程：标签区宽 W = 可用宽 / (1 + 2k/n)
      const int n = 4;
      const double available = 1070;
      final double w = available / (1 + 2 * 0.10 / n);
      expect(w, closeTo(1017.5, 3)); // 实测标签区宽 1017.5
      expect(w / n, closeTo(255, 1)); // 实测格宽 255
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

      // 选第 1 格：112% 宽的选中块向两侧溢出，若无侧内缩就会贴到栏体边框。
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
        reason: '首格选中块左缘须离栏体边框留距离（实测参考图 9px = 3.3dp）',
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

    testWidgets('选中块实测：宽 = 格宽 ×1.12、高 = 栏高 ×0.89、圆角 = 高/2',
        (WidgetTester tester) async {
      // 参考图（1220×2656@2.75）实测：选中块 x 850..1135 ⇒ 宽 286；
      // 标签中心间距 255 ⇒ `286 / 255 = 1.12`。
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
      // 标签区有侧内缩（0.10 格宽），格宽按标签区宽算，不是栏宽。
      final double shellWidth = tester.getSize(_shellFinder()).width;
      final double labelAreaWidth = shellWidth /
          (1 + 2 * NavBarStyle.sideInsetCellFactor / _kTabs.length);
      final double sideInset = (shellWidth - labelAreaWidth) / 2;
      final double cell = labelAreaWidth / _kTabs.length;
      final Rect pill = tester.getRect(_pillFinder());

      expect(pill.width, closeTo(cell * 1.12, 1.0));
      // ⭐ 钉住「选中块**向两侧溢出**格子」这个实测特征（宽 286 > 格宽 255）。
      // 曾经的 0.69（来自二次压缩的录屏帧）会让底衬明显偏窄，与参考图不符。
      expect(
        pill.width,
        greaterThan(cell),
        reason: '参考图实测选中块宽 286 > 格宽 255，即溢出格子',
      );
      expect(pill.height, closeTo(62 * 0.89, 1.0));
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

  group('材质对照真机复验修正（2026-10-12 / 10-13 三轮返工）', () {
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
          //    （栏体 31 / 选中块 27.59）。改用**唯一可靠**的判据：
          //    选中块的圆角 = `pillRadius(栏高 × 0.89)`，逐值相等；
          //    栏体是 31，不等。
          .where((DecoratedBox d) {
            final BoxDecoration b = d.decoration as BoxDecoration;
            final BorderRadiusGeometry? r = b.borderRadius;
            if (r == null) return false;
            final BorderRadius resolved = r.resolve(TextDirection.ltr);
            return (resolved.topLeft.x - NavBarStyle.pillRadius(62 * 0.89)).abs() < 0.01;
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
      // 参考图实测选中块 rgb(49,49,49)—— R=G=B，饱和度为 0。
      // 更早据二次压缩帧定的「冷灰蓝 0x9FB4C8」是压缩色偏产物，已作废。
      for (final Brightness b in Brightness.values) {
        final Color c = NavBarStyle.pillScrimColor(b);
        expect(
          c.r,
          c.g,
          reason: '选中块纱罩必须中性（R=G=B），实测 rgb(49,49,49)',
        );
        expect(c.g, c.b, reason: '中性灰：G=B');
      }
    });

    testWidgets('选中块 / 栏体亮度比 ≈ 2.3×（实测 49:21）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 参考图实测：栏体背后全黑、栏体空处 lum 21、选中块内 lum 49。
      // 0.12 是**反解**值：21 + 0.12 × (255 − 21) = 49.1 ≈ 49。
      const double barLum = 21;
      const double pillLum = 49;
      final double pillA = NavBarStyle.pillScrimAlpha(Brightness.dark);
      expect(
        pillA,
        closeTo(0.12, 0.005),
        reason: '纱罩 alpha 由目标亮度 49 反解（栏体 21 → 49），不是拍的',
      );
      expect(
        barLum + pillA * (255 - barLum),
        closeTo(pillLum, 1),
        reason: '反解式必须能还原实测亮度 49',
      );
      // 同一条反解式对栏体纱罩也成立（栏体 21 = 黑底 + 白纱）。
      final double barA = NavBarStyle.scrimAlpha(Brightness.dark);
      expect(barA * 255, closeTo(barLum, 2), reason: '栏体纱罩反解回 lum 21');
      expect(pillA, greaterThan(barA), reason: '选中块必须比栏体更亮一档');
    });

    testWidgets('⭐ 亮色档选中块**压黑**而非加白（否则在亮色下几乎不可见）',
        (WidgetTester tester) async {
      // 栏体亮色档已叠白纱 0.42，若选中块再加白纱会看不见。
      expect(
        NavBarStyle.pillScrimColor(Brightness.light).computeLuminance(),
        lessThan(NavBarStyle.scrimColor(Brightness.light).computeLuminance()),
        reason: '亮色下选中块必须比栏体暗（压黑），实测参考图为暗色场景',
      );
    });

    testWidgets('⭐ 栏体**没有**左右缘高光带（栏体内侧亮度平坦）',
        (WidgetTester tester) async {
      // 参考图实测：把栏体左缘 x60..160 逐点打出来，栏体从边缘内侧第 2px 起就
      // 稳定在 lum 20~21，一路平坦到标签；只有四周一道 1~2px 的亮描边
      // （左缘 x85 lum 49 / 右缘 x1135 lum 47 vs 本体 21）。
      //
      // ⚠️ 更早一版据**二次压缩帧**测到「左缘 42px 宽、lum 185 的亮带」并据此
      // 加了一层 15dp 渐变。压缩会抹平/偏移低对比度边界，这条特征是产物。
      await tester.pumpWidget(_navHost(GlassQualityTier.high, onTabSelected: _noop));
      await tester.pumpAndSettle();

      // 判据：栏体装饰里**不得**出现任何 LinearGradient（加回来即红）。
      final Iterable<LinearGradient> grads = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((DecoratedBox d) => d.decoration)
          .whereType<BoxDecoration>()
          .map((BoxDecoration b) => b.gradient)
          .whereType<LinearGradient>();
      expect(grads, isEmpty, reason: '栏体不应再有左右缘高光带渐变');

      // 描边仍在（那是真实特征：栏体亮度 21 → 上缘亮边 46 ⇒ alpha ≈ 0.11）。
      expect(NavBarStyle.barBorderAlpha, closeTo(0.12, 0.005));
      // ⚠️ 判据取「alpha > 0 的那些」：选中块的 `pillBorderAlpha` 是 0，
      // 直接全取会混进一条假的 0.0 断言失败（本轮踩过）；而按圆角值筛会与
      // `barRadius` 耦合成同义反复。只有栏体这一层有描边。
      final Iterable<double> barBorders = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((DecoratedBox d) => d.decoration is BoxDecoration)
          .map((DecoratedBox d) => (d.decoration as BoxDecoration).border)
          .whereType<Border>()
          .expand((Border b) => <double>[b.top.color.a, b.bottom.color.a])
          .where((double a) => a > 0);
      expect(barBorders, isNotEmpty, reason: '未定位到栏体的描边');
      for (final double a in barBorders) {
        expect(a, closeTo(0.12, 0.001), reason: '栏体四周亮描边实测反解 ≈ 0.11');
      }
    });

    testWidgets('⭐ 选中与未选中的图标/文字同色（实测亮度几乎一致）',
        (WidgetTester tester) async {
      // 参考图实测：四个标签的图标中位亮度 242~247、文字 215~223，选中与否
      // 几乎无差⇒ 选中态**只靠灰底衬区分**。未选中若走 `onSurfaceVariant`
      // 会明显发灰——这是「太丑」的另一半原因。
      expect(NavBarStyle.selectedIconAlpha, 0.95);
      expect(NavBarStyle.unselectedIconAlpha, 0.92);
      // 两档差必须极小（<0.05），保证观感上「几乎同色」。
      expect(
        NavBarStyle.selectedIconAlpha - NavBarStyle.unselectedIconAlpha,
        lessThan(0.05),
      );
      expect(
        NavBarStyle.selectedLabelAlpha - NavBarStyle.unselectedLabelAlpha,
        lessThan(0.05),
      );

      // ⭐ **必须钉实际渲染出来的颜色**，光钉常量是「钉了个寂寞」——2026-10-13
      // 变异③ 实测：把未选中图标改回 `onSurfaceVariant`（四个常量全部不动），
      // 上面这些常量断言**依然全绿**。真正的判据在这里。
      tester.view.physicalSize = const Size(592, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_navHost(
        GlassQualityTier.high,
        selectedIndex: 0,
        onTabSelected: _noop,
      ));
      await tester.pumpAndSettle();

      final ColorScheme colors =
          Theme.of(tester.element(find.byType(FrostedNavBar))).colorScheme;
      final List<Icon> icons =
          tester.widgetList<Icon>(find.byType(Icon)).toList();
      expect(icons.length, _kTabs.length, reason: '每个标签一个图标');
      // 第 0 格选中、第 1 格未选中：两者 RGB 通道须**完全相同**，只有 alpha 不同。
      // `onSurfaceVariant` 的 RGB 与 `onSurface` 不同 ⇒ 这条会红。
      expect(icons[0].color!.r, icons[1].color!.r,
          reason: '选中/未选中图标 RGB 必须相同（实测参考图亮度几乎一致）');
      expect(icons[0].color!.g, icons[1].color!.g);
      expect(icons[0].color!.b, icons[1].color!.b);
      expect(icons[0].color!.r, colors.onSurface.r);
      expect(icons[0].color!.g, colors.onSurface.g);
      expect(icons[0].color!.b, colors.onSurface.b);
      // 只有 alpha 有极小差异。
      expect(icons[0].color!.a, greaterThan(icons[1].color!.a));
      expect(icons[0].color!.a - icons[1].color!.a, lessThan(0.05));
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

    testWidgets('⭐ 拖动：1:1 跟手 + 横向拉伸（∝ 拖过格数）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _InteractiveHost(onSelect: _noop),
      );
      await tester.pumpAndSettle();

      final Rect shell = tester.getRect(_shellFinder());
      final Rect before = tester.getRect(_pillFinder());
      final double cell = _cellWidthOf(shell);

      // 起点取栏体内、避开标签文字（从标签上起拖会先被 `InkWell` 抢走手势）。
      //
      // ⚠️ **必须分步移动**（2026-10-12 实测）：单次 `moveBy` 一步跨大步时，
      // `HorizontalDragGestureRecognizer` 要在该帧内才决胜，而
      // `DragStartBehavior.start` 会丢掉决胜前的位移 ⇒ 拖动回调根本没进
      // （实测 pill 纹丝不动）。分步（贴近真实手指轨迹）即正常。
      final double drag = cell * 1.2;
      // ⚠️ 步数取整后**用 `步数 × 10` 反推拖动距离**：`232.5 × 1.2` 与 28 次
      // `moveBy(10)` 的浮点累积相差 ~1e-13，直接用 `cell * 1.2` 当上界会在
      // `279.9999999999999 > 279.0` 上假红。
      final int steps = (drag / 10).round();
      final double dragged = steps * 10.0;
      final TestGesture g = await tester.startGesture(
        Offset(shell.left + 8, shell.top + 8),
      );
      for (int i = 0; i < steps; i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      final Rect during = tester.getRect(_pillFinder());
      final double moved = during.center.dx - before.center.dx;

      // ① 跟手：位移须与拖动距离同量级。
      // ⚠️ **不能只钉「变大了」**（2026-10-12 变异判红抓到）：拉伸走
      // `Transform.scale`、且绕**中心**缩放，中心不受影响 ⇒ 把跟手位移那一项摘掉
      // 后位移为 0 却仍「变大了」。故这里是**位移**断言，且给出上下界：
      //   · 低于 1 格 ⇒ 说明位移机制失效；
      //   · 高于拖动距离 ⇒ 说明没有边界夹取。
      // 实测这 28 步**全部**计入了跟手位移（触摸 slop 未吃掉），故容差可收紧到 1px：
      // 任何「位移被吃掉一半」的实现都会红。
      expect(moved, closeTo(dragged, 1),
          reason: '应 1:1 跟手（摘掉跟手位移项时为 0）');
      expect(moved, lessThanOrEqualTo(dragged + 0.5),
          reason: '跟手位移不得超过拖动距离（边界夹取只减不增）');

      // ② 拉伸：宽度 = 静止宽 × (1 + 0.18 × 拖过格数)。
      // 参考视频实测：静止 145px ⇒ 拖动峰值 185px（比例 1.28，见 `dragStretchMax`）。
      // 期望值由**实测位移**推出，避免与「决胜吃掉的那 20px 触摸 slop」耦合。
      final double expectW = before.width * (1 + 0.18 * moved / cell);
      expect(during.width, closeTo(expectW, 2),
          reason: '拖过 n 格应拉宽 0.18n（摘掉 Transform.scale 时为静止宽）');

      // ③ 边界：拉伸后的左右缘都还在栏体内。
      expect(during.left, greaterThanOrEqualTo(shell.left - 0.5));
      expect(during.right, lessThanOrEqualTo(shell.right + 0.5));

      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('⭐ 松手吸附到最近的格子并切换 tab', (WidgetTester tester) async {
      final List<int> picked = <int>[];
      await tester.pumpWidget(_InteractiveHost(onSelect: picked.add));
      await tester.pumpAndSettle();

      final Rect shell = tester.getRect(_shellFinder());
      final Rect before = tester.getRect(_pillFinder());
      final double cell = _cellWidthOf(shell);

      // 拖 1.2 格 ⇒ 四舍五入为 1 格（阈值是半格 0.5，余量充足）。
      final TestGesture g = await tester.startGesture(
        Offset(shell.left + 8, shell.top + 8),
      );
      for (int i = 0; i < (cell * 1.2 / 10).round(); i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      expect(picked, isEmpty, reason: '拖动过程中不应切换');

      await g.up();
      await tester.pumpAndSettle();

      expect(picked, <int>[1], reason: '松手应吸附到最近格并切换一次');
      // 选中块中心间距就是格宽 ⇒ 第 1 格中心 = 第 0 格中心 + 1 格。
      expect(tester.getRect(_pillFinder()).center.dx,
          closeTo(before.center.dx + cell, 1.5),
          reason: '选中块应停在吸附格中心');
    });

    testWidgets('⭐ 左右边界：拖到端头时拉伸后的选中块不越出栏体',
        (WidgetTester tester) async {
      for (final double sign in <double>[1, -1]) {
        final List<int> picked = <int>[];
        // ⚠️ 换 `key` 强制重建宿主 State，否则第二轮会带着上一轮的下标起算。
        await tester.pumpWidget(
          _InteractiveHost(key: ValueKey<double>(sign), onSelect: picked.add),
        );
        await tester.pumpAndSettle();

        final Rect shell = tester.getRect(_shellFinder());
        final Rect before = tester.getRect(_pillFinder());
        final double cell = _cellWidthOf(shell);

        // 拖 8 格（远超 3 格栏宽）⇒ 无约束时选中块会整个飞出栏体。
        final int steps = (cell * 8 / 10).round();
        final TestGesture g = await tester.startGesture(
          Offset(shell.left + 8, shell.top + 8),
        );
        for (int i = 0; i < steps; i++) {
          await g.moveBy(Offset(10 * sign, 0));
          await tester.pump();
        }
        final Rect during = tester.getRect(_pillFinder());
        expect(during.left, greaterThanOrEqualTo(shell.left - 0.5),
            reason: '⭐ 拉伸后的左缘不得越出栏体');
        expect(during.right, lessThanOrEqualTo(shell.right + 0.5),
            reason: '⭐ 拉伸后的右缘不得越出栏体');
        // 反向断言：不能「夹过头」——拖满 8 格时须真的顶到端头
        // （否则一个恒居中的错误实现也能过上面两条）。
        if (sign > 0) {
          expect(during.right, closeTo(shell.right, 1),
              reason: '向右拖满应顶在栏体右内缘（参考视频实测 575 / 578）');
        } else {
          expect(during.left, closeTo(shell.left, 1),
              reason: '向左拖满应顶在栏体左内缘');
        }
        // 顶住时拉伸已封顶：宽 = 静止宽 × 1.30。
        expect(during.width, closeTo(before.width * 1.30, 2),
            reason: '拉伸应封顶在 0.30');

        await g.up();
        await tester.pumpAndSettle();
        // 向右拖满 ⇒ 末格；从首格向左拖 ⇒ 原地不动（夹到合法下标）。
        expect(picked, sign > 0 ? <int>[_kTabs.length - 1] : <int>[],
            reason: '吸附目标须夹在合法下标内');
      }
    });

    testWidgets('拖动不足半格时松手只回弹、不切换', (WidgetTester tester) async {
      final List<int> picked = <int>[];
      await tester.pumpWidget(_InteractiveHost(onSelect: picked.add));
      await tester.pumpAndSettle();

      final Rect shell = tester.getRect(_shellFinder());
      final Rect before = tester.getRect(_pillFinder());
      final double cell = _cellWidthOf(shell);

      // 拖 0.3 格 ⇒ 四舍五入为 0 格。
      final TestGesture g = await tester.startGesture(
        Offset(shell.left + 8, shell.top + 8),
      );
      for (int i = 0; i < (cell * 0.3 / 10).round(); i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();

      expect(picked, isEmpty,
          reason: '不足半格应回弹到原格；顺带钉住「拖动末端的抬手不误触发切换」');
      expect(tester.getRect(_pillFinder()).center.dx,
          closeTo(before.center.dx, 1.5),
          reason: '应回到原格中心');
    });

    testWidgets('⭐ 点首 / 末格时选中块**全程**不越出栏体（含过冲回弹）',
        (WidgetTester tester) async {
      // 2026-10-13 真机回归「点击时最左 / 最右边界溢出」。
      //
      // 切档走 `_slide` + `easeOutBack`：那条曲线会冲过终点一次
      // （峰值 ≈ 终点的 1.096 倍）。边界夹取若只算「静止位 + 手指偏移」，**动画
      // 途中那一冲完全没被夹到**——切到末格时选中块右缘会越出栏体
      // （3 格测试面实测越出 4.4px；5 格手机上按同比例 ≈ 20dp）。
      //
      // 故本用例必须**逐帧**取样整段动画，不能只看首末两帧。
      // 变异判红实证：把夹取对象退回「静止位 + 手指偏移」⇒ 红在
      // 「收藏 第 11 帧：右缘越出栏体」（776.89 > 772.5）。
      final List<int> picked = <int>[];
      await tester.pumpWidget(_InteractiveHost(onSelect: picked.add));
      await tester.pumpAndSettle();

      final Rect shell = tester.getRect(_shellFinder());
      final Rect before = tester.getRect(_pillFinder());
      final double cell = _cellWidthOf(shell);

      Future<void> tapAndWatch(String label, int targetIndex) async {
        await tester.tap(find.text(label));
        // 420ms 的切档动画按 ~16ms 逐帧走满。
        final List<double> centers = <double>[];
        for (int i = 0; i < 32; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final Rect p = tester.getRect(_pillFinder());
          expect(p.left, greaterThanOrEqualTo(shell.left - 0.5),
              reason: '$label 第 $i 帧：左缘越出栏体');
          expect(p.right, lessThanOrEqualTo(shell.right + 0.5),
              reason: '$label 第 $i 帧：右缘越出栏体');
          centers.add(p.center.dx);
        }
        // ⚠️ **必须同时钉「真的在动」**（2026-10-13 变异判红抓到）：
        // 只查「不越界」的话，把位置换成「目标下标的静止位」会让选中块**瞬间跳到
        // 终点、压根没有动画**——而它显然不越界，用例照样判绿。
        final double target = before.center.dx + targetIndex * cell;
        expect(centers.first, isNot(closeTo(target, 1)),
            reason: '$label 第一帧就停在终点 ⇒ 切档动画根本没跑');
        expect(centers.last, closeTo(target, 1.5),
            reason: '$label 动画结束应停在目标格中心');
        expect(
          centers.any((double c) => (c - target).abs() > cell * 0.2),
          isTrue,
          reason: '$label 全程都在终点附近 ⇒ 没有中间的滑动过程',
        );
        await tester.pumpAndSettle();
      }

      await tapAndWatch('收藏', 2); // 首格 → 末格
      await tapAndWatch('目录', 0); // 末格 → 首格
      expect(picked, <int>[2, 0]);
    });

    testWidgets('点一下就走（回归：拖动识别器输给 tap 时不得吞掉点击）',
        (WidgetTester tester) async {
      // ⚠️ 2026-10-13 真机回归「无法点击」的**根因用例**：
      // `HorizontalDragGestureRecognizer` 在指针抬起且未越过 slop 时走
      // `resolve(rejected)` → `onCancel`（**不是**「拖动松手」），而同级 `InkWell`
      // 的 `onTap` 在同一次事件派发里紧接着执行。若 `onHorizontalDragCancel` 里置
      // 了点击拦截位，`onTap` 会被吞掉 ⇒ 整个底栏点不动。
      //
      // 本用例**必须连续点两次**：`onCancel` 在**每一次**点击时都会来，故退回旧
      // 写法时是「每一次点击都被吞」（真机现象就是这个「完全点不动」），连续两次
      // 才能把「偶发 / 仅首帧」这类误判排除掉。变异判红实证：退回旧写法后
      // 红在「首次点击就必须生效」（Actual: []）。
      final List<int> picked = <int>[];
      await tester.pumpWidget(_InteractiveHost(onSelect: picked.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(picked, <int>[2], reason: '首次点击就必须生效');

      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      expect(picked, <int>[2, 0], reason: '后续点击同样必须生效');
    });
  });
}

void _noop(int _) {}

/// 由栏体可用宽解出格宽。
///
/// 口径同 `FrostedNavBar` 的 `LayoutBuilder`：标签区宽 `W = 可用宽 / (1 + 2k/n)`，
/// 格宽 `= W / n`。`k` 硬编码 0.10 字面量（不引用 `NavBarStyle` 常量当唯一判据）。
///
/// 3 格 + 测试面 800 宽 ⇒ 可用宽 744 ⇒ 格宽 **232.5**、静止选中块宽 **260.4**。
double _cellWidthOf(Rect shell) {
  const int n = 3;
  const double k = 0.10;
  return (shell.width / (1 + 2 * k / n)) / n;
}

/// 会**真的换选中下标**的宿主（镜像 `home_shell` 的受控用法）。
///
/// ⚠️ 吸附类用例必须用它：`_navHost` 的 `selectedIndex` 是定值，松手后
/// [FrostedNavBar] 仍会按旧下标把选中块动画拉回去，「停在吸附格」必红。
///
/// ⚠️ 同一用例里反复 `pumpWidget` 时**必须换 `key`**——同位置同类型的 widget 会
/// 复用同一个 `State`，`_index` 不会重置（实测：边界用例的第二轮直接从上一轮的
/// 下标 2 起算，把「原地不动」判成「切到 0」）。
class _InteractiveHost extends StatefulWidget {
  const _InteractiveHost({super.key, required this.onSelect});

  final void Function(int) onSelect;

  @override
  State<_InteractiveHost> createState() => _InteractiveHostState();
}

class _InteractiveHostState extends State<_InteractiveHost> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: GlassScopeProvider(
        config: glassTierConfigFor(GlassQualityTier.high),
        child: Stack(
          children: <Widget>[
            const Positioned.fill(child: ColoredBox(color: Color(0xFF303030))),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FrostedNavBar(
                tabs: _kTabs,
                selectedIndex: _index,
                onTabSelected: (int i) {
                  widget.onSelect(i);
                  setState(() => _index = i);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}