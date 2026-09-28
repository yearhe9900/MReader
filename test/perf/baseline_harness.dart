// 纯 Dart 基线测量 harness（`M35-T02` / 架构 §H.1·§H.2 / PRD §15.6.3）。
//
// ## 它测什么（口径写死，不许改口径凑结论）
//
// 逐条对齐 §H.1「测量协议」：
//   · **计时对象** = 纯解析入口（`load()` / `chapters()` / `content(i)`），
//     从「bytes 已在内存」到「return」——**不含 IO**（IO 单独测一次「冷读」作参考，不参与判定）；
//   · **含解压**（解压是这些能力的主体），**不含渲染**；
//   · **N = 7 取中位数**，另记 min / max / p90；**先跑 1 次不计入**（JIT / 首次分配）；
//   · **热态判定**；内存报**峰值**（`ProcessInfo.currentRss` 采样点即峰值近似，§13.2 口径）；
//   · **设备**：Android 主力机 = 唯一判定基准（PRD 指定）。桌面/开发机也测，
//     但 `judging: false`（§H.3：桌面只是**哨兵**，用它判定会「永远测不过阈值」）。
//
// ## 样本：**生成的大文件样本 + 真实脏书**（任务书原文要求两者都测）
//
//   · 生成样本由 `tool/gen_perf_fixtures.dart` 写到 `MREADER_PERF_DIR`（默认系统临时目录，不入库）；
//   · 真实脏书从 `tmp_book/` 扫（仓库已 gitignore；**不存在时该部分自动不声明**，不红不阻塞）。
//
// ## 成本边界（§15.6.2 处置 4）与**本实现暴露的口径缺陷（如实登记）**
//
//   2a = zip 解压 + container.xml / OPF 解析，**产出章节骨架**（含章节表）；
//   2b = 各章 XHTML → 段落 / 图片页。
//   → 本 harness 的 2a = `load()` + `chapters()`；2b = 全书 `content(i)` 之和；
//     **合计 = 两者相加**，覆盖「单本解析」原口径。
//
//   ⚠️ **口径重叠在「无目录书」上是重复计数，不是中性重叠**（T02 首跑实测暴露，勿轻信早前说法）：
//   本工程的 EPUB 解析在 toc 为空时于 `load()` 内做 `flatTitles` 标题预取
//   （**逐章解压 + XHTML 解析**，性质属 2b）。因此对无目录样本：
//
//     2a（= load + chapters）≈ 真 2a + F      （F = flatTitles 预取，2b 性质）
//     2b（= 全书 content）   = 真 2b
//     合计                   ≈ 真合计 + F     ← **高估**，F 被算了两遍
//
//   实测佐证（`big_bodies.epub`，无目录）：2a = 6098ms、2b = 7722ms——2a 若真是
//   「zip + OPF 产出骨架」，量级应是数十毫秒（对比有目录样本），6098ms 只可能来自逐章 XHTML 解析。
//
//   **因此判定补一条无条件下界**：因为 2b 的测量**只计 `content(i)` 循环**（`chapters()` 已在外层
//   调用并被缓存），它等于真 2b；又因真 2a ≥ 0，故 **真合计 ≥ 2b 分层值**。留档同时给出
//   「上界（分层和，判定口径）」与「下界（= 2b 分层值）」，并在结论里写明 over 是否**与口径无关**：
//   · 下界已越死区 → `over` 无条件成立；
//   · 仅上界越死区 → `over` 依赖上界口径，**必须补一个有目录样本复核**再据此开工。
//
// ## 怎么跑（负责人手动执行）
//
//   dart run tool/gen_perf_fixtures.dart "$TMPDIR/mreader_perf"       # 先生成样本
//   MREADER_PERF_BENCH=1 \
//   MREADER_PERF_DIR="$TMPDIR/mreader_perf" \
//   MREADER_PERF_DEVICE="<机型>" \
//   MREADER_PERF_OUT=docs/perf-baseline/2026-09-28-<机型>.json \   # 可选：自动落盘
//   flutter test test/perf/baseline_harness.dart                    # 再测
//   → 输出人类可读行 + 每能力一行 `BASELINE_JSON{...}`（§H.2 固定 schema）。
//   → 置了 `MREADER_PERF_OUT` 时另写一份信封 JSON（`{generatedAt, device, os, judging,
//     fixtures, records[]}`），供**人工 commit** 进 `docs/perf-baseline/`（§H.2 要求人工留档，
//     自动落盘只是免去手抄出错，commit 仍由人做）。
//   → 真机 MOBI 样本另用 `MREADER_PERF_MOBI=<真实 azw3 路径>`。
//
// **默认不置 `MREADER_PERF_BENCH=1` 时整组 skip**：它是重任务（7 轮 × 全书解压 + 8 次全书搜索，
// 本机实测约 5 分钟），不能拖慢 `reader` 分组的日常回归。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/format/dart_txt_source.dart';
import 'package:mreader/highperf/high_perf_capability.dart';
import 'package:mreader/task/isolate_runner.dart';
import 'package:mreader/task/search_session.dart';

import 'threshold_judge.dart';

/// 判定轮数（§H.1：N = 7 取中位数，另跑 1 次预热不计入）。
const int kBaselineIters = 7;

