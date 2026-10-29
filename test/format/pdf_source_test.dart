// `PdfSource` 契约测试（`FMT-01` 验收①②③ / `META-10` ①② / `RD-05` 错误码映射）。
//
// 渲染内核用假引擎（`pdf_fakes.dart`），因此本组纯 Dart、离线、确定性：
// 真渲染只在真样本冒烟（`tmp_book/`）走端到端路径。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/pdf_source.dart';
import 'package:mreader/platform/pdf_engine.dart';

import 'pdf_fakes.dart';

/// 造一个使用假引擎的 [PdfSource]。
PdfSource _source(FakePdfEngine engine, {String fileName = '测试书.pdf'}) =>
    PdfSource(fileName: fileName, bytes: minimalPdfBytes(), engine: engine);

void main() {
  group('PdfSource · 伪分章（FMT-01 ②：目录按伪分章生成）', () {
    test('25 页 / N=10 → 3 章；href = p{起始页}、标题 = 第 X–Y 页', () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 25));
      final List<Chapter> chapters = await source.chapters();
      expect(
        chapters.map((Chapter c) => c.href).toList(),
        <String>['p0', 'p10', 'p20'],
      );
      expect(
        chapters.map((Chapter c) => c.title).toList(),
        <String>['第 1–10 页', '第 11–20 页', '第 21–25 页'],
      );
      expect(chapters.every((Chapter c) => c.level == 0), isTrue);
      await source.dispose();
    });

    test('整除：100 页（FMT-01 ① 的样本量）→ 10 章', () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 100));
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.length, 10);
      expect(chapters.first.href, 'p0');
      expect(chapters.last.href, 'p90');
      expect(chapters.last.title, '第 91–100 页');
      await source.dispose();
    });

    test('单页 PDF → 1 章，标题写「第 1 页」（不带区间）', () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 1));
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.length, 1);
      expect(chapters.single.title, '第 1 页');
      await source.dispose();
    });

    test('content(i) 给出本章页区间的按页资源键（imagePages，与段落互斥）',
        () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 25));
      expect((await source.content(0)).imagePages, <String>[
        'p0', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8', 'p9',
      ]);
      expect((await source.content(1)).imagePages!.first, 'p10');
      await source.dispose();
    });

    test('末章不足 N 页时只给剩余页（content(2) → p20..p24）', () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 25));
      final ChapterContent content = await source.content(2);
      expect(content.imagePages, <String>['p20', 'p21', 'p22', 'p23', 'p24']);
      expect(content.paragraphs, isNull, reason: '两种正文形态互斥');
      await source.dispose();
    });

    test('越界 / 负索引 content → 空 imagePages（不抛异常）', () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 25));
      expect((await source.content(3)).isEmpty, isTrue);
      expect((await source.content(-1)).isEmpty, isTrue);
      await source.dispose();
    });
  });

  group('PdfSource · 页资源读取（FMT-01 ① 连续翻阅 / PERF-02 非驻留）', () {
    test('readResource("p3") 现渲染一页，宽度 = kPdfPageRenderWidthPx', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 25);
      final PdfSource source = _source(engine);
      final Uint8List? bytes = await source.readResource('p3');
      expect(bytes, isNotNull);
      expect(bytes!.take(8), <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(engine.renderedPages, <int>[3]);
      expect(engine.renderedWidths, <int>[kPdfPageRenderWidthPx]);
      await source.dispose();
    });

    test('同一页读两次 → 渲染两次（不缓存页字节：非驻留）', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 25);
      final PdfSource source = _source(engine);
      await source.readResource('p7');
      await source.readResource('p7');
      expect(engine.renderedPages, <int>[7, 7]);
      await source.dispose();
    });

    test('非法键 / 越界键 → null，且不触发任何渲染', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 25);
      final PdfSource source = _source(engine);
      expect(await source.readResource(''), isNull);
      expect(await source.readResource('p'), isNull);
      expect(await source.readResource('q3'), isNull);
      expect(await source.readResource('p1x'), isNull);
      expect(await source.readResource('p-1'), isNull);
      expect(await source.readResource('p25'), isNull, reason: '页索引越界');
      expect(engine.renderedPages, isEmpty);
      await source.dispose();
    });

    test('坏页渲染失败 → null（不把异常抛给渲染层）', () async {
      final PdfSource source = _source(
        FakePdfEngine(pageCount: 5, renderFailedPages: const <int>{2}),
      );
      expect(await source.readResource('p2'), isNull);
      expect(await source.readResource('p1'), isNotNull);
      await source.dispose();
    });

    test('dispose 后 readResource → null', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 5);
      final PdfSource source = _source(engine);
      await source.chapters();
      await source.dispose();
      expect(await source.readResource('p0'), isNull);
      expect(engine.renderedPages, isEmpty, reason: '已释放不应再触发渲染');
    });
  });

  group('PdfSource · 封面（META-10 ①②）', () {
    test('封面 = 第 0 页渲染结果为 PendingCover(PNG)，来源 metadata', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 25);
      final PdfSource source = _source(engine);
      final BookMeta meta = await source.load();
      expect(meta.cover, isA<PendingCover>());
      final PendingCover cover = meta.cover as PendingCover;
      expect(cover.format, CoverFormat.png, reason: '魔数嗅探真实格式（META-05）');
      expect(cover.bytes.take(8),
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(meta.coverOrigin, MetaOrigin.metadata);
      expect(meta.title, isNotEmpty);
      expect(meta.author, isNotEmpty);
      await source.dispose();
    });

    test('封面用低分辨率渲染宽度（缩略图不必渲大图）', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 25);
      final PdfSource source = _source(engine);
      await source.load();
      expect(engine.renderedPages.first, 0);
      expect(engine.renderedWidths.first, kPdfCoverRenderWidthPx);
      await source.dispose();
    });

    test('第 0 页渲染失败 → NoCover + 来源 none（META-10 ②：交 META-07 合成，非空白）',
        () async {
      final PdfSource source = _source(
        FakePdfEngine(pageCount: 3, renderFailedPages: const <int>{0}),
      );
      final BookMeta meta = await source.load();
      expect(meta.cover, isA<NoCover>());
      expect(meta.coverOrigin, MetaOrigin.none);
      await source.dispose();
    });
  });

  group('PdfSource · 错误映射（RD-05 唯一来源表）', () {
    /// 断言异常的错误码与文案（文案必须取自 `kFormatErrorMessages`）。
    Matcher hasCode(FormatErrorCode code) => isA<MReaderFormatException>()
        .having((MReaderFormatException e) => e.code, 'code', code)
        .having((MReaderFormatException e) => e.message, 'message',
            kFormatErrorMessages[code]);

    test('加密 PDF → encryptedPdf（Q4 ④：明确拒绝，不走输密码链路）', () async {
      final FakePdfEngine engine = FakePdfEngine(
        pageCount: 10,
        openFailure: PdfOpenFailure.encrypted,
      );
      final PdfSource source = _source(engine);
      // ⚠️ 异步匹配器必须 `await expectLater`：`expect(() => future, throwsA(…))`
      // 不等待，紧随其后的 `dispose()` 会先跑，`_prepare` 落进「打开完成时已释放」
      // 的竞态分支而优雅返回空元数据 —— 断言就永远看不到异常（实测踩坑）。
      await expectLater(
        source.load(),
        throwsA(hasCode(FormatErrorCode.encryptedPdf)),
      );
      await expectLater(
        source.chapters(),
        throwsA(hasCode(FormatErrorCode.encryptedPdf)),
      );
      // 导入管道也走 load()：同型同码（RD-05）
      expect(
        kFormatErrorMessages[FormatErrorCode.encryptedPdf],
        contains('PDF'),
      );
      await source.dispose();
    });

    test('不可读 PDF → corruptFile', () async {
      final PdfSource source = _source(
        FakePdfEngine(pageCount: 10, openFailure: PdfOpenFailure.unreadable),
      );
      await expectLater(
        source.load(),
        throwsA(hasCode(FormatErrorCode.corruptFile)),
      );
      await source.dispose();
    });

    test('空文件 → emptyFile，且不触碰渲染引擎', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 10);
      final PdfSource source = PdfSource(
        fileName: '空.pdf',
        bytes: Uint8List(0),
        engine: engine,
      );
      await expectLater(
        source.load(),
        throwsA(hasCode(FormatErrorCode.emptyFile)),
      );
      expect(engine.openCount, 0);
      await source.dispose();
    });

    test('引擎不可用（组合根未注入）→ unsupportedFormat，detail 指明原因', () async {
      final PdfSource source = PdfSource(
        fileName: '书.pdf',
        bytes: minimalPdfBytes(),
        engine: const UnavailablePdfEngine(),
      );
      await expectLater(
        source.load(),
        throwsA(isA<MReaderFormatException>()
            .having((MReaderFormatException e) => e.code, 'code',
                FormatErrorCode.unsupportedFormat)
            .having((MReaderFormatException e) => e.toString(), 'detail',
                contains('未注入'))),
      );
      await source.dispose();
    });

    test('0 页 PDF → corruptFile（detail 记页数）', () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 0));
      await expectLater(
        source.load(),
        throwsA(isA<MReaderFormatException>()
            .having((MReaderFormatException e) => e.code, 'code',
                FormatErrorCode.corruptFile)
            .having((MReaderFormatException e) => e.toString(), 'detail',
                contains('页数为 0'))),
      );
      await source.dispose();
    });
  });

  group('PdfSource · dispose 契约（与 TXT / CBZ 一致）', () {
    test('dispose 释放文档句柄，且幂等', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 5);
      final PdfSource source = _source(engine);
      await source.chapters();
      expect(engine.disposeCount, 0);
      await source.dispose();
      await source.dispose();
      expect(engine.disposeCount, 1, reason: '句柄只释放一次');
      expect(source.isDisposed, isTrue);
    });

    test('dispose 后 load / chapters / content / readResource 全部优雅空结果',
        () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 25);
      final PdfSource source = _source(engine);
      await source.chapters();
      await source.dispose();

      final BookMeta meta = await source.load();
      expect(meta.title, '未命名');
      expect(meta.titleOrigin, MetaOrigin.none);
      expect(meta.coverOrigin, MetaOrigin.none);
      expect(await source.chapters(), isEmpty);
      expect((await source.content(0)).isEmpty, isTrue);
      expect(await source.readResource('p0'), isNull);
    });

    test('未打开就 dispose：不抛异常、不误渲染', () async {
      final FakePdfEngine engine = FakePdfEngine(pageCount: 5);
      final PdfSource source = _source(engine);
      await source.dispose();
      expect(await source.chapters(), isEmpty);
      expect(await source.readResource('p0'), isNull);
    });
  });

  group('PdfSource · 能力如实（不宣称做不到的事）', () {
    test('capabilities：图片页 / 不重排 / 文本层可搜（T04 已接入）/ 无字符数',
        () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 5));
      final SourceCapabilities caps = source.capabilities();
      expect(caps.hasImages, isTrue);
      expect(caps.reflowable, isFalse);
      expect(caps.hasFootnotes, isFalse);
      expect(caps.searchable, isTrue,
          reason: 'M2b-T04 文本层搜索已接入（逐页 pageText），契约「声明可搜'
              '就要搜得到」由 search() 实现兑现（命中语义见 test/search/pdf_search_test.dart）');
      expect(caps.charCountSupported, isFalse);
      await source.dispose();
    });

    test('search 无文本层零命中、totalCharCount 为 null', () async {
      final PdfSource source = _source(FakePdfEngine(pageCount: 5));
      // 假引擎 texts 空 = 全书扫描件：零命中，但逐页进度照常产出（不再宣称「空流」）。
      final List<SearchEvent> events =
          await source.search('任意', cancel: CancelToken()).toList();
      expect(events.map((SearchEvent e) => e.hit).nonNulls, isEmpty);
      expect(events.map((SearchEvent e) => e.progress).nonNulls, hasLength(5));
      expect(await source.totalCharCount(), isNull);
      // T03：伪章无文本 → 不覆写 chapterCharCounts → 默认 null → 进度退化等权。
      expect(await source.chapterCharCounts(), isNull);
      await source.dispose();
    });

    test('implId 为 pdfrx-pdf（与契约清单标签一致）', () {
      final PdfSource source = _source(FakePdfEngine(pageCount: 5));
      expect(source.implId, 'pdfrx-pdf');
    });
  });
}
