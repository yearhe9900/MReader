// MOBI/AZW3 源单测（`FormatKind.mobi`，2026-10-20 接入）。
//
// 夹具在测试内**合成**（不依赖 `tmp_book/` 的大文件）：手搭 PalmDB + MOBI 头 +
// 文本记录，覆盖「未压缩」「标志说 PalmDOC 但实际未压缩」「真 PalmDOC 压缩流」
// 「HUFF/CDIC 诚实降级」四条口径。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/error_messages.dart';
import 'package:mreader/format/mobi/mobi_palmdoc.dart';
import 'package:mreader/format/mobi_source.dart';

/// 合成一个 MOBI 文件：记录 0 = PalmDOC 头 + MOBI 头，其后为文本记录。
Uint8List buildMobi({
  required List<String> textRecords,
  int compression = 0,
  int recordSize = 4096,
  int? textLength,
  int encryption = 0,
  int textEncoding = 65001,
  Map<int, String> exth = const <int, String>{},
}) {
  final List<Uint8List> records = <Uint8List>[
    Uint8List(0), // 占位，稍后填记录 0
    for (final String s in textRecords) Uint8List.fromList(utf8.encode(s)),
  ];
  final int recordCount = records.length;
  final int headerLen = 78 + recordCount * 8;
  final int exthLen = exth.isEmpty
      ? 0
      : 12 +
          exth.values
              .fold<int>(0, (int a, String v) => a + 8 + utf8.encode(v).length);
  final int mobiHeaderLen = 232;
  final int record0Len = 16 + mobiHeaderLen + exthLen;

  int cursor = headerLen;
  final List<int> offsets = <int>[];
  for (int i = 0; i < recordCount; i++) {
    offsets.add(i == 0 ? cursor : cursor);
    cursor += i == 0 ? record0Len : records[i].length;
  }

  final int textBytesLen =
      textRecords.fold<int>(0, (int a, String s) => a + utf8.encode(s).length);
  final Uint8List file = Uint8List(headerLen + record0Len + textBytesLen);
  final ByteData d = ByteData.sublistView(file);

  // PDB 头
  for (int i = 0; i < 32; i++) {
    file[i] = 0x41;
  }
  const List<int> tag = <int>[
    0x42, 0x4F, 0x4F, 0x4B, 0x4D, 0x4F, 0x42, 0x49, // BOOKMOBI
  ];
  file.setRange(60, 68, tag);
  d.setUint16(76, recordCount, Endian.big);
  for (int i = 0; i < recordCount; i++) {
    d.setUint32(78 + i * 8, offsets[i], Endian.big);
  }

  final int r0 = offsets[0];
  final int total = textRecords.fold<int>(
    0,
    (int a, String s) => a + utf8.encode(s).length,
  );
  // PalmDOC 头
  d.setUint16(r0, compression, Endian.big);
  d.setUint32(r0 + 4, textLength ?? total, Endian.big);
  d.setUint16(r0 + 8, textRecords.length, Endian.big);
  d.setUint16(r0 + 10, recordSize, Endian.big);
  d.setUint16(r0 + 12, encryption, Endian.big);

  // MOBI 头
  final int ms = r0 + 16;
  file.setRange(ms, ms + 4, 'MOBI'.codeUnits);
  d.setUint32(ms + 4, mobiHeaderLen, Endian.big); // headerLength（EXTH 紧随其后）
  d.setUint32(ms + 8, 2, Endian.big); // mobiType
  d.setUint32(ms + 12, textEncoding, Endian.big);
  d.setUint32(ms + 0x44, 0xffffffff, Endian.big); // firstImageIndex = 无
  d.setUint32(ms + 0x58, exth.isEmpty ? 0 : 0x40, Endian.big);

  if (exth.isNotEmpty) {
    final int e = ms + mobiHeaderLen;
    file.setRange(e, e + 4, 'EXTH'.codeUnits);
    d.setUint32(e + 4, 12 + exth.length * 8, Endian.big);
    d.setUint32(e + 8, exth.length, Endian.big);
    int p = e + 12;
    for (final MapEntry<int, String> entry in exth.entries) {
      final List<int> value = utf8.encode(entry.value);
      d.setUint32(p, entry.key, Endian.big);
      d.setUint32(p + 4, 8 + value.length, Endian.big);
      file.setRange(p + 8, p + 8 + value.length, value);
      p += 8 + value.length;
    }
  }

  // 文本记录
  int w = r0 + record0Len;
  for (int i = 1; i < recordCount; i++) {
    file.setRange(w, w + records[i].length, records[i]);
    w += records[i].length;
  }
  return file;
}

