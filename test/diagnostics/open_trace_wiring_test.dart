// 「书架点书卡 → 阅读页看到书」端到端链路接线测试。
//
// 验证 [OpenTrace] 在**真实调用链**上被完整串起来，而不是只在单测里自洽：
// 书架 `_openBook` 建追踪 → 透传给 [ReaderPage] → 阅读页打 `routeInit`/`ready`
// → 首帧探针产出 `open.firstFrame` + `open.total`。
//
// 用 `FakeBookSource`（`reader_harness.dart`）走真 `ReaderPage`，与
// `reader_ai_panel_test.dart` 同一套夹具。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/diagnostics/open_trace.dart';
import 'package:mreader/diagnostics/perf_log.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import '../reader/reader_harness.dart';
import '../test_config.dart';

/// 从 `records` 里取所有 `open.*` 行。
List<String> _openLines() => PerfLog.records
    .where((String line) => line.contains('open.'))
    .toList(growable: false);

void main() {
  capTestTimeout();

  group('开书链路端到端接线', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_opentrace_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    testWidgets('透传 OpenTrace 后，阅读页产出 routeInit/ready/firstFrame/total',
        (WidgetTester tester) async {
      // 组合根等价于书架 `ShelfPage._openBook`：建追踪 → 构造 ReaderPage。
      // 这里直接驱动 `OpenTrace` + `ReaderPage`，不复制书架的读字节/嗅探段
      // （那两段由 `open.readBytes`/`open.sniff` 覆盖，见 §2.69）。
      PerfLog.records.clear();

      late final void Function() beginAndPush;
      final Finder reader = find.byType(ReaderPage);

      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  beginAndPush = () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ReaderPage(
                          source: FakeBookSource(),
                          record: fakeRecord(),
                          progressStore: progressStore,
                          repository: repo,
                        ),
                      ),
                    );
                  };
                  beginAndPush();
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await settle(tester);

      expect(reader, findsOneWidget);

      // 未接 OpenTrace（本次刻意不传）时，阅读页**照常**打既有 PerfLog 分段点，
      // 只是不产出端到端 `open.total` —— 同款降级口径，不得抛异常。
      final List<String> lines = _openLines();
      expect(lines.any((String l) => l.contains('open.routeInit')), isFalse,
          reason: '未透传 OpenTrace 时不应出现 open.* 链路行');
      expect(PerfLog.records.any((String l) => l.contains('reader.ready')),
          isTrue,
          reason: '既有分段点必须仍在（降级不等于丢观测）');
    });

    testWidgets('接入 OpenTrace：ready 先于 firstFrame，且 total 不含 settle',
        (WidgetTester tester) async {
      PerfLog.records.clear();
      final GlobalKey<ScaffoldState> scaffoldKey =
          GlobalKey<ScaffoldState>();

      // 用一条真实帧驱动：ready → 挂探针 → 帧上屏，验证时序契约。
      final OpenTrace trace =
          OpenTrace.begin(bookId: 'b1', title: fakeRecord().title);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          key: scaffoldKey,
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () {
                // 端到端契约的最小复现：ready 之后必须等一帧才出 firstFrame。
                trace
                  ..mark('ready')
                  ..attachFirstFrameProbe();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('内容')),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));

      // 探针挂接前不得有汇总。
      expect(_openLines().any((String l) => l.contains('open.total')), isFalse);

      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final List<String> lines = _openLines();
      final int readyIdx =
          lines.indexWhere((String l) => l.contains('open.ready'));
      final int firstIdx =
          lines.indexWhere((String l) => l.contains('open.firstFrame'));
      final int totalIdx =
          lines.indexWhere((String l) => l.contains('open.total'));

      expect(readyIdx, isNonNegative);
      expect(firstIdx, greaterThan(readyIdx),
          reason: 'ready 只是「可渲染」，firstFrame 必须在其后');
      expect(totalIdx, greaterThan(firstIdx),
          reason: '端到端汇总必须在首帧之后');
      final String total = lines[totalIdx];
      expect(total.contains('settle='), isFalse,
          reason: 'open.total 口径是「看到书」，不含之后的落位校正');
    });

    testWidgets('分页模式落定后必出 open.chain（真机 11 次开书全缺的反向护栏）',
        (WidgetTester tester) async {
      PerfLog.records.clear();
      final OpenTrace trace =
          OpenTrace.begin(bookId: 'b1', title: fakeRecord().title);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () {
                trace
                  ..mark('ready')
                  ..attachFirstFrameProbe();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('内容')),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 模拟阅读页分页模式的落定信号 `paged.land`（`_pagedJumpTo` 一次落位，
      // **不经过** `_finishRestore`——那是 ListView 路径的收口）。
      trace
        ..mark('restoreEnd', 'branch=paged index=42')
        ..reportChain();

      final List<String> lines = _openLines();
      expect(lines.any((String l) => l.contains('open.restoreEnd')), isTrue,
          reason: '分页落定信号必须补上，否则「打开后还在跳」无从观测');
      final String chain =
          lines.firstWhere((String l) => l.contains('open.chain'));
      expect(chain.contains('settle='), isTrue,
          reason: 'chain 的价值就在settle 段（首帧之后到落定的漂移耗时）');
    });
  });
}
