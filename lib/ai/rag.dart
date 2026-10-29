// 跟书问答（`AI-06` / F5 流程 / `AI-09` 隐私红线的驱动层）。
//
// 验收落点：`AI-06` ① 可跳转引用：检索产物是 [RagSnippet]，内含 [SearchHit]
// （offset = 段落长度累加 + 段内命中位，与 `CNT-06` 搜索**同一口径**，阅读页
// `_jumpToSearchHit` 整段复用）；② 「书中未提及」：system 提示词强制
// （[kRagSystemPrompt]），零片段**不发请求**、面板直接展示「书中未提及」；
// ③ 不发全书：只发 [retrieveSnippets] 检索出的 Top-[kRagTopK] 片段，总字数
// 封顶 [kRagTotalChars]（F5「将发送 K 个片段，共 X 字」的 X 即此）；
// `AI-08` ① 流式 / 可取消（[RagJob] 协作式取消 + [AiCall.cancel]）。
// PRD §8.3「向量/关键词索引本地持久化」：[RagIndexStore] 按 bookId 分文件
// 缓存（同 [SummaryCache] 目录 `aiCache/`），重开零构建。
// 阈值 5（20MB 索引 >10s 或内存 >1.5×原文）基线：构建 / 落盘 / 读盘打点
// `rag.index.build` / `rag.index.persist` / `rag.index.load`，内存估算
// `rag.index.mem`（只观察不分支，`PerfLog` 契约）。
import 'dart:io';

import '../diagnostics/perf_log.dart';
import '../format/book_source.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'ai_client.dart';
import 'bm25.dart';
import 'provider_config.dart';

export 'bm25.dart';

/// 发送给模型的片段数上限（F5「Top-K 相关片段」）。
const int kRagTopK = 5;

/// 章级 BM25 先取的候选章数（≥ [kRagTopK]，给段级重排留选择余地）。
const int kRagChapterCandidates = 8;

/// 单片段发送节选上限（字符；超长段落按命中位置开窗）。
const int kRagSnippetChars = 600;

/// 单次提问发送的片段总字数硬顶（`AI-06` ③：结构上保证不发全书）。
const int kRagTotalChars = 3000;

/// 跟书问答系统提示词（`AI-06` ②：无信息必答「书中未提及」，禁止编造）。
const String kRagSystemPrompt =
    '你是阅读助手，回答必须严格基于下方给出的原文片段。规则：'
    '1. 只依据片段内容作答；引用某片段时在句末标注其编号，如 [1]、[2]。'
    '2. 如果片段中没有所需信息，明确回答「书中未提及」，禁止编造。'
    '3. 用简体中文直接输出答案，不复述规则。';

/// 一个检索片段（发送文本 + 可跳转引用）。
class RagSnippet {
  const RagSnippet({required this.hit, required this.text});

  /// 引用位置（阅读页 `_jumpToSearchHit` 消费）。
  final SearchHit hit;

  /// 实际发送的节选文本（≤ [kRagSnippetChars]；面板范围行按它计字数）。
  final String text;
}

/// 组装问答消息（纯函数；F5「将发送 K 个片段，共 X 字」的 X = 片段字数和）。
List<AiMessage> ragMessages({
  required String question,
  required List<RagSnippet> snippets,
}) {
  final StringBuffer user = StringBuffer();
  user.writeln('问题：$question');
  user.writeln('原文片段（共 ${snippets.length} 个）：');
  for (int i = 0; i < snippets.length; i++) {
    final RagSnippet snippet = snippets[i];
    final String title = snippet.hit.chapterTitle.isNotEmpty
        ? snippet.hit.chapterTitle
        : '第 ${snippet.hit.chapterIndex + 1} 节';
    user.writeln('[${i + 1}]（$title）');
    user.writeln(snippet.text);
    user.writeln();
  }
  return <AiMessage>[
    const AiMessage('system', kRagSystemPrompt),
    AiMessage('user', user.toString()),
  ];
}

/// 发起一次流式问答（句柄可 cancel；错误经 stream.onError 分类抛出）。
AiCall ragCall({
  required AiClient client,
  required AiProviderConfig config,
  required String apiKey,
  required String question,
  required List<RagSnippet> snippets,
}) {
  return client.chatStream(
    config: config,
    apiKey: apiKey,
    messages: ragMessages(question: question, snippets: snippets),
  );
}

