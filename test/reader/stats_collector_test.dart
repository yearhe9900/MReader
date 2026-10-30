// `test/reader/stats_collector_test.dart`：`M3-T10b` —— `STAT-01` 采集**生产接线**
//（ReaderPage → StatsService → SessionStore）的 widget 级验证。
//
// 覆盖（PRD `STAT-01` 里可在 widget 层验证的部分）：
//   ① 进页起表、退出阅读页落库一条会话（写库只发生在收尾）；
//   ② 连续交互（分页拖拽 / 跳章）期间统计目录 0 写入，关书才落库（验收⑤）；
//   ③ 切后台收尾落库、回前台另起会话：两条记录、时间不重叠、后台停留不计入
//      （验收④）；
//   ④ 注入链透传：HomeShell → ShelfPage →（开书）ReaderPage 是同一实例；
//      经书架真实 TXT 开书链路落库成功。
// 空闲 3 分钟切分、跨 0 点拆天等时间口径由 `SessionTracker` 单测覆盖
//（`test/stats/`），此处只验证接线，单次等待控制在秒级。
//
// ⚠️ FakeAsync 铁律同 `reader_page_test.dart`：测试体内 await 真 IO 必须包
// `tester.runAsync`；widget 内部 IO 用 [settle] 交替推进；关书用 [closeBook]。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/settings/shelf_layout_store.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/stats/session_store.dart';
import 'package:mreader/stats/stats_service.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/home_shell.dart';
import 'package:mreader/ui/shelf_page.dart';

