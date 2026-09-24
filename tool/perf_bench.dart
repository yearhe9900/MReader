// `PERF-02` 首屏 / 稳态性能基线（命令行，纯 Dart）。
//
// 测量「BookSource 层」的两件事：
//   ① **首屏**：进入阅读页前必须完成的工作 ——
//      `load()`（结构 + 元数据） + `chapters()`（章节表） + `content(目标章 ±1)`（首批正文）；
//   ② **稳态**（可选 `readChapters=N`）：在首屏之后再**顺序读完前 N 章**，测其 RSS ——
//      用于验证 `PERF-02` ①「读过的章不被永久驻留」（读全部后内存不该回到全书大小）。
//
// 为什么在 BookSource 层测：纯 Dart、可复现、与 UI/FakeAsync 无关。
//
// **一次进程只测一个样本**（避免跨样本 RSS 互污），并可重复多轮：
//   · `minMs`/`medianMs` 为多轮首屏耗时（min 最稳）；
//   · `maxGapMs` 为**主 isolate 心跳最大间隔**（`PERF-01` 验收口径）：首屏窗口内
//     以 10ms 周期定时器打点，主 isolate 被同步重活钉住时定时器排不上队，相邻
//     打点间隔就会远超周期 —— 取全轮最大值 ≈「UI 最长连续无响应时长」（含收尾间隔；
//     整窗无打点时按整窗时长计，那正是微任务链饿死定时器的连续阻塞形态）；
//   · `rssMB`/`peakMB` 为末轮首屏后 / 进程峰值；
//   · `rssAfterReadMB` 为末轮「读完 N 章」后的 RSS（配合 `rssMB` 看是否随读章数增长）。
//
// 用法：
//   dart run tool/gen_perf_fixtures.dart <目录>
//   dart run tool/perf_bench.dart <目录> <样本> <标签> [轮数] [读章数]
//     例：dart run tool/perf_bench.dart %TEMP%\mreader_perf big_bodies.epub after 5 100
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/format/dart_txt_source.dart';

/// 1 MiB。
const int _mib = 1024 * 1024;

/// 样本文件 -> [BookSource] 工厂。
BookSource? _open(String fixture, Uint8List bytes) {
  switch (fixture) {
    case 'big_20mb.txt':
      return DartTxtSource(fileName: fixture, bytes: bytes);
    case 'big_320.epub':
    case 'long_chapter.epub':
    case 'big_bodies.epub':
      return DartEpubSource(fileName: fixture, bytes: bytes);
    default:
      return null;
  }
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'usage: dart run tool/perf_bench.dart <dir> <fixture> <label> '
      '[iterations] [readChapters]',
    );
    exitCode = 2;
    return;
  }
  final String dir = args[0];
  final String fixture = args[1];
  final String label = args[2];
  final int iterations = args.length > 3 ? (int.tryParse(args[3]) ?? 3) : 3;
  final int readChapters = args.length > 4 ? (int.tryParse(args[4]) ?? 0) : 0;

  final File file = File('$dir${Platform.pathSeparator}$fixture');
  if (!file.existsSync()) {
    stdout.writeln('BENCH[$label] $fixture MISSING (${file.path})');
    return;
  }
  final Uint8List bytes = file.readAsBytesSync();

  final List<int> times = <int>[];
  int maxGap = 0;
  int lastRss = 0;
  int lastPeak = 0;
  int lastRssRead = 0;
  int chapterCount = 0;

  for (int i = 0; i < iterations; i++) {
    // 主 isolate 心跳（PERF-01 口径）：首屏窗口内的最大打点间隔。
    int iterMaxGap = 0;
    DateTime lastBeat = DateTime.now();
    final Timer beat = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final DateTime now = DateTime.now();
      final int gap = now.difference(lastBeat).inMilliseconds;
      if (gap > iterMaxGap) iterMaxGap = gap;
      lastBeat = now;
    });
    final Stopwatch sw = Stopwatch()..start();
    final BookSource? source = _open(fixture, bytes);
    if (source == null) {
      stderr.writeln('unknown fixture: $fixture');
      exitCode = 2;
      return;
    }
    await source.load();
    final List<Chapter> chapters = await source.chapters();
    chapterCount = chapters.length;

    // 首批正文：目标章 ±1（与阅读页首屏批次一致）。
    final int target = chapters.isEmpty ? 0 : chapters.length ~/ 2;
    if (chapters.isNotEmpty) {
      await source.content(target);
      if (target - 1 >= 0) await source.content(target - 1);
      if (target + 1 < chapters.length) await source.content(target + 1);
    }
    sw.stop();
    beat.cancel();
    // 收尾间隔：窗口结束 − 最后一次打点。**整窗无打点时 = 整窗时长**——
    // before 路径整条「微任务链」（load/chapters/content 全同步完成）会把定时器
    // 饿死一次都排不上队，这段连续无响应正是要计量的对象，不得漏掉。
    final int tailGap = DateTime.now().difference(lastBeat).inMilliseconds;
    if (tailGap > iterMaxGap) iterMaxGap = tailGap;
    times.add(sw.elapsedMilliseconds);
    if (iterMaxGap > maxGap) maxGap = iterMaxGap;
    lastRss = ProcessInfo.currentRss;
    lastPeak = ProcessInfo.maxRss;

    // 稳态（可选）：首屏后再顺序读完前 N 章，测其 RSS。
    if (readChapters > 0) {
      final int n = readChapters > chapters.length ? chapters.length : readChapters;
      for (int j = 0; j < n; j++) {
        await source.content(j);
      }
      lastRssRead = ProcessInfo.currentRss;
    }
    await source.dispose();
  }

  times.sort();
  final String readPart = readChapters > 0
      ? ' readChapters=$readChapters'
          ' rssAfterReadMB=${(lastRssRead / _mib).toStringAsFixed(1)}'
      : '';
  stdout.writeln(
    'BENCH[$label] $fixture '
    'chapters=$chapterCount '
    'iters=$iterations '
    'minMs=${times.first} '
    'medianMs=${times[times.length ~/ 2]} '
    'maxGapMs=$maxGap '
    'rssMB=${(lastRss / _mib).toStringAsFixed(1)} '
    'peakMB=${(lastPeak / _mib).toStringAsFixed(1)}'
    '$readPart',
  );
}
