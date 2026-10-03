// `M3-T03`：递进摘要驱动（`AI-04` ②③ / `AI-05` ①②③ / PRD §8.3 分块递进）。
//
// 本机 `HttpServer` 模拟 OpenAI 兼容端点（章请求 / 合并请求按 system 提示词
// 分流计数），钉四条链路：
//   · `AI-04` ② 章级缓存命中零请求、③ force 绕过缓存、长度档进键；
//   · `AI-05` ① 逐章递进 + 合并、② recap 只取近 5 章且带「上次读到」背景；
//   · `AI-05` ③ 可中断可续做：合并挂起时取消 → 章级已落缓存 → 重跑只补合并；
//   · PRD §8.3 超长章分块递进（分块各自梗概 → 合并成章梗概）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/recap.dart';
import 'package:mreader/ai/summarize.dart';
import 'package:mreader/ai/summary_cache.dart';

Future<(String, HttpServer)> _serve(
  Future<void> Function(HttpRequest request) handler,
) async {
  final HttpServer server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) async {
    try {
      await handler(request);
    } catch (_) {
      // 测试主动中止导致的写失败：忽略。
    }
  });
  return ('http://127.0.0.1:${server.port}/v1', server);
}

void _sse(HttpRequest request, List<String> chunks) {
  request.response.headers.contentType =
      ContentType('text', 'event-stream', charset: 'utf-8');
  for (final String c in chunks) {
    request.response.write(
      'data: ${jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'content': c}},
            ],
          })}\n\n',
    );
  }
  request.response.write('data: [DONE]\n\n');
}

/// 只发帧、不写 `[DONE]`、不关连接（`bufferOutput=false` 让帧立即落盘）。
Future<void> _sseHold(HttpRequest request, List<String> chunks) async {
  request.response.bufferOutput = false;
  request.response.headers.contentType =
      ContentType('text', 'event-stream', charset: 'utf-8');
  for (final String c in chunks) {
    request.response.write(
      'data: ${jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'content': c}},
            ],
          })}\n\n',
    );
  }
  await request.response.flush();
}

/// 读请求体（流只能消费一次——分支判断与断言共用这一份）。
Future<Map<String, Object?>> _body(HttpRequest r) async =>
    jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, Object?>;

/// 该请求体是不是「合并」请求（system = 合并提示词）。
bool _isMergeBody(Map<String, Object?> body) {
  final List<Object?> messages = body['messages']! as List<Object?>;
  final Map<String, Object?> first = messages.first! as Map<String, Object?>;
  return first['content'] == kMergeSummarySystemPrompt;
}

AiProviderConfig _config(String baseUrl) => AiProviderConfig(
      id: 'c1',
      name: 't',
      baseUrl: baseUrl,
      model: 'm',
    );

