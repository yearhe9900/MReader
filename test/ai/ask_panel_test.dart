// `AI-06` ①②③ / `AI-08` ①② / `AI-09` ①③ / F5：跟书问答面板 widget 测试
// （检索→范围行→流式答案+引用跳转、不发全书、零命中直答、最保守受限、失败重试）。
//
// 测试口径同 `summary_sheet_test`：关档宿主、真异步 IO 统一 [settleReal] 推进、
// mock OpenAI 端点本机 HttpServer。⚠️ 输入框聚焦后光标闪烁是周期定时器：
// **enterText 之后禁用 `pumpAndSettle`**（永不收束），改 [settleUntil] 定轮推进。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/rag.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/ask_panel.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../test_config.dart';

/// 起一次性本地服务（与 `summary_sheet_test` 同款）。
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

/// 读请求体（流只能消费一次）。
Future<Map<String, Object?>> _body(HttpRequest r) async =>
    jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, Object?>;

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  late Directory dir;
  late ProviderStore store;
  late RagIndexStore ragStore;
  late AiClient client;
  HttpServer? active;
  late BuildContext ctx;

  final List<SearchHit> jumps = <SearchHit>[];
  String jumpQuery = '';

  // 章文本（两章：第 1 章两段）；索引 / 检索 / 断言共用同一事实源。
  const List<String> titles = <String>['第一章', '第二章'];
  const List<String> texts = <String>[
    '猫坐在垫子上。\n狗在院子里跑。',
    '天空很蓝。',
  ];
  Future<String> loadText(int i) async => texts[i];

  setUp(() async {
    // binding 初始化会把 HttpOverrides.global 换成「一律 400」的假客户端；
    // 本文件的本地 mock server 需要真实网络栈，恢复为 null。
    HttpOverrides.global = null;
    GlassRuntime.resetForTest();
    dir = Directory.systemTemp.createTempSync('mreader_ask_ui_');
    store = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
    await store.load();
    // 最保守模式默认开启（`AI-09` ③）；本文件除「受限」用例外都按非受限口径测。
    await store.setSelectionOnly(false);
    ragStore = RagIndexStore(); // 纯内存模式（面板测试不碰磁盘索引）
    client = AiClient();
    active = null;
    jumps.clear();
    jumpQuery = '';
  });

  tearDown(() async {
    final HttpServer? server = active;
    active = null;
    if (server != null) {
      await server.close(force: true);
    }
    GlassRuntime.resetForTest();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 关档宿主（形制同 `summary_sheet_test`）。
  Widget buildHome() => MaterialApp(
        builder: (BuildContext context, Widget? child) => Material(
          type: MaterialType.transparency,
          child: GlassScopeProvider(
            config: glassTierConfigFor(GlassQualityTier.off),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: Scaffold(
          body: Builder(builder: (BuildContext context) {
            ctx = context;
            return const SizedBox.expand();
          }),
        ),
      );

  /// 交替 runAsync / pump：排密钥读取、HTTP、落盘等真异步 IO。
  Future<void> settleReal(WidgetTester tester, {int rounds = 30}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 同 [settleReal]，但每轮后判 [done]，命中即返回所用轮数（上限 [maxRounds] 防死等）。
  Future<int> settleUntil(
    WidgetTester tester, {
    required bool Function() done,
    int maxRounds = 150,
  }) async {
    for (int i = 1; i <= maxRounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      if (done()) return i;
    }
    return maxRounds;
  }

  /// 存配置（+ 可选密钥）——真 IO，必须包 runAsync。问答走 `AiUseCase.chat`。
  Future<void> addConfig(
    WidgetTester tester, {
    required String baseUrl,
    bool withKey = true,
  }) =>
      tester.runAsync(() async {
        await store.saveConfig(
          AiProviderConfig(
            id: 'c1',
            name: 't',
            baseUrl: baseUrl,
            model: 'm',
            useFor: const <AiUseCase>{AiUseCase.chat},
          ),
        );
        if (withKey) {
          await store.vault.write('c1', 'sk-t');
        }
      });

  void openSheet() {
    showAskSheet(
      ctx,
      aiStore: store,
      aiClient: client,
      ensureIndex: () => ragStore.ensure(
        bookId: 'b1',
        titles: titles,
        loadText: loadText,
      ),
      loadText: loadText,
      onJump: (SearchHit hit, String query) {
        // 与阅读页同契约：调用方负责关弹窗 + 跳转（此处只记录）。
        jumps.add(hit);
        jumpQuery = query;
      },
    );
  }

  /// 等提交按钮可用（配置 + 密钥读取完成）。
  bool submitReady(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('ask-submit'))).onPressed !=
      null;

  testWidgets('无配置：引导文案 + 范围行与输入框在场，不给「重试」',
      (tester) async {
    await tester.pumpWidget(buildHome());
    openSheet();
    await tester.pumpAndSettle(); // 同步出错态、无 spinner → 可 settle

    expect(find.text('AI 问答'), findsOneWidget);
    expect(
      find.text('尚未配置 AI 服务：请先在「设置 → AI 服务」中添加配置并勾选用途'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsNothing);
    expect(find.text('停止'), findsNothing);
    expect(find.byKey(const Key('ask-input')), findsOneWidget);
    expect(find.byKey(const Key('ask-scope')), findsOneWidget);
    expect(
      find.text('本地 BM25 检索 Top-5 片段作答，不发送全书'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ask-restricted')), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('有配置无密钥：引导填密钥，仍不给「重试」', (tester) async {
    await addConfig(
      tester,
      baseUrl: 'http://127.0.0.1:9/v1', // 密钥缺失不发请求，端口无效无碍
      withKey: false,
    );
    await tester.pumpWidget(buildHome());
    openSheet();
    // 读密钥是真 IO：等引导文案落地（固定轮数会偶发不够）。
    await settleUntil(
      tester,
      done: () =>
          find.text('尚未设置 API Key：请在该配置中填写密钥').evaluate().isNotEmpty,
    );

    expect(find.text('尚未设置 API Key：请在该配置中填写密钥'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('停止'), findsNothing);
  });

  testWidgets('F5 主流程：范围行「将发送 K 个片段，共 X 字」+ 流式答案 + 引用跳转 + 不发全书',
      (tester) async {
    String? system;
    String? user;
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        final Map<String, Object?> body = await _body(r);
        final List<Object?> messages = body['messages']! as List<Object?>;
        system = (messages[0]! as Map<String, Object?>)['content']! as String;
        user = (messages[1]! as Map<String, Object?>)['content']! as String;
        _sse(r, <String>['根据片段，', '猫坐在垫子上。']);
        await r.response.close();
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleUntil(tester, done: () => submitReady(tester));
    // 入场动画收束后再聚焦输入（enterText 后光标闪烁，禁 pumpAndSettle）。
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ask-input')), '猫在哪里');
    await tester.tap(find.byKey(const Key('ask-submit')));
    await settleUntil(
      tester,
      done: () => find.byKey(const Key('ask-copy')).evaluate().isNotEmpty,
    );

    // F5 范围行：1 个片段 7 字（"猫坐在垫子上。"）。
    expect(find.text('将发送 1 个片段，共 7 字'), findsOneWidget);
    expect(find.text('根据片段，猫坐在垫子上。'), findsOneWidget);
    expect(find.byKey(const Key('ask-citation-0')), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('停止'), findsNothing);

    // 请求体：system 约束 + 片段化 user；不含未命中章正文（`AI-06` ③）。
    expect(system, kRagSystemPrompt);
    expect(user, contains('问题：猫在哪里'));
    expect(user, contains('原文片段（共 1 个）：'));
    expect(user, contains('[1]（第一章）'));
    expect(user, contains('猫坐在垫子上。'));
    expect(user, isNot(contains('天空很蓝')));
    expect(user!.length, lessThan(500));

    // 点引用：传出命中（章 0 / 同口径 offset 0）+ 当前问题（`AI-06` ①）。
    await tester.tap(find.byKey(const Key('ask-citation-0')));
    await tester.pump(const Duration(milliseconds: 10));
    expect(jumps.length, 1);
    expect(jumps.first.chapterIndex, 0);
    expect(jumps.first.offset, 0);
    expect(jumpQuery, '猫在哪里');
  });

  testWidgets('`AI-06` ②：书内没有的信息 → 零请求直答「书中未提及」',
      (tester) async {
    int calls = 0;
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        calls += 1;
        _sse(r, <String>['不该被调用']);
        await r.response.close();
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleUntil(tester, done: () => submitReady(tester));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('ask-input')),
      '青蛙为什么唱歌',
    );
    await tester.tap(find.byKey(const Key('ask-submit')));
    await settleUntil(
      tester,
      done: () => find.byKey(const Key('ask-output')).evaluate().isNotEmpty,
    );

    expect(find.text('书中未提及。'), findsOneWidget);
    expect(
      find.text('未检索到相关片段（0 个），已直接回答「书中未提及」'),
      findsOneWidget,
    );
    expect(calls, 0); // 零命中不发请求
    expect(find.text('复制'), findsOneWidget);
    expect(find.byKey(const Key('ask-citation-0')), findsNothing);
  });

  testWidgets('`AI-09` ③：最保守模式（selectionOnly）问答标注受限且不可发送',
      (tester) async {
    await addConfig(tester, baseUrl: 'http://127.0.0.1:9/v1');
    await tester.runAsync(() => store.setSelectionOnly(true));

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleUntil(
      tester,
      done: () => find.byKey(const Key('ask-scope')).evaluate().isNotEmpty,
    );

    expect(
      find.text(
        '「仅发送选中文本」最保守模式下，跟书问答受限：检索片段属于章节上下文，不发送',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('ask-submit')))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<TextField>(find.byKey(const Key('ask-input'))).enabled,
      isFalse,
    );
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('`AI-08` ②：500 回显中文原因 + 「重试」再发起成功',
      (tester) async {
    int calls = 0;
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        calls += 1;
        if (calls == 1) {
          r.response.statusCode = HttpStatus.internalServerError;
          await r.response.close();
        } else {
          _sse(r, <String>['重试成功']);
          await r.response.close();
        }
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleUntil(tester, done: () => submitReady(tester));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ask-input')), '猫在哪里');
    await tester.tap(find.byKey(const Key('ask-submit')));
    await settleUntil(
      tester,
      done: () => find.text('服务端错误（500）').evaluate().isNotEmpty,
    );

    expect(find.text('服务端错误（500）'), findsOneWidget);
    expect(find.byKey(const Key('ask-error')), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 输入框仍聚焦（光标闪烁）：不能 pumpAndSettle，直接 tap（画面已静止）。
    await tester.tap(find.text('重试'));
    await settleUntil(
      tester,
      done: () => find.text('重试成功').evaluate().isNotEmpty,
    );
    expect(find.text('重试成功'), findsOneWidget);
    expect(find.text('服务端错误（500）'), findsNothing);
    expect(calls, 2);

    // keep-alive 连接的空闲定时器（15s）随 socket 关闭取消：手动关 server
    // 再排空事件循环，否则 teardown 后仍有 pending timer。
    await tester.runAsync(() async {
      final HttpServer? s = active;
      active = null;
      if (s != null) {
        await s.close(force: true);
      }
    });
    await settleReal(tester);
  });

  testWidgets('`AI-08` ①：流式中途停止 → 保留半截输出、按钮复位',
      (tester) async {
    int calls = 0;
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        calls += 1;
        await _sseHold(r, <String>['半截答案']);
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleUntil(tester, done: () => submitReady(tester));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ask-input')), '猫在哪里');
    await tester.tap(find.byKey(const Key('ask-submit')));
    // 首帧 delta 已渲染且停止按钮在场。
    await settleUntil(
      tester,
      done: () =>
          find.byKey(const Key('ask-output')).evaluate().isNotEmpty &&
          find.byKey(const Key('ask-stop')).evaluate().isNotEmpty,
    );
    expect(find.text('半截答案'), findsOneWidget);
    expect(calls, 1);

    await tester.tap(find.byKey(const Key('ask-stop')));
    await settleUntil(
      tester,
      done: () => find.byKey(const Key('ask-stop')).evaluate().isEmpty,
    );
    expect(find.byKey(const Key('ask-stop')), findsNothing);
    expect(find.text('半截答案'), findsOneWidget); // 半截输出保留
    expect(find.text('复制'), findsOneWidget);

    // held 连接仍开着：手动关 server 排掉残留，再排空事件循环。
    await tester.runAsync(() async {
      final HttpServer? s = active;
      active = null;
      if (s != null) {
        await s.close(force: true);
      }
    });
    await settleReal(tester);
  });
}
