// PDF 的纯 Dart [BookSource] 实现（`'pdfrx-pdf'`，`FMT-01` / `META-10`）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`、**不 import pdfrx**——
// 渲染能力经 [PdfEngine] 注入（`META-10` ③ / `Q4 ①` 验收①）。
//
// ## 模型映射（`FMT-01` 验收①~③ / `RD-04`）
//
// · **伪分章**：每 [kPdfPagesPerChapter] 页合成一章（PRD `FMT-01` 原文「按 N 页一个
//   伪章节」）。`Chapter.href` = `p{起始页}`（0 基页索引，稳定身份，对齐 `RD-04` /
//   `SYNC-02`），`title` = `第 X–Y 页`——目录「按伪分章生成」（验收②）；
// · **正文 = 图片页序列**：`ChapterContent.imagePages(['p0','p1',…])`，元素是**按页
//   资源键**，阅读页经 `readResource` 取 PNG 字节后走既有图片页分支（整页竖向滚动 +
//   点页全屏缩放，与 CBZ 完全同构 → 「连续翻阅」验收①成立，阅读页零改动）；
// · **进度可持久化**：直接复用语义坐标 `(chapterHref, chapterPos)`（验收③）——
//   伪章粒度天然可用，不为 PDF 造第二套进度模型；
// · **封面 = 渲染第 0 页**（`META-10` ①）：`PendingCover` + 魔数嗅探真实格式
//   （`META-05`）；渲染失败 → `NoCover`，由展示层按 `META-07` 合成封面而非空白（验收②）。
//
// ## N 为什么取 10
//
// 阅读页的图片页分支是 **Column 急构建**：进章瞬间就为本章每个 `imagePages` 元素发起
// 一次 `readResource`，而 PDF 每页都要**现渲染**（`PERF-02` 非驻留，不缓存位图）。
// N 越大，进章瞬间的并发渲染越多（内存 ×N、原生渲染线程争用）；N 越小则目录条目爆炸。
//
// ## 内存（`PERF-02`）
//
// 本类**不缓存任何页字节**：每次 `readResource` 现渲染（位图在适配器内当场释放），
// 结果交阅读页已有的 `ImageCacheLRU`（50MB 上界）兜解码缓存；文档句柄
// （[PdfEngineDocument]）随本实例生命周期，[dispose] 时释放。
import 'dart:typed_data';

import '../meta/meta_source.dart';
import '../meta/txt_meta.dart';
import '../platform/pdf_engine.dart';
import 'book_source.dart';

/// 每多少页合成一个伪章节（`FMT-01`「按 N 页一个伪章节」，取值理由见文件头）。
const int kPdfPagesPerChapter = 10;

/// 封面渲染宽度（`META-10` ①：书架 / 详情页缩略图足够，不必为此渲一张大图）。
const int kPdfCoverRenderWidthPx = 512;

/// 阅读页渲染宽度。
///
/// 取 1600：手机 / 桌面在 1x~2x 缩放下足够清晰；单页 BGRA 瞬时占用约
/// `1600 × 2263 × 4 ≈ 14.5MB`，渲染完立即释放，只留 PNG 与解码缓存。
///
/// **边界声明**：位图管线是「定分辨率渲染 + 客户端缩放」，倍率放大到全屏查看器的
/// `maxScale`（5x）时会有插值模糊——`FMT-01` 的「双指缩放」不含「缩放后不糊」硬指标
/// （那是 `FMT-02` 对 CBZ 原始字节的要求）。要无损放大须改「按倍率重渲染 + 分块」
/// 架构，不在本批范围。
const int kPdfPageRenderWidthPx = 1600;

/// 页资源键前缀（`p` + 0 基页索引），既是 `imagePages` 元素，也是 `readResource` 入参。
const String kPdfPageKeyPrefix = 'p';

/// 打开本地 PDF（纯字节入口）。
///
/// ## dispose 契约（与 `DartTxtSource` / `CbzSource` 一致）
///
/// [dispose] 之后、以及竞态恢复后，所有公开方法返回优雅空结果、绝不抛异常：
/// `load()` → 最小 [BookMeta]（origins 全 `MetaOrigin.none`）；`chapters()` /
/// `content()` → 空；`readResource()` → `null`。每个 `await` 恢复后重查 [_disposed]。
class PdfSource implements BookSource {
  PdfSource({
    required this.fileName,
    required this.bytes,
    PdfEngine? engine,
  }) : _engine = engine ?? PdfEngineProvider.current;

