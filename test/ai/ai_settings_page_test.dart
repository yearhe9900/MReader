// `M3-T01`：AI 设置页 widget 测试（`AI-01` 界面 / `AI-09` 开关 / `DATA-02` ③ 标注）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/ui/ai_settings_page.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  late Directory dir;
  late ProviderStore store;
  late AiClient client;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mreader_ai_page_');
    store = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
    await store.load();
    client = AiClient();
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 内容较高（多组卡片）：拉高视口避免懒加载回收（同 stats_page `_tall` 口径）。
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

  Widget buildApp() =>
      MaterialApp(home: AiSettingsPage(store: store, client: client));

  testWidgets('`AI-09`：启用 / 最保守两开关在场，默认全开', (tester) async {
    tall(tester);
    await tester.pumpWidget(buildApp());

    expect(find.text('AI 设置'), findsOneWidget);
    expect(find.text('启用 AI 功能'), findsOneWidget);
    expect(find.text('最保守模式'), findsOneWidget);
    expect(find.text('仅发送选中的文本，不携带章节或整书内容'), findsOneWidget);
    expect(store.prefs.aiEnabled, isTrue);
    expect(store.prefs.selectionOnly, isTrue);
    expect(find.byType(Switch), findsNWidgets(2));
  });

  testWidgets('点开关行切换全局开关（写入 store）', (tester) async {
    tall(tester);
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('启用 AI 功能'));
    await tester.pump();
    expect(store.prefs.aiEnabled, isFalse);

    await tester.tap(find.text('启用 AI 功能'));
    await tester.pump();
    expect(store.prefs.aiEnabled, isTrue);
  });

  testWidgets('空配置：提示文案 + 添加入口', (tester) async {
    tall(tester);
    await tester.pumpWidget(buildApp());

    expect(
      find.textContaining('尚未配置 AI 服务'),
      findsOneWidget,
    );
    expect(find.text('添加配置'), findsOneWidget);
  });

  testWidgets('`DATA-02` ③：明文降级时安全组显示明文告知', (tester) async {
    tall(tester);
    await tester.pumpWidget(buildApp());

    // FileSecureStore.isSecure 恒 false → securityNotice 必须展示。
    expect(store.vault.isSecure, isFalse);
    expect(find.text('密钥存储'), findsOneWidget);
    expect(find.textContaining('明文保存'), findsOneWidget);
  });

  testWidgets('点配置行进编辑页：标题与名称字段预填', (tester) async {
    tall(tester);
    // 真 IO（落盘 + 写密钥）必须包 runAsync —— 测试体在 FakeAsync 区。
    await tester.runAsync(() async {
      await store.saveConfig(
        AiProviderConfig(
          id: 'c1',
          name: '我的配置',
          baseUrl: 'https://api.example.com/v1',
          model: 'm1',
          useFor: const <AiUseCase>{AiUseCase.chat},
        ),
      );
      await store.vault.write('c1', 'sk-stored');
    });
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('我的配置'), findsOneWidget);
    await tester.tap(find.text('我的配置'));
    await tester.pumpAndSettle();

    expect(find.text('编辑配置'), findsOneWidget);
    expect(find.widgetWithText(TextField, '我的配置'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'https://api.example.com/v1'), findsOneWidget);
    // 编辑页 initState 读已存密钥（widget 内真 IO）→ 交替推进排空。
    await settleReal(tester);
    // 已存密钥不回显，只给「留空保持」提示（`DATA-02`：不把 key 铺在界面上）。
    expect(find.textContaining('已保存密钥'), findsOneWidget);
    expect(find.text('sk-stored'), findsNothing);
    // 用途 chips 预勾。
    expect(
      tester.widget<FilterChip>(
        find.ancestor(of: find.text('对话'), matching: find.byType(FilterChip)),
      ).selected,
      isTrue,
    );
  });

  testWidgets('新建空表单点保存 → 校验弹窗（`AI-01` ②）', (tester) async {
    tall(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加配置'));
    await tester.pumpAndSettle();
    expect(find.text('添加配置'), findsWidgets); // 顶栏标题 + 底层列表残留

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('无法保存'), findsOneWidget);
    expect(find.text('请填写配置名称'), findsOneWidget);
  });

  testWidgets('编辑页填合法值点保存 → 落盘并返回列表', (tester) async {
    tall(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加配置'));
    await tester.pumpAndSettle();

    final Iterable<TextField> fields =
        tester.widgetList<TextField>(find.byType(TextField));
    expect(fields, hasLength(8));
    // 顺序：名称 / Base URL / 模型 / Key / 超时 / tokens / 温度 / 头。
    await tester.enterText(find.byType(TextField).at(0), '新配置');
    await tester.enterText(find.byType(TextField).at(1), 'https://api.deepseek.com/v1');
    await tester.enterText(find.byType(TextField).at(2), 'deepseek-chat');
    await tester.enterText(find.byType(TextField).at(3), 'sk-new');

    await tester.tap(find.text('保存'));
    // _save 内落盘 + 写密钥是 widget 内真 IO → 交替推进；IO 排空后再等 pop 转场。
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(store.configs, hasLength(1));
    expect(store.configs.first.name, '新配置');
    expect(await tester.runAsync(() => store.readApiKey(store.configs.first.id)),
        'sk-new');
    // 回到列表页（编辑页已退场）。
    expect(find.byType(AiProviderEditPage), findsNothing);
    expect(find.text('新配置'), findsOneWidget);
  });
}
