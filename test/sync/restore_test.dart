// `SYNC-04` ② 往返验收 + 安全闸门 + 白名单分派：备份恢复测试。
//
// 双临时目录：source = 源设备（播种 + 打包），target = 全新设备（恢复落盘）。
// 均为纯 `test()`（无 FakeAsync 区），真实 socket / 文件 IO 异步可正常排空。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/sync/backup.dart';
import 'package:mreader/sync/restore.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';

import 'sync_support.dart';

/// 拼目录内相对路径（`rel` 用 `/`）。
String _join(Directory dir, String rel) =>
    '${dir.path}${Platform.pathSeparator}'
    '${rel.replaceAll('/', Platform.pathSeparator)}';

/// 用给定条目造一份裸 zip（不经 BackupEngine——测分派与闸门用）。
Uint8List _rawZip(Map<String, String> members) {
  final Archive archive = Archive();
  for (final MapEntry<String, String> e in members.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, utf8.encode(e.value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  late Directory sourceDir;
  late Directory targetDir;
  late TestAppPaths sourcePaths;
  late TestAppPaths targetPaths;
  late SyncConfigStore sourceConfig;
  late SyncConfigStore targetConfig;
  late WebdavClient client;
  late MockDav dav;
  late String base;
  late RestoreEngine restore;

  /// 写源设备本地文件（`rel` 用 `/`）。
  Future<void> writeSource(String rel, String content) async {
    final File file = File(_join(sourceDir, rel));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// 播种 §10.3 全套白名单数据（含 aiCache——往返包带全量）。
  Future<void> seedAll() async {
    await writeSource('library/index.json', '[{"bookId":"b1","title":"三体"}]');
    await writeSource('shelf_layout.json', '{"columns":3}');
    await writeSource('shelf_prefs.json', '{"grid":true}');
    await writeSource(
      'settings.json',
      '{"themeMode":"dark","fontSize":20,"lineHeight":1.8}',
    );
    await writeSource('prefs/reading_prefs.json', '{"fontSize":22}');
    await writeSource('bookmarks/b1.json', '{"bookId":"b1","bookmarks":[]}');
    await writeSource('progress/b1.json', '{"bookId":"b1","chapterIndex":3}');
    await writeSource('stats/sessions-2026-09.json', '{"sessions":[]}');
    await writeSource('stats/stats-config.json', '{"startDate":"2026-01-01"}');
    await writeSource('vocab.json', '{"words":["abandon"]}');
    await writeSource('tts_settings.json', '{"rate":1.0}');
    await writeSource('aiCache/summary.json', '{"s":1}');
    await writeSource('aiCache/rag_b1.json', '{"r":1}');
  }

  setUp(() async {
    sourceDir = Directory.systemTemp.createTempSync('mreader_src_');
    targetDir = Directory.systemTemp.createTempSync('mreader_dst_');
    sourcePaths = TestAppPaths(sourceDir);
    targetPaths = TestAppPaths(targetDir);
    sourceConfig = SyncConfigStore(
      sourceDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    targetConfig = SyncConfigStore(
      targetDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    base = await dav.start();
    // 注意：连接配置**不在 setUp 写**（`sync_config.json` 会落在 targetDir，
    // 污染闸门测试的「零写入」断言）——需要它的用例在体内保存。
    restore = RestoreEngine(
      paths: targetPaths,
      client: client,
      configStore: targetConfig,
    );
  });

  tearDown(() async {
    client.close();
    await dav.stop();
    for (final Directory dir in <Directory>[sourceDir, targetDir]) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  group('往返验收（`SYNC-04` ②：源打包 → 空目标恢复一致）', () {
    test('全量往返：重组段一致、原字节段逐字节一致、计数与汇总正确', () async {
      await seedAll();
      final BackupEngine source = BackupEngine(
        paths: sourcePaths,
        client: client,
        configStore: sourceConfig,
      );
      final ({Uint8List zip, int fileCount}) built =
          await source.buildZip(includeAiCache: true);

      final RestoreOutcome outcome = await restore.restoreFromZip(built.zip);
      expect(outcome.ok, isTrue, reason: outcome.reason);
      expect(outcome.summary, '恢复 13 项 · 跳过 0 项');
      expect(outcome.totalRestored, 13);
      expect(outcome.skipped, 0);
      expect(outcome.restored, <String, int>{
        'bookshelf': 3,
        'settings': 2,
        'bookmark': 1,
        'progress': 1,
        'stats': 2,
        'aiCache': 2,
        'vocab': 1,
        'tts': 1,
      });
      expect(outcome.meta?['schemaVersion'], 1);

      // 重组段（经 JsonStore 重编码）：语义一致。
      for (final String rel in <String>[
        'library/index.json',
        'shelf_layout.json',
        'shelf_prefs.json',
        'settings.json',
        'prefs/reading_prefs.json',
        'bookmarks/b1.json',
      ]) {
        final Object? fromSource =
            jsonDecode(await File(_join(sourceDir, rel)).readAsString());
        final Object? fromTarget =
            jsonDecode(await File(_join(targetDir, rel)).readAsString());
        expect(fromTarget, fromSource, reason: '$rel 语义一致');
      }
      // 原字节段：逐字节一致。
      for (final String rel in <String>[
        'progress/b1.json',
        'stats/sessions-2026-09.json',
        'stats/stats-config.json',
        'aiCache/summary.json',
        'aiCache/rag_b1.json',
        'vocab.json',
        'tts_settings.json',
      ]) {
        final List<int> fromSource =
            await File(_join(sourceDir, rel)).readAsBytes();
        final List<int> fromTarget =
            await File(_join(targetDir, rel)).readAsBytes();
        expect(fromTarget, fromSource, reason: '$rel 字节一致');
      }
    });

    test('restoreFromRemote：下载远端包恢复；404 → failed 可读原因', () async {
      await targetConfig.save(SyncConfig(url: base, account: 'acc'));
      await targetConfig.writePassword('pw');
      await seedAll();
      final BackupEngine source = BackupEngine(
        paths: sourcePaths,
        client: client,
        configStore: sourceConfig,
      );
      final Uint8List zip = (await source.buildZip()).zip;
      dav.seedBytes('backup-2026.zip', zip, DateTime.utc(2026, 10, 5));

      final RestoreOutcome ok = await restore.restoreFromRemote('backup-2026.zip');
      expect(ok.ok, isTrue, reason: ok.reason);
      expect(ok.totalRestored, 11, reason: '无 aiCache（默认关）');
      expect(
        File(_join(targetDir, 'progress/b1.json')).existsSync(),
        isTrue,
      );

      final RestoreOutcome missing =
          await restore.restoreFromRemote('missing.zip');
      expect(missing.ok, isFalse);
      expect(missing.reason, contains('404'));
    });

    test('restoreFromRemote：未配置 → failed + 可读原因', () async {
      final Directory freshDir =
          Directory.systemTemp.createTempSync('mreader_fresh_');
      try {
        final RestoreEngine fresh = RestoreEngine(
          paths: TestAppPaths(freshDir),
          client: client,
          configStore: SyncConfigStore(
            freshDir,
            SyncPasswordVault(MemorySecureStore()),
          ),
        );
        final RestoreOutcome outcome =
            await fresh.restoreFromRemote('backup.zip');
        expect(outcome.ok, isFalse);
        expect(outcome.reason, '尚未配置 WebDAV 同步');
      } finally {
        freshDir.deleteSync(recursive: true);
      }
    });
  });

  group('安全闸门（任何写入之前）', () {
    test('坏 zip → failed 零写入', () async {
      final RestoreOutcome outcome =
          await restore.restoreFromZip(utf8.encode('这不是 zip'));
      expect(outcome.ok, isFalse);
      expect(outcome.reason, '备份包不是有效的 zip 文件');
      expect(targetDir.listSync(), isEmpty);
    });

    test('缺 meta.json → failed 零写入', () async {
      final RestoreOutcome outcome = await restore.restoreFromZip(
        _rawZip(<String, String>{'bookshelf.json': '{"index":[]}'}),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.reason, '备份包缺少 meta.json');
      expect(targetDir.listSync(), isEmpty);
    });

    test('schemaVersion 过新 → failed 零写入（老应用不恢复新包）', () async {
      final RestoreOutcome outcome = await restore.restoreFromZip(
        _rawZip(<String, String>{
          'meta.json': '{"schemaVersion":2}',
          'bookshelf.json': '{"index":[]}',
          'progress/b1.json': '{"bookId":"b1"}',
        }),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.reason, '备份包版本 2 过新，当前应用仅支持版本 1');
      expect(targetDir.listSync(), isEmpty);
    });

    test('meta.json 损坏 → failed 零写入', () async {
      final RestoreOutcome outcome = await restore.restoreFromZip(
        _rawZip(<String, String>{'meta.json': '坏掉的'}),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.reason, '备份包 meta.json 损坏');
      expect(targetDir.listSync(), isEmpty);
    });
  });

  group('白名单分派（路径穿越 / 未知条目 / 单条损坏）', () {
    test('`../` 穿越条目 skipped，不写出界', () async {
      final RestoreOutcome outcome = await restore.restoreFromZip(
        _rawZip(<String, String>{
          'meta.json': '{"schemaVersion":1}',
          '../evil.json': '{"x":1}',
          'progress/../../evil2.json': '{"x":2}',
          'progress/ok.json': '{"bookId":"ok"}',
        }),
      );
      expect(outcome.ok, isTrue, reason: outcome.reason);
      expect(outcome.skipped, 2);
      expect(outcome.restored, <String, int>{'progress': 1});
      expect(File(_join(targetDir, 'progress/ok.json')).existsSync(), isTrue);
      // 数据根内、数据根外都不出现 evil 文件。
      expect(File(_join(targetDir, 'evil.json')).existsSync(), isFalse);
      expect(File(_join(targetDir, 'evil2.json')).existsSync(), isFalse);
      expect(
        File('${targetDir.parent.path}${Platform.pathSeparator}evil.json')
            .existsSync(),
        isFalse,
      );
      expect(
        File('${targetDir.parent.path}${Platform.pathSeparator}evil2.json')
            .existsSync(),
        isFalse,
      );
    });

    test('未知条目 skipped；note / meta 合法忽略不计数', () async {
      final RestoreOutcome outcome = await restore.restoreFromZip(
        _rawZip(<String, String>{
          'meta.json': '{"schemaVersion":1}',
          'note.json': '{"notes":[]}',
          'random/file.txt': 'x',
          'mystery.json': '{}',
        }),
      );
      expect(outcome.ok, isTrue, reason: outcome.reason);
      expect(outcome.skipped, 2, reason: 'meta/note 不计数，其余两条跳过');
      expect(outcome.totalRestored, 0);
      expect(outcome.summary, '恢复 0 项 · 跳过 2 项');
      expect(File(_join(targetDir, 'note.json')).existsSync(), isFalse);
      expect(File(_join(targetDir, 'mystery.json')).existsSync(), isFalse);
    });

    test('bookmark.json：键非法 / bookId 串档 → 单条 skipped，合法照常', () async {
      final RestoreOutcome outcome = await restore.restoreFromZip(
        _rawZip(<String, String>{
          'meta.json': '{"schemaVersion":1}',
          'bookmark.json': jsonEncode(<String, Object?>{
            'ok1': <String, Object?>{'bookId': 'ok1', 'bookmarks': <Object?>[]},
            '../evil': <String, Object?>{'bookId': 'x'},
            'bad': <String, Object?>{'bookId': 'other'},
          }),
        }),
      );
      expect(outcome.ok, isTrue, reason: outcome.reason);
      expect(outcome.restored, <String, int>{'bookmark': 1});
      expect(outcome.skipped, 2);
      expect(
        File(_join(targetDir, 'bookmarks/ok1.json')).existsSync(),
        isTrue,
      );
      expect(File(_join(targetDir, 'evil.json')).existsSync(), isFalse);
    });

    test('progress 条目：非法名 / 坏 JSON → skipped，不落盘', () async {
      final RestoreOutcome outcome = await restore.restoreFromZip(
        _rawZip(<String, String>{
          'meta.json': '{"schemaVersion":1}',
          'progress/bad name.json': '{}',
          'progress/other.json': '坏 json',
        }),
      );
      expect(outcome.ok, isTrue, reason: outcome.reason);
      expect(outcome.restored, isEmpty);
      expect(outcome.skipped, 2);
      expect(
        Directory(_join(targetDir, 'progress')).existsSync(),
        isFalse,
        reason: '零合法条目时不建目录',
      );
    });
  });
}