void main() {
  group('PalmDOC 解压器（spec 手算夹具）', () {
    test('0xC0 组合对：距离 3 / 长度 6 ⇒ "abcabcabc"', () {
      // 'a' 'b' 'c' 字面量，随后 pair=0x13 → 距离(0x13>>3)+1=3、长度(0x13&7)+3=6。
      final Uint8List out = decompressPalmDoc(
        Uint8List.fromList(<int>[0x61, 0x62, 0x63, 0xC0, 0x13]),
      );
      expect(utf8.decode(out), 'abcabcabc');
    });

    test('字面量直通 + 0x00 转义', () {
      final Uint8List out = decompressPalmDoc(
        Uint8List.fromList(<int>[0x41, 0x00, 0x42]),
      );
      expect(out, <int>[0x41, 0x00, 0x42]);
    });

    test('非法回溯距离不抛异常（脏书容错）', () {
      final Uint8List out = decompressPalmDoc(
        Uint8List.fromList(<int>[0x41, 0xC0, 0xF8]),
      );
      expect(out.isNotEmpty, isTrue);
    });
  });

  group('MobiSource', () {
    test('未压缩 MOBI：元数据 + 分章 + 正文', () async {
      final String html =
          '<html><body><h1>第一章</h1><p>Hello 正文一</p><h1>第二章</h1>'
          '<p>正文二</p></body></html>';
      final Uint8List bytes = buildMobi(
        textRecords: <String>[html],
        exth: <int, String>{100: '作者甲', 503: '书名乙'},
      );
      final MobiSource source = MobiSource(fileName: 'x.mobi', bytes: bytes);

      final meta = await source.load();
      expect(meta.title, '书名乙');
      expect(meta.author, '作者甲');

      final chapters = await source.chapters();
      expect(chapters.length, 2);
      expect(chapters[0].href, 'mobi:0');
      expect(chapters[1].title, contains('第二章'));

      final first = await source.content(0);
      expect(first.paragraphList.join(), contains('正文一'));
      expect(first.paragraphList.join(), isNot(contains('正文二')));
    });

    test('压缩标志为 PalmDOC 但实际未压缩（国产书口径）：按原始取，不误解压',
        () async {
      final String html =
          '<html><body><h2>目录</h2><p>中文正文内容</p></body></html>';
      final Uint8List bytes = buildMobi(textRecords: <String>[html], compression: 1);
      final MobiContainer container = parseMobi(bytes);
      final String text =
          utf8.decode(container.textBytes(), allowMalformed: true);
      expect(text, contains('中文正文内容'));
    });

    test('HUFF/CDIC（compression=2）：抛 mobiHuffCdicUnsupported（诚实降级）', () {
      final Uint8List bytes =
          buildMobi(textRecords: <String>['<html><body><p>x</p></body></html>'], compression: 2);
      expect(
        () => parseMobi(bytes).textBytes(),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.mobiHuffCdicUnsupported,
        )),
      );
    });

    test('截断文件：抛格式异常而非崩溃', () {
      expect(
        () => parseMobi(Uint8List(80)),
        throwsA(isA<MReaderFormatException>()),
      );
    });

    test('无标题无 pagebreak：整本单章', () async {
      final Uint8List bytes = buildMobi(
        textRecords: <String>['<html><body><p>只有一段</p></body></html>'],
      );
      final MobiSource source = MobiSource(fileName: 'y.mobi', bytes: bytes);
      final chapters = await source.chapters();
      expect(chapters.length, 1);
      expect((await source.content(0)).paragraphList.join(), contains('只有一段'));
    });

    test('章节权重走廉价口径（不解码正文）', () async {
      final Uint8List bytes = buildMobi(
        textRecords: <String>[
          '<html><body><h1>甲</h1><p>aaa</p><h1>乙</h1><p>bbb</p></body></html>',
        ],
      );
      final MobiSource source = MobiSource(fileName: 'z.mobi', bytes: bytes);
      final List<int>? weights = await source.chapterWeightEstimates();
      expect(weights, isNotNull);
      expect(weights!.length, 2);
      expect(weights.every((int w) => w > 0), isTrue);
    });
  });

  group('BookRegistry 分发', () {
    test('MOBI 走 MobiSource（不再抛 mobiUnsupported）', () async {
      final Uint8List bytes = buildMobi(
        textRecords: <String>['<html><body><p>ok</p></body></html>'],
      );
      final source = await openBook(fileName: 'a.mobi', bytes: bytes);
      expect(source.implId, 'dart-mobi');
      expect(await source.chapters(), isNotEmpty);
      await source.dispose();
    });
  });
}
