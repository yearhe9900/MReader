// `lib/meta/meta_source.dart` 单测：魔数嗅探（`META-05`）+ 统一兜底（`META-01`）。
//
// 期望值取自 `.scratch/probe_meta.dart` 实测。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/meta/meta_source.dart';
import 'package:mreader/model/book_meta.dart';

void main() {
  group('sniffCoverFormat（魔数嗅探，不看扩展名，META-05）', () {
    test('识别 JPEG / PNG / WebP / GIF / BMP', () {
      expect(
        sniffCoverFormat(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0])),
        CoverFormat.jpeg,
      );
      expect(
        sniffCoverFormat(Uint8List.fromList(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
        CoverFormat.png,
      );
      expect(
        sniffCoverFormat(Uint8List.fromList(<int>[
          0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
          0x57, 0x45, 0x42, 0x50,
        ])),
        CoverFormat.webp,
      );
      expect(
        sniffCoverFormat(Uint8List.fromList(<int>[0x47, 0x49, 0x46, 0x38, 0x39])),
        CoverFormat.gif,
      );
      expect(
        sniffCoverFormat(Uint8List.fromList(<int>[0x42, 0x4D, 0x00, 0x00])),
        CoverFormat.bmp,
      );
    });

    test('空字节 / 短字节 / 非图片 -> unknown', () {
      expect(sniffCoverFormat(Uint8List(0)), CoverFormat.unknown);
      expect(
        sniffCoverFormat(Uint8List.fromList(<int>[0xFF, 0xD8])),
        CoverFormat.unknown,
        reason: '不足 3 字节不能判为 JPEG',
      );
      expect(
        sniffCoverFormat(Uint8List.fromList(<int>[0x00, 0x01, 0x02, 0x03])),
        CoverFormat.unknown,
      );
    });
  });

  group('统一兜底（META-01）', () {
    test('fallbackAuthor：空 / 纯空白 -> 未知作者', () {
      expect(fallbackAuthor(''), '未知作者');
      expect(fallbackAuthor('   '), '未知作者');
      expect(fallbackAuthor(' 刘慈欣 '), '刘慈欣');
    });

    test('fallbackTitle：raw -> fallback -> 未命名书籍', () {
      expect(fallbackTitle(' 三体 ', 'x'), '三体');
      expect(fallbackTitle('', '红楼梦'), '红楼梦');
      expect(fallbackTitle('', '  '), '未命名书籍');
      expect(fallbackTitle('', ''), '未命名书籍');
    });
  });

  group('fileStem（文件名去目录/扩展名）', () {
    test('常见形态', () {
      expect(fileStem('红楼梦.txt'), '红楼梦');
      expect(fileStem('a.b.txt'), 'a.b');
      expect(fileStem('noext'), 'noext');
      expect(fileStem('.txt'), '');
      expect(fileStem(r'D:\books\x.txt'), 'x');
      expect(fileStem('/a/b/c.epub'), 'c');
    });
  });
}
