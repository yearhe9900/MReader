// `M4-T05`：自动同步触发编排（`SYNC-06`）+ 失败可见汇总（`SYNC-07`）。
//
// 触发时机（PRD §10.4）：
//   · App 启动     → 拉取进度（**仅进度**，不拉条目与书籍）；
//   · 退出阅读页   → 上报当前书进度 + 全量备份到期判定；
//   · 退出 App     → 上报全部变更（进度 + 索引 / 书签 / 设置）+ 备份到期判定；
//   · 手动（状态页）→ [syncNow] / [backupNow] / [listBackups] + [restoreFrom]、
//                     [uploadBooks] / [downloadMissingBooks]（`SYNC-05` 手动入口）。
//
// 全量备份间隔：距上次**成功**备份 ≥ [backupInterval]（默认 1 天，PRD §B.4）
// 才触发；未到间隔直接跳过（`SYNC-06` ③「未到间隔不重复全量备份」）。间隔账
// 记在 `sync_state.json` 的 `lastBackupAt`（由 [ProgressSyncState] 持有该文件，
// 两个顶层键并列读写互不覆盖）；**失败不记账** → 下次触发立即重试。
//
// 失败可见（`SYNC-07`）：各引擎结果汇总进 [SyncRunReport.failures]（条目清单 +
// 中文可读原因），落 [lastReport] 并通知监听者——状态页据此展示并提供重试。
//
// 三条纪律：
//   · **不抛**：触发多为 fire-and-forget（启动 / 退页 / 退应用都不 await），
//     异常一律收编进报告；唯一例外 [listBackups] 原样抛 [SyncException]
//     （可读中文，状态页收编展示）。
//   · **跳过不覆盖**：未配置 / 上一轮未完成的跳过报告**不落** [lastReport]
//     （不让一次空转抹掉上一轮的失败现场）。
//   · **单飞**：同步侧一个 [_running] 闸串行化（启动 / 退页 / 退出可能并发
//     竞争）；书籍批量传输用独立 [_bookRunning]（大文件传几十分钟，不得挡住
//     进度上报）。
import 'dart:io';

import '../library/book_record.dart';
import 'backup.dart';
import 'bookmark_sync.dart';
import 'book_upload.dart';
import 'entry_sync.dart';
import 'progress_sync.dart';
import 'restore.dart';
import 'settings_sync.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

/// 一条失败记录（`SYNC-07`：失败条目 + 可读原因）。
class SyncFailure {
  /// 创建失败条目（[title] = 书名 / 集合 / 动作，[reason] = 中文可读原因）。
  const SyncFailure(this.title, this.reason);

  /// 失败对象（书名 `《…》` / 集合路径 / `全量备份` 等）。
  final String title;

  /// 可读原因（`401 账号或密码错误` / `网络不可达` 等）。
  final String reason;

  @override
  String toString() => 'SyncFailure($title: $reason)';
}

/// 一轮触发的执行结果（状态页展示 + 测试断言的唯一事实源）。
class SyncRunReport {
  /// 创建一次报告；[wasSkipped] / [skipReason] 只由 [skipped] 工厂填。
  const SyncRunReport({
    required this.scope,
    required this.at,
    this.progress,
    this.entries = const <EntrySyncOutcome>[],
    this.backup,
    this.backupSkipped = false,
    this.error,
    this.wasSkipped = false,
    this.skipReason,
  });

  /// 跳过报告（未配置 / 上一轮未完成；**不落** [SyncTrigger.lastReport]）。
  static SyncRunReport skipped(String scope, String reason) => SyncRunReport(
        scope: scope,
        at: DateTime.now(),
        wasSkipped: true,
        skipReason: reason,
      );

  /// 触发范围（中文常量，状态页直接展示）。
  static const String scopeStartup = '启动时';
  static const String scopeReaderClosed = '退出阅读页时';
  static const String scopeAppExit = '退出应用时';
  static const String scopeManual = '手动';

  /// 触发范围。
  final String scope;

  /// 执行时刻。
  final DateTime at;

  /// 进度同步汇总（本范围含进度同步时非空）。
  final ProgressSyncReport? progress;

  /// 条目同步结果（索引 / 书签 / 设置；启动范围为空——仅拉进度）。
  final List<EntrySyncOutcome> entries;

