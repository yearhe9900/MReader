// `TTS-07` 在线 TTS 引擎行为（M3-T09）：本地 HttpServer 打桩，不依赖外网。
//
// 验收映射（PRD `TTS-07`）：
//   ① 配置后能播放：模板模式取到音频 → 假播放器播放 → 回 `done`；
//   ② 同一段文本二次朗读命中音频缓存：服务器命中数仍为 1；
//   ③ 失败重试有限次：5xx 最多 3 次仍失败 → `error`；4xx 不重试立即 `error`；
//   附加：stop 中途打断 → `cancelled` 不播放；换段作废旧 speak；
//   OpenAI 兼容模式的 POST 路径 / Authorization / 请求体；GBK 编码；
//   自定义请求头透传；`{text}` 百分号编码与缓存键指纹。
//
// 口径：契约期望值**硬编码字面量**；播放器 / 配置存储全部注入，不碰
// audioplayers 平台通道；真网络 IO 走 loopback（本文件为纯 `test()`）。
//
// **不初始化 `TestWidgetsFlutterBinding`**：该 binding 会装 HttpOverrides，
// 把所有 HttpClient 请求改成 400 假响应（flutter_test 内建行为），loopback
// 打桩会全军覆没；本文件不碰 widget / 平台通道，故一律裸跑。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/tts/online_tts.dart';
import 'package:mreader/tts/tts_engine.dart';

/// 假播放器：记录播放文件路径，立刻回「播完」（驱动 speak 收 `done`）。
class _FakePlayer implements TtsAudioPlayer {
  final List<String> played = <String>[];
  int stopCalls = 0;
  bool disposed = false;

  @override
  Future<void> play(File file, {required void Function() onDone}) async {
    played.add(file.path);
    onDone();
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Directory dir;
  late OnlineTtsStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mreader_online_tts_');
    store = OnlineTtsStore(dir);
    await store.load();
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 起一个 loopback TTS 服务；[handler] 收每个请求（自己负责回响应）。
  Future<HttpServer> serve(void Function(HttpRequest request) handler) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen(handler);
    return server;
  }

  group('TTS-07 ① 播放与缓存', () {
    test('模板模式取到音频 → 播放 → done（hits=1，缓存 1 条）', () async {
      int hits = 0;
      final HttpServer server = await serve((HttpRequest request) {
        hits++;
        request.response.statusCode = 200;
        request.response.add(utf8.encode('FAKE-AUDIO'));
        unawaited(request.response.close());
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
      ));
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      expect(await engine.init(), isTrue);
      expect(await engine.speak('你好世界'), TtsSpeakResult.done);
      expect(hits, 1);
      expect(player.played, hasLength(1));
      expect(File(player.played.single).existsSync(), isTrue);
      expect(await store.cache.count(), 1);
    });

    test('TTS-07 ② 同一段文本二次朗读命中缓存（服务器仍只 hit 1 次）', () async {
      int hits = 0;
      final HttpServer server = await serve((HttpRequest request) {
        hits++;
        request.response.statusCode = 200;
        request.response.add(utf8.encode('FAKE-AUDIO'));
        unawaited(request.response.close());
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
      ));
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      expect(await engine.speak('同一段'), TtsSpeakResult.done);
      expect(await engine.speak('同一段'), TtsSpeakResult.done);
      expect(hits, 1);
      expect(player.played, hasLength(2)); // 两次都播（本地缓存文件）
      expect(await store.cache.count(), 1);

      // 换文本 = 新指纹 → 再发一次请求。
      expect(await engine.speak('另一段'), TtsSpeakResult.done);
      expect(hits, 2);
    });

    test('缓存键随请求头变化（头不同 = 不同音频）', () async {
      final String a = OnlineTts.buildCacheKey(
        const OnlineTtsConfig(
          headers: <String, String>{'X-Token': 'a'},
        ),
        rate: TtsDefaults.normalRate,
        text: 't',
      );
      final String b = OnlineTts.buildCacheKey(
        const OnlineTtsConfig(
          headers: <String, String>{'X-Token': 'b'},
        ),
        rate: TtsDefaults.normalRate,
        text: 't',
      );
      final String c = OnlineTts.buildCacheKey(
        const OnlineTtsConfig(
          headers: <String, String>{'X-Token': 'a'},
        ),
        rate: TtsDefaults.normalRate,
        text: 't',
      );
      expect(a == b, isFalse);
      expect(a, c); // 同配置同文本恒等
    });
  });

