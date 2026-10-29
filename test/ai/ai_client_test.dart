// `AI-08`、`AI-01` ②：AiClient 流式 / 取消 / 错误分类 / 并发上限测试。
//
// 用本机 `HttpServer` 模拟 OpenAI 兼容端点：SSE 逐帧、各类状态码、挂起不回、
// 并发峰值观测。均为纯 `test()`（无 FakeAsync 区），真实 socket 异步可正常排空。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';

/// 起一个一次性本地服务；返回 baseUrl（`http://127.0.0.1:port/v1`）。
Future<(String, HttpServer)> _serve(
  Future<void> Function(HttpRequest request) handler,
) async {
  final HttpServer server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) async {
    try {
      await handler(request);
    } catch (_) {
      // 测试内主动中止（cancel）导致的写失败：忽略。
    }
  });
  final String baseUrl =
      'http://127.0.0.1:${server.port}/v1';
  return (baseUrl, server);
}

AiProviderConfig _config(String baseUrl, {int timeoutSeconds = 5}) {
  return AiProviderConfig(
    id: 'c1',
    name: 't',
    baseUrl: baseUrl,
    model: 'm',
    timeoutSeconds: timeoutSeconds,
  );
}

/// 写一段标准 SSE（OpenAI chat 流）。
void _sse(HttpRequest request, List<String> chunks, {bool done = true}) {
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
  if (done) {
    request.response.write('data: [DONE]\n\n');
  }
}

