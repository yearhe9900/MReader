// Rust 解析内核的 `BookSource` 适配层（图书解析核心移植，2026-10-22 二次同步）。
//
// ## 定位
//
// 解析全程走 vendored `rrk-*` 内核（`rust/vendor/`，上游 v0.1.1 / ABI v5，经 FRB 桥
// `lib/src/rust/api/kernel.dart`）：EPUB / TXT / MOBI-AZW3 的打开、分章、正文抽取、
// 资源读取都在 Rust 侧完成；CBZ（2026-10-23 接线）页表 / 图片页资源同样走内核，
// 但**页过滤、自然序与文件名元数据口径在宿主侧补齐**（与 `CbzSource` 逐条对齐，
// 见 [buildCbzPageList] / [_loadCbzMeta]），切换实现不改变用户可见行为。
// 本类负责「内核数据面 → MReader 模型」的映射与
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

import '../epub/zip_paths.dart';
import '../meta/meta_source.dart';
import '../meta/txt_meta.dart';
import '../src/rust/api/kernel.dart' as rk;
import 'book_source.dart';
import 'image_pages.dart';
import 'natural_sort.dart';

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
class ChapterRef {
  const ChapterRef(this.id, {this.from, this.to});

  final int id;
  final int? from;
  final int? to;
}

/// 宿主标记段（`\x00…\x00` 包裹）：剥标记比对可见文本、标题剥离时接力锚点用。
final RegExp _hostMarker = RegExp('\x00[^\x00]*\x00');

/// 段落的可见文本（剥离全部宿主标记后）。
String visibleTextOf(String paragraph) =>
    paragraph.replaceAll(_hostMarker, '').trim();

/// 首段与章标题重复则剥去（与纯 Dart 抽取「标题剥离」同规则，
/// `epub/section_extractor.dart`：「UI 单独渲染的标题」与「正文首段」不得
/// 重复显示同一句话）。剥去的首段若带**前置标记**，接力到新的首段
/// （锚点标记不失效，同 Dart 口径）。
List<String> stripDuplicateHeading(List<String> paragraphs, String title) {
  if (paragraphs.isEmpty) return paragraphs;
  final String first = paragraphs.first;
  if (visibleTextOf(first) != title.trim() || title.trim().isEmpty) {
    return paragraphs;
  }
  // 只接力**成对完整**的前置标记（图片 / 锚点等）；链接开标记 `A:` 的闭标记
  // 在被剥去的标题段内，接力会留下失衡开标记 → 一并随标题剥掉。
  final String leading = _hostMarker
      .allMatches(first)
      .map((Match m) => m.group(0)!)
      .takeWhile((String s) => first.startsWith(s))
      .where((String s) => !s.startsWith('\x00A:'))
      .join();
  if (paragraphs.length == 1) return const <String>[];
  if (leading.isEmpty) return paragraphs.sublist(1);
  return <String>[leading + paragraphs[1], ...paragraphs.sublist(2)];
}

