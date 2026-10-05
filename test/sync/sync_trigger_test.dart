// `M4-T05`：自动同步触发编排测试（`SYNC-06` 四时机 + 备份 1 天间隔 +
// `SYNC-07` 失败可见 / 跳过不覆盖 / 单飞闸 + `SYNC-05` 书籍批量开关）。
//
// 口径（同 `progress_sync_test`）：纯 `test()` + 真 socket [MockDav]；
// 拨时经 `SyncTrigger` 的 `clock` 注入（间隔判定不靠真实等待）；失败用例把
// 配置指向 `http://127.0.0.1:1/`（连接拒绝，秒失败）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/book_index.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/reader/bookmark.dart';
import 'package:mreader/reader/bookmark_store.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reading_prefs.dart';
import 'package:mreader/reader/reading_prefs_store.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/stats/session_store.dart';
import 'package:mreader/stats/stats_sync.dart';
import 'package:mreader/sync/backup.dart';
import 'package:mreader/sync/book_upload.dart';
import 'package:mreader/sync/bookmark_sync.dart';
import 'package:mreader/sync/entry_sync.dart';
import 'package:mreader/sync/progress_sync.dart';
import 'package:mreader/sync/restore.dart';
import 'package:mreader/sync/settings_sync.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/sync_trigger.dart';
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

ReadingProgress _prog({int index = 3, int updatedAt = 1700000000000}) =>
    ReadingProgress(
      bookId: _bookId,
      chapterHref: 'c#$index',
      chapterIndex: index,
      chapterPos: 0.4,
      updatedAt: updatedAt,
    );

