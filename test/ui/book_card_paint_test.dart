// 书卡封面的**绘制层次契约**（像素级）。
//
// 防什么：widget 属性断言（颜色/圆角/阴影参数）**看不见绘制顺序**。封面底色曾走
// `Ink`/`Ink.image` 墨迹层（由上层 `Material` 绘制）⇒ 逃逸封面外框的 `ClipRRect`
// （裁切只作用于子树）成方角；且墨迹层落在外框投影的填充之下被 α 染暗（「太暗了」）。
// 修法：封面一律**子树内**不透明绘制（`Image.memory` / `ColoredBox`）。本测试用**真实像素**
// 钉死这层契约——属性断言再绿也没用，顺序回潮这里就红。
//
// 手法：书卡放进 `RepaintBoundary` → `toImage()` → 读 RGBA 原始字节采样。
// ⚠️ `toImage()` 必须在 `tester.runAsync` 里 await（FakeAsync 不排空真异步）；
// ⚠️ 必须钉 `devicePixelRatio = 1`（默认 3 会把采样坐标算错）。
// ══════════════════════════════════════════════════════════════════════════════
import 'dart:async';
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

/// 卡片**全高** = 封面 192 + 间距 [kBookCoverToInfoGap] 8 + 信息区 [kBookInfoHeight] 30。
/// boundary 必须取全高，否则信息区被挤出可视区、下面的采点会越界。
const double _kCardHeight = _kCoverHeight + 8 + 30;

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

/// 返回**真图封面**字节的假存储（用于 [StoredCover] 路径）。
///
/// 为什么单列这条路径：[DefaultBookCover] **自带** `ClipRRect`，外层裁切失效它也圆、
/// 看不出来；真图封面走 [Image.memory] **完全依赖** `_buildCoverSurface` 里那一层
/// `ClipRRect`，必须自己钉住。
class _ImageCoverStore implements CoverStore {
  _ImageCoverStore(this.bytes);

  final Uint8List bytes;

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
  Future<Uint8List?> readFull(CoverRef ref) async => bytes;

  @override
  Future<Uint8List?> readThumb(CoverRef ref) async => bytes;

  @override
  Future<void> delete(CoverRef ref) async {}

  @override
  Future<int> purgeOrphans({required Set<String> referencedFileNames}) async =>
      0;
}

/// 一张**纯色** PNG（128×128）。用 `ui` 的真实编码器生成，避免手写 PNG 字节出错。
///
/// 纯色是关键：任何「封面底色漏到圆角外」都会在像素上表现为该纯色，好断言。
Future<Uint8List> _solidPng(Color color) async {
  const int side = 128;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..color = color,
  );
  final ui.Image image = await recorder.endRecording().toImage(side, side);
  final ByteData data = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  return data.buffer.asUint8List();
}

