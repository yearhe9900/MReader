// MOBI / AZW3 源（`FormatKind.mobi`，2026-10-20 接入）。
//
// ## 定位
//
// MOBI 正文是**一整条 HTML 流**（与 EPUB 的 XHTML 同构），因此段落提取直接
// 复用 `epub/section_extractor.dart`，本类只负责「容器解析 + 切章 + 元数据」。
//
// ## 切章口径（真样本实证，2026-10-20）
//
// 1. `<mbp:pagebreak>` ≥ 2 处 ⇒ 按它切（MOBI 原生的分页标记，foliate-js 同款做法）；
// 2. 否则按 `<h1>`/`<h2>`/`<h3>` 标题切（掌阅系 AZW3 实测无 pagebreak，正文靠
//    `<h2 class="titletoc">` 分章）；
// 3. 都没有 ⇒ 整本单章（脏书也不报错）。
//
// ## 边界（诚实降级 `NF-C8`）
//
// · HUFF/CDIC 压缩（`compression=2`）**不支持** → `mobiHuffCdicUnsupported`；
// · 图片不解包（`hasImages=false`，正文里的 `<img>` 标记不产出资源）；
// · DRM（`encryptionType != 0`）→ `encryptedMobi`。
import 'dart:convert';
import 'dart:typed_data';

import '../epub/section_extractor.dart';

import '../meta/meta_source.dart';
import 'book_source.dart';
import 'mobi/mobi_palmdoc.dart';

/// 章切分边界（字节区间，落在解码后的正文里）。
class _ChapterSpan {
  const _ChapterSpan(this.start, this.end, this.title);

  final int start;
  final int end;
  final String title;
}

/// MOBI / AZW3 / AZW / PRC 源（PalmDB `BOOKMOBI` 家族）。
class MobiSource implements BookSource {
  MobiSource({required this.fileName, required this.bytes});

  /// 原始文件名（元数据兜底用；`RD-04` 口径的展示名）。
  final String fileName;

  /// 整本字节（与其他源同一口径：构造时持有）。
  final Uint8List bytes;

  MobiContainer? _container;
  Uint8List? _text;
  List<_ChapterSpan>? _spans;
  List<int>? _weights;

  MobiContainer get _c => _container ??= parseMobi(bytes);

  Uint8List get _body => _text ??= _c.textBytes();

  @override
  String get implId => 'dart-mobi';

  @override
  Future<BookMeta> load() async {
    final MobiContainer c = _c;
    final String title = _cleanMeta(c.exth[503]) ??
        (c.fullName == null ? null : _cleanMeta(c.fullName)) ??
        _stemOf(fileName);
    final String? author = _cleanMeta(c.exth[100]);

    CoverRef cover = const NoCover();
    if (c.coverRecordIndex > 0) {
      final Uint8List? raw = c.record(c.coverRecordIndex);
      if (raw != null && raw.isNotEmpty) {
        final CoverFormat format = sniffCoverFormat(raw);
        if (format != CoverFormat.unknown) cover = PendingCover(raw, format);
      }
    }

    return BookMeta(
      title: title,
      titleOrigin: c.exth[503] != null ? MetaOrigin.metadata : MetaOrigin.filename,
      author: author ?? kUnknownAuthor,
      authorOrigin: author != null ? MetaOrigin.metadata : MetaOrigin.none,
      intro: '',
      introOrigin: MetaOrigin.none,
      cover: cover,
      coverOrigin: cover is NoCover ? MetaOrigin.none : MetaOrigin.metadata,
      language: '',
      auto: BookMetaAuto(title: title, author: author ?? kUnknownAuthor, intro: ''),
    );
  }

