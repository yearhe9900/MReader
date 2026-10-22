// Rust 解析内核的 `BookSource` 适配层（图书解析核心移植，2026-10-22 二次同步）。
//
// ## 定位
//
// 解析全程走 vendored `rrk-*` 内核（`rust/vendor/`，上游 v0.1.1 / ABI v5，经 FRB 桥
// `lib/src/rust/api/kernel.dart`）：EPUB / TXT / MOBI-AZW3 的打开、分章、正文抽取、
// 资源读取都在 Rust 侧完成。本类负责「内核数据面 → MReader 模型」的映射与
// [BookSource] 契约适配，包括**宿主标记织入**：
//   · 内核行内图片标记 `\u{FFFC}<key>\u{FFFC}` → 宿主图片标记 `\x00IMG:<key>\x00`；
//   · 内链区间（`RkLink`）→ 宿主可点链接标记 `\x00A:<href>\x00文字\x00A\x00`；
//   · 目录树（层级 + 章内锚点）→ 宿主章节列表（`href` + `locate`）：同文件多目录项
//     按锚点**切段**（正文按锚点区间归属、互不重叠），细粒度目录不退化。
//
// ## ⚠️ 本类**不是** compute() 安全的纯 Dart 类
//
// 持 FFI 书句柄（绑定当前 isolate），走「Rust 源」这条路（`lib/format/**` 的纯
// Dart 纪律服务的是可进 `compute()` 的 Dart 源，两者并存不冲突）。由
// [BookRegistry] 按探测结果择一。
//
// ## 坐标系
//
// 内核的链接区间与目录锚点都是**清洗后章文本的 UTF-8 字节偏移**；Dart `String`
// 是 UTF-16 code unit。本类的定位/切段全程在**字节坐标系**上做（utf8 编码一次、
// 字节扫描定位），只在拼最终段落字符串时按字节切片解码——避免两套偏移混算。
import 'dart:convert';
import 'dart:typed_data';

import '../meta/meta_source.dart';
import '../src/rust/api/kernel.dart' as rk;
import 'book_source.dart';

/// 内核图片标记：`\u{FFFC}<key>\u{FFFC}`（key 不含 U+FFFC，无需转义）。
final RegExp _kernelImageMarker = RegExp('\u{FFFC}([^\u{FFFC}]*)\u{FFFC}');

/// 织好宿主标记的一段正文 + 其在章文本中的**字节**区间（锚点切段用）。
class WovenParagraph {
  const WovenParagraph(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;
}

/// 章节列表项的解析引用：内核章 id + 锚点切段区间（`from`/`to` 为字节偏移，
/// `null` = 不设界；`from == null` 即整章）。
class _ChapterRef {
  const _ChapterRef(this.id, {this.from, this.to});