/// 章节列表构建（TOC 树摊平 + 未入目补齐）的**纯函数**：返回宿主 Chapter 列表
/// 与解析引用（同序）。
///
/// ## href 唯一性（2026-10-22 真机「章与页不匹配」定案）
///
/// 阅读器把 `Chapter.href` 当**唯一身份键**（分页缓存、视图定位、进度匹配全按
/// href 查表，见 `_applyPagedSample` 的首匹配）。同文件多目录项（EPUB 锚点书）
/// 会天然共用内核章 href——第二条起必须**唯一化**（`href#locate`），否则读数行
/// 的章归属会落到同 href 的第一条上（正文显示第五章、读数报第四章）。
/// 唯一化后的 href 供身份匹配用；[findChapterIndex] 的链接反查按 `#` 前的
/// 路径段匹配（`link_navigator.dart`），链接跳转不受影响。
(List<Chapter>, List<ChapterRef>) buildChapterList(
  List<rk.RkChapter> entries,
  List<rk.RkTocNode> toc,
) {
  final List<Chapter> out = <Chapter>[];
  final List<ChapterRef> refs = <ChapterRef>[];
  final Set<int> covered = <int>{};
  final Set<String> usedHrefs = <String>{};

  String uniqueHref(String href, String locate) {
    if (usedHrefs.add(href)) return href;
    final String alt = locate.isNotEmpty ? '$href#$locate' : href;
    if (usedHrefs.add(alt)) return alt;
    int n = 2;
    while (!usedHrefs.add('$href#$n')) {
      n++;
    }
    return '$href#$n';
  }

  void walk(List<rk.RkTocNode> nodes, int level) {
    for (final rk.RkTocNode n in nodes) {
      if (n.chapter < 0 || n.chapter >= entries.length) continue;
      final int id = n.chapter;
      final rk.RkChapter e = entries[id];
      final String locate = n.anchor?.toString() ?? '';
      // 同章两个「无锚点」目录项只留第一个（否则内容整章重复）。
      if (n.anchor == null && covered.contains(id)) continue;
      covered.add(id);
      out.add(Chapter(
        href: uniqueHref(e.href, locate),
        title: fallbackTitle(
            n.title, fallbackTitle(e.title ?? '', '第 ${id + 1} 章')),
        level: level,
        locate: locate,
      ));
      refs.add(ChapterRef(id, from: n.anchor));
      walk(n.children, level + 1);
    }
  }

  walk(toc, 0);
  for (int i = 0; i < entries.length; i++) {
    if (covered.contains(i)) continue;
    out.add(Chapter(
      href: uniqueHref(entries[i].href, ''),
      title: fallbackTitle(entries[i].title ?? '', '第 ${i + 1} 章'),
      level: 0,
      locate: '',
    ));
    refs.add(ChapterRef(i));
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
    final ChapterRef r = refs[i];
    if (r.from == null) continue;
    final List<int> anchors = byId[r.id]!;
    final int at = anchors.indexOf(r.from!);
    refs[i] = ChapterRef(r.id,
        from: r.from, to: at + 1 < anchors.length ? anchors[at + 1] : null);
  }
  return (out, refs);
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

/// CBZ 页表项：宿主页身份（归一化条目名，= `Chapter.href` / `imagePages` 元素，
/// 进度真值键）+ 内核页索引（资源键 `page:{id}` 用）。
class CbzPageRef {
  const CbzPageRef(this.href, this.kernelId);

  final String href;
  final int kernelId;
}

/// CBZ 页表构建（**纯函数**）：与 `CbzSource._prepare` 的页口径逐条对齐——
///
/// 1. 条目名归一化（[normalizeZipPath]）；
/// 2. 过滤：`__MACOSX/` 打包垃圾、隐藏文件（`.DS_Store` / `._*`）、非图片扩展名
///    （[isImagePageName] 白名单）；
/// 3. 大小写撞名去重（小写键只收第一件）；
/// 4. `compareNatural` 自然序排序（`10.jpg` 不插到 `2.jpg` 前）。
///
/// 内核 `rrk-cbz` 自身的过滤/排序口径与 Dart 基线**不一致**（白名单更窄、不含
/// 垃圾过滤、`natural_cmp` 大小写敏感），故这些规则在宿主侧补齐——切换实现
/// **不得改变**用户可见的页表。已知残余差异（罕见）：大小写撞名的「保留哪一件」
/// 取内核页序而非 zip 物理序；缺白名单扩展名（如 `.tif`）的页内核未列出、
/// 宿主不可恢复（上游 issue 跟踪补齐）。
List<CbzPageRef> buildCbzPageList(List<rk.RkChapter> entries) {
  final Map<String, CbzPageRef> byLower = <String, CbzPageRef>{};
  for (final rk.RkChapter e in entries) {
    final String name = normalizeZipPath(e.href);
    if (name.isEmpty) continue;
    final String lower = name.toLowerCase();
    if (lower.startsWith('__macosx/')) continue;
    final String base = lower.substring(lower.lastIndexOf('/') + 1);
    if (base.startsWith('.')) continue;
    if (!isImagePageName(lower)) continue;
    if (byLower.containsKey(lower)) continue;
    byLower[lower] = CbzPageRef(name, e.id);
  }
  final List<CbzPageRef> pages = byLower.values.toList()
    ..sort((CbzPageRef a, CbzPageRef b) => compareNatural(a.href, b.href));
  return pages;
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
  List<ChapterRef>? _refs;
  List<int>? _charCounts;
  List<int>? _weights;

  /// CBZ 页级视图（`_meta.format == 'CBZ'` 时建）：宿主页表 + 小写索引 + 内核页索引。
  List<CbzPageRef>? _cbzPages;
  List<Chapter>? _cbzChapters;
  Map<String, String>? _cbzLowerIndex;
  Map<String, int>? _cbzIdByHref;

  /// 是否 CBZ（页级图库：`content` = 图片页序列，不走正文织入管线）。
  bool get _isCbz => _meta.format == 'CBZ';

  /// 打开一本书。失败抛异常（[BookRegistry] 捕获后回落纯 Dart 实现）。
  ///
  /// [filePath] 可选：给了就走内核路径型打开（文件读入 Rust，不经 FFI 拷贝）；
  /// 不给则字节型打开（与 Dart 源同口径：构造时已持有全量字节）。
  ///
  /// CBZ 在此**预建页表**：页表为空（垃圾包 / 无图片条目）抛
  /// [FormatErrorCode.noImagePages]——由注册表回落 `CbzSource` 给出同型中文错误。
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
      final RustKernelSource source =
          RustKernelSource._(fileName, bytes, handle, meta);
      if (meta.format == 'CBZ') {
        await source._ensureCbzPages();
      }
      return source;
    } catch (_) {
      await rk.kernelClose(handle: handle).catchError((_) {});
      rethrow;
    }
  }

  /// 建 CBZ 页表（幂等）；空页表抛 `noImagePages`（口径同 `CbzSource._prepare`）。
  Future<void> _ensureCbzPages() async {
    if (_cbzPages != null) return;
    final List<CbzPageRef> pages =
        buildCbzPageList(await rk.kernelChapters(handle: _handle));
    if (pages.isEmpty) {
      throw const MReaderFormatException(FormatErrorCode.noImagePages);
    }
    final List<Chapter> chapters = <Chapter>[
      for (int i = 0; i < pages.length; i++)
        Chapter(href: pages[i].href, title: '第 ${i + 1} 页', level: 0, locate: ''),
    ];
    _cbzPages = pages;
    _cbzChapters = List<Chapter>.unmodifiable(chapters);
    _cbzLowerIndex = <String, String>{
      for (final CbzPageRef p in pages) p.href.toLowerCase(): p.href,
    };
    _cbzIdByHref = <String, int>{
      for (final CbzPageRef p in pages) p.href: p.kernelId,
    };
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
    if (_isCbz) return _loadCbzMeta();
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

  /// CBZ 元数据（口径与 `CbzSource.load` 逐条对齐）：
  ///  · 标题 / 作者 / 简介 = `META-04` 文件名规则链（[buildTxtMeta]）——内核只给
  ///    文件名主干，产品语义留在宿主；
  ///  · 封面 = **自然序首页**的原始字节 + 魔数嗅探真实格式（`META-05`）。
  ///    不走 `kernel_cover`：内核的「第一页」是内核页序首页，可能撞上被宿主
  ///    过滤掉的垃圾条目（`.__x.jpg` 在其自然序里反而在前）。
  Future<BookMeta> _loadCbzMeta() async {
    final BookMeta base = buildTxtMeta(fileName: fileName);
    CoverRef cover = const NoCover();
    MetaOrigin coverOrigin = MetaOrigin.none;
    final Uint8List? first = await readResource(_cbzPages!.first.href);
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

  Future<List<rk.RkChapter>> _kernelChapterList() async =>
      _kChapters ??= await rk.kernelChapters(handle: _handle);

  /// 章节列表（TOC 树摊平 + 未入目章补齐）与解析引用**成对**构建、同序。
  Future<void> _ensureChapterList() async {
    if (_chapters != null) return;
    final (List<Chapter> chapters, List<ChapterRef> refs) = buildChapterList(
      await _kernelChapterList(),
      await rk.kernelToc(handle: _handle),
    );
    _chapters = chapters;
    _refs = refs;
  }

  @override
  Future<List<Chapter>> chapters() async {
    if (_isCbz) {
      await _ensureCbzPages();
      return _cbzChapters!;
    }
    await _ensureChapterList();
    return List<Chapter>.unmodifiable(_chapters!);
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    if (_isCbz) {
      // 每页一章：正文 = 单元素图片页序列（与 `CbzSource.content` 同构，
      // 元素 = 归一化条目名，由 [readResource] 解出原始字节）。
      await _ensureCbzPages();
      final List<CbzPageRef> pages = _cbzPages!;
      if (chapterIndex < 0 || chapterIndex >= pages.length) {
        return const ChapterContent.imagePages(<String>[]);
      }
      return ChapterContent.imagePages(<String>[pages[chapterIndex].href]);
    }
    await _ensureChapterList();
    final List<ChapterRef> refs = _refs!;
    if (chapterIndex < 0 || chapterIndex >= refs.length) {
      return const ChapterContent.paragraphs(<String>[]);
    }
    final ChapterRef ref = refs[chapterIndex];
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
    // 标题剥离：UI 单独渲染章标题，正文首段与之重复则剥去（同 Dart 抽取口径）。
    return ChapterContent.paragraphs(
      stripDuplicateHeading(paragraphs, _chapters![chapterIndex].title),
    );
  }

  @override
  SourceCapabilities capabilities() {
    if (_isCbz) {
      // 与 `CbzSource.capabilities` 同一字面量（图片页不重排 / 无文本层不可搜）。
      return const SourceCapabilities(
        hasImages: true,
        hasFootnotes: false,
        reflowable: false,
        searchable: false,
        charCountSupported: false,
      );
    }
    return SourceCapabilities(
      hasImages: _meta.format != 'TXT',
      hasFootnotes: false,
      reflowable: true,
      searchable: true,
      charCountSupported: true,
    );
  }

  @override
  Stream<SearchEvent> search(String query,
      {required CancelToken cancel}) async* {
    if (_isCbz) return; // 图片页无文本层（`searchable: false`），空流同 CbzSource
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

  /// CBZ 图片页给不出可序列化源描述（也不可搜）→ `null`（同 `CbzSource`）。
  @override
  SearchBookSpec? get searchSpec => _isCbz
      ? null
      : SearchBookSpec(fileName: fileName, bytes: bytes);

  /// 精确口径（统计用；**阅读页禁调**，见 [BookSource.chapterCharCounts]）：
  /// 逐章加载后按「各段 `paragraph.length` 之和」计，与 Dart 源同一计数规则。
  @override
  Future<List<int>?> chapterCharCounts() async {
    if (_isCbz) return null; // 无文本层（charCountSupported: false），同 CbzSource
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
    if (_isCbz) return null; // 同 CbzSource（页数 ≠ 字符数）
    final List<int> counts = await chapterCharCounts() ?? const <int>[];
    return counts.fold<int>(0, (int a, int b) => a + b);
  }

  /// 廉价权重（内核零解压估算；阅读页进度百分比专用）。
  ///
  /// 内核权重按**内核章**给；宿主章节列表可能按锚点把一章拆成多条目——拆分条目
  /// **均分**该章权重（只求章间相对比例，不承诺绝对值，契约允许）。
  @override
  Future<List<int>?> chapterWeightEstimates() async {
    if (_isCbz) return null; // 同 CbzSource：调用方退化等权（内核页权重全 0 同义）
    final List<int>? cached = _weights;
    if (cached != null) return cached;
    await _ensureChapterList();
    final List<rk.RkWeight> w = await rk.kernelWeights(handle: _handle);
    final Map<int, int> byId = <int, int>{
      for (final rk.RkWeight e in w) e.id: e.charLen,
    };
    final Map<int, int> splitCount = <int, int>{};
    for (final ChapterRef r in _refs!) {
      splitCount[r.id] = (splitCount[r.id] ?? 0) + 1;
    }
    return _weights = <int>[
      for (final ChapterRef r in _refs!)
        (byId[r.id] ?? 0) ~/ (splitCount[r.id] ?? 1),
    ];
  }

  @override
  Future<Uint8List?> readResource(String href) async {
    if (_isCbz) {
      // 口径同 `CbzSource.readResource`：resolveEntryName 三试探（大小写 /
      // 百分号转义容错）→ 内核页资源 `page:{id}`；尽力而为、坏包不抛。
      try {
        await _ensureCbzPages();
        final String? name = resolveEntryName(_cbzLowerIndex!, href);
        if (name == null) return null;
        final int? id = _cbzIdByHref![name];
        if (id == null) return null;
        final rk.RkResource? res =
            await rk.kernelLoadResource(handle: _handle, key: 'page:$id');
        return res?.data;
      } catch (_) {
        return null;
      }
    }
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
    _cbzPages = null;
    _cbzChapters = null;
    _cbzLowerIndex = null;
    _cbzIdByHref = null;
    await rk.kernelClose(handle: _handle);
  }
}
