// BM25 关键词索引（M3-T04：`AI-06` 跟书问答的检索层；`Q6` 拍板——先用关键词/
// BM25，不上向量；`AI-08`/`AI-09` 无关本层）。
//
// ## 两级检索（为什么章级倒排 + 段级重排）
//
//   1. **章级 BM25**（[RagIndexBuilder] → [RagIndex.topChapters]）：倒排表按
//      「章」建 doc（k1=1.2 / b=0.75），问题分词打分取 Top-[kRagChapterCandidates]
//      候选章；
//   2. **段级重排**（`rag.dart` [retrieveSnippets]）：只在候选章内逐段线性打分，
//      取各章最相关段落构造引用（[SearchHit] 同口径）。
//
// 为什么不直接建段级倒排：20MB 书按段建 doc 的 posting 总量在千万级，
// 常驻内存逼近 PRD §15.6.3 **阈值 5**「索引内存 > 原文 1.5 倍」的红线；
// 章级倒排只有千级 doc（[RagIndex.approxBytes] 可实测），段级精度损失由
// 「候选章内重排」补回——候选章 ≤8，线性扫的开销相对取文可忽略。
//
// ## 分词口径
//
//   · ASCII 字母数字串 → 小写词元（`Hello` → `hello`）；
//   · CJK 连续段 → 按字 + 二元组（`中文` → `中`/`文`/`中文`）：bigram 保精确、
//     unigram 兜单字问题（同为「词元」，无词典依赖、纯 Dart 可进 isolate）；
//   · 其余字符（标点 / 空白）为分隔符，不进索引。
//
// 本文件**纯 Dart**（不 import Flutter / dart:io）：构建逻辑可整体搬进
// isolate（M3.5 阈值 5 若触发 Rust/后台化，此处是唯一改造面）。
import 'dart:math' as math;
import 'dart:typed_data';

/// BM25 词频饱和参数（标准取值）。
const double kBm25K1 = 1.2;

/// BM25 章节长度归一化参数（标准取值）。
const double kBm25B = 0.75;

