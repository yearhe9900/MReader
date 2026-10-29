// `AI-07` ①②③ / `AI-08` ①③ / §8.3「进度范围 + 内容 hash」缓存：人物关系与
// 设定梳理驱动（`EntityJob`）。本机 HttpServer 模拟 OpenAI 兼容端点，覆盖：
// JSONL 流式逐行解析 + 整段兜底（数组 / 围栏 / pretty-print）、跨段去重合并
// 与坏条目丢弃、范围限定只取 from..upto（「仅已读」的下层语义）、成品缓存
// （二次进入零请求、正文变更失效、force 绕过、中断不写缓存）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/entities.dart';
import 'package:mreader/ai/provider_config.dart';
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
    await request.response.flush();
  }
}

AiProviderConfig _config(String baseUrl) => AiProviderConfig(
      id: 'c1',
      name: 't',
      baseUrl: baseUrl,
      model: 'm',
    );

const String _line =
    '{"name":"李昂","type":"人物","desc":"主角，药师弟子","chapters":[0]}';

void main() {
  late Directory dir;
  late SummaryCache cache;
  HttpServer? active;

  setUp(() async {
    HttpOverrides.global = null; // 恢复真实网络栈（flutter_test 默认 400）。
    dir = Directory.systemTemp.createTempSync('mreader_entities_');
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

  EntityJob job(String base) => EntityJob(
        client: AiClient(),
        config: _config(base),
        apiKey: 'k',
        cache: cache,
      );

  Future<String> defaultText(int i) async => '正文$i';

  List<BookSummaryEntry> entityEntries() =>
      cache.bookEntries.where((BookSummaryEntry e) => e.kind == 'entities')
          .toList();

  group('parseEntityOutput / EntityItem（输出契约兜底）', () {
    test('JSONL 多行按序解析；坏 type 与空 name 整条丢弃', () {
      final List<EntityItem> items = parseEntityOutput(
        '$_line\n'
        '{"name":"破军","type":"组织","desc":"坏类型","chapters":[1]}\n'
        '{"name":"","type":"人物","desc":"空名","chapters":[]}\n',
      );
      expect(items, hasLength(1));
      expect(items.single.name, '李昂');
      expect(items.single.type, '人物');
      expect(items.single.chapters, <int>[0]);
    });

    test('围栏数组与 pretty-print 多对象 → 整段兜底', () {
      final List<EntityItem> fenced = parseEntityOutput(
        '```json\n[$_line]\n```',
      );
      expect(fenced.single.name, '李昂');

      final List<EntityItem> pretty = parseEntityOutput(
        '{\n  "name": "青冥宗",\n  "type": "势力",\n'
        '  "desc": "所属宗门",\n  "chapters": [0]\n}\n'
        '{\n  "name": "丹会",\n  "type": "势力",\n'
        '  "desc": "季度比试",\n  "chapters": [2]\n}',
      );
      expect(pretty.map((EntityItem e) => e.name), <String>[
        '青冥宗',
        '丹会',
      ]);
    });

    test('垃圾文本 → 空表；encode/decode 往返', () {
      expect(parseEntityOutput('模型胡言乱语'), isEmpty);
      expect(parseEntityOutput(''), isEmpty);

      final List<EntityItem> items = mergeEntityItems(<EntityItem>[
        const EntityItem(
          name: '李昂',
          type: '人物',
          desc: '主角',
          chapters: <int>[0],
        ),
      ]);
      final List<EntityItem> back = decodeEntities(encodeEntities(items));
      expect(back.single.name, '李昂');
      expect(back.single.chapters, <int>[0]);
      expect(decodeEntities('坏 JSON'), isEmpty);
    });
  });

  group('mergeEntityItems（跨段去重：验收①②保真）', () {
    test('同名并集：章节排序、描述递接不重复、类型首见保留', () {
      final List<EntityItem> merged = mergeEntityItems(<EntityItem>[
        const EntityItem(
          name: '李昂',
          type: '人物',
          desc: '药师弟子',
          chapters: <int>[2, 0],
        ),
        const EntityItem(
          name: '李昂',
          type: '人物',
          desc: '药师弟子',
          chapters: <int>[1],
        ),
        const EntityItem(
          name: '李昂',
          type: '势力', // 类型冲突：首见保留
          desc: '新信息',
          chapters: <int>[5],
        ),
        const EntityItem(
          name: '青冥宗',
          type: '势力',
          desc: '宗门',
          chapters: <int>[0],
        ),
      ]);
      expect(merged, hasLength(2));
      final EntityItem li = merged.first;
      expect(li.type, '人物');
      expect(li.chapters, <int>[0, 1, 2, 5]);
      expect(li.desc, '药师弟子；新信息');
    });
  });

  group('EntityJob.run（`AI-07` / `AI-08`）', () {
    test('生成落缓存 → 二次零请求命中 → force 绕过 → 正文变更失效', () async {
      int calls = 0;
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          calls += 1;
          _sse(r, <String>['$_line\n']);
          await r.response.close();
        },
      );
      active = server;
      final EntityJob j = job(base);

      final EntityOutcome first = await j.run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: defaultText,
      );
      expect(first.items.single.name, '李昂');
      expect(first.fromCache, isFalse);
      expect(first.chunksTotal, 1);
      expect(calls, 1);
      expect(entityEntries(), hasLength(1)); // kind='entities' 成品已落盘

      // 二次进入：同范围同正文 → 命中缓存、零请求。
      final EntityOutcome again = await j.run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: defaultText,
      );
      expect(again.fromCache, isTrue);
      expect(again.items.single.name, '李昂');
      expect(calls, 1);

      // force 绕过缓存读（结果仍回写）。
      final EntityOutcome forced = await j.run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: defaultText,
        force: true,
      );
      expect(forced.fromCache, isFalse);
      expect(calls, 2);

      // 正文变更 → inputHash 变 → 失效（PRD §8.3）。
      final EntityOutcome changed = await j.run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: (int i) async => '改过的正文$i',
      );
      expect(changed.fromCache, isFalse);
      expect(calls, 3);
    });

    test('范围限定只取 from..upto（`AI-07` ③「仅已读」下层语义）', () async {
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          _sse(r, <String>['$_line\n']);
          await r.response.close();
        },
      );
      active = server;
      final List<int> loaded = <int>[];
      final EntityOutcome outcome = await job(base).run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1, // 三章只取前两章
        hrefs: <String>['h0', 'h1', 'h2'],
        titles: <String>['一', '二', '三'],
        loadText: (int i) async {
          loaded.add(i);
          return '正文$i';
        },
      );
      expect(loaded, <int>[0, 1]);
      expect(outcome.items, hasLength(1));
      expect(entityEntries().single.uptoChapter, 1);
    });

    test('超长章分段递进：进度逐段回调 + onItems 渐进快照', () async {
      int calls = 0;
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          calls += 1;
          _sse(r, <String>[
            '{"name":"实体$calls","type":"人物","desc":"d$calls",'
                '"chapters":[0]}\n',
          ]);
          await r.response.close();
        },
      );
      active = server;
      final List<(int, int)> progress = <(int, int)>[];
      final List<int> snapshots = <int>[];
      final EntityOutcome outcome = await job(base).run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 0,
        hrefs: <String>['h0'],
        titles: <String>['超长章'],
        loadText: (int i) async => '哔' * (kEntityChunkChars * 2 + 1000),
        onProgress: (int done, int total) => progress.add((done, total)),
        onItems: (List<EntityItem> items) => snapshots.add(items.length),
      );
      expect(calls, 3); // 6000 + 6000 + 1000 → 3 段
      expect(progress, <(int, int)>[(1, 3), (2, 3), (3, 3)]);
      expect(snapshots, <int>[1, 2, 3]); // 每抽到一条即回一帧合并快照
      expect(outcome.items.map((EntityItem e) => e.name), <String>[
        '实体1',
        '实体2',
        '实体3',
      ]);
      expect(outcome.chunksDone, 3);
    });

    test('模型不守 JSON Lines（整体数组）→ 整段兜底解析', () async {
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          _sse(r, <String>[
            '[{"name":"王五","type":"势力","desc":"商会会长","chapters":[1]}]',
          ]);
          await r.response.close();
        },
      );
      active = server;
      final EntityOutcome outcome = await job(base).run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: defaultText,
      );
      expect(outcome.items.single.name, '王五');
      expect(outcome.items.single.type, '势力');
    });

    test('中断：部分结果回传、不写缓存；重跑重新请求（`AI-08` ①）', () async {
      int calls = 0;
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          calls += 1;
          if (calls == 1) {
            await _sseHold(r, <String>['$_line\n']); // 挂住，等测试取消
          } else {
            _sse(r, <String>['$_line\n']);
            await r.response.close();
          }
        },
      );
      active = server;
      final EntityJob j = job(base);
      final Completer<void> gotItem = Completer<void>();

      final Future<EntityOutcome> pending = j.run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: defaultText,
        onItems: (List<EntityItem> items) {
          if (items.isNotEmpty && !gotItem.isCompleted) gotItem.complete();
        },
      );
      await gotItem.future; // 首条已流式解析出来
      j.cancel();
      final EntityOutcome cancelled = await pending;
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.items.single.name, '李昂'); // 部分结果回传展示
      expect(entityEntries(), isEmpty); // 半截不写缓存

      // 重跑（新作业）：重新请求拿完整结果并落缓存。
      final EntityOutcome resumed = await job(base).run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: defaultText,
      );
      expect(resumed.cancelled, isFalse);
      expect(resumed.items.single.name, '李昂');
      expect(calls, 2);
      expect(entityEntries(), hasLength(1));
    });

    test('范围内无正文 → 零请求空结果', () async {
      int calls = 0;
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          calls += 1;
          _sse(r, <String>['$_line\n']);
          await r.response.close();
        },
      );
      active = server;
      final EntityOutcome outcome = await job(base).run(
        bookId: 'b1',
        fromChapter: 0,
        uptoChapter: 1,
        hrefs: <String>['h0', 'h1'],
        titles: <String>['一', '二'],
        loadText: (int i) async => '',
      );
      expect(outcome.isEmpty, isTrue);
      expect(calls, 0);
      expect(entityEntries(), isEmpty);
    });
  });
}
