// CBR 的 [BookSource] 实现（`'dart-cbr'`，`FMT-03` / `META-11` ③）。
//
// ## Q5 退化拍板（「导入即拒绝」口径）
//
// Dart 生态无 rar 解压 → 退化为「**识别 + 明确提示**」，**与加密文件的处理一致**：
// [load()] 抛 [FormatErrorCode.cbrUnsupported]（中文文案含「转换为 CBZ」指引），
// **导入即拒绝**（`ImportService.import` 的 `finally` 保证 dispose，错误原样冒到 UI），
// 书不入库——「不做半成品」。`META-11` ③ 如实记录为：退化模式下无封面链路
// （书不入库），错误单点在格式层、不波及封面 / 渲染任何环节。
//
// ## 升级路径（`FMT-03` ②「若支持，行为与 CBZ 一致」）
//
// 解压能力收敛在 [RarExtractor]（`lib/platform/rar_extractor.dart`）：将来接入
// 平台通道 / FFI 实现（unarr、libarchive、p7zip 等）后注入可用实现，即自动升级为
// 与 `CbzSource` 一致的行为（每页一章 / 自然序 / 首页图封面），调用方零改动。
// 当前**无任何生产实现**（[UnavailableRarExtractor]）；可用分支由假实现测试锁定。
import 'dart:typed_data';

import '../meta/meta_source.dart';
import '../meta/txt_meta.dart';
import '../platform/rar_extractor.dart';
import 'book_source.dart';
import 'image_pages.dart';
import 'natural_sort.dart';

/// 打开本地 CBR（纯字节入口）。
///
/// ## dispose 契约（与 `CbzSource` 一致）
///
/// [dispose] 之后所有公开方法返回优雅空结果、绝不抛异常。
class CbrSource implements BookSource {
  CbrSource({
    required this.fileName,
    required this.bytes,
    this.extractor = const UnavailableRarExtractor(),
  });

  /// 原始文件名（META-04 文件名规则链的书名 / 作者来源）。
  final String fileName;

  /// CBR（RAR）的完整字节。
  final Uint8List bytes;

  /// RAR 解压能力（`Q5`：默认不可用；可用时本类行为与 CBZ 一致）。
  final RarExtractor extractor;

  bool _disposed = false;
  Future<void>? _preparing;
  List<String>? _pages;
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
  String get implId => 'dart-cbr';

  @override
  Future<BookMeta> load() async {
    await _ensurePrepared(); // 能力不可用时在这里抛 cbrUnsupported（导入即拒绝）
    final List<String>? pages = _pages;
    if (_disposed || pages == null || pages.isEmpty) return _disposedMeta;

    final BookMeta base = buildTxtMeta(fileName: fileName);

    // META-11：与 CBZ 同口径——自然序首页图为封面（仅能力可用时可达）。
    CoverRef cover = const NoCover();
    MetaOrigin coverOrigin = MetaOrigin.none;
    final Uint8List? first = await _readPage(pages.first);
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
      return const ChapterContent.imagePages(<String>[]);
    }
    return ChapterContent.imagePages(<String>[pages[chapterIndex]]);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: true,
        hasFootnotes: false,
        reflowable: false,
        searchable: false,
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

  // `implements BookSource` 不继承接口默认实现：显式覆写，保持 null（不支持）。
  @override
  Future<List<int>?> chapterCharCounts() async => null;

  @override
  Future<List<int>?> chapterWeightEstimates() async => null;

  @override
  Future<Uint8List?> readResource(String href) async {
    try {
      await _ensurePrepared();
    } catch (_) {
      return null; // 尽力而为：退化模式（能力不可用）恒为 null
    }
    if (_disposed) return null;
    return _readPage(href);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _preparing = null;
    _pages = null;
    _chapters = null;
  }

  /// 是否已释放（供体检 / 测试观察）。
  bool get isDisposed => _disposed;

  // ---------------------------------------------------------------------------
  // 准备（建页表），Future 去重
  // ---------------------------------------------------------------------------

  Future<void> _ensurePrepared() {
    if (_disposed) return Future<void>.value();
    return _preparing ??= _prepare();
  }

  Future<void> _prepare() async {
    if (!extractor.isAvailable) {
      // Q5 退化（与加密文件处理一致）：识别为 CBR，但明确提示暂不支持。
      throw MReaderFormatException(
        FormatErrorCode.cbrUnsupported,
        detail: fileName,
      );
    }
    final List<String> entries = await extractor.listImageEntries(bytes);
    final List<String> pages = <String>[
      for (final String name in entries)
        if (isImagePageName(name.toLowerCase())) name,
    ];
    pages.sort(compareNatural); // META-11 ②：自然序
    if (pages.isEmpty) {
      throw const MReaderFormatException(FormatErrorCode.noImagePages);
    }
    final List<Chapter> chapters = <Chapter>[
      for (int i = 0; i < pages.length; i++)
        Chapter(href: pages[i], title: '第 ${i + 1} 页', level: 0, locate: ''),
    ];
    if (_disposed) return; // 竞态：解析完成时已释放，不写回
    _pages = pages;
    _chapters = List<Chapter>.unmodifiable(chapters);
  }

  Future<Uint8List?> _readPage(String name) => extractor.readEntry(bytes, name);
}
