// 人物关系与设定梳理驱动（M3-T05：`AI-07`）。
//
// 验收对应：
//   · `AI-07` ① 名字与书中一致：抽取提示词强制 name 用正文原写法，成品原样
//     展示不改写；
//   · `AI-07` ② 每条含出场章节引用：chapters 由模型按输入里的【章节 N】标注
//     回填（0-based），点章跳转经 UI 的 onJump 回调；
//   · `AI-07` ③ 「仅已读部分」防剧透：本层只按传入的 from..upto 抽取，
//     范围夹取（0..readUpto，RD-04 `chapterIndex` 口径）由调用方决定；
//   · `AI-08` ① 流式（JSONL 逐行解析、边抽边回调）/ 可取消（协作式 +
//     [AiCall.cancel]，中断不写缓存）/ 结果缓存（PRD §8.3「按 进度范围 +
//     内容 hash」——复用 [SummaryCache] 合并级条目，kind = [kEntityCacheKind]）。
//
// 输出契约（提示词钉死 JSON Lines）：每行一个
// `{"name":…,"type":"人物|势力|专有名词","desc":…,"chapters":[N]}`；
// [parseEntityOutput] 对模型不守约（数组 / 围栏 / pretty-print 多对象）做整段
// 兜底。跨段去重合并在**代码侧**完成（[mergeEntityItems]）——不经模型二次
// 合并，名字与章节引用原样保真（验收①② 的关键取舍）。
//
// 驱动层不依赖 Flutter / BookSource：章文本经 `loadText` 回调注入，本文件只做
// 编排 + 缓存 + 取消（形制照 [SummaryJob]）。
import 'dart:convert';

import 'ai_client.dart';
import 'provider_config.dart';
import 'recap.dart';
import 'summarize.dart';
import 'summary_cache.dart';

/// 成品缓存的 kind（[BookSummaryEntry] 白名单之一；text 存 [encodeEntities]）。
const String kEntityCacheKind = 'entities';

/// 分段阈值：与摘要分块同值（超长章复用 [splitSummaryChunks] 的切块边界）。
const int kEntityChunkChars = kSummaryChunkChars;

/// 三类实体（提示词、校验与展示共用；顺序即页面分组顺序）。
const List<String> kEntityTypes = <String>['人物', '势力', '专有名词'];

/// 抽取系统提示词（JSON Lines 输出契约 + 名字原写法 + 章节引用规则）。
const String kEntityExtractSystemPrompt =
    '你是阅读助手。请从给定正文中抽取值得梳理的实体，分三类：人物、势力、专有名词。'
    '严格按 JSON Lines 输出：每行一个 JSON 对象，形如 '
    '{"name":"某人","type":"人物","desc":"一句话描述","chapters":[0,2]}，'
    '不要用数组包裹整体，不要输出代码围栏或解释文字。'
    'name 必须与正文中的写法完全一致；type 只能是「人物」「势力」「专有名词」之一；'
    'desc 为简体中文一句话，说明身份与同其他实体的关系；'
    'chapters 只列输入中【章节 N】出现过的编号（整数）。'
    '只抽取正文中实际出现的实体，不要编造。';

/// 一个梳理实体（不可变值对象）。
class EntityItem {
  const EntityItem({
    required this.name,
    required this.type,
    required this.desc,
    required this.chapters,
  });

  /// 实体名（与正文写法一致，`AI-07` ①）。
  final String name;

  /// 类型（[kEntityTypes] 之一；[fromJson] 校验，非法即整条丢弃）。
  final String type;

  /// 关系 / 设定描述。
  final String desc;

  /// 出场章节（0-based，`AI-07` ②）。
  final List<int> chapters;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'type': type,
        'desc': desc,
        'chapters': <int>[...chapters],
      };

  /// 严格校验：name 非空 + type 合法，否则返回 null（坏条目整条跳过）。
  static EntityItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? name = json['name'];
    final Object? type = json['type'];
    if (name is! String ||
        name.isEmpty ||
        type is! String ||
        !kEntityTypes.contains(type)) {
      return null;
    }
    final Object? desc = json['desc'];
    final List<int> chapters = <int>[];
    final Object? raw = json['chapters'];
    if (raw is List) {
      for (final Object? c in raw) {
        if (c is num && c >= 0) chapters.add(c.toInt());
      }
    }
    return EntityItem(
      name: name,
      type: type,
      desc: desc is String ? desc : '',
      chapters: chapters,
    );
  }
}

