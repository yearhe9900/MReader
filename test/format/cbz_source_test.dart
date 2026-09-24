// `lib/format/cbz_source.dart` 单测（`FMT-02` / `META-11`，M2b-T02）。
//
// ⚠️ 预期值全部**人工推演**（防假绿）：
// · 页序 = 自然序（`pages/1.png` → `pages/2.jpg` → `pages/10.jpg`，
//   字典序会把 `10.jpg` 排到 `2.jpg` 前——这正是 META-11 ② 要防的）；
// · 封面 = 自然序**首页**的原始字节 + 魔数嗅探格式（META-11 ①②）；
// · `href` = zip 条目路径本身（稳定身份，RD-04）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/cbz_source.dart';
import 'package:mreader/format/image_pages.dart';
import 'package:mreader/format/natural_sort.dart';

import 'epub_builder.dart';

/// 伪 PNG 字节：真实 PNG 魔数 + 可辨识标签尾（各页字节可区分；嗅探只看头部）。
Uint8List _pngTagged(String tag) => Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ...utf8.encode(tag),
    ]);

/// 一本含脏条目的最小 CBZ：3 图片页（乱序放入）+ macOS 垃圾 + 隐藏文件 + 非图片。
Uint8List _cbzSample() => zipEntries(<EpubEntry>[
      EpubEntry('pages/10.jpg', _pngTagged('10')),
      EpubEntry('__MACOSX/._1.png', _pngTagged('junk')),
      EpubEntry('pages/2.jpg', _pngTagged('2')),
      EpubEntry('.DS_Store', _pngTagged('junk2')),
      EpubEntry('ComicInfo.xml', utf8.encode('<ComicInfo/>')),
      EpubEntry('pages/1.png', _pngTagged('1')),
      EpubEntry('info.txt', utf8.encode('not a page')),
    ]);

