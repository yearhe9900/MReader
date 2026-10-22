// Rust 解析内核的 `BookSource` 适配层（图书解析核心移植，2026-10-22）。
//
// ## 定位
//
// 解析全程走 vendored `rrk-*` 内核（`rust/vendor/`，经 FRB 桥
// `lib/src/rust/api/kernel.dart`）：EPUB / TXT / MOBI-AZW3 的打开、分章、
// 正文抽取、资源读取都在 Rust 侧完成；本类只做「内核数据面 → MReader 模型」
// 的映射与 [BookSource] 契约适配。
//
// ## ⚠️ 本类**不是** compute() 安全的纯 Dart 类
//
// `lib/format/**` 的「不 import Flutter / dart:io」纪律（`PERF-01`）服务的是
// 「解析丢 isolate」的 Dart 源；本类持 FFI 书句柄（绑定当前 isolate），走的是
// 架构 §A.1「RUST-03 衔接说明」里的另一条路——**不进 compute()**，由
// [BookRegistry] 按探测结果择一。这与 Dart 源并存不冲突。
//
// ## 与纯 Dart 抽取的形状对齐
//
// · 段落文本里的图片占位标记 `\x00IMG:<包内绝对路径>\x00`（`imageSrcsOf`
//   同一口径）；行内图片内嵌段落文本，块级图片自成一段；
// · 分割线只切段、不产段落；引用块摊平为内层段落；
// · **已知落差**：内核内容模型暂无链接，EPUB 内链在本路径呈纯文本
//   （纯 Dart 路径有 `\x00A:\x00` 可点链接标记）。
import 'dart:typed_data';

import '../meta/meta_source.dart';
import '../src/rust/api/kernel.dart' as rk;
import 'book_source.dart';

/// 内核块表 → 段落序列（与纯 Dart 抽取的段落形状对齐）。
///
/// · 空白段丢弃（含全空白的标题/段落）；
/// · 图片段的文本即 `\x00IMG:<key>\x00` 标记串（`imageSrcsOf` 同一口径），保留；
/// · 引用块摊平、分割线丢弃都在 Rust 桥完成，这里只见扁平块表。
///
/// 顶层函数形态 = 映射纯函数的测试缝（`test/format/rust_kernel_source_test.dart`）。
List<String> paragraphsFromBlocks(List<rk.RkBlock> blocks) {
  return <String>[
    for (final rk.RkBlock b in blocks)
      if (b.text.trim().isNotEmpty) b.text,
  ];
}

/// Rust 解析内核书源：一个实例 = 一本打开的书（内核句柄）。
class RustKernelSource implements BookSource {
  /// 私有构造：`this._x` 初始化形参只允许出现在**位置**参数上，故用位置形参。
  RustKernelSource._(this.fileName, this.bytes, this._handle, this._meta);

  /// 原始文件名（元数据兜底用，`RD-04` 口径的展示名）。
  final String fileName;

  /// 整本字节（`searchSpec` 后台重建用；与其他源同一口径）。
  final Uint8List bytes;

  final BigInt _handle;
  final rk.RkMeta _meta;

  List<rk.RkChapter>? _chapters;
  List<int>? _charCounts;
  List<int>? _weights;

  /// 打开一本书。失败抛异常（[BookRegistry] 捕获后回落纯 Dart 实现）。
  ///
  /// [filePath] 可选：给了就走内核路径型打开（文件读入 Rust，不经 FFI 拷贝）；
  /// 不给则字节型打开（与 Dart 源同口径：构造时已持有全量字节）。
  static Future<RustKernelSource> open({
    required String fileName,
    required Uint8List bytes,
    String? filePath,
  }) async {
    final BigInt handle = filePath != null
        ? await rk.kernelOpenPath(path: filePath)
        : await rk.kernelOpenBytes(name: fileName, data: bytes);
    try {
      final rk.RkMeta meta = await rk.kernelMeta(handle: handle);
      return RustKernelSource._(fileName, bytes, handle, meta);
    } catch (_) {
      await rk.kernelClose(handle: handle).catchError((_) {});
      rethrow;
    }
  }

  @override
  String get implId => switch (_meta.format) {
        'EPUB' => 'rust-epub',
        'TXT' => 'rust-txt',
        'MOBI' || 'AZW3' => 'rust-mobi',
        final String other => 'rust-${other.toLowerCase()}',
      };