  group('TTS-07 ③ 有限重试', () {
    test('5xx 可重试：3 次用尽 → error、未播放、不落缓存', () async {
      int hits = 0;
      final HttpServer server = await serve((HttpRequest request) {
        hits++;
        request.response.statusCode = 500;
        unawaited(request.response.close());
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
      ));
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      expect(await engine.speak('重试'), TtsSpeakResult.error);
      expect(hits, 3);
      expect(player.played, isEmpty);
      expect(await store.cache.count(), 0);
    });

    test('404 不可重试：1 次即 error', () async {
      int hits = 0;
      final HttpServer server = await serve((HttpRequest request) {
        hits++;
        request.response.statusCode = 404;
        unawaited(request.response.close());
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
      ));
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      expect(await engine.speak('缺失'), TtsSpeakResult.error);
      expect(hits, 1);
    });

    test('配置无效：init 回 false，speak 直接 error 且不发请求', () async {
      int hits = 0;
      final HttpServer server = await serve((HttpRequest request) {
        hits++;
        unawaited(request.response.close());
      });
      // 未配置（模板为空）。
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      expect(await engine.init(), isFalse);
      expect(await engine.speak('无配置'), TtsSpeakResult.error);
      expect(hits, 0);
      expect(player.played, isEmpty);
      expect(server.port, greaterThan(0));
    });
  });

