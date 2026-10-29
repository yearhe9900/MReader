// `SYNC-03`「取最近修改」+ 防回声 + `SYNC-07`：阅读设置同步测试。
//
// 基建在 `sync_support.dart`（真 socket 纯 `test()`，非 FakeAsync 区）。
// HttpDate 仅 1 秒分辨率：「同刻」用例的本地 mtime 经 `setLastModified`
// 截到整秒后再与远端播种值比对。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/reading_prefs.dart';
import 'package:mreader/reader/reading_prefs_store.dart';
import 'package:mreader/sync/entry_sync.dart';
import 'package:mreader/sync/settings_sync.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';
import 'package:mreader/typography/reader_settings.dart';

import 'sync_support.dart';

/// 2015-10-21 07:28:00 GMT——远端文件的参考 mtime（整秒，HttpDate 口径）。
final DateTime _remoteTime = DateTime.utc(2015, 10, 21, 7, 28);

ReadingPrefs _prefs({double brightness = 0.8}) => ReadingPrefs(
      settings: ReaderSettings(fontSize: 20),
      brightness: brightness,
    );

void main() {
  late Directory tempDir;
  late TestAppPaths paths;
  late ReadingPrefsStore prefsStore;
  late SyncConfigStore configStore;
  late WebdavClient client;
  late MockDav dav;
  late String base;
  late SettingsSync engine;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_sync_');
    paths = TestAppPaths(tempDir);
    prefsStore = ReadingPrefsStore(paths);
    configStore = SyncConfigStore(
      tempDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    base = await dav.start();
    await configStore.save(SyncConfig(url: base, account: 'acc'));
    await configStore.writePassword('pw');
    engine = SettingsSync(
      client: client,
      prefsStore: prefsStore,
      configStore: configStore,
    );
  });

  tearDown(() async {
    client.close();
    await dav.stop();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('单侧缺失', () {
    test('远端缺失 + 本地有 → 首传（逐级 MKCOL settings）', () async {
      await prefsStore.save(_prefs(brightness: 0.8));

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.failed, isFalse);
      expect(outcome.remoteChanged, isTrue);
      expect(outcome.addedFromLocal, 1);
      expect(dav.calls, contains('MKCOL /mreader'));
      expect(dav.calls, contains('MKCOL /mreader/settings'));
      expect(
        dav.textOf(SettingsSync.remotePath),
        contains('"brightness":0.8'),
      );
    });

    test('远端缺失 + 本地无 → unchanged（仅 1 次 PROPFIND）', () async {
      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isFalse);
      expect(dav.calls.length, 1);
    });

    test('本地无偏好 + 远端有 → 下载保存', () async {
      dav.seed(
        SettingsSync.remotePath,
        jsonEncode(_prefs(brightness: 0.5).toJson()),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isFalse);
      expect(outcome.addedFromRemote, 1);
      expect((await prefsStore.load())!.brightness, 0.5);
    });
  });

  group('SYNC-03 取最近修改', () {
    test('远端修改更新（now+1h）→ 下载覆盖本地，不上传', () async {
      await prefsStore.save(_prefs(brightness: 0.8));
      dav.seed(
        SettingsSync.remotePath,
        jsonEncode(_prefs(brightness: 0.5).toJson()),
        DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isFalse);
      expect((await prefsStore.load())!.brightness, 0.5);
      expect(dav.calls.where((String c) => c.startsWith('PUT')), isEmpty);
    });

    test('本地修改更新（远端 2015）→ 上传覆盖远端，本地不动', () async {
      await prefsStore.save(_prefs(brightness: 0.9));
      dav.seed(
        SettingsSync.remotePath,
        jsonEncode(_prefs(brightness: 0.5).toJson()),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isTrue);
      expect((await prefsStore.load())!.brightness, 0.9);
      expect(
        dav.textOf(SettingsSync.remotePath),
        contains('"brightness":0.9'),
      );
    });

    test('完全同刻 → 远端胜（云端为准，双侧同判收敛）', () async {
      await prefsStore.save(_prefs(brightness: 0.8));
      final File file = await prefsStore.file();
      await file.setLastModified(_remoteTime); // 截到整秒，与 HttpDate 同精度
      dav.seed(
        SettingsSync.remotePath,
        jsonEncode(_prefs(brightness: 0.5).toJson()),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isFalse);
      expect(
        (await prefsStore.load())!.brightness,
        0.5,
        reason: '同刻不满足「本地严格更新」→ 远端胜',
      );
      expect(dav.calls.where((String c) => c.startsWith('PUT')), isEmpty);
    });

    test('远端时间戳缺失 → 上传本地（缺失视为最旧）', () async {
      await prefsStore.save(_prefs(brightness: 0.9));
      dav.seed(
        SettingsSync.remotePath,
        jsonEncode(_prefs(brightness: 0.5).toJson()),
        null, // PROPFIND 不带 getlastmodified
      );

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isTrue);
      expect(
        dav.textOf(SettingsSync.remotePath),
        contains('"brightness":0.9'),
      );
    });
  });

  group('防回声与失败（`SYNC-07`）', () {
    test('内容相等 → unchanged：不上传、不落盘（防回声）', () async {
      await prefsStore.save(_prefs(brightness: 0.8));
      final int mtimeBefore =
          (await (await prefsStore.file()).stat()).modified.millisecondsSinceEpoch;
      dav.seed(
        SettingsSync.remotePath,
        jsonEncode(_prefs(brightness: 0.8).toJson()),
        DateTime.now().toUtc().add(const Duration(hours: 1)), // 远端 mtime 更新
      );

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isFalse);
      expect(dav.calls.where((String c) => c.startsWith('PUT')), isEmpty);
      final int mtimeAfter =
          (await (await prefsStore.file()).stat()).modified.millisecondsSinceEpoch;
      expect(mtimeAfter, mtimeBefore, reason: '本地文件未被重写');
    });

    test('远端内容不同但非对象（JSON 数组）→ failed 损坏可读', () async {
      await prefsStore.save(_prefs(brightness: 0.8));
      dav.seed(SettingsSync.remotePath, '[1, 2, 3]', _remoteTime);

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.failed, isTrue);
      expect(outcome.reason, '远端设置文件损坏，已跳过');
      expect((await prefsStore.load())!.brightness, 0.8, reason: '本地不动');
    });

    test('远端坏 JSON → failed 损坏可读', () async {
      dav.seed(SettingsSync.remotePath, '{ 坏掉的 json', _remoteTime);

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.failed, isTrue);
      expect(outcome.reason, contains('损坏'));
    });

    test('通道 500 → failed 服务端错误，不误报「损坏」', () async {
      await prefsStore.save(_prefs(brightness: 0.8));
      dav.seed(
        SettingsSync.remotePath,
        jsonEncode(_prefs(brightness: 0.5).toJson()),
        _remoteTime,
      );
      dav.failStatus = 500;

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.failed, isTrue);
      expect(outcome.reason, contains('服务端错误（500）'));
      expect(outcome.reason, isNot(contains('损坏')));
    });

    test('未配置 → failed 可读原因', () async {
      await configStore.remove();

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.failed, isTrue);
      expect(outcome.reason, '尚未配置 WebDAV 同步');
    });

    test('配置在、密码缺 → failed 可读原因', () async {
      await configStore.remove();
      await configStore.save(SyncConfig(url: base, account: 'acc'));

      final EntrySyncOutcome outcome = await engine.sync();

      expect(outcome.failed, isTrue);
      expect(outcome.reason, '尚未保存 WebDAV 密码');
    });
  });
}
