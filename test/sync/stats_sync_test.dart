// `STAT-08`：阅读统计跨设备同步测试（按会话 id 并集 / 同 id 取较大 duration /
// 连续同步 3 次总时长不变的幂等 / 默认开启可单独关闭且关闭零请求 + §10 验收：
// A 的 10 分钟 B 能拿到、同日同书两条相加而非覆盖）。
//
// 口径（同 `sync_trigger_test`）：纯 `test()` + 真 socket [MockDav]；两台设备
// = 两个临时目录两套 [SessionStore] / [StatsSync]，共享一个 MockDav 与同一份
// 连接配置（指向同一云端）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/stats/session_store.dart';
import 'package:mreader/stats/stats_sync.dart';
import 'package:mreader/sync/entry_sync.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';

import 'sync_support.dart';

/// 造一条会话（`id` 由 bookId + startedAt 确定性派生，`STAT-08` 幂等基础）。
ReadingSession _session({
  required String bookId,
  required int startedAt,
  required int duration,
}) =>
    ReadingSession(
      id: ReadingSession.makeId(bookId, startedAt),
      bookId: bookId,
      dayKey: sessionDayKey(startedAt),
      startedAt: startedAt,
      endedAt: startedAt + duration * 1000,
      duration: duration,
      start: SessionPosition(chapterHref: 'c#1', chapterPos: 0.1),
      end: SessionPosition(chapterHref: 'c#2', chapterPos: 0.9),
    );

