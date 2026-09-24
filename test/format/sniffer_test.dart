// `FMT-06`（M2b-T03）格式嗅探与魔数纠偏的验收测试。
//
// 夹具真实性（kTinyPng 教训：夹具必须按真实样本结构复刻，不许「号称」）：
// MOBI 系判据来自 tmp_book 真实《牧神记》.mobi / .azw3 **双样本实测**——两文件
// 偏移 60..68 均为 `42 4f 4f 4b 4d 4f 42 49`（PalmDB type "BOOK" + creator
// "MOBI"）；AZW3 头 8 字节为可打印 ASCII（PDB name 实测 `epubor.c`），夹具照
// 此复刻（可打印 name + NUL 填充 + BOOKMOBI tag），顺带覆盖「头可打印 ≠ 纯文
// 本」陷阱（AZW3 改名 .txt 不得落 txt）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/sniffer.dart';

/// PalmDB `BOOKMOBI` 最小复刻（真实 AZW3 形态：可打印 name + NUL 填充）。
Uint8List _mobiFixture() {
  final Uint8List bytes = Uint8List(80);
  // PDB name 字段（偏移 0..32）：可打印 ASCII + NUL 填充（AZW3 实测 `epubor.c`）。
  const String name = 'epubor.c';
  for (int i = 0; i < name.length; i++) {
    bytes[i] = name.codeUnitAt(i);
  }
  // type + creator（偏移 60..68）= ASCII "BOOKMOBI"。
  const String tag = 'BOOKMOBI';
  for (int i = 0; i < tag.length; i++) {
    bytes[60 + i] = tag.codeUnitAt(i);
  }
  return bytes;
}

/// 纯文本夹具（真实编码：UTF-8 字节）。
Uint8List _text(String s) => Uint8List.fromList(utf8.encode(s));

/// PK 假 zip 夹具（与既有回归条同构）。
Uint8List _fakeZip() => Uint8List.fromList(<int>[
      0x50, 0x4B, 0x03, 0x04, // PK local file header
      ...List<int>.filled(100, 0x00),
    ]);

void main() {
  group('hasMobiMagic（PalmDB BOOKMOBI 判据）', () {
    test('偏移 60..68 = BOOKMOBI → true（真实 MOBI/AZW3 双样本判据）', () {
      expect(hasMobiMagic(_mobiFixture()), isTrue);
    });

    test('不足 68 字节的截断文件 → false（不误判）', () {
      expect(hasMobiMagic(_mobiFixture().sublist(0, 64)), isFalse);
    });

    test('偏移 60 非 BOOKMOBI → false', () {
      final Uint8List bytes = _mobiFixture();
      bytes[60] = 0x58; // 破坏 tag 首字节
      expect(hasMobiMagic(bytes), isFalse);
    });

    test('纯文本 → false', () {
      expect(hasMobiMagic(_text('========\n第1章 归乡\n正文。')), isFalse);
    });
  });

  group('sniffFormat 魔数纠偏（FMT-06）', () {
    test('验收①：MOBI 系夹具改名 .txt → FormatKind.mobi（识别为 MOBI 系）', () {
      expect(
        sniffFormat(fileName: '牧神记.txt', bytes: _mobiFixture()),
        FormatKind.mobi,
      );
    });

    test('验收①：改名 .azw3/.mobi/.epub/.cbz/.cbr 均 → mobi（魔数压过后缀）', () {
      for (final String name in <String>[
        '牧神记.azw3',
        '牧神记.mobi',
        '牧神记.epub',
        '牧神记.cbz',
        '牧神记.cbr',
      ]) {
        expect(
          sniffFormat(fileName: name, bytes: _mobiFixture()),
          FormatKind.mobi,
          reason: '$name 应被魔数纠偏为 MOBI 系',
        );
      }
    });

    test('验收②：纯文本改名 .epub → 仍 epub（FMT-06 ②「明确报错」出口）', () {
      // FMT-06 ② 双出口取舍（M2b-T03）：「识别为 TXT」**或**「明确报错」。
      // 取后者——EPUB 解析器对非 zip 字节给 notZip 可读报错（诚实报错优先于
      // 静默改判），既有锁 dart_epub_source_test「非 zip 字节 + .epub → notZip
      // 文案」保持不动。若改走「识别为 TXT」出口，须同步推翻该测试。
      expect(
        sniffFormat(
          fileName: '伪装.epub',
          bytes: _text('========\n第1章 归乡\n正文。'),
        ),
        FormatKind.epub,
      );
    });

    test('回归：非 zip 二进制改名 .epub → epub（既有锁：交 EPUB 解析器给可读错）', () {
      expect(
        sniffFormat(
          fileName: 'x.epub',
          bytes: Uint8List.fromList(
            <int>[0x00, 0x01, 0x02, 0x03, 0x00, 0x01, 0x02, 0x03],
          ),
        ),
        FormatKind.epub,
      );
    });

    test('回归：PK 假 zip 改名 .txt → unsupported（既有锁）', () {
      expect(
        sniffFormat(fileName: 'x.txt', bytes: _fakeZip()),
        FormatKind.unsupported,
      );
    });

    test('回归：PK 假 zip 改名 .zip → unsupported（既有锁）', () {
      expect(
        sniffFormat(fileName: 'book.zip', bytes: _fakeZip()),
        FormatKind.unsupported,
      );
    });

    test('回归：纯文本 .txt / 无扩展名 → txt', () {
      expect(
        sniffFormat(fileName: 'x.txt', bytes: _text('纯文本。')),
        FormatKind.txt,
      );
      expect(
        sniffFormat(fileName: 'README', bytes: _text('纯文本。')),
        FormatKind.txt,
      );
    });

    test('边界：MOBI 系夹具 + 无扩展名 → mobi（不依赖后缀）', () {
      expect(
        sniffFormat(fileName: 'noext', bytes: _mobiFixture()),
        FormatKind.mobi,
      );
    });
  });
}
