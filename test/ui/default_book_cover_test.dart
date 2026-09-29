// 默认封面（无封面书籍）的形态契约
// （2026-09-29 拍板「采用 anx 无封面书籍的默认封面」：① 只改占位控件、② 完全照抄 anx 取色）。
//
// 视觉口径逐条对映 anx `widgets/bookshelf/book_cover.dart` 的默认封面分支
// （代码侧出处见 `lib/ui/default_book_cover.dart` 头注），本测试把可判定的部分钉死：
//   ① 底色 = `Colors.primaries[书名.hashCode % 18].shade200`；
//   ② 文字色按底色亮度自适应（浅底黑字 / 深底白字）；
//   ③ 四个尺寸与**封面宽度**成比例（0.12 / 0.08 / 0.8 / 0.08）；
//   ④ 右下角旋转 15° 的书本水印（文字色 10% 透明），故意探出封面后被裁；
//   ⑤ 长书名 3 行内省略、不溢出（`META-07` 验收 ②）；
//   ⑥ 底色画在**子树内**（`ColoredBox`），**不用 `Ink`**——`Ink` 是墨迹特性、
//      由上层 Material 绘制 ⇒ 会被外框 `ClipRRect` 漏裁（方角）并被投影填充染色
//      （变暗）；也不依赖 `Material` 祖先。
//
// ⚠️ 期望值一律硬编码字面量。其中「书名 → 具体颜色」两条是**按当前 SDK 的
// `String.hashCode` 实测**钉的（`三体` → 下标 4、`活着` → 下标 0）；SDK 升版若换了
// hashCode 算法，这两条会红，届时**按实测改字面量**即可——「公式」那条断言不受
// 影响，故能区分「SDK 漂移」与「取色口径被改」。
//
// ⚠️ 尺寸断言一律用 `closeTo`：这些值来自 `宽 × 0.12` 之类的浮点乘法
// （`120 * 0.12 = 14.400000000000002`），与字面量做 `==` 会假红。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/default_book_cover.dart';
import 'package:mreader/ui/shelf_grid.dart';

import '../test_config.dart';

const String _kTitle = '三体';
const String _kAuthor = '刘慈欣';

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

