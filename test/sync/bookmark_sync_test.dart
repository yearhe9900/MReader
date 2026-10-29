// `SYNC-03` 验收①② + 幂等 + `SYNC-07` 汇总：书签同步测试。
//
// 基建在 `sync_support.dart`（真 socket 纯 `test()`，非 FakeAsync 区）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/bookmark.dart';
import 'package:mreader/reader/bookmark_store.dart';
import 'package:mreader/sync/bookmark_sync.dart';
import 'package:mreader/sync/entry_sync.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';

import 'sync_support.dart';

const String _bookId = 'book0001';

/// 2015-10-21 07:28:00 GMT——远端文件的参考 mtime。
final DateTime _remoteTime = DateTime.utc(2015, 10, 21, 7, 28);

Bookmark _bm({
  int createdAt = 1700000000000,
  int index = 1,
  String href = 'c#1',
  String title = '章一',
}) =>
    Bookmark(
      bookId: _bookId,
      chapterHref: href,
      chapterIndex: index,
      chapterPos: 0.5,
      chapterTitle: title,
      createdAt: createdAt,
    );

/// 远端书签文件内容（形状同 `BookmarkStore`：`{"bookId": …, "bookmarks": […]}`）。
String _remoteJson(List<Bookmark> bookmarks) => jsonEncode(
      <String, Object?>{
        'bookId': _bookId,
        'bookmarks': <Object?>[for (final Bookmark b in bookmarks) b.toJson()],
      },
    );

void main() {
  late Directory tempDir;
  late TestAppPaths paths;
  late BookmarkStore store;
  late SyncConfigStore configStore;
  late WebdavClient client;
  late MockDav dav;
  late String base;
  late BookmarkSync engine;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_sync_');
    paths = TestAppPaths(tempDir);
    store = BookmarkStore(paths);
    configStore = SyncConfigStore(
      tempDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    base = await dav.start();
    await configStore.save(SyncConfig(url: base, account: 'acc'));
    await configStore.writePassword('pw');
    engine = BookmarkSync(
      client: client,
      store: store,
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

  group('SYNC-03 验收', () {
    test('① 远端有书签、本地空 → 下载并入（对端加的本地可见）', () async {
      dav.seed(
        BookmarkSync.remotePathFor(_bookId),
        _remoteJson(<Bookmark>[_bm(createdAt: 1700000001000, title: '远端条')]),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.failed, isFalse);
      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isFalse, reason: '远端已是并集，无需回写');
      expect(outcome.addedFromRemote, 1);
      final List<Bookmark> local = await store.load(_bookId);
      expect(local.single.chapterTitle, '远端条');
    });

    test('② 本地加一条 + 远端加一条 → 同步后两侧皆两条', () async {
      await store.save(_bookId, <Bookmark>[_bm(createdAt: 1700000000000)]);
      dav.seed(
        BookmarkSync.remotePathFor(_bookId),
        _remoteJson(<Bookmark>[_bm(createdAt: 1700000001000)]),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isTrue);
      expect(outcome.addedFromRemote, 1);
      expect(outcome.addedFromLocal, 1);
      final List<Bookmark> local = await store.load(_bookId);
      expect(
        local.map((Bookmark b) => b.createdAt).toList(),
        <int>[1700000000000, 1700000001000],
        reason: '按 createdAt 升序落盘',
      );
      final String? remote = dav.textOf(BookmarkSync.remotePathFor(_bookId));
      expect(remote, contains('"createdAt":1700000000000'));
      expect(remote, contains('"createdAt":1700000001000'));
    });

    test('二次同步幂等 → unchanged（不落盘、不上传、仅 2 次请求）', () async {
      await store.save(_bookId, <Bookmark>[_bm(createdAt: 1700000000000)]);
      dav.seed(
        BookmarkSync.remotePathFor(_bookId),
        _remoteJson(<Bookmark>[_bm(createdAt: 1700000000000)]),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isFalse);
      expect(dav.calls.where((String c) => c.startsWith('PUT')), isEmpty);
      expect(dav.calls.length, 2, reason: 'PROPFIND + GET，无写请求');
    });
  });

  group('单侧缺失', () {
    test('远端缺失 + 本地有 → 首传（逐级 MKCOL bookmarks）', () async {
      await store.save(_bookId, <Bookmark>[_bm(createdAt: 1700000000000)]);

      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.remoteChanged, isTrue);
      expect(outcome.addedFromLocal, 1);
      expect(dav.calls, contains('MKCOL /mreader'));
      expect(dav.calls, contains('MKCOL /mreader/bookmarks'));
      expect(
        dav.textOf(BookmarkSync.remotePathFor(_bookId)),
        contains('"createdAt":1700000000000'),
      );
    });

    test('远端缺失 + 本地无 → unchanged（仅 1 次 PROPFIND）', () async {
      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isFalse);
      expect(dav.calls.length, 1);
    });
  });

  group('失败与汇总（`SYNC-07`）', () {
    test('远端文件损坏 → failed 可读原因，本地不动', () async {
      await store.save(_bookId, <Bookmark>[_bm(createdAt: 1700000000000)]);
      dav.seed(BookmarkSync.remotePathFor(_bookId), '{ 坏掉的 json', _remoteTime);

      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.failed, isTrue);
      expect(outcome.reason, contains('损坏'));
      expect((await store.load(_bookId)).length, 1, reason: '本地保持原样');
    });

    test('远端文件属于另一本书（bookId 串档）→ failed，不并入', () async {
      await store.save(_bookId, <Bookmark>[_bm(createdAt: 1700000000000)]);
      final String foreign = jsonEncode(
        <String, Object?>{
          'bookId': 'other9999',
          'bookmarks': <Object?>[_bm(createdAt: 1700000001000).toJson()],
        },
      );
      dav.seed(BookmarkSync.remotePathFor(_bookId), foreign, _remoteTime);

      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.failed, isTrue);
      expect(outcome.reason, contains('损坏'));
      expect((await store.load(_bookId)).single.createdAt, 1700000000000);
    });

    test('未配置 → failed 可读原因', () async {
      await configStore.remove();

      final EntrySyncOutcome outcome = await engine.syncBook(_bookId);

      expect(outcome.failed, isTrue);
      expect(outcome.reason, '尚未配置 WebDAV 同步');
    });

    test('syncAll：单本失败不中断整体，汇总给失败清单', () async {
      const String other = 'book0002';
      dav.seed(BookmarkSync.remotePathFor(other), 'garbage', _remoteTime);

      final EntrySyncReport report = await engine.syncAll(
        bookIds: <String>[_bookId, other],
      );

      expect(report.outcomes.length, 2);
      expect(report.ok, isFalse);
      expect(report.failures.single.collection, 'bookmarks/$other');
      expect(report.summary, contains('失败 1 项'));
    });

    test('syncAll：全部成功 → ok 且失败清单为空', () async {
      final EntrySyncReport report = await engine.syncAll(
        bookIds: <String>[_bookId],
      );

      expect(report.ok, isTrue);
      expect(report.failures, isEmpty);
      expect(report.summary, contains('失败 0 项'));
    });
  });
}
