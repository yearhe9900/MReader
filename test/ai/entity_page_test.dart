// `M3-T05`：人物与设定梳理页 widget 测试（`AI-07` ①②③ / `AI-08` ①② /
// `AI-09` ①）。
//
// 验收映射：
//   · `AI-07` ① 成品名字原样展示、② 出场章节 chip 点击回调跳转；
//   · `AI-07` ③ 范围行与「仅已读」切换：切范围后新请求只发 0..readUpto；
//   · `AI-08` ① 停止中断（无结果 → 「已中断」+ 重试）、② 失败中文回显 +
//     重试、结果缓存（二次进入缓存 tag + 零请求）；
//   · `AI-09` ① 范围行常驻说明本次发什么。
//
// 三条测试口径同 `summary_sheet_test`：关档宿主（`MaterialApp.builder`
// 形制）、真异步 IO 统一 [settleReal] 推进、mock OpenAI 端点本机 HttpServer；
// 用到服务的用例在**测试体内**关 server + 排事件循环（keep-alive 空闲定时器
// 15s，teardown 才关会被 `!timersPending` 断言抓到）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/ai/summary_cache.dart';
import 'package:mreader/model/chapter.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/entity_page.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../test_config.dart';

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

/// 读请求体（流只能消费一次）。
Future<Map<String, Object?>> _body(HttpRequest r) async =>
    jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, Object?>;

const String _line =
    '{"name":"李昂","type":"人物","desc":"主角，药师弟子","chapters":[0]}';
