// 图片真尺寸（T05-b）单测：五格式文件头解析 + 与渲染同式的宽度适配 +
// 章内 src 提取与尺寸补入。
// 期望值一律硬编码字面量；字节夹具手工拼装（只拼到 SOF/IHDR 即可——
// 解析只读文件头，不解码像素，这是 #4 纯 test 环境可用的前提）。
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/image_dimensions.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  Uint8List bytes(List<int> data) => Uint8List.fromList(data);

  group('parseImageSize：五格式头解析', () {
    test('PNG：签名 + IHDR 宽高（BE）', () {
      final Uint8List png = bytes(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
        0, 0, 0, 13, // IHDR 长度
        0x49, 0x48, 0x44, 0x52, // 'IHDR'
        0, 0, 1, 44, // 宽 300
        0, 0, 0, 150, // 高 150
        0, 0, 0, 0, // 余量
      ]);

      expect(parseImageSize(png), const Size(300, 150));
    });

    test('PNG 首块非 IHDR（损坏）→ null', () {
      final Uint8List broken = bytes(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 13,
        0x49, 0x44, 0x41, 0x54, // 'IDAT'
        0, 0, 1, 44,
        0, 0, 0, 150,
      ]);

      expect(parseImageSize(broken), isNull);
    });

    test('JPEG：跳段找 SOF0（高在前、宽在后）、容忍 FF 填充', () {
      final Uint8List jpeg = bytes(<int>[
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0 段（长度 4）
        0xFF, 0xC0, // SOF0
        0x00, 0x11, // 段长度
        0x08, // 精度
        0x00, 0x96, // 高 150
        0x01, 0x2C, // 宽 300
        0x00,
      ]);
      expect(parseImageSize(jpeg), const Size(300, 150));

      // FF 填充：连续多个 FF 后才是段标记。
      final Uint8List padded = bytes(<int>[
        0xFF, 0xD8,
        0xFF, 0xFF, 0xC0, 0x00, 0x11, 0x08,
        0x00, 0x96, // 高 150
        0x01, 0x2C, // 宽 300
        0x00,
      ]);
      expect(parseImageSize(padded), const Size(300, 150));
    });

    test('JPEG：SOS 前无 SOF → null', () {
      final Uint8List scan = bytes(<int>[
        0xFF, 0xD8,
        0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00, // 直接到 SOS
      ]);

      expect(parseImageSize(scan), isNull);
    });

    test('GIF：逻辑屏幕宽高（LE）', () {
      // 夹具补足 12 字节过 parseImageSize 的最短门槛（头 10 字节 + 2 余量）。
      final Uint8List gif =
          bytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 44, 1, 150, 0, 0, 0]);

      expect(parseImageSize(gif), const Size(300, 150));
    });

    test('BMP：INFOHEADER 负高（自顶向下）取绝对值', () {
      final Uint8List bmp = bytes(<int>[
        0x42, 0x4D, // 'BM'
        0, 0, 0, 0, // 文件大小
        0, 0, 0, 0, // 保留
        0, 0, 0, 0, // 像素偏移
        40, 0, 0, 0, // DIB = 40
        44, 1, 0, 0, // 宽 300
        0x6A, 0xFF, 0xFF, 0xFF, // 高 −150（32 位补码 LE）
        0, 0,
      ]);

      expect(parseImageSize(bmp), const Size(300, 150));
    });

    test('BMP：COREHEADER（DIB=12，宽高各 2 字节）', () {
      final Uint8List core = bytes(<int>[
        0x42, 0x4D,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        12, 0, 0, 0, // DIB = 12
        44, 1, // 宽 300
        150, 0, // 高 150
        0, 0, 0, 0, 0, 0,
      ]);

      expect(parseImageSize(core), const Size(300, 150));
    });

    test('WebP：VP8 / VP8L / VP8X 三种载荷', () {
      // VP8（有损）：帧标签(3) + 同步码 9D 01 2A + 宽高各 2（LE 14 位）。
      final Uint8List vp8 = bytes(<int>[
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, // RIFF + size
        0x57, 0x45, 0x42, 0x50, // 'WEBP'
        0x56, 0x50, 0x38, 0x20, // 'VP8 '
        0, 0, 0, 0, // 块长
        0, 0, 0, // 帧标签
        0x9D, 0x01, 0x2A, // 同步码
        44, 1, // 宽 300
        150, 0, // 高 150
      ]);
      expect(parseImageSize(vp8), const Size(300, 150));

      // VP8L（无损）：0x2F + 宽−1/高−1 各 14 位小端位流。
      //   299 = 0b01_0010_1011 → 43 | (1<<8)；149 = 0b10_0101_01 → 低2位进 b22 高位。
      final Uint8List vp8l = bytes(<int>[
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x4C, // 'VP8L'
        0, 0, 0, 0,
        0x2F, // 签名
        43, 65, 37, 0, // 宽−1=299、高−1=149 位流
        0,
      ]);
      expect(parseImageSize(vp8l), const Size(300, 150));

      // VP8X（扩展）：画布宽−1 / 高−1 各 3 字节 LE。
      final Uint8List vp8x = bytes(<int>[
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x58, // 'VP8X'
        0, 0, 0, 0,
        0, 0, 0, 0, // 标志 + 保留
        43, 1, 0, // 宽−1 = 299
        149, 0, 0, // 高−1 = 149
      ]);
      expect(parseImageSize(vp8x), const Size(300, 150));
    });

    test('未知签名 / 过短字节 → null（不抛）', () {
      expect(parseImageSize(bytes(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])),
          isNull);
      expect(parseImageSize(bytes(<int>[0x42, 0x4D, 0, 0, 0, 0])), isNull);
      expect(parseImageSize(bytes(<int>[0xFF, 0xD8, 0xFF])), isNull); // 无段
      expect(parseImageSize(Uint8List(4)), isNull);
    });
  });

  group('fitWithinWidth：与渲染 box.dart:317 width 分支同式', () {
    test('宽超上限：等比缩（高按比例，非上限裁剪）', () {
      expect(fitWithinWidth(const Size(300, 150), 180), const Size(180, 90));
      expect(fitWithinWidth(const Size(400, 80), 180), const Size(180, 36));
    });

    test('宽不超 / 恰等上限：原样返回', () {
      expect(fitWithinWidth(const Size(60, 30), 180), const Size(60, 30));
      expect(fitWithinWidth(const Size(180, 100), 180), const Size(180, 100));
    });

    test('空尺寸：原样返回（渲染侧 _wh 已挡，此处双保险）', () {
      expect(fitWithinWidth(Size.zero, 180), Size.zero);
    });
  });

  group('imageSrcsOf：章内 IMG 提取（按序去重）', () {
    test('跨段收集、保序、去重；非 IMG 标记不算', () {
      final List<String> srcs = imageSrcsOf(<String>[
        'a\x00IMG:1.png\x00b',
        'c\x00IMG:2.png\x00d\x00IMG:1.png\x00e\x00A:h\x00f',
      ]);

      expect(srcs, <String>['1.png', '2.png']);
    });

    test('无图 / 空章 → 空表', () {
      expect(imageSrcsOf(<String>['纯文本', 'a\x00A:h\x00b']), isEmpty);
      expect(imageSrcsOf(<String>[]), isEmpty);
    });
  });

  group('ensureImageSize：异步补入', () {
    test('命中路径：写入新尺寸返 true，已有条目返 false 不再 resolve', () async {
      final Map<String, Size> sizes = <String, Size>{};
      int resolved = 0;
      Future<Uint8List?> resolve(String _) async {
        resolved++;
        return bytes(<int>[
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
          0, 0, 0, 13,
          0x49, 0x48, 0x44, 0x52,
          0, 0, 1, 44,
          0, 0, 0, 150,
        ]);
      }

      await expectLater(ensureImageSize('a.png', sizes, resolve),
          completion(true));
      await expectLater(ensureImageSize('a.png', sizes, resolve),
          completion(false));
      expect(resolved, 1);
      expect(sizes, <String, Size>{'a.png': const Size(300, 150)});
    });

    test('未加载（resolve null）/ 损坏字节 → false 不写', () async {
      final Map<String, Size> sizes = <String, Size>{};

      await expectLater(ensureImageSize('gone.png', sizes, (_) async => null),
          completion(false));
      await expectLater(
          ensureImageSize('bad.png', sizes, (_) async => bytes([1, 2, 3])),
          completion(false));
      expect(sizes, isEmpty);
    });
  });
}
