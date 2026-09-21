// EPUB 的纯 Dart [BookSource] 实现（`'dart-epub'`）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`，只吃 bytes ——
// 这正是 `PERF-01`（解析移出主 isolate）要求的形状：整个对象可以直接丢进 `compute()`。
// M3.5 若把解压层 Rust 化，会新增 `RustEpubSource` 实现同一接口，本文件保持不动。
import 'dart:typed_data';

import '../epub/epub_parser.dart';
import '../epub/section_extractor.dart';
import '../epub/zip_paths.dart';
import '../meta/epub_meta.dart';
import '../meta/meta_source.dart' show kUnknownAuthor;
import '../model/epub_book.dart';
import 'book_source.dart';

/// 打开本地 EPUB（纯字节入口）。
///
/// ## dispose 契约（与 [DartTxtSource] 一致，`RUST-01` 上层无感）
///
/// [dispose] 之后、以及「调用与 dispose 竞态」时，所有公开方法都**返回优雅空结果、
/// 绝不抛异常**：`load()` → 最小 [BookMeta]（title `'未命名'`、origins 全 `MetaOrigin.none`）；
/// `chapters()` / `content()` → 空；`search()` → 流立即结束；`totalCharCount()` → `null`。
/// 实现方式：**每个 `await` 恢复后重查 [_disposed]**（并让 [_bookOnce] 释放后返回 `null`
/// 而不重新触发解析），不依赖 `!` 断言。
class DartEpubSource implements BookSource {
  DartEpubSource({required this.fileName, required this.bytes});

  /// 原始文件名（书名缺失时兜底显示；错误细节里也用）。
  final String fileName;

  /// EPUB 的完整字节。
  final Uint8List bytes;

  EpubParseResult? _parsed;
  Future<EpubParseResult>? _loading;
  List<Chapter>? _chapters;
  int? _totalChars;
  bool _disposed = false;

  /// 已释放 / 竞态时 `load()` 的最小返回（title 不空、author 不空、origins 全 `none`）。
  ///
  /// **满足 [BookMeta] 自身的不变式**：`author` 不得留空字符串（`META-01`），
  /// 故沿用统一兜底常量 [kUnknownAuthor]，而非 `''`。
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
  String get implId => 'dart-epub';

  /// 惰性解析一次并缓存：构造**不解析**（打开的响应速度由调用方掌控）。
  ///
  /// 返回 [EpubParseResult]（结构 + `OpfView`，**同一次解压**）。
  /// **已释放时返回 `null`**（不再触发解析）；竞态中若解析在 dispose 之后才完成，
  /// 也返回 `null` 且**不写回** [_parsed]。
  Future<EpubParseResult?> _parsedOnce() async {
    if (_disposed) return null;
    final EpubParseResult? cached = _parsed;
    if (cached != null) return cached;
    final EpubParseResult parsed =
        await (_loading ??= parseEpubResult(bytes, fileName: fileName));
    if (_disposed) return null;
    _parsed = parsed;
    return parsed;
  }

  Future<EpubBook?> _bookOnce() async => (await _parsedOnce())?.book;

  @override
  Future<BookMeta> load() async {
    final EpubParseResult? parsed = await _parsedOnce();
    if (parsed == null) return _disposedMeta; // 已释放 / 竞态
    // `META-02/03`：经 `lib/meta/epub_meta.dart` 产 meta——四来源优先级链（命中即停）、
    // 多作者稳定顺序整体保留、封面候选 -> `PendingCover`（真实字节 + 真实格式）。
    // 纯 Dart：可进 `compute()`（`PERF-01`）。
    return buildEpubMeta(opfView: parsed.opfView, fileName: fileName);
  }

