// `M3-T10`：统计页 widget 测试（`STAT-03` 首屏三指标 / 起始日期 / 清空）。
//
// ⚠️ FakeAsync 铁律（同 `shelf_page_test.dart`）：`testWidgets` 体内禁真异步 IO，
// 页面 initState 的 `service.load()` 与回调里的落盘都要用 [_settle]
// （runAsync + pump 交替）排空，直接 `pumpAndSettle` 会挂死。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/stats/reading_session.dart';
import 'package:mreader/stats/session_store.dart';
import 'package:mreader/stats/stats_service.dart';
import 'package:mreader/ui/stats_page.dart';

import '../test_config.dart';

/// 临时目录实现 [AppPaths]。
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

/// 交替 runAsync / pump，排空 widget 内发起的真异步 IO（与 shelf 测试同款）。
Future<void> _settle(WidgetTester tester, {int rounds = 40}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
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
  capTestTimeout();

  late Directory tempDir;
  late _TestAppPaths paths;
  late StatsService service;

  final List<ReadingSession> seed = <ReadingSession>[
    _session(bookId: 'bookA', dayKey: '2026-09-10', startedAt: 1, duration: 600),
    _session(bookId: 'bookA', dayKey: '2026-09-10', startedAt: 2, duration: 120),
    _session(bookId: 'bookB', dayKey: '2026-09-11', startedAt: 3, duration: 300),
    _session(bookId: 'bookB', dayKey: '2026-08-15', startedAt: 4, duration: 1800),
  ];

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_stats_page_');
    paths = _TestAppPaths(tempDir);
    // 数据先于页面落盘（setUp 在 FakeAsync 之外，可照常 await 真 IO）。
    await SessionStore(paths).merge(seed);
    service = StatsService(paths);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp() => MaterialApp(home: StatsPage(service: service));

  testWidgets('STAT-03 ①：首屏三指标 —— 47 分钟 至今 / 3 天 / 2 本',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await _settle(tester); // 排 service.load()

    // 2820s = 47 分钟；天 09-10/09-11/08-15 = 3；本 bookA/bookB = 2。
    expect(find.text('47 分钟 至今'), findsOneWidget);
    expect(find.text('3 天'), findsOneWidget);
    expect(find.text('2 本'), findsOneWidget);
    expect(find.text('统计全部记录'), findsOneWidget);
    // 设置区两行在场。
    expect(find.text('起始日期'), findsOneWidget);
    expect(find.text('清空统计数据'), findsOneWidget);
  });

  testWidgets('STAT-03 ③：设置起始日期后，数字与文案同步变化（8 月不计）',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await _settle(tester);

    // 由服务侧设定（等价于弹层 / 日期选择器回传后的同一条路径）。
    await tester.runAsync(() => service.setSinceDate(DateTime(2026, 9, 1)));
    await tester.pump();

    // 1020s = 17 分钟；8 月那条不再计入。
    expect(find.text('17 分钟 至今'), findsOneWidget);
    expect(find.text('2 天'), findsOneWidget);
    expect(find.text('起始日期：2026-09-01'), findsOneWidget);
    expect(find.text('2026-09-01'), findsOneWidget); // 设置行当前值
    expect(find.text('47 分钟 至今'), findsNothing);
  });

  testWidgets('STAT-03 ④：清空走二次确认——确认后三指标归零、页面仍在',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await _settle(tester);
    expect(find.text('47 分钟 至今'), findsOneWidget);

    await tester.tap(find.text('清空统计数据'));
    await tester.pumpAndSettle(); // 确认框弹出

    expect(find.text('清空统计'), findsOneWidget); // 弹框标题
    expect(
      find.textContaining('书架、进度、书签与笔记不受影响'),
      findsOneWidget,
    );
    // 先点「取消」：数据不受影响（barrier 之外的第一道防线）。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('47 分钟 至今'), findsOneWidget);

    // 再点确认：真 IO（clearAll 落盘）→ _settle 排空 → 归零。
    await tester.tap(find.text('清空统计数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await _settle(tester);

    expect(find.text('0 分钟 至今'), findsOneWidget);
    expect(find.text('0 天'), findsOneWidget);
    expect(find.text('0 本'), findsOneWidget);
    // 页面仍在（非空态崩溃），设置区可继续操作。
    expect(find.text('起始日期'), findsOneWidget);
  });

  testWidgets('起始日期弹层选「不限」→ 回到全部记录口径',
      (WidgetTester tester) async {
    await tester.runAsync(() => service.setSinceDate(DateTime(2026, 9, 1)));
    await tester.pumpWidget(buildApp());
    await _settle(tester);
    expect(find.text('17 分钟 至今'), findsOneWidget);

    await tester.tap(find.text('起始日期'));
    await tester.pumpAndSettle(); // 玻璃选择层弹出

    await tester.tap(find.text('不限（统计全部记录）'));
    await _settle(tester); // 选择层 pop + setSinceDate 落盘 + 通知重建

    expect(find.text('不限'), findsOneWidget);
    expect(find.text('47 分钟 至今'), findsOneWidget);
    expect(find.text('统计全部记录'), findsOneWidget);
  });
}
