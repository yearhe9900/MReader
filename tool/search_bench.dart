// `CNT-06` 全书搜索性能基线（阈值 4；命令行，纯 Dart）。
//
// 阈值 4（PRD §15.6）：**50MB 书全库搜索首屏结果 > 1.5s**，或**搜索期间单帧
// > 16ms（UI 卡顿）**。两项对照口径：
//   · `firstHitMs` —— [SearchSession.firstHitElapsed]（发起 → 首条命中到泵口，
//     含 isolate 消息往返）：「首屏结果」埋点，阈值 **1500ms**；
//   · `maxGapMs` —— 主 isolate 心跳（Timer.periodic 10ms）最大打点间隔，
//     **含收尾间隔**、整窗无打点按整窗计（`perf_bench.dart` 同款口径，
//     微任务链饿死定时器的连续阻塞不得漏计）：「UI 卡顿」埋点，阈值 **16ms**
//     量级。搜索跑后台 isolate 时主 isolate 只收消息，间隙应近似空闲水平。
//
// 路径口径：EPUB / TXT 给得出 `searchSpec` → 走**后台重建**路径
// （`SearchSession.start(spec: …)`，与产品一致）；输出 `usedIsolate` 确认。
// `hits` 顺带对表验收①「命中数与实际出现次数一致」（稀有词查询可人工推演）。
//
// 用法：
//   dart run tool/gen_perf_fixtures.dart <目录>
//   dart run tool/search_bench.dart <目录> <样本> <标签> [查询词] [轮数]
//     例：dart run tool/search_bench.dart %TEMP%\mreader_perf big_bodies.epub after
//         dart run tool/search_bench.dart %TEMP%\mreader_perf big_bodies.epub rare 第1章第1段 3
//
// 查询词缺省 = 每样本的「稀有词」（人工推演恰 1 命中）：
//   · big_bodies.epub  → 「第1章第1段」（每段模板 `第N章第M段…`，仅 N=M=1 一段命中；
//     「第1章第10段」等不含该子串）；
//   · big_20mb.txt     → 「这是第1章的第1段」（每段模板 `这是第N章的第M段…`，唯一）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mreader/format/book_source.dart';
import 'package:mreader/task/search_session.dart';

/// 1 MiB。
const int _mib = 1024 * 1024;

/// 每样本的默认查询词（人工推演恰 1 命中，对表验收①）。
const Map<String, String> _defaultQuery = <String, String>{
  'big_bodies.epub': '第1章第1段',
  'big_20mb.txt': '这是第1章的第1段',
  'big_320.epub': '第1章第1段',
  'long_chapter.epub': '第1段',
};

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'usage: dart run tool/search_bench.dart <dir> <fixture> <label> '
      '[query] [iterations]',
    );
    exitCode = 2;
    return;
  }
  final String dir = args[0];
  final String fixture = args[1];
  final String label = args[2];
  final String query =
      args.length > 3 ? args[3] : (_defaultQuery[fixture] ?? '第1章第1段');
  final int iterations = args.length > 4 ? (int.tryParse(args[4]) ?? 3) : 3;

  final File file = File('$dir${Platform.pathSeparator}$fixture');
  if (!file.existsSync()) {
    stdout.writeln('SEARCH[$label] $fixture MISSING (${file.path})');
    return;
  }
  final Uint8List bytes = file.readAsBytesSync();
  // 与 `DartEpubSource.searchSpec` / `DartTxtSource.searchSpec` 返回值等价
  // （两者都是 SearchBookSpec(fileName, bytes)），直接构造省一次开源。
  final SearchBookSpec spec = SearchBookSpec(fileName: fixture, bytes: bytes);

  final List<int> firstHits = <int>[];
  final List<int> totals = <int>[];
  int firstEventMs = 0;
  int maxGap = 0;
  int hitsSeen = 0;
  bool usedIsolate = false;

  for (int i = 0; i < iterations; i++) {
    // 主 isolate 心跳（阈值 4「单帧 ≤ 16ms」口径）：搜索全窗口的最大打点间隔。
    int iterMaxGap = 0;
    DateTime lastBeat = DateTime.now();
    final Timer beat = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final DateTime now = DateTime.now();
      final int gap = now.difference(lastBeat).inMilliseconds;
      if (gap > iterMaxGap) iterMaxGap = gap;
      lastBeat = now;
    });

    final Stopwatch sw = Stopwatch()..start();
    final SearchSession session =
        SearchSession.start(query: query, spec: spec);
    int hits = 0;
    session.events.listen(
      (SearchEvent event) {
        if (event.hit != null) hits++;
      },
      // 业务错误不该出现在合法样本上；出错也照常收尾计时（下方 done 兜底）。
      onError: (Object _) {},
    );
    try {
      await session.done;
    } catch (_) {
      // 同上：错误已由流侧吞掉，这里只保证循环继续。
    }
    sw.stop();
    beat.cancel();
    // 收尾间隔（perf_bench 同款）：窗口末 − 最后打点；整窗无打点 = 整窗时长。
    final int tailGap = DateTime.now().difference(lastBeat).inMilliseconds;
    if (tailGap > iterMaxGap) iterMaxGap = tailGap;
    if (iterMaxGap > maxGap) maxGap = iterMaxGap;

    totals.add(sw.elapsedMilliseconds);
    final int? firstHit = session.firstHitElapsed?.inMilliseconds;
    if (firstHit != null) firstHits.add(firstHit);
    firstEventMs = session.firstEventElapsed?.inMilliseconds ?? 0;
    hitsSeen = hits;
    usedIsolate = session.usedIsolate;
  }

  totals.sort();
  firstHits.sort();
  final String firstHitPart = firstHits.isEmpty
      ? 'firstHitMs=none' // 全书零命中（默认查询词不会；自定义查询可能）
      : 'firstHitMinMs=${firstHits.first} '
          'firstHitMedianMs=${firstHits[firstHits.length ~/ 2]}';
  stdout.writeln(
    'SEARCH[$label] $fixture '
    'query=$query '
    'hits=$hitsSeen '
    'usedIsolate=$usedIsolate '
    'iters=$iterations '
    '$firstHitPart '
    'firstEventMs=$firstEventMs '
    'totalMinMs=${totals.first} '
    'totalMedianMs=${totals[totals.length ~/ 2]} '
    'maxGapMs=$maxGap '
    'fileMB=${(bytes.length / _mib).toStringAsFixed(2)}',
  );
}