  @override
  Future<List<Chapter>> chapters() async {
    final List<_ChapterSpan> spans = _chapters();
    return <Chapter>[
      for (int i = 0; i < spans.length; i++)
        Chapter(
          href: 'mobi:$i',
          title: spans[i].title,
          level: 0,
          locate: '',
        ),
    ];
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    final List<_ChapterSpan> spans = _chapters();
    if (chapterIndex < 0 || chapterIndex >= spans.length) {
      return const ChapterContent.paragraphs(<String>[]);
    }
    final _ChapterSpan span = spans[chapterIndex];
    final Uint8List slice = Uint8List.sublistView(
      _body,
      span.start,
      span.end > span.start ? span.end : span.start,
    );
    final List<String> paragraphs = extractParagraphsFromFragment(slice, '');
    return ChapterContent.paragraphs(
      paragraphs.isEmpty ? const <String>[] : paragraphs,
    );
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: false,
        hasFootnotes: false,
        reflowable: true,
        searchable: true,
        charCountSupported: true,
      );

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) async* {
    if (query.isEmpty) return;
    final String needle = query.toLowerCase();
    final List<_ChapterSpan> spans = _chapters();
    for (int i = 0; i < spans.length; i++) {
      if (cancel.isCancelled) return;
      yield SearchEvent.progress(i / spans.length);
      final List<String> paragraphs =
          (await content(i)).paragraphList;
      int offset = 0;
      for (final String p in paragraphs) {
        final int at = p.toLowerCase().indexOf(needle);
        if (at >= 0) {
          yield SearchEvent.hit(SearchHit(
            chapterIndex: i,
            chapterTitle: spans[i].title,
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

  @override
  Future<int?> totalCharCount() async {
    final List<_ChapterSpan> spans = _chapters();
    int sum = 0;
    for (final _ChapterSpan s in spans) {
      sum += (await content(_indexOf(spans, s))).paragraphList.fold<int>(
            0,
            (int a, String p) => a + p.length,
          );
    }
    return sum;
  }

  @override
  Future<List<int>?> chapterCharCounts() async {
    final List<_ChapterSpan> spans = _chapters();
    final List<int> out = <int>[];
    for (int i = 0; i < spans.length; i++) {
      int sum = 0;
      for (final String p in (await content(i)).paragraphList) {
        sum += p.length;
      }
      out.add(sum);
    }
    return out;
  }

  @override
  Future<List<int>?> chapterWeightEstimates() async {
    if (_weights != null) return _weights;
    // **廉价口径**：章字节长度（不解码、不解析），与字数强正相关。
    final List<_ChapterSpan> spans = _chapters();
    return _weights = <int>[
      for (final _ChapterSpan s in spans) s.end - s.start,
    ];
  }

  @override
  Future<Uint8List?> readResource(String href) async => null;

  @override
  Future<void> dispose() async {
    _text = null;
    _spans = null;
    _weights = null;
  }

  static int _indexOf(List<_ChapterSpan> spans, _ChapterSpan s) =>
      spans.indexOf(s);

  // ── 切章（一次扫描，结果缓存）────────────────────────────────────────

  List<_ChapterSpan> _chapters() {
    if (_spans != null) return _spans!;
    final Uint8List body = _body;
    final List<int> breaks = <int>[]; // pagebreak 位置
    final List<({int at, String title})> headings = <({int at, String title})>[];

    int i = 0;
    while (i < body.length) {
      if (body[i] != 0x3c /* '<' */) {
        i++;
        continue;
      }
      final int tagEnd = _tagEnd(body, i);
      if (tagEnd < 0) {
        i++;
        continue;
      }
      final String tag = String.fromCharCodes(body.sublist(i + 1, tagEnd))
          .toLowerCase();
      if (tag.startsWith('mbp:pagebreak')) {
        breaks.add(tagEnd);
      } else if (tag == 'h1' || tag == 'h2' || tag == 'h3') {
        final int close = _findClose(body, tagEnd, tag);
        headings.add((at: i, title: _textOf(body, tagEnd, close)));
      }
      i = tagEnd;
    }

    final List<int> cuts;
    if (breaks.length >= 2) {
      cuts = breaks;
    } else if (headings.length >= 2) {
      cuts = <int>[for (final ({int at, String title}) h in headings) h.at];
    } else {
      return _spans = <_ChapterSpan>[
        _ChapterSpan(0, body.length, _defaultTitle(0)),
      ];
    }

    final List<_ChapterSpan> out = <_ChapterSpan>[];
    // 首个切点之前的内容并入第一章（封面/版权页不该单独成章）。
    int start = 0;
    for (int k = 0; k < cuts.length; k++) {
      final int end = k + 1 < cuts.length ? cuts[k + 1] : body.length;
      if (end <= start) continue;
      final String? title = _titleInRange(body, start, end);
      out.add(_ChapterSpan(start, end, title ?? _defaultTitle(out.length)));
      start = end;
    }
    if (start < body.length) {
      out.add(_ChapterSpan(
        start,
        body.length,
        _titleInRange(body, start, body.length) ?? _defaultTitle(out.length),
      ));
    }
    return _spans = out.isEmpty
        ? <_ChapterSpan>[_ChapterSpan(0, body.length, _defaultTitle(0))]
        : out;
  }

  static int _tagEnd(Uint8List b, int lt) {
    for (int k = lt + 1; k < b.length && k < lt + 24; k++) {
      final int c = b[k];
      if (c == 0x3e /* > */ || c == 0x20 /* space */ || c == 0x2f /* / */) {
        return k;
      }
    }
    return -1;
  }

  /// 找标题标签的闭合位置（`</h1>` 之前），容错 4KB 上限。
  static int _findClose(Uint8List b, int from, String tag) {
    final String close = '</$tag';
    for (int k = from; k < b.length - close.length && k < from + 4096; k++) {
      if (b[k] != 0x3c) continue;
      final String t = String.fromCharCodes(
        b.sublist(k, (k + close.length).clamp(0, b.length)),
      ).toLowerCase();
      if (t.startsWith(close)) return k;
    }
    return -1;
  }

  static String _textOf(Uint8List b, int start, int end) {
    if (end < 0 || start < 0 || end <= start) return '';
    final String raw = const Utf8Decoder(allowMalformed: true)
        .convert(Uint8List.sublistView(b, start, end > b.length ? b.length : end));
    return raw.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(r'\s+', ' ').trim();
  }

  /// 章内首个标题文本（用于给切出来的章命名）。
  static String? _titleInRange(Uint8List b, int start, int end) {
    for (int k = start; k < end - 1 && k < start + 8192; k++) {
      if (b[k] != 0x3c) continue;
      final int tagEnd = _tagEnd(b, k);
      if (tagEnd < 0) continue;
      final String tag = String.fromCharCodes(b.sublist(k + 1, tagEnd)).toLowerCase();
      if (tag != 'h1' && tag != 'h2' && tag != 'h3' && tag != 'h4') continue;
      final int close = _findClose(b, tagEnd, tag);
      final String t = _textOf(b, tagEnd, close);
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  static String _defaultTitle(int index) => '第 ${index + 1} 节';

  static String? _cleanMeta(String? raw) {
    if (raw == null) return null;
    final String t = raw.replaceAll('\u0000', '').replaceAll(r'\s+', ' ').trim();
    return t.isEmpty ? null : t;
  }

  static String _stemOf(String name) {
    final String base = name.replaceAll('\\', '/').split('/').last;
    final int dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}
