// SyncConfigStore / SyncPasswordVault 测试。
//
// 覆盖：`DATA-01` 原子落盘往返、`DATA-02` ① 密码不进配置 JSON、
// remove 连带删密码、损坏回退、监听通知。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';

void main() {
  late Directory dir;
  late SyncPasswordVault vault;
  late SyncConfigStore store;

  String configPath() =>
      '${dir.path}${Platform.pathSeparator}sync_config.json';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mreader_sync_store_');
    vault = SyncPasswordVault(FileSecureStore(directory: dir));
    store = SyncConfigStore(dir, vault);
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  SyncConfig config() => SyncConfig(
        url: 'https://dav.jianguoyun.com/dav/',
        account: 'u@example.com',
        deviceName: '小米',
      );

  test('缺文件 load → 未配置（不抛）', () async {
    await store.load();
    expect(store.isConfigured, isFalse);
    expect(store.isLoaded, isTrue);
    expect(store.config, isNull);
  });

  test('save → 新实例 load 往返（`DATA-01` 原子落盘）', () async {
    await store.save(config());
    final SyncConfigStore fresh = SyncConfigStore(dir, vault);
    await fresh.load();
    expect(fresh.isConfigured, isTrue);
    expect(fresh.config!.url, 'https://dav.jianguoyun.com/dav/');
    expect(fresh.config!.account, 'u@example.com');
    expect(fresh.config!.deviceName, '小米');
    expect(fresh.config!.dir, 'mreader');
  });

  test('`DATA-02` ①：sync_config.json 不含密码，密码只经 vault', () async {
    await store.save(config());
    await store.writePassword('secret-pw-42');

    final String configJson = File(configPath()).readAsStringSync();
    expect(configJson, isNot(contains('secret-pw-42')));
    expect(configJson, isNot(contains('password')));

    // 密码可读回；明文降级必须可被 UI 感知（`DATA-02` ③）。
    expect(await store.readPassword(), 'secret-pw-42');
    expect(store.vault.isSecure, isFalse);
    expect(store.vault.securityNotice, contains('明文保存'));
  });

  test('remove：配置清空 + 密码连带删除，且幂等', () async {
    await store.save(config());
    await store.writePassword('pw');
    await store.remove();
    expect(store.isConfigured, isFalse);
    expect(await store.readPassword(), isNull);
    await store.remove(); // 第二次不抛。
    expect(store.isConfigured, isFalse);
  });

  test('密码空串视作删除（不存空凭据）', () async {
    await store.writePassword('pw');
    await store.writePassword('');
    expect(await store.readPassword(), isNull);
  });

  test('损坏 JSON → load 回退「未配置」，不抛', () async {
    File(configPath()).writeAsStringSync('{bad json');
    await store.load();
    expect(store.isConfigured, isFalse);
    expect(store.isLoaded, isTrue);
  });

  test('结构异常条目（缺 url）→ 视作未配置', () async {
    File(configPath()).writeAsStringSync('{"account":"a"}');
    await store.load();
    expect(store.isConfigured, isFalse);
  });

  test('save / remove 触发监听回调；退订后不再触发', () async {
    int fired = 0;
    void listener() => fired++;
    store.addListener(listener);
    await store.save(config());
    expect(fired, 1);
    await store.remove();
    expect(fired, 2);
    store.removeListener(listener);
    await store.save(config());
    expect(fired, 2, reason: '退订后不应再收到通知');
  });
}
