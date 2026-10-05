// `M4-T03`：`SYNC-03` 按条目合并（纯函数）+ 书库索引同步（`IndexSync`）测试。
//
// 合并 / 裁决零 IO 直接断言；`IndexSync` 集成走 `sync_support.dart` 的 MockDav
// （真 socket 纯 `test()`，非 FakeAsync 区）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_index.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/sync/entry_sync.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';

import 'sync_support.dart';

/// 纯合并测试用的最小条目（id = 身份，body = 内容指纹）。
typedef _Item = ({String id, String body});

MergeResult<_Item> _merge(List<_Item> local, List<_Item> remote) =>
    mergeById<_Item>(
      local: local,
      remote: remote,
      idOf: (_Item i) => i.id,
      encode: (_Item i) => i.body,
      resolve: byContent<_Item>((_Item i) => i.body),
    );

BookRecord _book(
  String bookId, {
  String title = '三体',
  int? lastReadAt,
  MetaOrigin titleOrigin = MetaOrigin.none,
}) =>
    BookRecord(
      bookId: bookId,
      fileName: '$bookId.epub',
      filePath: '$bookId.epub',
      title: title,
      author: '刘慈欣',
      format: 'epub',
      cover: const NoCover(),
      importedAt: 1700000000000,
      lastReadAt: lastReadAt,
      titleOrigin: titleOrigin,
    );

/// 2015-10-21 07:28:00 GMT——远端文件的参考 mtime。
final DateTime _remoteTime = DateTime.utc(2015, 10, 21, 7, 28);

