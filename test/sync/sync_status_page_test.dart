// `M4-T05`/`M4-T06`：同步状态与手动操作页 widget 测试（`SYNC-07` 失败可见 +
// 重试 / §10.4 手动三行 / `STAT-08` ③ 统计开关默认开且落盘 / `SYNC-05` 开关
// 默认关且落盘 / 设置页入口接线）。
//
// 三条口径（同 `sync_settings_page_test`）：
//   ① 宿主钉「关」档（玻璃浮层在软件光栅下开销大）；
//   ② 真异步 IO（落盘 / 读密码）经 `runAsync` / `settleReal` 排空；
//   ③ **真实 socket 不进 widget 测试**（`HttpOverrides` 把 suite 内
//      `HttpClient` 全拦 400）→ 注入 [_FakeDav]（覆写通道方法，零网络），
//      真网络语义在纯 `test()` 的 `sync_trigger_test` / `webdav_client_test`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/library/book_index.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/reader/bookmark_store.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reading_prefs_store.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
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
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/settings_kit.dart';
import 'package:mreader/ui/settings_page.dart';
import 'package:mreader/ui/sync_status_page.dart';

import '../test_config.dart';
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

/// 钉「关」档宿主（同 `sync_settings_page_test`）。
Widget host(GlassQualityTier tier, Widget home) {
  return MaterialApp(
    home: GlassScopeProvider(
      config: glassTierConfigFor(tier),
      child: home,
    ),
  );
}

/// 零网络的 [WebdavClient] 替身（口径③）：远端恒「无此文件」，
/// [fail] = `true` 时一切通道调用抛「网络不可达」（制造 `SYNC-07` 失败）。
class _FakeDav extends WebdavClient {
  /// `true` = 通道不可达（用例开跑前置位）。
  bool fail = false;

  void _gate() {
    if (fail) {
      throw SyncException(SyncErrorKind.network);
    }
  }

  @override
  Future<WebdavEntry?> stat(
    SyncConfig config,
    String password,
    String under,
  ) async {
    _gate();
    return null;
  }

  @override
  Future<void> ensureDirectory(
    SyncConfig config,
    String password, {
    String under = '',
  }) async {
    _gate();
  }

  @override
  Future<void> upload(
    SyncConfig config,
    String password,
    String under,
    List<int> bytes,
  ) async {
    _gate();
  }

  @override
  Future<List<int>> download(
    SyncConfig config,
    String password,
    String under,
  ) async {
    _gate();
    throw SyncException(SyncErrorKind.notFound);
  }