  @override
  Future<BookMeta> load() async {
    final String title = fallbackTitle(_meta.title, fileStem(fileName));
    final String author = fallbackAuthor(_meta.authors.join('、'));
    final bool hasTitleMeta = _meta.title.trim().isNotEmpty;

    CoverRef cover = const NoCover();
    if (_meta.coverKey != null) {
      final rk.RkResource? res =
          await rk.kernelCover(handle: _handle);
      if (res != null && res.data.isNotEmpty) {
        final CoverFormat format = sniffCoverFormat(res.data);
        if (format != CoverFormat.unknown) {
          cover = PendingCover(Uint8List.fromList(res.data), format);
        }
      }
    }

    return BookMeta(
      title: title,
      titleOrigin: hasTitleMeta ? MetaOrigin.metadata : MetaOrigin.filename,
      author: author,
      authorOrigin:
          _meta.authors.isNotEmpty ? MetaOrigin.metadata : MetaOrigin.none,
      // 内核书目暂无简介字段（EPUB OPF 的 description 等），记 none。
      intro: '',
      introOrigin: MetaOrigin.none,
      cover: cover,
      coverOrigin: cover is NoCover ? MetaOrigin.none : MetaOrigin.metadata,
      language: _meta.language ?? '',
      auto: BookMetaAuto(title: title, author: author, intro: ''),
    );
  }

  Future<List<rk.RkChapter>> _chapterList() async =>
      _chapters ??= await rk.kernelChapters(handle: _handle);

  @override
  Future<List<Chapter>> chapters() async {
    final List<rk.RkChapter> list = await _chapterList();
    return <Chapter>[
      for (int i = 0; i < list.length; i++)
        Chapter(
          href: list[i].href,
          // 无标题章补「第 N 章」占位（与 dart_epub_source 的占位口径一致）。
          title: fallbackTitle(list[i].title ?? '', '第 ${i + 1} 章'),
          level: 0,
          locate: '',
        ),
    ];
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    final List<rk.RkChapter> list = await _chapterList();
    if (chapterIndex < 0 || chapterIndex >= list.length) {
      return const ChapterContent.paragraphs(<String>[]);
    }
    final rk.RkChapterText text = await rk.kernelLoadChapter(
      handle: _handle,
      chapterId: list[chapterIndex].id,
    );
    return ChapterContent.paragraphs(paragraphsFromBlocks(text.blocks));
  }

  @override
  SourceCapabilities capabilities() => SourceCapabilities(
        hasImages: _meta.format != 'TXT',
        hasFootnotes: false,
        reflowable: true,
        searchable: true,
        charCountSupported: true,
      );

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) async* {
    if (query.isEmpty) return;
    final String needle = query.toLowerCase();
    final List<rk.RkChapter> list = await _chapterList();
    for (int i = 0; i < list.length; i++) {
      if (cancel.isCancelled) return;
      yield SearchEvent.progress(i / list.length);
      final List<String> paragraphs = (await content(i)).paragraphList;
      int offset = 0;
      for (final String p in paragraphs) {
        final int at = p.toLowerCase().indexOf(needle);
        if (at >= 0) {
          yield SearchEvent.hit(SearchHit(
            chapterIndex: i,
            chapterTitle: list[i].title ?? '第 ${i + 1} 章',
            offset: offset + at,
            context: p,
          ));
        }
        offset += p.length;
      }
    }
  }

  @override
  SearchBookSpec? get searchSpec => SearchBookSpec(fileName: fileName, bytes: bytes);

  /// 精确口径（统计用；**阅读页禁调**，见 [BookSource.chapterCharCounts]）：
  /// 逐章加载后按「各段 `paragraph.length` 之和」计，与 Dart 源同一计数规则。
  @override
  Future<List<int>?> chapterCharCounts() async {
    final List<int>? cached = _charCounts;
    if (cached != null) return cached;
    final List<rk.RkChapter> list = await _chapterList();
    final List<int> out = List<int>.filled(list.length, 0);
    for (int i = 0; i < list.length; i++) {
      int sum = 0;
      for (final String p in (await content(i)).paragraphList) {
        sum += p.length;
      }
      out[i] = sum;
    }
    return _charCounts = out;
  }

  @override
  Future<int?> totalCharCount() async {
    final List<int> counts =
        await chapterCharCounts() ?? const <int>[];
    return counts.fold<int>(0, (int a, int b) => a + b);
  }

  /// 廉价权重（内核零解压估算；阅读页进度百分比专用）。
  @override
  Future<List<int>?> chapterWeightEstimates() async {
    final List<int>? cached = _weights;
    if (cached != null) return cached;
    final List<rk.RkWeight> w = await rk.kernelWeights(handle: _handle);
    // 按章序对齐（内核权重表按 id 升序返回；仍显式排一次防实现漂移）。
    final List<rk.RkWeight> sorted = w.toList()..sort((a, b) => a.id.compareTo(b.id));
    return _weights = <int>[for (final rk.RkWeight e in sorted) e.charLen];
  }

  @override
  Future<Uint8List?> readResource(String href) async {
    final rk.RkResource? res =
        await rk.kernelLoadResource(handle: _handle, key: href);
    return res == null ? null : Uint8List.fromList(res.data);
  }

  @override
  Future<void> dispose() async {
    _chapters = null;
    _charCounts = null;
    _weights = null;
    await rk.kernelClose(handle: _handle);
  }
}