/// 真实脏书目录（仓库已 gitignore；不存在时只跑生成样本）。
const String kRealBookDir = 'tmp_book';

/// 是否启用（重任务默认关）。
final bool kBenchEnabled =
    Platform.environment['MREADER_PERF_BENCH'] == '1';

/// 生成样本目录（`tool/gen_perf_fixtures.dart` 的产物；不入库）。
final String kFixtureDir = Platform.environment['MREADER_PERF_DIR'] ??
    '${Directory.systemTemp.path}${Platform.pathSeparator}mreader_perf';

/// 设备标签（真机判定时由负责人用 `MREADER_PERF_DEVICE` 写明机型）。
final String kDeviceLabel = Platform.environment['MREADER_PERF_DEVICE'] ??
    (Platform.isAndroid ? 'Android 主力机（未标注机型）' : '开发机（未标注机型）');

/// 是否参与判定：**只有 Android 主力机**（§H.3 / PRD §15.6.3）。
final bool kJudging = Platform.isAndroid;

String get _osLabel =>
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

/// 单条用例自带的超时（5 分钟）。
///
/// harness 是重任务（**7 轮 × 全书解压**，候选 4 还是 8 次完整后台搜索），
/// runner 的默认超时不够；把它写在用例上，**不依赖调用方记得传 `--timeout`**
/// （同一文件另一条踩坑记录见 `test/test_config.dart`：CLI 默认值会被显式值压过）。
final Timeout kBenchTimeout = Timeout(const Duration(minutes: 5));

// ---------------------------------------------------------------------------
// 测量基础设施
// ---------------------------------------------------------------------------

/// 只在本 isolate 现跑的 runner（**测量专用**）。
///
/// 为什么需要它：`PERF-01` 把解析派进后台 isolate，`DartEpubSource` / `DartTxtSource`
/// 的公开入口因此含**建销成本**（秒级以下但与算法同量级）。阈值测的是**算法**
/// （§H.1「纯解析入口」），故测量时把派发换成现跑；真机跑的是同一份代码路径的算法部分。
/// 注入缝是既有的 `runner` 参数（测试早就用它注入 spy / 故障 runner），**不改产品代码**。
///
/// **候选 4 例外**：阈值 4 的口径是**真实用户路径**（含后台 isolate 与协议开销），
/// 那里不换 runner——见其分组注释。
class _LocalRunner extends IsolateRunner {
  const _LocalRunner();

  @override
  Future<R> run<M, R>(IsolateTask<M, R> task, M message, {String? debugLabel}) async =>
      task(message);

  @override
  Future<R> runWithFallback<M, R>(
    IsolateTask<M, R> task,
    M message, {
    String? debugLabel,
  }) async =>
      task(message);
}

/// 一个被测样本（生成的大文件样本 **或** `tmp_book/` 的真实脏书）。
class _Sample {
  const _Sample({
    required this.label,
    required this.file,
    required this.real,
  });

  /// 留档标签（= 文件名；生成样本与真实脏书同名不同源时靠 [real] 区分）。
  final String label;

  final File file;

  /// 是否真实脏书（`tmp_book/`）。
  final bool real;

  String get source => real ? kRealBookDir : '生成样本';

  /// 是否「大体量」样本——候选 4（全书搜索）只在体量够的样本上跑，
  /// 免得 KB 级生成样本刷出一堆无意义的 0ms 记录。
  bool get major => !real || file.lengthSync() >= 1000 * 1000;
}

/// 扫 `tmp_book/` 里指定扩展名的真实脏书（字典序稳定；目录不存在返回空）。
List<_Sample> _realSamples(String ext) {
  final Directory dir = Directory(kRealBookDir);
  if (!dir.existsSync()) return const <_Sample>[];
  final List<File> files = dir
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.toLowerCase().endsWith('.$ext'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  return <_Sample>[
    for (final File f in files)
      _Sample(label: f.uri.pathSegments.last, file: f, real: true),
  ];
}

/// 生成样本在 [kFixtureDir] 下的一个条目。
_Sample _generated(String name) => _Sample(
      label: name,
      file: File('$kFixtureDir${Platform.pathSeparator}$name'),
      real: false,
    );

/// 按 §H.1 协议重复测量 [once]（返回**本轮被测段**的耗时）。
///
/// 先预热 1 次不计入；再跑 [kBaselineIters] 次取样本。
Future<_Measured> _measureBytes(
  Uint8List bytes,
  _Sample sample,
  Future<int> Function() once,
) async {
  await once(); // 预热（JIT / 首次分配）
  final List<int> samples = <int>[];
  for (int i = 0; i < kBaselineIters; i++) {
    samples.add(await once());
  }
  return _Measured(
    samples: samples,
    bytesInMemory: bytes.lengthInBytes,
    coldReadMs: _coldReadMs(sample),
  );
}

/// 一次能力测量的原始结果。
class _Measured {
  _Measured({
    required this.samples,
    required this.bytesInMemory,
    required this.coldReadMs,
  });

  /// 每轮耗时（毫秒）。
  final List<int> samples;

  /// 输入字节数（热态）。
  final int bytesInMemory;

  /// 冷读一次（含 IO）的参考耗时——**不参与判定**（§H.1）。
  final int? coldReadMs;
}

/// 冷读耗时（含 IO；§H.1 单独记录、不参与判定）。样本不在盘上时返回 `null`。
int? _coldReadMs(_Sample sample) {
  if (!sample.file.existsSync()) return null;
  final Stopwatch stopwatch = Stopwatch()..start();
  sample.file.readAsBytesSync();
  stopwatch.stop();
  return stopwatch.elapsedMilliseconds;
}

/// 读样本（不存在返回 `null` → 该能力记「无可测基线」而不是失败）。
Uint8List? _readOf(_Sample sample) {
  if (!sample.file.existsSync()) return null;
  return sample.file.readAsBytesSync();
}

/// 计时一小段异步动作，返回毫秒。
Future<int> _timed(Future<void> Function() action) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  await action();
  stopwatch.stop();
  return stopwatch.elapsedMilliseconds;
}