/// 成品序列化（进 [SummaryCache] 合并级条目的 text 字段）。
String encodeEntities(List<EntityItem> items) =>
    jsonEncode(<Object?>[for (final EntityItem e in items) e.toJson()]);

/// 成品反序列化（坏 JSON → 空表：命中条目损坏时按无成品处理）。
List<EntityItem> decodeEntities(String raw) {
  try {
    final Object? value = jsonDecode(raw);
    if (value is! List) return <EntityItem>[];
    return <EntityItem?>[
      for (final Object? e in value) EntityItem.fromJson(e),
    ].whereType<EntityItem>().toList();
  } catch (_) {
    return <EntityItem>[];
  }
}

/// 单行解析（流式增量用；非对象行 / 坏行 → null）。
EntityItem? parseEntityLine(String line) {
  final String s = line.trim();
  if (s.isEmpty || !s.startsWith('{') || !s.endsWith('}')) return null;
  try {
    return EntityItem.fromJson(jsonDecode(s));
  } catch (_) {
    return null;
  }
}

/// 整段兜底解析：模型不守 JSON Lines（数组 / 代码围栏 / pretty-print 多对象）
/// 时对原始输出再解析一次（流式行解析一条都没中时调用）。
List<EntityItem> parseEntityOutput(String raw) {
  String text = raw.trim();
  if (text.isEmpty) return <EntityItem>[];
  if (text.startsWith('```')) {
    text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
    text = text.replaceFirst(RegExp(r'\s*```$'), '');
    text = text.trim();
  }
  // 整体是数组 / 单对象。
  try {
    final Object? value = jsonDecode(text);
    if (value is List) {
      return <EntityItem?>[
        for (final Object? e in value) EntityItem.fromJson(e),
      ].whereType<EntityItem>().toList();
    }
    final EntityItem? one = EntityItem.fromJson(value);
    if (one != null) return <EntityItem>[one];
  } catch (_) {
    // 落到下一档。
  }
  // pretty-print 多对象：`}\s*{` → `},{` 后当数组解。
  try {
    final Object? value =
        jsonDecode('[${text.replaceAll(RegExp(r'}\s*{'), '},{')}]');
    if (value is List) {
      return <EntityItem?>[
        for (final Object? e in value) EntityItem.fromJson(e),
      ].whereType<EntityItem>().toList();
    }
  } catch (_) {
    // 落到下一档。
  }
  // 逐行兜底。
  final List<EntityItem> items = <EntityItem>[];
  for (final String line in text.split('\n')) {
    final EntityItem? item = parseEntityLine(line);
    if (item != null) items.add(item);
  }
  return items;
}

/// 跨段去重合并（纯函数）：同名首见优先（类型保留首见），章节取并集排序，
/// 描述非重复时用「；」递接。
List<EntityItem> mergeEntityItems(Iterable<EntityItem> items) {
  final Map<String, EntityItem> byName = <String, EntityItem>{};
  for (final EntityItem item in items) {
    final EntityItem? prev = byName[item.name];
    if (prev == null) {
      byName[item.name] = item;
      continue;
    }
    final List<int> chapters = <int>{...prev.chapters, ...item.chapters}.toList()
      ..sort();
    String desc = prev.desc;
    if (item.desc.isNotEmpty && !desc.contains(item.desc)) {
      desc = desc.isEmpty ? item.desc : '$desc；${item.desc}';
    }
    byName[item.name] = EntityItem(
      name: prev.name,
      type: prev.type,
      desc: desc,
      chapters: chapters,
    );
  }
  return byName.values.toList(growable: false);
}

/// 组装单段抽取消息（纯函数；[text] 为带【章节 N】标注的正文）。
List<AiMessage> entityExtractMessages({required String text}) => <AiMessage>[
      const AiMessage('system', kEntityExtractSystemPrompt),
      AiMessage('user', text),
    ];

/// 一次人物梳理作业的结果。
class EntityOutcome {
  const EntityOutcome({
    required this.items,
    required this.chunksDone,
    required this.chunksTotal,
    required this.cancelled,
    required this.fromCache,
  });

  /// 成品（合并去重后；取消时为已完成段的部分结果）。
  final List<EntityItem> items;