/// 宿主：固定宽高的封面盒，放在 `Scaffold` 里（**不必再有 `Material` 祖先**——
/// 底色走 `ColoredBox`，见 group ④）。高度按书架封面区的实际比例
/// （1.6 × 宽）给，保证「不溢出」的判定是真实场景而非凑数。
Future<void> _pumpCover(
  WidgetTester tester, {
  required double width,
  double? height,
  String title = _kTitle,
  String author = _kAuthor,
  double radius = 8,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height ?? width * 1.6,
            child: DefaultBookCover(
              title: title,
              author: author,
              radius: radius,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 读某 finder 命中的 `Text` 的样式（须唯一命中）。
TextStyle _styleOf(Finder finder) =>
    (finder.evaluate().single.widget as Text).style!;

/// 封面内边距（标题 `Text` 的**最近** `Padding` 祖先；`find.ancestor` 由近及远）。
EdgeInsets _coverPadding(WidgetTester tester) =>
    tester
            .widget<Padding>(
              find
                  .ancestor(
                    of: find.text(_kTitle),
                    matching: find.byType(Padding),
                  )
                  .first,
            )
            .padding
        as EdgeInsets;

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('① 取色（纯函数；anx `book_cover.dart:57-59` / `:23-26`）', () {
    test('底色 = Colors.primaries[书名.hashCode % 18].shade200', () {
      expect(
        Colors.primaries.length,
        18,
        reason: 'anx 直接用 Colors.primaries.length，不是写死的 18',
      );
      // 口径本身（与 anx 逐字一致的公式）。
      final Color ofSanTi = defaultBookCoverColor(_kTitle);
      expect(
        ofSanTi,
        Colors.primaries[_kTitle.hashCode % Colors.primaries.length].shade200,
      );
      // 实测钉点（见文件头注）：`三体` → 下标 4 = indigo，`活着` → 下标 0 = red。
      expect(ofSanTi, Colors.indigo.shade200);
      expect(defaultBookCoverColor('活着'), Colors.red.shade200);
      // 「浅色 / shade200」这一档被钉死：结果必须落在这 18 个 `shade200` 里
      // （改去 shade500 之类会红；而 SDK 换 hashCode 只会让上面两条钉点红）。
      expect(<Color>[
        for (final MaterialColor c in Colors.primaries) c.shade200,
      ], contains(defaultBookCoverColor('红楼梦')));
      // 换本书换色（不是固定取 0 号色）。
      expect(ofSanTi, isNot(defaultBookCoverColor('活着')));
    });

    test('文字色按底色亮度自适应（浅底黑字 / 深底白字）', () {
      expect(defaultBookCoverInk(Colors.indigo.shade200), Colors.black);
      expect(defaultBookCoverInk(Colors.red.shade200), Colors.black);
      expect(defaultBookCoverInk(Colors.black), Colors.white);
      expect(defaultBookCoverInk(Colors.indigo.shade900), Colors.white);
    });
  });

  group('② 尺寸与封面宽度成比例（真渲染）', () {
    testWidgets('120 宽 → 标题 14.4 / 作者 9.6 / 水印 96 / 内边距 9.6', (
      WidgetTester tester,
    ) async {
      await _pumpCover(tester, width: 120);

      expect(_styleOf(find.text(_kTitle)).fontSize, closeTo(14.4, 1e-9));
      expect(_styleOf(find.text(_kAuthor)).fontSize, closeTo(9.6, 1e-9));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.book)).size,
        closeTo(96, 1e-9),
      );
      expect(_coverPadding(tester).left, closeTo(9.6, 1e-9));
      expect(_coverPadding(tester).right, closeTo(9.6, 1e-9));
    });

    testWidgets('200 宽 → 24 / 16 / 160 / 16（整体等比，非固定值）', (
      WidgetTester tester,
    ) async {
      await _pumpCover(tester, width: 200);

      expect(_styleOf(find.text(_kTitle)).fontSize, closeTo(24, 1e-9));
      expect(_styleOf(find.text(_kAuthor)).fontSize, closeTo(16, 1e-9));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.book)).size,
        closeTo(160, 1e-9),
      );
      expect(_coverPadding(tester).left, closeTo(16, 1e-9));
    });
  });

  group('③ 水印与裁切（真渲染）', () {
    testWidgets('右下角、旋转 15°、文字色 10% 透明，且探出封面被裁', (WidgetTester tester) async {
      await _pumpCover(tester, width: 120, radius: 8);

      // 颜色 = 文字色 10% 透明（底色是浅色 → 文字色为黑）。
      expect(
        tester.widget<Icon>(find.byIcon(Icons.book)).color,
        Colors.black.withValues(alpha: 0.1),
        reason: '水印色须为文字色的 10% 透明',
      );

      // 旋转角度从矩阵里**反解**（`Transform.rotate` 的 2×2 部分就是 R(θ)：
      // `storage[0]` = cosθ、`storage[1]` = sinθ），而不是回头引用实现里的常量。
      final Transform rotate = tester.widget<Transform>(
        find
            .ancestor(
              of: find.byIcon(Icons.book),
              matching: find.byType(Transform),
            )
            .first,
      );
      final Matrix4 m = rotate.transform;
      final double degrees =
          math.atan2(m.storage[1], m.storage[0]) * 180 / math.pi;
      expect(degrees, closeTo(15, 1e-9), reason: '水印须旋转 15°');

      // ⚠️ `tester.getRect` 对**旋转过**的 widget **不给轴对齐外接框**：它取的是
      // 「变换后的左上角」与「变换后的右下角」之间的矩形（即对角线的两端），
      // 实测 96 宽 / 15° 时只有 **67.88**（= 96 × (cos15° − sin15°)），而真外接框
      // 是 117.58 —— 直接断言宽度会让人误判成「角度不对」。故只用它取
      // **变换不变的中心**（两角点对称于中心，中点即中心），再按
      // 「中心 ± 半个对角线的投影」自算真·外接框。
      final Offset center = tester.getRect(find.byIcon(Icons.book)).center;
      const double rad = 15 * math.pi / 180;
      final double halfSide = 96 / 2 * (math.cos(rad) + math.sin(rad));
      final Rect bounds = Rect.fromCenter(
        center: center,
        width: halfSide * 2,
        height: halfSide * 2,
      );

      // 位置 = `Positioned(right: -padding*0.8, bottom: -padding*0.5)`（负值 = 声明探出）。
      final Positioned position = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byIcon(Icons.book),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(position.right, closeTo(-7.68, 1e-9));
      expect(position.bottom, closeTo(-4.8, 1e-9));

      // 「压不住的半本书」：真·外接框越过封面右/下缘，由组件自带的 `ClipRRect` 裁掉。
      final Rect cover = tester.getRect(find.byType(DefaultBookCover));
      expect(bounds.right, greaterThan(cover.right));
      expect(bounds.bottom, greaterThan(cover.bottom));

      // 裁切圆角 = 传入的 radius（组件自带裁切，调用方不必再包一层）。
      expect(
        tester
            .widget<ClipRRect>(
              find.descendant(
                of: find.byType(DefaultBookCover),
                matching: find.byType(ClipRRect),
              ),
            )
            .borderRadius,
        BorderRadius.circular(8),
      );
    });

    testWidgets('长书名：3 行内省略、不溢出（META-07 验收 ②）', (WidgetTester tester) async {
      // 320 字标题塞进 120×192 的封面：溢出会被框架报成 FlutterError → 用例红。
      final String longTitle = '长书名' * 80;
      await _pumpCover(tester, width: 120, title: longTitle);

      final Text title = find.text(longTitle).evaluate().single.widget as Text;
      expect(title.maxLines, 3);
      expect(title.overflow, TextOverflow.ellipsis);

      // 正文块必须落在内边距之内（书名贴顶、作者贴底，中间 `Spacer` 撑开）。
      final Rect cover = tester.getRect(find.byType(DefaultBookCover));
      expect(tester.getRect(find.text(longTitle)).top, greaterThan(cover.top));
      expect(
        tester.getRect(find.text(_kAuthor)).bottom,
        lessThan(cover.bottom),
        reason: '作者行须在封面内（底部内边距 9.6）',
      );
    });
  });

  group('④ 底色画在**子树内**（不用 `Ink`：会漏裁 + 被投影染色）', () {
    testWidgets('有 Material 祖先 → 仍用 `ColoredBox`，组件内**没有** `Ink`', (
      WidgetTester tester,
    ) async {
      await _pumpCover(tester, width: 120);

      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byType(DefaultBookCover),
                matching: find.byType(ColoredBox),
              ),
            )
            .color,
        defaultBookCoverColor(_kTitle),
      );
      // **反向断言**：`Ink` 是**墨迹特性**、由上层 `Material` 绘制（`material.dart:621-634`
      // 先画 ink 特性再画子树），于是 ① **逃逸本组件的 `ClipRRect`** ⇒ 封面方角；
      // ② 落在封面外框投影的**填充**之下 ⇒ 整张封面被染上一层 α0.39 的色（「太暗」）。
      // 两条都是 2026-09-29 的像素级实证（见 §2.54），回潮即红。
      expect(
        find.descendant(
          of: find.byType(DefaultBookCover),
          matching: find.byType(Ink),
        ),
        findsNothing,
        reason: '底色必须画在子树内；用 `Ink` 会漏裁并被投影染色',
      );
    });

    testWidgets('无 Material 祖先也照常渲染（不再依赖 Material）', (
      WidgetTester tester,
    ) async {
      // 玻璃库页面没有 `Material` 祖先（PRD §11.4）。此前靠 `Material.maybeOf` 分支
      // 退化成 `ColoredBox`，现在**只剩这一条路**，故这里证明它不需要 Material。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LookupBoundary(
              child: SizedBox(
                width: 120,
                height: 192,
                child: DefaultBookCover(title: _kTitle, author: _kAuthor),
              ),
            ),
          ),
        ),
      );

      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byType(DefaultBookCover),
                matching: find.byType(ColoredBox),
              ),
            )
            .color,
        defaultBookCoverColor(_kTitle),
      );
    });
  });

  testWidgets('接入：书架无封面书卡的封面 = 默认封面（调色板底色）', (WidgetTester tester) async {
    final BookRecord book = BookRecord(
      bookId: 'book0',
      fileName: '0.epub',
      filePath: '0.epub',
      title: '书0',
      author: '作者0',
      format: 'epub',
      cover: const NoCover(),
      importedAt: 1700000000000,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 392,
            height: 700,
            child: ShelfGrid(
              books: <BookRecord>[book],
              coverStore: _FakeCoverStore(),
              openingBookId: null,
              onOpenBook: (_) {},
              onBookActions: (_) async {},
            ),
          ),
        ),
      ),
    );

    // 书卡封面走的是新默认封面（不再是「主题色底 + 书名首字」）。
    expect(
      find.descendant(
        of: find.byType(BookCard),
        matching: find.byType(DefaultBookCover),
      ),
      findsOneWidget,
    );
    // 底色 = 该书书名的调色板色（`书0` → 下标 6 = **lightBlue**，
    // ⚠️ 下标 5 才是 blue——`Colors.primaries` 的顺序是 red/pink/purple/
    // deepPurple/indigo/blue/lightBlue/…，别凭印象数）。
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byType(DefaultBookCover),
              matching: find.byType(ColoredBox),
            ),
          )
          .color,
      Colors.lightBlue.shade200,
    );
    // **整张书卡里一个 `Ink` 都不该有**——书卡曾有 `Ink.image`（真封面）与
    // `Ink`（占位底色）两处墨迹层绘制，它们会漏裁 + 被投影染色（§2.54）。
    expect(
      find.descendant(of: find.byType(BookCard), matching: find.byType(Ink)),
      findsNothing,
      reason: '书卡不得再用负责面绘制的 Ink（InkWell 的水波纹不是 Ink widget）',
    );
  });
}
