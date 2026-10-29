// 递进摘要驱动（`AI-04` 章节摘要 / `AI-05` 全书摘要 + 前情回顾）。
//
// 验收落点：`AI-05` ③ 长书可中断可续做：逐章生成、**每章完成即写
// [SummaryCache] 章级缓存**，中断（[SummaryJob.cancel]）后重跑已生成章直接
// 命中跳过、只补缺章——续做的持久化点就是章级缓存本身；schedule:222「缓存键
// 必须能区分生成到第几章」：章级键含 href+hash+模型+长度，合并级键含范围
// 起止章 + inputHash（见 summary_cache.dart 头注）；PRD §8.3「超长则分块
// 递进」：> [kSummaryChunkChars] 的章先分块各自出梗概再合并
// （[SummaryJob._summarizeLong]）。
//
// 驱动层**不依赖 Flutter / BookSource**：章文本经 `loadText` 回调注入，
// 本文件只做编排 + 缓存 + 取消。
import 'dart:async';

import 'ai_client.dart';
import 'provider_config.dart';
import 'summarize.dart';
import 'summary_cache.dart';

/// 前情回顾：停读阈值（天；PRD S3「停读一周回来」）。
const int kRecapIdleDays = 7;

/// 前情回顾：覆盖「上次读到位置」往前的章数（`AI-05` ② 近 N 章）。
const int kRecapRecentChapters = 5;

/// 全书摘要目标字数。
const int kBookSummaryMaxChars = 1000;

/// 前情回顾目标字数（30 秒读完量级，PRD S3）。
const int kRecapMaxChars = 400;

/// 章文本加载回调（注入缝：阅读页给纯文本，测试给字面量）。
typedef ChapterTextLoader = Future<String> Function(int index);

/// 一次递进摘要的结果。
class SummaryOutcome {
  const SummaryOutcome({
    required this.text,
    required this.chaptersDone,
    required this.chaptersTotal,
    required this.cancelled,
    required this.fromCache,
  });

  /// 合并结果（中途取消且未走到合并 → 空串）。
  final String text;

  /// 范围内已生成（含缓存命中）的章数。
  final int chaptersDone;
  final int chaptersTotal;

  /// 是否被 [SummaryJob.cancel] 中断。
  final bool cancelled;

  /// 合并级缓存直接命中（未发合并请求；章级全命中时也不发章请求）。
  final bool fromCache;

  /// 空结果 = 一步都没完成（未配置 / 首章失败等，UI 给错误态）。
  bool get isEmpty => text.isEmpty;
}

/// 一次可取消的摘要作业（一个面板一个实例；dispose 时必须 [cancel]）。
/// 取消是协作式的：步骤间检查 `_cancelled`，在途请求经 [AiCall.cancel] 中止
/// （静默收流，不把半截文本写缓存）。
class SummaryJob {
  SummaryJob({
    required this.client,
    required this.config,
    required this.apiKey,
    required this.cache,
  });

  final AiClient client;
  final AiProviderConfig config;
  final String apiKey;
  final SummaryCache cache;

  AiCall? _call;
  bool _cancelled = false;

  /// 是否已取消。
  bool get isCancelled => _cancelled;

  /// 中断：置位 + 中止在途请求（幂等；`AI-08` ①）。
  void cancel() {
    _cancelled = true;
    _call?.cancel();
  }

