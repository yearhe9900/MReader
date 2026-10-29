// `AI-02` ②③④ / `AI-03` ② / `AI-08` ①② / `AI-09` ①：划词翻译 / 释义结果面板
// widget 测试（流式完成出「复制」、中途停止转可复制态、失败回显中文原因+重试、
// 释义存生词本落盘、范围行两态）。
//
// ⚠️ 测试口径：钉「关」档须把 `GlassScopeProvider` 放 `MaterialApp.builder`
// （覆盖路由树，否则 route 回落玻璃默认档，软件光栅下每帧数百 ms）；spinner 在场
// **禁用** `pumpAndSettle`（会挂死），真异步 IO（读密钥 / HTTP / 落盘）一律
// [settleReal]（runAsync 与 pump 交替）推进。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/ai/vocab_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/reader/selection_ai_sheet.dart';
import 'package:mreader/reader/selection_overlay.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../test_config.dart';

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

/// OpenAI 兼容 SSE 帧 + `[DONE]`（**不关连接**，由调用方 `close()`）。
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

/// 只发若干帧、**不写 `[DONE]`、不关 response**：连接保持 → 面板停在
/// 「生成中」（`AI-02` ③ 中途停止用例）。
Future<void> _sseHold(HttpRequest request, List<String> chunks) async {
  // ⚠️ 必须关 `bufferOutput`（且在任何 write 之前，headersWritten 后设会抛
  // StateError）：默认缓冲到 close 才落 socket，不关连接时客户端连响应头都收不到。
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

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  late Directory dir;
  late ProviderStore store;
  late VocabStore vocab;
  late AiClient client;
  HttpServer? active;
  late BuildContext ctx;

  /// 划词选区样本（词「境界」，h1 第 4 段）。
  const ParaSelection sel = ParaSelection(
    chapterHref: 'h1',
    paraIndex: 3,
    start: 0,
    end: 2,
    text: '境界',
  );

  setUp(() async {
    // ⚠️ 必须恢复 `HttpOverrides.global = null`：binding 初始化会换成「一律 400」
    // 假客户端（防误联网），本地 mock server 需要真实网络栈（isolate 级不外溢）。
    HttpOverrides.global = null;
    GlassRuntime.resetForTest();
    dir = Directory.systemTemp.createTempSync('mreader_sheet_ui_');
    store = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
    await store.load();
    vocab = VocabStore(dir);
    await vocab.load();
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

  /// 关档宿主（`MaterialApp.builder` 形制：provider 覆盖到**路由树**之上，
  /// 面板与面板内 toast 都钉关档——只钉 `home` 的话 route 回落玻璃默认档）。
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

  /// 交替 runAsync / pump：排空面板内发起的真异步 IO（读密钥 / HTTP / 落盘）。
  Future<void> settleReal(WidgetTester tester, {int rounds = 30}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 存配置（+ 可选密钥）——真 IO，必须包 runAsync（同 `ai_settings_page_test`）。
  Future<void> addConfig(
    WidgetTester tester, {
    required String baseUrl,
    Set<AiUseCase> useFor = const <AiUseCase>{AiUseCase.translate},
    bool withKey = true,
  }) =>
      tester.runAsync(() async {
        await store.saveConfig(
          AiProviderConfig(
            id: 'c1',
            name: 't',
            baseUrl: baseUrl,
            model: 'm',
            useFor: useFor,
          ),
        );
        if (withKey) {
          await store.vault.write('c1', 'sk-t');
        }
      });

  /// 弹出面板（后续推进由调用方按状态选 [settleReal] / `pumpAndSettle`）。
  void openSheet({
    SelectionAiMode mode = SelectionAiMode.translate,
    String? before,
    String? after,
  }) {
    showSelectionAiSheet(
      ctx,
      mode: mode,
      selection: sel,
      aiStore: store,
      aiClient: client,
      vocabStore: vocab,
      bookId: 'b1',
      bookTitle: '测试书',
      before: before,
      after: after,
    );
  }

  testWidgets('无配置：只给引导文案，不给「重试」；范围行报最保守', (tester) async {
    await tester.pumpWidget(buildHome());
    openSheet();
    await tester.pumpAndSettle(); // 同步出错态、无 spinner → 可 settle

    expect(find.text('划词翻译'), findsOneWidget);
    expect(
      find.text('尚未配置 AI 服务：请先在「设置 → AI 服务」中添加配置并勾选用途'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsNothing);
    expect(find.text('复制'), findsNothing);
    expect(find.text('停止'), findsNothing);
    // `AI-09` ① 默认最保守：只报选文字数。
    expect(find.text('本次仅发送选中文本（2 字）'), findsOneWidget);
    // 选文预览在场。
    expect(find.text('境界'), findsOneWidget);
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
    await settleReal(tester); // 读密钥是真 IO

    expect(
      find.text('尚未设置 API Key：请在该配置中填写密钥'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsNothing); // `_canRetry` 需配置 + 密钥齐备
    expect(find.text('停止'), findsNothing);
  });

  testWidgets('`AI-02` ②：流式出字到完成 → 「复制」，翻译模式不出生词本入口',
      (tester) async {
    // `_copy` 走 `Clipboard.setData`（平台通道无默认实现会抛
    // MissingPluginException）→ 注册 mock 拦截（每测自动清理）。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => null,
    );
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        _sse(r, <String>['翻', '译完成']);
        await r.response.close();
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleReal(tester);

    expect(find.text('翻译完成'), findsOneWidget); // 增量拼接的最终输出
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('停止'), findsNothing);
    expect(find.text('存生词本'), findsNothing); // 翻译模式不出生词本入口

    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(find.text('译文已复制'), findsOneWidget);
  });

  testWidgets('`AI-02` ③：中途停止 → 保留已出文字、转可复制态', (tester) async {
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        await _sseHold(r, <String>['部分内容']);
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    await addConfig(tester, baseUrl: base);

    await tester.pumpWidget(buildHome());
    openSheet();
    await settleReal(tester);

    expect(find.text('部分内容'), findsOneWidget); // 首帧已到、流未结束
    expect(find.text('停止'), findsOneWidget);

    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(find.text('停止'), findsNothing);
    expect(find.text('部分内容'), findsOneWidget); // 已出文字保留
    expect(find.text('复制'), findsOneWidget); // 完成态（可复制）
    expect(
      find.textContaining('失败'),
      findsNothing, // 取消是静默的，不回显错误
    );

    // ⚠️ 必须手动关 server：held 连接下 `abort()` 不生效，`Stream.timeout(60s)`
    // 定时器留在 FakeAsync 区会判失败；关掉 → 响应流报错退出 → 定时器取消。
    await tester.runAsync(() async {
      final HttpServer? server = active;
      active = null;
      if (server != null) {
        await server.close(force: true);
      }
    });
    await settleReal(tester);
  });

  testWidgets('`AI-02` ④：500 回显中文原因 + 「重试」再发起成功', (tester) async {
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
    await settleReal(tester);

    expect(find.text('服务端错误（500）'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await settleReal(tester);

    expect(find.text('重试成功'), findsOneWidget);
    expect(find.text('服务端错误（500）'), findsNothing);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('`AI-03` ②：释义完成 → 存生词本 → 字段落盘 + 按钮转「已存」',
      (tester) async {
    final (String, HttpServer)? served = await tester.runAsync(
      () => _serve((HttpRequest r) async {
        _sse(r, <String>['释义内容']);
        await r.response.close();
      }),
    );
    final (String base, HttpServer server) = served!;
    active = server;
    // 释义模式配置路由：对话用途优先（回退翻译）——这里存 chat 用途即命中。
    await addConfig(
      tester,
      baseUrl: base,
      useFor: const <AiUseCase>{AiUseCase.chat},
    );

    await tester.pumpWidget(buildHome());
    openSheet(mode: SelectionAiMode.explain);
    await settleReal(tester);

    expect(find.text('划词释义'), findsOneWidget);
    expect(find.text('释义内容'), findsOneWidget);
    expect(find.text('存生词本'), findsOneWidget);

    await tester.tap(find.text('存生词本'));
    await settleReal(tester); // add() 含真 IO 落盘

    expect(find.text('已存'), findsOneWidget);
    expect(find.text('存生词本'), findsNothing);
    expect(find.text('已存入生词本'), findsOneWidget); // 轻提示

    expect(vocab.entries, hasLength(1));
    final VocabEntry entry = vocab.entries.single;
    expect(entry.word, '境界');
    expect(entry.meaning, '释义内容');
    expect(entry.bookId, 'b1');
    expect(entry.bookTitle, '测试书');
    expect(entry.chapterHref, 'h1');
    expect(entry.paraIndex, 3);
  });

  testWidgets('`AI-09` ① 范围行两态：最保守只报选文；关闭后报选文 + 前后段落',
      (tester) async {
    await tester.pumpWidget(buildHome());

    openSheet(before: '他突破了', after: '惊呆了众人。');
    await tester.pumpAndSettle(); // 无配置同步出错态，无 spinner
    expect(find.text('本次仅发送选中文本（2 字）'), findsOneWidget);
    expect(
      find.text('本次发送：选中文本 + 前后段落（共 12 字）'),
      findsNothing,
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.runAsync(() => store.setSelectionOnly(false));
    openSheet(before: '他突破了', after: '惊呆了众人。');
    await tester.pumpAndSettle();
    // 2（选文）+ 4（前）+ 6（后）= 12。
    expect(
      find.text('本次发送：选中文本 + 前后段落（共 12 字）'),
      findsOneWidget,
    );
    expect(find.text('本次仅发送选中文本（2 字）'), findsNothing);
  });
}
