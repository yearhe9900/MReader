// `M3-T01`：ProviderStore 持久化 / 用途路由 / 密钥联动 / 全局开关测试。
//
// 核心断言 `DATA-02` ①：**配置落盘文件里搜不到密钥**（密钥只在 credentials.json）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/provider_config.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/platform/secure_store_io.dart';

AiProviderConfig _config(String id, {Set<AiUseCase> useFor = const <AiUseCase>{}}) {
  return AiProviderConfig(
    id: id,
    name: '配置$id',
    baseUrl: 'https://api.example.com/v1',
    model: 'model-$id',
    useFor: useFor,
  );
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mreader_ai_store_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  ProviderStore newStore() =>
      ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));

  test('save → 新实例 load → 配置与开关保真', () async {
    final ProviderStore store = newStore();
    await store.load();
    await store.saveConfig(
      _config('c1', useFor: const <AiUseCase>{AiUseCase.chat}),
    );
    await store.setAiEnabled(false);
    await store.setSelectionOnly(false);

    final ProviderStore reloaded = newStore();
    await reloaded.load();
    expect(reloaded.configs, hasLength(1));
    expect(reloaded.configs.first.id, 'c1');
    expect(reloaded.configs.first.useFor, <AiUseCase>{AiUseCase.chat});
    expect(reloaded.prefs.aiEnabled, isFalse);
    expect(reloaded.prefs.selectionOnly, isFalse);
  });

  test('`DATA-02` ①：密钥不进配置 JSON（ai_providers.json 搜不到 key）', () async {
    final ProviderStore store = newStore();
    await store.load();
    await store.saveConfig(_config('c1'));
    await store.vault.write('c1', 'sk-super-secret-42');

    final File cfg = File('${dir.path}${Platform.pathSeparator}ai_providers.json');
    expect(cfg.existsSync(), isTrue);
    expect(cfg.readAsStringSync(), isNot(contains('sk-super-secret-42')));

    // 密钥确实在安全存储文件里（明文降级实现，`DATA-02` ③ 已标注）。
    final File cred = File('${dir.path}${Platform.pathSeparator}credentials.json');
    expect(cred.readAsStringSync(), contains('sk-super-secret-42'));
    // 且按 id 挂靠可读回。
    expect(await store.readApiKey('c1'), 'sk-super-secret-42');
  });

  test('configFor：按用途路由到声明了该用途的第一套', () async {
    final ProviderStore store = newStore();
    await store.load();
    await store.saveConfig(
      _config('chat1', useFor: const <AiUseCase>{AiUseCase.chat}),
    );
    await store.saveConfig(
      _config('tr1', useFor: const <AiUseCase>{AiUseCase.translate}),
    );
    expect(store.configFor(AiUseCase.chat)?.id, 'chat1');
    expect(store.configFor(AiUseCase.translate)?.id, 'tr1');
    expect(store.configFor(AiUseCase.summarize), isNull);
  });

  test('removeConfig：连带删除密钥（不留孤儿 key）', () async {
    final ProviderStore store = newStore();
    await store.load();
    await store.saveConfig(_config('c1'));
    await store.vault.write('c1', 'sk-x');
    expect(await store.vault.read('c1'), 'sk-x');

    await store.removeConfig('c1');
    expect(store.configs, isEmpty);
    expect(await store.vault.read('c1'), isNull);
    final File cred = File('${dir.path}${Platform.pathSeparator}credentials.json');
    expect(cred.readAsStringSync(), isNot(contains('sk-x')));
  });

  test('坏配置条目跳过、其余照常读出', () async {
    final File cfg = File('${dir.path}${Platform.pathSeparator}ai_providers.json');
    cfg.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'configs': <Object?>[
          <String, Object?>{'id': 'ok', 'name': 'n', 'baseUrl': 'u', 'model': 'm'},
          'garbage',
          <String, Object?>{'id': 'broken'},
        ],
        'aiEnabled': true,
        'selectionOnly': true,
      }),
    );
    final ProviderStore store = newStore();
    await store.load();
    expect(store.configs, hasLength(1));
    expect(store.configs.first.id, 'ok');
  });

  test('未配置文件 → 默认值（开关均开：可用 + 最保守）', () async {
    final ProviderStore store = newStore();
    await store.load();
    expect(store.prefs.aiEnabled, isTrue);
    expect(store.prefs.selectionOnly, isTrue);
    expect(store.configs, isEmpty);
  });

  test('开关写入触发监听者', () async {
    final ProviderStore store = newStore();
    await store.load();
    int fired = 0;
    store.addListener(() => fired++);
    await store.setAiEnabled(false);
    expect(fired, 1);
    await store.setAiEnabled(false); // 同值不触发
    expect(fired, 1);
    store.removeListener(() {});
    await store.setSelectionOnly(false);
    expect(fired, 2);
  });

  test('AiKeyVault：空串写入 = 删除；前缀隔离', () async {
    final ProviderStore store = newStore();
    await store.load();
    await store.vault.write('c1', 'sk-a');
    expect(await store.vault.read('c1'), 'sk-a');
    await store.vault.write('c1', '');
    expect(await store.vault.read('c1'), isNull);
    expect(AiKeyVault.keyNameFor('c1'), 'ai.key.c1');
  });
}
