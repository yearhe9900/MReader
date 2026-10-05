// `M4-T02`：阅读进度同步引擎测试（`SYNC-02` 验收①②③ + F7 流程 + `SYNC-07` 汇总）。
//
// 内存 WebDAV 服务端与临时目录 / 凭据假件在 `sync_support.dart`（`M4-T03` 抽出
// 共用）：均为纯 `test()`（无 FakeAsync 区），真实 socket 异步可正常排空。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/sync/progress_sync.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';

import 'sync_support.dart';

const String _bookId = 'book0001';

final BookRecord _book = BookRecord(
  bookId: _bookId,
  fileName: '三体.epub',
  filePath: '$_bookId.epub',
  title: '三体',
  author: '刘慈欣',
  format: 'epub',
  cover: const NoCover(),
  importedAt: 1700000000000,
);

/// 2015-10-21 07:28:00 GMT——远端文件的参考 mtime。
final DateTime _remoteTime = DateTime.utc(2015, 10, 21, 7, 28);

ReadingProgress _prog({
  int index = 1,
  double pos = 0.0,
  int updatedAt = 1700000000000,
  bool withHint = false,
}) =>
    ReadingProgress(
      bookId: _bookId,
      chapterHref: 'c#$index',
      chapterIndex: index,
      chapterPos: pos,
      updatedAt: updatedAt,
      localHint: withHint
          ? const LocalLayoutHint(
              scrollOffset: 120,
              fontSize: 18,
              lineHeight: 1.6,
              viewportWidth: 400,
              viewportHeight: 800,
            )
          : null,
    );

String _remoteJson({
  int index = 5,
  double pos = 0.5,
  int updatedAt = 1600000000000,
  bool withHint = false,
}) =>
    jsonEncode(
      _prog(
        index: index,
        pos: pos,
        updatedAt: updatedAt,
        withHint: withHint,
      ).toJson(),
    );