  @override
  Future<List<Chapter>> chapters() async {
    final List<Chapter>? cached = _chapters;
    if (cached != null) return cached;

    final EpubBook? book = await _bookOnce();
    if (book == null) return const <Chapter>[]; // 已释放 / 竞态

    final List<Chapter> result;

    if (book.toc.isNotEmpty) {
      // 有目录：**直接使用**解析结果（目录项即章节，类型统一为 Chapter，无需搬运字段）。
      // 包一层 unmodifiable，避免把 EpubBook 内部列表泄漏给调用方。
      result = List<Chapter>.unmodifiable(book.toc);
    } else {
      // 无目录：降级为「按 spine 的平坦目录」（RD-01 ④）。
      final List<Chapter> flat = <Chapter>[];
      for (int i = 0; i < book.sections.length; i++) {
        final EpubSection section = book.sections[i];
        final String title = extractSection(section.rawBytes).title;
        flat.add(Chapter(
          href: section.href,
          title: title.isNotEmpty ? title : '第 ${i + 1} 章',
          level: 0,
          locate: '',
        ));
      }
      result = List<Chapter>.unmodifiable(flat);
    }

    if (_disposed) return const <Chapter>[]; // 竞态：算完已释放
    _chapters = result;
    return result;
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    final List<Chapter> chapterList = await chapters();
    if (chapterIndex < 0 || chapterIndex >= chapterList.length) {
      return const ChapterContent.paragraphs(<String>[]);
    }

    final Chapter chapter = chapterList[chapterIndex];
    final EpubBook? book = await _bookOnce();
    if (book == null) return const ChapterContent.paragraphs(<String>[]);
    final EpubSection? section = _sectionFor(book, chapter, chapterIndex);
    if (section == null) return const ChapterContent.paragraphs(<String>[]);

    final List<String> paragraphs = chapter.locate.isEmpty
        ? extractSection(section.rawBytes).paragraphs
        : extractParagraphsFromFragment(section.rawBytes, chapter.locate);

    return ChapterContent.paragraphs(paragraphs);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: true,
        hasFootnotes: true,
        reflowable: true,
        searchable: true,
        charCountSupported: true,
      );

  @override
  Future<int?> totalCharCount() async {
    final int? cached = _totalChars;
    if (cached != null) return cached;

    // 刻意**不在 load() 里算**：20MB 的书会把打开动作拖慢。
    final EpubBook? book = await _bookOnce();
    if (book == null) return null; // 已释放 / 竞态
    int sum = 0;
    for (final EpubSection section in book.sections) {
      for (final String paragraph in extractSection(section.rawBytes).paragraphs) {
        sum += paragraph.length;
      }
    }
    if (_disposed) return null; // 竞态：算完已释放
    _totalChars = sum;
    return sum;
  }

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) async* {
    if (query.isEmpty) return;

    final List<Chapter> chapterList = await chapters();
    if (_disposed || chapterList.isEmpty) return;
    final EpubBook? book = await _bookOnce();
    if (_disposed || book == null) return;
    final int total = chapterList.length;

    for (int i = 0; i < total; i++) {
      if (cancel.isCancelled || _disposed) return;
      final Chapter chapter = chapterList[i];
      final EpubSection? section = _sectionFor(book, chapter, i);
      final List<String> paragraphs =
          section == null ? const <String>[] : extractSection(section.rawBytes).paragraphs;

      int offset = 0;
      for (final String paragraph in paragraphs) {
        int from = 0;
        while (true) {
          final int at = paragraph.indexOf(query, from);
          if (at < 0) break;
          yield SearchEvent.hit(SearchHit(
            chapterIndex: i,
            chapterTitle: chapter.title,
            offset: offset + at,
            context: paragraph,
          ));
          if (cancel.isCancelled) return;
          from = at + query.length;
        }
        offset += paragraph.length;
      }

      yield SearchEvent.progress((i + 1) / total);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _parsed = null;
    _loading = null;
    _chapters = null;
    _totalChars = null;
  }

  /// 是否已释放（供体检 / 测试观察）。
  bool get isDisposed => _disposed;

  /// 由 [Chapter.href] 反查 spine section。
  ///
  /// **不能按索引一一对应**：目录项数与 spine 项数可以不相等（目录常合并/拆分章节）。
  /// 匹配用「百分号解码 + 小写」归一化，容忍 `fx03` 那种大小写不一致的脏书；
  /// 实在匹配不上时退回同序号 section（best-effort，保证 `content(i)` 不抛异常）。
  EpubSection? _sectionFor(EpubBook book, Chapter chapter, int chapterIndex) {
    final String target = _matchKey(chapter.href);
    for (final EpubSection section in book.sections) {
      if (_matchKey(section.href) == target) return section;
    }
    if (chapterIndex >= 0 && chapterIndex < book.sections.length) {
      return book.sections[chapterIndex];
    }
    return null;
  }

  /// href 的匹配键：百分号解码 + 转小写。
  String _matchKey(String href) => decodePercentPath(href).toLowerCase();
}