/// 检索：章级 BM25 候选 → 候选章内段级重排 → 各章最相关段落 → 预算裁剪。
/// 返回按相关度降序的 ≤ [topK] 条；零命中返空表（面板据此答「书中未提及」，
/// 不发请求）。[loadText] 单章取文失败跳过该章，不拖垮检索。
Future<List<RagSnippet>> retrieveSnippets({
  required String question,
  required RagIndex index,
  required Future<String> Function(int) loadText,
  int topK = kRagTopK,
}) async {
  final Set<String> terms = tokenize(question).toSet();
  if (terms.isEmpty || index.docLengths.isEmpty) {
    return const <RagSnippet>[];
  }
  final Map<String, double> weights = <String, double>{
    for (final String t in terms) t: t.length >= 2 ? 1.0 : 0.4,
  };
  final List<({int chapterIndex, double score})> candidates =
      index.topChapters(question, kRagChapterCandidates);
  if (candidates.isEmpty) return const <RagSnippet>[];

  final List<_ParaHit> hits = <_ParaHit>[];
  for (final ({int chapterIndex, double score}) cand in candidates) {
    String text;
    try {
      text = await loadText(cand.chapterIndex);
    } catch (_) {
      continue; // 单章取文失败：跳过该候选章（与摘要驱动同策略）。
    }
    final List<String> paragraphs = text.split('\n');
    double bestScore = 0;
    int bestPara = -1;
    int bestPos = 0;
    int bestStart = 0;
    int start = 0;
    for (int p = 0; p < paragraphs.length; p++) {
      final (double score, int pos) = _scoreParagraph(paragraphs[p], weights);
      if (score > bestScore) {
        bestScore = score;
        bestPara = p;
        bestPos = pos;
        bestStart = start;
      }
      start += paragraphs[p].length; // SearchHit.offset 同口径（无分隔符）。
    }
    if (bestPara < 0 || bestScore <= 0) continue;
    final String paragraph = paragraphs[bestPara];
    final int offset =
        bestPos < paragraph.length ? bestStart + bestPos : bestStart;
    hits.add(
      _ParaHit(
        chapterIndex: cand.chapterIndex,
        chapterTitle: index.titles.length > cand.chapterIndex
            ? index.titles[cand.chapterIndex]
            : '',
        offset: offset,
        // 段级主分 + 章级 BM25 微扰（同段分时偏向更相关的章）。
        score: bestScore + cand.score * 0.001,
        text: paragraph,
      ),
    );
  }
  hits.sort((_ParaHit a, _ParaHit b) {
    final int byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.chapterIndex.compareTo(b.chapterIndex);
  });

  final List<RagSnippet> out = <RagSnippet>[];
  int total = 0;
  for (final _ParaHit hit in hits) {
    if (out.length >= topK) break;
    String excerpt = _excerpt(hit.text, terms, kRagSnippetChars);
    if (total + excerpt.length > kRagTotalChars) {
      final int remain = kRagTotalChars - total;
      if (remain <= 0) break;
      if (out.isNotEmpty) break; // 首条即超预算：截到预算为止，保证有片段可发。
      excerpt = excerpt.substring(0, remain);
    }
    total += excerpt.length;
    out.add(
      RagSnippet(
        hit: SearchHit(
          chapterIndex: hit.chapterIndex,
          chapterTitle: hit.chapterTitle,
          offset: hit.offset,
          context: hit.text,
        ),
        text: excerpt,
      ),
    );
  }
  return out;
}

/// 段落打分：命中词加权计数（长词元权重高），并返回最早命中位。
(double, int) _scoreParagraph(String paragraph, Map<String, double> weights) {
  if (paragraph.isEmpty) return (0, 0);
  final String lower = paragraph.toLowerCase();
  double score = 0;
  int first = -1;
  weights.forEach((String token, double weight) {
    int idx = lower.indexOf(token);
    if (idx < 0) return;
    int count = 0;
    while (idx >= 0) {
      count++;
      if (first < 0 || idx < first) first = idx;
      idx = lower.indexOf(token, idx + token.length);
    }
    score += weight * count;
  });
  if (first < 0 || first >= paragraph.length) return (score, 0);
  return (score, first);
}

