// `TTS-07` 在线 TTS 配置页 widget 测试（M3-T09）。
//
// 验收映射：
//   · 双模式表单切换（URL 模板 ↔ OpenAI 兼容：组随模式显隐）；
//   · 保存前 validate 中文校验弹窗（无 `{text}` 被拦）；
//   · 合法填写保存 → 落盘到 `OnlineTtsStore` + 页面返回；
//   · API Key 不回显（`DATA-02`）：已存密钥只给「留空保持」提示；
//   · 音频缓存计数与「清理」入口（`TTS-07` ② 管理面）。
//
// 口径：装具同 `ai_settings_page_test`（`capTestTimeout` / `tall` /
// `settleReal`）；真 IO（落盘 / 读密钥）包 `tester.runAsync`；期望值硬编码。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/tts/online_tts.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/tts_settings_page.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  late Directory dir;
  late OnlineTtsStore store;
  late ProviderStore aiStore;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mreader_tts_page_');
    store = OnlineTtsStore(dir);
    await store.load();
    aiStore = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
    await aiStore.load();
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 内容较高（多组卡片）：拉高视口避免懒加载回收（同 ai_settings 口径）。
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(2400, 3600);
    addTearDown(tester.view.reset);
  }

  /// 交替 runAsync / pump，排空 widget 内发起的真异步 IO（落盘 / 读密钥）。
  Future<void> settleReal(WidgetTester tester, {int rounds = 30}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 宿主（按钮 push 页面——保存 `pop` 回按钮页，不掏空根路由）。
  Widget buildApp() => MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => TtsSettingsPage(
                    store: store,
                    aiStore: aiStore,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

  /// 开页面并排空 initState 的真 IO（读已存密钥）。
  Future<void> openPage(WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await settleReal(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('默认 URL 模式：模板组在场、OpenAI 组缺席', (tester) async {
    tall(tester);
    await openPage(tester);

    expect(find.text('在线 TTS'), findsOneWidget);
    expect(find.byKey(const Key('tts-online-mode-url')), findsOneWidget);
    expect(find.byKey(const Key('tts-online-mode-openai')), findsOneWidget);
    expect(
      find.text('请求头（每行「名称: 值」，可选）'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('tts-online-enc-utf8')), findsOneWidget);
    expect(find.byKey(const Key('tts-online-enc-gbk')), findsOneWidget);
    // OpenAI 组 / Key 组不出现。
    expect(find.text('Base URL'), findsNothing);
    expect(find.text('API Key'), findsNothing);
    // 通用组 + 缓存组 + 引擎提示。
    expect(find.text('清理音频缓存'), findsOneWidget);
    expect(
      find.text('保存后，在阅读页「朗读设置」里把引擎切到「在线 TTS」即可生效。'),
      findsOneWidget,
    );
  });

  testWidgets('切 OpenAI 模式：组随模式显隐 + 导入入口在场', (tester) async {
    tall(tester);
    await openPage(tester);

    await tester.tap(find.byKey(const Key('tts-online-mode-openai')));
    await tester.pumpAndSettle();

    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('API Key'), findsNWidgets(2)); // 组头 + 字段标签
    expect(find.text('模型'), findsOneWidget);
    expect(
      find.text('请求头（每行「名称: 值」，可选）'),
      findsNothing,
    );
    expect(find.byKey(const Key('tts-online-import-ai')), findsOneWidget);

    // 切回模板模式 → OpenAI 组退场。
    await tester.tap(find.byKey(const Key('tts-online-mode-url')));
    await tester.pumpAndSettle();
    expect(find.text('Base URL'), findsNothing);
    expect(
      find.text('请求头（每行「名称: 值」，可选）'),
      findsOneWidget,
    );
  });

  testWidgets('无 {text} 保存 → 中文校验弹窗（TTS-07 配置闸）', (tester) async {
    tall(tester);
    await openPage(tester);

    await tester.enterText(find.byType(TextField).at(0), 'https://a.com/tts');
    await tester.tap(find.text('保存'));
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(find.text('无法保存'), findsOneWidget);
    expect(
      find.text('URL 模板需包含 {text} 占位符'),
      findsOneWidget,
    );
    // 未落盘。
    expect(store.value.urlTemplate, '');
  });

  testWidgets('合法填写保存 → 落盘并返回', (tester) async {
    tall(tester);
    await openPage(tester);

    // 顺序：URL 模板 / 请求头 / 超时。
    await tester.enterText(
      find.byType(TextField).at(0),
      'https://a.com/tts?q={text}',
    );
    await tester.enterText(
      find.byType(TextField).at(1),
      'X-Token: abc123',
    );
    await tester.enterText(find.byType(TextField).at(2), '30');
    await tester.tap(find.text('保存'));
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(store.value.urlTemplate, 'https://a.com/tts?q={text}');
    expect(store.value.headers, <String, String>{'X-Token': 'abc123'});
    expect(store.value.timeoutSeconds, 30);
    // 页面返回宿主。
    expect(find.text('在线 TTS'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('API Key 不回显：已存密钥只给留空保持提示（DATA-02）', (tester) async {
    tall(tester);
    await tester.runAsync(() => store.writeApiKey('sk-stored-key'));
    await openPage(tester);

    await tester.tap(find.byKey(const Key('tts-online-mode-openai')));
    await tester.pumpAndSettle();
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('已保存密钥'), findsOneWidget);
    expect(find.text('sk-stored-key'), findsNothing);
    // 留空保存不覆盖已存密钥。
    await tester.enterText(
      find.byType(TextField).at(0),
      'https://api.example.com/v1',
    );
    await tester.tap(find.text('保存'));
    await settleReal(tester);
    await tester.pumpAndSettle();
    expect(
      await tester.runAsync(() => store.readApiKey()),
      'sk-stored-key',
    );
  });

  testWidgets('音频缓存计数与清理入口（TTS-07 ② 管理面）', (tester) async {
    tall(tester);
    await tester.runAsync(
      () => store.cache.store('k1', Uint8List.fromList(const <int>[1, 2, 3])),
    );
    await openPage(tester);
    expect(find.text('已缓存 1 段音频'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tts-online-clear-cache')));
    await settleReal(tester);
    await tester.pumpAndSettle();
    expect(find.text('已缓存 0 段音频'), findsOneWidget);
    expect(await tester.runAsync(() => store.cache.count()), 0);
  });
}
