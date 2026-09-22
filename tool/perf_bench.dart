// `PERF-02` 首屏性能基线（命令行，纯 Dart）。
//
// 测量「BookSource 层首屏」——进入阅读页前必须完成的工作：
//   `load()`（结构 + 元数据） + `chapters()`（章节表） + `content(目标章 ±1)`（首批正文）。
//
// 为什么在 BookSource 层测：纯 Dart、可复现、与 UI/FakeAsync 无关；阅读页「首屏」正是
// 「等这一组调用返回 + 首次布局」。改前 / 改后用同一脚本、同一命令对比即可。
//
// **一次进程只测一个样本**（避免跨样本的 RSS 互相污染），并可重复多轮观察：
//   · `firstScreenMs` 取「预热后的最小值」——最稳、最能反映稳态成本；
//   · `rssMB` / `peakMB` 取最后一轮的驻留 / 峰值（VM 不归还内存，故接近高水位）；
//   · 多轮 `rssMB` 的走势可看「开关书是否累积」（配合 `test/perf` 的 5× 开关断言）。
//
// 用法：
//   dart run tool/gen_perf_fixtures.dart <目录>            # 先生成样本
//   dart run tool/perf_bench.dart <目录> <样本> <标签> [轮数]
//     例：dart run tool/perf_bench.dart %TEMP%\mreader_perf big_320.epub after 5
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
      return DartEpubSource(fileName: fixture, bytes: bytes);
    default:
      return null;
  }
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'usage: dart run tool/perf_bench.dart <dir> <fixture> <label> [iterations]',
    );
    exitCode = 2;
    return;
  }
  final String dir = args[0];
  final String fixture = args[1];
  final String label = args[2];
  final int iterations = args.length > 3 ? (int.tryParse(args[3]) ?? 3) : 3;

  final File file = File('$dir${Platform.pathSeparator}$fixture');
  if (!file.existsSync()) {
    stdout.writeln('BENCH[$label] $fixture MISSING (${file.path})');
    return;
  }
  final Uint8List bytes = file.readAsBytesSync();

  final List<int> times = <int>[];
  int lastRss = 0;
  int lastPeak = 0;
  int chapterCount = 0;

  for (int i = 0; i < iterations; i++) {
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
    final int target = chapters.isEmpty ? 0 : chapters.length ~/ 2;
    if (chapters.isNotEmpty) {
      await source.content(target);
      if (target - 1 >= 0) await source.content(target - 1);
      if (target + 1 < chapters.length) await source.content(target + 1);
    }
    sw.stop();
    times.add(sw.elapsedMilliseconds);
    lastRss = ProcessInfo.currentRss;
    lastPeak = ProcessInfo.maxRss;
    await source.dispose();
  }

  times.sort();
  stdout.writeln(
    'BENCH[$label] $fixture '
    'chapters=$chapterCount '
    'iters=$iterations '
    'minMs=${times.first} '
    'medianMs=${times[times.length ~/ 2]} '
    'rssMB=${(lastRss / _mib).toStringAsFixed(1)} '
    'peakMB=${(lastPeak / _mib).toStringAsFixed(1)}',
  );
}
