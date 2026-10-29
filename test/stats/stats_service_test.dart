// `STAT-03`：StatsService 单测（真异步 IO，普通 `test()`——
// ⚠️ FakeAsync 区会挂死真 IO，**勿改 testWidgets**）。
//
// 覆盖：载入聚合逐秒一致（②）、起始日期过滤 + 持久化（③）、清空归零且
// 不伤其它数据（④）、监听回调通知语义。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/stats/session_store.dart';
import 'package:mreader/stats/stats_service.dart';

/// 临时目录实现 [AppPaths]（与 `session_store_test.dart` 同款）。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir = Directory(
      '${_root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}

/// 构造一条记录（id 派生口径同采集器）。
ReadingSession _session({
  required String bookId,
  required String dayKey,
  required int startedAt,
  required int duration,
}) {
  return ReadingSession(
    id: ReadingSession.makeId(bookId, startedAt),
    bookId: bookId,
    dayKey: dayKey,
    startedAt: startedAt,
    endedAt: startedAt + duration * 1000,
    duration: duration,
    start: SessionPosition(chapterHref: 'c1', chapterPos: 0.1),
    end: SessionPosition(chapterHref: 'c1', chapterPos: 0.9),
  );
}

void main() {
  late Directory tempDir;
  late _TestAppPaths paths;

  // 与 aggregator_test 同型样本（经真实分片往返）：
  //   A bookA 09-10 600s / B bookA 09-10 120s / C bookB 09-11 300s / D bookB 08-15 1800s
  final List<ReadingSession> seed = <ReadingSession>[
    _session(bookId: 'bookA', dayKey: '2026-09-10', startedAt: 1, duration: 600),
    _session(bookId: 'bookA', dayKey: '2026-09-10', startedAt: 2, duration: 120),
    _session(bookId: 'bookB', dayKey: '2026-09-11', startedAt: 3, duration: 300),
    _session(bookId: 'bookB', dayKey: '2026-08-15', startedAt: 4, duration: 1800),
  ];

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_stats_service_');
    paths = _TestAppPaths(tempDir);
    await SessionStore(paths).merge(seed);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('STAT-03 ②：载入后总时长与全部记录求和逐秒一致，天数 / 书籍去重', () async {
    final StatsService service = StatsService(paths);
    await service.load();
    expect(service.isLoaded, isTrue);
    expect(service.overview.totalSeconds, 2820); // 600+120+300+1800
    expect(service.overview.activeDays, 3);
    expect(service.overview.bookCount, 2);
    expect(service.sinceDay, isNull); // 默认不限
    expect(service.sessions.length, 4);
  });

  test('STAT-03 ③：setSinceDate 过滤生效且持久化（新实例 load 后仍生效）', () async {
    final StatsService service = StatsService(paths);
    await service.load();
    await service.setSinceDate(DateTime(2026, 9, 1));
    expect(service.sinceDay, '2026-09-01');
    expect(service.overview.totalSeconds, 1020); // 2820 - 1800（8 月）

    // 模拟重启：新实例读到同一配置。
    final StatsService reopened = StatsService(paths);
    await reopened.load();
    expect(reopened.sinceDay, '2026-09-01');
    expect(reopened.overview.totalSeconds, 1020);

    // 恢复不限。
    await reopened.setSinceDate(null);
    expect(reopened.sinceDay, isNull);
    expect(reopened.overview.totalSeconds, 2820);
  });

  test('STAT-03 ④：clearAll 归零，只删会话分片——配置与其它目录不动', () async {
    final StatsService service = StatsService(paths);
    await service.load();
    await service.setSinceDate(DateTime(2026, 9, 1));

    // 在 library 目录放一个「其它数据」（代表书架副本；书架索引、进度等同理
    // 各有自己的存储，清空统计绝不触碰）。
    final Directory libDir = await paths.subDir('library');
    final File bystander = File(
      '${libDir.path}${Platform.pathSeparator}book.epub',
    );
    await bystander.writeAsString('书架数据');

    await service.clearAll();

    // 三指标归零。
    expect(service.sessions, isEmpty);
    expect(service.overview.totalSeconds, 0);
    expect(service.overview.activeDays, 0);
    expect(service.overview.bookCount, 0);

    // 会话分片全删。
    final Directory statsDir = await paths.subDir(SessionStore.dirName);
    final List<FileSystemEntity> shards = statsDir
        .listSync()
        .where((FileSystemEntity e) =>
            e.path.contains(SessionStore.filePrefix))
        .toList();
    expect(shards, isEmpty);

    // 起始日期配置保留（清空统计 ≠ 重置配置）。
    expect(
      File(
        '${statsDir.path}${Platform.pathSeparator}${StatsService.configFile}',
      ).existsSync(),
      isTrue,
    );
    final StatsService reopened = StatsService(paths);
    await reopened.load();
    expect(reopened.sinceDay, '2026-09-01');
    expect(reopened.overview.totalSeconds, 0); // 配置在，但数据已空

    // library 旁观文件原样。
    expect(bystander.readAsStringSync(), '书架数据');
  });

  test('监听回调：load / setSinceDate / clearAll 各通知一次，remove 后静默', () async {
    final StatsService service = StatsService(paths);
    int calls = 0;
    void listener() => calls++;

    service.addListener(listener);
    await service.load();
    expect(calls, 1);
    await service.setSinceDate(DateTime(2026, 9, 1));
    expect(calls, 2);
    await service.clearAll();
    expect(calls, 3);

    service.removeListener(listener);
    await service.load();
    expect(calls, 3); // 已移除，不再通知
  });
}