void main() {
  late Directory tempDir;
  late TestAppPaths paths;
  late ProgressStore progressStore;
  late SyncConfigStore configStore;
  late WebdavClient client;
  late MockDav dav;
  late String base;
  late ProgressSyncState state;
  late BookmarkStore bookmarkStore;
  late ReadingPrefsStore prefsStore;
  late BookUploadPrefsStore uploadPrefs;
  late StatsSyncPrefsStore statsPrefs;
  late SyncTrigger trigger;
  late DateTime now;
  late Future<List<BookRecord>> Function() loader;

  /// 远端备份包的 PUT 次数（备份间隔判定的唯一口径）。
  int backupPuts() => dav.calls
      .where((String c) => c.startsWith('PUT /mreader/backup-'))
      .length;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_trigger_');
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
    bookmarkStore = BookmarkStore(paths);
    prefsStore = ReadingPrefsStore(paths);
    uploadPrefs = BookUploadPrefsStore(tempDir);
    await uploadPrefs.load();
    statsPrefs = StatsSyncPrefsStore(tempDir);
    await statsPrefs.load();
    now = DateTime(2026, 10, 5, 12);
    loader = () async => <BookRecord>[_book];
    trigger = SyncTrigger(
      progressEngine: ProgressSyncEngine(
        client: client,
        progressStore: progressStore,
        configStore: configStore,
        state: state,
      ),
      indexEngine: IndexSync(
        client: client,
        index: BookIndex(paths),
        configStore: configStore,
      ),
      bookmarkEngine: BookmarkSync(
        client: client,
        store: bookmarkStore,
        configStore: configStore,
      ),
      settingsEngine: SettingsSync(
        client: client,
        prefsStore: prefsStore,
        configStore: configStore,
      ),
      statsEngine: StatsSync(
        client: client,
        sessionStore: SessionStore(paths),
        configStore: configStore,
        prefs: statsPrefs,
      ),
      backupEngine: BackupEngine(
        paths: paths,
        client: client,
        configStore: configStore,
      ),
      restoreEngine: RestoreEngine(
        paths: paths,
        client: client,
        configStore: configStore,
      ),
      bookUploadEngine: BookUploadEngine(
        client: client,
        prefs: uploadPrefs,
        configStore: configStore,
      ),
      uploadPrefsStore: uploadPrefs,
      statsPrefsStore: statsPrefs,
      syncState: state,
      syncConfig: configStore,
      booksLoader: () => loader(),
      bookFileResolver: (BookRecord record) async => File(
        '${tempDir.path}${Platform.pathSeparator}library'
        '${Platform.pathSeparator}${record.filePath}',
      ),
      clock: () => now,
    );
  });

  tearDown(() async {
    client.close();
    await dav.stop();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('`SYNC-06` ① App 启动：仅拉进度', () {
    test('未配置 → 跳过：零请求、不落 lastReport、不通知监听者', () async {
      await configStore.remove();
      int notified = 0;
      trigger.addListener(() => notified++);

      final SyncRunReport report = await trigger.onAppStart();

      expect(report.wasSkipped, isTrue);
      expect(report.skipReason, '尚未配置 WebDAV 同步');
      expect(trigger.lastReport, isNull, reason: '跳过报告不落 lastReport');
      expect(notified, 0, reason: '跳过不通知（不让空转抹掉失败现场）');
      expect(dav.calls, isEmpty, reason: '未配置 = 零网络请求');
    });

    test('已配置 → 上报进度；不拉条目（远端 library/index.json 不被创建）',
        () async {
      await progressStore.save(_prog(index: 6));
      int notified = 0;
      trigger.addListener(() => notified++);

      final SyncRunReport report = await trigger.onAppStart();

      expect(report.wasSkipped, isFalse);
      expect(report.scope, SyncRunReport.scopeStartup);
      expect(report.ok, isTrue);
      expect(report.entries, isEmpty, reason: '启动范围不含条目（PRD §10.4）');
      expect(backupPuts(), 0, reason: '启动不做备份');
      expect(
        dav.calls.where((String c) => c.contains('library')),
        isEmpty,
        reason: '启动不触碰索引',
      );
      expect(
        dav.calls.where((String c) => c.startsWith('PUT /mreader/bookProgress')),
        hasLength(1),
        reason: '本地进度推上远端',
      );
      expect(notified, 1);
      expect(trigger.lastReport, same(report));
    });
  });

  group('`SYNC-06` ② 退出阅读页：单本进度 + 备份到期', () {
    test('首次退出：上报本书进度 + 立即首备份（从未备份 = 立即到期）', () async {
      await progressStore.save(_prog(index: 7));

      final SyncRunReport report = await trigger.onReaderClosed(_book);

      expect(report.scope, SyncRunReport.scopeReaderClosed);
      expect(report.ok, isTrue);
      expect(report.progress!.outcomes, hasLength(1), reason: '只报本书');
      expect(
        dav.calls.where((String c) => c.startsWith('PUT /mreader/bookProgress')),
        hasLength(1),
      );
      expect(backupPuts(), 1, reason: 'lastBackupAt = 0 → 首备份立即执行');
      expect(state.lastBackupAt, now.millisecondsSinceEpoch);
      expect(report.backup!.ok, isTrue);
      expect(report.backupSkipped, isFalse);
    });

    test('`SYNC-06` ③ 间隔 1 天：期内重复退出不再备份，拨钟 +25h 后重新到期',
        () async {
      await progressStore.save(_prog(index: 7));
      await trigger.onReaderClosed(_book);
      expect(backupPuts(), 1);

      // 同一时刻再退出（备份未到间隔）。
      final SyncRunReport second = await trigger.onReaderClosed(_book);
      expect(second.backupSkipped, isTrue, reason: '期内不重复全量备份');
      expect(second.backup, isNull);
      expect(backupPuts(), 1, reason: '备份 PUT 计数不变');
      expect(second.summary, contains('备份未到间隔'));

      // 拨过间隔（默认 1 天）→ 重新到期。
      now = now.add(const Duration(hours: 25));
      final SyncRunReport third = await trigger.onReaderClosed(_book);
      expect(third.backupSkipped, isFalse);
      expect(backupPuts(), 2, reason: '过间隔后再备一次');
    });
  });

  group('`SYNC-06` ② 退出应用：上报全部变更', () {
    test('进度 + 索引 + 设置 + 书签三件套 + 备份全部执行', () async {
      await progressStore.save(_prog(index: 9));
      await BookIndex(paths).save(<BookRecord>[_book]);
      await prefsStore.save(ReadingPrefs(brightness: 0.6));
      await bookmarkStore.save(_bookId, <Bookmark>[
        Bookmark(
          bookId: _bookId,
          chapterHref: 'c#1',
          chapterIndex: 1,
          chapterPos: 0.2,
          chapterTitle: '第一章',
          createdAt: 1700000000000,
        ),
      ]);

      final SyncRunReport report = await trigger.onAppExit();

      expect(report.scope, SyncRunReport.scopeAppExit);
      expect(report.ok, isTrue, reason: '全部成功');
      expect(report.entries, hasLength(4), reason: '索引 + 设置 + 1 本书签 + 统计');
      expect(
        dav.calls.where((String c) => c.startsWith('PUT /mreader/bookProgress')),
        hasLength(1),
      );
      expect(
        dav.calls.where((String c) => c.startsWith('PUT /mreader/library')),
        hasLength(1),
        reason: '书架索引推上远端',
      );
      expect(
        dav.calls
            .where((String c) => c.startsWith('PUT /mreader/settings')),
        hasLength(1),
        reason: '阅读设置推上远端',
      );
      expect(
        dav.calls
            .where((String c) => c.startsWith('PUT /mreader/bookmarks')),
        hasLength(1),
        reason: '书签推上远端',
      );
      expect(backupPuts(), 1, reason: '退出应用也做备份到期判定');
    });
  });

  group('`SYNC-07` 失败可见 + 跳过不覆盖', () {
    test('通道不可达 → 失败清单可见、落 lastReport 并通知；随后未配置跳过不覆盖',
        () async {
      await progressStore.save(_prog(index: 5));
      await configStore.save(
        SyncConfig(url: 'http://127.0.0.1:1/', account: 'acc'),
      );
      await configStore.writePassword('pw');
      int notified = 0;
      trigger.addListener(() => notified++);

      final SyncRunReport failed = await trigger.onAppStart();

      expect(failed.ok, isFalse);
      expect(failed.failures, isNotEmpty, reason: '失败必须可见（不静默）');
      expect(failed.failures.first.title, contains('三体'));
      expect(failed.failures.first.reason, isNotEmpty);
      expect(trigger.lastReport, same(failed));
      expect(notified, 1);

      // 配置被删 → 跳过报告不得抹掉上一轮失败现场。
      await configStore.remove();
      final SyncRunReport skipped = await trigger.onAppStart();
      expect(skipped.wasSkipped, isTrue);
      expect(trigger.lastReport, same(failed), reason: '跳过不覆盖 lastReport');
      expect(notified, 1, reason: '跳过不再通知');
    });
  });

  group('单飞闸（启动 / 退页 / 手动并发竞争）', () {
    test('上一轮未完成 → 后续触发跳过「上一轮同步尚未完成」，完成后恢复', () async {
      final Completer<List<BookRecord>> gate = Completer<List<BookRecord>>();
      loader = () => gate.future;

      final Future<SyncRunReport> pending = trigger.onAppStart();
      // onAppStart 在首个 await（读书列表）前已置闸 → 此处确定性竞争。
      final SyncRunReport closed = await trigger.onReaderClosed(_book);
      expect(closed.wasSkipped, isTrue);
      expect(closed.skipReason, '上一轮同步尚未完成');
      final SyncRunReport manual = await trigger.syncNow();
      expect(manual.wasSkipped, isTrue);
      expect(manual.skipReason, '上一轮同步尚未完成');
      expect(trigger.lastReport, isNull, reason: '跳过不落 lastReport');

      gate.complete(<BookRecord>[]);
      final SyncRunReport done = await pending;
      expect(done.wasSkipped, isFalse);
      expect(done.scope, SyncRunReport.scopeStartup);
      expect(trigger.lastReport, same(done));
    });
  });

  group('手动操作（状态页入口，PRD §10.4）', () {
    test('syncNow 进度 + 条目三件套；backupNow 记账；listBackups / restoreFrom 可用',
        () async {
      await progressStore.save(_prog(index: 4));

      final SyncRunReport manual = await trigger.syncNow();
      expect(manual.scope, SyncRunReport.scopeManual);
      expect(manual.ok, isTrue);
      expect(manual.entries, hasLength(4), reason: '索引 + 设置 + 本书书签 + 统计');
      expect(manual.backup, isNull, reason: '「立即同步」不含备份');

      final BackupOutcome backup = await trigger.backupNow();
      expect(backup.ok, isTrue, reason: backup.reason);
      expect(state.lastBackupAt, now.millisecondsSinceEpoch);
      expect(backupPuts(), 1);

      final List<BackupEntry> list = await trigger.listBackups();
      expect(list, hasLength(1), reason: '刚备的包在远端根目录');

      final RestoreOutcome restored = await trigger.restoreFrom(list.first.path);
      expect(restored.reason, isNull, reason: restored.summary);
      expect(
        await progressStore.load(_bookId),
        isNotNull,
        reason: '备份里的进度已恢复回本地',
      );
    });

    test('上一轮同步进行中 → restoreFrom 直接返回忙因（不排队、不静默）', () async {
      final Completer<List<BookRecord>> gate = Completer<List<BookRecord>>();
      loader = () => gate.future;
      final Future<SyncRunReport> pending = trigger.onAppStart();

      final RestoreOutcome outcome = await trigger.restoreFrom('backup-x.zip');
      expect(outcome.reason, '上一轮同步尚未完成');
      expect(outcome.restored, isEmpty);

      gate.complete(<BookRecord>[]);
      await pending;
    });
  });

  group('`SYNC-05` 书籍文件批量（开关默认关）', () {
    Future<File> localBookFile() async {
      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}library'
        '${Platform.pathSeparator}${_book.filePath}',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('EPUB-BYTES');
      return file;
    }

    test('开关关 → 逐本 skipped 零请求；开启 → 上传 + 下载补齐回环', () async {
      final File file = await localBookFile();

      // 关（默认）：不产生任何 books/ 请求。
      final List<BookUploadOutcome> off = await trigger.uploadBooks();
      expect(off.single.action, BookTransferAction.skipped);
      expect(
        dav.calls.where((String c) => c.contains('/books/')),
        isEmpty,
        reason: '开关关 = 零请求（判定先于一切网络调用）',
      );

      // 开：上传成功。
      await uploadPrefs.setEnabled(true);
      final List<BookUploadOutcome> on = await trigger.uploadBooks();
      expect(on.single.action, BookTransferAction.uploaded);
      expect(
        dav.calls.where((String c) => c.startsWith('PUT /mreader/books/')),
        hasLength(1),
      );

      // 本机文件缺失 → 下载补齐（不覆盖已有，缺失才下）。
      await file.delete();
      final List<BookUploadOutcome> down = await trigger.downloadMissingBooks();
      expect(down.single.action, BookTransferAction.downloaded);
      expect(await file.exists(), isTrue, reason: '缺失的书已补齐回本地');

      // 已存在 → 不重复下载。
      final List<BookUploadOutcome> again = await trigger.downloadMissingBooks();
      expect(again, isEmpty, reason: '无缺失 = 空清单（零请求）');
    });
  });
}
