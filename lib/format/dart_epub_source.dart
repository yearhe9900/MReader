// EPUB 的纯 Dart [BookSource] 实现（`'dart-epub'`）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`，只吃 bytes。
// M3.5 若把解压层 Rust 化，会新增 `RustEpubSource` 实现同一接口，本文件保持不动。
//
// ⚠️ `PERF-01`（解析移出主 isolate，`M2a-T06` 已接线）**不是**「把本对象直接丢进
//    `compute()`」——本对象持有的 `EpubBook.sections[i]` 带 `loadBytes` 闭包、
//    `OpfView.readEntry` 也是闭包，**闭包不可**被 `SendPort` 序列化。已接线的做法
//    （[_parsedOnce]）：经 `IsolateRunner` 在后台 isolate 跑 `parseEpubStructureTask`
//    （纯数据）→ 结构经信封传回 → 由持有原始 `bytes` 的**本 isolate** 调
//    `bindEpubResult` 绑定（见 `lib/epub/epub_parser.dart` 顶部说明与
//    `docs/schedule.md` 的 M2a-T06 勘误）。
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../epub/epub_parser.dart';
import '../epub/section_extractor.dart';
import '../epub/zip_paths.dart';
import '../meta/epub_meta.dart';
import '../meta/meta_source.dart' show kUnknownAuthor;
import '../model/epub_book.dart';
import '../task/isolate_runner.dart';
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
  DartEpubSource({
    required this.fileName,
    required this.bytes,
    this.runner = const IsolateRunner(),
  });

  /// 原始文件名（书名缺失时兜底显示；错误细节里也用）。
  final String fileName;

  /// EPUB 的完整字节。
  final Uint8List bytes;

  /// isolate 派发器（`PERF-01`）：默认派真实后台 isolate，测试可注入 spy / 故障 runner。
  final IsolateRunner runner;

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
  /// 返回 [EpubParseResult]（结构 + `OpfView`）。
  /// **已释放时返回 `null`**（不再触发解析）；竞态中若解析在 dispose 之后才完成，
  /// 也返回 `null` 且**不写回** [_parsed]。
  Future<EpubParseResult?> _parsedOnce() async {
    if (_disposed) return null;
    final EpubParseResult? cached = _parsed;
    if (cached != null) return cached;
    final EpubParseResult parsed = await (_loading ??= _parseOffloaded());
    if (_disposed) return null;
    _parsed = parsed;
    return parsed;
  }

  /// `PERF-01` 接线：结构解析在**后台 isolate**（纯数据往返），绑定在**本 isolate**
  /// （闭包从不出境）；派发失败经 [IsolateRunner.runWithFallback] 回落本 isolate 现跑，
  /// 业务错误（[EpubParseOutcome] 信封）与旧直解析路径同型同码。
  Future<EpubParseResult> _parseOffloaded() async {
    final EpubParseOutcome outcome =
        await runner.runWithFallback<EpubParseRequest, EpubParseOutcome>(
      parseEpubStructureTask,
      EpubParseRequest(bytes, fileName: fileName),
      debugLabel: 'mreader-epub-parse',
    );
    final MReaderFormatException? error = outcome.error;
    if (error != null) throw error; // 业务错误：原样抛（与旧路径一致）
    final EpubStructure? structure = outcome.structure;
    if (structure == null) {
      // 不变量：无错必有结构。信封被破坏按坏文件处理。
      throw const MReaderFormatException(FormatErrorCode.corruptFile);
    }
    return bindEpubResult(bytes, structure);
  }

  Future<EpubBook?> _bookOnce() async => (await _parsedOnce())?.book;

  @override
  Future<BookMeta> load() async {
    final EpubParseResult? parsed = await _parsedOnce();
    if (parsed == null) return _disposedMeta; // 已释放 / 竞态
    // `META-02/03`：经 `lib/meta/epub_meta.dart` 产 meta——四来源优先级链（命中即停）、
    // 多作者稳定顺序整体保留、封面候选 -> `PendingCover`（真实字节 + 真实格式）。
    // 纯 Dart（不引 Flutter / dart:io）；此处 `opfView` 含 `readEntry` 闭包，**不可**跨
    // isolate——`PERF-01` 已由 [_parsedOnce] 完成「后台跑纯数据结构、本 isolate 绑定」。
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
      // `CNT-05`（linear="no" 可见并标注）：
      //   · 目录已覆盖的非主线章：标题追加「（非主线）」；
      //   · 未被目录覆盖的非主线章：按平坦目录**补入**（同样标注），
      //     保证非主线内容可从章节表进入；主线目录项的顺序不动。
      final List<Chapter> out = <Chapter>[];
      final Set<String> covered = <String>{};
      for (final Chapter chapter in book.toc) {
        covered.add(_matchKey(chapter.href));
        final EpubSection? section = _sectionByHref(book, chapter.href);
        final bool nonLinear = section != null && !section.linear;
        out.add(nonLinear ? _markNonLinear(chapter) : chapter);
      }
      for (int i = 0; i < book.sections.length; i++) {
        final EpubSection section = book.sections[i];
        if (section.linear) continue;
        if (covered.contains(_matchKey(section.href))) continue;
        out.add(_flatChapter(
          section,
          i,
          nonLinear: true,
          title: book.flatTitles[section.href],
        ));
      }
      // 包一层 unmodifiable，避免把 EpubBook 内部列表泄漏给调用方。
      result = List<Chapter>.unmodifiable(out);
    } else {
      // 无目录：降级为「按 spine 的平坦目录」（RD-01 ④）。
      // `CNT-05`：`linear="no"` 章节同样保留，标题追加「（非主线）」。
      // 标题走 [EpubBook.flatTitles] 预取（PERF-01 残余项：解析 isolate 一次取好，
      // 此处零解压）；手造 EpubBook 未预取（miss）时回退现场解压（旧行为）。
      final List<Chapter> flat = <Chapter>[];
      for (int i = 0; i < book.sections.length; i++) {
        final EpubSection section = book.sections[i];
        flat.add(_flatChapter(
          section,
          i,
          nonLinear: !section.linear,
          title: book.flatTitles[section.href],
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

    // baseDir：XHTML 文件所在目录，用于把 <img src> 的相对路径归一化为绝对包内路径。
    final String baseDir = p.posix.dirname(section.href);
    final List<String> paragraphs = chapter.locate.isEmpty
        ? extractSection(section.rawBytes, baseDir: baseDir).paragraphs
        : extractParagraphsFromFragment(section.rawBytes, chapter.locate,
            baseDir: baseDir);

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
  Future<Uint8List?> readResource(String href) async {
    if (_disposed) return null;
    final EpubParseResult? parsed = await _parsedOnce();
    if (parsed == null || _disposed) return null;
    // OpfView.readEntry 按需解压（lazyEntryLoader），不常驻全书图片字节（PERF-02）。
    return parsed.opfView.readEntry?.call(href);
  }

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

  /// 按 href 精确反查 spine section（**不做**同序号兜底）。
  ///
  /// 「linear=no 是否已被目录覆盖」这类判断只能按 href 匹配——目录项数与
  /// spine 项数可以不相等，按索引兜底会错位（`CNT-05`）。
  EpubSection? _sectionByHref(EpubBook book, String href) {
    final String target = _matchKey(href);
    for (final EpubSection section in book.sections) {
      if (_matchKey(section.href) == target) return section;
    }
    return null;
  }

  /// 由 [Chapter] 定位 spine section（供 `content(i)` / `search()` 用）。
  ///
  /// **不能按索引一一对应**：目录项数与 spine 项数可以不相等（目录常合并/拆分章节）。
  /// 匹配用「百分号解码 + 小写」归一化（[_sectionByHref]，容忍 `fx03` 那种大小写
  /// 不一致的脏书）；实在匹配不上时退回同序号 section（best-effort，保证
  /// `content(i)` 不抛异常）。
  EpubSection? _sectionFor(EpubBook book, Chapter chapter, int chapterIndex) {
    final EpubSection? byHref = _sectionByHref(book, chapter.href);
    if (byHref != null) return byHref;
    if (chapterIndex >= 0 && chapterIndex < book.sections.length) {
      return book.sections[chapterIndex];
    }
    return null;
  }

  /// href 的匹配键：百分号解码 + 转小写。
  String _matchKey(String href) => decodePercentPath(href).toLowerCase();
}

/// `linear="no"`（非主线）章节的目录标题后缀（`CNT-05`）。
const String kNonLinearTitleSuffix = '（非主线）';

/// 由 spine section 生成一条平坦目录项（无目录降级 / linear=no 补入共用）。
///
/// [title] 的三级语义（`PERF-01` 残余项）：
///   · `null` —— 未预取（有目录书的 linear=no 补入 / 手造 EpubBook）：现场解压取标题
///     （旧行为；预取表 [EpubBook.flatTitles] 仅在 toc 为空时填充）；
///   · `''` —— 已预取但该章无标题：直接补「第 N 章」占位，**不再解压**；
///   · 非空 —— 预取标题，直接采用。
/// 无目录书一律走预取路径，`chapters()` 不再逐章「解压 + HTML 解析」（大书冻结源）。
Chapter _flatChapter(
  EpubSection section,
  int index, {
  required bool nonLinear,
  String? title,
}) {
  final String resolved = title ?? extractSection(section.rawBytes).title;
  final String base = resolved.isNotEmpty ? resolved : '第 ${index + 1} 章';
  return Chapter(
    href: section.href,
    title: nonLinear ? '$base$kNonLinearTitleSuffix' : base,
    level: 0,
    locate: '',
  );
}

/// 给目录项标题追加「（非主线）」标注（`CNT-05`；Chapter 无 copyWith，重建一条）。
Chapter _markNonLinear(Chapter chapter) => Chapter(
      href: chapter.href,
      title: '${chapter.title}$kNonLinearTitleSuffix',
      level: chapter.level,
      locate: chapter.locate,
    );