/// 超长段落按最早命中位开窗（前留 1/6 上文），保证节选 ≤ [maxChars]。
String _excerpt(String paragraph, Set<String> terms, int maxChars) {
  if (paragraph.length <= maxChars) return paragraph;
  final String lower = paragraph.toLowerCase();
  int pos = -1;
  for (final String token in terms) {
    final int i = lower.indexOf(token);
    if (i >= 0 && (pos < 0 || i < pos)) pos = i;
  }
  if (pos < 0) return paragraph.substring(0, maxChars);
  int start = pos - maxChars ~/ 6;
  if (start > paragraph.length - maxChars) {
    start = paragraph.length - maxChars;
  }
  if (start < 0) start = 0;
  return paragraph.substring(start, start + maxChars);
}

/// 段级命中的中间产物（排序后映射到 [RagSnippet]）。
class _ParaHit {
  _ParaHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.offset,
    required this.score,
    required this.text,
  });

  final int chapterIndex;
  final String chapterTitle;
  final int offset;
  final double score;
  final String text;
}

/// 一次问答的结果。
class RagOutcome {
  const RagOutcome({required this.text, required this.cancelled});

  /// 完整答案（取消时为已生成的部分）。
  final String text;

  /// 是否被 [RagJob.cancel] 中断。
  final bool cancelled;
}

/// 一次可取消的问答作业（一个面板一个实例；dispose 时必须 [cancel]）。
/// 形制照 `SummaryJob`：协作式取消——步骤间检查 `_cancelled`，在途请求经
/// [AiCall.cancel] 中止（静默收流，不留半截缓存）。
class RagJob {
  RagJob({required this.client, required this.config, required this.apiKey});

  final AiClient client;
  final AiProviderConfig config;
  final String apiKey;

  AiCall? _call;
  bool _cancelled = false;

  /// 是否已取消。
  bool get isCancelled => _cancelled;

  /// 中断：置位 + 中止在途请求（幂等；`AI-08` ①）。
  void cancel() {
    _cancelled = true;
    _call?.cancel();
  }

  /// 发起一次流式问答（[onDelta] 逐字回调）；取消时返回**已生成的部分**
  /// （面板保留可见文本；问答无结果缓存，半截文本不会被当成品复用）。
  Future<RagOutcome> ask({
    required String question,
    required List<RagSnippet> snippets,
    void Function(String delta)? onDelta,
  }) async {
    if (_cancelled) return const RagOutcome(text: '', cancelled: true);
    final String out = await _collect(
      ragCall(
        client: client,
        config: config,
        apiKey: apiKey,
        question: question,
        snippets: snippets,
      ),
      onDelta: onDelta,
    );
    return RagOutcome(text: out, cancelled: _cancelled);
  }

  /// 收流到完整文本（登记在途句柄供 [cancel] 中止；onDelta 逐字转发）。
  Future<String> _collect(
    AiCall call, {
    void Function(String delta)? onDelta,
  }) async {
    _call = call;
    final StringBuffer out = StringBuffer();
    try {
      await for (final String delta in call.stream) {
        out.write(delta);
        onDelta?.call(delta);
      }
    } finally {
      if (identical(_call, call)) _call = null;
    }
    return out.toString();
  }
}

/// 跟书问答索引存储（进程内共享，按 bookId 分文件持久化；`aiCache/` 目录）。
/// 形制仿 [SummaryCache]（JsonStore → AtomicFile，`DATA-01` 原子写入），差异是
/// **惰性按书加载**：无全局 `load()`，首次提问走 [ensure]（内存 → 磁盘 → 构建），
/// 构建分章 yield 不卡死主 isolate。
class RagIndexStore {
  RagIndexStore([Directory? dir])
      : _dir = dir,
        _sep = Platform.pathSeparator;

  final Directory? _dir;
  final String _sep;

  final Map<String, RagIndex> _mem = <String, RagIndex>{};

  /// 在途构建去重（同一本书并发 ensure 只构建一次）。
  final Map<String, Future<RagIndex>> _pending = <String, Future<RagIndex>>{};