/// 渲染一张书卡并返回「封面区域内的像素读取器」。
///
/// [imageBytes] 非空时走**真图封面**路径（[StoredCover] → `Image.memory`）；
/// 为空则走**默认封面**路径（[NoCover] → [DefaultBookCover]）。
Future<int Function(double, double)> _pumpAndSample(
  WidgetTester tester,
  Brightness brightness, {
  Uint8List? imageBytes,
}) async {
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
    cover: imageBytes == null
        ? const NoCover()
        : const StoredCover('probe.png'),
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
              height: _kCardHeight,
              child: BookCard(
                record: book,
                coverStore: imageBytes == null
                    ? _FakeCoverStore()
                    : _ImageCoverStore(imageBytes),
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (imageBytes != null) {
    // 真图路径有两段真异步：① `_loadThumb` 的 `await readThumb`；
    // ② `Image.memory` 的解码。都必须在 `runAsync` 里推进，`pump` 推不动。
    for (int i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

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

      // ① 封面内部（避开左上书名与右下角水印）：必须**精确等于**调色板底色
      //    （曾被外框投影的 α 填充染暗过）。
      final int inner = pixel(12, _kCoverHeight * 0.55);
      expect(
        inner,
        coverColor,
        reason:
            '封面内部像素须精确等于默认封面底色 ${_hex(coverColor)}'
            '（实测 ${_hex(inner)} 说明有东西盖在封面上——通常是外框投影的填充）',
      );

      // ② 左上角 (2,2) 在圆角 20 的弧**外**（角弧中心 (20,20)，(2,2) 距它
      //    √(18²+18²) ≈ 25.5 > 20），**不该**是封面色（应是背景 / 投影）；
      //    底色走墨迹层逃逸 `ClipRRect` 时这里会读到封面色（方角回潮即红）。
      final int corner = pixel(2, 2);
      expect(
        corner,
        isNot(coverColor),
        reason: '圆角外不该出现封面底色（实测 ${_hex(corner)}）——圆角被漏裁了',
      );
    });
  }

  // 「打开准备中」的封面蒙层已随「点击即开书」移除（点卡即进阅读页骨架屏，
  // 书架侧无准备期）——原蒙层用例（只盖封面 / 圆角裁切 / 不碰信息区）随实现下线。

  // **真图封面**（`StoredCover` → `Image.memory`）的圆角契约。为什么单列：默认封面
  // [DefaultBookCover] **自带** `ClipRRect`，外层裁切失效它也会圆；真图封面**完全依赖**
  // `_buildCoverSurface` 那一层裁切，这条路径必须自己钉住。
  for (final Brightness brightness in Brightness.values) {
    testWidgets('$brightness：真图封面被裁进圆角（不逃逸 ClipRRect）', (WidgetTester tester) async {
      // 纯色封面：内部像素必须**精确等于**该色，圆角外必须**不是**它。
      const Color coverColor = Color(0xFF1E88E5); // blue 600，深浅主题下都好分辨
      final Uint8List png = (await tester.runAsync(
        () => _solidPng(coverColor),
      ))!;

      final int Function(double, double) pixel = await _pumpAndSample(
        tester,
        brightness,
        imageBytes: png,
      );
      const int coverRgb = 0x1E88E5;

      // ① 自检：确实渲染的是这张真图（否则后面的圆角断言毫无意义）。
      final int inner = pixel(12, _kCoverHeight * 0.55);
      expect(
        inner,
        coverRgb,
        reason: '真图封面内部须精确等于纯色 ${_hex(coverRgb)}（实测 ${_hex(inner)}）',
      );

      // ② 圆角外不得出现封面色；若 `Image.memory` 逃逸 `ClipRRect`，这里会读到封面色
      //    ⇒ 方角回潮即红。
      final int corner = pixel(2, 2);
      expect(
        corner,
        isNot(coverRgb),
        reason:
            '圆角外不该出现真图封面色（实测 ${_hex(corner)}）'
            '——`Image.memory` 逃逸了外层 `ClipRRect`，封面成了方角',
      );
    });
  }

  // **墨迹（高亮 + 水波纹）必须整体关闭**：ink 特性画在子树之下，只从卡片仅有的两处
  // 透明区（信息区文字 / 封面圆角缺口）露出来，长按时会糊灰底（机制详 `book_card.dart`
  // 的 InkWell 注）。
  //
  // 两条断言（互为兜底）：
  //   ① **确定性属性**——`InkWell` 的墨迹取色与工厂必须是「透明 / `NoSplash`」（读 widget
  //      自己的公开字段，不用本仓常量，避免同义反复）。
  //   ② **像素**——按住不放、长按阈值之前采样（水波纹已起、放大未起），信息区与圆角缺口
  //      必须与静止态**逐位相同**；反向验证：把 splash 改回默认即染灰判红。
  testWidgets('书卡墨迹：按下/长按不得在文字区与圆角缺口留下灰底', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 700);
    addTearDown(tester.view.reset);

    final Completer<void> sheet = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: _kBoundaryKey,
              child: SizedBox(
                width: _kCoverWidth,
                height: _kCardHeight,
                child: BookCard(
                  record: BookRecord(
                    bookId: 'book0',
                    fileName: '0.epub',
                    filePath: '0.epub',
                    title: '书0',
                    author: '作者0',
                    format: 'epub',
                    cover: const NoCover(),
                    importedAt: 0,
                  ),
                  coverStore: _FakeCoverStore(),
                  onTap: () {},
                  onLongPress: () => sheet.future,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // ① 确定性属性契约：墨迹三条通路全部关死。
    final InkWell ink = tester.widget<InkWell>(find.byType(InkWell));
    expect(
      ink.highlightColor?.toARGB32(),
      0x00000000,
      reason: '按下高亮必须透明（0x00000000）——否则长按会在整卡糊一块灰',
    );
    expect(
      ink.splashColor?.toARGB32(),
      0x00000000,
      reason: '水波纹色必须透明（0x00000000）',
    );
    expect(
      ink.splashFactory,
      NoSplash.splashFactory,
      reason: '水波纹工厂必须是 NoSplash——InkSparkle 是整块矩形填充，会糊住文字与圆角',
    );

    // ② 像素契约：按住不放，看文字区 / 圆角缺口是否被水波纹染灰。
    final RenderRepaintBoundary boundary = tester.renderObject(
      find.byKey(_kBoundaryKey),
    );
    final Rect cover = tester.getRect(find.byKey(kBookCoverSurfaceKey));

    Future<(int, int)> sample() async {
      late ui.Image image;
      late ByteData data;
      await tester.runAsync(() async {
        image = await boundary.toImage();
        data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      });
      final Rect local = boundary.globalToLocal(cover.topLeft) & cover.size;
      int at(double dx, double dy) {
        final int i =
            ((local.top + dy).round() * image.width +
                (local.left + dx).round()) *
            4;
        return (data.getUint8(i) << 16) |
            (data.getUint8(i + 1) << 8) |
            data.getUint8(i + 2);
      }

      // (信息区书名行, 圆角缺口)：卡片上仅有的两处透明区。
      return (at(12, cover.height + 20), at(2, 2));
    }

    final (int idleText, int idleCorner) = await sample();

    // 按住不放（长按阈值 500ms 之前采样：水波纹已起、放大未起，坐标稳定）。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(BookCard)),
    );
    int last = 0;
    for (final int ms in <int>[250, 300, 350, 400]) {
      await tester.pump(Duration(milliseconds: ms - last));
      last = ms;
      final (int text, int corner) = await sample();
      expect(
        text,
        idleText,
        reason:
            't=${ms}ms 信息区（文字）不该被墨迹染色：静止 ${_hex(idleText)} → 实测 '
            '${_hex(text)}（`0x40CCCCCC` 叠黑底 = `#333333`）',
      );
      expect(
        corner,
        idleCorner,
        reason:
            't=${ms}ms 封面圆角缺口不该被墨迹染色：静止 ${_hex(idleCorner)} → 实测 '
            '${_hex(corner)}',
      );
    }
    await gesture.up();
    sheet.complete();
    await tester.pump();
  });
}