void main() {
  final AiClient client = AiClient();
  HttpServer? active;

  tearDown(() async {
    final HttpServer? s = active;
    active = null;
    if (s != null) {
      await s.close(force: true);
    }
  });

  Future<List<String>> collect(AiCall call) => call.stream.toList();

  test('SSE 流式：逐 delta 收到 chunks，[DONE] 结束', () async {
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      _sse(r, <String>['你', '好', '！']);
      await r.response.close();
    });
    active = server;
    final List<String> chunks = await collect(
      client.chatStream(
        config: _config(base),
        apiKey: 'sk-test',
        messages: const <AiMessage>[AiMessage('user', 'hi')],
      ),
    );
    expect(chunks, <String>['你', '好', '！']);
  });

  test('请求体：Bearer 头 + model + stream:true + 消息', () async {
    late Map<String, Object?> body;
    late String? auth;
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      auth = r.headers.value(HttpHeaders.authorizationHeader);
      body = jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, Object?>;
      _sse(r, <String>['ok']);
      await r.response.close();
    });
    active = server;
    final List<String> chunks = await collect(
      client.chatStream(
        config: _config(base),
        apiKey: 'sk-abc',
        messages: const <AiMessage>[AiMessage('user', '你好')],
      ),
    );
    expect(chunks, <String>['ok']);
    expect(auth, 'Bearer sk-abc');
    expect(body['model'], 'm');
    expect(body['stream'], isTrue);
    expect(body['messages'], <Object?>[
      <String, Object?>{'role': 'user', 'content': '你好'},
    ]);
  });

  test('401 → unauthorized（不可重试，`AI-08`）', () async {
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      r.response.statusCode = HttpStatus.unauthorized;
      r.response.write(jsonEncode(<String, Object?>{
        'error': <String, Object?>{'message': 'Invalid API key'},
      }));
      await r.response.close();
    });
    active = server;
    await expectLater(
      collect(
        client.chatStream(
          config: _config(base),
          apiKey: 'bad',
          messages: const <AiMessage>[AiMessage('user', 'x')],
        ),
      ),
      throwsA(
        isA<AiException>()
            .having((AiException e) => e.kind, 'kind', AiErrorKind.unauthorized)
            .having((AiException e) => e.statusCode, 'status', 401)
            .having((AiException e) => e.retryable, 'retryable', isFalse)
            .having((AiException e) => e.message, 'message', contains('Invalid API key')),
      ),
    );
  });

  test('404 → notFound（提示查 Base URL，不可重试）', () async {
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      r.response.statusCode = HttpStatus.notFound;
      await r.response.close();
    });
    active = server;
    await expectLater(
      collect(
        client.chatStream(
          config: _config(base),
          apiKey: 'k',
          messages: const <AiMessage>[AiMessage('user', 'x')],
        ),
      ),
      throwsA(
        isA<AiException>()
            .having((AiException e) => e.kind, 'kind', AiErrorKind.notFound)
            .having((AiException e) => e.retryable, 'retryable', isFalse)
            .having((AiException e) => e.message, 'message', contains('Base URL')),
      ),
    );
  });

  test('500 → server（可重试）', () async {
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      r.response.statusCode = HttpStatus.internalServerError;
      r.response.write('boom');
      await r.response.close();
    });
    active = server;
    await expectLater(
      collect(
        client.chatStream(
          config: _config(base),
          apiKey: 'k',
          messages: const <AiMessage>[AiMessage('user', 'x')],
        ),
      ),
      throwsA(
        isA<AiException>()
            .having((AiException e) => e.kind, 'kind', AiErrorKind.server)
            .having((AiException e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('连接被拒 → network（可重试）', () async {
    // 拿一个刚释放的端口 → 必然 connection refused。
    final HttpServer probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final int deadPort = probe.port;
    await probe.close();
    await expectLater(
      collect(
        client.chatStream(
          config: _config('http://127.0.0.1:$deadPort/v1'),
          apiKey: 'k',
          messages: const <AiMessage>[AiMessage('user', 'x')],
        ),
      ),
      throwsA(
        isA<AiException>()
            .having((AiException e) => e.kind, 'kind', AiErrorKind.network)
            .having((AiException e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('服务端挂起不回 → timeout（可重试）', () async {
    final (String base, HttpServer server) =
        await _serve((HttpRequest r) async {
      await Completer<void>().future; // 永不响应。
    });
    active = server;
    await expectLater(
      collect(
        client.chatStream(
          config: _config(base, timeoutSeconds: 1),
          apiKey: 'k',
          messages: const <AiMessage>[AiMessage('user', 'x')],
        ),
      ).timeout(const Duration(seconds: 10)),
      throwsA(
        isA<AiException>()
            .having((AiException e) => e.kind, 'kind', AiErrorKind.timeout)
            .having((AiException e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('取消：静默结束（无 error、无残留）', () async {
    final (String base, HttpServer server) =
        await _serve((HttpRequest r) async {
      await Completer<void>().future;
    });
    active = server;
    final AiCall call = client.chatStream(
      config: _config(base, timeoutSeconds: 5),
      apiKey: 'k',
      messages: const <AiMessage>[AiMessage('user', 'x')],
    );
    bool done = false;
    Object? error;
    final Completer<void> finished = Completer<void>();
    call.stream.listen(
      (_) {},
      onError: (Object e) {
        error = e;
      },
      onDone: () {
        done = true;
        if (!finished.isCompleted) {
          finished.complete();
        }
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    call.cancel();
    await finished.future.timeout(const Duration(seconds: 5));
    expect(error, isNull, reason: '取消不应向流抛错');
    expect(done, isTrue);
  });

  test('并发上限 2（`AI-08` ③：三路同发，服务端峰值 ≤ 2）', () async {
    int inflight = 0;
    int peak = 0;
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      inflight++;
      if (inflight > peak) {
        peak = inflight;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      _sse(r, <String>['x']);
      await r.response.close();
      inflight--;
    });
    active = server;
    final List<List<String>> results = await Future.wait(
      List<Future<List<String>>>.generate(
        3,
        (_) => collect(
          client.chatStream(
            config: _config(base),
            apiKey: 'k',
            messages: const <AiMessage>[AiMessage('user', 'x')],
          ),
        ),
      ),
    );
    expect(results, hasLength(3));
    expect(peak, lessThanOrEqualTo(2));
  });

  test('testConnection：200 → 成功返回', () async {
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      r.response.write(jsonEncode(<String, Object?>{'choices': <Object?>[]}));
      await r.response.close();
    });
    active = server;
    await client.testConnection(config: _config(base), apiKey: 'k');
  });

  test('testConnection：401 → unauthorized 可读错误', () async {
    final (String base, HttpServer server) = await _serve((HttpRequest r) async {
      r.response.statusCode = HttpStatus.unauthorized;
      await r.response.close();
    });
    active = server;
    await expectLater(
      client.testConnection(config: _config(base), apiKey: 'bad'),
      throwsA(
        isA<AiException>().having(
          (AiException e) => e.kind,
          'kind',
          AiErrorKind.unauthorized,
        ),
      ),
    );
  });
}