const String _line2 =
    '{"name":"青冥宗","type":"势力","desc":"李昂所属宗门","chapters":[2]}';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  late Directory dir;
  late ProviderStore store;
  late SummaryCache cache;
  late AiClient client;
  HttpServer? active;
  late BuildContext ctx;
  late List<int> jumps;

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
    dir = Directory.systemTemp.createTempSync('mreader_entity_ui_');
    store = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
    await store.load();
    cache = SummaryCache(dir);
    await cache.load();
    client = AiClient();
    active = null;
    jumps = <int>[];
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

  /// 同 [settleReal]，但每轮后判 [done]，命中即返回（上限防死等）。
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

  /// 作业已完成：输出在场且「停止」消失。
  ///
  /// 输出在流式阶段就出现（`_running` 仍 true），凡是要断言完成态动作 /
  /// 点范围 chip（running 时禁用）/ pop（dispose 会取消在途）的等待都用它。
  bool runSettled() =>
      find.byKey(const Key('entity-output')).evaluate().isNotEmpty &&
      find.byKey(const Key('entity-stop')).evaluate().isEmpty;

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

  /// 用过服务的用例在测试体内关 server + 排空事件循环（keep-alive 空闲
  /// 定时器随 socket 关闭取消，否则 teardown 后仍有 pending timer）。
  Future<void> shutdownServer(WidgetTester tester) async {
    final HttpServer? server = active;
    active = null;
    if (server != null) {
      await tester.runAsync(() => server.close(force: true));
    }
    await settleReal(tester);
  }

  void openPage({int readUptoIndex = 1}) {
    Navigator.of(ctx).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => EntityPage(
          aiStore: store,
          aiClient: client,
          summaryCache: cache,
          bookId: 'b1',
          chapters: chapters,
          readUptoIndex: readUptoIndex,
          loadText: loadText,
          onJump: jumps.add,
        ),
      ),
    );
  }

  testWidgets('无配置：引导文案 + 范围行 + 范围二选在场，不给重试', (tester) async {
    await tester.pumpWidget(buildHome());
    openPage();
    await tester.pumpAndSettle(); // 同步出错态、无 spinner → 可 settle

    expect(find.text('人物与设定'), findsOneWidget);
    expect(
      find.byKey(const Key('entity-error')),
      findsOneWidget,
    );
    expect(
      find.text('尚未配置 AI 服务：请先在「设置 → AI 服务」中添加配置并勾选用途'),
      findsOneWidget,
    );
    expect(find.text('重试'), findsNothing);
    expect(find.text('停止'), findsNothing);
    expect(find.byKey(const Key('entity-range-read')), findsOneWidget);
    expect(find.byKey(const Key('entity-range-full')), findsOneWidget);
    expect(find.byKey(const Key('entity-cache-tag')), findsNothing);
    // `AI-09` ① 范围行（默认全书）。
    expect(find.byKey(const Key('entity-scope')), findsOneWidget);
    expect(find.textContaining('本次发送：第 1~3 章'), findsOneWidget);
    expect(find.textContaining('非一次全发'), findsOneWidget);
    // 默认范围 = 全书。
    expect(find.textContaining('全书（1~3章）'), findsOneWidget);
  });

  testWidgets('有配置无密钥：引导填密钥，仍不给重试', (tester) async {
    await addConfig(
      tester,
      baseUrl: 'http://127.0.0.1:9/v1', // 密钥缺失不发请求，端口无效无碍
      withKey: false,
    );
    await tester.pumpWidget(buildHome());
    openPage();
    // 读密钥是真 IO：等引导文案落地。
    final int rounds = await settleUntil(
      tester,
      done: () =>
          find.text('尚未设置 API Key：请在该配置中填写密钥').evaluate().isNotEmpty,
    );
    expect(rounds, lessThan(150));
    expect(find.text('重试'), findsNothing);
    expect(find.text('停止'), findsNothing);
  });

  testWidgets('生成成功：名字原样展示 + 章节 chip 回调 + 重新生成在场', (
    tester,
  ) async {
    final (String base, HttpServer server) = (await tester.runAsync(
      () => _serve((HttpRequest r) async {
        _sse(r, <String>['$_line\n$_line2\n']);
        await r.response.close();
      }),
    ))!;
    active = server;
    await addConfig(tester, baseUrl: base);
    await tester.pumpWidget(buildHome());
    openPage();

    final int rounds = await settleUntil(tester, done: runSettled);
    expect(rounds, lessThan(150));

    // `AI-07` ① 名字原样展示 + 分组标题 + 描述。
    expect(find.text('李昂'), findsOneWidget);
    expect(find.text('青冥宗'), findsOneWidget);
    expect(find.text('主角，药师弟子'), findsOneWidget);
    expect(find.text('人物'), findsOneWidget);
    expect(find.text('势力'), findsOneWidget);
    // `AI-07` ② 出场章节 chip（0-based → 显示第 1 章）。
    expect(find.widgetWithText(TextButton, '第1章'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '第3章'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '第1章'));
    expect(jumps, <int>[0]);
    // 完成态动作：重新生成在场、停止消失。
    expect(find.byKey(const Key('entity-generate')), findsOneWidget);
    expect(find.text('重新生成'), findsOneWidget);
    expect(find.text('停止'), findsNothing);
    expect(find.byKey(const Key('entity-cache-tag')), findsNothing);

    await shutdownServer(tester);
  });

  testWidgets('二次进入命中缓存：缓存 tag + 零请求（`AI-08` ③）', (tester) async {
    int calls = 0;
    final (String base, HttpServer server) = (await tester.runAsync(
      () => _serve((HttpRequest r) async {
        calls += 1;
        _sse(r, <String>['$_line\n']);
        await r.response.close();
      }),
    ))!;
    active = server;
    await addConfig(tester, baseUrl: base);
    await tester.pumpWidget(buildHome());

    openPage();
    final int first = await settleUntil(tester, done: runSettled);
    expect(first, lessThan(150));
    expect(calls, 1);

    // 关页再进：同范围同正文 → 缓存命中零请求。
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    openPage();
    final int second = await settleUntil(
      tester,
      done: () => find.byKey(const Key('entity-cache-tag')).evaluate().isNotEmpty,
    );
    expect(second, lessThan(150));
    expect(calls, 1);
    expect(find.text('李昂'), findsOneWidget);

    await shutdownServer(tester);
  });

  testWidgets('切「仅已读」：新请求只发 0..readUpto（`AI-07` ③）', (
    tester,
  ) async {
    final List<String> bodies = <String>[];
    final (String base, HttpServer server) = (await tester.runAsync(
      () => _serve((HttpRequest r) async {
        final Map<String, Object?> body = await _body(r);
        final Map<String, Object?> user =
            (body['messages']! as List<Object?>)[1]! as Map<String, Object?>;
        bodies.add(user['content'] as String);
        _sse(r, <String>['$_line\n']);
        await r.response.close();
      }),
    ))!;
    active = server;
    await addConfig(tester, baseUrl: base);
    await tester.pumpWidget(buildHome());
    openPage(readUptoIndex: 1); // 已读到第 2 章（0-based index 1）

    final int full = await settleUntil(tester, done: runSettled);
    expect(full, lessThan(150));
    expect(bodies, hasLength(1));
    expect(bodies.single, contains('章节 2')); // 全书：第三章标注在场
    expect(find.textContaining('仅已读部分'), findsNothing);

    // 切「仅已读」→ 自动按新范围重发（范围行同步切换）。
    await tester.tap(find.byKey(const Key('entity-range-read')));
    final int read = await settleUntil(
      tester,
      done: () => runSettled() && bodies.length == 2,
    );
    expect(read, lessThan(150));
    expect(bodies.last, contains('章节 0'));
    expect(bodies.last, isNot(contains('章节 2'))); // 第三章不发（防剧透）
    expect(find.textContaining('仅已读部分'), findsOneWidget);
    expect(find.textContaining('本次发送：第 1~2 章'), findsOneWidget);
    expect(find.textContaining('仅已读（1~2章）'), findsOneWidget);

    await shutdownServer(tester);
  });

  testWidgets('失败：中文回显 + 重试成功（`AI-08` ②）', (tester) async {
    int calls = 0;
    final (String base, HttpServer server) = (await tester.runAsync(
      () => _serve((HttpRequest r) async {
        calls += 1;
        if (calls == 1) {
          r.response.statusCode = 500;
          r.response.write('boom');
          await r.response.close();
        } else {
          _sse(r, <String>['$_line\n']);
          await r.response.close();
        }
      }),
    ))!;
    active = server;
    await addConfig(tester, baseUrl: base);
    await tester.pumpWidget(buildHome());
    openPage();

    final int err = await settleUntil(
      tester,
      done: () => find.byKey(const Key('entity-error')).evaluate().isNotEmpty,
    );
    expect(err, lessThan(150));
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('停止'), findsNothing);

    await tester.tap(find.byKey(const Key('entity-retry')));
    final int ok = await settleUntil(tester, done: runSettled);
    expect(ok, lessThan(150));
    expect(calls, 2);
    expect(find.text('李昂'), findsOneWidget);

    await shutdownServer(tester);
  });

  testWidgets('停止：无结果中断给「已中断」+ 重试（`AI-08` ①）', (tester) async {
    final Completer<void> arrived = Completer<void>();
    final (String base, HttpServer server) = (await tester.runAsync(
      () => _serve((HttpRequest r) async {
        if (!arrived.isCompleted) arrived.complete();
        await _sseHold(r, <String>[]); // 不给任何数据，挂住等停止
      }),
    ))!;
    active = server;
    await addConfig(tester, baseUrl: base);
    await tester.pumpWidget(buildHome());
    openPage();

    final int running = await settleUntil(
      tester,
      done: () =>
          arrived.isCompleted &&
          find.byKey(const Key('entity-stop')).evaluate().isNotEmpty,
    );
    expect(running, lessThan(150));

    await tester.tap(find.byKey(const Key('entity-stop')));
    final int stopped = await settleUntil(
      tester,
      done: () => find.byKey(const Key('entity-error')).evaluate().isNotEmpty,
    );
    expect(stopped, lessThan(150));
    expect(find.text('已中断且无结果，可点击重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('停止'), findsNothing);

    await shutdownServer(tester);
  });
}