// ---------------------------------------------------------------------------
// 留档
// ---------------------------------------------------------------------------

/// 本次运行产出的全部记录（`MREADER_PERF_OUT` 落盘用）。
final List<BaselineRecord> _records = <BaselineRecord>[];

/// 打印一条留档记录（人类可读 + 机读 JSON 两行），并收进本次运行清单。
void _emit(BaselineRecord record) {
  _records.add(record);
  stdout.writeln(
    '[${record.verdict}] 候选 ${record.thresholdNo}'
    '${record.sampleLabel.isEmpty ? '' : ' · ${record.sampleLabel}'}'
    ' | median=${record.median}ms min=${record.min} max=${record.max}'
    ' p90=${record.p90} 冷读=${record.coldReadMs ?? '—'}ms'
    ' | ${record.bytesInMemory ~/ 1024}KB',
  );
  stdout.writeln('  结论：${record.conclusion}');
  stdout.writeln('BASELINE_JSON${jsonEncode(record.toJson())}');
}

/// 组装留档记录（统一处理「判定 / 无可测基线」两种形态）。
///
/// **判定一律用中位数**（§H.1），不拿第一轮去判——口径漂移大多死在这一点上。
BaselineRecord _record({
  required ThresholdSpec? spec,
  required String wireId,
  required _Measured? measured,
  required String sampleLabel,
  String? conclusion,
  Map<String, Object?>? scale,
  List<String> extraNotes = const <String>[],
  int? thresholdNoOverride,
}) {
  final String? coldRead = measured?.coldReadMs?.toString();
  final List<String> baseNotes = <String>[
    if (coldRead != null) '冷读（含 IO）参考：${coldRead}ms（不参与判定，§H.1）',
    ..._desktopNote(),
  ];
  if (measured == null || spec == null) {
    return BaselineRecord(
      capability: wireId,
      device: kDeviceLabel,
      os: _osLabel,
      samples: const <int>[],
      bytesInMemory: 0,
      peakMemBytes: ProcessInfo.currentRss,
      conclusion: conclusion ?? '无可测基线（样本或前置条件缺失）',
      thresholdNo: spec?.no ?? thresholdNoOverride ?? 0,
      verdict: 'notMeasured',
      judging: kJudging,
      sampleLabel: sampleLabel,
      scale: scale,
      notes: <String>[...baseNotes, ...extraNotes],
    );
  }
  final int median = _median(measured.samples);
  final ThresholdDecision decision = judgeThreshold(
    spec,
    Duration(milliseconds: median),
    sampleLabel: sampleLabel,
    scaleMeasured: scale == null
        ? null
        : Duration(milliseconds: scale['measuredMs']! as int),
  );
  return BaselineRecord(
    capability: wireId,
    device: kDeviceLabel,
    os: _osLabel,
    samples: measured.samples,
    bytesInMemory: measured.bytesInMemory,
    peakMemBytes: ProcessInfo.currentRss,
    conclusion: decision.text,
    thresholdNo: spec.no,
    verdict: decision.verdict.name,
    judging: kJudging,
    coldReadMs: measured.coldReadMs,
    sampleLabel: sampleLabel,
    scale: scale,
    notes: <String>[...baseNotes, ...extraNotes],
  );
}

/// 中位数（毫秒）：奇数取中位、偶数取中间两者均值（四舍五入）。
int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final List<int> sorted = List<int>.of(values)..sort();
  final int mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

List<String> _desktopNote() => kJudging
    ? const <String>[]
    : const <String>[
        '本机为开发机 / 桌面：**仅作劣化哨兵，不作为判定基准**（§H.3）——'
            'PRD 阈值取自移动体验导向的 NF-P2 / NF-P3，桌面上判定会「永远测不过」',
      ];

/// 把某个样本的测量「失败」如实记成记录（脏书解析不了不该让整轮 bench 变红）。
void _emitMeasurementFailure({
  required ThresholdSpec? spec,
  required String wireId,
  required String sampleLabel,
  required Object error,
  int? thresholdNoOverride,
}) {
  _emit(_record(
    spec: spec,
    wireId: wireId,
    measured: null,
    sampleLabel: sampleLabel,
    conclusion: '测量失败（该样本被 `try` 捕获，不中断整轮）：'
        '${error.runtimeType}: $error',
    thresholdNoOverride: thresholdNoOverride,
  ));
}

