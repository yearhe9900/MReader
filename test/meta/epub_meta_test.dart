// `META-02` / `META-03`：EPUB 元数据提取（四来源优先级链 + 多作者 + 简介 + 兜底）。
//
// 期望值取自 `.scratch/probe_meta.dart` 实测。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/epub/epub_parser.dart';
import 'package:mreader/meta/epub_meta.dart';
import 'package:mreader/model/book_meta.dart';

import '../format/epub_builder.dart';
import 'meta_fixtures.dart';

/// 组装一本结构完整的最小 EPUB（1 章正文；可带自定义 manifest / 封面条目）。
Uint8List _epub({
  required String manifest,
  String title = '书名',
  String? creators,
  String extraMetadata = '',
  String guide = '',
  List<EpubEntry> extraEntries = const <EpubEntry>[],
}) {
  return zipEntries(<EpubEntry>[
    textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
    textEntry(
      'OEBPS/content.opf',
      opfXml(
        title: title,
        creators: creators,
        manifest: manifest,
        spine: itemrefXml('c1'),
        version: '3.0',
        extraMetadata: extraMetadata,
        guide: guide,
      ),
    ),
    textEntry(
      'OEBPS/text/ch1.xhtml',
      xhtmlDoc(title: '一', heading: '第一章', paragraphs: <String>['正文。']),
    ),
    ...extraEntries,
  ]);
}

Future<BookMeta> _metaOf(Uint8List bytes, {String fileName = 'x.epub'}) async {
  final EpubParseResult r = await parseEpubResult(bytes, fileName: fileName);
  return buildEpubMeta(opfView: r.opfView, fileName: fileName);
}

String _chap() =>
    itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml');

