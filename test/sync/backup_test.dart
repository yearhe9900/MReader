// `SYNC-04` 验收 ①③ + §10.3 包内布局 + `SYNC-07`：全量备份测试。
//
// 内存 WebDAV 服务端与临时目录 / 凭据假件在 `sync_support.dart`（共用）：
// 均为纯 `test()`（无 FakeAsync 区），真实 socket 异步可正常排空。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/epub/zip_paths.dart';
import 'package:mreader/sync/backup.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';

import 'sync_support.dart';

/// 解包（合法 zip 断言 + 条目名 → 原字节）。
Map<String, List<int>> _unzip(Uint8List zip) {
  final Archive? archive = tryDecodeZip(zip);
  expect(archive, isNotNull, reason: '备份包必须是合法 zip');
  return <String, List<int>>{
    for (final ArchiveFile file in archive!)
      file.name: file.readBytes() ?? <int>[],
  };
}

/// 解包内 JSON 条目。
Object? _jsonOf(Map<String, List<int>> entries, String name) {
  final List<int>? bytes = entries[name];
  expect(bytes, isNotNull, reason: '包内应有 $name');
  return jsonDecode(utf8.decode(bytes!));
}

void main() {
  late Directory tempDir;
  late TestAppPaths paths;
  late SyncConfigStore configStore;
  late WebdavClient client;
  late MockDav dav;
  late BackupEngine engine;

  /// 写源设备本地文件（`rel` 用 `/`）。
  Future<void> writeLocal(String rel, String content) async {
    final String path = '${tempDir.path}${Platform.pathSeparator}'
        '${rel.replaceAll('/', Platform.pathSeparator)}';
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// 播种 §10.3 全套白名单数据。
  Future<void> seedAll() async {
    await writeLocal('library/index.json', '[{"bookId":"b1","title":"三体"}]');
    await writeLocal('shelf_layout.json', '{"columns":3}');
    await writeLocal('shelf_prefs.json', '{"grid":true}');
    await writeLocal(
      'settings.json',
      '{"themeMode":"dark","fontSize":20,"lineHeight":1.8}',
    );
    await writeLocal('prefs/reading_prefs.json', '{"fontSize":22}');
    await writeLocal('bookmarks/b1.json', '{"bookId":"b1","bookmarks":[]}');
    await writeLocal('progress/b1.json', '{"bookId":"b1","chapterIndex":3}');
    await writeLocal('stats/sessions-2026-09.json', '{"sessions":[]}');
    await writeLocal('stats/stats-config.json', '{"startDate":"2026-01-01"}');
    await writeLocal('vocab.json', '{"words":["abandon"]}');
    await writeLocal('tts_settings.json', '{"rate":1.0}');
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_backup_');
    paths = TestAppPaths(tempDir);
    configStore = SyncConfigStore(
      tempDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    final String base = await dav.start();
    await configStore.save(
      SyncConfig(url: base, account: 'acc', deviceName: 'MReader'),
    );
    await configStore.writePassword('pw');
    engine = BackupEngine(
      paths: paths,
      client: client,
      configStore: configStore,
      clock: () => DateTime(2026, 10, 5, 12),
    );
  });

  tearDown(() async {
    client.close();
    await dav.stop();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('包内容（`SYNC-04` ①：§10.3 约定全部文件）', () {
    test('白名单收集：§10.3 全套 + vocab / tts 均在包内', () async {
      await seedAll();
      final ({Uint8List zip, int fileCount}) built = await engine.buildZip();
      final Map<String, List<int>> entries = _unzip(built.zip);
      expect(entries.keys.toList()..sort(), <String>[
        'bookmark.json',
        'bookshelf.json',
        'meta.json',
        'note.json',
        'progress/b1.json',
        'settings.json',
        'stats/sessions-2026-09.json',
        'stats/stats-config.json',
        'tts_settings.json',
        'vocab.json',
      ]);
      expect(built.fileCount, 10);
    });

    test('bookshelf.json 三段 / settings.json 双段 / bookmark.json 按书分键', () async {
      await seedAll();
      final Map<String, List<int>> entries = _unzip((await engine.buildZip()).zip);

      final Object? shelf = _jsonOf(entries, 'bookshelf.json');
      expect(shelf, isA<Map<String, Object?>>());
      final Map<String, Object?> shelfMap = shelf! as Map<String, Object?>;
      expect(shelfMap.keys.toList()..sort(), <String>[
        'index',
        'shelfLayout',
        'shelfPrefs',
      ]);
      expect(shelfMap['index'], <Object?>[
        <String, Object?>{'bookId': 'b1', 'title': '三体'},
      ]);
      expect(shelfMap['shelfLayout'], <String, Object?>{'columns': 3});
      expect(shelfMap['shelfPrefs'], <String, Object?>{'grid': true});

      final Map<String, Object?> settings =
          _jsonOf(entries, 'settings.json')! as Map<String, Object?>;
      expect(settings.keys.toList()..sort(), <String>['app', 'reading']);
      expect(settings['app'], <String, Object?>{
        'themeMode': 'dark',
        'fontSize': 20,
        'lineHeight': 1.8,
      });
      expect(settings['reading'], <String, Object?>{'fontSize': 22});

      expect(_jsonOf(entries, 'bookmark.json'), <String, Object?>{
        'b1': <String, Object?>{'bookId': 'b1', 'bookmarks': <Object?>[]},
      });
    });

    test('meta.json 四要素：版本号 / 导出时间 / 设备名 / 包内清单', () async {
      await seedAll();
      final Map<String, List<int>> entries = _unzip((await engine.buildZip()).zip);
      final Map<String, Object?> meta =
          _jsonOf(entries, 'meta.json')! as Map<String, Object?>;
      expect(meta['schemaVersion'], 1);
      expect(meta['exportedAt'], '2026-10-05T12:00:00.000', reason: 'clock 固定注入');
      expect(meta['deviceName'], 'MReader');
      final List<String> files = (meta['files'] as List<Object?>).cast<String>();
      expect(files, <String>[
        'bookmark.json',
        'bookshelf.json',
        'note.json',
        'progress/b1.json',
        'settings.json',
        'stats/sessions-2026-09.json',
        'stats/stats-config.json',
        'tts_settings.json',
        'vocab.json',
      ]);
      expect(files.contains('meta.json'), isFalse, reason: '清单不含自身');
      // note.json 占位内容（§10.3 结构先对齐）。
      expect(utf8.decode(entries['note.json']!), '{"notes":[]}');
    });

    test('本地损坏段不进包（不传播损坏，恢复端也不覆盖该段）', () async {
      await seedAll();
      // 仅 app 段损坏 → 剔除该段，reading 段照常（段级剔除）。
      await writeLocal('settings.json', '{ 坏掉的 json');
      final Map<String, List<int>> entries = _unzip((await engine.buildZip()).zip);
      final Map<String, Object?> settings =
          _jsonOf(entries, 'settings.json')! as Map<String, Object?>;
      expect(settings.containsKey('app'), isFalse, reason: '损坏段被剔除');
      expect(settings['reading'], <String, Object?>{'fontSize': 22});
      expect(entries.containsKey('bookshelf.json'), isTrue, reason: '其余段照常');
      expect(entries.containsKey('progress/b1.json'), isTrue);

      // 双段全损坏 → 整条 settings.json 不进包。
      await writeLocal('prefs/reading_prefs.json', '{ 也坏掉');
      final Map<String, List<int>> allBad =
          _unzip((await engine.buildZip()).zip);
      expect(allBad.containsKey('settings.json'), isFalse);
      expect(allBad.containsKey('bookshelf.json'), isTrue);
      expect(allBad.containsKey('progress/b1.json'), isTrue);
    });
  });

  group('凭据红线（`SYNC-04` ③ / `DATA-02`：白名单结构性排除）', () {
    test('凭据 / 状态 / 书籍副本 / 缓存目录都不进包，包内搜不到敏感串', () async {
      await seedAll();
      await writeLocal(
        'sync_config.json',
        '{"url":"https://secret.example.com/dav/","account":"secret_account"}',
      );
      await writeLocal(
        'credentials.json',
        '{"sync.password.default":"SUPER_SECRET_PW_987"}',
      );
      await writeLocal('sync_state.json', '{"progress":{}}');
      await writeLocal('perf_prefs.json', '{"fastMode":true}');
      await writeLocal('ai_providers.json', '{"providers":[]}');
      await writeLocal('library/book0001.epub', 'FAKE_BOOK_BYTES');
      await writeLocal('structure/b1.json', '{}');
      await writeLocal('covers/b1.jpg', 'fake-cover');

      final Map<String, List<int>> entries = _unzip((await engine.buildZip()).zip);
      for (final String banned in <String>[
        'sync_config.json',
        'credentials.json',
        'sync_state.json',
        'perf_prefs.json',
        'ai_providers.json',
        'library/book0001.epub',
        'structure/b1.json',
        'covers/b1.jpg',
      ]) {
        expect(entries.containsKey(banned), isFalse, reason: '白名单外：$banned');
      }
      // 解压后逐条目拼接搜敏感串（压缩字节搜不到原串，解压后才算数）。
      final String all = entries.values
          .map((List<int> bytes) => utf8.decode(bytes, allowMalformed: true))
          .join('\n');
      expect(all.contains('secret.example.com'), isFalse, reason: 'WebDAV 地址');
      expect(all.contains('secret_account'), isFalse, reason: 'WebDAV 账号');
      expect(all.contains('SUPER_SECRET_PW_987'), isFalse, reason: 'WebDAV 密码');
      expect(all.contains('127.0.0.1'), isFalse, reason: '真实连接配置文件');
      expect(all.contains('FAKE_BOOK_BYTES'), isFalse, reason: '书籍文件本体');
    });
  });

  group('aiCache 可选（§10.1：体积大，默认关）', () {
    test('默认不进包；includeAiCache 才进，且仍过白名单', () async {
      await seedAll();
      await writeLocal('aiCache/summary.json', '{"s":1}');
      await writeLocal('aiCache/rag_b1.json', '{"r":1}');
      await writeLocal('aiCache/other.json', '{"o":1}');

      final Map<String, List<int>> off = _unzip((await engine.buildZip()).zip);
      expect(off.keys.where((String n) => n.startsWith('aiCache/')), isEmpty);

      final Map<String, List<int>> on =
          _unzip((await engine.buildZip(includeAiCache: true)).zip);
      expect(
        on.keys.where((String n) => n.startsWith('aiCache/')).toList()..sort(),
        <String>['aiCache/rag_b1.json', 'aiCache/summary.json'],
        reason: '非白名单条目（other.json）仍被排除',
      );
    });
  });

  group('backupNow（上传远端根）', () {
    test('MKCOL 根 + PUT backup-{日期}-{设备}.zip，包可解且条目数一致', () async {
      await seedAll();
      final BackupOutcome outcome = await engine.backupNow();
      expect(outcome.ok, isTrue, reason: outcome.reason);
      expect(outcome.remotePath, 'backup-2026-10-05-MReader.zip');
      expect(outcome.fileCount, 10);
      expect(outcome.zipBytes, greaterThan(0));
      expect(dav.calls.contains('MKCOL /mreader'), isTrue);
      expect(
        dav.calls.contains('PUT /mreader/backup-2026-10-05-MReader.zip'),
        isTrue,
      );
      final List<int>? uploaded =
          dav.bytesOf('backup-2026-10-05-MReader.zip');
      expect(uploaded, isNotNull);
      expect(_unzip(Uint8List.fromList(uploaded!)).length, outcome.fileCount);
    });

    test('未配置 WebDAV → failed + 可读原因（零请求）', () async {
      final SyncConfigStore freshStore = SyncConfigStore(
        tempDir,
        SyncPasswordVault(MemorySecureStore()),
      );
      // freshStore 未 load/save → config 为 null（SyncConfigStore 默认未配置）。
      final BackupEngine fresh = BackupEngine(
        paths: paths,
        client: client,
        configStore: freshStore,
      );
      final BackupOutcome outcome = await fresh.backupNow();
      expect(outcome.ok, isFalse);
      expect(outcome.reason, '尚未配置 WebDAV 同步');
      expect(dav.calls, isEmpty);
    });
  });

  group('listBackups（远端清单）', () {
    test('过滤 backup-*.zip，按 mtime 新 → 旧', () async {
      dav.seed(
        'backup-2026-01-01-MReader.zip',
        'old',
        DateTime.utc(2026, 1, 1),
      );
      dav.seed(
        'backup-2026-06-01-MReader.zip',
        'newer',
        DateTime.utc(2026, 6, 1),
      );
      dav.seed('not-a-backup.txt', 'x', DateTime.utc(2026, 7, 1));
      dav.seed('bookProgress/b1.json', '{}', DateTime.utc(2026, 8, 1));

      final List<BackupEntry> list = await engine.listBackups();
      expect(list.map((BackupEntry e) => e.path).toList(), <String>[
        'backup-2026-06-01-MReader.zip',
        'backup-2026-01-01-MReader.zip',
      ]);
      expect(list.first.lastModified, DateTime.utc(2026, 6, 1));
    });

    test('远端根不存在（404）→ 空表（从未备份）', () async {
      expect(await engine.listBackups(), isEmpty);
    });

    test('未配置 → 抛可读 SyncException（不静默成空表）', () async {
      final SyncConfigStore freshStore = SyncConfigStore(
        tempDir,
        SyncPasswordVault(MemorySecureStore()),
      );
      final BackupEngine fresh = BackupEngine(
        paths: paths,
        client: client,
        configStore: freshStore,
      );
      expect(fresh.listBackups, throwsA(isA<SyncException>()));
    });
  });
}
