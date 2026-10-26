// 书架几何**契约测试**。
//
// 防什么：书架几何照抄 anx-reader（anx 的 widget 长在 Riverpod/freezed/sqflite 骨架上
// 搬不动，只能抄数值），而抄错**画面会崩**。本测试把关键几何**钉死**：改了事实源 →
// 这里红 → 人回来核对 PRD + `shelf_geometry.dart` 里的 anx 出处行号。
//
// ⚠️ **期望值一律硬编码字面量，禁止引用 `shelf_geometry` 的常量**——引用常量等于同义
// 反复：常量改了测试也跟着改，就永远红不了、防了个寂寞。
//
// 测量方式是**真实渲染尺寸**（不是断言常量本身），故同时能抓住两类错：
//   ① 数值抄错（常量值不对）；
//   ② 参数接错线（值对但没被用上，如 `childAspectRatio` 写成 `2.1 / 1`）。
// ══════════════════════════════════════════════════════════════════════════════
import 'dart:typed_data';

import 'package:flutter/material.dart';
// `RenderDecoratedBox`：真·渲染对象断言用（material 不导出 rendering）。
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/theme/app_theme.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/home_shell.dart' show kShellBottomInset;
// 几何常量经 `shelf_grid.dart` 的 `export 'shelf_geometry.dart'` 一并可用
// （再直接 import 事实源会触发 `unnecessary_import`）。
import 'package:mreader/ui/shelf_grid.dart';

import '../test_config.dart';

/// 几何无关的假封面存储：书卡只在 `cover is StoredCover` 时才读缩略图，
/// 本测试的书全是 [NoCover]，故下面的读方法**永远不会被调用**。
class _FakeCoverStore implements CoverStore {
  @override
  Future<StoredCover> materialize({
    required String bookId,
    required PendingCover pending,
  }) => throw UnimplementedError();

  @override
  Future<StoredCover> replaceWithUserPick({
    required String bookId,
    required Uint8List bytes,
    required CoverRef? previous,
  }) => throw UnimplementedError();

  @override
  Future<Uint8List?> readFull(CoverRef ref) async => null;

  @override
  Future<Uint8List?> readThumb(CoverRef ref) async => null;

  @override
  Future<void> delete(CoverRef ref) async {}

  @override
  Future<int> purgeOrphans({required Set<String> referencedFileNames}) async =>
      0;
}

/// 造一本无封面、无进度的书（不触发任何真实 IO）。
BookRecord _book(int i) => BookRecord(
  bookId: 'book$i',
  fileName: '$i.epub',
  filePath: '$i.epub',
  title: '书$i',
  author: '作者$i',
  format: 'epub',
  cover: const NoCover(),
  importedAt: 1700000000000 + i,
);