/// 候选 2 的 2a / 2b 分层值（按样本标签累积）。
///
/// **合计才是触发口径**（§15.6.3 / v2.6 方案 A）：分层值只作归因与优先级指引。
/// 但「2a 含无目录书的 flatTitles 预取」会让简单相加**高估**，故判定时同时给
/// **下界 = 2b 分层值**、并在结论里写明 over 是否与口径无关（见文件头）。
final Map<String, Map<String, int>> _epubParts = <String, Map<String, int>>{};

void _putPart(String label, String key, int ms) =>
    _epubParts.putIfAbsent(label, () => <String, int>{})[key] = ms;

// ---------------------------------------------------------------------------
// 样本清单（声明期算一次，保证三组按键一致）
// ---------------------------------------------------------------------------

final List<_Sample> _epubList = <_Sample>[
  _generated('big_bodies.epub'),
  _generated('big_320.epub'),
  _generated('long_chapter.epub'),
  ..._realSamples('epub'),
];

final List<_Sample> _txtList = <_Sample>[
  _generated('big_20mb.txt'),
  ..._realSamples('txt'),
];

void main() {
  // 传 `null` 才是「不跳过」：空字符串会被 test 包当成**有 skip 理由**而照跳
  // （`Metadata` 里 `skip is String` 即成立），因此这里必须给 `String?` 而不是 `String`。
  final String? skipReason = kBenchEnabled
      ? null
      : '未启用：置 MREADER_PERF_BENCH=1 后单独运行（重任务不进日常分组回归）';

  tearDownAll(() {
    if (!kBenchEnabled) return;
    final String? out = Platform.environment['MREADER_PERF_OUT'];
    stdout.writeln('样本清单：生成 ${_epubList.where((s) => !s.real).length} EPUB + '
        '${_txtList.where((s) => !s.real).length} TXT；'
        '真实脏书 ${_epubList.where((s) => s.real).length} EPUB + '
        '${_txtList.where((s) => s.real).length} TXT（$kRealBookDir/）');
    if (out == null || out.isEmpty) {
      stdout.writeln('（未置 MREADER_PERF_OUT，记录仅打印在 stdout；'
          '留档请按 §H.2 人工粘贴进 docs/perf-baseline/ 并 commit）');
      return;
    }
    final File file = File(out);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'generatedAt': DateTime.now().toIso8601String(),
        'harness': 'test/perf/baseline_harness.dart',
        'iters': kBaselineIters,
        'device': kDeviceLabel,
        'os': _osLabel,
        'judging': kJudging,
        'fixtures': <String, Object?>{
          'dir': kFixtureDir,
          'realBookDir': kRealBookDir,
          'epub': <String>[for (final _Sample s in _epubList) '${s.label}${s.real ? '（真实脏书）' : '（生成）'}'],
          'txt': <String>[for (final _Sample s in _txtList) '${s.label}${s.real ? '（真实脏书）' : '（生成）'}'],
        },
        'records': <Map<String, Object?>>[
          for (final BaselineRecord r in _records) r.toJson(),
        ],
      }),
    );
    stdout.writeln('留档已写入：${file.path}（人工复核后 commit，§H.2）');
  });

  // -------------------------------------------------------------------------
  // 候选 2a · EPUB 解压层
  // -------------------------------------------------------------------------
  group('候选 2a · EPUB 解压层（load + chapters）', () {
    for (final _Sample sample in _epubList) {
      test('2a / ${sample.label}${sample.real ? '（真实脏书）' : ''}', () async {
        final Uint8List? bytes = _readOf(sample);
        if (bytes == null) {
          _emit(_record(
            spec: kThresholdSpecs[1],
            wireId: HighPerfCapability.epubDecompress.wireId,
            measured: null,
            sampleLabel: sample.label,
            conclusion: sample.real
                ? '样本缺失：$kRealBookDir/${sample.label} 不存在'
                : '样本缺失：先跑 `dart run tool/gen_perf_fixtures.dart "$kFixtureDir"`',
          ));
          return;
        }
        try {
          final _Measured measured = await _measureBytes(
            bytes,
            sample,
            () async {
              final DartEpubSource source = DartEpubSource(
                fileName: sample.label,
                bytes: bytes,
                runner: const _LocalRunner(),
              );
              // **只有 parse 段进计时**（§H.1「从 bytes 已在内存到 return」）；
              // `dispose()` 是生命周期收尾、不是解析工作，放在计时外。
              final int ms = await _timed(() async {
                await source.load();
                await source.chapters();
              });
              await source.dispose();
              return ms;
            },
          );
          _putPart(sample.label, 'a', _median(measured.samples));
          _emit(_record(
            spec: kThresholdSpecs[1],
            wireId: HighPerfCapability.epubDecompress.wireId,
            measured: measured,
            sampleLabel: '${sample.label}（2a 分层值，仅归因）',
            extraNotes: <String>[
              '来源：${sample.source}；2a 口径 = `load()` + `chapters()`'
                  '（含无目录书的 flatTitles 预取 → 对无目录样本是 2a 的**上界**）',
            ],
          ));
        } catch (error) {
          _emitMeasurementFailure(
            spec: kThresholdSpecs[1],
            wireId: HighPerfCapability.epubDecompress.wireId,
            sampleLabel: '${sample.label}（2a）',
            error: error,
          );
        }
      }, skip: skipReason, timeout: kBenchTimeout);
    }
  });

  // -------------------------------------------------------------------------
  // 候选 2b · EPUB 正文抽取层
  // -------------------------------------------------------------------------
  group('候选 2b · EPUB 正文抽取层（全书 content）', () {
    for (final _Sample sample in _epubList) {
      test('2b / ${sample.label}${sample.real ? '（真实脏书）' : ''}', () async {
        final Uint8List? bytes = _readOf(sample);
        if (bytes == null) {
          _emit(_record(
            spec: kThresholdSpecs[1],
            wireId: HighPerfCapability.epubDecompress.wireId,
            measured: null,
            sampleLabel: sample.label,
            conclusion: sample.real
                ? '样本缺失：$kRealBookDir/${sample.label} 不存在'
                : '样本缺失：先跑 `dart run tool/gen_perf_fixtures.dart "$kFixtureDir"`',
          ));
          return;
        }
        try {
          final _Measured measured = await _measureBytes(
            bytes,
            sample,
            () async {
              final DartEpubSource source = DartEpubSource(
                fileName: sample.label,
                bytes: bytes,
                runner: const _LocalRunner(),
              );
              // 章节表构建属 2a（口径见文件头），故先在外层取好、不进计时。
              final List<Chapter> chapters = await source.chapters();
              final int ms = await _timed(() async {
                for (int i = 0; i < chapters.length; i++) {
                  await source.content(i);
                }
              });
              await source.dispose();
              return ms;
            },
          );
          _putPart(sample.label, 'b', _median(measured.samples));
          _emit(_record(
            spec: kThresholdSpecs[1],
            wireId: HighPerfCapability.epubDecompress.wireId,
            measured: measured,
            sampleLabel: '${sample.label}（2b 分层值，仅归因）',
            extraNotes: <String>[
              '来源：${sample.source}；2b 口径 = 全书 `content(i)` 之和'
                  '（`chapters()` 在外层、已缓存 → 本值即真 2b，是**合计的无条件下界**）',
            ],
          ));
        } catch (error) {
          _emitMeasurementFailure(
            spec: kThresholdSpecs[1],
            wireId: HighPerfCapability.epubDecompress.wireId,
            sampleLabel: '${sample.label}（2b）',
            error: error,
          );
        }
      }, skip: skipReason, timeout: kBenchTimeout);
    }
  });

  // -------------------------------------------------------------------------
  // 候选 3 · TXT
  // -------------------------------------------------------------------------
  group('候选 3 · TXT 编码探测与分章', () {
    for (final _Sample sample in _txtList) {
      test('3 / ${sample.label}${sample.real ? '（真实脏书）' : ''}', () async {
        final Uint8List? bytes = _readOf(sample);
        if (bytes == null) {
          _emit(_record(
            spec: kThresholdSpecs[2],
            wireId: HighPerfCapability.txtChapterize.wireId,
            measured: null,
            sampleLabel: sample.label,
            conclusion: sample.real
                ? '样本缺失：$kRealBookDir/${sample.label} 不存在'
                : '样本缺失：先跑 `dart run tool/gen_perf_fixtures.dart "$kFixtureDir"`',
          ));
          return;
        }
        try {
          final _Measured measured = await _measureBytes(
            bytes,
            sample,
            () async {
              final DartTxtSource source = DartTxtSource(
                fileName: sample.label,
                bytes: bytes,
                runner: const _LocalRunner(),
              );
              final int ms = await _timed(() async {
                await source.load();
                await source.chapters();
              });
              await source.dispose();
              return ms;
            },
          );
          _emit(_record(
            spec: kThresholdSpecs[2],
            wireId: HighPerfCapability.txtChapterize.wireId,
            measured: measured,
            sampleLabel: sample.label,
            extraNotes: <String>[
              '来源：${sample.source}；口径 = `load()`（编码探测 + 全量解码 + 分章）+ `chapters()`',
              if (sample.real)
                '真实脏书体量未必等于阈值口径的 20MB——本值供「同量级比对」，'
                    '结论按 MREADER_PERF_DEVICE 标注的机型在 docs/perf-baseline/ 里裁',
            ],
          ));
        } catch (error) {
          _emitMeasurementFailure(
            spec: kThresholdSpecs[2],
            wireId: HighPerfCapability.txtChapterize.wireId,
            sampleLabel: sample.label,
            error: error,
          );
        }
      }, skip: skipReason, timeout: kBenchTimeout);
    }
  });

  // -------------------------------------------------------------------------
  // 候选 4 · 全书搜索首屏
  // -------------------------------------------------------------------------
  group('候选 4 · 全书搜索首屏（真实路径：后台 isolate）', () {
    for (final _Sample sample in _epubList.where((_Sample s) => s.major)) {
      test('4 / ${sample.label}${sample.real ? '（真实脏书）' : ''}', () async {
        final Uint8List? bytes = _readOf(sample);
        if (bytes == null) {
          _emit(_record(
            spec: kThresholdSpecs[3],
            wireId: HighPerfCapability.fullTextSearch.wireId,
            measured: null,
            sampleLabel: sample.label,
            conclusion: '样本缺失：$kRealBookDir/${sample.label} 不存在',
          ));
          return;
        }
        try {
          final String? query = await _queryFor(sample, bytes);
          if (query == null) {
            _emit(_record(
              spec: kThresholdSpecs[3],
              wireId: HighPerfCapability.fullTextSearch.wireId,
              measured: null,
              sampleLabel: sample.label,
              conclusion: '未测量：无法从该样本派生搜索词（无章节 / 首章无可取正文）',
            ));
            return;
          }
          // 阈值 4 的口径是**真实用户路径**（含后台 isolate 建销与协议开销），故**不换 runner**。
          final List<int> samples = <int>[];
          int? warmUpMs;
          for (int i = 0; i <= kBaselineIters; i++) {
            final SearchSession session = SearchSession.start(
              query: query,
              spec: SearchBookSpec(fileName: sample.label, bytes: bytes),
            );
            await session.done;
            final int ms = session.firstHitElapsed?.inMilliseconds ?? -1;
            if (i == 0) {
              warmUpMs = ms; // 预热轮不进样本
            } else {
              samples.add(ms);
            }
          }
          final _Measured measured = _Measured(
            samples: samples,
            bytesInMemory: bytes.lengthInBytes,
            // 冷读 = 真「把文件读进内存」的耗时（§H.1），**不是**预热轮的首屏值
            // ——T02 首跑把它错填成预热值（8082ms），标签与语义都不符，已修。
            coldReadMs: _coldReadMs(sample),
          );
          // **零命中必须判 notMeasured，不能当有效样本**：`firstHitElapsed` 为 null 时
          // 记的是 -1，而 -1 < 1500ms 会被三段式判成 `under`（「不上 Rust」）——那是
          // 一个**假结论**（根本没测到东西）。T02 首跑就这么错判过两条。
          if (samples.any((int s) => s < 0)) {
            _emit(_record(
              spec: null,
              wireId: HighPerfCapability.fullTextSearch.wireId,
              measured: null,
              sampleLabel: sample.label,
              conclusion: '未判定：搜索词 ${jsonEncode(query)} 在该样本**零命中**'
                  '（`firstHitElapsed` 为 null，全体样本记 -1）→ 未构成首屏口径测量；'
                  '换词后重跑，**不得**把 -1 当成「< 1.5s 达标」',
              thresholdNoOverride: 4,
            ));
            return;
          }
          _emit(_record(
            spec: kThresholdSpecs[3],
            wireId: HighPerfCapability.fullTextSearch.wireId,
            measured: measured,
            sampleLabel: '${sample.label}（首屏命中耗时）',
            extraNotes: <String>[
              '来源：${sample.source}；搜索词 = ${jsonEncode(query)}'
                  '${sample.real ? '（从该书首章正文派生，不冻结任何作品专有词）' : '（与 docs/perf-baseline/search.md 同词，便于对比）'}',
              '命中数 > 0（零命中的样本会改判 notMeasured，不进判定）',
              '预热轮首屏 = ${warmUpMs ?? '—'}ms（不计入样本）',
              '链路：`SearchSession.start(spec:)` → 后台 isolate 重建源 → 首个命中'
                  '（含建销；阈值 4 测的就是这条真实路径）',
            ],
          ));
        } catch (error) {
          _emitMeasurementFailure(
            spec: kThresholdSpecs[3],
            wireId: HighPerfCapability.fullTextSearch.wireId,
            sampleLabel: sample.label,
            error: error,
          );
        }
      }, skip: skipReason, timeout: kBenchTimeout);
    }

    test('4 · 单帧口径说明（不判定）', () {
      // 阈值 4 的后半是「搜索期间出现单帧 > 16ms」。M2b-T04 已实测：Windows 本底
      // 心跳 15~25ms，**不具 16ms 区分力**（`docs/perf-baseline/search.md` §3）。
      // 真机上该口径需 Flutter 帧回调 + DevTools 时间线才有意义 → 本轮**不做判定**，
      // 如实登记 `notMeasured`，而不是用一个测不出结论的方法凑一个数字。
      _emit(_record(
        spec: null,
        wireId: HighPerfCapability.fullTextSearch.wireId,
        measured: null,
        sampleLabel: '单帧 > 16ms',
        conclusion: '未判定：帧时间口径需真机帧回调 / 时间线取证（'
            'Windows 本底 15~25ms 无区分力，见 docs/perf-baseline/search.md §3）',
        scale: <String, Object?>{'thresholdNo': 4, 'condition': '单帧 > 16ms'},
        thresholdNoOverride: 4,
      ));
    }, skip: skipReason, timeout: kBenchTimeout);
  });

  // -------------------------------------------------------------------------
  // 候选 1 · MOBI/AZW3
  // -------------------------------------------------------------------------
  group('候选 1 · MOBI/AZW3 解压（需真实样本）', () {
    test('1 · 真实 AZW3（MREADER_PERF_MOBI 指定路径）', () {
      final String? mobiPath = Platform.environment['MREADER_PERF_MOBI'];
      final List<_Sample> azw =
          _realSamples('azw3') + _realSamples('mobi') + _realSamples('azw');
      final String inventory = azw.isEmpty
          ? '$kRealBookDir/ 内未见 .azw3/.mobi/.azw'
          : '$kRealBookDir/ 内可见 ${azw.length} 个：'
              '${azw.map((s) => s.label).join('、')}';
      if (mobiPath == null || mobiPath.isEmpty) {
        // 合成 20MB AZW3 不现实（KF8 + Huff/CDIC 生成器本身就是一个项目），
        // 因此本项**只接受真实样本路径**。已测过的下界见 `docs/perf-baseline/mobi.md`
        // （M2b-T05 原型探针，24MB 真实样本：open 12.7ms / full 23.7~176.5ms）。
        _emit(_record(
          spec: kThresholdSpecs[0],
          wireId: HighPerfCapability.mobiDecompress.wireId,
          measured: null,
          sampleLabel: '真实 AZW3（未提供）',
          conclusion: '未测量：MOBI 解析器属 M4-T07（FMT-04），本 harness 只做'
              '「样本可达性」登记；已有下界见 docs/perf-baseline/mobi.md'
              '（M2b-T05：24MB 样本 open 12.7ms / full 23.7~176.5ms，'
              '距阈值 1 的 3s / 2s 共 1~2 个数量级）→ **阈值 1 暂无「纯 Dart 超标」信号**，'
              '但按 PRD §15.6.2 该候选的最终基线在 M4，**不得据此提前实施 Rust**',
          scale: <String, Object?>{
            'thresholdNo': 1,
            'condition': kThresholdSpecs[0].condition,
            'priorLowerBoundMs': 176,
          },
          extraNotes: <String>['样本清单：$inventory'],
        ));
        return;
      }
      _emit(_record(
        spec: kThresholdSpecs[0],
        wireId: HighPerfCapability.mobiDecompress.wireId,
        measured: null,
        sampleLabel: mobiPath,
        conclusion: '未测量：MOBI 解析器属 M4-T07（FMT-04），解析链尚未落地 →'
            '本时点没有可测的纯 Dart 入口；下界见 docs/perf-baseline/mobi.md',
        extraNotes: <String>['样本清单：$inventory'],
      ));
    }, skip: skipReason, timeout: kBenchTimeout);
  });

  // -------------------------------------------------------------------------
  // 候选 5 · BM25
  // -------------------------------------------------------------------------
  group('候选 5 · BM25 索引（基线待 AI 落地）', () {
    test('5 · 索引构建 / 内存倍率', () {
      _emit(_record(
        spec: null,
        wireId: HighPerfCapability.bm25Index.wireId,
        measured: null,
        sampleLabel: '单本 20MB 书',
        conclusion: '未测量：依赖 AI 跟书问答（AI-06）的纯 Dart 基线，'
            'PRD §15.6 明文「阈值 5 基线待 AI 后补」（M3 殿后）→'
            '**本时点不得实施 Rust 版本**（RUST-06 反向硬约束）',
        scale: <String, Object?>{
          'thresholdNo': 5,
          'condition': kThresholdSpecs[4].condition,
        },
        thresholdNoOverride: 5,
      ));
    }, skip: skipReason, timeout: kBenchTimeout);
  });

  // -------------------------------------------------------------------------
  // 候选 2 · 合计判定（真正的触发口径）
  // -------------------------------------------------------------------------
  group('候选 2 · 合计判定（**真正的触发口径**：2a + 2b）', () {
    // 本组必须**最后声明**：它消费前两组累积的分层值（flutter test 按声明顺序执行）。
    // 为什么合计才是口径：§15.6.3 的反例——2a = 300ms、2b = 450ms、合计 750ms < 800ms 时，
    // 独立触发会让 2b 单独触发，**把门槛拆松**。
    for (final _Sample sample in _epubList) {
      test('合计 / ${sample.label}${sample.real ? '（真实脏书）' : ''}', () {
        final Map<String, int>? parts = _epubParts[sample.label];
        final int? a = parts?['a'];
        final int? b = parts?['b'];
        if (a == null || b == null) {
          _emit(_record(
            spec: kThresholdSpecs[1],
            wireId: HighPerfCapability.epubDecompress.wireId,
            measured: null,
            sampleLabel: '${sample.label}（合计）',
            conclusion: '无可测基线：分层值缺失（a=$a, b=$b）——'
                '样本缺失、或 2a/2b 用例未执行 / 测量失败',
          ));
          return;
        }
        final int total = a + b;
        final int lowerBound = b; // 真合计 ≥ 真 2b = b（真 2a ≥ 0）；见文件头
        // `big_bodies` 是「解压后正文 ≈48MB」的**50MB 口径**样本（与 search.md 同口径），
        // 因此额外按 50MB 口径（合计 > 2s）判一次；真实脏书体量各异，不套用该口径。
        final bool isLargeScale = !sample.real && sample.label == 'big_bodies.epub';
        // over 是否**与口径无关**：口径缺陷只可能**高估**（+F），所以只影响 over 方向。
        // 下界本身已越死区 → 翻不动，任何口径下都 over。
        final bool overIsUnconditional =
            lowerBound > (kThresholdSpecs[1].limit.inMilliseconds * 1.1).round();
        _emit(_record(
          spec: kThresholdSpecs[1],
          wireId: HighPerfCapability.epubDecompress.wireId,
          measured: _Measured(
            samples: <int>[total],
            bytesInMemory: _readOf(sample)?.lengthInBytes ?? 0,
            coldReadMs: _coldReadMs(sample),
          ),
          sampleLabel:
              '${sample.label}（2a=${a}ms + 2b=${b}ms；下界=${lowerBound}ms）',
          scale: isLargeScale
              ? <String, Object?>{
                  'measuredMs': total,
                  'limitMs': kThresholdSpecs[1].scaleLimit!.inMilliseconds,
                  'text': kThresholdSpecs[1].scaleText,
                }
              : null,
          extraNotes: <String>[
            '合计数 = 2a / 2b 两轮中位数**相加**（§15.6.2 处置 4 的成本边界）。'
                '本行 `samples` 只有 1 个元素（合计值本身），不是 N=7 样本；'
                '组成它的两个分层值各自是 N=7 中位数',
            '**口径缺陷（如实登记）**：无目录样本的 2a 含 flatTitles 预取（2b 性质），'
                '故「2a+2b」对无目录书**高估** F；'
                '下界 = 2b 分层值（真 2a ≥ 0 ⇒ 真合计 ≥ 真 2b），'
                '冷读字段对本行取真冷读、与合计值无关',
            if (overIsUnconditional)
              '**over 与口径无关**：下界 ${lowerBound}ms 自身已越死区'
                  '（>${(kThresholdSpecs[1].limit.inMilliseconds * 1.1).round()}ms）——'
                  '无论 flatTitles 算进 2a 还是 2b，合计都必然越阈值'
            else
              '【注意】本 over **依赖上界口径**：下界 ${lowerBound}ms 未越死区，'
                  '本 over 由 2a+2b 相加得出、可能含 flatTitles 重复计数 →'
                  '**必须补一个有目录（toc 非空）的大样本复核**后才可据此开工（RUST-06）',
            if (isLargeScale)
              '本样本按 50MB 口径（合计 > 2s）另行判定——'
                  '与 docs/perf-baseline/search.md 的样本口径一致',
            if (!sample.real && sample.label == 'big_bodies.epub')
              '本样本压缩态仅 ~675KB、**解压后正文 ≈48MB**；'
                  '`bytesInMemory` 报的是压缩态（真正的输入），勿按 675KB 读结论',
          ],
        ));
      }, skip: skipReason, timeout: kBenchTimeout);
    }
  });
}