void main() {
  group('compareNatural 自然序（META-11 ②）', () {
    test('数字段按数值：2.jpg 在 10.jpg 前', () {
      expect(compareNatural('2.jpg', '10.jpg'), lessThan(0));
      expect(compareNatural('10.jpg', '2.jpg'), greaterThan(0));
    });

    test('数值相等：前导零少者在前（7 在 07 前）', () {
      expect(compareNatural('7', '07'), lessThan(0));
    });

    test('混合串内数字段同样生效（a2b < a10b）', () {
      expect(compareNatural('a2b', 'a10b'), lessThan(0));
    });

    test('大小写不敏感比较、原始串兜底保证全序', () {
      expect(compareNatural('page.jpg', 'PAGE.jpg'), greaterThan(0),
          reason: '小写全等后回退原始串 compareTo：page > PAGE');
    });

    test('前缀短者在前（a < a1）', () {
      expect(compareNatural('a', 'a1'), lessThan(0));
    });
  });

  group('isImagePageName', () {
    test('图片扩展名白名单', () {
      expect(isImagePageName('a/b.png'), isTrue);
      expect(isImagePageName('x.JPEG'.toLowerCase()), isTrue);
      expect(isImagePageName('x.txt'), isFalse);
      expect(isImagePageName('x'), isFalse);
      expect(isImagePageName('x.'), isFalse);
    });
  });

  group('CbzSource', () {
    test('页表 = 自然序图片页；脏条目全部排除（FMT-02 ①）', () async {
      final CbzSource source =
          CbzSource(fileName: '测试漫画.cbz', bytes: _cbzSample());
      final List<Chapter> chapters = await source.chapters();
      // 人工推演：1.png(1) < 2.jpg(2) < 10.jpg(10)；__MACOSX/.DS_Store/info.txt/
      // ComicInfo.xml 不是图片页 → 不进页表。
      expect(
        chapters.map((Chapter c) => c.href).toList(),
        <String>['pages/1.png', 'pages/2.jpg', 'pages/10.jpg'],
      );
      expect(
        chapters.map((Chapter c) => c.title).toList(),
        <String>['第 1 页', '第 2 页', '第 3 页'],
        reason: '每页一章：章名 = 自然序页号',
      );
      expect(chapters.map((Chapter c) => c.href).toSet().length, 3,
          reason: 'href 是稳定身份（RD-04），必须唯一');
      await source.dispose();
    });

    test('content(i) = 单元素 imagePages（与段落互斥）', () async {
      final CbzSource source =
          CbzSource(fileName: 'a.cbz', bytes: _cbzSample());
      final ChapterContent content = await source.content(1);
      expect(content.paragraphs, isNull, reason: '图片页模式无段落（互斥构造器）');
      expect(content.imagePages, <String>['pages/2.jpg']);
      expect((await source.content(-1)).isEmpty, isTrue, reason: '越界不抛异常');
      expect((await source.content(3)).isEmpty, isTrue);
      await source.dispose();
    });

    test('readResource 按条目名取原始字节；未知条目返回 null', () async {
      final CbzSource source =
          CbzSource(fileName: 'a.cbz', bytes: _cbzSample());
      expect(await source.readResource('pages/10.jpg'), _pngTagged('10'));
      expect(await source.readResource('pages/99.jpg'), isNull);
      await source.dispose();
    });

    test('封面 = 自然序首页图（META-11 ①②），格式按魔数嗅探（META-05）', () async {
      final CbzSource source =
          CbzSource(fileName: 'a.cbz', bytes: _cbzSample());
      final BookMeta meta = await source.load();
      expect(meta.cover, isA<PendingCover>());
      final PendingCover cover = meta.cover as PendingCover;
      expect(cover.bytes, _pngTagged('1'),
          reason: '首页 = 自然序第一张 pages/1.png（不是条目序第一张 10.jpg）');
      expect(cover.format, CoverFormat.png);
      expect(meta.coverOrigin, MetaOrigin.metadata);
      await source.dispose();
    });

    test('书名 / 作者走 META-04 文件名规则链（与 TXT 同源）', () async {
      final CbzSource source =
          CbzSource(fileName: '《测试漫画》.cbz', bytes: _cbzSample());
      final BookMeta meta = await source.load();
      expect(meta.title, '测试漫画');
      expect(meta.titleOrigin, MetaOrigin.filename);
      expect(meta.author, isNotEmpty, reason: 'META-01：作者缺失兜底非空');
      await source.dispose();
    });

    test('capabilities：图片页格式（不重排 / 不可搜 / 无字数）', () async {
      final CbzSource source =
          CbzSource(fileName: 'a.cbz', bytes: _cbzSample());
      final SourceCapabilities caps = source.capabilities();
      expect(caps.hasImages, isTrue);
      expect(caps.reflowable, isFalse);
      expect(caps.searchable, isFalse);
      expect(caps.charCountSupported, isFalse);
      expect(await source.search('x', cancel: CancelToken()).toList(), isEmpty);
      expect(await source.totalCharCount(), isNull);
      await source.dispose();
    });

    test('无图片页 → noImagePages；坏 zip → corruptFile；空字节 → emptyFile', () async {
      final CbzSource noPages = CbzSource(
        fileName: 'a.cbz',
        bytes: zipEntries(<EpubEntry>[textEntry('info.txt', 'x')]),
      );
      await expectLater(
        noPages.load(),
        throwsA(isA<MReaderFormatException>().having(
            (MReaderFormatException e) => e.code, 'code', FormatErrorCode.noImagePages)),
      );
      await noPages.dispose();

      final CbzSource badZip = CbzSource(
        fileName: 'a.cbz',
        bytes: Uint8List.fromList(utf8.encode('this is not a zip')),
      );
      await expectLater(
        badZip.load(),
        throwsA(isA<MReaderFormatException>().having(
            (MReaderFormatException e) => e.code, 'code', FormatErrorCode.corruptFile)),
      );
      await badZip.dispose();

      final CbzSource empty = CbzSource(fileName: 'a.cbz', bytes: Uint8List(0));
      await expectLater(
        empty.load(),
        throwsA(isA<MReaderFormatException>().having(
            (MReaderFormatException e) => e.code, 'code', FormatErrorCode.emptyFile)),
      );
      await empty.dispose();
    });

    test('dispose 幂等；dispose 后优雅空（不抛异常）', () async {
      final CbzSource source =
          CbzSource(fileName: 'a.cbz', bytes: _cbzSample());
      await source.chapters();
      await source.dispose();
      await source.dispose();
      expect(source.isDisposed, isTrue);
      expect(await source.chapters(), isEmpty);
      expect((await source.content(0)).isEmpty, isTrue);
      expect(await source.readResource('pages/1.png'), isNull);
      final BookMeta meta = await source.load();
      expect(meta.titleOrigin, MetaOrigin.none);
    });
  });

  group('sniffFormat / openBook 分发（M2b-T02 接线）', () {
    test('.cbz 以扩展名为主（坏包也交给 CbzSource 给可读提示）', () {
      expect(
        sniffFormat(fileName: 'a.cbz', bytes: Uint8List.fromList(<int>[1, 2])),
        FormatKind.cbz,
      );
    });

    test('.cbr 识别为 cbr（Q5：识别 + 明确提示）', () {
      expect(
        sniffFormat(fileName: 'a.cbr', bytes: Uint8List.fromList(<int>[1, 2])),
        FormatKind.cbr,
      );
    });

    test('回归：PK 魔数的 .txt 仍判 unsupported（既有口径不变）', () {
      expect(
        sniffFormat(
          fileName: 'a.txt',
          bytes: Uint8List.fromList(<int>[0x50, 0x4B, 0x03, 0x04, 0, 0]),
        ),
        FormatKind.unsupported,
      );
    });

    test('openBook(.cbz) → dart-cbz', () async {
      final BookSource source =
          await openBook(fileName: 'a.cbz', bytes: _cbzSample());
      expect(source.implId, 'dart-cbz');
      await source.dispose();
    });
  });
}
