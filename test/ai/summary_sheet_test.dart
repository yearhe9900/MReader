// `AI-04` ①②③ / `AI-05` ①②③ / `AI-08` ①② / `AI-09` ①：AI 摘要面板 widget
// 测试（长度档、缓存命中零请求、重新生成、逐章递进、中断续做只补缺章、回顾合并
// 带「上次读到」、失败重试、范围行逐模式）。
//
// 测试口径同 `selection_ai_sheet_test`：关档宿主（`MaterialApp.builder` 形制）、
// 真异步 IO 统一 [settleReal] 推进、mock OpenAI 端点本机 HttpServer。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/ai/summarize.dart';
import 'package:mreader/ai/summary_cache.dart';
import 'package:mreader/model/chapter.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/reader/summary_sheet.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../test_config.dart';

/// 起一次性本地服务（与 `selection_ai_sheet_test` 同款）。
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

bool _isMergeBody(Map<String, Object?> body) {
  final List<Object?> messages = body['messages']! as List<Object?>;
  final Map<String, Object?> first = messages.first! as Map<String, Object?>;
  return first['content'] == kMergeSummarySystemPrompt;
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  late Directory dir;
  late ProviderStore store;
  late SummaryCache cache;
  late AiClient client;
  HttpServer? active;
  late BuildContext ctx;

  const List<Chapter> chapters = <Chapter>[
    Chapter(href: 'h1', title: '第一章', level: 0, locate: ''),
    Chapter(href: 'h2', title: '第二章', level: 0, locate: ''),
    Chapter(href: 'h3', title: '第三章', level: 0, locate: ''),
  ];

  Future<String> loadText(int i) async => '第${i + 1}章的正文内容。';

  setUp(() async {
    // binding 初始化会把 HttpOverrides.global 换成「一律 400」的假客户端；
    // 本文件的本地 mock server 需要真实网络栈，恢复为 null。
    HttpOverrides.global = null;
    GlassRuntime.resetForTest();
    dir = Directory.systemTemp.createTempSync('mreader_summary_ui_');
    store = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
    await store.load();
    cache = SummaryCache(dir);
    await cache.load();
    client = AiClient();
    active = null;
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

  /// 关档宿主（形制同 `selection_ai_sheet_test`）。
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

  /// 存配置（+ 可选密钥）——真 IO，必须包 runAsync。
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
            useFor: const <AiUseCase>{AiUseCase.summarize},
          ),
        );
        if (withKey) {
          await store.vault.write('c1', 'sk-t');
        }
      });

  void openSheet({
    SummaryMode mode = SummaryMode.chapter,
    int currentIndex = 0,
  }) {
    showSummarySheet(
      ctx,
      initialMode: mode,
      aiStore: store,
      aiClient: client,
      summaryCache: cache,
      bookId: 'b1',
      chapters: chapters,
      currentIndex: currentIndex,
      loadText: loadText,
    );
  }

  testWidgets('无配置：引导文案 + 模式/长度行在场，不给「重试」', (tester) async {
    await tester.pumpWidget(buildHome());
    openSheet();
    await tester.pumpAndSettle(); // 同步出错态、无 spinner → 可 settle

    expect(find.text('AI 摘要'), findsOneWidget);
    expect(
      find.text('尚未配置 AI 服务：请先在「设置 → AI 服务」中添加配置并勾选用途'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsNothing);
    expect(find.text('停止'), findsNothing);
    expect(find.text('复制'), findsNothing);
    // 三模式 + 长度档在场。
    expect(find.byKey(const Key('summary-mode-chapter')), findsOneWidget);
    expect(find.byKey(const Key('summary-mode-book')), findsOneWidget);
    expect(find.byKey(const Key('summary-mode-recap')), findsOneWidget);
    expect(find.byKey(const Key('summary-length-100')), findsOneWidget);
    expect(find.byKey(const Key('summary-length-200')), findsOneWidget);
    expect(find.byKey(const Key('summary-length-500')), findsOneWidget);
    // `AI-09` ① 范围行（无配置时未取正文 → 0 字）。
    expect(
      find.byKey(const Key('summary-scope')),
      findsOneWidget,
    );
    expect(find.textContaining('本次发送：第 1 章全文'), findsOneWidget);
    expect(find.textContaining('目标 200 字梗概'), findsOneWidget);
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
          find.text('尚未设置 API Key：请在该配置中填写密钥')
              .evaluate()
              .isNotEmpty ||
          find.text('复制').evaluate().isNotEmpty,
    );

    expect(find.text('尚未设置 API Key：请在该配置中填写密钥'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('停止'), findsNothing);
  });

  testWidgets('`AI-04` ①②③：生成完成 → 重开命中缓存零请求 → 重新生成 → 长度档',
      (tester) async {
    int calls = 0;
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        calls += 1;
        _sse(r, <String>['章一梗概']);
        await r.response.close();
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleUntil(
      tester,
      done: () => find.text('复制').evaluate().isNotEmpty,
    );

    // 首次：流式生成完成。
    expect(find.text('章一梗概'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(calls, 1);
    expect(find.byKey(const Key('summary-cache-tag')), findsNothing);

    // 关面板 → 二次进入：命中缓存、零请求（`AI-04` ②）。
    await tester.pumpAndSettle(); // 等入场动画收束，避免 tap 打在动画帧上
    await tester.tap(find.byKey(const Key('summary-close')));
    await tester.pumpAndSettle();
    openSheet();
    await settleUntil(
      tester,
      done: () =>
          find.byKey(const Key('summary-cache-tag')).evaluate().isNotEmpty,
    );
    expect(find.text('章一梗概'), findsOneWidget);
    expect(find.byKey(const Key('summary-cache-tag')), findsOneWidget);
    expect(calls, 1);
    // `AI-04` ③ 手动重新生成：force 发新请求，tag 消失。
    await tester.pumpAndSettle(); // 等入场动画收束，避免 tap 打在动画帧上
    await tester.tap(find.text('重新生成'));
    await settleUntil(
      tester,
      done: () =>
          calls == 2 &&
          find.byKey(const Key('summary-cache-tag')).evaluate().isEmpty &&
          find.text('章一梗概').evaluate().isNotEmpty &&
          find.byKey(const Key('summary-stop')).evaluate().isEmpty,
    );
    expect(calls, 2);
    expect(find.byKey(const Key('summary-cache-tag')), findsNothing);
    expect(find.text('章一梗概'), findsOneWidget);

    // `AI-04` ① 长度档切换：500 字键不同 → miss → 新请求 + 范围行同步。
    await tester.tap(find.byKey(const Key('summary-length-500')));
    await settleUntil(
      tester,
      done: () =>
          calls == 3 &&
          find.textContaining('目标 500 字梗概').evaluate().isNotEmpty &&
          find.text('章一梗概').evaluate().isNotEmpty &&
          find.byKey(const Key('summary-stop')).evaluate().isEmpty,
    );
    expect(calls, 3);
    expect(find.textContaining('目标 500 字梗概'), findsOneWidget);
    expect(find.text('章一梗概'), findsOneWidget);
  });

  testWidgets('`AI-08` ②：500 回显中文原因 + 「重试」再发起成功', (tester) async {
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
    await settleUntil(
      tester,
      done: () => find.text('服务端错误（500）').evaluate().isNotEmpty,
    );

    expect(find.text('服务端错误（500）'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.pumpAndSettle(); // 等入场动画收束，避免 tap 打在动画帧上
    await tester.tap(find.text('重试'));
    await settleUntil(
      tester,
      done: () => find.text('重试成功').evaluate().isNotEmpty,
    );
    expect(find.text('重试成功'), findsOneWidget);
    expect(find.text('服务端错误（500）'), findsNothing);
  });

  testWidgets('`AI-05` ③：全书摘要中途中断 →「已中断」→ 继续只补缺章',
      (tester) async {
    int chapterCalls = 0;
    int mergeCalls = 0;
    bool holdSecond = true; // 第 2 章请求挂起，模拟长书中途停止
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        final Map<String, Object?> body = await _body(r);
        if (_isMergeBody(body)) {
          mergeCalls += 1;
          _sse(r, <String>['全书总结']);
          await r.response.close();
        } else {
          chapterCalls += 1;
          if (chapterCalls == 2 && holdSecond) {
            await _sseHold(r, <String>['半截']);
          } else {
            _sse(r, <String>['章$chapterCalls 梗概']);
            await r.response.close();
          }
        }
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet(mode: SummaryMode.book);
    // 第 1 章完成、第 2 章挂起：进度 + 停止在场（等第 2 请求已到服务端再断言）。
    await settleUntil(
      tester,
      done: () =>
          chapterCalls >= 2 &&
          find.textContaining('正在生成章摘要（1/3）').evaluate().isNotEmpty,
    );
    expect(find.textContaining('正在生成章摘要（1/3）'), findsOneWidget);
    expect(find.byKey(const Key('summary-stop')), findsOneWidget);
    expect(chapterCalls, 2);

    // 中途停止（`AI-08` ①）：章级成果保留 → 回「已中断，可续做」。
    await tester.tap(find.byKey(const Key('summary-stop')));
    await settleUntil(
      tester,
      done: () =>
          find.textContaining('已中断（完成 1/3 章）').evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('summary-stop')), findsNothing);
    expect(find.byKey(const Key('summary-error')), findsOneWidget);
    expect(
      find.textContaining('已中断（完成 1/3 章）'),
      findsOneWidget,
    );
    expect(chapterCalls, 2);

    // 继续：第 1 章命中缓存跳过，只补第 2、3 章 + 合并（`AI-05` ③）。
    holdSecond = false;
    await tester.tap(find.byKey(const Key('summary-generate')));
    // 等到合并流完整收束（首帧 delta 只让文本在场，`复制` 要 _running=false）。
    await settleUntil(
      tester,
      done: () =>
          find.text('全书总结').evaluate().isNotEmpty &&
          find.byKey(const Key('summary-stop')).evaluate().isEmpty,
    );
    expect(find.text('全书总结'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(chapterCalls, 4); // 2（中断前）+ 2（续做）——第 1 章零重发
    expect(mergeCalls, 1);

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

  testWidgets('`AI-09` ① + `AI-05` ②：范围行逐模式；回顾合并带「上次读到」',
      (tester) async {
    String? mergeUser;
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        final Map<String, Object?> body = await _body(r);
        if (_isMergeBody(body)) {
          final Map<String, Object?> user =
              (body['messages']! as List<Object?>)[1]! as Map<String, Object?>;
          mergeUser = user['content'] as String;
          _sse(r, <String>['回顾内容']);
        } else {
          _sse(r, <String>['章梗概']);
        }
        await r.response.close();
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet(currentIndex: 2); // 读到第 3 章

    // 章模式首生成完成（模式 chip 生成中禁用 → 必须等完成才能切换）。
    await settleUntil(
      tester,
      done: () =>
          find.text('章梗概').evaluate().isNotEmpty &&
          find.byKey(const Key('summary-stop')).evaluate().isEmpty,
    );

    // 章模式：报单章全文与目标长度（`AI-04` ① 200 字基线）。
    expect(
      find.text('本次发送：第 3 章全文（9 字），目标 200 字梗概'),
      findsOneWidget,
    );

    // 全书模式：报逐章发送 + 合并只发梗概。
    await tester.pumpAndSettle(); // 等入场动画收束，避免 tap 打在动画帧上
    await tester.tap(find.byKey(const Key('summary-mode-book')));
    await settleUntil(
      tester,
      done: () =>
          find.text('回顾内容').evaluate().isNotEmpty &&
          find.byKey(const Key('summary-stop')).evaluate().isEmpty,
    );
    expect(
      find.text(
        '本次发送：逐章发送各章全文（共 3 章，每章一次请求），合并时仅发送各章梗概',
      ),
      findsOneWidget,
    );

    // 回顾模式：近 5 章窗口（3 章书夹到 1~3）+「上次读到第 3 章」进合并请求。
    await tester.pumpAndSettle(); // 无 spinner 态，等动画收束再切 chip
    await tester.tap(find.byKey(const Key('summary-mode-recap')));
    await settleUntil(
      tester,
      done: () =>
          find.textContaining('本次发送：第 1~3 章全文（近 5 章')
              .evaluate()
              .isNotEmpty &&
          find.byKey(const Key('summary-stop')).evaluate().isEmpty,
    );
    expect(
      find.text('本次发送：第 1~3 章全文（近 5 章，上次读到第 3 章）'),
      findsOneWidget,
    );
    expect(find.text('回顾内容'), findsOneWidget);
    expect(mergeUser, contains('上次读到第 3 章'));
    expect(mergeUser, contains('不超过 400 字'));
  });
}