/// 在**固定宽度**的容器里渲染书架网格（列数由宽度决定，故宽度必须可控）。
///
/// 高度 700：内容区 = 700 - padding(top 12 + bottom 96) = 592，
/// 足够容纳本测试各用例要断言的行数。
Future<void> _pumpGrid(
  WidgetTester tester, {
  required double width,
  required int bookCount,
  ThemeData? theme,
}) async {
  final List<BookRecord> books = <BookRecord>[
    for (int i = 0; i < bookCount; i++) _book(i),
  ];
  await tester.pumpWidget(
    MaterialApp(
      // 不传 = 与既有用例逐字一致（`MaterialApp` 自带浅色 M3 主题）。
      // 封面投影**随主题**（见 `bookCoverShadowOf`），故深浅两档各需要一条用例。
      theme: theme,
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 700,
          child: ShelfGrid(
            books: books,
            coverStore: _FakeCoverStore(),
            openingBookId: null,
            onOpenBook: (_) {},
            // 异步回调：书卡会 `await` 它拿「长按抬起」的复位时机。
            onBookActions: (_) async {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  capTestTimeout();

  group('① 事实源常量（改任一值 = 破坏契约，先核对 PRD 与 anx 出处）', () {
    test('网格度量', () {
      // 列数口径（anx `bookshelf_page.dart:453-454`）保留：392 宽仍 3 列，
      // 与 Mi 参考图（393dp 三列、图宽 115.5）对齐，单列 114.8。
      expect(kShelfCoverTargetWidth, 120);
      expect(kShelfMinColumns, 1);
      expect(kShelfMaxColumns, 64);
      expect(kShelfFallbackColumns, 3);
      // 行距 15 / 列距 11.9 = Mi 卡实测（`MiThemeCardMetrics.rowGap` / `columnGap`；
      // anx 旧值 30 / 20）。
      expect(kShelfMainAxisSpacing, 15);
      expect(kShelfCrossAxisSpacing, 11.9);
      // 页面左右边距 11.9（Mi 首页实测页边距；anx 旧值 20）。上 12 与底部
      // kShellBottomInset 是本项目自有值，不变。
      expect(kShelfPageInset, 11.9);
      expect(
        kShelfGridPadding,
        const EdgeInsets.fromLTRB(11.9, 12, 11.9, kShellBottomInset),
      );
      // 回退高宽比 = 按列宽 120 套同一公式（封面 2:3 + 8 + 30）。
      expect(
        kShelfChildAspectRatio,
        closeTo(120 / (120 * 3 / 2 + 8 + 30), 1e-9),
        reason: '回退比例须与 shelfChildAspectRatio(120) 同口径',
      );
    });

    test('单元格高宽比由列宽推导（封面 2:3 + 间距 8 + 信息区 30）', () {
      // 封面比例 = 常见实体书比例（拍板「高度降低一些，视觉上像一本书」）；
      // Mi 锁屏比例 259:472 ≈ 0.549 回潮即红。
      expect(kBookCoverAspectRatio, closeTo(2 / 3, 1e-12));
      expect(kBookCoverAspectRatio, greaterThan(259 / 472));

      // 392 宽三列：cellW = (392 − 2×11.9 − 2×11.9) / 3 = 114.8。
      expect(
        shelfChildAspectRatio(114.8),
        closeTo(114.8 / (114.8 * 3 / 2 + 8 + 30), 1e-9),
        reason: 'cellHeight 必须 = cellWidth×3/2 + 8 + 30（书本比例 2:3）',
      );
      // 防御分支：非有限 / 非正 → 回退定值（期望值硬编码字面量，不引常量）。
      expect(
        shelfChildAspectRatio(double.infinity),
        closeTo(120 / (120 * 3 / 2 + 8 + 30), 1e-9),
      );
      expect(
        shelfChildAspectRatio(0),
        closeTo(120 / (120 * 3 / 2 + 8 + 30), 1e-9),
      );
    });

    test('浮动头部几何（2026-09-29 参考图批：搜索行 + chips 行）', () {
      // 行高分解 44.1 / 12 / 40 → 头部 96.1（搜索行高 = MiSearchBar 栏高 44.1）。
      // 三值是照参考图**估的初始值**（截图为缩放图，不作精确依据）、可整体调；
      // 但改这里 = 破坏契约，**须同步 `shelf_page_test` 里 96.1 / 108.1 两处字面量**。
      expect(kShelfSearchRowHeight, 44.1);
      expect(kShelfHeaderRowGap, 12);
      expect(kShelfChipsRowHeight, 40);
      expect(kShelfHeaderHeight, 96.1);

      // 合成的网格内边距：top = 状态栏 + 头部 + 12。例：状态栏 48 → 156.1。
      // 左右 11.9 不受头部影响（Mi 页面边距）。
      expect(
        shelfGridPadding(48),
        const EdgeInsets.fromLTRB(11.9, 156.1, 11.9, kShellBottomInset),
      );
      // 状态栏 0（widget 测试窗口）→ 首行顶边 = 0 + 96.1 + 12 = 108.1，
      // 与 `shelf_page_test` 的 `getTopLeft(BookCard).dy == 108.1` 同一口径。
      expect(shelfGridPadding(0).top, 108.1);
      // 其余三边不受头部影响（左右 11.9 / 底部 kShellBottomInset）。
      expect(shelfGridPadding(0).left, 11.9);
      expect(shelfGridPadding(0).right, 11.9);
      expect(shelfGridPadding(0).bottom, kShellBottomInset);
    });

    test('单卡分区', () {
      // Mi 卡实测：图→标题 8（`MiThemeCardMetrics.titleTopGap`；anx 旧值 5）。
      expect(kBookCoverToInfoGap, 8);
      // 信息区固定高 30 = 13.85（cardTitle）+ 2 + 13（作者行）≤ 30（见事实源推导）。
      expect(kBookInfoHeight, 30);
      // 封面圆角 = Mi 圆角 token（`MiDimens.radiusLg`；anx 旧值 8）。
      expect(kBookCoverRadius, 20);
      // 书名左内缩 = Mi 卡标题内缩（`MiThemeCardMetrics.titleIndent`；anx 旧值 2）。
      expect(kBookInfoIndent, 8.8);
      // 本项目自有值（Mi 与 anx 该处均无此物，见事实源注释）。
      expect(kBookTitleToAuthorGap, 2);
      // 角标内缩 8（= `MiDimens.spaceSm`；圆角放大到 20 后，旧值 6 会被角弧擦到）。
      expect(kBookFormatBadgeInset, 8);
    });
  });

  group('② 真实渲染契约', () {
    testWidgets('392 宽 → 3 列；单列 114.8；卡片高 = 列宽×3/2 + 8 + 30；信息区+间距 = 38', (
      WidgetTester tester,
    ) async {
      // 392 = 手机常见逻辑宽；392 ~/ 120 = 3 列。
      await _pumpGrid(tester, width: 392, bookCount: 4);

      // --- 列数：前 3 张必须同一行，第 4 张换行 ---
      final Offset row0 = tester.getTopLeft(find.byType(BookCard).at(0));
      final Offset row0Last = tester.getTopLeft(find.byType(BookCard).at(2));
      final Offset row1First = tester.getTopLeft(find.byType(BookCard).at(3));
      expect(row0Last.dy, row0.dy, reason: '392 宽应为 3 列：第 1~3 张须同行');
      expect(
        row1First.dy,
        greaterThan(row0.dy),
        reason: '392 宽应为 3 列：第 4 张须换到第二行',
      );
      // 列间距顺带锁住（anx crossAxisSpacing 20）。
      expect(
        row0Last.dx - row0.dx,
        greaterThan(0),
        reason: '第 1 张与第 3 张必须横向错开（否则其实只有 1 列）',
      );

      // --- 单元格宽 = (392 − 2×11.9 − 2×11.9) / 3 = 114.8（页边距与列距都是 Mi 的 11.9）---
      final Size cell = tester.getSize(find.byType(BookCard).first);
      expect(
        cell.width,
        closeTo((392 - 2 * 11.9 - 2 * 11.9) / 3, 0.01),
        reason: '单列宽须为「(宽 − 左右页边距 11.9 − 2×列距 11.9) / 3」= 114.8',
      );

      // --- 卡片比例：封面区按书本比例 2:3 随列宽定高，其下叠间距 8 + 信息区 30 ---
      expect(
        cell.height,
        closeTo(cell.width * 3 / 2 + 8 + 30, 0.05),
        reason: '单元格高 = 列宽×3/2 + 8 + 30（书本比例 2:3；锁屏比例 472/259 回潮即红）',
      );

      // --- 信息区合计：卡片高 - 封面(Hero)高 = 间距 8 + 信息区 30 = 38 ---
      final Size cover = tester.getSize(
        find.descendant(
          of: find.byType(BookCard).first,
          matching: find.byType(Hero),
        ),
      );
      expect(
        cell.height - cover.height,
        38,
        reason: '封面下方应只剩「间距 8 + 信息区 30」= 38',
      );
    });

    testWidgets('119 宽 → 1 列（列数下限兜底，`~/` 不会算出 0 列）', (
      WidgetTester tester,
    ) async {
      // 119 ~/ 120 = 0 → 必须被下限兜成 1，否则 grid delegate 断言直接崩。
      await _pumpGrid(tester, width: 119, bookCount: 2);

      final Offset first = tester.getTopLeft(find.byType(BookCard).at(0));
      final Offset second = tester.getTopLeft(find.byType(BookCard).at(1));
      expect(
        second.dy,
        greaterThan(first.dy),
        reason: '119 宽只有 1 列：两本书必须上下排列',
      );
    });

    testWidgets('格式标签角标贴在封面右下角（PRD US-06/LIB-01 的呈现位置）', (
      WidgetTester tester,
    ) async {
      await _pumpGrid(tester, width: 392, bookCount: 1);

      // 角标是封面 Stack 内的 Positioned，故它必须是 BookCard 的后代。
      final Finder badge = find.descendant(
        of: find.byType(BookCard),
        matching: find.text('EPUB'),
      );
      expect(badge, findsOneWidget, reason: '格式标签须在书卡内可见');

      // 位置：贴右下角（距右/下各 6），即不在卡片左半、也不在卡片上半。
      final Rect badgeRect = tester.getRect(badge);
      final Rect cellRect = tester.getRect(find.byType(BookCard).first);
      expect(
        badgeRect.center.dx,
        greaterThan(cellRect.center.dx),
        reason: '角标应在封面右半侧',
      );
      expect(
        badgeRect.center.dy,
        greaterThan(cellRect.center.dy),
        reason: '角标应在封面下半侧',
      );
      // 距右缘 14 = `Positioned(right: 8)` 的角标内缩（`kBookFormatBadgeInset`）+
      // `_FormatTag` 自带的 `horizontal: 6` 内边距——本断言量的是角标**文案 Text**。
      expect(
        cellRect.right - badgeRect.right,
        closeTo(14, 1),
        reason: '文案右缘距卡片右缘 = 内缩 8 + 标签内边距 6',
      );
      expect(cellRect.bottom - badgeRect.bottom, greaterThan(6),
          reason: '角标贴封面底，其下方还有信息区');
    });

    testWidgets('封面圆角 20、投影 = anx 四参数（**浅色主题**；读渲染对象，不是读常量）', (
      WidgetTester tester,
    ) async {
      await _pumpGrid(tester, width: 392, bookCount: 1);

      // 圆角与投影都在封面外框（`_buildCoverSurface` 的 `DecoratedBox`）上：
      // `RenderDecoratedBox.decoration` 就是实际参与绘制的那份 decoration，
      // 故这里断言的是渲染管线里的真值，不是回来引用常量。
      final RenderDecoratedBox surface = tester.renderObject<RenderDecoratedBox>(
        find.byKey(kBookCoverSurfaceKey),
      );
      final BoxDecoration decoration = surface.decoration as BoxDecoration;
      expect(
        decoration.borderRadius,
        BorderRadius.circular(20),
        reason: '封面圆角须为 20（Mi 预览图圆角 `MiDimens.radiusLg`）',
      );
      expect(
        decoration.boxShadow,
        const <BoxShadow>[
          // 0x649E9E9E = `Colors.grey.withAlpha(100)`（0x64 = 100）。
          BoxShadow(
            color: Color(0x649E9E9E),
            spreadRadius: 5,
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
        reason: '浅色主题下封面投影须为 anx `book_item.dart:69-75` 的四参数'
            '（深色主题换色源，见下一条用例）',
      );

      // 裁切用的 `ClipRRect` 必须用**同一个**圆角，否则投影会从裁切角落露出来。
      // ⚠️ 断言的是**全部**下层 `ClipRRect`、不是「那一个」：无封面书卡的占位
      // [DefaultBookCover] 自带一层同圆角裁切，外框下会有两层——逐层验收反而更强，
      // 任一层圆角不一致即红。
      final Iterable<ClipRRect> clips = tester.widgetList<ClipRRect>(
        find.descendant(
          of: find.byKey(kBookCoverSurfaceKey),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clips, isNotEmpty, reason: '封面外框内至少要有一层裁切框');
      for (final ClipRRect clip in clips) {
        expect(clip.borderRadius, BorderRadius.circular(20));
      }
    });

    testWidgets('深色主题：封面投影改用主题阴影色（几何与透明度不变，不再是固定灰）', (
      WidgetTester tester,
    ) async {
      // 前提自检：本用例必须真的跑在深色主题上，否则等于在重测浅色分支。
      expect(AppTheme.dark().brightness, Brightness.dark);
      await _pumpGrid(
        tester,
        width: 392,
        bookCount: 1,
        theme: AppTheme.dark(),
      );

      final RenderDecoratedBox surface = tester.renderObject<RenderDecoratedBox>(
        find.byKey(kBookCoverSurfaceKey),
      );
      final BoxShadow shadow =
          (surface.decoration as BoxDecoration).boxShadow!.single;

      // 色源 = `colorScheme.shadow`（M3 下恒为不透明黑）；透明度与几何照抄 anx
      // 不动 —— `0x64000000` 的 0x64 = 100 = anx 的 `withAlpha(100)`。
      expect(
        shadow,
        const BoxShadow(
          color: Color(0x64000000),
          spreadRadius: 5,
          blurRadius: 10,
          offset: Offset(0, 2),
        ),
        reason: '深色主题的封面投影须为「主题阴影色 + anx 的透明度与几何」',
      );
      // **反向断言**：固定灰是这次要消灭的东西，回潮即红（浅色分支仍用它）。
      expect(
        shadow.color,
        isNot(const Color(0x649E9E9E)),
        reason: '固定灰在深色背景上比背景亮 → 一圈浅色描边（负责人反馈「太强烈」）',
      );
      // 圆角与浅色一致（换的是色源，不是几何）。
      expect(
        (surface.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(20),
      );
    });
  });
}
