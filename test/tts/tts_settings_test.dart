// `TTS-04`/`TTS-05` 朗读设置值对象与持久化（M3-T08）。
//
// 验收映射：
//   · `TTS-04` 语速合法性（0~1.5、NaN 回默认）与音色字段持久化；
//   · `TTS-05` 定时档位归一（0 = 关闭 / 10~180 十分钟档）与「重启后设置
//     保留」（新 store 实例从磁盘回读一致）。
//
// 口径：契约期望值**硬编码字面量**；持久化形制与 `ShelfPrefsStore` 同款
// （`JsonStore` → `AtomicFile`），落盘回读用第二个 store 实例验证。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/tts/tts_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsSettings.clampRate（TTS-04 语速合法性）', () {
    test('越界夹紧、区间内原样、NaN/Infinity 回默认', () {
      expect(TtsSettings.clampRate(-1), 0.0);
      expect(TtsSettings.clampRate(2.0), 1.5);
      expect(TtsSettings.clampRate(0.75), 0.75);
      expect(TtsSettings.clampRate(double.nan), 0.5);
      expect(TtsSettings.clampRate(double.infinity), 0.5);
      expect(TtsSettings.clampRate(double.negativeInfinity), 0.5);
    });
  });

  group('TtsSettings.clampSleep（TTS-05 定时档位）', () {
    test('0/负数 = 关闭；正数归一到 10~180 的 10 分钟档', () {
      expect(TtsSettings.clampSleep(0), 0);
      expect(TtsSettings.clampSleep(-30), 0);
      expect(TtsSettings.clampSleep(7), 10);
      expect(TtsSettings.clampSleep(15), 10);
      expect(TtsSettings.clampSleep(25), 20);
      expect(TtsSettings.clampSleep(100), 100);
      expect(TtsSettings.clampSleep(179), 170);
      expect(TtsSettings.clampSleep(180), 180);
      expect(TtsSettings.clampSleep(9999), 180);
    });
  });

  group('序列化', () {
    test('toJson 省略默认键（文件最小形态）', () {
      expect(const TtsSettings().toJson(), <String, Object?>{});
      expect(
        const TtsSettings(rate: 0.8, sleepMinutes: 30).toJson(),
        <String, Object?>{'rate': 0.8, 'sleepMinutes': 30},
      );
      expect(
        const TtsSettings(
          followSystemRate: true,
          voiceName: 'zh-fake',
          voiceLocale: 'zh-CN',
        ).toJson(),
        <String, Object?>{
          'followSystemRate': true,
          'voiceName': 'zh-fake',
          'voiceLocale': 'zh-CN',
        },
      );
    });

    test('fromJson 缺失 / 坏类型逐项回退默认，越界值归一', () {
      expect(TtsSettings.fromJson(null), const TtsSettings());
      expect(TtsSettings.fromJson('junk'), const TtsSettings());
      expect(
        TtsSettings.fromJson(<String, Object?>{
          'rate': 'oops',
          'sleepMinutes': 3.5,
          'voiceName': 42,
          'followSystemRate': 'yes',
        }),
        const TtsSettings(),
      );
      final TtsSettings parsed = TtsSettings.fromJson(<String, Object?>{
        'rate': 4.2, // 越界 → 夹到 1.5
        'followSystemRate': true,
        'voiceName': 'zh-fake',
        'voiceLocale': 'zh-CN',
        'sleepMinutes': 17, // 非档位 → 向下取 10
      });
      expect(parsed.rate, 1.5);
      expect(parsed.followSystemRate, isTrue);
      expect(parsed.voiceName, 'zh-fake');
      expect(parsed.voiceLocale, 'zh-CN');
      expect(parsed.sleepMinutes, 10);
    });

    test('roundtrip：toJson → fromJson 恒等', () {
      const TtsSettings value = TtsSettings(
        rate: 1.2,
        followSystemRate: true,
        voiceName: 'v1',
        voiceLocale: 'zh-CN',
        sleepMinutes: 60,
      );
      expect(TtsSettings.fromJson(value.toJson()), value);
    });

    test('engine（TTS-07 双引擎）：默认省略、在线落盘、未知值回系统', () {
      expect(
        const TtsSettings().toJson(),
        <String, Object?>{},
      );
      expect(
        const TtsSettings(engine: TtsEngineKind.online).toJson(),
        <String, Object?>{'engine': 'online'},
      );
      expect(
        TtsSettings.fromJson(const <String, Object?>{'engine': 'online'}).engine,
        TtsEngineKind.online,
      );
      expect(
        TtsSettings.fromJson(const <String, Object?>{'engine': 'nope'}).engine,
        TtsEngineKind.system,
      );
      expect(
        TtsSettings.fromJson(<String, Object?>{'engine': 42}).engine,
        TtsEngineKind.system,
      );
      // copyWith 保留 / 覆盖 engine。
      expect(
        const TtsSettings(engine: TtsEngineKind.online).copyWith(rate: 1.0).engine,
        TtsEngineKind.online,
      );
      expect(
        const TtsSettings().copyWith(engine: TtsEngineKind.online).engine,
        TtsEngineKind.online,
      );
      // roundtrip 含 engine。
      const TtsSettings withEngine = TtsSettings(
        engine: TtsEngineKind.online,
        rate: 0.8,
      );
      expect(TtsSettings.fromJson(withEngine.toJson()), withEngine);
    });
  });

  group('TtsSettingsStore 持久化', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_tts_store_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('空目录回默认；写入后新实例回读一致（TTS-05 ② 重启保留）', () async {
      final TtsSettingsStore store = TtsSettingsStore(tempDir);
      await store.load();
      expect(store.isLoaded, isTrue);
      expect(store.value, const TtsSettings());

      await store.setRate(0.8);
      await store.setVoice(name: 'zh-fake', locale: 'zh-CN');
      await store.setSleepMinutes(45); // 45 → 向下取 40 档
      expect(
        store.value,
        const TtsSettings(
          rate: 0.8,
          voiceName: 'zh-fake',
          voiceLocale: 'zh-CN',
          sleepMinutes: 40,
        ),
      );

      final TtsSettingsStore reopened = TtsSettingsStore(tempDir);
      await reopened.load();
      expect(
        reopened.value,
        const TtsSettings(
          rate: 0.8,
          voiceName: 'zh-fake',
          voiceLocale: 'zh-CN',
          sleepMinutes: 40,
        ),
      );
    });

    test('setVoice() 任一为空即清音色回系统默认', () async {
      final TtsSettingsStore store = TtsSettingsStore(tempDir);
      await store.load();
      await store.setVoice(name: 'zh-fake', locale: 'zh-CN');
      expect(store.value.voiceName, 'zh-fake');
      await store.setVoice();
      expect(store.value.voiceName, isNull);
      expect(store.value.voiceLocale, isNull);
    });

    test('变更通知监听者；等值写短路不通知、退订后不再收', () async {
      final TtsSettingsStore store = TtsSettingsStore(tempDir);
      await store.load();
      int notified = 0;
      void listener() => notified++;

      store.addListener(listener);
      await store.setFollowSystemRate(true);
      expect(notified, 1);
      await store.setFollowSystemRate(true); // 等值 → 短路
      expect(notified, 1);
      await store.setSleepMinutes(30);
      expect(notified, 2);

      store.removeListener(listener);
      await store.setSleepMinutes(60);
      expect(notified, 2);
    });

    test('setEngine 落盘回读；setVoice 不重置 engine（TTS-07）', () async {
      final TtsSettingsStore store = TtsSettingsStore(tempDir);
      await store.load();
      await store.setEngine(TtsEngineKind.online);
      expect(store.value.engine, TtsEngineKind.online);

      // 换音色的手构路径不得把 engine 打回 system。
      await store.setVoice(name: 'zh-fake', locale: 'zh-CN');
      expect(store.value.engine, TtsEngineKind.online);
      // 清音色同理。
      await store.setVoice();
      expect(store.value.engine, TtsEngineKind.online);

      final TtsSettingsStore reopened = TtsSettingsStore(tempDir);
      await reopened.load();
      expect(reopened.value.engine, TtsEngineKind.online);

      await reopened.setEngine(TtsEngineKind.system);
      expect(reopened.value.engine, TtsEngineKind.system);
      final TtsSettingsStore again = TtsSettingsStore(tempDir);
      await again.load();
      expect(again.value.engine, TtsEngineKind.system);
    });
  });
}
