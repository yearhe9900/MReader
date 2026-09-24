// CBZ 的纯 Dart [BookSource] 实现（`'dart-cbz'`，`FMT-02` / `META-11`）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`，只吃 bytes。
//
// ## 模型映射（`FMT-02` 验收①③ / `RD-04`）
//
// · **每张图片页 = 一章**：`Chapter.href` = zip 条目路径（稳定身份，`RD-04`/`SYNC-02`
//   对齐），`title` = `第 N 页`（N = 自然序页号）。「进度按页记录」（验收③）于是
//   天然成立——进度真值 `(chapterHref, chapterPos)` 的章粒度即页粒度；
// · **正文 = 图片页序列**：`ChapterContent.imagePages([条目路径])`（与段落互斥，
//   见 `chapter_content.dart` 的类型约束）；整页渲染由阅读页图片页分支负责
//   （点页全屏缩放，验收②「缩放后不糊」用原始字节解码、不降采样）；
// · **封面 = 自然序第一张图片页**（`META-11` ①②）：原始字节 + `sniffCoverFormat`
//   魔数嗅探的真实格式（`META-05`）→ [PendingCover]，落盘仍归 `CoverStore`。
//
// ## 内存（`PERF-02` ① 非驻留解压）
//
// 图片字节经 `lazyEntryLoader` **按需现解、不常驻**（绝不用 `ArchiveFile.content`——
// 一次解压即永久缓存在条目上）；阅读页侧再过 `ImageCacheLRU`（50MB 上界）兜字节缓存。
// `load()` 只建页表（条目名）与解压闭包表，O(页数) 轻量结构、无文本解码/分章计算，
// 主 isolate 直做即可（与 TXT 的 `PERF-01` isolate 派发不同因）。
//
// ## 排序与条目过滤（`META-11` ② / `FMT-02` ①）
//
// 图片页按**自然序**排列（`10.jpg` 在 `2.jpg` 之后，`natural_sort.dart`）；
// `__MACOSX/`、隐藏文件（`.DS_Store` / `._*`）、目录项与非图片扩展名一律排除。
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../epub/zip_paths.dart';
import '../meta/meta_source.dart';
import '../meta/txt_meta.dart';
import 'book_source.dart';
import 'image_pages.dart';
import 'natural_sort.dart';

/// 打开本地 CBZ（纯字节入口）。
///
// ## dispose 契约（与 `DartTxtSource` / `DartEpubSource` 一致）
//
/// [dispose] 之后、以及竞态恢复后，所有公开方法返回优雅空结果、绝不抛异常：
/// `load()` → 最小 [BookMeta]（origins 全 `MetaOrigin.none`）；`chapters()` /
/// `content()` → 空；`readResource()` → `null`。每个 `await` 恢复后重查 [_disposed]。
class CbzSource implements BookSource {
  CbzSource({
    required this.fileName,
    required this.bytes,
  });

  /// 原始文件名（META-04 文件名规则链的书名 / 作者来源）。
  final String fileName;

  /// CBZ（zip）的完整字节。
  final Uint8List bytes;

  bool _disposed = false;
  Future<void>? _preparing;

  /// 自然序页表：归一化条目名（= `Chapter.href` / `imagePages` 元素）。
  List<String>? _pages;
  List<Chapter>? _chapters;

  /// 小写名 → 真实条目名（`resolveEntryName` 三试探的索引）。
  Map<String, String> _lowerIndex = <String, String>{};

  /// 真实条目名 → 非驻留解压闭包（`PERF-02` ①）。
  final Map<String, Uint8List Function()> _loaders =
      <String, Uint8List Function()>{};

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
  String get implId => 'dart-cbz';