void main() {
  late Directory tempDir;
  late TestAppPaths paths;
  late BookIndex bookIndex;
  late SyncConfigStore configStore;
  late WebdavClient client;
  late MockDav dav;
  late String base;
  late IndexSync sync;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_sync_');
    paths = TestAppPaths(tempDir);
    bookIndex = BookIndex(paths);
    configStore = SyncConfigStore(
      tempDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    base = await dav.start();
    await configStore.save(SyncConfig(url: base, account: 'acc'));
    await configStore.writePassword('pw');
    sync = IndexSync(
      client: client,
      index: bookIndex,
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

  group('mergeById 并集合并（纯函数）', () {
    test('双侧独有条目互相并入：本地序在前、远端独有追加，计数准确', () {
      final MergeResult<_Item> result = _merge(
        <_Item>[(id: 'a', body: 'A')],
        <_Item>[(id: 'b', body: 'B')],
      );

      expect(result.merged.map((_Item i) => i.id).toList(), <String>['a', 'b']);
      expect(result.localChanged, isTrue);
      expect(result.remoteChanged, isTrue);
      expect(result.addedFromRemote, 1);
      expect(result.addedFromLocal, 1);
    });

    test('两侧内容完全相同 → 双侧无变更（幂等，不产生回写）', () {
      final MergeResult<_Item> result = _merge(
        <_Item>[(id: 'a', body: 'A')],
        <_Item>[(id: 'a', body: 'A')],
      );

      expect(result.localChanged, isFalse);
      expect(result.remoteChanged, isFalse);
      expect(result.addedFromRemote, 0);
      expect(result.addedFromLocal, 0);
    });

    test('同 key 冲突 → 内容字典序大者胜（本侧胜则对端需回写）', () {
      final MergeResult<_Item> result = _merge(
        <_Item>[(id: 'a', body: 'A1')],
        <_Item>[(id: 'a', body: 'A2')],
      );

      expect(result.merged.single.body, 'A2');
      expect(result.localChanged, isTrue, reason: '本地需采纳 A2');
      expect(result.remoteChanged, isFalse, reason: '远端已是 A2');
    });

    test('同侧同 key 重复 → 保留首条', () {
      final MergeResult<_Item> result = _merge(
        <_Item>[
          (id: 'a', body: 'first'),
          (id: 'a', body: 'second'),
        ],
        <_Item>[],
      );

      expect(result.merged.single.body, 'first');
    });
  });

  group('byContent 对称裁决（防双侧互不相让的震荡）', () {
    test('内容不同 → resolve(l, r) 与 resolve(r, l) 同一胜者', () {
      final _Item low = (id: 'a', body: 'A1');
      final _Item high = (id: 'a', body: 'A2');
      final _Item Function(_Item, _Item) resolve =
          byContent<_Item>((_Item i) => i.body);

      expect(resolve(low, high).body, 'A2');
      expect(resolve(high, low).body, 'A2');
    });

    test('内容相同 → 返回入参之一（内容等价，无副作用）', () {
      final _Item same = (id: 'a', body: 'same');
      expect(byContent<_Item>((_Item i) => i.body)(same, same).body, 'same');
    });
  });

  group('resolveIndexConflict 三级规则（PRD §10.2）', () {
    test('① lastReadAt 新者胜，压过内容字典序', () {
      final BookRecord newer = _book('b1', title: 'A书', lastReadAt: 3000);
      final BookRecord older = _book('b1', title: 'Z书', lastReadAt: 2000);

      expect(resolveIndexConflict(newer, older).title, 'A书');
      expect(resolveIndexConflict(older, newer).title, 'A书');
    });

    test('② lastReadAt 平 → 用户编辑标记（META-09）胜，压过字典序', () {
      final BookRecord edited =
          _book('b1', title: '改过', titleOrigin: MetaOrigin.user);
      final BookRecord plain = _book('b1', title: '远胜书名');

      expect(resolveIndexConflict(edited, plain).title, '改过');
      expect(resolveIndexConflict(plain, edited).title, '改过');
    });

    test('③ 全平 → 内容 JSON 字典序大者胜，且双侧同判（对称）', () {
      final BookRecord left = _book('b1', title: '三体');
      final BookRecord right = _book('b1', title: '三体书');

      expect(resolveIndexConflict(left, right).title, '三体书');
      expect(resolveIndexConflict(right, left).title, '三体书');
    });
  });

  group('IndexSync 集成（library/index.json）', () {
    test('双侧各一本 → 并集合并、双向落盘', () async {
      await bookIndex.save(<BookRecord>[_book('book0001')]);
      dav.seed(
        IndexSync.remotePath,
        jsonEncode(<Object?>[_book('book0002', title: '异形').toJson()]),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.failed, isFalse);
      expect(outcome.collection, 'library/index');
      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isTrue);
      expect(outcome.addedFromRemote, 1);
      expect(outcome.addedFromLocal, 1);
      final List<BookRecord> local = await bookIndex.load();
      expect(
        local.map((BookRecord r) => r.bookId).toList(),
        <String>['book0001', 'book0002'],
      );
      final String? remote = dav.textOf(IndexSync.remotePath);
      expect(remote, contains('book0001'));
      expect(remote, contains('book0002'));
    });

    test('同书冲突：远端 lastReadAt 更新 → 本地被替换、不回写远端', () async {
      await bookIndex.save(<BookRecord>[_book('b1', title: '本地名')]);
      dav.seed(
        IndexSync.remotePath,
        jsonEncode(<Object?>[
          _book('b1', title: '远端名', lastReadAt: 2000).toJson(),
        ]),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isFalse);
      expect((await bookIndex.load()).single.title, '远端名');
      expect(dav.calls.where((String c) => c.startsWith('PUT')), isEmpty);
    });

    test('同书冲突：本地 lastReadAt 更新 → 推上远端', () async {
      await bookIndex.save(
        <BookRecord>[_book('b1', title: '本地名', lastReadAt: 3000)],
      );
      dav.seed(
        IndexSync.remotePath,
        jsonEncode(<Object?>[
          _book('b1', title: '远端名', lastReadAt: 2000).toJson(),
        ]),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isTrue);
      expect(dav.textOf(IndexSync.remotePath), contains('本地名'));
    });

    test('远端顶层非数组 → failed（损坏可读、本地不动）', () async {
      await bookIndex.save(<BookRecord>[_book('b1')]);
      dav.seed(IndexSync.remotePath, '{"not":"array"}', _remoteTime);

      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.failed, isTrue);
      expect(outcome.reason, contains('远端索引文件损坏'));
      expect((await bookIndex.load()).single.bookId, 'b1');
    });

    test('远端数组内单条损坏 → 跳过该条、其余照常（LIB-03 降级同款）', () async {
      await bookIndex.save(<BookRecord>[_book('book0001')]);
      dav.seed(
        IndexSync.remotePath,
        jsonEncode(<Object?>[
          _book('book0002').toJson(),
          'garbage',
          <String, Object?>{},
        ]),
        _remoteTime,
      );

      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.failed, isFalse);
      expect(outcome.addedFromRemote, 1);
      expect((await bookIndex.load()).length, 2);
    });

    test('双侧皆空 → unchanged（仅 1 次 PROPFIND，无写请求）', () async {
      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.localChanged, isFalse);
      expect(outcome.remoteChanged, isFalse);
      expect(dav.calls.length, 1);
    });

    test('远端缺失 + 本地有书 → 首传（逐级 MKCOL library）', () async {
      await bookIndex.save(<BookRecord>[_book('book0001')]);

      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.remoteChanged, isTrue);
      expect(outcome.addedFromLocal, 1);
      expect(dav.calls, contains('MKCOL /mreader'));
      expect(dav.calls, contains('MKCOL /mreader/library'));
      expect(dav.textOf(IndexSync.remotePath), contains('book0001'));
    });

    test('未配置 → failed 可读原因（`SYNC-07` 不静默）', () async {
      await configStore.remove();

      final EntrySyncOutcome outcome = await sync.sync();

      expect(outcome.failed, isTrue);
      expect(outcome.reason, '尚未配置 WebDAV 同步');
    });
  });
}