  final int id;
  final int? from;
  final int? to;
}

/// 字节序列扫描定位（`String.indexOf` 的 UTF-8 字节坐标系等价物）。
int indexOfBytes(List<int> haystack, List<int> needle, int from) {
  outer:
  for (int i = from; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// 一个文本片（UTF-8 字节）按内链区间切分，织入宿主可点链接标记。
String weaveLinks(List<int> part, int base, List<rk.RkLink> links) {
  final List<rk.RkLink> hit = <rk.RkLink>[
    for (final rk.RkLink l in links)
      if (l.end > base && l.start < base + part.length) l,
  ]..sort((rk.RkLink a, rk.RkLink b) => a.start.compareTo(b.start));
  final StringBuffer sb = StringBuffer();
  int pos = 0;
  for (final rk.RkLink l in hit) {
    final int s = (l.start - base).clamp(0, part.length);
    final int e = (l.end - base).clamp(0, part.length);
    if (s > pos) sb.write(utf8.decode(part.sublist(pos, s)));
    if (e > s) {
      sb.write('\x00A:${l.href}\x00');
      sb.write(utf8.decode(part.sublist(s, e)));
      sb.write('\x00A\x00');
    }
    if (e > pos) pos = e;
  }
  if (pos < part.length) sb.write(utf8.decode(part.sublist(pos)));
  return sb.toString();
}

/// 内核块表 → 织好宿主标记的段落序列（含源字节区间）。
///
/// 定位方式：块文本去掉图片标记后是章文本的**连续切片**，按块序用游标在字节上
/// 扫描定位（顺序单调、不回溯）；图片块无文本可定位，位置取当前游标（前向填充）。
List<WovenParagraph> weaveChapter(rk.RkChapterText chapter) {
  final List<int> bytes = utf8.encode(chapter.text);
  final List<rk.RkLink> links = chapter.links;
  final List<WovenParagraph> out = <WovenParagraph>[];
  int cursor = 0;

  for (final rk.RkBlock block in chapter.blocks) {
    final StringBuffer sb = StringBuffer();
    int blockStart = -1;
    int blockEnd = -1;

    void handleText(String part) {
      if (part.isEmpty) return;
      final List<int> partBytes = utf8.encode(part);
      final int at = indexOfBytes(bytes, partBytes, cursor);
      if (at < 0) {
        // 理论不发生（块文本必是章文本切片）；兜底：原样回填、不推进游标。
        if (blockStart < 0) blockStart = cursor;
        sb.write(part);
        return;
      }
      if (blockStart < 0) blockStart = at;
      sb.write(weaveLinks(partBytes, at, links));
      cursor = at + partBytes.length;
      blockEnd = cursor;
    }

    int pos = 0;
    for (final RegExpMatch m in _kernelImageMarker.allMatches(block.text)) {
      handleText(block.text.substring(pos, m.start));
      sb.write('\x00IMG:${m.group(1)}\x00');
      pos = m.end;
    }
    handleText(block.text.substring(pos));

    final String text = sb.toString();
    if (text.trim().isEmpty) continue;
    final int start = blockStart < 0 ? cursor : blockStart;
    out.add(WovenParagraph(text, start, blockEnd < 0 ? start : blockEnd));
  }
  return out;
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

  List<rk.RkChapter>? _kChapters;
  List<Chapter>? _chapters;
  List<_ChapterRef>? _refs;
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
    final String intro = _meta.description?.trim() ?? '';

    CoverRef cover = const NoCover();
    if (_meta.coverKey != null) {
      final rk.RkResource? res = await rk.kernelCover(handle: _handle);
      if (res != null && res.data.isNotEmpty) {
        final CoverFormat format = sniffCoverFormat(res.data);
        if (format != CoverFormat.unknown) {
          cover = PendingCover(res.data, format);
        }
      }
    }

    return BookMeta(
      title: title,
      titleOrigin: hasTitleMeta ? MetaOrigin.metadata : MetaOrigin.filename,
      author: author,
      authorOrigin:
          _meta.authors.isNotEmpty ? MetaOrigin.metadata : MetaOrigin.none,
      intro: intro,
      introOrigin: intro.isEmpty ? MetaOrigin.none : MetaOrigin.metadata,
      cover: cover,
      coverOrigin: cover is NoCover ? MetaOrigin.none : MetaOrigin.metadata,
      language: _meta.language ?? '',
      auto: BookMetaAuto(title: title, author: author, intro: intro),
    );
  }

  Future<List<rk.RkChapter>> _kernelChapterList() async =>
      _kChapters ??= await rk.kernelChapters(handle: _handle);

  /// 章节列表（TOC 树摊平 + 未入目章补齐）与解析引用**成对**构建、同序。
  Future<void> _ensureChapterList() async {
    if (_chapters != null) return;
    final List<rk.RkChapter> entries = await _kernelChapterList();
    final List<rk.RkTocNode> toc = await rk.kernelToc(handle: _handle);
    final List<Chapter> out = <Chapter>[];
    final List<_ChapterRef> refs = <_ChapterRef>[];
    final Set<int> covered = <int>{};

    void walk(List<rk.RkTocNode> nodes, int level) {
      for (final rk.RkTocNode n in nodes) {
        if (n.chapter < 0 || n.chapter >= entries.length) continue;
        final int id = n.chapter;
        final rk.RkChapter e = entries[id];
        // 同章两个「无锚点」目录项只留第一个（否则内容整章重复）。
        if (n.anchor == null && covered.contains(id)) continue;
        covered.add(id);
        out.add(Chapter(
          href: e.href,
          title: fallbackTitle(
              n.title, fallbackTitle(e.title ?? '', '第 ${id + 1} 章')),
          level: level,
          locate: n.anchor?.toString() ?? '',
        ));
        refs.add(_ChapterRef(id, from: n.anchor));
        walk(n.children, level + 1);
      }
    }

    walk(toc, 0);
    for (int i = 0; i < entries.length; i++) {
      if (covered.contains(i)) continue;
      out.add(Chapter(
        href: entries[i].href,
        title: fallbackTitle(entries[i].title ?? '', '第 ${i + 1} 章'),
        level: 0,
        locate: '',
      ));
      refs.add(_ChapterRef(i));
    }

    // 同章锚点切段的右界 = 同 id 下一锚点（按锚点升序），互不重叠。
    final Map<int, List<int>> byId = <int, List<int>>{};
    for (int i = 0; i < refs.length; i++) {
      final int? from = refs[i].from;
      if (from != null) (byId[refs[i].id] ??= <int>[]).add(from);
    }
    for (final List<int> anchors in byId.values) {
      anchors.sort();
    }
    for (int i = 0; i < refs.length; i++) {
      final _ChapterRef r = refs[i];
      if (r.from == null) continue;
      final List<int> anchors = byId[r.id]!;
      final int at = anchors.indexOf(r.from!);
      refs[i] = _ChapterRef(r.id,
          from: r.from, to: at + 1 < anchors.length ? anchors[at + 1] : null);
    }

    _chapters = out;
    _refs = refs;
  }

  @override
  Future<List<Chapter>> chapters() async {
    await _ensureChapterList();
    return List<Chapter>.unmodifiable(_chapters!);
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    await _ensureChapterList();
    final List<_ChapterRef> refs = _refs!;
    if (chapterIndex < 0 || chapterIndex >= refs.length) {
      return const ChapterContent.paragraphs(<String>[]);
    }
    final _ChapterRef ref = refs[chapterIndex];
    final List<rk.RkChapter> entries = await _kernelChapterList();
    if (ref.id < 0 || ref.id >= entries.length) {
      return const ChapterContent.paragraphs(<String>[]);
    }
    final rk.RkChapterText text = await rk.kernelLoadChapter(
      handle: _handle,
      chapterId: entries[ref.id].id,
    );
    final List<WovenParagraph> woven = weaveChapter(text);
    final int? from = ref.from;
    final int? to = ref.to;
    final List<String> paragraphs = <String>[
      for (final WovenParagraph w in woven)
        if ((from == null || w.start >= from) && (to == null || w.start < to))
          w.text,
    ];
    return ChapterContent.paragraphs(paragraphs);
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
  Stream<SearchEvent> search(String query,
      {required CancelToken cancel}) async* {
    if (query.isEmpty) return;
    final String needle = query.toLowerCase();
    await _ensureChapterList();
    final List<Chapter> list = _chapters!;
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
            chapterTitle: list[i].title,
            offset: offset + at,
            context: p,
          ));
        }
        offset += p.length;
      }
    }
  }

  @override
  SearchBookSpec? get searchSpec =>
      SearchBookSpec(fileName: fileName, bytes: bytes);

  /// 精确口径（统计用；**阅读页禁调**，见 [BookSource.chapterCharCounts]）：
  /// 逐章加载后按「各段 `paragraph.length` 之和」计，与 Dart 源同一计数规则。
  @override
  Future<List<int>?> chapterCharCounts() async {
    final List<int>? cached = _charCounts;
    if (cached != null) return cached;
    await _ensureChapterList();
    final List<int> out = List<int>.filled(_chapters!.length, 0);
    for (int i = 0; i < out.length; i++) {
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
    final List<int> counts = await chapterCharCounts() ?? const <int>[];
    return counts.fold<int>(0, (int a, int b) => a + b);
  }

  /// 廉价权重（内核零解压估算；阅读页进度百分比专用）。
  ///
  /// 内核权重按**内核章**给；宿主章节列表可能按锚点把一章拆成多条目——拆分条目
  /// **均分**该章权重（只求章间相对比例，不承诺绝对值，契约允许）。
  @override
  Future<List<int>?> chapterWeightEstimates() async {
    final List<int>? cached = _weights;
    if (cached != null) return cached;
    await _ensureChapterList();
    final List<rk.RkWeight> w = await rk.kernelWeights(handle: _handle);
    final Map<int, int> byId = <int, int>{
      for (final rk.RkWeight e in w) e.id: e.charLen,
    };
    final Map<int, int> splitCount = <int, int>{};
    for (final _ChapterRef r in _refs!) {
      splitCount[r.id] = (splitCount[r.id] ?? 0) + 1;
    }
    return _weights = <int>[
      for (final _ChapterRef r in _refs!)
        (byId[r.id] ?? 0) ~/ (splitCount[r.id] ?? 1),
    ];
  }

  @override
  Future<Uint8List?> readResource(String href) async {
    final rk.RkResource? res =
        await rk.kernelLoadResource(handle: _handle, key: href);
    return res?.data;
  }

  @override
  Future<void> dispose() async {
    _kChapters = null;
    _chapters = null;
    _refs = null;
    _charCounts = null;
    _weights = null;
    await rk.kernelClose(handle: _handle);
  }
}
