// 图片真尺寸：字节头解析 + 与渲染一致的宽度适配。
//
// 解析只读文件头（PNG IHDR / JPEG SOF / GIF / BMP / WebP），**不解码像素**——
// 纯 Dart 同步可跑，绕开 `dart:ui` 解码（#4 环境限制），任意 isolate 可用。
// 未解出（未加载 / 未知格式 / 字节损坏）→ `null`，测量回退 48×48 占位
// （= `_InlineImage` 加载 / 错误态）。
//
// 渲染一致性：`_InlineImage` 加载后 `Image.memory` 不设固定宽高 → 占位布局走
// `BoxConstraints(maxWidth: 页宽, 无高上限)`（`rendering/paragraph.dart:199`）→
// `constrainSizeAndAttemptToPreserveAspectRatio`（`rendering/box.dart:317`）：
// 仅「宽 > maxWidth」等比缩，高上限 ∞ / 下限 0 均不触发 ⇒ [fitWithinWidth] 同式。
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// 读取图片文件头中的像素尺寸；不支持或损坏 → `null`。
Size? parseImageSize(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (_isPng(bytes)) return _png(bytes);
  if (_isJpeg(bytes)) return _jpeg(bytes);
  if (_isGif(bytes)) return _gif(bytes);
  if (_isBmp(bytes)) return _bmp(bytes);
  if (_isWebp(bytes)) return _webp(bytes);
  return null;
}

/// 与渲染同式（`box.dart:317` width 分支）：仅「宽 > maxWidth」按比例缩，
/// 其余（含空尺寸）原样返回。
Size fitWithinWidth(Size size, double maxWidth) {
  if (size.isEmpty || size.width <= maxWidth) return size;
  return Size(maxWidth, maxWidth * size.height / size.width);
}

/// 章内出现的全部图片 src（原文标记 `\x00IMG:src\x00`，按出现序、去重）。
/// 供分页前预解析尺寸（`ensureImageSize`）用——投影 `placeholderSrcs` 是
/// 测量后的逐占位视图，本函数不依赖排版。
List<String> imageSrcsOf(List<String> paragraphs) {
  final List<String> out = <String>[];
  for (final String paragraph in paragraphs) {
    for (final Match match in _imgMarker.allMatches(paragraph)) {
      final String src = match.group(1)!;
      if (!out.contains(src)) out.add(src);
    }
  }
  return out;
}

/// 确保 [sizes] 含 [href] 的真尺寸：已有条目直接 `false`；否则经 [resolve]
/// 取字节（应先查 `ImageCacheLRU` 再读包，即阅读页的 `_resolveImage`）解析写入。
/// 返回 `true` = 写入了新尺寸 → 调用方须随后 `PaginationScheduler.
/// invalidateForImageSizes()` 重分页；未加载 / 未知格式 → `false` 不写。
Future<bool> ensureImageSize(
  String href,
  Map<String, Size> sizes,
  Future<Uint8List?> Function(String href) resolve,
) async {
  if (sizes.containsKey(href)) return false;
  final Uint8List? bytes = await resolve(href);
  if (bytes == null) return false;
  final Size? size = parseImageSize(bytes);
  if (size == null) return false;
  sizes[href] = size;
  return true;
}

final RegExp _imgMarker = RegExp('\x00IMG:([^\x00]+)\x00');

bool _isPng(Uint8List b) =>
    b.length >= 8 &&
    b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
    b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A;

Size? _png(Uint8List b) {
  // 签名(8) + 长度(4) + IHDR(4) + 宽高各 4（BE）；首块非 IHDR 视为损坏。
  if (b.length < 24 ||
      b[12] != 0x49 || b[13] != 0x48 || b[14] != 0x44 || b[15] != 0x52) {
    return null;
  }
  return _wh(_be32(b, 16), _be32(b, 20));
}

bool _isJpeg(Uint8List b) =>
    b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

Size? _jpeg(Uint8List b) {
  int i = 2;
  while (i + 1 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    int j = i + 1;
    while (j < b.length && b[j] == 0xFF) {
      j++; // 填充 FF
    }
    if (j >= b.length) return null;
    final int marker = b[j];
    if (marker == 0xD9 || marker == 0xDA) return null; // EOI / SOS 前未见 SOF
    if (marker == 0xD8) {
      i = j + 1;
      continue; // SOI 无长度域
    }
    if (j + 2 >= b.length) return null;
    final int length = (b[j + 1] << 8) | b[j + 2];
    if (length < 2) return null; // 畸形长度域，防死循环
    // SOF0-15 中排除 DHT(C4) / JPG(C8) / DAC(CC)。
    final bool sof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (sof) {
      if (j + 7 >= b.length) return null;
      // 段体：精度(1) + 高(2 BE) + 宽(2 BE)。
      return _wh((b[j + 6] << 8) | b[j + 7], (b[j + 4] << 8) | b[j + 5]);
    }
    i = j + 1 + length; // 段 = 长度域(2) + 体(length−2)
  }
  return null;
}

bool _isGif(Uint8List b) =>
    b.length >= 6 &&
    b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 &&
    (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61;

Size? _gif(Uint8List b) =>
    b.length < 10 ? null : _wh(b[6] | b[7] << 8, b[8] | b[9] << 8);

bool _isBmp(Uint8List b) =>
    b.length >= 26 && b[0] == 0x42 && b[1] == 0x4D; // 'BM'

Size? _bmp(Uint8List b) {
  if (b.length < 26) return null;
  final int dib = _le32(b, 14);
  if (dib == 12) return _wh(b[18] | b[19] << 8, b[20] | b[21] << 8); // COREHEADER
  final int w = _le32s(b, 18);
  final int h = _le32s(b, 22); // 负 = 自顶向下
  return _wh(w, h.abs());
}

bool _isWebp(Uint8List b) =>
    b.length >= 12 &&
    b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF
    b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50; // WEBP

Size? _webp(Uint8List b) {
  if (b.length < 16) return null;
  final String fourcc = String.fromCharCodes(b.sublist(12, 16));
  if (fourcc == 'VP8 ') {
    // 有损：帧标签(3) + 同步码 9D 01 2A + 宽/高各 2（LE 14 位）。
    if (b.length < 30 || b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) {
      return null;
    }
    return _wh((b[26] | b[27] << 8) & 0x3FFF, (b[28] | b[29] << 8) & 0x3FFF);
  }
  if (fourcc == 'VP8L') {
    // 无损：0x2F 签名 + 宽−1(14b) + 高−1(14b) 小端位流。
    if (b.length < 25 || b[20] != 0x2F) return null;
    final int w = 1 + (b[21] | (b[22] & 0x3F) << 8);
    final int h =
        1 + (((b[22] >> 6) & 0x03) | (b[23] << 2) | ((b[24] & 0x0F) << 10));
    return _wh(w, h);
  }
  if (fourcc == 'VP8X') {
    // 扩展：画布宽−1 / 高−1 各 3 字节 LE。
    if (b.length < 30) return null;
    return _wh(
      1 + (b[24] | b[25] << 8 | b[26] << 16),
      1 + (b[27] | b[28] << 8 | b[29] << 16),
    );
  }
  return null;
}

Size? _wh(int w, int h) =>
    (w > 0 && h > 0) ? Size(w.toDouble(), h.toDouble()) : null;

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _le32s(Uint8List b, int o) {
  final int v = _le32(b, o);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}
