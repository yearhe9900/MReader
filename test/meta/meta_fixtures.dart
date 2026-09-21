// M1-T05 元数据测试的公共夹具：封面字节 + 最小可解码图片。
//
// 本文件属测试脚手架（`test/`），不属 `lib/` 产物。
import 'dart:convert';
import 'dart:typed_data';

/// 1×1 真实可解码 PNG（供魔数嗅探与提交 3 的缩略图生成复用）。
final Uint8List kTinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// 伪 JPEG：仅前 3 字节为 `FF D8 FF`（`sniffCoverFormat` 只看头部，足够）。
final Uint8List kTinyJpeg =
    Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A]);

/// 伪 WebP：`RIFF`????`WEBP`。
final Uint8List kTinyWebp = Uint8List.fromList(<int>[
  0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
  0x57, 0x45, 0x42, 0x50, 0x00, 0x00, 0x00, 0x00,
]);

/// 非图片字节（供「嗅探不出格式 -> 跳过该候选」用例）。
final Uint8List kNotAnImage = Uint8List.fromList(utf8.encode('<html></html>'));