/// 生成样本的搜索词（**写死**，为的是与 `docs/perf-baseline/search.md` 的既有读数可比）。
///
/// 注意每个词必须**真的出现在该样本正文里**：`long_chapter.epub` 的生成器写的是
/// `第N段字字字…`（没有「第N章」前缀），沿用大书用的「第1章第1段」会**零命中**
/// （T02 首跑实证），故单独给词。
const Map<String, String> _generatedQueries = <String, String>{
  'big_bodies.epub': '第1章第1段',
  'big_320.epub': '第1章第1段',
  'long_chapter.epub': '第1段',
};

/// 从真实脏书派生搜索词：**首章正文里一段连续汉字的中间 6 字**。
///
/// 对齐 `test/format/real_samples_smoke_test.dart` 的既定纪律「用真书正文派生查询，
/// 不冻结」——不把任何作品专有词写进仓库。
///
/// 两条**必须**的守卫（T02 首跑各踩一次）：
///   · **只要纯汉字连续段**：首章常是封面 / 图片页，`extractSection` 对图片产出的是
///     `IMG:…` 占位符——首跑就把 `IMG:OE` 当成了查询词（零命中）；
///   · **只取 `locate` 为空的章**：`content(i)` 在 `locate` 非空时走**片段**抽取，
///     而 `search()` 一律走**整节**抽取；两者段落文本可能不同，拿片段里的词去整节里
///     搜未必命中。`locate` 为空时两条路径同源，派生词**必然可命中**。
Future<String?> _queryFor(_Sample sample, Uint8List bytes) async {
  // 生成样本：查表。**表里没有就不测**（不猜一个词——猜错就是零命中，
  // 而零命中会被误判成「达标」，见候选 4 分组里的守卫）。
  if (!sample.real) return _generatedQueries[sample.label];
  final DartEpubSource source = DartEpubSource(
    fileName: sample.label,
    bytes: bytes,
    runner: const _LocalRunner(),
  );
  try {
    final List<Chapter> chapters = await source.chapters();
    for (int i = 0; i < chapters.length && i < 8; i++) {
      if (chapters[i].locate.isNotEmpty) continue; // 见上方第 2 条守卫
      final ChapterContent content = await source.content(i);
      for (final String paragraph in content.paragraphList) {
        final String? run = _longestHanRun(paragraph);
        if (run == null) continue;
        return run.substring(2, 8); // 段中间取 6 字，避开可能的行首噪声
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    await source.dispose();
  }
}

/// 取一段里最长的「连续汉字」片段；不足 8 字返回 `null`。
///
/// 纯 ASCII 写法判汉字区间（U+4E00–U+9FFF），不引任何正则依赖。
String? _longestHanRun(String text) {
  String? best;
  int start = -1;
  for (int i = 0; i <= text.length; i++) {
    final bool isHan = i < text.length &&
        text.codeUnitAt(i) >= 0x4E00 &&
        text.codeUnitAt(i) <= 0x9FFF;
    if (isHan) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      if (best == null || i - start > best.length) {
        best = text.substring(start, i);
      }
      start = -1;
    }
  }
  return (best != null && best.length >= 8) ? best : null;
}
