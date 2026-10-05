// `M4-T01`：SyncConfig 模型测试（`SYNC-01` 五要素 / `DATA-02` ① 结构性不含密码）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/sync/sync_config.dart';

void main() {
  group('默认与归一（`SYNC-01`：远端目录默认 `mreader`）', () {
    test('缺省 dir = mreader、deviceName = MReader', () {
      final SyncConfig c = SyncConfig(
        url: 'https://dav.jianguoyun.com/dav/',
        account: 'u@example.com',
      );
      expect(c.dir, 'mreader');
      expect(c.deviceName, 'MReader');
    });

    test('dir 去首尾斜杠、空回退默认；deviceName 空回退默认', () {
      expect(
        SyncConfig(url: 'https://x/dav/', account: 'a', dir: '/x/y/').dir,
        'x/y',
      );
      expect(
        SyncConfig(url: 'https://x/dav/', account: 'a', dir: '   ').dir,
        'mreader',
      );
      expect(
        SyncConfig(url: 'https://x/dav/', account: 'a', dir: '').dir,
        'mreader',
      );
      expect(
        SyncConfig(url: 'https://x/dav/', account: 'a', deviceName: ' ').deviceName,
        'MReader',
      );
      expect(
        SyncConfig(url: 'https://x/dav/', account: 'a', deviceName: '小米').deviceName,
        '小米',
      );
    });
  });

  group('validate（`SYNC-01` ②：面向用户的中文错误）', () {
    test('合法配置 → null', () {
      expect(
        SyncConfig(
          url: 'https://dav.jianguoyun.com/dav/',
          account: 'u@example.com',
        ).validate(),
        isNull,
      );
    });

    test('缺 url / 非 http(s) / 缺账号 / dir 含 .. → 中文错误', () {
      expect(
        SyncConfig(url: '', account: 'a').validate(),
        contains('服务器地址'),
      );
      expect(
        SyncConfig(url: 'ftp://x/y', account: 'a').validate(),
        contains('http(s)'),
      );
      expect(
        SyncConfig(url: 'https://x/y', account: '').validate(),
        contains('账号'),
      );
      expect(
        SyncConfig(url: 'https://x/y', account: 'a', dir: 'a/../b').validate(),
        contains('..'),
      );
    });
  });

  group('序列化（`DATA-02` ①：密码结构性不进 JSON）', () {
    test('toJson 键集合精确等于四要素（无 password 键位）', () {
      final SyncConfig c = SyncConfig(
        url: 'https://x/dav/',
        account: 'a',
        dir: 'mreader',
        deviceName: 'd',
      );
      expect(
        c.toJson().keys.toList(),
        <String>['url', 'account', 'dir', 'deviceName'],
      );
    });

    test('fromJson 往返一致', () {
      final SyncConfig c = SyncConfig(
        url: 'https://x/dav/',
        account: 'a@example.com',
        dir: 'sync',
        deviceName: 'PC',
      );
      final SyncConfig? back = SyncConfig.fromJson(c.toJson());
      expect(back, isNotNull);
      expect(back!.url, c.url);
      expect(back.account, c.account);
      expect(back.dir, c.dir);
      expect(back.deviceName, c.deviceName);
    });

    test('缺 dir / deviceName 字段 → 回退默认', () {
      final SyncConfig? c = SyncConfig.fromJson(<String, Object?>{
        'url': 'https://x/dav/',
        'account': 'a',
      });
      expect(c, isNotNull);
      expect(c!.dir, 'mreader');
      expect(c.deviceName, 'MReader');
    });

    test('结构异常 → null（坏条目由 store 跳过）', () {
      expect(SyncConfig.fromJson(null), isNull);
      expect(SyncConfig.fromJson('not a map'), isNull);
      expect(SyncConfig.fromJson(<String, Object?>{'account': 'a'}), isNull);
      expect(
        SyncConfig.fromJson(<String, Object?>{'url': '   ', 'account': 'a'}),
        isNull,
      );
    });
  });

  group('服务商预设（`SYNC-01`：多家服务商预设）', () {
    test('预设至少两家，且每个预设地址都通过 validate', () {
      expect(SyncConfig.presets.length, greaterThanOrEqualTo(2));
      for (final WebdavPreset preset in SyncConfig.presets) {
        expect(preset.name, isNotEmpty, reason: '预设必须有展示名');
        expect(preset.hint, isNotEmpty, reason: '预设必须有说明脚注');
        final SyncConfig c = SyncConfig(url: preset.url, account: 'a');
        expect(c.validate(), isNull, reason: '预设地址必须合法：${preset.url}');
      }
    });
  });
}