  /// 原始文件名（META-04 文件名规则链的书名 / 作者来源，与 TXT / CBZ 同源）。
  final String fileName;

  /// PDF 的完整字节（`openData` 会持有，故不复制、不改编）。
  final Uint8List bytes;

  /// 渲染内核（`META-10` ③ 注入缝）。默认取组合根注入的全局引擎；
  /// 测试按实例传假引擎，互不污染。
  final PdfEngine _engine;

  bool _disposed = false;
  Future<void>? _preparing;

  /// 已打开的文档句柄（`dispose()` 释放；竞态时不写回）。
  PdfEngineDocument? _document;

  int _pageCount = 0;
  List<Chapter>? _chapters;

  /// 已释放 / 竞态时 `load()` 的最小返回（满足 `META-01` 兜底不变式）。
  static const BookMeta _disposedMeta = BookMeta(
    title: '未命名',
    titleOrigin: MetaOrigin.none,
    author: kUnknownAuthor,
    authorOrigin: MetaOrigin.none,
    intro: '',
    introOrigin: MetaOrigin.none,
    cover: NoCover(),
    coverOrigin: MetaOrigin.none,
    language: '',
    auto: BookMetaAuto(title: '未命名', author: kUnknownAuthor, intro: ''),
  );

  @override
  String get implId => 'pdfrx-pdf';

  @override
  Future<BookMeta> load() async {
    await _ensurePrepared();
    final List<Chapter>? chapters = _chapters;
    if (_disposed || chapters == null || chapters.isEmpty) return _disposedMeta;

    // 书名 / 作者 / 来源标记：META-04 文件名规则链（与 TXT / CBZ 同源）。
    final BookMeta base = buildTxtMeta(fileName: fileName);

    // META-10 ①：封面 = 渲染第 0 页（小图渲染，够缩略图用）。
    // 渲染失败 → NoCover，展示层按 META-07 合成封面（验收②：不是空白）。
    CoverRef cover = const NoCover();
    MetaOrigin coverOrigin = MetaOrigin.none;
    final Uint8List? first = await _renderPage(0, kPdfCoverRenderWidthPx);
    if (first != null && first.isNotEmpty) {
      final CoverFormat format = sniffCoverFormat(first);
      if (format != CoverFormat.unknown) {
        cover = PendingCover(first, format);
        coverOrigin = MetaOrigin.metadata;
      }
    }

    return BookMeta(
      title: base.title,
      titleOrigin: base.titleOrigin,
      author: base.author,
      authorOrigin: base.authorOrigin,
      intro: base.intro,
      introOrigin: base.introOrigin,
      cover: cover,
      coverOrigin: coverOrigin,
      language: base.language,
      auto: base.auto,
    );
  }

