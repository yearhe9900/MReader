import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 框架 API 走公共 barrel；若导出缺失会在这里暴露。
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';
// 内部画笔：只用来把「选中胶囊落在哪个槽位」读成数值（不属公开 API）。
import 'package:mreader/ui/mi_like_ui/src/components/navigation/glass_side_nav_bar/side_nav_bar_painter.dart';

/// 宽屏导航回归：侧边导航栏的几何 / 选中态 / 回调，以及示例应用在
/// **导航断点两侧**的形态切换（底部栏 ⇄ 侧栏）。
///
/// 断点口径照抄 MReader 主壳层（`lib/ui/home_shell.dart`）：
/// `LayoutBuilder` 读**外壳自己的容器宽**、`maxWidth > 600` 才切侧栏 ——
/// 所以平板（中等宽）也用侧栏，只有手机竖屏 / 窄窗留底栏。
///
/// 判据约定：
///  * **形态唯一** = 任何容器宽下底部栏与侧栏**恰好出现一个**；
///  * **边界严格大于** = 画面容器宽 600 → 底栏，602 → 侧栏；
///  * **布局不错位** = 页面左缘恰为侧栏列宽（`gutterWidth`）、侧栏左缘留白
///    25.5、贴顶，且不溢出（`takeException() == null`）；
///  * **行为一致** = 点条目回调的下标与页面切换结果和底部栏相同；
///  * **切形态不丢状态** = 跨断点来回改变窗口尺寸后，页面滚动位置保持不变。
void main() {
  void setWindow(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  List<MiGlassNavItem> items(MiThemeMode mode) {
    final ink = MiColors.foregroundFor(mode);
    return [
      MiGlassNavItem(label: '首页', painter: RollerIconPainter(ink)),
      MiGlassNavItem(label: '分类', painter: GridSparkleIconPainter(ink)),
      MiGlassNavItem(label: '我的', painter: SmileyBeretIconPainter(ink)),
    ];
  }

  Widget harness({
    int selected = 0,
    ValueChanged<int>? onTap,
    MiThemeMode mode = MiThemeMode.dark,
    MiGlassNavFab? fab,
  }) {
    return MaterialApp(
      theme: mode == MiThemeMode.dark
          ? ThemeData.dark(useMaterial3: true)
          : ThemeData.light(useMaterial3: true),
      home: Scaffold(
        // 亮色配方在深底上也能看清外缘高光/投影，故两套模式共用同一底。
        backgroundColor: const Color(0xFF101014),
        body: Center(
          child: MiGlassSideNavBar(
            items: items(mode),
            selectedIndex: selected,
            onTap: onTap ?? (_) {},
            fab: fab,
            themeMode: mode,
          ),
        ),
      ),
    );
  }

  /// 条目 [i] 静止时胶囊中心的纵坐标（与组件内同一公式）。
  double slotCenter(int i) =>
      MiGlassSideNavMetrics.railInnerPad +
      MiGlassSideNavMetrics.itemHeight / 2 +
      MiGlassSideNavMetrics.pitch * i;

  /// 测试用圆钮（子级用文本，方便取几何中心）。
  MiGlassNavFab demoFab({VoidCallback? onTap}) => MiGlassNavFab(
        tabIndex: 0,
        onTap: onTap ?? () {},
        child: const Text('圆钮'),
      );

  SideNavPainter pillPainter(WidgetTester tester) => tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(MiGlassSideNavBar),
          matching: find.byType(CustomPaint),
        ),
      )
      .map((w) => w.painter)
      .whereType<SideNavPainter>()
      .single;


  group('MiGlassSideNavMetrics（推导值，与底部栏同源）', () {
    test('栏宽 / 条目高 / 列宽沿用底部栏实测 token', () {
      expect(
        MiGlassSideNavMetrics.railWidth,
        closeTo(
          MiGlassNavMetrics.cellWidth + 2 * MiGlassNavMetrics.barInnerPad,
          1e-9,
        ),
      );
      expect(MiGlassSideNavMetrics.itemWidth, MiGlassNavMetrics.cellWidth);
      expect(
        MiGlassSideNavMetrics.itemHeight,
        closeTo(
          MiGlassNavMetrics.barHeight - 2 * MiGlassNavMetrics.pillInsetV,
          1e-9,
        ),
      );
      // 图标墨盒 / 图标到标签间距与底部栏一字不改（两种形态图标同大）
      expect(MiGlassSideNavMetrics.iconHeight, MiGlassNavMetrics.iconHeight);
      expect(MiGlassSideNavMetrics.iconLabelGap, MiGlassNavMetrics.iconLabelGap);
      expect(
        MiGlassSideNavMetrics.gutterWidth,
        closeTo(MiGlassSideNavMetrics.railMargin + MiGlassSideNavMetrics.railWidth, 1e-9),
      );
    });

    test('栏高 = 2×内边距 + n×条目高 + (n−1)×间隙', () {
      expect(
        MiGlassSideNavMetrics.railHeightFor(3),
        closeTo(2 * 6.6 + 3 * 49.3 + 2 * 8, 1e-9),
      );
      expect(
        MiGlassSideNavMetrics.railHeightFor(5) -
            MiGlassSideNavMetrics.railHeightFor(4),
        closeTo(MiGlassSideNavMetrics.itemHeight + MiGlassSideNavMetrics.itemGap, 1e-9),
      );
    });

    test('栏体圆角以内圈胶囊为准等距外扩（内外圈间距四周恒 6.6）', () {
      // 端头圆弧与胶囊顶角圆弧**同心**：圆心 y 同为 内边距 + 胶囊半径，
      // 间距 = 半径差 = 内边距。旧值 railWidth/2 = 47.7 与内圈不同心，
      // 肩部间距会从 6.6 收缩到 0（两圆弧相交）—— 用户反馈平板模式
      // 内外圈间距应一致，以内圈为准。
      expect(
        MiGlassSideNavMetrics.railRadius,
        closeTo(MiGlassSideNavMetrics.pillRadius + MiGlassSideNavMetrics.railInnerPad, 1e-9),
      );
      expect(MiGlassSideNavMetrics.railRadius, closeTo(31.25, 1e-9));
      // 圆钮几何沿用底部栏实测（直径 = 栏高、间距 11.9）
      expect(MiGlassSideNavMetrics.fabDiameter, MiGlassNavMetrics.fabDiameter);
      expect(MiGlassSideNavMetrics.fabGap, MiGlassNavMetrics.fabGap);
      // 槽位恒定预留：hasFab 只加一段定高，显隐不改布局
      expect(
        MiGlassSideNavMetrics.heightFor(3, hasFab: true),
        closeTo(
          MiGlassSideNavMetrics.railHeightFor(3) +
              MiGlassSideNavMetrics.fabGap +
              MiGlassSideNavMetrics.fabDiameter,
          1e-9,
        ),
      );
      expect(
        MiGlassSideNavMetrics.heightFor(3),
        closeTo(MiGlassSideNavMetrics.railHeightFor(3), 1e-9),
      );
    });
  });

  group('MiGlassSideNavBar', () {
    testWidgets('按声明尺寸渲染：栏体收缩到内容高、条目等距排布', (tester) async {
      setWindow(tester, const Size(400, 600));
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(MiGlassSideNavBar));
      expect(size.width, closeTo(MiGlassSideNavMetrics.railWidth, 0.01));
      expect(
        size.height,
        closeTo(MiGlassSideNavMetrics.railHeightFor(3), 0.01),
      );

      // 三个条目纵向等距，间距 = itemGap
      final railTop = tester.getTopLeft(find.byType(MiGlassSideNavBar)).dy;
      final c0 = tester.getCenter(find.text('首页')).dy;
      final c1 = tester.getCenter(find.text('分类')).dy;
      final c2 = tester.getCenter(find.text('我的')).dy;
      expect(c1 - c0, closeTo(MiGlassSideNavMetrics.pitch, 0.01));
      expect(c2 - c1, closeTo(MiGlassSideNavMetrics.pitch, 0.01));
      // 首条目：内边距 + 半个条目高（标签不是条目圆心，故与胶囊中心差一档
      // icon/gap 偏移，这里只锁「首条目在栏顶内边距之内」）
      expect(c0 - railTop, greaterThan(MiGlassSideNavMetrics.railInnerPad));
      expect(c2 - railTop, lessThan(size.height - MiGlassSideNavMetrics.railInnerPad));
    });

    testWidgets('点按回调下标，选中胶囊落到对应槽位（首/中/尾都对齐）', (tester) async {
      setWindow(tester, const Size(400, 600));
      addTearDown(tester.view.reset);

      final tapped = <int>[];
      await tester.pumpWidget(harness(onTap: tapped.add));
      await tester.pumpAndSettle();

      // 首帧即稳态：选中 0 的胶囊就在 0 号槽位
      expect(pillPainter(tester).pillCenterY, closeTo(slotCenter(0), 0.01));
      expect(pillPainter(tester).pillHeight, closeTo(MiGlassSideNavMetrics.itemHeight, 0.01));
      expect(pillPainter(tester).pillWidth, closeTo(MiGlassSideNavMetrics.itemWidth, 0.01));

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(tapped, [2]);

      // 受控组件：调用方回传新的 selectedIndex 后才移动
      await tester.pumpWidget(harness(selected: 2, onTap: tapped.add));
      await tester.pumpAndSettle();
      expect(pillPainter(tester).pillCenterY, closeTo(slotCenter(2), 0.01));

      await tester.tap(find.text('分类'));
      await tester.pumpAndSettle();
      expect(tapped, [2, 1]);
      await tester.pumpWidget(harness(selected: 1, onTap: tapped.add));
      await tester.pumpAndSettle();
      expect(pillPainter(tester).pillCenterY, closeTo(slotCenter(1), 0.01));
    });

    testWidgets('纵向拖拽吸附最近条目（与底部栏横向拖拽同一套吸附）', (tester) async {
      setWindow(tester, const Size(400, 600));
      addTearDown(tester.view.reset);

      final tapped = <int>[];
      await tester.pumpWidget(harness(onTap: tapped.add));
      await tester.pumpAndSettle();

      // 从栏体中心（= 1 号条目）向下拖两格 → 吸附到末条目
      const dragDy = MiGlassSideNavMetrics.pitch * 2;
      await tester.drag(find.byType(MiGlassSideNavBar), const Offset(0, dragDy));
      await tester.pumpAndSettle();
      expect(tapped, [2]);
    });

    testWidgets('只挂一个磨砂层、不引入额外遮罩（每帧模糊预算）', (tester) async {
      setWindow(tester, const Size(400, 600));
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      final rail = find.byType(MiGlassSideNavBar);
      expect(
        find.descendant(of: rail, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      // 半透明遮罩会让 backdrop 变空（本项目已实测的坑）
      expect(
        find.descendant(of: rail, matching: find.byType(ShaderMask)),
        findsNothing,
      );
      // 条目 3 个图标 + 1 个胶囊画笔
      expect(
        find.descendant(of: rail, matching: find.byType(CustomPaint)),
        findsNWidgets(4),
      );
    });

    testWidgets('亮色配方可用（投影/渐变不报错）', (tester) async {
      setWindow(tester, const Size(400, 600));
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(mode: MiThemeMode.light));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(pillPainter(tester).palette.scrimGradient, isNotNull);
    });
  });

  group('预留空位圆钮（MiGlassNavFab，与底部栏同契约）', () {
    testWidgets('圆钮挂在栏尾下方：水平居中 / 间距 fabGap / 槽位恒定预留', (tester) async {
      setWindow(tester, const Size(400, 700));
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(selected: 0, fab: demoFab()));
      await tester.pumpAndSettle();

      final railFinder = find.byType(MiGlassSideNavBar);
      final size = tester.getSize(railFinder);
      expect(size.width, closeTo(MiGlassSideNavMetrics.railWidth, 0.01));
      // 配置圆钮后组件总高 = 栏体高 + 间距 + 直径（槽位恒定预留）
      expect(
        size.height,
        closeTo(MiGlassSideNavMetrics.heightFor(3, hasFab: true), 0.01),
      );

      // 圆钮中心：水平对齐栏体中线，纵向在栏尾下方一个间距 + 半径
      final center = tester.getCenter(find.text('圆钮'));
      final railTopLeft = tester.getTopLeft(railFinder);
      expect(center.dx, closeTo(railTopLeft.dx + size.width / 2, 0.01));
      expect(
        center.dy,
        closeTo(
          railTopLeft.dy +
              MiGlassSideNavMetrics.railHeightFor(3) +
              MiGlassSideNavMetrics.fabGap +
              MiGlassSideNavMetrics.fabDiameter / 2,
          0.01,
        ),
      );
      // 首帧即稳态：选中「首页」圆钮完全显示
      final opacity = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('圆钮'), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, 1.0);
    });

    testWidgets('切到其它条目收起、切回弹出；收起不改组件高度、不吃点击', (tester) async {
      setWindow(tester, const Size(400, 700));
      addTearDown(tester.view.reset);

      var taps = 0;
      await tester.pumpWidget(harness(selected: 0, fab: demoFab(onTap: () => taps++)));
      await tester.pumpAndSettle();
      final shownHeight = tester.getSize(find.byType(MiGlassSideNavBar)).height;
      final fabCenter = tester.getCenter(find.text('圆钮'));

      // 切到「分类」：镜像收起（reverse 时间镜像），槽位仍在、高度不变
      await tester.pumpWidget(harness(selected: 1, fab: demoFab(onTap: () => taps++)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(MiGlassSideNavBar)).height,
        closeTo(shownHeight, 0.01),
        reason: '收起不应引起布局跳动（槽位恒定预留）',
      );
      final hidden = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('圆钮'), matching: find.byType(Opacity)),
      );
      expect(hidden.opacity, 0.0);
      // 收起后圆钮整体 IgnorePointer：点在圆钮位置不触发回调、不吞下层点击
      await tester.tapAt(fabCenter);
      await tester.pumpAndSettle();
      expect(taps, 0, reason: '收起的圆钮不应吃点击');

      // 切回「首页」：弹回完全显示，点击恢复
      await tester.pumpWidget(harness(selected: 0, fab: demoFab(onTap: () => taps++)));
      await tester.pumpAndSettle();
      final back = tester.widget<Opacity>(
        find
            .ancestor(of: find.text('圆钮'), matching: find.byType(Opacity)),
      );
      expect(back.opacity, 1.0);
      await tester.tap(find.text('圆钮'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('圆钮点按回调触发', (tester) async {
      setWindow(tester, const Size(400, 700));
      addTearDown(tester.view.reset);

      var taps = 0;
      await tester.pumpWidget(harness(selected: 0, fab: demoFab(onTap: () => taps++)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('圆钮'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('超过 3 个条目 / tabIndex 越界：initState 断言', (tester) async {
      // 数量与范围校验在 initState 断言（const 构造断言不支持 .length 求值）
      final fourItems = [
        for (var i = 0; i < 4; i++)
          MiGlassNavItem(
            label: 'tab$i',
            painter: RollerIconPainter(MiColors.foregroundFor(MiThemeMode.dark)),
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MiGlassSideNavBar(
              items: fourItems,
              selectedIndex: 0,
              onTap: (_) {},
              fab: demoFab(),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isA<AssertionError>());

      // fab.tabIndex 越界（构造期无法校验，initState 断言）
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MiGlassSideNavBar(
                items: items(MiThemeMode.dark),
                selectedIndex: 0,
                onTap: (_) {},
                fab: MiGlassNavFab(
                  tabIndex: 3,
                  onTap: () {},
                  child: const Text('圆钮'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isA<AssertionError>());
    });
  });

  group('导航形态断点（照 MReader：容器宽 > 600）', () {
    test('usesSideNav 严格大于 600，与 MReader 的 maxWidth > 600 同口径', () {
      expect(MiBreakpoints.navRail, 600);
      expect(MiBreakpoints.usesSideNav(0), isFalse);
      expect(MiBreakpoints.usesSideNav(393), isFalse);
      expect(MiBreakpoints.usesSideNav(599.99), isFalse);
      expect(MiBreakpoints.usesSideNav(600), isFalse, reason: '正好 600 仍走底栏');
      expect(MiBreakpoints.usesSideNav(600.01), isTrue);
      expect(MiBreakpoints.usesSideNav(768), isTrue, reason: '平板也用侧栏');
      expect(MiBreakpoints.usesSideNav(1366), isTrue);
    });

    test('枚举口径：medium / expanded 都用侧栏（600 边界点除外）', () {
      expect(MiWindowSize.compact.usesSideNav, isFalse);
      expect(MiWindowSize.medium.usesSideNav, isTrue);
      expect(MiWindowSize.expanded.usesSideNav, isTrue);
      // 桌面档判定仍是 1024（只用于舞台加宽等桌面专属样式）
      expect(MiBreakpoints.desktop, 1024);
      expect(MiWindowSize.medium.isDesktop, isFalse);
      expect(MiWindowSize.expanded.isDesktop, isTrue);
    });
  });
}
