// [BookSource] 契约测试：**所有已注册的格式实现都必须满足**。
//
// 为什么要有这个文件：`RD-01`/`CNT-06` 的契约是「实现互不感知、只消费抽象结果」。
// 把公共契约集中在一处，新增格式（M1-T02B 的 TXT、M2b 的 CBZ/PDF、M3.5 的 Rust 实现）
// 只需往 `registeredSources()` 追加一行，就会自动被同一组断言覆盖。
//
// **M1-T02B 接入信号**：在 `registeredSources()` 里追加一条 `dart-txt` 样本即可。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/cbz_source.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/format/dart_txt_source.dart';
import 'package:mreader/format/pdf_source.dart';

import 'epub_builder.dart';
import 'pdf_fakes.dart';

/// 一个「已注册实现」的样本：标签 + 工厂（每次调用返回**全新实例**，保证用例互不污染）。
class BookSourceSample {
  const BookSourceSample({
    required this.label,
    required this.fileName,
    required this.create,
  });

  final String label;
  final String fileName;
  final BookSource Function() create;
}

/// 一本结构完整的最小 EPUB（1 章，含正文）。
Uint8List _minimalEpub() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '契约样本',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1'),
        ),
      ),
      textEntry('OEBPS/text/ch1.xhtml',
          xhtmlDoc(title: '一 起', heading: '第一章', paragraphs: <String>['正文一。', '正文二。'])),
    ]);

/// 一段最小 TXT 样本：两章（标题可被「第X章 …」类规则命中）+ 含「正文」的段落。
///
/// 之所以刻意带上「正文」二字：契约里 `capabilities().searchable` 为真时，
/// 会拿 `'正文'` 去搜，必须能命中样本内容。
Uint8List _minimalTxt() => Uint8List.fromList(utf8.encode(
      '第一章 起\n'
      '正文一。\n'
      '\n'
      '第二章 承\n'
      '正文二。\n',
    ));

/// 一本结构完整的最小 CBZ（2 个图片页；M2b-T02 接入信号）。
Uint8List _minimalCbz() => zipEntries(<EpubEntry>[
      EpubEntry('p/2.png', <int>[0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]),
      EpubEntry('p/10.png', <int>[0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]),
    ]);

/// 已注册的实现清单。
///
/// **新增格式实现时在这里追加**（M1-T02B 已加 `dart-txt`；M2b-T02 已加 `dart-cbz`）。
List<BookSourceSample> registeredSources() => <BookSourceSample>[
      BookSourceSample(
        label: 'dart-epub',
        fileName: 'contract.epub',
        create: () => DartEpubSource(
          fileName: 'contract.epub',
          bytes: _minimalEpub(),
        ),
      ),
      BookSourceSample(
        label: 'dart-txt',
        fileName: 'contract.txt',
        create: () => DartTxtSource(
          fileName: 'contract.txt',
          bytes: _minimalTxt(),
        ),
      ),
      BookSourceSample(
        label: 'dart-cbz',
        fileName: 'contract.cbz',
        create: () => CbzSource(
          fileName: 'contract.cbz',
          bytes: _minimalCbz(),
        ),
      ),
      // M2b-T01 接入信号：PDF 走**注入的**渲染内核（`META-10` ③），
      // 契约测试用假引擎，故不依赖 pdfrx 与原生库（离线可跑）。
      BookSourceSample(
        label: 'pdfrx-pdf',
        fileName: 'contract.pdf',
        create: () => PdfSource(
          fileName: 'contract.pdf',
          bytes: minimalPdfBytes(),
          // texts 注入「正文」页文本：`capabilities().searchable` 为真后，
          // 契约「声明可搜就必须搜得到」对 PDF 同样生效（M2b-T04）。
          engine: FakePdfEngine(
            pageCount: 2,
            texts: <int, String>{0: '正文一。', 1: '正文二。'},
          ),
        ),
      ),
    ];