void main() {
  late Directory dirA;
  late Directory dirB;
  late SessionStore storeA;
  late SessionStore storeB;
  late StatsSyncPrefsStore prefsA;
  late StatsSyncPrefsStore prefsB;
  late SyncConfigStore configStore;
  late WebdavClient client;
  late MockDav dav;
  late StatsSync syncA;
  late StatsSync syncB;

  /// 远端 stats 分片的 PUT 计数（幂等口径：收敛后不再增长）。
  int statsPuts() => dav.calls
      .where((String c) => c.startsWith('PUT /mreader/stats/'))
      .length;

  Future<int> totalSeconds(SessionStore store) async =>
      (await store.loadAll()).fold<int>(
        0,
        (int sum, ReadingSession s) => sum + s.duration,
      );

  setUp(() async {
    dirA = Directory.systemTemp.createTempSync('mreader_stats_a_');
    dirB = Directory.systemTemp.createTempSync('mreader_stats_b_');
    final TestAppPaths pathsA = TestAppPaths(dirA);
    final TestAppPaths pathsB = TestAppPaths(dirB);
    storeA = SessionStore(pathsA);
    storeB = SessionStore(pathsB);
    prefsA = StatsSyncPrefsStore(dirA);
    prefsB = StatsSyncPrefsStore(dirB);
    await prefsA.load();
    await prefsB.load();
    configStore = SyncConfigStore(
      dirA,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    final String base = await dav.start();
    await configStore.save(SyncConfig(url: base, account: 'acc'));
    await configStore.writePassword('pw');
    syncA = StatsSync(
      client: client,
      sessionStore: storeA,
      configStore: configStore,
      prefs: prefsA,
    );
    syncB = StatsSync(
      client: client,
      sessionStore: storeB,
      configStore: configStore,
      prefs: prefsB,
    );
  });

  tearDown(() async {
    client.close();
    await dav.stop();
    if (dirA.existsSync()) {
      dirA.deleteSync(recursive: true);
    }
    if (dirB.existsSync()) {
      dirB.deleteSync(recursive: true);
    }
  });

  group('`STAT-08` ③ 开关：默认开启、可单独关闭', () {
    test('缺失 stats_sync.json 即默认开；关闭后同步零请求', () async {
      expect(prefsA.enabled, isTrue, reason: '默认开启（fail-open）');
      final int startedAt = DateTime(2026, 10, 5, 8).millisecondsSinceEpoch;
      await storeA.merge(<ReadingSession>[
        _session(bookId: 'b1', startedAt: startedAt, duration: 600),
      ]);

      await prefsA.setEnabled(false);
      final int before = dav.calls.length;
      final EntrySyncOutcome outcome = await syncA.sync();
      expect(outcome.failed, isFalse);
      expect(outcome.changed, isFalse);
      expect(
        dav.calls.length,
        before,
        reason: '关闭 = 零请求（判定先于一切网络调用）',
      );

      // 显式关闭持久化（重开读盘仍是 false）。
      final StatsSyncPrefsStore reopened = StatsSyncPrefsStore(dirA);
      await reopened.load();
      expect(reopened.enabled, isFalse, reason: '关闭写入 stats_sync.json');
    });
  });

  group('PRD §10 验收：两台设备相加而非覆盖', () {
    test('A 的 10 分钟 → B 同步拿到；各自新增后双向相加', () async {
      final int t1 = DateTime(2026, 10, 5, 8).millisecondsSinceEpoch;
      await storeA.merge(<ReadingSession>[
        _session(bookId: 'b1', startedAt: t1, duration: 600),
      ]);

      final EntrySyncOutcome a1 = await syncA.sync();
      expect(a1.remoteChanged, isTrue, reason: 'A 首推远端');
      expect(statsPuts(), 1);

      final EntrySyncOutcome b1 = await syncB.sync();
      expect(b1.localChanged, isTrue);
      expect(b1.addedFromRemote, 1);
      expect(
        await totalSeconds(storeB),
        600,
        reason: '验收① A 的 10 分钟 B 拿到',
      );

      // B 同日另一段会话（不同 startedAt → 不同 id）→ 推上远端。
      final int t2 = DateTime(2026, 10, 5, 20).millisecondsSinceEpoch;
      await storeB.merge(<ReadingSession>[
        _session(bookId: 'b1', startedAt: t2, duration: 300),
      ]);
      final EntrySyncOutcome b2 = await syncB.sync();
      expect(b2.remoteChanged, isTrue);
      expect(statsPuts(), 2);

      // A 拉到 B 的新会话：两条相加，不互相覆盖。
      final EntrySyncOutcome a2 = await syncA.sync();
      expect(a2.localChanged, isTrue);
      expect(a2.remoteChanged, isFalse, reason: '远端已是全集');
      expect(await totalSeconds(storeA), 900, reason: '验收② 两条记录相加');
      expect(await totalSeconds(storeB), 900);
    });
  });

  group('同 id 时长不一致取较大值', () {
    test('远端较大 → 本地升为较大值', () async {
      final int t = DateTime(2026, 10, 6, 9).millisecondsSinceEpoch;
      const String bookId = 'b1';
      await storeA.merge(<ReadingSession>[
        _session(bookId: bookId, startedAt: t, duration: 600),
      ]);
      dav.seed(
        'stats/sessions-2026-10.json',
        jsonEncode(<String, Object?>{
          'sessions': <Object?>[
            _session(bookId: bookId, startedAt: t, duration: 900).toJson(),
          ],
        }),
        DateTime.now(),
      );

      final EntrySyncOutcome outcome = await syncA.sync();
      expect(outcome.localChanged, isTrue);
      expect(outcome.remoteChanged, isFalse, reason: '远端已是较大值，无需回传');
      expect(await totalSeconds(storeA), 900, reason: '同 id 取较大时长');
    });

    test('本地较大 → 推上远端，不被较小值覆盖', () async {
      final int t = DateTime(2026, 10, 7, 9).millisecondsSinceEpoch;
      const String bookId = 'b1';
      await storeA.merge(<ReadingSession>[
        _session(bookId: bookId, startedAt: t, duration: 1200),
      ]);
      dav.seed(
        'stats/sessions-2026-10.json',
        jsonEncode(<String, Object?>{
          'sessions': <Object?>[
            _session(bookId: bookId, startedAt: t, duration: 900).toJson(),
          ],
        }),
        DateTime.now(),
      );

      final EntrySyncOutcome outcome = await syncA.sync();
      expect(outcome.remoteChanged, isTrue);
      expect(outcome.localChanged, isFalse, reason: '本地已是较大值');
      expect(await totalSeconds(storeA), 1200, reason: '本地不被远端小值覆盖');
      final Map<String, Object?> remote =
          jsonDecode(dav.textOf('stats/sessions-2026-10.json')!)
              as Map<String, Object?>;
      final List<Object?> sessions = remote['sessions']! as List<Object?>;
      final Map<String, Object?> first = sessions.single! as Map<String, Object?>;
      expect(first['duration'], 1200, reason: '远端已更新为较大值');
    });
  });

  group('并集幂等（`STAT-08` 验收③）', () {
    test('同一批数据连续同步 3 次总时长不变，收敛后零远端写入', () async {
      final int t1 = DateTime(2026, 10, 5, 8).millisecondsSinceEpoch;
      final int t2 = DateTime(2026, 10, 5, 20).millisecondsSinceEpoch;
      await storeA.merge(<ReadingSession>[
        _session(bookId: 'b1', startedAt: t1, duration: 600),
      ]);
      await storeB.merge(<ReadingSession>[
        _session(bookId: 'b1', startedAt: t2, duration: 300),
      ]);

      // 首轮交汇至收敛：A 推 → B 并入并回推 → A 并入。
      await syncA.sync();
      await syncB.sync();
      await syncA.sync();
      final int totalA = await totalSeconds(storeA);
      final int totalB = await totalSeconds(storeB);
      expect(totalA, 900);
      expect(totalB, 900);
      final int puts = statsPuts();

      // 连续同步 3 次：总时长不变、无任何一侧写入（幂等）。
      for (int i = 0; i < 3; i++) {
        final EntrySyncOutcome oa = await syncA.sync();
        final EntrySyncOutcome ob = await syncB.sync();
        expect(oa.changed, isFalse, reason: '收敛后 A 无变更');
        expect(ob.changed, isFalse, reason: '收敛后 B 无变更');
      }
      expect(await totalSeconds(storeA), totalA, reason: '3 次同步总时长不变');
      expect(await totalSeconds(storeB), totalB, reason: '3 次同步总时长不变');
      expect(statsPuts(), puts, reason: '收敛后零远端写入');
    });
  });

  group('失败可见（`SYNC-07` 不静默）', () {
    test('通道 500 → failed + 可读原因；未配置同样收编', () async {
      final int t = DateTime(2026, 10, 8, 9).millisecondsSinceEpoch;
      await storeA.merge(<ReadingSession>[
        _session(bookId: 'b1', startedAt: t, duration: 300),
      ]);

      dav.failStatus = 500;
      final EntrySyncOutcome failed = await syncA.sync();
      expect(failed.failed, isTrue);
      expect(failed.reason, contains('服务端错误'));

      dav.failStatus = null;
      await configStore.remove();
      final EntrySyncOutcome unconfigured = await syncA.sync();
      expect(unconfigured.failed, isTrue);
      expect(unconfigured.reason, contains('尚未配置'));
    });

    test('远端分片损坏 → 整轮跳过，不拿本地覆盖', () async {
      final int t = DateTime(2026, 10, 9, 9).millisecondsSinceEpoch;
      await storeA.merge(<ReadingSession>[
        _session(bookId: 'b1', startedAt: t, duration: 300),
      ]);
      dav.seed('stats/sessions-2026-10.json', 'not-json{{{', DateTime.now());

      final EntrySyncOutcome outcome = await syncA.sync();
      expect(outcome.failed, isTrue);
      expect(outcome.reason, contains('损坏'));
      expect(await totalSeconds(storeA), 300, reason: '本地不动');
      expect(
        dav.textOf('stats/sessions-2026-10.json'),
        'not-json{{{',
        reason: '远端不被覆盖',
      );
      expect(statsPuts(), 0);
    });
  });
}
