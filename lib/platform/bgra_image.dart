// 原始光栅 → 可显示位图（PDF 页的显示出口）。
//
// 为什么不用 PNG 中转：整页 1600×2263 的手写 PNG 编码是数百毫秒的纯 CPU
// （B/R 换位 + deflate + CRC），编完还要 Flutter 再解码回像素——而 pdfium 交出的
// **本来就是像素**。`decodeImageFromPixels` 直接吃 BGRA8888，省掉编码 / 传输 /
// 解码三跳，实测同一张页从 `35ms 编码 + 19ms 解码` 降到 `6ms`（桌面，1600×2263）。
//
// ⚠️ [decodeImageFromPixels] 在调用时**同步**把像素拷进引擎缓冲区
// （`ImmutableBuffer.fromUint8List`），因此可以放心在原生缓冲区释放后使用返回的
// 位图；反过来，调用方也**不必**再为「先拷贝再解码」多付一次内存拷贝。
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'pdf_engine.dart';

/// 把 [page] 的 BGRA8888 像素解码成可上屏的位图（**调用方负责 `dispose()`**）。
///
/// 解码失败抛异常（调用方按缺图兜底）；`bgra` 长度不足时同样抛异常——宁可显式报错，
/// 也不静默产出花屏。
Future<ui.Image> decodeBgraToImage(PdfRasterPage page) {
  final int expected = page.width * page.height * 4;
  if (page.width <= 0 || page.height <= 0 || page.bgra.length < expected) {
    throw ArgumentError(
      'BGRA 像素不合法：${page.bgra.length} < $expected'
      '（${page.width}x${page.height}）',
    );
  }
  final Completer<ui.Image> completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.sublistView(page.bgra, 0, expected),
    page.width,
    page.height,
    ui.PixelFormat.bgra8888,
    completer.complete,
  );
  return completer.future;
}