  /// 取（或构建）某书的索引；[titles] 与 [loadText] 只在**需要构建**时消费，
  /// 磁盘命中直接返回不触发取文（重开零解析，PRD §8.3 缓存策略）。
  Future<RagIndex> ensure({
    required String bookId,
    required List<String> titles,
    required Future<String> Function(int) loadText,
  }) {
    final RagIndex? cached = _mem[bookId];
    if (cached != null) return Future<RagIndex>.value(cached);
    final Future<RagIndex>? pending = _pending[bookId];
    if (pending != null) return pending;
    final Future<RagIndex> future = _ensureImpl(
      bookId: bookId,
      titles: titles,
      loadText: loadText,
    );
    _pending[bookId] = future;
    return future.whenComplete(() {
      if (identical(_pending[bookId], future)) _pending.remove(bookId);
    });
  }

  Future<RagIndex> _ensureImpl({
    required String bookId,
    required List<String> titles,
    required Future<String> Function(int) loadText,
  }) async {
    final JsonStore? store = _jsonStore(bookId);
    // ① 磁盘命中（`AI-06` 索引本地持久化；重开零构建）。
    if (store != null) {
      final PerfWatch watch = PerfLog.watch('rag.index.load');
      try {
        final Object? json = await store.read();
        final RagIndex? loaded = json == null ? null : RagIndex.fromJson(json);
        watch.done('bookId=$bookId hit=${loaded != null}');
        if (loaded != null) {
          _mem[bookId] = loaded;
          return loaded;
        }
      } catch (_) {
        watch.done('bookId=$bookId error');
        // 读盘失败按未缓存处理 → 走构建。
      }
    }
    // ② 构建：分章取文 + 分词，周期性 yield（阈值 5 的计时口径 = build 段）。
    final PerfWatch build = PerfLog.watch('rag.index.build');
    final RagIndexBuilder builder = RagIndexBuilder();
    int origChars = 0;
    for (int i = 0; i < titles.length; i++) {
      String text;
      try {
        text = await loadText(i);
      } catch (_) {
        text = ''; // 单章取文失败：按空章入索引，不拖垮整轮。
      }
      origChars += text.length;
      builder.addChapter(titles[i], text);
      if (i % 16 == 15) {
        await Future<void>.delayed(Duration.zero); // 让出事件循环，不连续卡帧。
      }
    }
    final RagIndex index =
        titles.isEmpty ? RagIndex.empty() : builder.finish();
    build.done(
      'bookId=$bookId chapters=${builder.chapterCount} '
      'tokens=${builder.totalTokens}',
    );
    PerfLog.mark(
      'rag.index.mem',
      'bookId=$bookId terms=${index.postings.length} '
      'est=${index.approxBytes}B origChars=$origChars '
      'ratio=${(index.approxBytes / (origChars * 2)).toStringAsFixed(2)}',
    );
    _mem[bookId] = index;
    // ③ 落盘（失败静默：内存索引仍可用，下次再试）。
    if (store != null && titles.isNotEmpty) {
      final PerfWatch persist = PerfLog.watch('rag.index.persist');
      try {
        await store.write(index.toJson());
        persist.done('bookId=$bookId');
      } catch (_) {
        persist.done('bookId=$bookId error');
      }
    }
    return index;
  }

  /// 删除某书的索引（书架删书连带清理；内存 + 磁盘含备份/隔离文件）。
  Future<void> removeBook(String bookId) async {
    _mem.remove(bookId);
    _pending.remove(bookId);
    final Directory? dir = _dir;
    if (dir == null) return;
    for (final String suffix in <String>['', '.bak', '.corrupt', '.tmp']) {
      final File file = File('${dir.path}${_sep}rag_$bookId.json$suffix');
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 删除失败不影响主流程（残留由下次同 bookId 覆盖写自愈）。
      }
    }
  }

  /// 某书的 JSON 通道；`dir == null`（测试 / 未接线）= 纯内存模式。
  JsonStore? _jsonStore(String bookId) {
    final Directory? dir = _dir;
    if (dir == null) return null;
    return JsonStore(AtomicFile('${dir.path}${_sep}rag_$bookId.json'));
  }
}
