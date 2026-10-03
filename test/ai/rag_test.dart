// `M3-T04`：问答驱动与检索层单测（`AI-06` ①③ / F5 范围字数 / PRD §8.3
// 索引本地持久化 / M3.5 阈值 5 埋点存在性）。
//
// 验收映射：
//   · `AI-06` ③ 不发全书：[retrieveSnippets] 只回 Top-K 片段、单条
//     ≤ [kRagSnippetChars]、总字数 ≤ [kRagTotalChars]（ragMessages 的 user
//     消息由片段拼出，结构上不可能携带全书）；
//   · `AI-06` ① 引用口径：[SearchHit.offset] = 段落长度累加 + 段内命中位
//     （与 `CNT-06` 搜索同口径 → 阅读页 `_jumpToSearchHit` 可直接复用）；
//   · 零命中返空列表（面板据此不发请求、直答「书中未提及」）；
//   · [RagIndexStore] 内存缓存 / 磁盘命中零取文 / removeBook 连带清理，
//     以及构建 / 内存埋点落 [PerfLog.records]（阈值 5 基线数据源）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/rag.dart';
import 'package:mreader/diagnostics/perf_log.dart';
import 'package:mreader/format/book_source.dart';

import '../test_config.dart';

/// 章文本（两段 + 一章单段；与索引 / 检索断言对齐）。
const List<String> kTexts = <String>[
  '猫坐在垫子上。\n狗在院子里跑。',
  '天空很蓝。',
];

const List<String> kTitles = <String>['第一章', '第二章'];

Future<String> _loadText(int i) async => kTexts[i];