/// 分词：ASCII 词元小写化 + CJK 按字与二元组；其余字符为分隔符。
List<String> tokenize(String text) {
  final List<String> out = <String>[];
  final int n = text.length;
  int i = 0;
  while (i < n) {
    final int cu = text.codeUnitAt(i);
    if (_isAsciiWord(cu)) {
      int j = i;
      while (j < n && _isAsciiWord(text.codeUnitAt(j))) {
        j++;
      }
      out.add(text.substring(i, j).toLowerCase());
      i = j;
    } else if (_isCjk(cu)) {
      int j = i;
      while (j < n && _isCjk(text.codeUnitAt(j))) {
        j++;
      }
      for (int k = i; k < j; k++) {
        out.add(text.substring(k, k + 1));
        if (k + 1 < j) {
          out.add(text.substring(k, k + 2));
        }
      }
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

bool _isAsciiWord(int cu) =>
    (cu >= 0x30 && cu <= 0x39) || // 0-9
    (cu >= 0x41 && cu <= 0x5A) || // A-Z
    (cu >= 0x61 && cu <= 0x7A); // a-z

/// CJK 统一汉字（基本区 + 扩展 A）+ 兼容区；标点 / 假名 / 全角符号不入索引。
bool _isCjk(int cu) =>
    (cu >= 0x3400 && cu <= 0x9FFF) || (cu >= 0xF900 && cu <= 0xFAFF);

/// 增量构建器：逐章喂入 → [finish] 产出 [RagIndex]。
///
/// 逐章构建的原因：取文是异步的（[RagIndexStore.ensure] 按章加载），
/// 构建器必须能在章节之间 yield（长书不让主 isolate 连续卡死 10s）。
class RagIndexBuilder {
  /// term → [doc, tf, doc, tf, …]（doc = 章下标，升序追加）。
  final Map<String, List<int>> _postings = <String, List<int>>{};

  /// 每章 token 总数（BM25 长度归一化用）。
  final List<int> _docLengths = <int>[];

  /// 每章标题（引用展示用；[RagIndex.topChapters] 不参与打分之外的逻辑）。
  final List<String> titles = <String>[];

  int _totalTokens = 0;

  /// 已建 doc 数（= 已喂章数）。
  int get chapterCount => _docLengths.length;

  /// 已积累的 token 总数。
  int get totalTokens => _totalTokens;

  /// 追加一章（[title] 也进索引——按章节名提问应能命中）。
  void addChapter(String title, String text) {
    final List<String> tokens = tokenize('$title\n$text');
    final Map<String, int> tf = <String, int>{};
    for (final String token in tokens) {
      tf[token] = (tf[token] ?? 0) + 1;
    }
    final int doc = _docLengths.length;
    tf.forEach((String term, int count) {
      (_postings[term] ??= <int>[]).add(doc);
      (_postings[term]!).add(count);
    });
    _docLengths.add(tokens.length);
    titles.add(title);
    _totalTokens += tokens.length;
  }

  /// 收口：posting 列表压成 [Int32List]（省内存，贴近阈值 5 的内存口径）。
  RagIndex finish() {
    final Map<String, Int32List> postings = <String, Int32List>{};
    _postings.forEach((String term, List<int> pairs) {
      postings[term] = Int32List.fromList(pairs);
    });
    return RagIndex(
      titles: List<String>.of(titles),
      docLengths: List<int>.of(_docLengths),
      postings: postings,
      totalTokens: _totalTokens,
    );
  }
}

/// 不可变索引（可 JSON 序列化，持久化与进程内缓存共用同一形态）。
class RagIndex {
  RagIndex({
    required this.titles,
    required this.docLengths,
    required this.postings,
    required this.totalTokens,
  });

  /// 空索引（无章节时的退化形态；[topChapters] 恒空）。
  factory RagIndex.empty() => RagIndex(
        titles: <String>[],
        docLengths: <int>[],
        postings: <String, Int32List>{},
        totalTokens: 0,
      );

  /// 各章标题（与 [SearchHit.chapterTitle] 对齐）。
  final List<String> titles;

  /// 每章 token 数。
  final List<int> docLengths;

  /// term → [doc, tf, doc, tf, …]。
  final Map<String, Int32List> postings;

  /// 全书 token 总数。
  final int totalTokens;

  /// BM25 章级打分：返回得分 > 0 的章，按分数降序（同分章下标升序）。
  List<({int chapterIndex, double score})> topChapters(
    String query,
    int limit,
  ) {
    final int n = docLengths.length;
    if (n == 0 || limit <= 0) {
      return const <({int chapterIndex, double score})>[];
    }
    final Set<String> terms = tokenize(query).toSet();
    if (terms.isEmpty) {
      return const <({int chapterIndex, double score})>[];
    }
    final double avgLen = totalTokens / n;
    final Map<int, double> scores = <int, double>{};
    for (final String term in terms) {
      final Int32List? pairs = postings[term];
      if (pairs == null) continue;
      final int df = pairs.length ~/ 2;
      final double idf = math.log((n - df + 0.5) / (df + 0.5) + 1.0);
      for (int k = 0; k + 1 < pairs.length; k += 2) {
        final int doc = pairs[k];
        final double f = pairs[k + 1].toDouble();
        final double norm = f + kBm25K1 * (1 - kBm25B + kBm25B * docLengths[doc] / avgLen);
        scores[doc] = (scores[doc] ?? 0) + idf * (f * (kBm25K1 + 1)) / norm;
      }
    }
    final List<({int chapterIndex, double score})> ranked =
        <({int chapterIndex, double score})>[
      for (final MapEntry<int, double> e in scores.entries)
        if (e.value > 0) (chapterIndex: e.key, score: e.value),
    ]..sort((({int chapterIndex, double score}) a, ({int chapterIndex, double score}) b) {
        final int byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : a.chapterIndex.compareTo(b.chapterIndex);
      });
    return ranked.take(limit).toList();
  }

  /// 常驻内存的**估算**字节数（阈值 5 内存口径的观察值，只用于打点，不分支）。
  ///
  /// 口径：词条 UTF-16 字符 + Map/Int32List 对象头 + posting 每项 4B，
  /// 加章标题与长度数组；忽略 Dart 堆对齐等二阶项。
  int get approxBytes {
    int bytes = 64; // 对象头 / 表结构的固定开销（下限）。
    postings.forEach((String term, Int32List pairs) {
      bytes += 64 + term.length * 2 + pairs.length * 4;
    });
    for (final String title in titles) {
      bytes += 48 + title.length * 2;
    }
    bytes += docLengths.length * 16;
    return bytes;
  }

  /// 落盘 JSON（`v` 为格式版本，升级即整体重建——索引是可再生缓存）。
  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'titles': titles,
        'lengths': docLengths,
        'total': totalTokens,
        'postings': <String, Object?>{
          for (final MapEntry<String, Int32List> e in postings.entries)
            e.key: e.value,
        },
      };

  /// 由 [toJson] 还原；结构异常返 `null`（调用方回退重建）。
  static RagIndex? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['v'] != 1) return null;
    final Object? titles = json['titles'];
    final Object? lengths = json['lengths'];
    final Object? total = json['total'];
    final Object? rawPostings = json['postings'];
    if (titles is! List || lengths is! List || rawPostings is! Map) return null;
    final List<String> titleList = <String>[];
    for (final Object? t in titles) {
      titleList.add(t is String ? t : '');
    }
    final List<int> lengthList = <int>[];
    for (final Object? l in lengths) {
      if (l is! num) return null;
      lengthList.add(l.toInt());
    }
    final Map<String, Int32List> postingMap = <String, Int32List>{};
    for (final MapEntry<Object?, Object?> e in rawPostings.entries) {
      if (e.key is! String || e.value is! List) return null;
      final List<Object?> pairs = e.value! as List<Object?>;
      if (pairs.length.isOdd) return null;
      final Int32List list = Int32List(pairs.length);
      for (int i = 0; i < pairs.length; i++) {
        final Object? v = pairs[i];
        if (v is! num) return null;
        list[i] = v.toInt();
      }
      postingMap[e.key! as String] = list;
    }
    return RagIndex(
      titles: titleList,
      docLengths: lengthList,
      postings: postingMap,
      totalTokens: total is num ? total.toInt() : 0,
    );
  }
}
