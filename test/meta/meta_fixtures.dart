// M1-T05 元数据测试的公共夹具：封面字节 + 最小可解码图片。
//
// 本文件属测试脚手架（`test/`），不属 `lib/` 产物。
import 'dart:convert';
import 'dart:typed_data';

/// 1×1 真实可解码 PNG（RGB 红点；供魔数嗅探、缩略图生成与图片页测试复用）。
///
/// 2026-09-24 换过一次：旧串 IDAT 的 CRC 损坏、chunk 结构崩坏，Flutter
/// `instantiateImageCodec` 解码必败（「Codec failed to produce an image」），
/// 连带 cover_store 缩略图生成失败。新串由 zlib 自构造，三 chunk CRC 全过。
final Uint8List kTinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mP4z8AAAAMBAQD3A0FDAAAAAElFTkSuQmCC',
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
