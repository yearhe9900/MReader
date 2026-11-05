// BGRA 原始像素 → 可显示位图（`decodeImageFromPixels` 直通）的验证。
//
// 这条路径是 PDF 页的**显示出口**（替代 PNG 中转），必须证明两件事：
// ① 像素通道顺序没搞反（输入 BGRA → 取回 RGBA 逐字节一致）；
// ② 尺寸 / 非法输入有明确后果（尺寸取输入，长度不足显式抛错，不静默花屏）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/bgra_image.dart';
import 'package:mreader/platform/pdf_engine.dart';

/// 2×2 已知色 BGRA 页（左上红 / 右上绿 / 左下蓝 / 右下白）。
PdfRasterPage _knownPage() {
  final Uint8List bgra = Uint8List(2 * 2 * 4);
  void put(int pixel, int r, int g, int b) {
    final int i = pixel * 4;
    bgra[i] = b; // B
    bgra[i + 1] = g; // G
    bgra[i + 2] = r; // R
    bgra[i + 3] = 0xFF; // A
  }

  put(0, 0xFF, 0x00, 0x00);
  put(1, 0x00, 0xFF, 0x00);
  put(2, 0x00, 0x00, 0xFF);
  put(3, 0xFF, 0xFF, 0xFF);
  return PdfRasterPage(bgra: bgra, width: 2, height: 2);
}

void main() {
  test('BGRA → 位图：尺寸取输入，通道顺序正确（取回 RGBA 逐字节一致）', () async {
    final ui.Image image = await decodeBgraToImage(_knownPage());
    addTearDown(image.dispose);

    expect(image.width, 2);
    expect(image.height, 2);

    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    expect(data!.buffer.asUint8List(), <int>[
      0xFF, 0x00, 0x00, 0xFF, // 红
      0x00, 0xFF, 0x00, 0xFF, // 绿
      0x00, 0x00, 0xFF, 0xFF, // 蓝
      0xFF, 0xFF, 0xFF, 0xFF, // 白
    ]);
  });

  test('像素长度不足 / 尺寸非法 → 显式抛错（不静默产出花屏）', () {
    expect(
      () => decodeBgraToImage(
        PdfRasterPage(bgra: Uint8List(8), width: 2, height: 2),
      ),
      throwsArgumentError,
    );
    expect(
      () => decodeBgraToImage(
        PdfRasterPage(bgra: Uint8List(16), width: 0, height: 0),
      ),
      throwsArgumentError,
    );
  });

  test('尾部多余字节被忽略（原生缓冲区常大于逻辑尺寸）', () async {
    final PdfRasterPage page = _knownPage();
    final Uint8List padded = Uint8List(page.bgra.length + 8)
      ..setRange(0, page.bgra.length, page.bgra);
    final ui.Image image = await decodeBgraToImage(
      PdfRasterPage(bgra: padded, width: 2, height: 2),
    );
    addTearDown(image.dispose);
    expect(image.width, 2);
    expect(image.height, 2);
  });
}