  /// 本范围内的全量备份结果（未到期为 `null` 且 [backupSkipped] = true）。
  final BackupOutcome? backup;

  /// 备份因「未到间隔」跳过（`SYNC-06` ③）。
  final bool backupSkipped;

  /// 兜底异常文案（引擎之外的意外错误；正常路径为 `null`）。
  final String? error;

  /// 是否为跳过报告（未执行——不落 [SyncTrigger.lastReport]）。
  ///
  /// 字段名不用 `skipped`：与静态工厂 [skipped] 同名冲突（`Dart` 不允许
  /// 静态成员与实例成员同名）。
  final bool wasSkipped;

  /// 跳过原因（[wasSkipped] = true 时非空）。
  final String? skipReason;

  /// 是否全部成功（跳过态视为不成功——它不是一次「完成」）。
  bool get ok => !wasSkipped && failures.isEmpty;

  /// 失败条目清单（`SYNC-07`：进度逐本 + 条目逐组 + 备份 + 兜底异常）。
  List<SyncFailure> get failures => <SyncFailure>[
        if (error != null) SyncFailure('同步', error!),
        if (progress != null)
          for (final ProgressSyncOutcome outcome in progress!.failures)
            SyncFailure('《${outcome.title}》', outcome.reason ?? '未知错误'),
        for (final EntrySyncOutcome outcome in entries)
          if (outcome.failed) SyncFailure(outcome.collection, outcome.reason!),
        if (backup != null && !backup!.ok)
          SyncFailure('全量备份', backup!.reason!),
      ];

  /// 中文汇总行（状态页 / toast 直接回显）。
  String get summary {
    if (wasSkipped) {
      return skipReason ?? '未执行';
    }
    final List<String> parts = <String>[
      ?error,
      if (progress != null) progress!.summary,
      if (entries.isNotEmpty)
        '条目同步 ${entries.length} 组（失败 '
            '${entries.where((EntrySyncOutcome o) => o.failed).length} 组）',
      if (backupSkipped) '备份未到间隔',
      if (backup != null)
        backup!.ok
            ? '备份完成（${backup!.fileCount} 个文件）'
            : '备份失败：${backup!.reason}',
    ];
    return parts.isEmpty ? '无操作' : parts.join(' · ');
  }
}

/// 同步触发编排器（进程内共享，组合根注入，见 `lib/main.dart`）。
///
/// 页面用法（PRD §15.1 进程内单例 + 监听回调）：状态页 `initState` 订阅
/// [addListener]、`dispose` 退订、回调内 `setState`。
class SyncTrigger {
  /// 创建编排器（依赖由组合根注入）；[clock] 仅测试拨时。
  SyncTrigger({
    required ProgressSyncEngine progressEngine,
    required IndexSync indexEngine,
    required BookmarkSync bookmarkEngine,
    required SettingsSync settingsEngine,
    required BackupEngine backupEngine,
    required RestoreEngine restoreEngine,
    required BookUploadEngine bookUploadEngine,
    required BookUploadPrefsStore uploadPrefsStore,
    required ProgressSyncState syncState,
    required SyncConfigStore syncConfig,
    required Future<List<BookRecord>> Function() booksLoader,
    required Future<File> Function(BookRecord record) bookFileResolver,
    DateTime Function()? clock,
    Duration backupInterval = const Duration(days: 1),
  })  : _progress = progressEngine,
        _index = indexEngine,
        _bookmarks = bookmarkEngine,
        _settings = settingsEngine,
        _backup = backupEngine,
        _restore = restoreEngine,
        _bookUpload = bookUploadEngine,
        _uploadPrefs = uploadPrefsStore,
        _state = syncState,
        _configStore = syncConfig,
        _loadBooks = booksLoader,
        _bookFile = bookFileResolver,
        _clock = clock ?? DateTime.now,
        _interval = backupInterval;

  final ProgressSyncEngine _progress;
  final IndexSync _index;
  final BookmarkSync _bookmarks;
  final SettingsSync _settings;
  final BackupEngine _backup;
  final RestoreEngine _restore;
  final BookUploadEngine _bookUpload;
  final BookUploadPrefsStore _uploadPrefs;
  final ProgressSyncState _state;
  final SyncConfigStore _configStore;
  final Future<List<BookRecord>> Function() _loadBooks;
  final Future<File> Function(BookRecord record) _bookFile;
  final DateTime Function() _clock;
  final Duration _interval;

