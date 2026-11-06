// 阅读页底部工具栏（mi_like_ui 悬浮工具栏）的**布局契约**。
//
// 形态（负责人 2026-11-06 拍板）：原「上一章 — 进度滑条 — 下一章」那一行
// **暂时移除**，底部只剩一枚 `MiFloatingToolbar` **胶囊**，内横排
// 目录 / 夜间 / 设置 / 更多 四格（`MiActionEntry`，64×56 定宽格）。本测试钉住：
//   ① 工具栏不吞正文高度（覆盖层，盒高 ≤ 80dp；胶囊本体 = 外留白 8×2 + 格高 56 = 72）；
//   ② 四档屏宽（800/393/360/320）均无溢出；
//   ③ 四格一个不少（窄屏也不吞控件）；
//   ④ 胶囊居中、宽 = 4×64 + 外留白 12×2 = 280dp，任何档宽都不越出屏；
//   ⑤ 「更多」无收纳项时该格不渲染（不留空壳）；
//   ⑥ 悬浮「听」钮计入盒高（画在盒外会命中告警），但**不给胶囊长高**。
//
// 滑条相关口径（滑条宽度 > 60dp、章钮禁用不消失、单章书降禁用）随那一行
// **一并移除**，恢复滑条时要连同 git 历史里的旧用例一起取回。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart';

import '../test_config.dart';

/// 胶囊宽 = 4 格 × 64 + 外留白 12×2（与 `MiFloatingToolbarMetrics.outsidePadding`
/// 同源；改上游外留白 / 格宽要同步这里）。
const double _kToolbarWidth = 4 * kReaderToolbarCellWidth + 12 * 2;

/// 胶囊高 = 外留白 8×2 + 格高 56（见 [kReaderToolbarCellHeight]）。
const double _kToolbarHeight = 8 * 2 + kReaderToolbarCellHeight;

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  // 按给定屏宽构建阅读页底部工具栏并 settle。
  Future<void> pumpBar(
    WidgetTester tester,
    int width, {
    bool withMore = true,
    Widget? floating,
  }) async {
    tester.view.physicalSize = Size(width.toDouble(), 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ReaderControlBar(
          onToc: () {},
          onNight: () {},
          nightActive: false,
          onSettings: () {},
          onMore: withMore ? () {} : null,
          floating: floating,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('阅读页底部工具栏（悬浮胶囊形态）', () {
    testWidgets('不吞正文高度：无听钮盒高 ≤ 80dp（胶囊本体 72）',
        (WidgetTester tester) async {
      // 盒高 = 胶囊 72；断言上限而非精确值——真值口径是「不得显著长高」，
      // 因为工具栏是 `bottomNavigationBar` 覆盖层，长高 1dp 就是正文少 1dp
      // （`TYP-09` 契约由 inset 测试钉住）。
      await pumpBar(tester, 800);
      final double height =
          tester.getSize(find.byType(ReaderControlBar)).height;
      expect(height, lessThanOrEqualTo(80), reason: '盒高 $height，胶囊应为 72');
      expect(height, greaterThanOrEqualTo(_kToolbarHeight),
          reason: '盒高不得小于胶囊本体（否则胶囊顶部被 `Clip.hardEdge` 削掉）');
    });

    testWidgets('四档屏宽（800/393/360/320）均无溢出、无重叠',
        (WidgetTester tester) async {
      for (final int width in <int>[800, 393, 360, 320]) {
        await pumpBar(tester, width);
        expect(tester.takeException(), isNull,
            reason: '${width}dp 宽下不得出现 RenderFlex 溢出');
      }
    });

    testWidgets('四格一个不少（窄屏也不吞控件）', (WidgetTester tester) async {
      for (final int width in <int>[393, 320]) {
        await pumpBar(tester, width);
        for (final String key in <String>[
          'reader-toc',
          'reader-night',
          'reader-appearance',
          'reader-more',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget,
              reason: '${width}dp 下 $key 不应消失');
        }
      }
    });

    testWidgets('胶囊居中、宽 280dp、不越出屏（四档宽度）',
        (WidgetTester tester) async {
      for (final int width in <int>[800, 393, 360, 320]) {
        await pumpBar(tester, width);
        final Rect pill = tester.getRect(find.byType(MiFloatingToolbar));
        expect(pill.width, moreOrLessEquals(_kToolbarWidth, epsilon: 0.5),
            reason: '${width}dp 下胶囊宽 ${pill.width}（应为 $_kToolbarWidth）');
        expect(pill.center.dx, moreOrLessEquals(width / 2, epsilon: 0.5),
            reason: '${width}dp 下胶囊应水平居中（中心 ${pill.center.dx}）');
        expect(pill.left, greaterThanOrEqualTo(0), reason: '胶囊不得越出左屏缘');
        expect(pill.right, lessThanOrEqualTo(width + 0.5),
            reason: '胶囊不得越出右屏缘（320dp 档最紧）');
        // 胶囊自身画投影（不引离屏）⇒ 它必须落在工具栏盒内。
        final Rect bar = tester.getRect(find.byType(ReaderControlBar));
        expect(pill.top, greaterThanOrEqualTo(bar.top - 0.5),
            reason: '胶囊顶部不得探出盒外（会被 `Clip.hardEdge` 削掉）');
      }
    });

    testWidgets('「更多」无收纳项 → 该格不渲染；有则在场',
        (WidgetTester tester) async {
      await pumpBar(tester, 800, withMore: false);
      expect(find.byKey(const Key('reader-more')), findsNothing,
          reason: '全不可用时不留空壳格子');

      await pumpBar(tester, 800, withMore: true);
      expect(find.byKey(const Key('reader-more')), findsOneWidget);
    });

    testWidgets('悬浮「听」钮计入盒高，且钮落在盒内（不给胶囊长高）',
        (WidgetTester tester) async {
      await pumpBar(
        tester,
        800,
        floating: const SizedBox(
          key: Key('reader-control-tts'),
          width: 48,
          height: 48,
        ),
      );
      final Rect bar = tester.getRect(find.byType(ReaderControlBar));
      final Rect pill = tester.getRect(find.byType(MiFloatingToolbar));
      final Rect fab =
          tester.getRect(find.byKey(const Key('reader-control-tts')));

      // 听钮区 = 48 + 间隙 12 ⇒ 盒高 = 72 + 60 = 132。
      expect(bar.height,
          moreOrLessEquals(_kToolbarHeight + 48 + 12, epsilon: 0.5),
          reason: '听钮区必须计入盒高（画在盒外 → 事件穿透到正文 / tap 告警）');
      expect(fab.bottom, lessThanOrEqualTo(bar.bottom + 0.5),
          reason: '听钮必须落在盒内');
      // 听钮在胶囊**上方**（`bottom: 胶囊高 + 间隙`），不给胶囊长高。
      expect(pill.height, moreOrLessEquals(_kToolbarHeight, epsilon: 0.5),
          reason: '有听钮时胶囊高仍应是 72');
      expect(fab.bottom, moreOrLessEquals(pill.top - 12, epsilon: 0.5),
          reason: '听钮应悬在胶囊上方 12dp 处');
    });
  });
}
