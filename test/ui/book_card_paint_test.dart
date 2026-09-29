// 书卡封面的**绘制层次契约**（像素级）——2026-09-29 新建。
//
// ══════════════════════════════════════════════════════════════════════════════
// 这个测试在防什么
// ══════════════════════════════════════════════════════════════════════════════
// 其余 UI 测试都只断言 **widget 属性**（颜色值、圆角值、阴影参数），因此**看不见
// 绘制顺序**。而 2026-09-29 的两个真实缺陷恰恰全出在顺序上（负责人反馈
// 「书籍封面没有圆角，太暗了」），属性断言当时**全是绿的**：
//
//   ① 封面底色/图片曾用 `Ink` / `Ink.image` 画（**墨迹特性**，由上层 `Material`
//      绘制：`material.dart:621-634` 先画 ink 特性、再画子树）⇒ **逃逸**封面外框的
//      `ClipRRect`（裁切只作用于该 Material 的子**树**）⇒ 封面是**方角**；
//   ② 同一个墨迹层落在封面外框 `DecoratedBox` 的投影**填充**之下
//      （`BoxShadow` 是填充形状：`box_decoration.dart:448-470` 直接 `drawRRect` 填充）
//      ⇒ 整张封面被染上一层 α0.39 的色：浅色主题 = 灰（实测 `#9FA8DA` → `#9FA4C2`）、
//      深色主题 = 黑（→ `#616685`）⇒「太暗了」。
//
// 修法：封面（含占位底色）一律改成**子树内**不透明绘制（`Image.memory` /
// `ColoredBox`）。本测试用**真实像素**把这层契约钉死——属性断言再变绿也没用，
// 只要顺序回潮这里就红。
//
// 手法：把书卡放进 `RepaintBoundary` → `toImage()` → 读 RGBA 原始字节采样。
// ⚠️ `toImage()` 必须在 `tester.runAsync` 里 await（FakeAsync 不排空真异步）。
// ⚠️ 必须钉 `devicePixelRatio = 1`：默认 3 会把采样坐标算错。
// ══════════════════════════════════════════════════════════════════════════════
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/theme/app_theme.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/default_book_cover.dart';

import '../test_config.dart';

const Key _kBoundaryKey = ValueKey<String>('paint-probe-boundary');

/// 封面盒尺寸（与 392 宽三列网格里的实际封面宽接近）。
const double _kCoverWidth = 120;
const double _kCoverHeight = 192;

/// 几何无关的假封面存储（本测试的书全是 [NoCover]，读方法不会被调用）。
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

/// 渲染一张无封面书卡并返回「封面区域内的像素读取器」。
Future<int Function(double, double)> _pumpAndSample(
  WidgetTester tester,
  Brightness brightness,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 700);
  addTearDown(tester.view.reset);

  final BookRecord book = BookRecord(
    bookId: 'book0',
    fileName: '0.epub',
    filePath: '0.epub',
    title: '书0',
    author: '作者0',
    format: 'epub',
    cover: const NoCover(),
    importedAt: 0,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _kBoundaryKey,
            child: SizedBox(
              width: _kCoverWidth,
              height: _kCoverHeight,
              child: BookCard(
                record: book,
                coverStore: _FakeCoverStore(),
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_kBoundaryKey),
  );
  final Rect cover = tester.getRect(find.byKey(kBookCoverSurfaceKey));
  // 转成 boundary 内的局部坐标（`toImage` 的输出原点 = boundary 左上角）。
  final Rect local = boundary.globalToLocal(cover.topLeft) & cover.size;

  late ui.Image image;
  late ByteData data;
  await tester.runAsync(() async {
    image = await boundary.toImage();
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });

  return (double dx, double dy) {
    final int i =
        ((local.top + dy).round() * image.width + (local.left + dx).round()) *
        4;
    return (data.getUint8(i) << 16) |
        (data.getUint8(i + 1) << 8) |
        data.getUint8(i + 2);
  };
}

String _hex(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0')}';

void main() {
  capTestTimeout();

  // `书0` → `Colors.primaries[6]` = lightBlue（见 `default_book_cover_test.dart` 的注）。
  final int coverColor = defaultBookCoverColor('书0').toARGB32() & 0xffffff;

  for (final Brightness brightness in Brightness.values) {
    testWidgets('$brightness：封面不被投影染色，且圆角外不画封面', (WidgetTester tester) async {
      final int Function(double, double) pixel = await _pumpAndSample(
        tester,
        brightness,
      );

      // ① 封面内部（避开左上书名与右下角水印）：必须**精确等于**调色板底色。
      //    曾经这里浅色得 `#9FA4C2`、深色得 `#616685`（α0.39 的投影填充盖在封面上）。
      final int inner = pixel(12, _kCoverHeight * 0.55);
      expect(
        inner,
        coverColor,
        reason:
            '封面内部像素须精确等于默认封面底色 ${_hex(coverColor)}'
            '（实测 ${_hex(inner)} 说明有东西盖在封面上——通常是外框投影的填充）',
      );

      // ② 左上角 (2,2)：圆角 8 的弧**外**（到弧心 (8,8) 距离 ≈ 8.49 > 8），
      //    故这里**不该**是封面色（应是背景 / 投影）。曾测到这里仍是封面色
      //    —— 因为底色走墨迹层、逃逸了 `ClipRRect`，封面成了方角。
      final int corner = pixel(2, 2);
      expect(
        corner,
        isNot(coverColor),
        reason: '圆角外不该出现封面底色（实测 ${_hex(corner)}）——圆角被漏裁了',
      );
    });
  }
}