  @override
  Future<List<Chapter>> chapters() async {
    await _ensurePrepared();
    if (_disposed) return const <Chapter>[];
    return _chapters ?? const <Chapter>[];
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    await _ensurePrepared();
    final List<Chapter>? chapters = _chapters;
    if (_disposed || chapters == null) {
      return const ChapterContent.imagePages(<String>[]);
    }
    if (chapterIndex < 0 || chapterIndex >= chapters.length) {
      return const ChapterContent.imagePages(<String>[]); // 越界不抛异常
    }
    final int start = chapterIndex * kPdfPagesPerChapter;
    final int end = _chapterEnd(start);
    // 本章覆盖的页 → 按页资源键序列（与段落互斥的类型约束）。
    return ChapterContent.imagePages(<String>[
      for (int page = start; page < end; page++) '$kPdfPageKeyPrefix$page',
    ]);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: true,
        hasFootnotes: false,
        reflowable: false, // 页面固版式：不重排（与 CBZ 同口径）
        // `M2b-T04`（`CNT-06` / `Q4` ②）：文本层搜索已接入——逐页消费
        // `PdfEngineDocument.pageText`，扫描件（无文本层页）自动跳过。
        searchable: true,
        charCountSupported: false, // 无「字符数」语义（页数 ≠ 字符数）
      );

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) async* {
    if (query.isEmpty) return;
    await _ensurePrepared();
    if (_disposed) return;
    final PdfEngineDocument? document = _document;
    final List<Chapter>? chapterList = _chapters;
    if (document == null || chapterList == null || chapterList.isEmpty) return;
    final int pages = _pageCount;

    // 与 `DartEpubSource.search` 同一形状的朴素子串扫描（`CNT-06` 验收①
    // 「命中数与实际出现次数一致」= indexOf 全计数）。扫描单位是**页**（文本层的
    // 最小抽取单元；扫描件页 `pageText` 为 null 自动跳过），命中 `chapterIndex`
    // 按伪分章折算，`offset` 为**章内**页文本字符累加偏移（与段落源同一语义）。
    int chapterIndex = -1;
    int offsetInChapter = 0;
    for (int page = 0; page < pages; page++) {
      if (cancel.isCancelled || _disposed) return;
      final String? text = await document.pageText(page);
      if (_disposed) return; // `pageText` 的 await 期间可能已被释放
      final int chapter = page ~/ kPdfPagesPerChapter;
      if (chapter != chapterIndex) {
        chapterIndex = chapter;
        offsetInChapter = 0;
      }
      if (text != null && text.isNotEmpty) {
        int from = 0;
        while (true) {
          final int at = text.indexOf(query, from);
          if (at < 0) break;
          yield SearchEvent.hit(SearchHit(
            chapterIndex: chapterIndex,
            chapterTitle: chapterList[chapterIndex].title,
            offset: offsetInChapter + at,
            context: _lineAround(text, at, at + query.length),
          ));
          if (cancel.isCancelled) return;
          from = at + query.length;
        }
        offsetInChapter += text.length;
      }
      yield SearchEvent.progress((page + 1) / pages);
    }
  }

  /// 命中所在行（页文本按 `\n` 分行）作上下文片段——对齐段落源的「命中所在整段」。
  static String _lineAround(String text, int start, int end) {
    final int found = text.lastIndexOf('\n', start);
    final int lineStart = found < 0 ? 0 : found + 1;
    int lineEnd = text.indexOf('\n', end);
    if (lineEnd < 0) lineEnd = text.length;
    return text.substring(lineStart, lineEnd);
  }

  /// PDF 是**句柄源**（`PdfEngineDocument` 绑原生引擎、不可序列化）→ 给不出
  /// [SearchBookSpec]：搜索驱动层据此改走本 isolate 流式（`lib/task/search_session.dart`）。
  /// （`BookSource.searchSpec` 的默认实现**不跨 `implements` 继承**，显式写出。）
  @override
  SearchBookSpec? get searchSpec => null;

  @override
  Future<int?> totalCharCount() async => null;

  // `implements BookSource` 不继承接口默认实现：显式覆写，保持 null（伪章无文本
  // → 调用方进度退化页数/等权加权，T03）。
  @override
  Future<List<int>?> chapterCharCounts() async => null;

  @override
  Future<List<int>?> chapterWeightEstimates() async => null;

  @override
  Future<Uint8List?> readResource(String href) async {
    try {
      await _ensurePrepared();
    } catch (_) {
      return null; // 资源读取尽力而为：坏文件不把业务错误抛给渲染层
    }
    if (_disposed) return null;
    final int? page = _pageIndexOf(href);
    if (page == null || page < 0 || page >= _pageCount) return null;
    return _renderPage(page, kPdfPageRenderWidthPx);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _preparing = null;
    _chapters = null;
    _pageCount = 0;
    final PdfEngineDocument? document = _document;
    _document = null;
    if (document != null) {
      await document.dispose(); // 释放原生文档句柄（PERF-02）
    }
  }

  /// 是否已释放（供体检 / 测试观察）。
  bool get isDisposed => _disposed;

  // ---------------------------------------------------------------------------
  // 准备（打开文档 + 建伪章表），Future 去重
  // ---------------------------------------------------------------------------

  Future<void> _ensurePrepared() {
    if (_disposed) return Future<void>.value(); // 已释放：不再触发解析
    return _preparing ??= _prepare();
  }

  Future<void> _prepare() async {
    if (bytes.isEmpty) {
      throw const MReaderFormatException(FormatErrorCode.emptyFile);
    }
    // 组合根未注入渲染内核：给「暂不支持这种格式」的可读提示，而不是静默空白页
    // 或崩栈（诚实降级；`main()` 正常注入后此分支不可达）。
    if (!_engine.isAvailable) {
      throw const MReaderFormatException(
        FormatErrorCode.unsupportedFormat,
        detail: 'PDF 渲染内核未注入',
      );
    }

    final PdfEngineDocument document;
    try {
      document = await _engine.open(bytes);
    } on PdfEngineOpenException catch (e) {
      // 引擎异常 → 用户可读文案（`RD-05` 唯一来源；Q4 ④ 加密 PDF 明确拒绝）。
      throw MReaderFormatException(
        switch (e.reason) {
          PdfOpenFailure.encrypted => FormatErrorCode.encryptedPdf,
          PdfOpenFailure.unreadable => FormatErrorCode.corruptFile,
        },
        detail: e.detail,
      );
    }

    if (_disposed) {
      await document.dispose(); // 竞态：打开完成时已释放，不写回
      return;
    }

    final int pageCount = document.pageCount;
    if (pageCount <= 0) {
      await document.dispose();
      // 0 页 PDF 无法作为电子书阅读：按「损坏 / 不是有效电子书」报错（边界声明：
      // 不复用 EPUB 口径的 `emptySpine`，其文案含 EPUB 专有名词）。
      throw const MReaderFormatException(
        FormatErrorCode.corruptFile,
        detail: 'PDF 页数为 0',
      );
    }

    _document = document;
    _pageCount = pageCount;
    _chapters = List<Chapter>.unmodifiable(_buildChapters(pageCount));
  }

  /// 伪分章表（`FMT-01` ②：目录按伪分章生成）。
  List<Chapter> _buildChapters(int pageCount) {
    final List<Chapter> chapters = <Chapter>[];
    for (int start = 0; start < pageCount; start += kPdfPagesPerChapter) {
      final int end = _chapterEnd(start);
      chapters.add(
        Chapter(
          // 章身份 = 起始页（`FMT-01` ③ 进度真值的 `chapterHref`）；
          // 与页资源键同名同源，语义清晰：`p10` 既是「第 11 页」也是「该页所在章」。
          href: '$kPdfPageKeyPrefix$start',
          title: _titleFor(start, end),
          level: 0,
          locate: '',
        ),
      );
    }
    return chapters;
  }

  /// 章的结束页（不含）；最后一章可为不足 [kPdfPagesPerChapter] 页。
  int _chapterEnd(int start) {
    final int next = start + kPdfPagesPerChapter;
    return next < _pageCount ? next : _pageCount;
  }

  /// 目录标题：`第 X–Y 页`；单页章写 `第 X 页`（1 基展示，与 CBZ「第 N 页」同风格）。
  String _titleFor(int start, int end) => end - start == 1
      ? '第 ${start + 1} 页'
      : '第 ${start + 1}–$end 页';

  /// 解析页资源键（`p{n}`，n 为 0 基页索引）；非法键返回 `null`。
  int? _pageIndexOf(String href) {
    if (href.length <= kPdfPageKeyPrefix.length) return null;
    if (href.codeUnitAt(0) != 0x70 /* 'p' */) return null;
    for (int i = 1; i < href.length; i++) {
      final int c = href.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return null; // 非数字
    }
    return int.tryParse(href.substring(1));
  }

  /// 渲染一页为 PNG 字节。
  ///
  /// **非驻留**（`PERF-02` ①）：每次现渲染，位图在引擎实现内当场释放；
  /// 失败返回 `null`（阅读页图片分支已有缺图兜底，不炸阅读）。
  Future<Uint8List?> _renderPage(int pageIndex, int widthPx) async {
    final PdfEngineDocument? document = _document;
    if (_disposed || document == null) return null;
    try {
      return await document.renderPagePng(pageIndex, widthPx: widthPx);
    } catch (_) {
      return null; // 防引擎实现漏收敛异常：坏页不给上层抛
    }
  }
}