  /// `AI-04`：单章摘要（带缓存 + 超长分块）。[onDelta] 逐字回调（单块直发
  /// 流式；分块章在最终合并段才回调）；[force] = `AI-04` ③ 手动重新生成：
  /// 绕过缓存读，结果仍回写覆盖；取消时返回**已生成的部分**且**不写缓存**。
  Future<SummaryOutcome> chapter({
    required String bookId,
    required String href,
    required String title,
    required String text,
    int maxChars = kSummaryDefaultChars,
    bool force = false,
    void Function(String delta)? onDelta,
  }) async {
    final String model = config.model;
    final String hash = summaryContentHash(text);
    final ChapterSummaryEntry? hit = force
        ? null
        : cache.findChapter(
            bookId: bookId,
            chapterHref: href,
            contentHash: hash,
            model: model,
            maxChars: maxChars,
          );
    if (hit != null) {
      return SummaryOutcome(
        text: hit.text,
        chaptersDone: 1,
        chaptersTotal: 1,
        cancelled: false,
        fromCache: true,
      );
    }
    if (_cancelled) {
      return const SummaryOutcome(
        text: '',
        chaptersDone: 0,
        chaptersTotal: 1,
        cancelled: true,
        fromCache: false,
      );
    }

    final String out = text.length > kSummaryChunkChars
        ? await _summarizeLong(
            text: text,
            title: title,
            maxChars: maxChars,
            onDelta: onDelta,
          )
        : await _collect(
            summarizeChapter(
              client: client,
              config: config,
              apiKey: apiKey,
              text: text,
              maxChars: maxChars,
              title: title,
            ),
            onDelta: onDelta,
          );
    if (_cancelled) {
      return SummaryOutcome(
        text: out,
        chaptersDone: 0,
        chaptersTotal: 1,
        cancelled: true,
        fromCache: false,
      );
    }
    await cache.putChapter(
      ChapterSummaryEntry(
        bookId: bookId,
        chapterHref: href,
        contentHash: hash,
        model: model,
        maxChars: maxChars,
        text: out,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return SummaryOutcome(
      text: out,
      chaptersDone: 1,
      chaptersTotal: 1,
      cancelled: false,
      fromCache: false,
    );
  }

  /// `AI-05` ①：全书摘要——章级递进生成（0..[uptoChapter]）后合并。
  /// [loadText] 按章索引取纯文本；[onProgress] 每完成一章回调一次（含缓存
  /// 命中）；[onDelta] 合并段流式增量。
  Future<SummaryOutcome> book({
    required String bookId,
    required int uptoChapter,
    required List<String> hrefs,
    required List<String> titles,
    required ChapterTextLoader loadText,
    void Function(int done, int total)? onProgress,
    void Function(String delta)? onDelta,
  }) {
    return _run(
      kind: 'book',
      bookId: bookId,
      fromChapter: 0,
      uptoChapter: uptoChapter,
      hrefs: hrefs,
      titles: titles,
      loadText: loadText,
      maxChars: kBookSummaryMaxChars,
      instruction: null,
      onProgress: onProgress,
      onDelta: onDelta,
    );
  }

  /// `AI-05` ②：前情回顾——覆盖 [uptoChapter] 往前近 [kRecapRecentChapters]
  /// 章的窗口（范围夹在 0..upto），合并时带上「上次读到位置」背景。
  Future<SummaryOutcome> recap({
    required String bookId,
    required int uptoChapter,
    required List<String> hrefs,
    required List<String> titles,
    required ChapterTextLoader loadText,
    void Function(int done, int total)? onProgress,
    void Function(String delta)? onDelta,
  }) {
    final int from =
        uptoChapter - kRecapRecentChapters + 1 < 0
            ? 0
            : uptoChapter - kRecapRecentChapters + 1;
    final String chapterTitle = uptoChapter >= 0 && uptoChapter < titles.length
        ? titles[uptoChapter]
        : '';
    return _run(
      kind: 'recap',
      bookId: bookId,
      fromChapter: from,
      uptoChapter: uptoChapter,
      hrefs: hrefs,
      titles: titles,
      loadText: loadText,
      maxChars: kRecapMaxChars,
      instruction: '读者停读一段时间后回来，上次读到第 ${uptoChapter + 1} 章'
          '${chapterTitle.isEmpty ? '' : '（$chapterTitle）'}。'
          '请生成一份帮助他接上剧情的前情回顾。',
      onProgress: onProgress,
      onDelta: onDelta,
    );
  }

  // ---------------------------------------------------------------- 内部

  /// 递进主流程：逐章（章级缓存）→ 合并（合并级缓存）。
  Future<SummaryOutcome> _run({
    required String kind,
    required String bookId,
    required int fromChapter,
    required int uptoChapter,
    required List<String> hrefs,
    required List<String> titles,
    required ChapterTextLoader loadText,
    required int maxChars,
    required String? instruction,
    required void Function(int done, int total)? onProgress,
    required void Function(String delta)? onDelta,
  }) async {
    final int total = uptoChapter - fromChapter + 1;
    if (total <= 0 || uptoChapter >= hrefs.length) {
      return SummaryOutcome(
        text: '',
        chaptersDone: 0,
        chaptersTotal: total < 0 ? 0 : total,
        cancelled: false,
        fromCache: false,
      );
    }
    final String model = config.model;
    final List<String> parts = <String>[];
    final List<String> hashes = <String>[];
    int done = 0;
    for (int i = fromChapter; i <= uptoChapter; i++) {
      if (_cancelled) break;
      String text;
      try {
        text = await loadText(i);
      } catch (_) {
        text = ''; // 单章取文失败：跳过该章，不拖垮整轮（下轮可补）。
      }
      final String hash = text.isEmpty ? '' : summaryContentHash(text);
      ChapterSummaryEntry? entry;
      if (hash.isNotEmpty) {
        entry = cache.findChapter(
          bookId: bookId,
          chapterHref: hrefs[i],
          contentHash: hash,
          model: model,
          maxChars: kSummaryDefaultChars,
        );
        if (entry == null && text.isNotEmpty) {
          final String part = text.length > kSummaryChunkChars
              ? await _summarizeLong(
                  text: text,
                  title: titles[i],
                  maxChars: kSummaryDefaultChars,
                )
              : await _collect(
                  summarizeChapter(
                    client: client,
                    config: config,
                    apiKey: apiKey,
                    text: text,
                    maxChars: kSummaryDefaultChars,
                    title: titles[i],
                  ),
                );
          if (_cancelled) break;
          entry = ChapterSummaryEntry(
            bookId: bookId,
            chapterHref: hrefs[i],
            contentHash: hash,
            model: model,
            maxChars: kSummaryDefaultChars,
            text: part,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          );
          await cache.putChapter(entry);
        }
      }
      if (entry != null) {
        parts.add(titles[i].isEmpty ? entry.text : '${titles[i]}：${entry.text}');
        hashes.add(hash);
      }
      done++;
      onProgress?.call(done, total);
    }
    if (_cancelled) {
      return SummaryOutcome(
        text: '',
        chaptersDone: done,
        chaptersTotal: total,
        cancelled: true,
        fromCache: false,
      );
    }
    if (parts.isEmpty) {
      return SummaryOutcome(
        text: '',
        chaptersDone: done,
        chaptersTotal: total,
        cancelled: false,
        fromCache: false,
      );
    }

    final String inputHash = summaryContentHash(hashes.join('|'));
    final BookSummaryEntry? hit = cache.findBook(
      bookId: bookId,
      model: model,
      kind: kind,
      fromChapter: fromChapter,
      uptoChapter: uptoChapter,
      inputHash: inputHash,
    );
    if (hit != null) {
      return SummaryOutcome(
        text: hit.text,
        chaptersDone: done,
        chaptersTotal: total,
        cancelled: false,
        fromCache: true,
      );
    }

    final String merged = await _collect(
      mergeSummaries(
        client: client,
        config: config,
        apiKey: apiKey,
        parts: parts,
        maxChars: maxChars,
        instruction: instruction,
      ),
      onDelta: onDelta,
    );
    if (_cancelled) {
      return SummaryOutcome(
        text: '',
        chaptersDone: done,
        chaptersTotal: total,
        cancelled: true,
        fromCache: false,
      );
    }
    await cache.putBook(
      BookSummaryEntry(
        bookId: bookId,
        model: model,
        kind: kind,
        fromChapter: fromChapter,
        uptoChapter: uptoChapter,
        inputHash: inputHash,
        text: merged,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return SummaryOutcome(
      text: merged,
      chaptersDone: done,
      chaptersTotal: total,
      cancelled: false,
      fromCache: false,
    );
  }

  /// 超长章：分块各自出梗概 → 合并成章梗概（PRD §8.3 分块递进）。
  Future<String> _summarizeLong({
    required String text,
    required String title,
    required int maxChars,
    void Function(String delta)? onDelta,
  }) async {
    final List<String> chunks = splitSummaryChunks(text);
    final List<String> parts = <String>[];
    for (final String chunk in chunks) {
      if (_cancelled) return parts.join('\n');
      parts.add(
        await _collect(
          summarizeChapter(
            client: client,
            config: config,
            apiKey: apiKey,
            text: chunk,
            maxChars: kSummaryDefaultChars,
            title: title,
          ),
        ),
      );
    }
    if (_cancelled || parts.length == 1) return parts.join('\n');
    return _collect(
      mergeSummaries(
        client: client,
        config: config,
        apiKey: apiKey,
        parts: parts,
        maxChars: maxChars,
        instruction: title.isEmpty ? null : '本章标题：$title。合并以上片段梗概为该章完整梗概。',
      ),
      onDelta: onDelta,
    );
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

/// 把超长文本按段落边界切成 ≤ [kSummaryChunkChars] 的块（纯函数）。
List<String> splitSummaryChunks(String text) {
  if (text.length <= kSummaryChunkChars) return <String>[text];
  final List<String> chunks = <String>[];
  final StringBuffer buf = StringBuffer();
  for (final String line in text.split('\n')) {
    String rest = line;
    // 单行超限：先硬切成整块（残段继续走常规累积）。
    while (rest.length > kSummaryChunkChars) {
      if (buf.isNotEmpty) {
        chunks.add(buf.toString());
        buf.clear();
      }
      chunks.add(rest.substring(0, kSummaryChunkChars));
      rest = rest.substring(kSummaryChunkChars);
    }
    if (buf.isNotEmpty && buf.length + 1 + rest.length > kSummaryChunkChars) {
      chunks.add(buf.toString());
      buf.clear();
    }
    if (buf.isNotEmpty) buf.write('\n');
    buf.write(rest);
  }
  if (buf.isNotEmpty) chunks.add(buf.toString());
  return chunks.isEmpty ? <String>[text] : chunks;
}

/// 是否应显示「前情回顾」入口（`AI-05` ②：停读 ≥ [kRecapIdleDays] 天）。
/// [lastReadAtMs] = 上次进度的 `updatedAt`（Unix 毫秒）；无进度 / 时间戳
/// 非法返 false（没读过书不出回顾入口）。
bool shouldShowRecapEntrance({
  required int? lastReadAtMs,
  required int nowMs,
}) {
  if (lastReadAtMs == null || lastReadAtMs <= 0) return false;
  final int idleDays =
      ((nowMs - lastReadAtMs) / Duration.millisecondsPerDay).floor();
  return idleDays >= kRecapIdleDays;
}
