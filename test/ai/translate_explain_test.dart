// `M3-T02`：划词翻译 / 释义的消息组装 + 流式调用（`AI-02`、`AI-03` ①、`AI-09` ①）。
//
// 纯函数部分断言提示词结构（system 恒为首条、最保守模式只发选文、非保守模式
// 带前后段落）；流式部分用本机 `HttpServer` 模拟 OpenAI 兼容端点，验证请求体
// 与 [translateMessages] 同构 + chunks 逐帧到达。纯 `test()`（无 FakeAsync 区）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/explain.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/translate.dart';

/// 起一次性本地服务（与 `ai_client_test` 同款）。
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

AiProviderConfig _config(String baseUrl) => AiProviderConfig(
      id: 'c1',
      name: 't',
      baseUrl: baseUrl,
      model: 'm',
    );

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

void main() {
  group('translateMessages（`AI-09` ① 上下文范围）', () {
    test('system 恒为首条且是翻译系统提示词', () {
      final List<AiMessage> msgs = translateMessages(text: 'hello');
      expect(msgs, hasLength(2));
      expect(msgs[0].role, 'system');
      expect(msgs[0].content, kTranslateSystemPrompt);
      expect(msgs[0].content, contains('简体中文'));
      expect(msgs[0].content, contains('不要解释'));
    });

    test('最保守模式（无前后段落）：user 只含待翻译文本', () {
      final List<AiMessage> msgs = translateMessages(text: 'hello world');
      expect(msgs[1].role, 'user');
      expect(msgs[1].content, contains('待翻译：'));
      expect(msgs[1].content, contains('hello world'));
      expect(msgs[1].content, isNot(contains('前文')));
      expect(msgs[1].content, isNot(contains('后文')));
    });

    test('带上下文：前文 / 后文都进 user', () {
      final List<AiMessage> msgs = translateMessages(
        text: 'it',
        before: '前面的段落',
        after: '后面的段落',
      );
      expect(msgs[1].content, contains('前文：'));
      expect(msgs[1].content, contains('前面的段落'));
      expect(msgs[1].content, contains('待翻译：'));
      expect(msgs[1].content, contains('后文：'));
      expect(msgs[1].content, contains('后面的段落'));
      // 前文在待翻译之前、后文在之后（顺序敏感）。
      expect(
        msgs[1].content.indexOf('前文'),
        lessThan(msgs[1].content.indexOf('待翻译')),
      );
      expect(
        msgs[1].content.indexOf('后文'),
        greaterThan(msgs[1].content.indexOf('待翻译')),
      );
    });

    test('空前文 / 后文视为不传', () {
      final List<AiMessage> msgs =
          translateMessages(text: 'x', before: '', after: '');
      expect(msgs[1].content, isNot(contains('前文')));
      expect(msgs[1].content, isNot(contains('后文')));
    });
  });

  group('explainMessages（`AI-03` ① 结合上下文）', () {
    test('system 恒为首条且要求语境义优先', () {
      final List<AiMessage> msgs = explainMessages(text: '词');
      expect(msgs, hasLength(2));
      expect(msgs[0].role, 'system');
      expect(msgs[0].content, kExplainSystemPrompt);
      expect(msgs[0].content, contains('结合上下文'));
      expect(msgs[0].content, contains('语境义优先'));
    });

    test('user 以「词语：」引出选词；带上下文时前后段落齐备', () {
      final List<AiMessage> msgs = explainMessages(
        text: '境界',
        before: '他突破了',
        after: '惊呆了众人。',
      );
      expect(msgs[1].content, contains('词语：'));
      expect(msgs[1].content, contains('境界'));
      expect(msgs[1].content, contains('前文：'));
      expect(msgs[1].content, contains('他突破了'));
      expect(msgs[1].content, contains('后文：'));
      expect(msgs[1].content, contains('惊呆了众人。'));
    });

    test('最保守模式只发词本身', () {
      final List<AiMessage> msgs = explainMessages(text: '境界');
      expect(msgs[1].content, isNot(contains('前文')));
      expect(msgs[1].content, isNot(contains('后文')));
    });
  });

  group('流式调用（复用 AiClient 底座）', () {
    HttpServer? active;

    tearDown(() async {
      final HttpServer? s = active;
      active = null;
      if (s != null) {
        await s.close(force: true);
      }
    });

    test('translateSelection：请求体与 translateMessages 同构，chunks 逐帧到达',
        () async {
      late Map<String, Object?> body;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        body = jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, Object?>;
        _sse(r, <String>['你', '好']);
        await r.response.close();
      });
      active = server;
      final AiClient client = AiClient();
      final List<String> chunks = await translateSelection(
        client: client,
        config: _config(base),
        apiKey: 'sk-t',
        text: 'hello',
        before: 'ctx-before',
      ).stream.toList();
      expect(chunks, <String>['你', '好']);
      expect(
        body['messages'],
        translateMessages(text: 'hello', before: 'ctx-before')
            .map((AiMessage m) => <String, Object?>{
                  'role': m.role,
                  'content': m.content,
                })
            .toList(),
      );
      expect(body['stream'], isTrue);
    });

    test('explainSelection：走同一端点，user 是释义形态', () async {
      late Map<String, Object?> body;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        body = jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, Object?>;
        _sse(r, <String>['释义内容']);
        await r.response.close();
      });
      active = server;
      final AiClient client = AiClient();
      final List<String> chunks = await explainSelection(
        client: client,
        config: _config(base),
        apiKey: 'sk-t',
        text: '境界',
      ).stream.toList();
      expect(chunks, <String>['释义内容']);
      expect(
        body['messages'],
        explainMessages(text: '境界')
            .map((AiMessage m) => <String, Object?>{
                  'role': m.role,
                  'content': m.content,
                })
            .toList(),
      );
    });

    test('错误照底座分类抛出（500 → server 可重试）', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        r.response.statusCode = HttpStatus.internalServerError;
        await r.response.close();
      });
      active = server;
      final AiClient client = AiClient();
      await expectLater(
        translateSelection(
          client: client,
          config: _config(base),
          apiKey: 'k',
          text: 'x',
        ).stream.toList(),
        throwsA(
          isA<AiException>()
              .having((AiException e) => e.kind, 'kind', AiErrorKind.server)
              .having((AiException e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });
  });
}