  @override
  Future<BookMeta> load() async {
    await _ensurePrepared();
    final List<String>? pages = _pages;
    if (_disposed || pages == null || pages.isEmpty) return _disposedMeta;

    // 书名 / 作者 / 来源标记：META-04 文件名规则链（与 TXT 同源）。
    final BookMeta base = buildTxtMeta(fileName: fileName);

    // META-11 ①②：封面 = 自然序第一张图片页，魔数嗅探真实格式（META-05）。
    CoverRef cover = const NoCover();
    MetaOrigin coverOrigin = MetaOrigin.none;
    final Uint8List? first = _readPage(pages.first);
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
    final List<String>? pages = _pages;
    if (_disposed || pages == null) {
      return const ChapterContent.imagePages(<String>[]);
    }
    if (chapterIndex < 0 || chapterIndex >= pages.length) {
      return const ChapterContent.imagePages(<String>[]); // 越界不抛异常
    }
    // 每页一章：正文 = 单元素图片页序列（与段落互斥的类型约束）。
    return ChapterContent.imagePages(<String>[pages[chapterIndex]]);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: true,
        hasFootnotes: false,
        reflowable: false, // 图片页不重排（PDF / CBZ 为 false 的既有口径）
        searchable: false, // 无文本层，全书搜索不适用
        charCountSupported: false,
      );

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) =>
      const Stream<SearchEvent>.empty();

  /// 图片格式给不出可序列化源描述（也不可搜）→ `null`。
  /// （`BookSource.searchSpec` 的默认实现**不跨 `implements` 继承**，显式写出。）
  @override
  SearchBookSpec? get searchSpec => null;

  @override
  Future<int?> totalCharCount() async => null;

  @override
  Future<Uint8List?> readResource(String href) async {
    try {
      await _ensurePrepared();
    } catch (_) {
      return null; // 资源读取尽力而为：坏包不把业务错误抛给渲染层
    }
    if (_disposed) return null;
    final String? name = resolveEntryName(_lowerIndex, href);
    if (name == null) return null;
    return _readPage(name);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _preparing = null;
    _pages = null;
    _chapters = null;
    _lowerIndex = <String, String>{};
    _loaders.clear();
  }

  /// 是否已释放（供体检 / 测试观察）。
  bool get isDisposed => _disposed;

  // ---------------------------------------------------------------------------
  // 准备（建页表），Future 去重
  // ---------------------------------------------------------------------------

  Future<void> _ensurePrepared() {
    if (_disposed) return Future<void>.value(); // 已释放：不再触发解析
    return _preparing ??= _prepare();
  }

  Future<void> _prepare() async {
    if (bytes.isEmpty) {
      throw const MReaderFormatException(FormatErrorCode.emptyFile);
    }
    final Archive? archive = tryDecodeZip(bytes);
    if (archive == null) {
      throw const MReaderFormatException(FormatErrorCode.corruptFile);
    }
    final Map<String, String> lowerIndex = <String, String>{};
    final List<String> pages = <String>[];
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final String name = normalizeZipPath(file.name);
      if (name.isEmpty) continue;
      final String lower = name.toLowerCase();
      // macOS 打包垃圾与隐藏文件不算页（Finder 压缩的 CBZ 常带 `__MACOSX/`）。
      if (lower.startsWith('__macosx/')) continue;
      final String base = lower.substring(lower.lastIndexOf('/') + 1);
      if (base.startsWith('.')) continue;
      if (!isImagePageName(lower)) continue;
      if (lowerIndex.containsKey(lower)) continue; // 大小写撞名：只收第一件
      lowerIndex[lower] = name;
      _loaders[name] = lazyEntryLoader(file);
      pages.add(name);
    }
    pages.sort(compareNatural); // META-11 ②：自然序（`10.jpg` 不插到 `2.jpg` 前）
    if (pages.isEmpty) {
      throw const MReaderFormatException(FormatErrorCode.noImagePages);
    }
    final List<Chapter> chapters = <Chapter>[
      for (int i = 0; i < pages.length; i++)
        Chapter(href: pages[i], title: '第 ${i + 1} 页', level: 0, locate: ''),
    ];
    if (_disposed) return; // 竞态：解析完成时已释放，不写回
    _lowerIndex = lowerIndex;
    _pages = pages;
    _chapters = List<Chapter>.unmodifiable(chapters);
  }

  /// 按真实条目名取页字节（非驻留解压闭包，每次现解）。
  Uint8List? _readPage(String name) {
    final Uint8List Function()? loader = _loaders[name];
    return loader == null ? null : loader();
  }
}