  /// 同步侧单飞闸（启动 / 退页 / 退出 App 可能并发竞争）。
  bool _running = false;

  /// 书籍批量传输闸（独立于 [_running]：大文件传输不得挡住进度上报）。
  bool _bookRunning = false;

  SyncRunReport? _lastReport;
  final List<void Function()> _listeners = <void Function()>[];

  /// 是否已完成 WebDAV 配置（状态页据此决定提示文案）。
  bool get isConfigured => _configStore.isConfigured;

  /// 同步侧是否正在执行一轮（状态页禁用按钮 / 转圈）。
  bool get isRunning => _running;

  /// 书籍批量传输是否进行中。
  bool get isBookRunning => _bookRunning;

  /// 最近一次**已执行**的报告；从未执行为 `null`（跳过报告不落此处）。
  SyncRunReport? get lastReport => _lastReport;

  /// 书籍上传开关存储（`SYNC-05` ① 的「单独开关」，状态页直接读写）。
  BookUploadPrefsStore get uploadPrefs => _uploadPrefs;

  /// 自动全量备份间隔（状态页说明文案用）。
  Duration get backupInterval => _interval;

  /// 订阅报告更新（状态页 `initState` 订阅 / `dispose` 退订）。
  void addListener(void Function() listener) => _listeners.add(listener);

  /// 退订。
  void removeListener(void Function() listener) => _listeners.remove(listener);

  // ───────────────────────────────────────────────────────────────────────────
  // 自动触发（`SYNC-06`）
  // ───────────────────────────────────────────────────────────────────────────

  /// App 启动（`SYNC-06` ①）：**仅拉取进度**——不拉条目、不拉书籍。
  ///
  /// 未配置 / 上一轮未完成 → 返回跳过报告（不落 [lastReport]）。
  Future<SyncRunReport> onAppStart() async {
    final SyncRunReport? blocked = _blocked(SyncRunReport.scopeStartup);
    if (blocked != null) {
      return blocked;
    }
    _running = true;
    try {
      final List<BookRecord> books = await _safeBooks();
      final ProgressSyncReport progress = await _progress.syncAll(books: books);
      return _finish(
        SyncRunReport(
          scope: SyncRunReport.scopeStartup,
          at: _clock(),
          progress: progress,
        ),
      );
    } catch (e) {
      return _finish(_errorReport(SyncRunReport.scopeStartup, e));
    } finally {
      _running = false;
    }
  }

  /// 退出阅读页（`SYNC-06` ②）：上报当前书进度 + 备份到期判定
  /// （PRD §B.4「退出 App / 阅读页时触发，间隔 1 天」）。
  Future<SyncRunReport> onReaderClosed(BookRecord book) async {
    final SyncRunReport? blocked = _blocked(SyncRunReport.scopeReaderClosed);
    if (blocked != null) {
      return blocked;
    }
    _running = true;
    try {
      final ProgressSyncReport progress = ProgressSyncReport(
        <ProgressSyncOutcome>[await _progress.syncBook(book)],
      );
      final BackupOutcome? backup = await _backupIfDue();
      return _finish(
        SyncRunReport(
          scope: SyncRunReport.scopeReaderClosed,
          at: _clock(),
          progress: progress,
          backup: backup,
          backupSkipped: backup == null,
        ),
      );
    } catch (e) {
      return _finish(_errorReport(SyncRunReport.scopeReaderClosed, e));
    } finally {
      _running = false;
    }
  }