  /// 分段进度（缓存命中为 0/0，UI 不显示进度）。
  final int chunksDone;
  final int chunksTotal;

  /// 是否被 [EntityJob.cancel] 中断。
  final bool cancelled;

  /// 缓存直接命中（零请求）。
  final bool fromCache;

  /// 空结果 = 一段都没抽出来（无正文 / 模型空输出，UI 给空完成态）。
  bool get isEmpty => items.isEmpty;
}

/// 一次可取消的人物梳理作业（一个页面一个实例；dispose 时必须 [cancel]）。
///
/// 取消是协作式的：步骤间检查 `_cancelled`，在途请求经 [AiCall.cancel] 中止
/// （静默收流，半截结果**不写缓存**，`AI-08` ①）。
class EntityJob {
  EntityJob({
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

  /// 中断：置位 + 中止在途请求（幂等）。
  void cancel() {
    _cancelled = true;
    _call?.cancel();
  }

  /// 抽取范围 [fromChapter]..[uptoChapter]（闭区间）内各章的实体清单。
  ///
  /// 流程：取文 → 算范围内容 hash → 分段打包 → 查缓存 → 逐段流式抽取
  /// （JSONL 逐行解析，[onItems] 每抽到一条回调一次合并快照）→ 合并去重
  /// → 落缓存。[force] 绕过缓存读，结果仍回写。
  Future<EntityOutcome> run({
    required String bookId,
    required int fromChapter,
    required int uptoChapter,
    required List<String> hrefs,
    required List<String> titles,
    required ChapterTextLoader loadText,
    bool force = false,
    void Function(int done, int total)? onProgress,
    void Function(List<EntityItem> items)? onItems,
  }) async {
    final int total = uptoChapter - fromChapter + 1;
    if (fromChapter < 0 || total <= 0 || uptoChapter >= hrefs.length) {
      return const EntityOutcome(
        items: <EntityItem>[],
        chunksDone: 0,
        chunksTotal: 0,
        cancelled: false,
        fromCache: false,
      );
    }

    // 取文 + 范围内容 hash（缓存键 = 进度范围 + 内容 hash，PRD §8.3）。
    final List<String> texts = <String>[];
    final List<String> hashParts = <String>[];
    for (int i = fromChapter; i <= uptoChapter; i++) {
      String text;
      try {
        text = await loadText(i);
      } catch (_) {
        text = ''; // 单章取文失败：跳过该章，不拖垮整轮。
      }
      texts.add(text);
      hashParts.add(
        '${hrefs[i]}:${text.isEmpty ? '' : summaryContentHash(text)}',
      );
    }
    if (_cancelled) return _cancelledOutcome(0, 0, const <EntityItem>[]);

    // 切段：超长章先按摘要同边界分块，再按段落累计打包（单段 ≤ 阈值）。
    final List<_Piece> pieces = <_Piece>[];
    for (int t = 0; t < texts.length; t++) {
      final String text = texts[t];
      if (text.isEmpty) continue;
      final int i = fromChapter + t;
      final String title = i < titles.length ? titles[i] : '';
      if (text.length > kEntityChunkChars) {
        for (final String part in splitSummaryChunks(text)) {
          pieces.add(_Piece(i, title, part));
        }
      } else {
        pieces.add(_Piece(i, title, text));
      }
    }
    final List<List<_Piece>> chunks = <List<_Piece>>[];
    List<_Piece> cur = <_Piece>[];
    int curLen = 0;
    for (final _Piece p in pieces) {
      final int add = p.text.length + p.title.length + 24;
      if (cur.isNotEmpty && curLen + add > kEntityChunkChars) {
        chunks.add(cur);
        cur = <_Piece>[];
        curLen = 0;
      }
      cur.add(p);
      curLen += add;
    }
    if (cur.isNotEmpty) chunks.add(cur);
    if (chunks.isEmpty) {
      // 范围内没有可分析的正文：零请求空结果。
      return const EntityOutcome(
        items: <EntityItem>[],
        chunksDone: 0,
        chunksTotal: 0,
        cancelled: false,
        fromCache: false,
      );
    }

    final String model = config.model;
    final String inputHash = summaryContentHash(hashParts.join('|'));
    final BookSummaryEntry? hit = force
        ? null
        : cache.findBook(
            bookId: bookId,
            model: model,
            kind: kEntityCacheKind,
            fromChapter: fromChapter,
            uptoChapter: uptoChapter,
            inputHash: inputHash,
          );
    if (hit != null) {
      return EntityOutcome(
        items: decodeEntities(hit.text),
        chunksDone: chunks.length,
        chunksTotal: chunks.length,
        cancelled: false,
        fromCache: true,
      );
    }

    final List<EntityItem> found = <EntityItem>[];
    int done = 0;
    for (final List<_Piece> chunk in chunks) {
      if (_cancelled) break;
      final (String raw, int parsed) = await _collectLines(
        client.chatStream(
          config: config,
          apiKey: apiKey,
          messages: entityExtractMessages(text: _chunkText(chunk)),
        ),
        found: found,
        onItems: onItems,
      );
      if (_cancelled) break;
      // 行解析一条都没中（数组 / 围栏 / pretty-print）→ 整段兜底解析。
      if (parsed == 0) {
        found.addAll(parseEntityOutput(raw));
        _notify(onItems, found);
      }
      done++;
      onProgress?.call(done, chunks.length);
    }
    final List<EntityItem> items = mergeEntityItems(found);
    if (_cancelled) {
      // 中断：部分结果回传给 UI 展示，但**不写缓存**（半截不可当成品）。
      return EntityOutcome(
        items: items,
        chunksDone: done,
        chunksTotal: chunks.length,
        cancelled: true,
        fromCache: false,
      );
    }
    if (items.isNotEmpty) {
      await cache.putBook(
        BookSummaryEntry(
          bookId: bookId,
          model: model,
          kind: kEntityCacheKind,
          fromChapter: fromChapter,
          uptoChapter: uptoChapter,
          inputHash: inputHash,
          text: encodeEntities(items),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return EntityOutcome(
      items: items,
      chunksDone: done,
      chunksTotal: chunks.length,
      cancelled: false,
      fromCache: false,
    );
  }

  /// 收流 + 增量按行解析（JSONL 流式：每凑齐一行抽一条并回调合并快照）。
  ///
  /// 返回 (原始输出, 行解析成功条数)；坏行留给整段兜底。
  Future<(String, int)> _collectLines(
    AiCall call, {
    required List<EntityItem> found,
    required void Function(List<EntityItem> items)? onItems,
  }) async {
    _call = call;
    final StringBuffer raw = StringBuffer();
    String buf = '';
    int parsed = 0;
    try {
      await for (final String delta in call.stream) {
        raw.write(delta);
        buf += delta;
        if (!buf.contains('\n')) continue;
        final List<String> lines = buf.split('\n');
        buf = lines.removeLast();
        for (final String line in lines) {
          final EntityItem? item = parseEntityLine(line);
          if (item == null) continue;
          found.add(item);
          parsed++;
          _notify(onItems, found);
        }
      }
      // 无换行结尾的尾行。
      final EntityItem? last = parseEntityLine(buf);
      if (last != null) {
        found.add(last);
        parsed++;
        _notify(onItems, found);
      }
    } finally {
      if (identical(_call, call)) _call = null;
    }
    return (raw.toString(), parsed);
  }

  void _notify(
    void Function(List<EntityItem> items)? onItems,
    List<EntityItem> found,
  ) {
    onItems?.call(List<EntityItem>.unmodifiable(mergeEntityItems(found)));
  }

  EntityOutcome _cancelledOutcome(
    int done,
    int total,
    List<EntityItem> items,
  ) =>
      EntityOutcome(
        items: items,
        chunksDone: done,
        chunksTotal: total,
        cancelled: true,
        fromCache: false,
      );
}

/// 一段待发送正文（章索引 + 标题 + 文本）。
class _Piece {
  const _Piece(this.index, this.title, this.text);

  final int index;
  final String title;
  final String text;
}

/// 拼一段发送文本：每章前打【章节 N】标（N = 0-based，模型按它回填 chapters）。
String _chunkText(List<_Piece> pieces) {
  final StringBuffer buf = StringBuffer();
  for (final _Piece p in pieces) {
    buf.writeln(
      p.title.isEmpty ? '【章节 ${p.index}】' : '【章节 ${p.index} · ${p.title}】',
    );
    buf.writeln(p.text);
  }
  return buf.toString();
}