  @override
  Future<List<WebdavEntry>> list(
    SyncConfig config,
    String password,
    String under,
  ) async {
    _gate();
    return const <WebdavEntry>[];
  }
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  late Directory dir;
  late TestAppPaths paths;
  late SyncConfigStore configStore;
  late _FakeDav fake;
  late BookUploadPrefsStore uploadPrefs;
  late StatsSyncPrefsStore statsPrefs;
  late SyncTrigger trigger;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mreader_status_page_');
    paths = TestAppPaths(dir);
    configStore = SyncConfigStore(
      dir,
      SyncPasswordVault(MemorySecureStore()),
    );
    await configStore.save(SyncConfig(url: 'https://dav.example.com/dav/', account: 'acc'));
    await configStore.writePassword('pw');
    fake = _FakeDav();
    uploadPrefs = BookUploadPrefsStore(dir);
    await uploadPrefs.load();
    statsPrefs = StatsSyncPrefsStore(dir);
    await statsPrefs.load();
    final ProgressSyncState state = ProgressSyncState(dir);
    trigger = SyncTrigger(
      progressEngine: ProgressSyncEngine(
        client: fake,
        progressStore: ProgressStore(paths),
        configStore: configStore,
        state: state,
      ),
      indexEngine: IndexSync(
        client: fake,
        index: BookIndex(paths),
        configStore: configStore,
      ),
      bookmarkEngine: BookmarkSync(
        client: fake,
        store: BookmarkStore(paths),
        configStore: configStore,
      ),
      settingsEngine: SettingsSync(
        client: fake,
        prefsStore: ReadingPrefsStore(paths),
        configStore: configStore,
      ),
      statsEngine: StatsSync(
        client: fake,
        sessionStore: SessionStore(paths),
        configStore: configStore,
        prefs: statsPrefs,
      ),
      backupEngine: BackupEngine(
        paths: paths,
        client: fake,
        configStore: configStore,
      ),
      restoreEngine: RestoreEngine(
        paths: paths,
        client: fake,
        configStore: configStore,
      ),
      bookUploadEngine: BookUploadEngine(
        client: fake,
        prefs: uploadPrefs,
        configStore: configStore,
      ),
      uploadPrefsStore: uploadPrefs,
      statsPrefsStore: statsPrefs,
      syncState: state,
      syncConfig: configStore,
      booksLoader: () async => <BookRecord>[_book],
      bookFileResolver: (BookRecord record) async => File(
        '${dir.path}${Platform.pathSeparator}library'
        '${Platform.pathSeparator}${record.filePath}',
      ),
    );
  });

  tearDown(() async {
    fake.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 内容较高：拉高视口避免懒加载回收（同 `sync_settings_page_test`）。
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(2400, 3600);
    addTearDown(tester.view.reset);
  }

  /// 交替 runAsync / pump，排空 widget 内发起的真异步 IO（落盘 / 读密码）。
  Future<void> settleReal(WidgetTester tester, {int rounds = 40}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 按行标题定位该行内的 Switch（页面有多个开关后 `find.byType` 不唯一）。
  Finder switchOf(String title) => find.descendant(
        of: find.ancestor(
          of: find.text(title),
          matching: find.byType(SettingsTile),
        ),
        matching: find.byType(Switch),
      );

  Widget buildApp() => host(GlassQualityTier.off, SyncStatusPage(trigger: trigger));

  group('状态组（`SYNC-07`：未配置 / 未同步 / 失败可见 + 重试）', () {
    testWidgets('未配置 → 引导回「WebDAV 同步」配置', (WidgetTester tester) async {
      tall(tester);
      await tester.runAsync(() => configStore.remove());
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(find.text('尚未配置 WebDAV 同步'), findsOneWidget);
      expect(
        find.text('请先返回「WebDAV 同步」完成服务器配置'),
        findsOneWidget,
      );
    });

    testWidgets('已配置未同步 → 「尚未同步」+ 自动时机说明', (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(find.text('尚未同步'), findsOneWidget);
      expect(
        find.text('启动、退出阅读页与退出应用时将自动同步'),
        findsOneWidget,
      );
      expect(find.text('手动操作'), findsOneWidget);
      expect(find.text('立即同步'), findsOneWidget);
      expect(find.text('立即备份'), findsOneWidget);
      expect(find.text('从云端恢复'), findsOneWidget);
      // 脚注说明备份间隔（默认 1 天，PRD §B.4）。
      expect(find.textContaining('超过 1 天才自动触发'), findsOneWidget);
      expect(find.textContaining('无系统级定时任务'), findsOneWidget);
    });

    testWidgets('手动同步成功 → 状态卡显示「上次同步（手动）」', (WidgetTester tester) async {
      tall(tester);
      await tester.runAsync(() => trigger.syncNow());
      await tester.pumpWidget(buildApp());
      await settleReal(tester, rounds: 6);

      expect(find.textContaining('上次同步（手动）'), findsOneWidget);
      expect(find.text('尚未同步'), findsNothing);
      expect(find.text('重试'), findsNothing, reason: '成功不给重试');
    });

    testWidgets('通道不可达 → 失败逐条红字可见 + 「重试」（`SYNC-07` ①②）',
        (WidgetTester tester) async {
      tall(tester);
      fake.fail = true;
      await tester.runAsync(() => trigger.syncNow());
      await tester.pumpWidget(buildApp());
      await settleReal(tester, rounds: 6);

      expect(find.textContaining('上次同步（手动）'), findsOneWidget);
      expect(
        find.text('《三体》：网络不可达，请检查网络连接'),
        findsOneWidget,
        reason: '失败条目 + 可读原因逐条展示',
      );
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);

      // 点重试 → 仍失败时失败现场保持可见（恢复后重试成功在纯测试覆盖）。
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await settleReal(tester, rounds: 6);
      expect(
        find.text('《三体》：网络不可达，请检查网络连接'),
        findsOneWidget,
      );
    });
  });

  group('书籍文件组（`SYNC-05` ① 开关默认关 + 落盘）', () {
    testWidgets('初始关闭；点开 → 已开启并持久化到 book_upload.json',
        (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(buildApp());
      await settleReal(tester, rounds: 6);

      expect(find.text('已关闭（默认）'), findsOneWidget);
      expect(find.textContaining('默认关闭（不传书籍本体）'), findsOneWidget);
      expect(uploadPrefs.enabled, isFalse);
      expect(
        tester.widget<Switch>(switchOf('上传书籍文件')).value,
        isFalse,
        reason: '开关默认关',
      );

      await tester.tap(switchOf('上传书籍文件'));
      // 落盘链（exists → write flush → rename ×2）在 fake zone 里逐步推进，
      // 每步要占一个 runAsync 窗口 → 用默认 40 轮排空后再断言。
      await settleReal(tester);

      expect(uploadPrefs.enabled, isTrue);
      expect(
        tester.widget<Switch>(switchOf('上传书籍文件')).value,
        isTrue,
        reason: 'UI 已重建（setState 落到帧上）',
      );
      expect(find.text('已开启：书籍文件会同步到云端'), findsOneWidget);
      // 新实例读盘验证真的落了 book_upload.json。
      final BookUploadPrefsStore reopened = BookUploadPrefsStore(dir);
      await tester.runAsync(() => reopened.load());
      expect(reopened.enabled, isTrue, reason: '开关持久化');
    });
  });

  group('统计数据组（`STAT-08` ③ 默认开 + 落盘）', () {
    testWidgets('初始开启；关闭 → 已关闭并持久化到 stats_sync.json',
        (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(buildApp());
      await settleReal(tester, rounds: 6);

      expect(find.text('统计数据'), findsOneWidget);
      expect(statsPrefs.enabled, isTrue, reason: '默认开启（缺失即 true）');
      expect(
        tester.widget<Switch>(switchOf('同步阅读统计')).value,
        isTrue,
        reason: '开关默认开',
      );

      await tester.tap(switchOf('同步阅读统计'));
      await settleReal(tester);

      expect(statsPrefs.enabled, isFalse);
      expect(
        tester.widget<Switch>(switchOf('同步阅读统计')).value,
        isFalse,
        reason: 'UI 已重建',
      );
      expect(find.text('已关闭：阅读统计仅保留在本机'), findsOneWidget);
      // 新实例读盘验证真的落了 stats_sync.json。
      final StatsSyncPrefsStore reopened = StatsSyncPrefsStore(dir);
      await tester.runAsync(() => reopened.load());
      expect(reopened.enabled, isFalse, reason: '开关持久化');
    });
  });

  group('设置页入口接线（状态页唯一入口）', () {
    late SettingsStore settings;
    late ProviderStore aiStore;

    setUp(() async {
      settings = SettingsStore(dir);
      aiStore = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
      await settings.load();
      await aiStore.load();
    });

    testWidgets('传 syncTrigger → 「同步状态与备份」入口在场，点入进状态页',
        (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(
        host(
          GlassQualityTier.off,
          SettingsPage(
            settings: settings,
            aiStore: aiStore,
            aiClient: AiClient(),
            syncStore: configStore,
            syncClient: fake,
            syncTrigger: trigger,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('同步状态与备份'), findsOneWidget);
      await tester.tap(find.text('同步状态与备份'));
      await tester.pumpAndSettle();

      expect(find.text('同步与备份'), findsOneWidget, reason: '已推进状态页');
      expect(find.text('立即同步'), findsOneWidget);
    });

    testWidgets('未传 syncTrigger → 状态页入口隐藏（WebDAV 配置入口仍在）',
        (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(
        host(
          GlassQualityTier.off,
          SettingsPage(
            settings: settings,
            aiStore: aiStore,
            aiClient: AiClient(),
            syncStore: configStore,
            syncClient: fake,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('同步状态与备份'), findsNothing);
      expect(find.text('WebDAV 同步'), findsOneWidget);
    });
  });
}
