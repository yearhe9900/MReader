// BGRA8888 → PNG 编码器的逐字节验证（PDF 页渲染的唯一编码出口）。
//
// 手写编码器必须证明「真能被解码」，故本文件自带一个**独立于实现**的 PNG 结构解析器
// （CRC-32 用按位展开写法，不复用编码器的查表实现——避免「两边同错」），
// 并先拿仓库既有参考图 `kTinyPng`（三 chunk CRC 全过、生产链路已在用的有效 PNG）
// 自检解析器本身，再拿它验证编码器输出。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/bgra_png.dart';

import '../meta/meta_fixtures.dart';
import 'pdf_fakes.dart';

/// 独立实现（按位）的 CRC-32，IEEE 802.3 反射多项式。
int _crc32Ref(List<int> bytes) {
  int crc = 0xFFFFFFFF;
  for (int i = 0; i < bytes.length; i++) {
    crc ^= bytes[i];
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0
          ? ((crc >> 1) ^ 0xEDB88320) & 0xFFFFFFFF
          : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// 测试侧 PNG 解析结果。
class _Png {
  _Png({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.raw,
    required this.types,
  });

  final int width;
  final int height;
  final int bitDepth;
  final int colorType;

  /// 解压后的扫描线（每行以过滤器字节开头）。
  final Uint8List raw;
  final List<String> types;
}

/// 解析并**逐分块校验 CRC**；结构不合规直接 fail。
_Png _parsePng(Uint8List png) {
  expect(png.length > 8, isTrue, reason: 'PNG 长度不足');
  expect(png.sublist(0, 8), kPngSignature, reason: 'PNG 签名不符');

  int offset = 8;
  final List<String> types = <String>[];
  Uint8List? ihdr;
  final BytesBuilder idat = BytesBuilder(copy: false);
  while (offset < png.length) {
    final int len = _u32(png, offset);
    final String type = ascii.decode(png.sublist(offset + 4, offset + 8));
    final Uint8List data = png.sublist(offset + 8, offset + 8 + len);
    final int crc = _u32(png, offset + 8 + len);
    expect(
      crc,
      _crc32Ref(png.sublist(offset + 4, offset + 8 + len)),
      reason: '$type 分块 CRC 不符',
    );
    types.add(type);
    if (type == 'IHDR') ihdr = data;
    if (type == 'IDAT') idat.add(data);
    offset += 12 + len;
  }
  expect(offset, png.length, reason: '分块长度累加应正好等于文件长度（无尾随垃圾）');
  final Uint8List? header = ihdr;
  expect(header, isNotNull, reason: '缺 IHDR');
  expect(types.last, 'IEND', reason: '最后一个分块必须是 IEND');
  return _Png(
    width: _u32(header!, 0),
    height: _u32(header, 4),
    bitDepth: header[8],
    colorType: header[9],
    raw: Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes())),
    types: types,
  );
}

void main() {
  group('测试侧 PNG 解析器自检（防「解析器与实现同错」）', () {
    test('能校验既有参考图 kTinyPng 的分块结构与 CRC', () {
      final _Png png = _parsePng(kTinyPng);
      expect(png.types, <String>['IHDR', 'IDAT', 'IEND']);
      expect(png.width, greaterThan(0));
      expect(png.height, greaterThan(0));
      expect(png.raw, isNotEmpty);
    });
  });

  group('encodeBgraToPng', () {
    test('1×1 纯色：IHDR 8bit / 色彩类型 6、CRC 全过、B↔R 已换位', () {
      // BGRA: B=0x11 G=0x22 R=0x33 A=0xFF
      final Uint8List bgra = Uint8List.fromList(<int>[0x11, 0x22, 0x33, 0xFF]);
      final Uint8List png = encodeBgraToPng(bgra, width: 1, height: 1);
      final _Png parsed = _parsePng(png);
      expect(parsed.width, 1);
      expect(parsed.height, 1);
      expect(parsed.bitDepth, 8);
      expect(parsed.colorType, 6, reason: 'truecolor + alpha');
      // 扫描线 = 过滤器字节 0(None) + RGBA（R 取原 B 位、B 取原 R 位）
      expect(parsed.raw, <int>[0x00, 0x33, 0x22, 0x11, 0xFF]);
    });

    test('2×2 多色：逐像素往返一致，且每行过滤器字节为 0', () {
      final Uint8List bgra = solidBgra(width: 2, height: 2, seed: 5);
      final Uint8List png = encodeBgraToPng(bgra, width: 2, height: 2);
      final _Png parsed = _parsePng(png);
      const int rowStride = 1 + 2 * 4;
      expect(parsed.raw.length, 2 * rowStride);
      for (int y = 0; y < 2; y++) {
        expect(parsed.raw[y * rowStride], 0, reason: '第 $y 行过滤器应为 None');
        for (int x = 0; x < 2; x++) {
          final int src = (y * 2 + x) * 4;
          final int dst = y * rowStride + 1 + x * 4;
          expect(parsed.raw[dst], bgra[src + 2], reason: 'R 通道换位');
          expect(parsed.raw[dst + 1], bgra[src + 1], reason: 'G 通道');
          expect(parsed.raw[dst + 2], bgra[src], reason: 'B 通道换位');
          expect(parsed.raw[dst + 3], bgra[src + 3], reason: 'A 通道');
        }
      }
    });

    test('尾部多余字节被忽略（便于直接吃原生缓冲区）', () {
      final Uint8List bgra = Uint8List(4 * 4 + 12)
        ..setAll(0, solidBgra(width: 2, height: 2, seed: 9));
      final Uint8List png = encodeBgraToPng(bgra, width: 2, height: 2);
      expect(_parsePng(png).raw.length, 2 * (1 + 2 * 4));
    });

    test('参数校验：宽高非正 / 字节不足 → ArgumentError', () {
      expect(
        () => encodeBgraToPng(Uint8List(4), width: 0, height: 1),
        throwsArgumentError,
      );
      expect(
        () => encodeBgraToPng(Uint8List(4), width: 1, height: 0),
        throwsArgumentError,
      );
      expect(
        () => encodeBgraToPng(Uint8List(3), width: 1, height: 1),
        throwsArgumentError,
      );
    });
  });
}
