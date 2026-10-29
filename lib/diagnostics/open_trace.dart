// 「书架点书卡 → 阅读页看到书」的**端到端链路追踪**。
//
// 为什么需要它：既有 [PerfLog] 埋点只覆盖链路中段，两头都缺——**缺头**：书架侧只有
// `open.readBytes` / `open.sniff` 两个孤立点，没有「用户按下那一瞬」的原点，算不出
// 「点下到第一帧到底多久」；**缺尾**：阅读侧 `reader.ready` 打在 `_ready = true` 的
// setState **之后立刻**，此刻正文**还没被 build / layout / paint**，「ready 很快」与
// 「看到书很快」是两件事。本模块补上这两个缺口：记录**按下时刻**并量到**首帧真正
// 上屏**（`addPostFrameCallback` + 首帧 `FrameTiming`），输出 `open.total` 汇总行并
// 逐段打点，`adb logcat` 一眼看出瓶颈段落。
//
// 读数口径：`open.total` = **用户按下书卡 → 第一帧上屏**（用户真实感知的等待）；
// `open.sinceReady` = `reader.ready` → 首帧上屏（**渲染段**，纯 build / layout / paint，
// 这段长说明是渲染 / 排版慢而非解析慢）；`open.firstFrame` 额外带首帧 `FrameTiming`
// （build / raster 毫秒），区分「一帧画太久」（raster 超 16ms）与「等太久」（多帧累积）。
// ⚠️ `reader.ready` 之后的耗时**必须**分两段看——`open.sinceReady` 才是渲染成本，
// 二者相加才是用户等待；只看 `reader.ready` 会严重低估。
//
// 本模块**只观察、不分支**（同 [PerfLog] 口径）：产品逻辑不得依赖它的任何输出。
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'perf_log.dart';

/// 开书链路追踪（一次开书一个实例）。生命周期：[begin] → 若干 [mark]/[step] →
/// [attachFirstFrameProbe] → [report]；未调用 [attachFirstFrameProbe] 就 [report] 时，
/// 只汇总到最后一个已记录段落。
class OpenTrace {
  OpenTrace._({required this.bookId, required this.title});

  /// 书库 `bookId`（跨文件串联用；同书重开复用同一 id 便于聚类）。
  final String bookId;

  /// 书名（日志可读性；含空格 / 中文，故各字段按 `k=v` 输出时需引号约定）。
  final String title;

  /// 按下书卡的时刻（perf 计时原点）。
  final Stopwatch _clock = Stopwatch()..start();

  /// 已打点的段落名 → 距按下时刻的毫秒数（保持插入序）。
  final Map<String, int> _stamps = <String, int>{};

  /// 逐段耗时（毫秒），保持打点顺序。与 [_stamps] 分开存的原因：`step` 自带**权威**
  /// 段耗时（`Stopwatch` 差值），若用累计 `at` 反推，多段落同毫秒时会算出 0ms 被丢弃
  /// ——实测 `readBytes` 与紧随其后的 mark 同毫秒，汇总行恰好丢掉最该看见的那段。
  /// 故 `step` 记自己的 `ms`，只有 `mark` 才用 `at` 反推。
  final List<(String, int)> _segments = <(String, int)>[];

  /// 上一打点的累计毫秒（供 [mark] 反推段耗时）。
  int? _lastAt;

  /// 首帧探针是否已挂（重复调用只生效一次）。
  bool _probeAttached = false;

  /// 是否已汇总输出 [open.total]（防重复打印）。
  bool _reported = false;

  /// 是否已汇总输出 [open.chain]（防重复打印）。
  bool _chainReported = false;

  /// 当前距按下时刻的毫秒数。
  int get elapsedMs => _clock.elapsedMilliseconds;

  /// 开始一次开书追踪（**必须在用户按下的第一时间调用**，越晚越不准）。
  static OpenTrace begin({required String bookId, required String title}) {
    final OpenTrace trace = OpenTrace._(bookId: bookId, title: title);
    PerfLog.mark('open.begin',
        'book=${_q(title)} id=${_q(bookId)}');
    return trace;
  }

  /// 打一个瞬时段落（记录距按下时刻的累计毫秒）。[phase] 用点分小段命名（`tap` /
  /// `pushed` / `routeInit` / `ready` / `firstFrame` / `restoreEnd`），段耗时按
  /// 「距上一点点的差值」记。
  void mark(String phase, [String detail = '']) {
    final int at = elapsedMs;
    final int delta = at - (_lastAt ?? 0);
    _lastAt = at;
    _stamps[phase] = at;
    _segments.add((phase, delta));
    PerfLog.mark('open.$phase',
        'at=${at}ms${detail.isEmpty ? '' : ' $detail'}');
  }

  /// 打一个耗时段落（[ms] 为该段自身耗时，附加累计 [at] 便于排序定位）。
  /// 段耗时用**权威的 [ms]** 而非累计差值——见 [_segments] 的说明。
  void step(String phase, int ms, [String detail = '']) {
    final int at = elapsedMs;
    _lastAt = at;
    _stamps[phase] = at;
    _segments.add((phase, ms));
    PerfLog.step('open.$phase', ms,
        'at=${at}ms${detail.isEmpty ? '' : ' $detail'}');
  }