void main() {
  group('META-02 封面四来源（命中即停）', () {
    test('① OPF <meta name="cover" content="id">', () async {
      final Uint8List bytes = _epub(
        manifest: '${_chap()}${itemXml('cov', 'images/cover.png', 'image/png')}',
        extraMetadata: '<meta name="cover" content="cov"/>',
        extraEntries: <EpubEntry>[
          EpubEntry('OEBPS/images/cover.png', kTinyPng),
        ],
      );
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.cover, isA<PendingCover>());
      final PendingCover cover = meta.cover as PendingCover;
      expect(cover.format, CoverFormat.png);
      expect(cover.bytes, kTinyPng);
      expect(meta.coverOrigin, MetaOrigin.metadata);
    });

    test('② properties="cover-image"（EPUB3 最常见；仅此来源也能取到）', () async {
      final Uint8List bytes = _epub(
        manifest: '${_chap()}${itemXml(
          'cov',
          'images/cover.png',
          'image/png',
          properties: 'cover-image',
        )}',
        extraEntries: <EpubEntry>[
          EpubEntry('OEBPS/images/cover.png', kTinyPng),
        ],
      );
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.cover, isA<PendingCover>());
      expect((meta.cover as PendingCover).format, CoverFormat.png);
    });

    test('③ guide <reference type="cover" href>', () async {
      final Uint8List bytes = _epub(
        manifest: '${_chap()}${itemXml('cov', 'images/pic.jpg', 'image/jpeg')}',
        guide: '<guide><reference type="cover" href="images/pic.jpg"/></guide>',
        extraEntries: <EpubEntry>[
          EpubEntry('OEBPS/images/pic.jpg', kTinyJpeg),
        ],
      );
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.cover, isA<PendingCover>());
      expect((meta.cover as PendingCover).format, CoverFormat.jpeg);
    });

    test('④ 文件名含 cover 的图片项', () async {
      final Uint8List bytes = _epub(
        manifest:
            '${_chap()}${itemXml('cv', 'images/mycover.png', 'image/png')}',
        extraEntries: <EpubEntry>[
          EpubEntry('OEBPS/images/mycover.png', kTinyPng),
        ],
      );
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.cover, isA<PendingCover>());
      expect((meta.cover as PendingCover).format, CoverFormat.png);
    });

    test('★ 高优先级命中即停：meta(jpeg) 优先于 properties(png)', () async {
      final Uint8List bytes = _epub(
        manifest: '${_chap()}'
            '${itemXml('a', 'images/a.jpg', 'image/jpeg')}'
            '${itemXml('b', 'images/b.png', 'image/png', properties: 'cover-image')}',
        extraMetadata: '<meta name="cover" content="a"/>',
        extraEntries: <EpubEntry>[
          EpubEntry('OEBPS/images/a.jpg', kTinyJpeg),
          EpubEntry('OEBPS/images/b.png', kTinyPng),
        ],
      );
      final BookMeta meta = await _metaOf(bytes);
      expect((meta.cover as PendingCover).format, CoverFormat.jpeg,
          reason: '取优先级最高者，重复解析结果稳定');
    });

    test('四种来源皆缺 -> NoCover（不报错，交合成封面）', () async {
      final Uint8List bytes = _epub(manifest: _chap());
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.cover, isA<NoCover>());
      expect(meta.coverOrigin, MetaOrigin.none);
    });

    test('候选字节非图片（嗅探 unknown）则跳过该候选', () async {
      // guide 指向一个 XHTML 封面页（EPUB2 常见）——不是图片，应跳过而非当封面。
      final Uint8List bytes = _epub(
        manifest: '${_chap()}${itemXml('pg', 'text/cover.xhtml', 'application/xhtml+xml')}',
        guide: '<guide><reference type="cover" href="text/cover.xhtml"/></guide>',
        extraEntries: <EpubEntry>[
          EpubEntry('OEBPS/text/cover.xhtml', kNotAnImage),
        ],
      );
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.cover, isA<NoCover>());
    });
  });

  group('META-03 书名与作者', () {
    test('多作者按稳定顺序整体保留（不切分）', () async {
      final Uint8List bytes = _epub(
        manifest: _chap(),
        title: 'T',
        creators: '<dc:creator>甲</dc:creator><dc:creator>乙</dc:creator>',
      );
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.author, '甲；乙');
      expect(meta.authorOrigin, MetaOrigin.metadata);
    });

    test('dc:description -> intro（metadata）', () async {
      final Uint8List bytes = _epub(
        manifest: _chap(),
        extraMetadata: '<dc:description>简介文字</dc:description>',
      );
      final BookMeta meta = await _metaOf(bytes);
      expect(meta.intro, '简介文字');
      expect(meta.introOrigin, MetaOrigin.metadata);
    });

    test('书名/作者缺失 -> 文件名解析兜底（filename）', () async {
      final Uint8List bytes = _epub(manifest: _chap(), title: '', creators: '');
      final BookMeta meta =
          await _metaOf(bytes, fileName: '《无名书》作者：某人.epub');
      expect(meta.title, '无名书');
      expect(meta.titleOrigin, MetaOrigin.filename);
      expect(meta.author, '某人');
      expect(meta.authorOrigin, MetaOrigin.filename);
    });

    test('均有标题但无作者 -> 作者回退文件名（META-03 ②）', () async {
      final Uint8List bytes = _epub(manifest: _chap(), creators: '');
      final BookMeta meta = await _metaOf(bytes, fileName: '活着 by 余华.epub');
      expect(meta.title, '书名');
      expect(meta.titleOrigin, MetaOrigin.metadata);
      expect(meta.author, '余华');
      expect(meta.authorOrigin, MetaOrigin.filename);
    });

    test('书名/作者全缺 -> 未命名书籍 / 未知作者（来源 none）', () async {
      final Uint8List bytes = _epub(manifest: _chap(), title: '', creators: '');
      final BookMeta meta = await _metaOf(bytes, fileName: '.epub');
      expect(meta.title, '未命名书籍');
      expect(meta.titleOrigin, MetaOrigin.none);
      expect(meta.author, '未知作者');
      expect(meta.authorOrigin, MetaOrigin.none);
    });

    test('auto 快照恒非空且等于解析结果', () async {
      final BookMeta meta = await _metaOf(_epub(manifest: _chap()));
      expect(meta.auto, isNotNull);
      expect(meta.auto!.title, '书名');
    });
  });

  group('OpfView.readEntry', () {
    test('封面候选 href 可读到字节，未知 href 返回 null', () async {
      final Uint8List bytes = _epub(
        manifest: '${_chap()}${itemXml(
          'cov',
          'images/cover.png',
          'image/png',
          properties: 'cover-image',
        )}',
        extraEntries: <EpubEntry>[
          EpubEntry('OEBPS/images/cover.png', kTinyPng),
        ],
      );
      final EpubParseResult r = await parseEpubResult(bytes, fileName: 'x.epub');
      expect(r.opfView.coverCandidates, isNotEmpty);
      final String href = r.opfView.coverCandidates.first.href;
      expect(r.opfView.readEntry?.call(href), kTinyPng);
      expect(r.opfView.readEntry?.call('no/such.png'), isNull);
    });
  });
}