void main() {
  final List<BookSourceSample> samples = registeredSources();

  test('已注册实现清单非空（防止将来误删注册）', () {
    expect(samples, isNotEmpty);
    expect(
      samples.map((BookSourceSample s) => s.label).toSet().length,
      samples.length,
      reason: '标签必须唯一，便于定位失败实现',
    );
  });

  for (final BookSourceSample sample in samples) {
    group('契约 · ${sample.label}', () {
      test('implId 非空且为小写短标识', () {
        final BookSource source = sample.create();
        expect(source.implId, isNotEmpty);
        expect(source.implId, sample.label);
        expect(source.implId, matches(RegExp(r'^[a-z0-9-]+$')));
      });

      test('load() 返回元数据，字段不为 null', () async {
        final BookSource source = sample.create();
        final BookMeta meta = await source.load();
        expect(meta.title, isNotEmpty, reason: 'META-01：书名缺失也要兜底为非空');
        expect(meta.author, isNotEmpty, reason: 'META-01：作者缺失也要兜底为非空');
        expect(meta.language, isA<String>());
        expect(meta.intro, isA<String>());
        // 枚举化后 `isNotEmpty` 失效：来源标记改为**闭合枚举**断言。
        // 契约样本必有书名，故 titleOrigin 一定不是 none；author/cover 可为 none（缺失）。
        expect(meta.titleOrigin, isNot(MetaOrigin.none));
        expect(meta.authorOrigin, isA<MetaOrigin>());
        expect(meta.coverOrigin, isA<MetaOrigin>());
        expect(meta.cover, isA<CoverRef>());
        await source.dispose();
      });

      test('chapters() 非空，且 content(i) 对每个 i 都成功', () async {
        final BookSource source = sample.create();
        final List<Chapter> chapters = await source.chapters();
        expect(chapters, isNotEmpty, reason: '可打开的样本必须给出至少一章');

        for (int i = 0; i < chapters.length; i++) {
          final Chapter chapter = chapters[i];
          expect(chapter.href, isNotEmpty, reason: '第 $i 章的 href 是稳定身份，不可为空');
          expect(chapter.level, greaterThanOrEqualTo(0));

          final ChapterContent content = await source.content(i);
          expect(
            content.paragraphs != null || content.imagePages != null,
            isTrue,
            reason: '第 $i 章必须要么是段落、要么是图片页',
          );
        }
        await source.dispose();
      });

      test('越界 content(i) 不抛异常（返回空内容）', () async {
        final BookSource source = sample.create();
        final int count = (await source.chapters()).length;
        expect((await source.content(count)).isEmpty, isTrue);
        expect((await source.content(-1)).isEmpty, isTrue);
        await source.dispose();
      });

      test('capabilities() 与搜索契约一致', () async {
        final BookSource source = sample.create();
        final SourceCapabilities caps = source.capabilities();
        if (caps.searchable) {
          final List<SearchEvent> events = await source
              .search('正文', cancel: CancelToken())
              .toList();
          expect(
            events.any((SearchEvent e) => e.hit != null),
            isTrue,
            reason: '声明 searchable 就必须能搜到样本里的正文',
          );
        }
        await source.dispose();
      });

      test('dispose() 幂等（可重复调用）', () async {
        final BookSource source = sample.create();
        await source.chapters();
        await source.dispose();
        await source.dispose();
      });
    });
  }

  test('openBook 分发的实现与注册清单一致（epub）', () async {
    final BookSource source = await openBook(
      fileName: 'contract.epub',
      bytes: _minimalEpub(),
    );
    expect(source.implId, 'dart-epub');
    final bool declared = samples.any(
      (BookSourceSample s) => s.label == source.implId,
    );
    expect(declared, isTrue, reason: 'openBook 选出的实现必须在契约清单里');
    await source.dispose();
  });

  test('openBook 分发的实现与注册清单一致（txt）', () async {
    final BookSource source = await openBook(
      fileName: 'contract.txt',
      bytes: _minimalTxt(),
    );
    expect(source.implId, 'dart-txt');
    final bool declared = samples.any(
      (BookSourceSample s) => s.label == source.implId,
    );
    expect(declared, isTrue, reason: 'openBook 选出的实现必须在契约清单里');
    await source.dispose();
  });

  test('搜索可取消：已取消的令牌不产出任何事件', () async {
    final BookSource source = registeredSources().first.create();
    final CancelToken token = CancelToken()..cancel();
    expect(await source.search('正文', cancel: token).toList(), isEmpty);
    await source.dispose();
  });

  // 防止误改：契约样本本身必须是「可解析」的 zip，而不是碰巧空字节。
  test('契约样本字节非空且为 zip', () {
    final Uint8List bytes = _minimalEpub();
    expect(bytes.length, greaterThan(0));
    expect(bytes.sublist(0, 2), <int>[0x50, 0x4B], reason: 'zip 魔数 PK');
    expect(utf8.decode(bytes.sublist(0, 2), allowMalformed: true), 'PK');
  });
}
