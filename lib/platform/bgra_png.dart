// BGRA 原始位图 → PNG 字节（PDF 页渲染结果的编码出口）。
//
// 为什么需要它：pdfrx 的 `PdfImage` 只给到 `BGRA8888` 原始像素，而阅读页的图片页
// 管线吃**编码后的图片字节**（CBZ 直接给 JPEG/PNG 原始字节 → `Image.memory`）。
// 要复用同一条管线（含点页全屏缩放的原始字节解码），适配器必须把 BGRA 编成 PNG——
// 这是「让 PDF 页与 CBZ 页对上层完全同形」的代价。
//
// 为什么手写而不用现成库：1. 只要「一种无损编码」，PNG 结构极简（签名 + IHDR +
// IDAT + IEND），deflate 用 `dart:io` 的 `ZLibEncoder`（zlib 流正是 IDAT 格式）；
// 2. 少一个依赖 = 少一个跨平台变量；3. 纯函数、可被单测逐字节验证
// （`test/format/bgra_png_test.dart` 解回像素比对）。
//
// 格式细节：色彩类型 6（truecolor + alpha，每像素 4 字节）位深 8，与 BGRA 一一对应，
// 只需 B 与 R 换位（PNG 是 RGBA 顺序）；每行前置 1 字节过滤器类型 0（None）；
// **本文件是平台层**（用 `dart:io` 的 zlib），不进格式层，不违反纯 Dart 铁律。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// PNG 文件签名（8 字节，`\x89PNG\r\n\x1a\n`）。
const List<int> kPngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// 把 BGRA8888 原始像素编码为 PNG 字节。
///
/// [bgra] 长度必须 ≥ `width * height * 4`（多出的尾部忽略，便于直接吃原生缓冲区）；
/// 像素顺序为 B、G、R、A（pdfrx / pdfium 的原生输出顺序）。
Uint8List encodeBgraToPng(
  Uint8List bgra, {
  required int width,
  required int height,
  int zlibLevel = 6,
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width/height 必须为正：$width x $height');
  }
  final int expected = width * height * 4;
  if (bgra.length < expected) {
    throw ArgumentError('BGRA 字节不足：${bgra.length} < $expected');
  }

  // 1) 扫描线：每行 1 字节过滤器 + width 个 RGBA 像素（B 与 R 换位）。
  final Uint8List raw = Uint8List(height * (1 + width * 4));
  int out = 0;
  for (int y = 0; y < height; y++) {
    raw[out++] = 0; // 过滤器类型 0 = None
    int i = y * width * 4;
    for (int x = 0; x < width; x++) {
      raw[out++] = bgra[i + 2]; // R ← B 位
      raw[out++] = bgra[i + 1]; // G
      raw[out++] = bgra[i]; // B ← R 位
      raw[out++] = bgra[i + 3]; // A
      i += 4;
    }
  }

  // 2) 分块：IHDR + IDAT（zlib 压缩后的扫描线）+ IEND。
  final BytesBuilder png = BytesBuilder(copy: false);
  png.add(kPngSignature);
  final Uint8List ihdr = Uint8List(13);
  _writeUint32(ihdr, 0, width);
  _writeUint32(ihdr, 4, height);
  ihdr[8] = 8; // 位深
  ihdr[9] = 6; // 色彩类型 6 = truecolor + alpha
  ihdr[10] = 0; // 压缩方法（仅 0 合法）
  ihdr[11] = 0; // 过滤方法（仅 0 合法）
  ihdr[12] = 0; // 逐行扫描（非隔行）
  _addChunk(png, 'IHDR', ihdr);
  _addChunk(png, 'IDAT', ZLibEncoder(level: zlibLevel).convert(raw));
  _addChunk(png, 'IEND', const <int>[]);
  return png.takeBytes();
}

void _addChunk(BytesBuilder out, String type, List<int> data) {
  final List<int> typeBytes = ascii.encode(type);
  final Uint8List head = Uint8List(4);
  _writeUint32(head, 0, data.length);
  out.add(head);
  out.add(typeBytes);
  out.add(data);
  // CRC 覆盖 **type + data**（不含长度字段），PNG 规范如此。
  final Uint8List crcInput = Uint8List(typeBytes.length + data.length);
  crcInput.setRange(0, typeBytes.length, typeBytes);
  crcInput.setRange(typeBytes.length, crcInput.length, data);
  final Uint8List crc = Uint8List(4);
  _writeUint32(crc, 0, _crc32(crcInput));
  out.add(crc);
}

void _writeUint32(Uint8List target, int offset, int value) {
  target[offset] = (value >> 24) & 0xFF;
  target[offset + 1] = (value >> 16) & 0xFF;
  target[offset + 2] = (value >> 8) & 0xFF;
  target[offset + 3] = value & 0xFF;
}

/// CRC-32（PNG 用的 IEEE 802.3 多项式 `0xEDB88320`，反射式）。
Uint32List? _crcTableCache;

Uint32List get _crcTable => _crcTableCache ??= _buildCrcTable();

Uint32List _buildCrcTable() {
  final Uint32List table = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) & 0xFFFFFFFF : c >> 1;
    }
    table[n] = c;
  }
  return table;
}

int _crc32(Uint8List bytes) {
  final Uint32List table = _crcTable;
  int c = 0xFFFFFFFF;
  for (int i = 0; i < bytes.length; i++) {
    c = (table[(c ^ bytes[i]) & 0xFF] ^ (c >> 8)) & 0xFFFFFFFF;
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
