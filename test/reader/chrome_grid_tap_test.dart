// `TYP-09` 点按热区：**九宫格中宫**才是 chrome 唤出开关（2026-10-10 负责人
// 拍板：「将阅读页划为9宫格，只有最中间的宫格位置，才能点击呼出菜单」）。
//
// ## 口径
//
// 判定框 = `reader-chrome-toggle` 手势层的盒（与 `reader-content-area` 同框，
// 顶部让过系统 inset、底部让过 28dp 读数行）。按三分线划 3×3：
//
//   · 中宫 `[w/3, 2w/3] × [h/3, 2h/3]`（**含边界**）的落点 = 呼出 / 收起开关
//     （toggle 语义保留）；
//   · 其余八格落点**无任何效果**（既不呼出、也不收起——防阅读时侧边 / 角落
//     误触把 chrome 翻出来）。
//
// 闸门只管**正文手势层**（`reader-chrome-toggle`）的落点；chrome 显形态下叠
// 在正文之上的 chrome UI（顶栏 / 控制条 / 常驻读数行）各有自己的行为、不进
// 九宫格判定——其中读数行（`reader-chrome-toggle-status`）是设计内的第二切换
// 入口（图片页中央点击被「点页全屏缩放」占用，靠它兜底；`reader_inset_test`
// 已双向钉住），**必须保留**。注意显形态时底部层上移、读数行恰好盖住九宫格
// 底排（实测数见 §2.83）⇒ 那几个落点是「点在读数行上」
// 不是「点在正文上」，用例②显形态段会把这类落点剔出正文格再断言。
//
// ## 落点换算为什么用 `globalToLocal`
//
// `TapUpDetails.localPosition` 的构造兜底是 `localPosition ?? globalPosition`
// （`gestures/tap.dart`）——坐标链一旦不一致会静默退化成全局坐标。而测试窗
// 原点即全局原点、两种写法恒等，测不出来。故产品侧显式
// `RenderBox.globalToLocal(details.globalPosition)`，本文件再用「系统 inset
// 把正文区推离窗口原点」的用例④把该口径钉死（那种布局下两坐标系不重合）。
//
// 期望值不硬编码：格线由 `reader-content-area` 的实测 rect 推出（几何事实源
// 是运行时布局，不是常量）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/control_bar.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('TYP-09 九宫格中宫唤出（点按热区）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_grid_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: fakeRepository(paths),
          ),
        );

    /// chrome 是否在树上（与 `fullscreen_progress_test` 同判据）。
    bool chromeShown(WidgetTester tester) =>
        find.byType(AppBar).evaluate().isNotEmpty &&
        find.byType(ReaderControlBar).evaluate().isNotEmpty;

    Rect contentRect(WidgetTester tester) => tester
        .getRect(find.byKey(const ValueKey<String>('reader-content-area')));

    testWidgets('中宫点按唤出 chrome，再点中宫收起（toggle 语义保留）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      expect(chromeShown(tester), isFalse, reason: '默认即沉浸全屏');
      await tester.tapAt(contentRect(tester).center);
      await tester.pump();
      expect(chromeShown(tester), isTrue, reason: '中宫点按应唤出顶栏 + 控制条');

      await tester.tapAt(contentRect(tester).center);
      await tester.pump();
      expect(chromeShown(tester), isFalse, reason: '再点中宫应收起（开关语义）');

      await closeBook(tester);
    });

    testWidgets('其余八格点按一律无响应（含不收起）', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      final Rect area = contentRect(tester);
      // 3×3 格心（局部 (2c+1)/6 × (2r+1)/6），跳过中宫。
      final List<Offset> offCenter = <Offset>[
        for (int cx = 0; cx < 3; cx++)
          for (int cy = 0; cy < 3; cy++)
            if (!(cx == 1 && cy == 1))
              area.topLeft +
                  Offset(area.width * (2 * cx + 1) / 6,
                      area.height * (2 * cy + 1) / 6),
      ];
      expect(offCenter, hasLength(8), reason: '八格 = 3×3 − 中宫');

      // ① chrome 隐藏态：八格点按**不得呼出**。
      for (final Offset p in offCenter) {
        await tester.tapAt(p);
        await tester.pump();
        expect(chromeShown(tester), isFalse,
            reason: '非中宫落点 $p 不许唤出 chrome（改前点正文任意处都切）');
      }

      // 假绿排除：中宫一触即唤出（证明本用例的 tap 确实送达了手势层）。
      await tester.tapAt(area.center);
      await tester.pump();
      expect(chromeShown(tester), isTrue);

      // ② chrome 显现态：落在**正文上**的格点**也不许收起**（收起同样只认
      // 中宫）。显形态下底部层（读数行 + 控制条）上移叠进正文带、顶栏也压在
      // 正文上——点它们是「点 chrome UI」不是「点正文」，不属闸门口径（读数
      // 行更是设计内的切换入口，见文件头），此处按实测 rect 剔出后再断言。
      final Rect statusRow = tester
          .getRect(find.byKey(const Key('reader-chrome-toggle-status')));
      final Rect controlBar = tester.getRect(find.byType(ReaderControlBar));
      final Rect appBar = tester.getRect(find.byType(AppBar));
      final List<Offset> surfaceCells = offCenter
          .where((Offset p) =>
              !statusRow.contains(p) &&
              !controlBar.contains(p) &&
              !appBar.contains(p))
          .toList();
      expect(surfaceCells, hasLength(5),
          reason: '显形态的读数行 / 控制条只盖住九宫格底排 3 格，其余 5 格必须'
              '露在正文上（overlay 几何变了会在此翻红、提醒人工过目）');
      for (final Offset p in surfaceCells) {
        await tester.tapAt(p);
        await tester.pump();
        expect(chromeShown(tester), isTrue,
            reason: '非中宫落点 $p 不许收起 chrome（收起入口同为中宫）');
      }

      await closeBook(tester);
    });

    testWidgets('三分线口径：中宫含边界，边界外 1px 无响应',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      final Rect area = contentRect(tester);
      // 中宫四角的两条对角：左上角 (w/3, h/3)、右下角 (2w/3, 2h/3)。
      // 表达式与产品侧 `size.width / 3`、`size.width * 2 / 3` **逐字同构**
      // （同值同运算 ⇒ 双精度恒等，边界断言不靠容差）。
      final Offset lowerIn =
          area.topLeft + Offset(area.width / 3, area.height / 3);
      final Offset upperIn =
          area.topLeft + Offset(area.width * 2 / 3, area.height * 2 / 3);
      final Offset lowerOut = lowerIn - const Offset(1, 1);
      final Offset upperOut = upperIn + const Offset(1, 1);

      // 含边界：两条边界角都算中宫（toggle 一下）。
      await tester.tapAt(lowerIn);
      await tester.pump();
      expect(chromeShown(tester), isTrue, reason: '左上边界角（含）应响应');
      await tester.tapAt(lowerIn);
      await tester.pump();
      expect(chromeShown(tester), isFalse, reason: '再点同一边界角应收回');

      await tester.tapAt(upperIn);
      await tester.pump();
      expect(chromeShown(tester), isTrue, reason: '右下边界角（含）应响应');

      // 边界外 1px：不得收起（非中宫连收起都不做）。
      await tester.tapAt(upperOut);
      await tester.pump();
      expect(chromeShown(tester), isTrue,
          reason: '右下边界外 1px 不在中宫——无任何效果');
      await tester.tapAt(upperIn);
      await tester.pump();
      expect(chromeShown(tester), isFalse, reason: '回归中宫恢复响应');
      await tester.tapAt(lowerOut);
      await tester.pump();
      expect(chromeShown(tester), isFalse,
          reason: '左上边界外 1px 不在中宫——不得呼出');

      // 单轴出界探针：四个方向各一点（另一维留在中宫带内）——把 4 条边界
      // **逐条**钉死。对角探针（上面的 lowerOut / upperOut）是双维同出，
      // 单撤一条界会被另一维挡住判绿（变异测不出来），故补这一组。
      final Offset xLowerOut =
          area.topLeft + Offset(area.width / 3 - 1, area.height / 2);
      final Offset xUpperOut =
          area.topLeft + Offset(area.width * 2 / 3 + 1, area.height / 2);
      final Offset yLowerOut =
          area.topLeft + Offset(area.width / 2, area.height / 3 - 1);
      final Offset yUpperOut =
          area.topLeft + Offset(area.width / 2, area.height * 2 / 3 + 1);
      for (final Offset p
          in <Offset>[xLowerOut, xUpperOut, yLowerOut, yUpperOut]) {
        await tester.tapAt(p);
        await tester.pump();
        expect(chromeShown(tester), isFalse,
            reason: '单轴出界点 $p 不在中宫——不得呼出');
      }

      await closeBook(tester);
    });

    testWidgets('系统 inset 把正文区推离窗口原点后，判定仍按正文区局部坐标',
        (WidgetTester tester) async {
      // `globalToLocal` 口径钉死用例：顶部 inset 24dp ⇒ 正文区 rect
      // (0, 24, 800, 548)，**局部 y ≠ 全局 y**。若产品侧误用全局坐标当局部
      // （`localPosition` 兜底退化正是这个形态），中宫横带的判定整体上移 24px，
      // 本用例的陷阱点会立刻翻红。
      // `FakeViewPadding` 以**物理像素**计（`MediaQueryData.fromView` 走
      // `EdgeInsets.fromViewPadding(view.padding, devicePixelRatio)` 折成逻辑
      // 像素）⇒ 逻辑 inset 24dp 要乘回 DPR（测试窗默认 DPR=3，直写 24 只会
      // 得到逻辑 8）。
      tester.view.padding =
          FakeViewPadding(top: 24 * tester.view.devicePixelRatio);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildApp());
      await settle(tester);

      final Rect area = contentRect(tester);
      expect(area.top, 24.0,
          reason: '前提自检：inset 应把正文区推离窗口原点（否则本用例测不到'
              '两坐标系之差）');
      expect(area.height, 548.0,
          reason: '前提自检：600 − 24 inset − 28 读数让位');

      // 陷阱点：全局 y=200 → 局部 y=176 < 548/3=182.67 ⇒ **顶格**，无响应。
      // 误用全局坐标时 200 ∈ [182.67, 365.33] 会被误判进中宫。
      await tester.tapAt(const Offset(400, 200));
      await tester.pump();
      expect(chromeShown(tester), isFalse,
          reason: '局部坐标在顶格——不许响应（误用全局坐标会在此翻红）');

      // 对照点：全局 y=300 → 局部 y=276 ∈ 中宫横带 ⇒ 响应。
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(chromeShown(tester), isTrue, reason: '对照点在中宫——必须响应');
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(chromeShown(tester), isFalse);

      await closeBook(tester);
    });
  });
}