import '../test_config.dart';
import 'reader_harness.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('STAT-01 采集接线', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;
    late StatsService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_stat01_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
      service = StatsService(paths);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Directory statsDir() => Directory(
          '${tempDir.path}${Platform.pathSeparator}${SessionStore.dirName}',
        );

    Widget buildReader() => MaterialApp(
          home: ReaderPage(
            source: FakeBookSource(),
            record: fakeRecord(),
            progressStore: progressStore,
            repository: repo,
            statsService: service,
          ),
        );

    /// 排空收尾（dispose / 切后台）发起的 `ingest`（merge + loadAll 真 IO）。
    Future<void> drainIngest(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await settle(tester, rounds: 25);
    }

    testWidgets('① 进页起表：退出阅读页落库一条 ≥1s 的会话（写库只在收尾）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildReader());
      await settle(tester); // 开书 + 定位（起表在 initState）

      // 时长按整秒向下取整 → 必须真实读满 1s 才会产出记录（`STAT-02` ②）。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await closeBook(tester);
      await drainIngest(tester);

      await tester.runAsync(service.load);
      expect(service.sessions.length, 1);
      final ReadingSession session = service.sessions.single;
      expect(session.bookId, 'testbook01');
      expect(session.duration, greaterThanOrEqualTo(1));
      expect(
        session.duration,
        lessThan(10),
        reason: '只计阅读期，不应把整个测试时长吞进去',
      );
      expect(
        statsDir().listSync().whereType<File>().length,
        1,
        reason: '当月单分片（`STAT-02` 按月分片）',
      );
    });

    testWidgets('⑤ 接线面：连续交互期间统计 0 写入，关书才落库',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildReader());
      await settle(tester);

      // 连续滚动交互（分页拖拽停稳 → `_onPagedStopped` 汇聚点）。
      for (int i = 0; i < 5; i++) {
        await tester.drag(find.byType(PagedScroller), const Offset(0, -240));
        await settle(tester, rounds: 8);
      }
      // 跳章交互（目录 → `_goToChapter` 汇聚点）。
      // 注：点 ListTile 而非 `find.text('第三章')`——该文案在树里出现两处
      // （NAV-01 未拖拽时恰好唯一），按文本点会歧义。
      await showChrome(tester);
      await tester.tap(find.byKey(const Key('reader-toc')));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(3));
      await tester.tap(find.byType(ListTile).at(2));
      await tester.pumpAndSettle();
      await settle(tester, rounds: 10);

      expect(
        statsDir().existsSync() &&
            statsDir().listSync().whereType<File>().isNotEmpty,
        isFalse,
        reason: '`STAT-01` ⑤：翻页 / 跳转只 noteActivity，不触发统计写库',
      );

      await closeBook(tester);
      await drainIngest(tester);
      expect(statsDir().existsSync(), isTrue, reason: '关书才落库');
      expect(statsDir().listSync().whereType<File>().length, 1);
    });

    testWidgets('④ 切后台收尾落库、回前台另起会话：两条不重叠，后台停留不计入',
        (WidgetTester tester) async {
      final int t0 = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(buildReader());
      await settle(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );

      // 切后台 = 会话结束 + 落库（写库事件只发生在会话结束或切后台）。
      final int pauseAt = DateTime.now().millisecondsSinceEpoch;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await drainIngest(tester);

      await tester.runAsync(service.load);
      expect(service.sessions.length, 1, reason: '切后台即落库第一条');
      final int firstEnd = service.sessions.single.endedAt;

      // 后台停留 ≥2.5s——若被计入阅读时长，末尾的时值守恒断言必炸。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2500)),
      );
      final int resumeAt = DateTime.now().millisecondsSinceEpoch;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      // 回前台另起会话：再读 ≥1s 保证第二条能产出。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await closeBook(tester);
      await drainIngest(tester);
      final int t1 = DateTime.now().millisecondsSinceEpoch;

      await tester.runAsync(service.load);
      final List<ReadingSession> sessions = List<ReadingSession>.of(
        service.sessions,
      )..sort((ReadingSession a, ReadingSession b) =>
          a.startedAt.compareTo(b.startedAt));
      expect(sessions.length, 2, reason: '切后台再回前台 = 两次会话（验收④）');
      expect(sessions.first.duration, greaterThanOrEqualTo(1));
      expect(sessions.last.duration, greaterThanOrEqualTo(1));
      expect(
        sessions.last.startedAt,
        greaterThanOrEqualTo(firstEnd),
        reason: '两段会话不重叠、总时长不重复',
      );
      // 时值守恒：两条 duration 之和 ≤ 总墙钟 − 后台停留（毫秒口径，floor 只会更小）。
      // 若后台被误计入（如 paused 未收尾），此式必然被撑破。
      final int activeBudgetMs = (t1 - t0) - (resumeAt - pauseAt);
      expect(
        (sessions.first.duration + sessions.last.duration) * 1000,
        lessThanOrEqualTo(activeBudgetMs),
        reason: '后台停留的 ${resumeAt - pauseAt}ms 不得计入阅读时长',
      );
    });

    testWidgets('注入链 A：HomeShell 把组合根的 statsService 透传给 ShelfPage',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            repository: repo,
            coverStore: FileCoverStore(paths),
            progressStore: progressStore,
            shelfPrefs: ShelfPrefsStore(tempDir),
            shelfLayout: ShelfLayoutStore(tempDir),
            settings: SettingsStore(tempDir),
            statsService: service,
            aiStore: ProviderStore(
              tempDir,
              AiKeyVault(FileSecureStore(directory: tempDir)),
            ),
            aiClient: AiClient(),
          ),
        ),
      );
      await settle(tester, rounds: 30);

      final ShelfPage shelf = tester.widget<ShelfPage>(find.byType(ShelfPage));
      expect(
        identical(shelf.statsService, service),
        isTrue,
        reason: '组合根 → HomeShell → ShelfPage 必须是同一实例',
      );

      // 拆树排空（统计页 initState 起的真 IO），避免 tearDown 删目录竞态。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await settle(tester, rounds: 10);
    });

    testWidgets('注入链 B：经 ShelfPage 真实开书（TXT）后会话照常落库',
        (WidgetTester tester) async {
      final ImportResult? imported = await tester.runAsync(
        () => repo.importFile(
          bytes: Uint8List.fromList(utf8.encode('甲书正文内容。' * 20)),
          fileName: '甲书.txt',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ShelfPage(
            repository: repo,
            coverStore: FileCoverStore(paths),
            progressStore: progressStore,
            shelfPrefs: ShelfPrefsStore(tempDir),
            shelfLayout: ShelfLayoutStore(tempDir),
            statsService: service,
          ),
        ),
      );
      await settle(tester);

      // 点卡直接进阅读页（`951f571`；书名命中封面 + 信息区两处 → 取 .first）。
      await tester.tap(
        find
            .ancestor(of: find.text('甲书'), matching: find.byType(BookCard))
            .first,
      );
      await settle(tester, rounds: 80); // 真实开书：读文件 + 解析 + 首帧
      expect(
        find.byType(ReaderPage, skipOffstage: false),
        findsOneWidget,
        reason: '书架应已 push 阅读页',
      );

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await closeBook(tester);
      await drainIngest(tester);

      await tester.runAsync(service.load);
      expect(service.sessions.length, 1);
      final ReadingSession session = service.sessions.single;
      expect(session.bookId, imported!.record.bookId,
          reason: '落库归属开的那本书');
      expect(session.duration, greaterThanOrEqualTo(1));
    });
  });
}
