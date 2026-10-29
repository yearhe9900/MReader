// `TTS-07` 在线 TTS 配置值对象 / 持久化 / 音频缓存。
//
// 覆盖：配置 toJson 最小形态 / fromJson 容错 / validate 中文报错（配置页弹窗
// 文案）；持久化写盘 → 新实例回读一致；`DATA-02`：API Key **不进配置 JSON 原文**
// （走 AiKeyVault 安全存储）；音频缓存 store/find/count/clear + 覆盖写（② 存储层）。
// 口径：契约期望值**硬编码字面量**。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/tts/audio_cache.dart';
import 'package:mreader/tts/online_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OnlineTtsConfig 值对象', () {
    test('toJson 省略默认键（文件最小形态）', () {
      expect(const OnlineTtsConfig().toJson(), <String, Object?>{});
      expect(
        const OnlineTtsConfig(
          urlTemplate: 'https://a.com/tts?q={text}',
          headers: <String, String>{'X-A': '1'},
          textEncoding: OnlineTtsEncoding.gbk,
          timeoutSeconds: 30,
        ).toJson(),
        <String, Object?>{
          'urlTemplate': 'https://a.com/tts?q={text}',
          'headers': <String, String>{'X-A': '1'},
          'textEncoding': 'gbk',
          'timeoutSeconds': 30,
        },
      );
      expect(
        const OnlineTtsConfig(
          mode: OnlineTtsMode.openaiSpeech,
          baseUrl: 'https://api.openai.com/v1',
          model: 'tts-1-hd',
          voice: 'nova',
          audioFormat: 'wav',
        ).toJson(),
        <String, Object?>{
          'mode': 'openaiSpeech',
          'baseUrl': 'https://api.openai.com/v1',
          'model': 'tts-1-hd',
          'voice': 'nova',
          'audioFormat': 'wav',
        },
      );
    });

    test('fromJson 缺失 / 坏类型逐项回退默认', () {
      expect(OnlineTtsConfig.fromJson(null), const OnlineTtsConfig());
      expect(OnlineTtsConfig.fromJson('junk'), const OnlineTtsConfig());
      expect(
        OnlineTtsConfig.fromJson(<String, Object?>{
          'mode': 'nope',
          'urlTemplate': 42,
          'headers': <String, Object?>{'a': 1},
          'textEncoding': 'nope',
          'timeoutSeconds': 'soon',
          'model': '',
        }),
        const OnlineTtsConfig(),
      );
      final OnlineTtsConfig parsed = OnlineTtsConfig.fromJson(<String, Object?>{
        'mode': 'openaiSpeech',
        'urlTemplate': 'https://a.com/tts?q={text}',
        'headers': <String, Object?>{'X-A': 'v'},
        'textEncoding': 'gbk',
        'baseUrl': 'https://api.example.com/v1',
        'timeoutSeconds': 0, // 非正数 → 回默认 60
      });
      expect(parsed.mode, OnlineTtsMode.openaiSpeech);
      expect(parsed.headers, <String, String>{'X-A': 'v'});
      expect(parsed.textEncoding, OnlineTtsEncoding.gbk);
      expect(parsed.timeoutSeconds, 60);
    });

    test('roundtrip：toJson → fromJson 恒等', () {
      const OnlineTtsConfig value = OnlineTtsConfig(
        mode: OnlineTtsMode.urlTemplate,
        urlTemplate: 'https://a.com/tts?q={text}',
        headers: <String, String>{'X-A': '1', 'X-B': '2'},
        textEncoding: OnlineTtsEncoding.gbk,
        baseUrl: 'https://api.example.com/v1',
        model: 'm1',
        voice: 'v1',
        audioFormat: 'ogg',
        timeoutSeconds: 15,
      );
      expect(OnlineTtsConfig.fromJson(value.toJson()), value);
    });

    test('validate：中文报错逐条（配置页弹窗文案）', () {
      expect(
        const OnlineTtsConfig().validate(),
        '请填写 URL 模板',
      );
      expect(
        const OnlineTtsConfig(urlTemplate: 'https://a.com/tts').validate(),
        'URL 模板需包含 {text} 占位符',
      );
      expect(
        const OnlineTtsConfig(urlTemplate: 'ftp://a/{text}').validate(),
        'URL 模板需为完整的 http(s) 地址（如 https://example.com/tts?q={text}）',
      );
      expect(
        const OnlineTtsConfig(
          mode: OnlineTtsMode.openaiSpeech,
        ).validate(),
        'Base URL 需为完整的 http(s) 地址（如 https://api.openai.com/v1）',
      );
      expect(
        const OnlineTtsConfig(
          mode: OnlineTtsMode.openaiSpeech,
          baseUrl: 'https://api.example.com/v1',
          model: ' ',
        ).validate(),
        '请填写模型名',
      );
      expect(
        const OnlineTtsConfig(
          mode: OnlineTtsMode.openaiSpeech,
          baseUrl: 'https://api.example.com/v1',
          voice: '',
        ).validate(),
        '请填写音色',
      );
      expect(
        const OnlineTtsConfig(
          urlTemplate: 'https://a.com/tts?q={text}',
          timeoutSeconds: 0,
        ).validate(),
        '超时需为正整数秒',
      );
      expect(
        const OnlineTtsConfig(
          urlTemplate: 'https://a.com/tts?q={text}',
        ).validate(),
        isNull,
      );
      expect(
        const OnlineTtsConfig(
          mode: OnlineTtsMode.openaiSpeech,
          baseUrl: 'https://api.example.com/v1',
        ).validate(),
        isNull,
      );
    });
  });

  group('OnlineTtsStore 持久化与密钥', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mreader_online_store_');
    });

    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test('空目录回默认；写入后新实例回读一致', () async {
      final OnlineTtsStore store = OnlineTtsStore(dir);
      await store.load();
      expect(store.isLoaded, isTrue);
      expect(store.value, const OnlineTtsConfig());

      await store.setConfig(const OnlineTtsConfig(
        urlTemplate: 'https://a.com/tts?q={text}',
        textEncoding: OnlineTtsEncoding.gbk,
        timeoutSeconds: 20,
      ));
      expect(store.value.timeoutSeconds, 20);

      final OnlineTtsStore reopened = OnlineTtsStore(dir);
      await reopened.load();
      expect(reopened.value, store.value);

      // 等值写短路不重写（与 TtsSettingsStore 同口径）。
      int notified = 0;
      reopened.addListener(() => notified++);
      await reopened.setConfig(reopened.value);
      expect(notified, 0);
    });

    test('DATA-02：API Key 不出现在配置 JSON 原文', () async {
      final OnlineTtsStore store = OnlineTtsStore(dir);
      await store.load();
      await store.setConfig(const OnlineTtsConfig(
        mode: OnlineTtsMode.openaiSpeech,
        baseUrl: 'https://api.example.com/v1',
      ));
      await store.writeApiKey('sk-super-secret-123');

      final File jsonFile =
          File('${dir.path}${Platform.pathSeparator}online_tts.json');
      expect(jsonFile.existsSync(), isTrue);
      final String raw = await jsonFile.readAsString();
      expect(raw.contains('sk-super-secret-123'), isFalse);
      expect(raw.contains('apiKey'), isFalse);

      // 密钥本身可读写（走 AiKeyVault 安全存储）。
      expect(await store.readApiKey(), 'sk-super-secret-123');
      expect(store.keyIsSecure, isFalse); // FileSecureStore 明文降级（DATA-02 ③）
      expect(store.keySecurityNotice, isNotEmpty);

      // 空串 = 删除。
      await store.writeApiKey('');
      expect(await store.readApiKey(), isNull);
    });
  });

  group('TtsAudioCache（TTS-07 ② 存储层）', () {
    late Directory dir;
    late TtsAudioCache cache;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mreader_tts_cache_');
      cache = TtsAudioCache(Directory('${dir.path}${Platform.pathSeparator}tts_audio'));
    });

    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test('未建目录 count=0 / find 未命中', () async {
      expect(await cache.count(), 0);
      expect(await cache.find('nope'), isNull);
    });

    test('store → find 命中且字节一致；count=1', () async {
      await cache.store('k1', Uint8List.fromList(<int>[1, 2, 3]));
      final File? hit = await cache.find('k1');
      expect(hit, isNotNull);
      expect(await hit!.readAsBytes(), <int>[1, 2, 3]);
      expect(await cache.count(), 1);
      // 临时文件不计入（只数 .audio）。
      expect(
        File('${hit.path}.tmp').existsSync(),
        isFalse,
      );
    });

    test('覆盖写：同键新字节替换旧条目（Windows 先删目标）', () async {
      await cache.store('k1', Uint8List.fromList(<int>[1]));
      await cache.store('k1', Uint8List.fromList(<int>[9, 9]));
      final File? hit = await cache.find('k1');
      expect(await hit!.readAsBytes(), <int>[9, 9]);
      expect(await cache.count(), 1);
    });

    test('clear 整目录清空（清理入口语义）', () async {
      await cache.store('k1', Uint8List.fromList(<int>[1]));
      await cache.store('k2', Uint8List.fromList(<int>[2]));
      expect(await cache.count(), 2);
      await cache.clear();
      expect(await cache.count(), 0);
      expect(await cache.find('k1'), isNull);
    });
  });
}
