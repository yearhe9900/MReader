// `AI-04` / `AI-05`：章节摘要 / 合并摘要的提示词组装 + 流式调用。
//
// 纯函数部分断言消息结构（system 恒为首条、目标长度进 user、分章编号顺序、
// 回顾背景 instruction）；流式部分用本机 `HttpServer` 模拟 OpenAI 兼容端点，
// 验证请求体与纯函数同构 + chunks 逐帧到达。形制照 `translate_explain_test`。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/summarize.dart';

/// 起一次性本地服务（与 `translate_explain_test` 同款）。
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
  group('summarizeMessages（`AI-04` ① 可指定长度）', () {
    test('system 恒为首条且是章节梗概系统提示词', () {
      final List<AiMessage> msgs = summarizeMessages(text: '正文');
      expect(msgs, hasLength(2));
      expect(msgs[0].role, 'system');
      expect(msgs[0].content, kSummarizeSystemPrompt);
      expect(msgs[0].content, contains('梗概'));
      expect(msgs[0].content, contains('简体中文'));
    });

    test('user 含目标长度与章节正文，正文原样在末尾', () {
      final List<AiMessage> msgs = summarizeMessages(
        text: '第一章的正文内容。',
        maxChars: 100,
      );
      expect(msgs[1].role, 'user');
      expect(msgs[1].content, contains('目标长度：不超过 100 字。'));
      expect(msgs[1].content, contains('章节正文：'));
      expect(msgs[1].content, contains('第一章的正文内容。'));
      // 默认 200（`AI-04` ① 验收基线「200 字内」）。
      expect(
        summarizeMessages(text: 'x').last.content,
        contains('不超过 $kSummaryDefaultChars 字'),
      );
    });

    test('带标题时进 user；空标题视为不传', () {
      final List<AiMessage> withTitle =
          summarizeMessages(text: 'body', title: '第三章 风起');
      expect(withTitle[1].content, contains('章节标题：第三章 风起'));
      expect(
        withTitle[1].content.indexOf('章节标题'),
        lessThan(withTitle[1].content.indexOf('章节正文')),
      );
      final List<AiMessage> empty =
          summarizeMessages(text: 'body', title: '');
      expect(empty[1].content, isNot(contains('章节标题')));
    });
  });

  group('mergeSummaryMessages（`AI-05` 全书 / 回顾合并）', () {
    test('system 恒为首条且要求按章节顺序串联', () {
      final List<AiMessage> msgs =
          mergeSummaryMessages(parts: <String>['甲：梗概']);
      expect(msgs, hasLength(2));
      expect(msgs[0].role, 'system');
      expect(msgs[0].content, kMergeSummarySystemPrompt);
      expect(msgs[0].content, contains('按章节顺序'));
      expect(msgs[0].content, contains('简体中文'));
    });

    test('各章梗概按 1..N 编号顺序进 user', () {
      final List<AiMessage> msgs = mergeSummaryMessages(
        parts: <String>['第一章梗概', '第二章梗概'],
        maxChars: 1000,
      );
      expect(msgs[1].content, contains('目标长度：不超过 1000 字。'));
      expect(msgs[1].content, contains('1. 第一章梗概'));
      expect(msgs[1].content, contains('2. 第二章梗概'));
      expect(
        msgs[1].content.indexOf('1. 第一章梗概'),
        lessThan(msgs[1].content.indexOf('2. 第二章梗概')),
      );
    });

    test('instruction 追加背景（前情回顾「上次读到」），null 时不出现', () {
      final List<AiMessage> withCtx = mergeSummaryMessages(
        parts: <String>['梗概'],
        instruction: '上次读到第 3 章。',
      );
      expect(withCtx[1].content, contains('上次读到第 3 章。'));
      expect(
        withCtx[1].content.indexOf('上次读到'),
        lessThan(withCtx[1].content.indexOf('各章梗概')),
      );
      final List<AiMessage> noCtx =
          mergeSummaryMessages(parts: <String>['梗概']);
      expect(noCtx[1].content, isNot(contains('上次读到')));
    });
  });

  group('summaryChunkMessages（PRD §8.3 超长分块）', () {
    test('片段消息带长度上限与片段正文', () {
      final List<AiMessage> msgs =
          summaryChunkMessages(text: '片段文本', chunkChars: 6000);
      expect(msgs[0].content, kSummaryChunkSystemPrompt);
      expect(msgs[1].content, contains('片段长度上限 6000 字。'));
      expect(msgs[1].content, contains('片段文本'));
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

    test('summarizeChapter：请求体与 summarizeMessages 同构，chunks 逐帧到达',
        () async {
      late Map<String, Object?> body;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        body = jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, Object?>;
        _sse(r, <String>['章', '梗概']);
        await r.response.close();
      });
      active = server;
      final AiClient client = AiClient();
      final List<String> chunks = await summarizeChapter(
        client: client,
        config: _config(base),
        apiKey: 'sk-t',
        text: '正文',
        maxChars: 100,
        title: '第一章',
      ).stream.toList();
      expect(chunks, <String>['章', '梗概']);
      expect(
        body['messages'],
        summarizeMessages(text: '正文', maxChars: 100, title: '第一章')
            .map((AiMessage m) => <String, Object?>{
                  'role': m.role,
                  'content': m.content,
                })
            .toList(),
      );
      expect(body['stream'], isTrue);
    });

    test('mergeSummaries：parts / instruction / 长度都进请求体', () async {
      late Map<String, Object?> body;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        body = jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, Object?>;
        _sse(r, <String>['全书总结']);
        await r.response.close();
      });
      active = server;
      final AiClient client = AiClient();
      final List<String> chunks = await mergeSummaries(
        client: client,
        config: _config(base),
        apiKey: 'k',
        parts: <String>['一：甲', '二：乙'],
        maxChars: 400,
        instruction: '上次读到第 5 章。',
      ).stream.toList();
      expect(chunks, <String>['全书总结']);
      expect(
        body['messages'],
        mergeSummaryMessages(
          parts: <String>['一：甲', '二：乙'],
          maxChars: 400,
          instruction: '上次读到第 5 章。',
        ).map((AiMessage m) => <String, Object?>{
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
        summarizeChapter(
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