  /// 挂首帧探针：从**此刻起的第一帧**渲染完成后采集 build/raster 时序，在该帧的
  /// `addPostFrameCallback` 里落 `open.firstFrame` 与 `open.total`。**幂等**（重复
  /// 调用只生效一次，避免多帧被重复统计）。调用时机：`_ready = true` 的 `setState`
  /// **之后立刻**——此时已排入一帧，回调拿到的就是「正文第一次真正上屏」那一帧。
  void attachFirstFrameProbe() {
    if (_probeAttached) return;
    _probeAttached = true;

    // 帧时序：build/raster 的权威口径（比 addPostFrameCallback 多了 GPU 段）。
    List<FrameTiming>? firstTimings;
    void onTimings(List<FrameTiming> timings) {
      if (firstTimings != null || timings.isEmpty) return;
      firstTimings = timings;
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      _emitFirstFrame(firstTimings!);
    }

    SchedulerBinding.instance.addTimingsCallback(onTimings);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      // 兜底：若帧时序回调（某些平台/首帧不回调）没来，仍要给出 firstFrame 与
      // total，否则这条链路就断在最关键的尾段。
      if (firstTimings == null) {
        SchedulerBinding.instance.removeTimingsCallback(onTimings);
        _emitFirstFrame(const <FrameTiming>[]);
      }
    });
  }

  void _emitFirstFrame(List<FrameTiming> timings) {
    if (_reported) return;
    final int at = elapsedMs;
    _stamps['firstFrame'] = at;
    if (timings.isEmpty) {
      PerfLog.mark('open.firstFrame', 'at=${at}ms timings=none');
    } else {
      // 单帧（开书首帧通常只有一帧）四项耗时；raster 超 16ms 即为「一帧画太久」。
      final FrameTiming t = timings.first;
      PerfLog.mark('open.firstFrame',
          'at=${at}ms build=${_ms(t.buildDuration)} '
          'raster=${_ms(t.rasterDuration)} '
          'totalSpan=${_ms(t.totalSpan)} '
          'over16ms=${t.rasterDuration.inMicroseconds > 16000}');
    }
    report();
  }

  /// 输出一条汇总行：[open.total]（按下→上屏）与各段落耗时。幂等（只打一次）。
  /// 逐段落用 `d1=..ms d2=..ms` 形式给出**段间差值**（而非累计值），便于直接看出
  /// 「哪一段吃了最多时间」。
  void report() {
    if (_reported) return;
    _reported = true;
    _emitSummary('open.total', includeSettle: false);
  }

  /// 追加一条**全链路**汇总行 [open.chain]：含恢复校正落定（`restoreEnd`）。与 [report]
  /// 的分工：`open.total` 量「按下→看到书」，本行量「按下→内容停在目标段落」（含恢复
  /// 校正，即用户抱怨的「打开后还在跳」）。**看差异**才有诊断价值：`chain` 远大于
  /// `total` ⇒ 位置在动；两者接近 ⇒ 首帧之后的校正很快。幂等（只打一次 `open.chain`）。
  void reportChain() {
    if (_chainReported) return;
    _chainReported = true;
    _emitSummary('open.chain', includeSettle: true);
  }

  void _emitSummary(String name, {required bool includeSettle}) {
    final int? readyAt = _stamps['ready'];
    final int? firstAt = _stamps['firstFrame'];
    final int? restoreAt = _stamps['restoreEnd'];
    // `open.total` 的口径是「看到书」⇒ 终点取 firstFrame；即便此刻 restoreEnd
    // 已被记录也不并入（否则 total 会被后面的校正耗时污染，与口径不符）。
    // 两个分支都非空，故 `end` 推断为非空 `int`。
    final int end = includeSettle
        ? (restoreAt ?? firstAt ?? elapsedMs)
        : (firstAt ?? elapsedMs);
    final List<String> deltas = _deltas();

    PerfLog.mark(
      name,
      'at=${end}ms book=${_q(title)}'
          '${readyAt == null ? '' : ' ready=${readyAt}ms'}'
          '${firstAt == null ? '' : ' firstFrame=${firstAt}ms'}'
          '${readyAt != null && firstAt != null ? ' render=${firstAt - readyAt}ms' : ''}'
          // total→chain 的差值 = 首帧上屏之后再花多久才停在目标段落。
          // 只在 chain 行出现（total 的口径不含它）。
          '${includeSettle && firstAt != null && restoreAt != null ? ' settle=${restoreAt - firstAt}ms' : ''}'
          '${deltas.isEmpty ? '' : ' ${deltas.join(' ')}'}',
    );
  }

  /// 逐段差值（`ready=140ms` 形式），跳过 0ms 的瞬时点以免噪声淹没真信号。
  List<String> _deltas() {
    final List<String> out = <String>[];
    for (final (String, int) seg in _segments) {
      if (seg.$2 > 0) out.add('${seg.$1}=${seg.$2}ms');
    }
    return out;
  }

  /// 值含空格时加引号，避免 `k=v` 解析歧义。
  static String _q(String value) =>
      value.contains(' ') ? '"$value"' : value;

  /// 毫秒数（保留一位小数；`FrameTiming` 是微秒精度，整数会丢掉亚毫秒段）。
  static String _ms(Duration d) =>
      (d.inMicroseconds / 1000).toStringAsFixed(1);
}