  /// 退出 App（`SYNC-06` ②）：上报全部变更（进度 + 索引 / 书签 / 设置）+
  /// 备份到期判定。
  Future<SyncRunReport> onAppExit() async {
    final SyncRunReport? blocked = _blocked(SyncRunReport.scopeAppExit);
    if (blocked != null) {
      return blocked;
    }
    _running = true;
    try {
      final List<BookRecord> books = await _safeBooks();
      final ProgressSyncReport progress = await _progress.syncAll(books: books);
      final List<EntrySyncOutcome> entries = await _syncEntries(books);
      final BackupOutcome? backup = await _backupIfDue();
      return _finish(
        SyncRunReport(
          scope: SyncRunReport.scopeAppExit,
          at: _clock(),
          progress: progress,
          entries: entries,
          backup: backup,
          backupSkipped: backup == null,
        ),
      );
    } catch (e) {
      return _finish(_errorReport(SyncRunReport.scopeAppExit, e));
    } finally {
      _running = false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 手动（状态页；§10.4「立即同步 / 立即备份 / 从云端恢复」）
  // ───────────────────────────────────────────────────────────────────────────

  /// 立即同步：进度 + 条目（不含备份——「立即备份」是独立动作）。
  ///
  /// 与自动触发同一套失败汇总；跳过报告同样不落 [lastReport]。
  Future<SyncRunReport> syncNow() async {
    final SyncRunReport? blocked = _blocked(SyncRunReport.scopeManual);
    if (blocked != null) {
      return blocked;
    }
    _running = true;
    try {
      final List<BookRecord> books = await _safeBooks();
      final ProgressSyncReport progress = await _progress.syncAll(books: books);
      final List<EntrySyncOutcome> entries = await _syncEntries(books);
      return _finish(
        SyncRunReport(
          scope: SyncRunReport.scopeManual,
          at: _clock(),
          progress: progress,
          entries: entries,
        ),
      );
    } catch (e) {
      return _finish(_errorReport(SyncRunReport.scopeManual, e));
    } finally {
      _running = false;
    }
  }

  /// 立即备份（**不看间隔**）；成功记 [ProgressSyncState.markBackup] 账。
  ///
  /// 不抛：失败经 [BackupOutcome.reason] 返回（`SYNC-07`）。
  Future<BackupOutcome> backupNow() async {
    if (_running) {
      return BackupOutcome(reason: '上一轮同步尚未完成');
    }
    _running = true;
    try {
      final BackupOutcome outcome = await _backup.backupNow();
      if (outcome.ok) {
        await _state.load();
        await _state.markBackup(_clock().millisecondsSinceEpoch);
      }
      return outcome;
    } finally {
      _running = false;
    }
  }

  /// 列出云端备份（新 → 旧；空表 = 从未备份）。
  ///
  /// **唯一允许抛出的方法**：未配置时引擎原样抛 [SyncException]
  /// （可读中文），状态页收编为提示。
  Future<List<BackupEntry>> listBackups() => _backup.listBackups();

  /// 从云端恢复指定备份包（`SYNC-04` 恢复链路的编排入口）。
  ///
  /// 不抛：失败经 [RestoreOutcome.reason] 返回。
  Future<RestoreOutcome> restoreFrom(String remotePath) async {
    if (_running) {
      return const RestoreOutcome(
        restored: <String, int>{},
        skipped: 0,
        summary: '上一轮同步尚未完成',
        reason: '上一轮同步尚未完成',
      );
    }
    _running = true;
    try {
      return await _restore.restoreFromRemote(remotePath);
    } finally {
      _running = false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 书籍文件批量传输（`SYNC-05` ②；开关关 → 引擎逐本 skipped 零请求）
  // ───────────────────────────────────────────────────────────────────────────

  /// 上传本机全部书籍到远端 `books/`。
  ///
  /// [onFile] 每本开始前回调（1 起的序号 / 总数 / 书名）；[onProgress] 为
  /// 当前文件字节进度；[control] 取消当前文件后**停止后续书籍**。
  /// 单本失败不中断其余书籍（`SYNC-07` 汇总）。
  ///
  /// 并发进入返回空表（页面以 [isBookRunning] 禁用入口）。
  Future<List<BookUploadOutcome>> uploadBooks({
    void Function(int index, int total, String name)? onFile,
    void Function(int sent, int total)? onProgress,
    TransferControl? control,
  }) async {
    if (_bookRunning) {
      return const <BookUploadOutcome>[];
    }
    _bookRunning = true;
    try {
      final List<BookRecord> books = await _safeBooks();
      final List<BookUploadOutcome> outcomes = <BookUploadOutcome>[];
      int index = 0;
      for (final BookRecord book in books) {
        index++;
        onFile?.call(index, books.length, book.title);
        final BookUploadOutcome outcome = await _bookUpload.uploadBook(
          await _bookFile(book),
          control: control,
          onProgress: onProgress,
        );
        outcomes.add(outcome);
        if (outcome.action == BookTransferAction.cancelled) {
          break; // 用户取消：停止后续书籍（`SYNC-05` ③）。
        }
      }
      return outcomes;
    } finally {
      _bookRunning = false;
    }
  }

  /// 下载补齐本机**缺失**的书籍（新设备场景；已存在的文件不覆盖）。
  ///
  /// 回调口径同 [uploadBooks]。
  Future<List<BookUploadOutcome>> downloadMissingBooks({
    void Function(int index, int total, String name)? onFile,
    void Function(int sent, int total)? onProgress,
    TransferControl? control,
  }) async {
    if (_bookRunning) {
      return const <BookUploadOutcome>[];
    }
    _bookRunning = true;
    try {
      final List<BookRecord> books = await _safeBooks();
      // 先算缺失清单（onFile 的 total = 缺失数，而非全库数）。
      final List<(BookRecord, File)> missing = <(BookRecord, File)>[];
      for (final BookRecord book in books) {
        final File file = await _bookFile(book);
        if (!await file.exists()) {
          missing.add((book, file));
        }
      }
      final List<BookUploadOutcome> outcomes = <BookUploadOutcome>[];
      int index = 0;
      for (final (BookRecord book, File file) in missing) {
        index++;
        onFile?.call(index, missing.length, book.title);
        final BookUploadOutcome outcome = await _bookUpload.downloadBook(
          book.filePath,
          file,
          control: control,
          onProgress: onProgress,
        );
        outcomes.add(outcome);
        if (outcome.action == BookTransferAction.cancelled) {
          break;
        }
      }
      return outcomes;
    } finally {
      _bookRunning = false;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 内部
  // ───────────────────────────────────────────────────────────────────────────

  /// 自动触发闸：未配置 / 上一轮未完成 → 跳过报告（不落盘、不通知）。
  SyncRunReport? _blocked(String scope) {
    if (!_configStore.isConfigured) {
      return SyncRunReport.skipped(scope, '尚未配置 WebDAV 同步');
    }
    if (_running) {
      return SyncRunReport.skipped(scope, '上一轮同步尚未完成');
    }
    return null;
  }

  /// 落报告 + 通知监听者。
  SyncRunReport _finish(SyncRunReport report) {
    _lastReport = report;
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    return report;
  }

  /// 兜底异常 → 报告（`SYNC-07`：不静默）。
  SyncRunReport _errorReport(String scope, Object e) => SyncRunReport(
        scope: scope,
        at: _clock(),
        error: '同步失败：$e',
      );

  /// 书列表（读取异常回退空表——索引已逐条降级，这里是额外保险）。
  Future<List<BookRecord>> _safeBooks() async {
    try {
      return await _loadBooks();
    } catch (_) {
      return <BookRecord>[];
    }
  }

  /// 条目三件套（索引 / 设置 / 书签；启动范围**不**调用——仅拉进度）。
  Future<List<EntrySyncOutcome>> _syncEntries(
    List<BookRecord> books,
  ) async {
    final EntrySyncOutcome index = await _index.sync();
    final EntrySyncOutcome settings = await _settings.sync();
    final EntrySyncReport bookmarks = await _bookmarks.syncAll(
      bookIds: <String>[for (final BookRecord b in books) b.bookId],
    );
    return <EntrySyncOutcome>[index, settings, ...bookmarks.outcomes];
  }

  /// 备份到期判定（`SYNC-06` ③）：未到期返 `null`；到期执行并记账。
  Future<BackupOutcome?> _backupIfDue() async {
    await _state.load();
    final int now = _clock().millisecondsSinceEpoch;
    final int last = _state.lastBackupAt;
    if (last > 0 && now - last < _interval.inMilliseconds) {
      return null; // 未到间隔不重复全量备份。
    }
    final BackupOutcome outcome = await _backup.backupNow();
    if (outcome.ok) {
      await _state.markBackup(now);
    }
    return outcome;
  }
}
