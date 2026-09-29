// 书架几何**契约测试**（2026-09-29 拍板「几何抽成事实源 + 契约测试」）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 这个测试在防什么
// ══════════════════════════════════════════════════════════════════════════════
// 本项目书架几何照抄 anx-reader，但 anx 的 widget 长在 Riverpod/freezed/sqflite
// 骨架上搬不动，只能抄数值——「抄」就可能抄错，而抄错**画面会崩**（2026-09-28
// 一次几何批次要动 3 个文件 6 处数值）。本测试把关键几何**钉死**：
// 改了事实源 → 这里红 → 人回来核对 PRD + `shelf_geometry.dart` 里的 anx 出处行号。
//
// ⚠️ **期望值一律硬编码字面量，禁止引用 `shelf_geometry` 的常量**——
// 引用常量等于同义反复：常量改了测试也跟着改，就永远红不了、防了个寂寞。
//
// 测量方式是**真实渲染尺寸**（不是断言常量本身），故同时能抓住两类错：
//   ① 数值抄错（常量值不对）；
//   ② 参数接错线（值对但没被用上，如 `childAspectRatio` 写成 `2.1 / 1`）。
// ══════════════════════════════════════════════════════════════════════════════
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/settings/shelf_layout_store.dart';
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
}) async {
  final List<BookRecord> books = <BookRecord>[
    for (int i = 0; i < bookCount; i++) _book(i),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 700,
          child: ShelfGrid(
            folders: const <BookFolder>[],
            books: books,
            allBooks: books,
            coverStore: _FakeCoverStore(),
            openingBookId: null,
            onOpenBook: (_) {},
            onBookActions: (_) {},
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
      // 列数口径：容器宽 ~/ 120（anx `bookshelf_page.dart:453-454`）。
      expect(kShelfCoverTargetWidth, 120);
      expect(kShelfMinColumns, 1);
      expect(kShelfMaxColumns, 64);
      expect(kShelfFallbackColumns, 3);
      // 比例 1/2.1（anx `:455`）、行距 30 / 列距 20（anx `:456-457`）。
      expect(kShelfChildAspectRatio, closeTo(1 / 2.1, 1e-12));
      expect(kShelfMainAxisSpacing, 30);
      expect(kShelfCrossAxisSpacing, 20);
      // 内边距（anx `:449` 左右 20 / 上 12；底部换本项目的 kShellBottomInset）。
      expect(
        kShelfGridPadding,
        const EdgeInsets.fromLTRB(20, 12, 20, kShellBottomInset),
      );
    });

    test('单卡分区', () {
      // anx `book_item.dart:88` 封面↔信息间距 5、`:89-90` 信息区 55。
      expect(kBookCoverToInfoGap, 5);
      expect(kBookInfoHeight, 55);
      // 本项目自有值（anx 该处无此物，见事实源注释）。
      expect(kBookTitleToAuthorGap, 2);
      expect(kBookInfoHorizontalPadding, 2);
      expect(kBookFormatBadgeInset, 6);
    });
  });

  group('② 真实渲染契约', () {
    testWidgets('392 宽 → 3 列；卡片高/宽 = 2.1；信息区+间距 = 60', (
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

      // --- 卡片比例：高 / 宽 = 2.1（childAspectRatio 1/2.1 的倒数）---
      final Size cell = tester.getSize(find.byType(BookCard).first);
      expect(
        cell.height / cell.width,
        closeTo(2.1, 0.02),
        reason: '单元格高宽比应为 2.1（anx childAspectRatio: 1 / 2.1）',
      );

      // --- 信息区合计：卡片高 - 封面(Hero)高 = 间距 5 + 信息区 55 = 60 ---
      final Size cover = tester.getSize(
        find.descendant(
          of: find.byType(BookCard).first,
          matching: find.byType(Hero),
        ),
      );
      expect(
        cell.height - cover.height,
        60,
        reason: '封面下方应只剩「间距 5 + 信息区 55」= 60',
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
      // 距右缘 12 = `Positioned(right: 6)` 的角标内缩（事实源
      // `kBookFormatBadgeInset`）+ `_FormatTag` 自带的 `horizontal: 6` 内边距
      // ——本断言量的是角标**文案 Text**（它比角标容器再往里 6）。
      expect(
        cellRect.right - badgeRect.right,
        closeTo(12, 1),
        reason: '文案右缘距卡片右缘 = 内缩 6 + 标签内边距 6',
      );
      expect(cellRect.bottom - badgeRect.bottom, greaterThan(6),
          reason: '角标贴封面底，其下方还有信息区');
    });
  });
}
