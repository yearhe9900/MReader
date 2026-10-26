// 书卡「长按抬起反馈」的形态契约（采用 anx 的书卡长按动画和效果）。
//
// 效果的真实出身（写下来，免得以后按表象去错地方找）：anx 的 `onLongPress` 只有一句
// 裸 `showModalBottomSheet`、**没有任何动画**；抬起反馈的真身在 `bookshelf_page.dart
// :388-405`——借 pub 包 `flutter_reorderable_grid_view` 的长按拖拽拿反馈（`onReorder`
// 是空实现，只为反馈不为重排）。本项目书架已去拖拽化、不引该包，照抄其数值自己实现：
// 放大 1.05 / 150ms、阴影渐入 250ms。
//
// ⚠️ 量放大的**正确姿势**（本测试踩过）：放大走 `Transform` 变换，而 `tester.getRect`
// 的 `localToGlobal` 计入的是**祖先**变换——直接量 `find.byType(BookCard)` 量到的是
// 变换宿主自己，尺寸**不含**自身变换（恒为 120，看着像「没生效」）。故统一量变换
// **子树内**的 [Card]（`_card`）。期望值一律硬编码字面量（引用 `kBookLiftScale` 之类
// 常量 = 同义反复，红不了）。
// ══════════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/ui/book_card.dart';

import '../test_config.dart';

/// 卡片原始尺寸（缩放比要按它算，故尺寸必须固定可控）。
const double _kCardWidth = 120;
const double _kCardHeight = 252;

/// 被放大的那层：`AnimatedScale` **子树内**的 `Card`（见文件头「量放大的正确姿势」）。
Finder get _card =>
    find.descendant(of: find.byType(BookCard), matching: find.byType(Card));

/// 几何无关的假封面存储：本测试的书全是 [NoCover]，读方法**永远不会被调用**。
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
BookRecord _book() => BookRecord(
  bookId: 'book0',
  fileName: '0.epub',
  filePath: '0.epub',
  title: '书0',
  author: '作者0',
  format: 'epub',
  cover: const NoCover(),
  importedAt: 1700000000000,
);

/// 宿主：固定尺寸的卡片，居中。
Future<void> _pumpCard(
  WidgetTester tester, {
  required Future<void> Function()? onLongPress,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _kCardWidth,
            height: _kCardHeight,
            child: BookCard(
              record: _book(),
              coverStore: _FakeCoverStore(),
              onTap: () {},
              onLongPress: onLongPress,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  testWidgets('长按 → 放大 1.05 / 150ms + 阴影 250ms；回调 Future 完成后复位', (
    WidgetTester tester,
  ) async {
    // 书架侧语义：这个 Future 在**长按弹框关闭时**完成（`shelf_page._showBookActions`）。
    final Completer<void> sheetClosed = Completer<void>();
    await _pumpCard(tester, onLongPress: () => sheetClosed.future);

    final Rect resting = tester.getRect(_card);
    expect(resting.width, _kCardWidth);
    expect(resting.height, _kCardHeight);

    // 长按（`InkWell` 在 `kLongPressTimeout` 后回调），再推 250ms 把两条动画
    // （放大 150ms、阴影 250ms）走完。
    await tester.longPress(find.byType(BookCard));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // ① 真实渲染尺寸：`_card` 在 `AnimatedScale` 子树内，故 `getRect` 含放大变换。
    final Rect lifted = tester.getRect(_card);
    expect(
      lifted.width,
      closeTo(_kCardWidth * 1.05, 0.01),
      reason: '抬起后宽度应 ×1.05（包内 `_defaultFeedbackScaleFactor`）',
    );
    expect(
      lifted.height,
      closeTo(_kCardHeight * 1.05, 0.01),
      reason: '抬起后高度应 ×1.05',
    );
    expect(
      lifted.center.dx,
      closeTo(resting.center.dx, 0.01),
      reason: '放大须保持居中（anx 的反馈也用 offset 重新居中）',
    );
    expect(lifted.center.dy, closeTo(resting.center.dy, 0.01));

    // ② 形态参数（期望值硬编码；出处见 `book_card.dart` 的顶部总注）。
    final AnimatedScale scale = tester.widget<AnimatedScale>(
      find.byKey(kBookLiftKey),
    );
    expect(scale.scale, 1.05);
    expect(scale.duration, const Duration(milliseconds: 150));
    expect(
      scale.curve,
      Curves.linear,
      reason: '曲线照抄包内兜底值 `Curves.linear`（不是刻意选的缓动）',
    );

    final AnimatedContainer shadow = tester.widget<AnimatedContainer>(
      find.byKey(kBookLiftShadowKey),
    );
    expect(shadow.duration, const Duration(milliseconds: 250));
    expect((shadow.decoration! as BoxDecoration).boxShadow, const <BoxShadow>[
      // 0x33000000 = `Colors.black.withOpacity(0.2)`（0x33 = 51 = 0.2 × 255）。
      BoxShadow(
        color: Color(0x33000000),
        spreadRadius: 5,
        blurRadius: 6,
        offset: Offset(0, 3),
      ),
    ], reason: '抬起阴影须为包内 `_defaultBoxDecoration` 的四参数');
    // ⚠️ 形状必须是**封面的圆角**，不是卡片外框的方角：`BoxShadow` 是填充形状，画在
    // 整张卡外面（卡片无底板、信息区透明）会变成一张**方角灰板**——盖住封面圆角、
    // 长按时整卡变暗。故这颗 `AnimatedContainer` 挂在**封面外框**上
    // （`kBookCoverSurfaceKey` 的祖先），并带 20 圆角（Mi 预览图圆角）。
    expect(
      (shadow.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(20),
      reason: '抬起阴影的形状须跟封面圆角一致（20），否则长按时出现方角灰板',
    );
    expect(
      find.ancestor(
        of: find.byKey(kBookCoverSurfaceKey),
        matching: find.byKey(kBookLiftShadowKey),
      ),
      findsOneWidget,
      reason: '抬起阴影须画在封面外框这一层，不能像原先那样包整张卡',
    );

    // ③ 长按弹框关闭 → 卡片落回原位。
    sheetClosed.complete();
    await tester.pump(); // 微任务：`await` 返回 → setState 复位
    await tester.pump(const Duration(milliseconds: 250));

    final Rect settled = tester.getRect(_card);
    expect(settled.width, closeTo(_kCardWidth, 0.001));
    expect(settled.height, closeTo(_kCardHeight, 0.001));
    expect(
      tester.widget<AnimatedScale>(find.byKey(kBookLiftKey)).scale,
      1.0,
      reason: '复位后缩放目标须回到 1.0',
    );
    expect(
      (tester
                  .widget<AnimatedContainer>(find.byKey(kBookLiftShadowKey))
                  .decoration!
              as BoxDecoration)
          .boxShadow,
      isEmpty,
      reason: '复位后抬起阴影须撤掉（静止态的封面投影仍在，那是另一个 DecoratedBox）',
    );
  });

  testWidgets('`onLongPress` 为 null：长按既不抬起也不响应', (WidgetTester tester) async {
    // `shelf_grid.dart` 现在总是传回调；此用例守的是「不传回调时不长按」这条
    // `BookCard` 自身的契约（避免以后有人把 `_handleLongPress` 无条件挂上）。
    await _pumpCard(tester, onLongPress: null);

    final Rect resting = tester.getRect(_card);
    await tester.longPress(find.byType(BookCard));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.getRect(_card), resting);
    expect(tester.widget<AnimatedScale>(find.byKey(kBookLiftKey)).scale, 1.0);
  });
}