void main() {
  late Directory dir;
  late SummaryCache cache;
  HttpServer? active;

  setUp(() async {
    HttpOverrides.global = null; // 恢复真实网络栈（flutter_test 默认 400）。
    dir = Directory.systemTemp.createTempSync('mreader_recap_');
    cache = SummaryCache(dir);
    await cache.load();
    active = null;
  });

  tearDown(() async {
    final HttpServer? server = active;
    active = null;
    if (server != null) {
      await server.close(force: true);
    }
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  SummaryJob job(String base) => SummaryJob(
        client: AiClient(),
        config: _config(base),
        apiKey: 'k',
        cache: cache,
      );

  group('splitSummaryChunks（PRD §8.3 分块边界）', () {
    test('不超阈值 → 单块原样返回', () {
      expect(splitSummaryChunks('短文本'), <String>['短文本']);
      expect(splitSummaryChunks(''), <String>['']);
    });

    test('多段落长文：按段落切、每块 ≤ 阈值、可无损重组', () {
      final String line = '啊' * 3000;
      final String text = <String>[line, line, line].join('\n');
      final List<String> chunks = splitSummaryChunks(text);
      expect(chunks.length, 3);
      for (final String c in chunks) {
        expect(c.length, lessThanOrEqualTo(kSummaryChunkChars));
      }
      expect(chunks.join('\n'), text);
    });

    test('单行超限：硬切成整块，首块恰为阈值长、拼回无损', () {
      final String line = '哔' * 20000;
      final List<String> chunks = splitSummaryChunks(line);
      expect(chunks.length, 4);
      expect(chunks.first.length, kSummaryChunkChars);
      for (final String c in chunks) {
        expect(c.length, lessThanOrEqualTo(kSummaryChunkChars));
      }
      expect(chunks.join(''), line);
    });
  });

  group('shouldShowRecapEntrance（`AI-05` ② 停读阈值）', () {
    const int day = Duration.millisecondsPerDay;

    test('无进度 / 时间戳非法 → 不出入口', () {
      expect(shouldShowRecapEntrance(lastReadAtMs: null, nowMs: 100 * day),
          isFalse);
      expect(shouldShowRecapEntrance(lastReadAtMs: 0, nowMs: 100 * day),
          isFalse);
      expect(
          shouldShowRecapEntrance(lastReadAtMs: 100 * day, nowMs: 90 * day),
          isFalse); // 未来时间戳
    });

    test('停读 6 天不出、满 7 天出（`kRecapIdleDays` 边界）', () {
      final int now = 100 * day;
      expect(
          shouldShowRecapEntrance(lastReadAtMs: now - 6 * day, nowMs: now),
          isFalse);
      expect(
          shouldShowRecapEntrance(lastReadAtMs: now - 7 * day, nowMs: now),
          isTrue);
      expect(
          shouldShowRecapEntrance(lastReadAtMs: now - 30 * day, nowMs: now),
          isTrue);
    });
  });

  group('SummaryJob.chapter（`AI-04` ①②③）', () {
    test('生成 → 落缓存 → 二次进入零请求命中；force 绕过、长度档进键', () async {
      int calls = 0;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        calls += 1;
        _sse(r, <String>['章', '摘要']);
        await r.response.close();
      });
      active = server;
      final SummaryJob j = job(base);

      final SummaryOutcome first = await j.chapter(
        bookId: 'b1',
        href: 'h1',
        title: '第一章',
        text: '正文内容',
      );
      expect(first.text, '章摘要');
      expect(first.fromCache, isFalse);
      expect(calls, 1);

      // `AI-04` ②：同输入再进 → 命中缓存、零请求。
      final SummaryOutcome second = await j.chapter(
        bookId: 'b1',
        href: 'h1',
        title: '第一章',
        text: '正文内容',
      );
      expect(second.fromCache, isTrue);
      expect(second.text, '章摘要');
      expect(calls, 1);

      // `AI-04` ③：force 绕过缓存读 → 重新请求（结果仍回写）。
      final SummaryOutcome forced = await j.chapter(
        bookId: 'b1',
        href: 'h1',
        title: '第一章',
        text: '正文内容',
        force: true,
      );
      expect(forced.fromCache, isFalse);
      expect(calls, 2);

      // 长度档不同 = 不同成品 → miss（键含 maxChars）。
      await j.chapter(
        bookId: 'b1',
        href: 'h1',
        title: '第一章',
        text: '正文内容',
        maxChars: 500,
      );
      expect(calls, 3);
    });

    test('onDelta 逐字回调', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        _sse(r, <String>['甲', '乙']);
        await r.response.close();
      });
      active = server;
      final StringBuffer deltas = StringBuffer();
      final SummaryOutcome outcome = await job(base).chapter(
        bookId: 'b1',
        href: 'h1',
        title: 't',
        text: 'body',
        onDelta: deltas.write,
      );
      expect(outcome.text, '甲乙');
      expect(deltas.toString(), '甲乙');
    });

    test('超长章分块递进：分块各自梗概 → 合并成章梗概（PRD §8.3）', () async {
      int calls = 0;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        calls += 1;
        if (_isMergeBody(await _body(r))) {
          _sse(r, <String>['合并章摘要']);
        } else {
          _sse(r, <String>['块$calls']);
        }
        await r.response.close();
      });
      active = server;
      final SummaryOutcome outcome = await job(base).chapter(
        bookId: 'b1',
        href: 'h1',
        title: '超长章',
        text: '哔' * 13000, // → 6000 + 6000 + 1000 三块
      );
      expect(outcome.text, '合并章摘要');
      expect(calls, 4); // 3 块 + 1 合并
    });
  });

  group('SummaryJob.book（`AI-05` ①③）', () {
    List<String> hrefs() => <String>['h1', 'h2', 'h3'];
    List<String> titles() => <String>['一', '二', '三'];

    test('逐章递进 + 合并；进度回调；二次全命中零请求', () async {
      int chapterCalls = 0;
      int mergeCalls = 0;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        if (_isMergeBody(await _body(r))) {
          mergeCalls += 1;
          _sse(r, <String>['全书摘要']);
        } else {
          chapterCalls += 1;
          _sse(r, <String>['章$chapterCalls 梗概']);
        }
        await r.response.close();
      });
      active = server;
      final SummaryJob j = job(base);
      final List<(int, int)> progress = <(int, int)>[];

      final SummaryOutcome outcome = await j.book(
        bookId: 'b1',
        uptoChapter: 2,
        hrefs: hrefs(),
        titles: titles(),
        loadText: (int i) async => '第${i + 1}章正文',
        onProgress: (int done, int total) => progress.add((done, total)),
      );
      expect(outcome.text, '全书摘要');
      expect(outcome.chaptersDone, 3);
      expect(outcome.chaptersTotal, 3);
      expect(outcome.fromCache, isFalse);
      expect(chapterCalls, 3);
      expect(mergeCalls, 1);
      expect(progress, <(int, int)>[(1, 3), (2, 3), (3, 3)]);

      // 二次进入：章级 + 合并级全命中 → 零请求。
      final SummaryOutcome again = await j.book(
        bookId: 'b1',
        uptoChapter: 2,
        hrefs: hrefs(),
        titles: titles(),
        loadText: (int i) async => '第${i + 1}章正文',
      );
      expect(again.fromCache, isTrue);
      expect(again.text, '全书摘要');
      expect(chapterCalls, 3);
      expect(mergeCalls, 1);
    });

    test('`AI-05` ③ 中断可续做：合并挂起时取消 → 章级已缓存，重跑只补合并',
        () async {
      int chapterCalls = 0;
      int mergeCalls = 0;
      final Completer<void> mergeArrived = Completer<void>();
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        if (_isMergeBody(await _body(r))) {
          mergeCalls += 1;
          if (mergeCalls == 1) {
            if (!mergeArrived.isCompleted) mergeArrived.complete();
            await _sseHold(r, <String>['半截']); // 挂住，等测试取消
          } else {
            _sse(r, <String>['全书摘要']);
            await r.response.close();
          }
        } else {
          chapterCalls += 1;
          _sse(r, <String>['章$chapterCalls 梗概']);
          await r.response.close();
        }
      });
      active = server;
      final SummaryJob j1 = job(base);

      final Future<SummaryOutcome> pending = j1.book(
        bookId: 'b1',
        uptoChapter: 2,
        hrefs: hrefs(),
        titles: titles(),
        loadText: (int i) async => '第${i + 1}章正文',
      );
      await mergeArrived.future; // 三章全部完成、合并请求挂起
      j1.cancel();
      final SummaryOutcome cancelled = await pending;
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.chaptersDone, 3); // 章级成果保留在缓存里
      expect(cancelled.text, ''); // 合并未完成 → 无半截成品
      expect(chapterCalls, 3);

      // 续做：新作业，三章全部命中 → 只补一次合并请求。
      final SummaryOutcome resumed = await job(base).book(
        bookId: 'b1',
        uptoChapter: 2,
        hrefs: hrefs(),
        titles: titles(),
        loadText: (int i) async => '第${i + 1}章正文',
      );
      expect(resumed.cancelled, isFalse);
      expect(resumed.text, '全书摘要');
      expect(chapterCalls, 3); // 零新增章请求
      expect(mergeCalls, 2); // 只重发合并
    });
  });

  group('SummaryJob.recap（`AI-05` ② 窗口与背景）', () {
    test('只取近 5 章，合并带「上次读到第 N 章」；上限 400 字', () async {
      String? mergeUser;
      int mergeCalls = 0;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        final Map<String, Object?> body = await _body(r);
        if (_isMergeBody(body)) {
          mergeCalls += 1;
          final Map<String, Object?> user =
              (body['messages']! as List<Object?>)[1]! as Map<String, Object?>;
          mergeUser = user['content'] as String;
          _sse(r, <String>['前情回顾']);
        } else {
          _sse(r, <String>['章梗概']);
        }
        await r.response.close();
      });
      active = server;

      final List<int> loaded = <int>[];
      final SummaryOutcome outcome = await job(base).recap(
        bookId: 'b1',
        uptoChapter: 9, // 第 10 章 → 窗口 5..9（近 5 章）
        hrefs: <String>[for (int i = 0; i < 10; i++) 'h$i'],
        titles: <String>[for (int i = 0; i < 10; i++) '第${i + 1}章'],
        loadText: (int i) async {
          loaded.add(i);
          return '第${i + 1}章正文';
        },
      );
      expect(outcome.text, '前情回顾');
      expect(loaded, <int>[5, 6, 7, 8, 9]);
      expect(outcome.chaptersTotal, 5);
      expect(mergeCalls, 1);
      expect(mergeUser, contains('上次读到第 10 章'));
      expect(mergeUser, contains('不超过 $kRecapMaxChars 字'));
    });

    test('首章起读（upto < 近 N 章）：窗口夹到 0，不越界', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        _sse(r, <String>['回顾']);
        await r.response.close();
      });
      active = server;
      final List<int> loaded = <int>[];
      final SummaryOutcome outcome = await job(base).recap(
        bookId: 'b1',
        uptoChapter: 1, // 只有 2 章 → 窗口 0..1
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: (int i) async {
          loaded.add(i);
          return '正文$i';
        },
      );
      expect(loaded, <int>[0, 1]);
      expect(outcome.chaptersTotal, 2);
      expect(outcome.text, '回顾');
    });
  });
}
