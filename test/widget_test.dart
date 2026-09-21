// 解析层单测（在内存里现造一本最小 EPUB，不依赖任何外部文件）+ 首页冒烟测试。
//
// 注意文件名叫 widget_test.dart：`flutter create` 只在文件缺失时才生成模板，
// 这样就不会注入它自带的 counter 测试（那会让 `flutter test` 编译失败）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/app.dart';
import 'package:mreader/epub/epub_parser.dart';
import 'package:mreader/epub/section_extractor.dart';
import 'package:mreader/format/error_messages.dart';
import 'package:mreader/main.dart';
import 'package:mreader/model/epub_book.dart';
import 'package:mreader/settings/settings_store.dart';

/// 把若干「路径 -> 文本内容」打成 zip 字节流。
Uint8List _zip(Map<String, String> entries) {
  final Archive archive = Archive();
  for (final MapEntry<String, String> entry in entries.entries) {
    final List<int> bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final List<int>? encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

/// 一本结构完整的最小 EPUB：2 个 chapter，第二个标了 linear="no"。
Uint8List _minimalEpub() {
  return _zip(<String, String>{
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<container version="1.0" '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles>'
            '<rootfile full-path="OEBPS/content.opf" '
            'media-type="application/oebps-package+xml"/>'
            '</rootfiles></container>',
    'OEBPS/content.opf':
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
            'unique-identifier="uid">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>测试书名</dc:title>'
            '<dc:creator>测试作者</dc:creator>'
            '<dc:language>zh</dc:language>'
            '</metadata>'
            '<manifest>'
            '<item id="c1" href="text/ch1.xhtml" '
            'media-type="application/xhtml+xml"/>'
            '<item id="c2" href="text/ch2.xhtml" '
            'media-type="application/xhtml+xml"/>'
            '</manifest>'
            '<spine><itemref idref="c1"/><itemref idref="c2" linear="no"/></spine>'
            '</package>',
    'OEBPS/text/ch1.xhtml':
        '<html xmlns="http://www.w3.org/1999/xhtml">'
            '<head><title>第一章 起</title></head>'
            '<body><h1>第一章</h1><p>你好，世界。</p><p>第二段。</p></body></html>',
    'OEBPS/text/ch2.xhtml':
        '<html xmlns="http://www.w3.org/1999/xhtml">'
            '<body><p>不应出现</p></body></html>',
  });
}

void main() {
  group('parseEpub', () {
    test('解析元数据，按 spine 顺序取章节，跳过 linear="no"', () async {
      final EpubBook book =
          await parseEpub(_minimalEpub(), fileName: 'demo.epub');

      expect(book.title, '测试书名');
      expect(book.author, '测试作者');
      expect(book.language, 'zh');
      expect(book.displayTitle, '测试书名');
      expect(book.sections.length, 1);
      expect(book.sections.first.href, 'OEBPS/text/ch1.xhtml');
    });

    test('extractSection 抽到标题，且正文里不再重复标题', () async {
      final EpubBook book = await parseEpub(_minimalEpub());
      final ExtractedSection section =
          extractSection(book.sections.first.rawBytes);

      expect(section.title, '第一章');
      expect(section.paragraphs, <String>['你好，世界。', '第二段。']);
    });

    test('缺 container.xml 时抛出可读的 MReaderFormatException', () async {
      final Uint8List broken = _zip(<String, String>{
        'mimetype': 'application/epub+zip',
      });
      await expectLater(
        parseEpub(broken),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.missingContainer,
        )),
      );
    });

    test('非 zip 字节流抛出可读的 MReaderFormatException', () async {
      await expectLater(
        parseEpub(Uint8List.fromList(<int>[1, 2, 3, 4, 5])),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.notZip,
        )),
      );
    });
  });

  testWidgets('首页可以正常渲染（冒烟）', (WidgetTester tester) async {
    final Directory dir =
        await Directory.systemTemp.createTemp('mreader_widget_test_');
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
    final SettingsStore settings = SettingsStore(dir);
    await tester.pumpWidget(
      MReaderApp(settings: settings, home: const HomePage()),
    );
    expect(find.textContaining('EPUB'), findsWidgets);
    expect(find.textContaining('TXT'), findsWidgets);
  });
}
