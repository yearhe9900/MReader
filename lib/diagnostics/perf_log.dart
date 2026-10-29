// 开书 / 滚动链路的**耗时日志**（零依赖、纯 Dart、可进 isolate）。
//
// 用途：把「书架点击 → 读文件 → 解析 → 定位目标章 → 首帧 → 恢复校正 → 后台补齐」
// 全链路逐段打点，真机跑一遍 `adb logcat` 即可看出秒级耗时花在哪一步。埋点前缀即
// 链路段：`open.*` 开书准备；`reader.*` 阅读页 `_open`；`restore.*` 程序化滚动校正；
// `autofill.*` 后台补齐；`layout.*` 布局突变重锚与占位高刷新；`nav.*` 目录 / 跳转；
// `txt.*` / `epub.*` 解析源内部阶段（含后台 isolate 内的打印）。
//
// 输出通道：`print` → stdout → Android logcat 的 `I/flutter` 行（`adb logcat -s flutter`），
// 同时留内存 [PerfLog.records]（环形上限，供测试断言）；isolate 内的 `print` 同样落
// stdout，混排在同一条时间线上。
//
// 读数口径（重要）：行格式 `[perf] <名字> <毫秒>ms  k=v k=v …`，瞬时事件（[PerfLog.mark]）
// 无毫秒段；首行 `[perf] session product=…` 标**构建形态**——`product=false` 是
// debug/profile（JIT + 断言，普遍比 release AOT 慢数倍），**读任何数字前先看这一行**，
// 否则会把 debug 档的慢当成产品问题；计时用 [Stopwatch]（墙上时钟），不受 FakeAsync
// 测试区影响，测试可照常跑。
//
// 开关：默认开，`--dart-define=MREADER_PERF_LOG=false` 可整体静音。本组件**不得**被
// 产品逻辑依赖（只许观察，不许分支）。
class PerfLog {
  PerfLog._();

  /// 总开关（默认开；`--dart-define=MREADER_PERF_LOG=false` 静音）。
  static const bool enabled =
      bool.fromEnvironment('MREADER_PERF_LOG', defaultValue: true);

  /// 内存留档（环形上限 [maxRecords]；测试可断言）。
  static final List<String> records = <String>[];

  /// [records] 环形上限（长会话防无界增长）。
  static const int maxRecords = 500;

  static bool _sessionLogged = false;

  /// 瞬时事件：`[perf] <event>  k=v …`。
  static void mark(String event, [String detail = '']) {
    _emit(detail.isEmpty ? event : '$event  $detail');
  }

  /// 耗时事件：`[perf] <name> <ms>ms  k=v …`。
  static void step(String name, int ms, [String detail = '']) {
    _emit(detail.isEmpty ? '$name ${ms}ms' : '$name ${ms}ms  $detail');
  }

  /// 开一个计时器；调用 `done()` 落一条 [step]。
  static PerfWatch watch(String name) => PerfWatch._(name, Stopwatch()..start());

  static void _emit(String body) {
    if (!enabled) return;
    if (!_sessionLogged) {
      _sessionLogged = true;
      final String header = '[perf] session  '
          'product=${const bool.fromEnvironment('dart.vm.product')}';
      records.add(header);
      // ignore: avoid_print —— 诊断日志的落点就是 stdout（Android logcat `I/flutter`）。
      print(header);
    }
    final String line = '[perf] $body';
    if (records.length >= maxRecords) records.removeAt(0);
    records.add(line);
    // ignore: avoid_print
    print(line);
  }
}

/// [PerfLog.watch] 的句柄：`Stopwatch` 薄封装，`done()` 打点并停表。
class PerfWatch {
  PerfWatch._(this.name, this._stopwatch);

  /// 打点名（如 `reader.load`）。
  final String name;

  final Stopwatch _stopwatch;

  /// 已耗时（毫秒）。
  int get elapsedMs => _stopwatch.elapsedMilliseconds;

  /// 停表并落一条 `name <ms>ms  detail`。
  void done([String detail = '']) {
    _stopwatch.stop();
    PerfLog.step(name, _stopwatch.elapsedMilliseconds, detail);
  }
}
