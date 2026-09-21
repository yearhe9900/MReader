// EPUB 的纯 Dart [BookSource] 实现（`'dart-epub'`）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`，只吃 bytes ——
// 这正是 `PERF-01`（解析移出主 isolate）要求的形状：整个对象可以直接丢进 `compute()`。
// M3.5 若把解压层 Rust 化，会新增 `RustEpubSource` 实现同一接口，本文件保持不动。
import 'dart:typed_data';

import '../epub/epub_parser.dart';
import '../epub/section_extractor.dart';
import '../epub/zip_paths.dart';
import '../model/epub_book.dart';
import 'book_source.dart';

/// 打开本地 EPUB（纯字节入口）。
class DartEpubSource implements BookSource {
  DartEpubSource({required this.fileName, required this.bytes});

  /// 原始文件名（书名缺失时兜底显示；错误细节里也用）。
  final String fileName;

  /// EPUB 的完整字节。
  final Uint8List bytes;

  EpubBook? _book;
  Future<EpubBook>? _loading;
  List<Chapter>? _chapters;
  int? _totalChars;
  bool _disposed = false;

  @override
  String get implId => 'dart-epub';

  /// 惰性解析一次并缓存：构造**不解析**（打开的响应速度由调用方掌控）。
  Future<EpubBook> _bookOnce() {
    final EpubBook? cached = _book;
    if (cached != null) return Future<EpubBook>.value(cached);
    return _loading ??= parseEpub(bytes, fileName: fileName).then(
      (EpubBook book) {
        _book = book;
        return book;
      },
    );
  }

  @override
  Future<BookMeta> load() async {
    final EpubBook book = await _bookOnce();
    // 说明：本批（M1-T02A）只做「OPF 优先」这一来源。
    // M1-T05（META-02）会在这里接入**四来源优先级链**
    // （OPF -> 文件名 -> 合成 -> 用户），并按来源回填 titleOrigin / authorOrigin；
    // coverBytes 亦由 M1-T05 的封面链路填充，本批恒为 null。
    return BookMeta(
      title: book.title,
      author: book.author,
      language: book.language,
      coverBytes: null,
      titleOrigin: book.title.isEmpty ? 'none' : 'opf:dc:title',
      authorOrigin: book.author.isEmpty ? 'none' : 'opf:dc:creator',
      coverOrigin: 'none',
    );
  }

  @override
  Future<List<Chapter>> chapters() async {
    final List<Chapter>? cached = _chapters;
    if (cached != null) return cached;

    final EpubBook book = await _bookOnce();
    final List<Chapter> result;

    if (book.toc.isNotEmpty) {
      // 有目录：原样映射（层级来自真实嵌套深度）。
      result = book.toc
          .map((entry) => Chapter(
                href: entry.href,
                title: entry.title,
                level: entry.level,
                locate: entry.locate,
              ))
          .toList(growable: false);
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
    final EpubBook book = await _bookOnce();
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
    final EpubBook book = await _bookOnce();
    int sum = 0;
    for (final EpubSection section in book.sections) {
      for (final String paragraph in extractSection(section.rawBytes).paragraphs) {
        sum += paragraph.length;
      }
    }
    _totalChars = sum;
    return sum;
  }

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) async* {
    if (query.isEmpty) return;

    final List<Chapter> chapterList = await chapters();
    if (chapterList.isEmpty) return;
    final EpubBook book = await _bookOnce();
    final int total = chapterList.length;

    for (int i = 0; i < total; i++) {
      if (cancel.isCancelled) return;
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
    _book = null;
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
