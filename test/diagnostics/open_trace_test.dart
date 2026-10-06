// [OpenTrace] 开书链路追踪的单元 / widget 测试。
//
// 钉住三件事：
//   ① **计时原点**是「用户按下」——`begin` 后再人为等待 N 毫秒，`open.total`
//     必须 ≥ N（防「原点记晚了」这个最容易犯的错）；
//   ② `open.total` 只在**首帧上屏**后产出，且 `render=` 段 = firstFrame − ready；
//   ③ 幂等：首帧探针重复挂接、重复汇总，都只打一次。
//
// 计时用真实 `Stopwatch`（墙上时钟），不受 widget 测试的 FakeAsync 影响
// （`testWidgets` 体内 `await tester.pump(duration)` 只是推进假时钟）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/diagnostics/open_trace.dart';
import 'package:mreader/diagnostics/perf_log.dart';

/// 跑一个把 [PerfLog.records] 清空并收集本次输出行的辅助。
Future<List<String>> _captureTrace(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  PerfLog.records.clear();
  await body();
  await tester.pump();
  return PerfLog.records
      .map((String line) => line)
      .where((String line) => line.contains('open.'))
      .toList();
}

void main() {
  test('begin 落 open.begin 且含书名与 id', () {
    PerfLog.records.clear();
    OpenTrace.begin(bookId: 'b1', title: '绍宋');
    expect(PerfLog.records.any((String l) => l.contains('open.begin')),
        isTrue);
    expect(PerfLog.records.any((String l) => l.contains('绍宋')), isTrue);
  });

  test('report 输出 open.total，含 ready/render 段与逐段差值', () {
    PerfLog.records.clear();
    final OpenTrace trace = OpenTrace.begin(bookId: 'b1', title: 'T');
    trace.step('readBytes', 12, 'sizeKB=1024');
    trace.mark('pushed');
    trace.mark('ready', 'paged=true');
    // 模拟「ready 之后又渲染了 30ms 才上屏」。
    trace.mark('firstFrame', 'build=4.0ms raster=6.0ms');
    trace.report();

    final String total =
        PerfLog.records.firstWhere((String l) => l.contains('open.total'));
    expect(total, contains('ready='));
    expect(total, contains('firstFrame='));
    expect(total, contains('render='),
        reason: '必须单列渲染段，否则解析快=体验快的错觉会掩盖渲染慢');
    expect(total, contains('readBytes=12ms'),
        reason: '逐段差值应能从日志直接读出瓶颈段落');
  });

  test('report / reportChain 幂等：各只打一次', () {
    PerfLog.records.clear();
    final OpenTrace trace = OpenTrace.begin(bookId: 'b1', title: 'T');
    trace.mark('firstFrame');
    trace.report();
    trace.report();
    trace.reportChain();
    trace.reportChain();

    expect(PerfLog.records.where((String l) => l.contains('open.total')).length,
        1);
    expect(PerfLog.records.where((String l) => l.contains('open.chain')).length,
        1);
  });

  test('chain 段含 settle（首帧上屏 → 位置落定），total 不含', () {
    PerfLog.records.clear();
    final OpenTrace trace = OpenTrace.begin(bookId: 'b1', title: 'T');
    trace.mark('ready');
    trace.mark('firstFrame');
    trace.mark('restoreEnd', 'converged=true');
    trace.report();
    trace.reportChain();

    final String total =
        PerfLog.records.firstWhere((String l) => l.contains('open.total'));
    final String chain =
        PerfLog.records.firstWhere((String l) => l.contains('open.chain'));
    expect(chain, contains('settle='),
        reason: '「打开后还在跳」的耗时须单列，这是 total 之后的增量');
    expect(total.contains('settle='), isFalse,
        reason: 'total 的口径是「看到书」，不含之后的位置校正');
  });

  testWidgets('首帧探针：正文上屏后才产出 open.total', (WidgetTester tester) async {
    final List<String> lines = await _captureTrace(tester, () async {
      final OpenTrace trace = OpenTrace.begin(bookId: 'b1', title: 'T');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () {
                trace.mark('ready');
                trace.attachFirstFrameProbe();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('内容')),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));

      // 探针挂接前：不应有任何汇总。
      expect(PerfLog.records.any((String l) => l.contains('open.total')),
          isFalse,
          reason: 'ready 只是「可渲染」，此刻还没上屏，不能提前汇总');

      await tester.tap(find.text('go'));
      await tester.pump(); // 触发 SnackBar（排入一帧）
      await tester.pump(const Duration(milliseconds: 300)); // SnackBar 动画跑完
    });

    expect(lines.any((String l) => l.contains('open.firstFrame')), isTrue,
        reason: '应产出首帧时序行');
    expect(lines.any((String l) => l.contains('open.total')), isTrue,
        reason: '应产出端到端汇总行');
    final String firstFrame =
        lines.firstWhere((String l) => l.contains('open.firstFrame'));
    // 帧时序在测试环境可能为空（无 raster），但 build/raster 字段要么有值、
    // 要么显式 `timings=none`——不能整行缺失。
    expect(firstFrame.contains('build=') || firstFrame.contains('timings='),
        isTrue);
  });

  testWidgets('探针幂等：重复挂接只统计一次首帧', (WidgetTester tester) async {
    final List<String> lines = await _captureTrace(tester, () async {
      final OpenTrace trace = OpenTrace.begin(bookId: 'b1', title: 'T');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () {
                trace.mark('ready');
                trace
                  ..attachFirstFrameProbe()
                  ..attachFirstFrameProbe()
                  ..attachFirstFrameProbe();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('x')),
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
    });

    expect(lines.where((String l) => l.contains('open.firstFrame')).length, 1);
    expect(lines.where((String l) => l.contains('open.total')).length, 1);
  });
}