/// 手工构造一条片段（ragMessages 结构断言用，不经过检索）。
RagSnippet _snippet({
  int chapterIndex = 0,
  String chapterTitle = '第一章',
  int offset = 0,
  String text = '猫坐在垫子上。',
}) {
  return RagSnippet(
    hit: SearchHit(
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      offset: offset,
      context: text,
    ),
    text: text,
  );
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('ragMessages 消息组装', () {
    test('system 恒首条 + 问题与编号片段进 user', () {
      final List<AiMessage> messages = ragMessages(
        question: '猫在哪里',
        snippets: <RagSnippet>[
          _snippet(),
          _snippet(chapterIndex: 1, chapterTitle: '第二章', text: '天空很蓝。'),
        ],
      );
      expect(messages.length, 2);
      expect(messages.first.role, 'system');
      expect(messages.first.content, kRagSystemPrompt);
      expect(messages.last.role, 'user');
      expect(messages.last.content, contains('问题：猫在哪里'));
      expect(messages.last.content, contains('原文片段（共 2 个）：'));
      expect(messages.last.content, contains('[1]（第一章）'));
      expect(messages.last.content, contains('[2]（第二章）'));
      expect(messages.last.content, contains('猫坐在垫子上。'));
      expect(messages.last.content, contains('天空很蓝。'));
    });

    test('标题为空回落「第 N 节」', () {
      final List<AiMessage> messages = ragMessages(
        question: 'q',
        snippets: <RagSnippet>[_snippet(chapterTitle: '')],
      );
      expect(messages.last.content, contains('[1]（第 1 节）'));
    });

    test('system 提示词带「书中未提及」与引用标注约束（`AI-06` ②）', () {
      expect(kRagSystemPrompt, contains('书中未提及'));
      expect(kRagSystemPrompt, contains('禁止编造'));
      expect(kRagSystemPrompt, contains('[1]'));
    });
  });

  group('retrieveSnippets 检索', () {
    late RagIndex index;

    setUp(() {
      index = (RagIndexBuilder()
            ..addChapter(kTitles[0], kTexts[0])
            ..addChapter(kTitles[1], kTexts[1]))
          .finish();
    });

    test('命中段落 → 片段带章标题 / 同口径 offset / 整段 context', () async {
      final List<RagSnippet> snippets = await retrieveSnippets(
        question: '猫在哪里',
        index: index,
        loadText: _loadText,
      );
      expect(snippets.length, 1);
      expect(snippets.first.hit.chapterIndex, 0);
      expect(snippets.first.hit.chapterTitle, '第一章');
      expect(snippets.first.hit.offset, 0); // 首段起点 + 段内命中位 0
      expect(snippets.first.hit.context, '猫坐在垫子上。');
      expect(snippets.first.text, '猫坐在垫子上。');
    });

    test('第二段命中：offset = 前段长度累加 + 段内命中位（搜索同口径）',
        () async {
      final List<RagSnippet> snippets = await retrieveSnippets(
        question: '院子里',
        index: index,
        loadText: _loadText,
      );
      expect(snippets.length, 1);
      // 段 0 长 7；「院子」在段 1 内第 2 个字符处 → 7 + 2 = 9。
      expect(snippets.first.hit.offset, 9);
      expect(snippets.first.hit.context, '狗在院子里跑。');
    });

    test('书内不存在的问题 → 空列表（面板据此直答「书中未提及」）', () async {
      final List<RagSnippet> snippets = await retrieveSnippets(
        question: '青蛙为什么唱歌',
        index: index,
        loadText: _loadText,
      );
      expect(snippets, isEmpty);
    });

    test('取文失败的章跳过，不拖垮检索', () async {
      final List<RagSnippet> snippets = await retrieveSnippets(
        question: '猫在哪里',
        index: index,
        loadText: (int i) async => throw StateError('取文失败'),
      );
      expect(snippets, isEmpty);
    });

    test('超长段落：节选 ≤ kRagSnippetChars 且 offset 指向命中位', () async {
      final String long = '${'x' * 500}青蛙${'y' * 500}';
      final RagIndex longIndex = (RagIndexBuilder()
            ..addChapter('长章', long))
          .finish();
      final List<RagSnippet> snippets = await retrieveSnippets(
        question: '青蛙',
        index: longIndex,
        loadText: (int i) async => long,
      );
      expect(snippets.length, 1);
      expect(snippets.first.text.length, kRagSnippetChars);
      expect(snippets.first.hit.offset, 500);
    });

    test('topK 截断：候选章再多也只回 topK 条', () async {
      final RagIndexBuilder builder = RagIndexBuilder()
        ..addChapter('章0', '青蛙在池塘。');
      for (int i = 1; i <= 10; i++) {
        builder.addChapter('章$i', '青蛙在草地。');
      }
      final List<RagSnippet> snippets = await retrieveSnippets(
        question: '青蛙',
        index: builder.finish(),
        loadText: (int i) async => '青蛙在草地。',
        topK: 3,
      );
      expect(snippets.length, 3);
    });
  });

  group('RagIndexStore 索引存储', () {
    test('内存模式：同书二次 ensure 零重复取文 + 构建埋点在场', () async {
      final RagIndexStore store = RagIndexStore();
      int calls = 0;
      Future<String> loadText(int i) async {
        calls++;
        return kTexts[i];
      }

      final RagIndex a = await store.ensure(
        bookId: 'b1',
        titles: kTitles,
        loadText: loadText,
      );
      final RagIndex b = await store.ensure(
        bookId: 'b1',
        titles: kTitles,
        loadText: loadText,
      );
      expect(calls, 2); // 只有首建取文
      expect(identical(a, b), isTrue);
      expect(a.titles, kTitles);
      // 阈值 5 基线数据源：构建计时 + 内存估算打点必须在场（只观察不分支）。
      expect(
        PerfLog.records.any((String r) => r.contains('rag.index.build')),
        isTrue,
      );
      expect(
        PerfLog.records.any((String r) => r.contains('rag.index.mem')),
        isTrue,
      );
    });

    test('磁盘命中：重开零取文；removeBook 连带清内存与文件', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('mreader_rag_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final String file =
          '${dir.path}${Platform.pathSeparator}rag_b9.json';

      // 首建：取文 + 落盘。
      final RagIndexStore s1 = RagIndexStore(dir);
      int calls = 0;
      await s1.ensure(
        bookId: 'b9',
        titles: kTitles,
        loadText: (int i) async {
          calls++;
          return kTexts[i];
        },
      );
      expect(calls, 2);
      expect(File(file).existsSync(), isTrue);

      // 重开：磁盘命中，零取文，检索能力不变。
      final RagIndexStore s2 = RagIndexStore(dir);
      bool touched = false;
      final RagIndex loaded = await s2.ensure(
        bookId: 'b9',
        titles: kTitles,
        loadText: (int i) async {
          touched = true;
          return '';
        },
      );
      expect(touched, isFalse);
      expect(loaded.titles, kTitles);
      expect(loaded.topChapters('猫', 5), isNotEmpty);

      // 删书连带：内存清 + 磁盘文件（含备份 / 隔离）删除。
      await s2.removeBook('b9');
      expect(File(file).existsSync(), isFalse);
      bool touchedAfter = false;
      await s2.ensure(
        bookId: 'b9',
        titles: kTitles,
        loadText: (int i) async {
          touchedAfter = true;
          return kTexts[i];
        },
      );
      expect(touchedAfter, isTrue); // 已清除 → 重新构建
    });

    test('并发 ensure 去重：同书只构建一次', () async {
      final RagIndexStore store = RagIndexStore();
      int calls = 0;
      Future<String> loadText(int i) async {
        calls++;
        return kTexts[i];
      }

      final List<RagIndex> results = await Future.wait(<Future<RagIndex>>[
        store.ensure(bookId: 'b2', titles: kTitles, loadText: loadText),
        store.ensure(bookId: 'b2', titles: kTitles, loadText: loadText),
      ]);
      expect(calls, 2);
      expect(identical(results[0], results[1]), isTrue);
    });
  });
}