  group('打断与作废', () {
    test('stop 中途打断在途请求 → cancelled 且不播放', () async {
      final HttpServer server = await serve((HttpRequest request) {
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 400), () {
            request.response.statusCode = 200;
            request.response.add(utf8.encode('SLOW-AUDIO'));
            unawaited(request.response.close());
          }),
        );
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
      ));
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      final Future<TtsSpeakResult> pending = engine.speak('慢段');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop();
      expect(await pending, TtsSpeakResult.cancelled);
      expect(player.played, isEmpty);
      expect(player.stopCalls, 1);
    });

    test('换段：第二次 speak 让第一段 cancelled，第二段照常 done', () async {
      final HttpServer server = await serve((HttpRequest request) {
        final bool slow = request.uri.queryParameters['q'] == '慢段';
        unawaited(
          Future<void>.delayed(
            Duration(milliseconds: slow ? 400 : 0),
            () {
              request.response.statusCode = 200;
              request.response.add(utf8.encode('AUDIO'));
              unawaited(request.response.close());
            },
          ),
        );
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
      ));
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      final Future<TtsSpeakResult> first = engine.speak('慢段');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final Future<TtsSpeakResult> second = engine.speak('快段');
      expect(await second, TtsSpeakResult.done);
      expect(await first, TtsSpeakResult.cancelled);
      expect(player.played, hasLength(1));
      expect(player.played.single, contains('tts_audio'));
    });
  });

  group('OpenAI 兼容模式（PRD §8.2 TTS 复用）', () {
    test('POST {base}/audio/speech + Bearer + 请求体字段', () async {
      String? seenMethod;
      String? seenPath;
      String? seenAuth;
      String? seenBody;
      final HttpServer server = await serve((HttpRequest request) async {
        seenMethod = request.method;
        seenPath = request.uri.path;
        seenAuth = request.headers.value('authorization');
        seenBody = await utf8.decodeStream(request);
        request.response.statusCode = 200;
        request.response.add(utf8.encode('OPENAI-AUDIO'));
        await request.response.close();
      });
      await store.setConfig(OnlineTtsConfig(
        mode: OnlineTtsMode.openaiSpeech,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'tts-1',
        voice: 'alloy',
      ));
      await store.writeApiKey('sk-test-key');
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      addTearDown(engine.dispose);

      expect(await engine.init(), isTrue);
      await engine.setRate(1.0); // 0.5 → speed 1.0；1.0 → speed 2.0
      expect(await engine.speak('你好'), TtsSpeakResult.done);

      expect(seenMethod, 'POST');
      expect(seenPath, '/v1/audio/speech');
      expect(seenAuth, 'Bearer sk-test-key');
      final Map<String, Object?> body =
          jsonDecode(seenBody!) as Map<String, Object?>;
      expect(body['model'], 'tts-1');
      expect(body['voice'], 'alloy');
      expect(body['input'], '你好');
      expect(body['response_format'], 'mp3');
      expect(body['speed'], 2.0);
      expect(player.played, hasLength(1));
    });

    test('baseUrl 尾斜杠归一（不产生 //audio/speech）', () async {
      late Uri seenUri;
      final HttpServer server = await serve((HttpRequest request) {
        seenUri = request.uri;
        request.response.statusCode = 200;
        request.response.add(utf8.encode('AUDIO'));
        unawaited(request.response.close());
      });
      await store.setConfig(OnlineTtsConfig(
        mode: OnlineTtsMode.openaiSpeech,
        baseUrl: 'http://127.0.0.1:${server.port}/v1/',
      ));
      final OnlineTts engine =
          OnlineTts(store, player: _FakePlayer());
      addTearDown(engine.dispose);

      expect(await engine.speak('x'), TtsSpeakResult.done);
      expect(seenUri.path, '/v1/audio/speech');
    });
  });

  group('编码与请求头', () {
    test('percentEncodeText：UTF-8 / GBK / unreserved 直通 / 回退', () {
      expect(percentEncodeText('中', OnlineTtsEncoding.utf8), '%E4%B8%AD');
      expect(percentEncodeText('中', OnlineTtsEncoding.gbk), '%D6%D0');
      expect(percentEncodeText('A-z_0.~', OnlineTtsEncoding.utf8), 'A-z_0.~');
      // emoji 不在 GBK 字符集：不抛异常（charset 编码器给替换单字节），
      // 输出仍是合法百分号编码形态——绝不让一个字符炸掉整段朗读。
      final String emojiGbk = percentEncodeText('😀', OnlineTtsEncoding.gbk);
      expect(RegExp(r'^(?:%[0-9A-F]{2})+$').hasMatch(emojiGbk), isTrue);
      expect(emojiGbk, isNot(isEmpty));
    });

    test('GBK 编码透出请求 query（服务器端可见 %D6%D0）', () async {
      late String rawQuery;
      final HttpServer server = await serve((HttpRequest request) {
        rawQuery = request.uri.query;
        request.response.statusCode = 200;
        request.response.add(utf8.encode('AUDIO'));
        unawaited(request.response.close());
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
        textEncoding: OnlineTtsEncoding.gbk,
      ));
      final OnlineTts engine =
          OnlineTts(store, player: _FakePlayer());
      addTearDown(engine.dispose);

      expect(await engine.speak('中'), TtsSpeakResult.done);
      expect(rawQuery, 'q=%D6%D0');
    });

    test('自定义请求头透传（模板模式）', () async {
      String? seenToken;
      String? seenContentType;
      final HttpServer server = await serve((HttpRequest request) {
        seenToken = request.headers.value('x-token');
        seenContentType = request.headers.value('content-type');
        request.response.statusCode = 200;
        request.response.add(utf8.encode('AUDIO'));
        unawaited(request.response.close());
      });
      await store.setConfig(OnlineTtsConfig(
        urlTemplate: 'http://127.0.0.1:${server.port}/tts?q={text}',
        headers: const <String, String>{'X-Token': 'abc123'},
      ));
      final OnlineTts engine =
          OnlineTts(store, player: _FakePlayer());
      addTearDown(engine.dispose);

      expect(await engine.speak('头'), TtsSpeakResult.done);
      expect(seenToken, 'abc123');
      expect(seenContentType, isNull); // 模板模式 GET 无请求体
    });

    test('parseHeaderLines / formatHeaderLines 往返与坏行中文报错', () {
      final ({Map<String, String> headers, String? error}) ok =
          parseHeaderLines('X-A: 1\n\nAuthorization: Bearer x\n');
      expect(ok.error, isNull);
      expect(ok.headers, <String, String>{
        'X-A': '1',
        'Authorization': 'Bearer x',
      });
      expect(formatHeaderLines(ok.headers), 'X-A: 1\nAuthorization: Bearer x');

      expect(parseHeaderLines('').error, isNull);
      expect(
        parseHeaderLines('坏行没有冒号').error,
        '请求头每行需为「名称: 值」格式',
      );
      expect(parseHeaderLines(': 少名称').error, '请求头每行需为「名称: 值」格式');
    });
  });

  group('引擎契约杂项', () {
    test('getVoices 空列表（面板隐藏音色区，诚实降级）', () async {
      final OnlineTts engine =
          OnlineTts(store, player: _FakePlayer());
      addTearDown(engine.dispose);
      expect(await engine.getVoices(), isEmpty);
      await engine.setVoice(const TtsVoice(name: 'x', locale: 'zh-CN'));
    });

    test('speedForRate：0.5→1.0、1.0→2.0、越界夹紧、NaN 回 1.0', () {
      expect(OnlineTtsConfig.speedForRate(0.5), 1.0);
      expect(OnlineTtsConfig.speedForRate(1.0), 2.0);
      expect(OnlineTtsConfig.speedForRate(0.0), 0.25);
      expect(OnlineTtsConfig.speedForRate(3.0), 4.0);
      expect(OnlineTtsConfig.speedForRate(double.nan), 1.0);
    });

    test('dispose 释放播放器（换引擎 / 关页路径）', () async {
      final _FakePlayer player = _FakePlayer();
      final OnlineTts engine = OnlineTts(store, player: player);
      await engine.dispose();
      expect(player.disposed, isTrue);
    });
  });
}