void main() {
  late Directory tempDir;
  late TestAppPaths paths;
  late ProgressStore progressStore;
  late ProgressSyncState state;
  late SyncConfigStore configStore;
  late WebdavClient client;
  late MockDav dav;
  late String base;
  late ProgressSyncEngine engine;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_sync_');
    paths = TestAppPaths(tempDir);
    progressStore = ProgressStore(paths);
    state = ProgressSyncState(tempDir);
    configStore = SyncConfigStore(
      tempDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    base = await dav.start();
    await configStore.save(SyncConfig(url: base, account: 'acc'));
    await configStore.writePassword('pw');
    engine = ProgressSyncEngine(
      client: client,
      progressStore: progressStore,
      configStore: configStore,
      state: state,
    );
  });

  tearDown(() async {
    client.close();
    await dav.stop();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('远端路径（PRD §10.3：bookProgress/{书名}_{作者}.json）', () {
    test('标准书名 → 原样拼接', () {
      expect(progressRemotePath(_book), 'bookProgress/三体_刘慈欣.json');
    });

    test('书名含路径 / 非法字符 → 净化；作者空 → 未知', () {
      final BookRecord weird = BookRecord(
        bookId: 'book0002',
        fileName: 'x.txt',
        filePath: 'book0002.txt',
        title: ' a/b:c ',
        author: '',
        format: 'txt',
        cover: const NoCover(),
        importedAt: 1700000000000,
      );
      expect(progressRemotePath(weird), 'bookProgress/a_b_c_未知.json');
    });
  });

  group('SYNC-02 验收', () {
    test('① 远端更靠后 → 覆盖本地（后读的进度覆盖先读的）', () async {
      await progressStore.save(_prog(index: 3, pos: 0.2));
      dav.seed(
        progressRemotePath(_book),
        _remoteJson(index: 5, pos: 0.75),
        _remoteTime,
      );

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.downloaded);
      final ReadingProgress? local = await progressStore.load(_bookId);
      expect(local!.chapterIndex, 5, reason: '本地被远端 ch5 覆盖');
      expect(local.chapterPos, 0.75);
      expect(state.syncedAt(_bookId), greaterThan(0), reason: '同步时间已更新');
    });

    test('② 本地更靠后 → 不被远端回退，且推上远端', () async {
      await progressStore.save(_prog(index: 8, pos: 0.1));
      dav.seed(
        progressRemotePath(_book),
        _remoteJson(index: 5, pos: 0.9),
        _remoteTime,
      );

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.uploaded);
      final ReadingProgress? local = await progressStore.load(_bookId);
      expect(local!.chapterIndex, 8, reason: '本地 ch8 不被远端 ch5 回退');
      expect(
        dav.textOf(progressRemotePath(_book)),
        contains('"chapterIndex":8'),
        reason: '本地进度已推上远端',
      );
    });

    test('③ 远端时间戳更旧 → 直接跳过（不下载、不动本地、不改同步时间）', () async {
      await progressStore.save(_prog(index: 3, updatedAt: 1600000000000));
      await state.markSynced(_bookId, 1700000000000); // 上次同步 2023 年
      dav.seed(
        progressRemotePath(_book),
        _remoteJson(index: 9), // 远端位置更靠后，但时间戳更旧 → 仍跳过
        _remoteTime, // 2015 年 < 2023 年
      );

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.skipped);
      final ReadingProgress? local = await progressStore.load(_bookId);
      expect(local!.chapterIndex, 3, reason: '本地未被覆盖');
      expect(
        dav.calls.where((String c) => c.startsWith('GET')),
        isEmpty,
        reason: '「直接跳过」= 连下载都不发',
      );
      expect(state.syncedAt(_bookId), 1700000000000, reason: '跳过不更新同步时间');
    });

    test('本地新阅读 + 远端陈旧（退出上报时机）→ 上传本地', () async {
      await progressStore.save(_prog(index: 7, updatedAt: 1700000001000));
      await state.markSynced(_bookId, 1700000000000);
      dav.seed(progressRemotePath(_book), _remoteJson(index: 5), _remoteTime);

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.uploaded);
      expect(
        dav.textOf(progressRemotePath(_book)),
        contains('"chapterIndex":7'),
        reason: '本地新进度推上远端',
      );
      expect(state.syncedAt(_bookId), greaterThan(1700000001000));
    });
  });

  group('单侧缺失', () {
    test('远端缺失 + 本地有进度 → 首传（逐级 MKCOL + 丢弃 localHint）', () async {
      await progressStore.save(_prog(index: 2, withHint: true));

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.uploaded);
      expect(dav.calls, contains('MKCOL /mreader'));
      expect(dav.calls, contains('MKCOL /mreader/bookProgress'));
      final String? remote = dav.textOf(progressRemotePath(_book));
      expect(remote, contains('"chapterIndex":2'));
      expect(
        remote,
        isNot(contains('localHint')),
        reason: '设备本地版面快照不跨设备（`RD-04`）',
      );
    });

    test('远端缺失 + 本地无进度 → unchanged（只发一次 PROPFIND）', () async {
      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.unchanged);
      expect(dav.calls.length, 1, reason: '无事可做时不产生写请求');
    });

    test('本地无进度 + 远端有 → 下载落盘，远端带来的 hint 被丢弃', () async {
      dav.seed(
        progressRemotePath(_book),
        _remoteJson(index: 4, pos: 0.6, withHint: true),
        _remoteTime,
      );

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.downloaded);
      final ReadingProgress? local = await progressStore.load(_bookId);
      expect(local!.chapterIndex, 4);
      expect(local.chapterPos, 0.6);
      expect(local.localHint, isNull, reason: '别设备的版面快照不可用');
    });
  });

  group('相同与失败（`SYNC-07`）', () {
    test('语义完全相同 → identical：不写进度、不上传，仅更新同步时间', () async {
      await progressStore.save(_prog(index: 4, pos: 0.3, updatedAt: 1700000000000));
      dav.seed(
        progressRemotePath(_book),
        _remoteJson(index: 4, pos: 0.3, updatedAt: 1600000000000),
        _remoteTime,
      );

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.identical);
      final ReadingProgress? local = await progressStore.load(_bookId);
      expect(local!.updatedAt, 1700000000000, reason: '本地未被改写');
      expect(
        dav.calls.where((String c) => c.startsWith('PUT')),
        isEmpty,
        reason: '完全相同不写入',
      );
      expect(state.syncedAt(_bookId), greaterThan(0), reason: '仅更新时间戳');
    });

    test('远端进度文件损坏 → failed，原因可读', () async {
      await progressStore.save(_prog(index: 2));
      dav.seed(progressRemotePath(_book), '{ 坏掉的 json', _remoteTime);

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.failed);
      expect(outcome.reason, contains('损坏'));
    });

    test('远端文件属于另一本书 → failed，不覆盖本地', () async {
      await progressStore.save(_prog(index: 2));
      final String foreign = jsonEncode(
        ReadingProgress(
          bookId: 'other9999',
          chapterHref: 'c#9',
          chapterIndex: 9,
          chapterPos: 0.9,
          updatedAt: 1600000000000,
        ).toJson(),
      );
      dav.seed(progressRemotePath(_book), foreign, _remoteTime);

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.failed);
      expect(outcome.reason, contains('另一本书'));
      final ReadingProgress? local = await progressStore.load(_bookId);
      expect(local!.chapterIndex, 2, reason: '本地保持原样');
    });

    test('通道 500 → failed，中文可读（`SYNC-07` 不静默）', () async {
      dav.failStatus = 500;

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.failed);
      expect(outcome.reason, contains('服务端错误（500）'));
    });

    test('未配置 → failed 可读原因', () async {
      await configStore.remove();

      final ProgressSyncOutcome outcome = await engine.syncBook(_book);

      expect(outcome.action, ProgressSyncAction.failed);
      expect(outcome.reason, '尚未配置 WebDAV 同步');
    });
  });

  group('syncAll 汇总（`SYNC-07`：失败项汇总，可重试）', () {
    test('单本失败不中断整体；报告给出动作计数与失败清单', () async {
      final BookRecord other = BookRecord(
        bookId: 'book0002',
        fileName: '异形.txt',
        filePath: 'book0002.txt',
        title: '异形',
        author: '某人',
        format: 'txt',
        cover: const NoCover(),
        importedAt: 1700000000000,
      );
      // book0001：两侧皆无 → unchanged；book0002：远端损坏 → failed。
      await progressStore.save(_prog(index: 6));
      dav.seed(progressRemotePath(other), 'garbage', _remoteTime);

      final ProgressSyncReport report = await engine.syncAll(
        books: <BookRecord>[_book, other],
      );

      expect(report.outcomes.length, 2, reason: '每本都有结果');
      expect(report.ok, isFalse);
      expect(report.count(ProgressSyncAction.failed), 1);
      expect(report.failures.single.bookId, 'book0002');
      expect(report.failures.single.title, '异形');
      expect(report.summary, contains('失败 1 本'));
    });

    test('全部成功 → ok 且失败清单为空', () async {
      final ProgressSyncReport report =
          await engine.syncAll(books: <BookRecord>[_book]);

      expect(report.ok, isTrue);
      expect(report.failures, isEmpty);
      expect(report.summary, contains('失败 0 本'));
    });
  });

  group('ProgressSyncState 持久化', () {
    test('markSynced 落盘后新实例可取回；未记录过 → 0', () async {
      await state.markSynced('b1', 1700000000123);

      final ProgressSyncState reloaded = ProgressSyncState(tempDir);
      await reloaded.load();
      expect(reloaded.syncedAt('b1'), 1700000000123);
      expect(reloaded.syncedAt('never'), 0);
    });
  });
}
