// 引入门槛的**判定器**：PRD §15.6.3 阈值表的唯一机读来源 + 架构 §H.4 的三段式判定。
//
// `RUST-06` 的门槛是「**先测后引**」：超过阈值才允许上 Rust；反向硬约束是「未超过
// 阈值的候选能力**不得**实施 Rust 版本」。因此阈值**必须**：① **先是数字、再是代码**
// （`Q22`）——表在 PRD、这里的常量逐字照抄，调整**必须**同步改 PRD；② **可被反例
// 验证**：越界与否只能有一个答案（§H.4）。本文件 = **照抄阈值表** + **只在一处实现
// 判定规则**；`threshold_judge_test.dart` 把 §H.4 示例与边界值逐条钉死。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`（可在 isolate / 桌面 / 真机同码运行）。
import 'package:mreader/highperf/high_perf_capability.dart';

/// 判定结论（§H.4 三段式）。
enum ThresholdVerdict {
  /// `M > 阈值 × 1.1` → **越过阈值 → 允许上 Rust**（进 T04，并记录超过的阈值编号）。
  over,

  /// `阈值 ≤ M ≤ 阈值 × 1.1` → 临界，结论记「临界 · 暂不上」，进观察名单，**本轮不做**。
  borderline,

  /// `M < 阈值` → 未越阈值 → **不上 Rust**（同样是一份合格结论，留档即可）。
  under,
}

/// 死区系数（§H.4 写死的 10%）：把「测量噪声」与「真实越界」分开——测量有抖动
/// （GC / 后台进程 / 机型差异），紧贴阈值就立刻改判会在边界反复横跳。
const double kBorderlineFactor = 1.1;

/// 一条候选门槛（**逐字取自 PRD §15.6.3**）。
class ThresholdSpec {
  const ThresholdSpec({
    required this.no,
    required this.capability,
    required this.condition,
    required this.limit,
    required this.basis,
    this.scaleLimit,
    this.scaleText,
    this.preconditions = const <String>[],
  });

  /// 阈值编号（`RUST-06 ⑤`「超过的阈值编号可被逐条指出」用的就是它）。
  ///
  /// 注意编号 **2** 同时覆盖 2a / 2b（合计判定），因此编号 ≠ 能力数量。
  final int no;

  /// 对应能力（2a 对应 [HighPerfCapability.epubDecompress]；2b 无枚举值，见其注释）。
  final HighPerfCapability capability;

  /// 触发条件的**原话**（含样本规模），判定文案直接引用它。
  final String condition;

  /// 触发阈值：**超过**才上 Rust。
  final Duration limit;

  /// 取值依据（照抄 PRD，防「阈值是哪来的」在几轮之后无法追溯）。
  final String basis;

  /// 大样本口径的等价阈值（仅候选 2 有：50MB 口径合计 > 2s）。
  final Duration? scaleLimit;

  /// 大样本口径的原文。
  final String? scaleText;

  /// 比阈值更严的**前置条件**（候选 2b / 3 有：不满足则「即使超阈值也不得实施」）。
  final List<String> preconditions;
}

/// PRD §15.6.3 的阈值表（5 行；候选 2b 与 2a 合并判定，故不与 2a 并列成行）。
const List<ThresholdSpec> kThresholdSpecs = <ThresholdSpec>[
  ThresholdSpec(
    no: 1,
    capability: HighPerfCapability.mobiDecompress,
    condition: '打开 20MB AZW3 > 3s，或单本解压 + 解析 > 2s',
    limit: Duration(seconds: 3),
    basis: 'MOBI/AZW3 是「需解压后才能重排」的格式，用户预期接近「打开即读」；'
        '3s 对齐 NF-P3（50MB 大书 ≤ 10s）中「明显可感知」的档位。'
        '该项是本组唯一**确定性 CPU 密集**项，阈值有意设在易触发处。',
  ),
  ThresholdSpec(
    no: 2,
    capability: HighPerfCapability.epubDecompress,
    condition: '单本「2a + 2b」合计 > 800ms',
    limit: Duration(milliseconds: 800),
    basis: '由 v2.4 的「单本解析 > 800ms」对半拆分用于归因；'
        '合计口径仍以 2026-09-18 决策文档的量级判断为据。',
    scaleLimit: Duration(seconds: 2),
    scaleText: '50MB 口径：合计 > 2s',
    preconditions: <String>[
      '合并判定：分层值 400ms / 1s **仅作归因与优先级指引**，不作独立触发条件（v2.6 方案 A，'
          '防「独立触发把门槛拆松」）',
      '候选 2b（XHTML → 段落）另有更严前置条件：必须先完成「切段规则规格化」，'
          '否则即使合计超过阈值也不得实施（RUST-02 的 L2 等价性无法验收）',
    ],
  ),
  ThresholdSpec(
    no: 3,
    capability: HighPerfCapability.txtChapterize,
    condition: '20MB TXT 分章 > 800ms',
    limit: Duration(milliseconds: 800),
    basis: 'RD-02 已要求「20MB TXT 能打开不闪退」；800ms 约为 NF-P2（普通书 ≤ 2s）的 40%，'
        '为渲染与寻址留足余量。',
    preconditions: <String>[
      '首版只做「探测出编码名」，解码仍留 Dart（保持既有 charset 与 NF-C4 六级兜底行为不变）；'
          '若把解码一并交给 Rust，另立阈值',
    ],
  ),
  ThresholdSpec(
    no: 4,
    capability: HighPerfCapability.fullTextSearch,
    condition: '50MB 书全库搜索首屏结果 > 1.5s，或搜索期间出现单帧 > 16ms',
    limit: Duration(milliseconds: 1500),
    basis: '搜索是交互式能力，1.5s 是「键入后无感等待」的上限；'
        '帧时间阈值用于防止「不卡死但也不流畅」——CNT-06 只要求「不卡死」，本阈值更严。',
  ),
  ThresholdSpec(
    no: 5,
    capability: HighPerfCapability.bm25Index,
    condition: '单本 20MB 书索引构建 > 10s，或索引占用内存 > 原文的 1.5 倍',
    limit: Duration(seconds: 10),
    basis: '索引是**一次性后台任务**，10s 可接受（用户此时在读别的）；'
        '但内存倍率必须受限，否则直接违反 NF-M1 / NF-P2。',
    preconditions: <String>[
      '基线依赖 AI 跟书问答（AI-06）落地；M3.5 时点尚无可测的纯 Dart 基线',
          '（PRD §15.6 明文「阈值 5 基线待 AI 后补」）',
    ],
  ),
];

/// 取某能力对应的门槛；无候选门槛的能力返回 `null`。
ThresholdSpec? thresholdFor(HighPerfCapability capability) {
  for (final ThresholdSpec spec in kThresholdSpecs) {
    if (spec.capability == capability) return spec;
  }
  return null;
}

/// §H.4 的判定规则（**唯一实现**，别在别处重写）。
ThresholdVerdict judgeDuration(Duration measured, Duration limit) {
  final int m = measured.inMicroseconds;
  final int t = limit.inMicroseconds;
  if (m < t) return ThresholdVerdict.under;
  final int deadband = (t * kBorderlineFactor).round();
  if (m > deadband) return ThresholdVerdict.over;
  return ThresholdVerdict.borderline;
}

/// 判定 + 给人看 / 留档用的结论文案。
///
/// [sampleLabel] 用于把「哪个样本」写进结论（同一阈值可能测多个样本）。
ThresholdDecision judgeThreshold(
  ThresholdSpec spec,
  Duration measured, {
  String sampleLabel = '',
  Duration? scaleMeasured,
}) {
  final ThresholdVerdict verdict = judgeDuration(measured, spec.limit);
  final String where = sampleLabel.isEmpty ? '' : '（$sampleLabel）';
  final String ratio = (measured.inMicroseconds / spec.limit.inMicroseconds)
      .toStringAsFixed(2);
  final StringBuffer text = StringBuffer()
    ..write('阈值 ${spec.no} · ${spec.condition}$where：实测 ')
    ..write('${measured.inMilliseconds}ms')
    ..write(' / 阈值 ${spec.limit.inMilliseconds}ms（$ratio×）→ ');
  switch (verdict) {
    case ThresholdVerdict.over:
      text.write('**越过阈值 → 允许上 Rust**');
    case ThresholdVerdict.borderline:
      text.write('临界 · 暂不上（进观察名单，下一轮样本 / 机型更新后重测再判）');
    case ThresholdVerdict.under:
      text.write('未越阈值 → 不上 Rust（合格结论，留档）');
  }
  if (spec.scaleLimit != null && scaleMeasured != null) {
    final ThresholdVerdict scaleVerdict =
        judgeDuration(scaleMeasured, spec.scaleLimit!);
    text
      ..write('；${spec.scaleText ?? '大样本口径'}：实测 ')
      ..write('${scaleMeasured.inMilliseconds}ms'
          ' / ${spec.scaleLimit!.inMilliseconds}ms → ')
      ..write(scaleVerdict.name);
  }
  return ThresholdDecision(verdict: verdict, text: text.toString());
}

/// 判定结果。
class ThresholdDecision {
  const ThresholdDecision({required this.verdict, required this.text});

  final ThresholdVerdict verdict;

  /// 结论文案（可直接粘进 `docs/perf-baseline/*.md`）。
  final String text;

  /// 是否允许实施 Rust 版本（`RUST-06`：只有 over 允许）。
  bool get allowsRust => verdict == ThresholdVerdict.over;
}

/// 一次基线测量的留档记录（§H.2 的固定 schema）。
///
/// 字段名与架构 §H.2 逐字对应：`{capability, device, os, samples[], median, min, max,
/// p90, bytesInMemory, peakMemBytes, conclusion}`，另补 `thresholdNo` / `verdict` /
/// `judging` / `scale` 四项——`RUST-06 ⑤` 要求「能指出超过的阈值编号」，
/// 而 §H.3 要求桌面数据标注 `judging: false`（不作为判定基准）。
class BaselineRecord {
  const BaselineRecord({
    required this.capability,
    required this.device,
    required this.os,
    required this.samples,
    required this.bytesInMemory,
    required this.peakMemBytes,
    required this.conclusion,
    required this.thresholdNo,
    required this.verdict,
    required this.judging,
    this.coldReadMs,
    this.scale,
    this.sampleLabel = '',
    this.notes = const <String>[],
  });

  /// 能力 wireId（`HighPerfCapability.wireId`）。
  final String capability;
  final String device;
  final String os;

  /// 每轮耗时（毫秒，**按轮次顺序**，含预热轮之外的 N 轮）。
  final List<int> samples;

  /// 输入字节数（热态，已在内存）。
  final int bytesInMemory;

  /// 进程峰值内存（对齐 §13.2 的分口径：峰值与稳态分开报）。
  final int peakMemBytes;

  /// 结论（`ThresholdDecision.text` 或「无可测基线」的原因）。
  final String conclusion;

  /// 对应阈值编号（0 = 无阈值，如「无可测基线」）。
  final int thresholdNo;

  /// 判定结论名（`over` / `borderline` / `under` / `notMeasured`）。
  final String verdict;

  /// 是否参与判定（§H.3：桌面 = `false`，Android 主力机 = `true`）。
  final bool judging;

  /// **冷读一次（含 IO）的耗时**——§H.1 要求「额外记录一次冷读总耗时作参考，不参与
  /// 判定」。单独成字段而非只写 [notes]：留档要**机读**，否则「有没有测冷读」只能靠读人话。
  final int? coldReadMs;

  /// 大样本口径（候选 2 的 50MB）测量与阈值。
  final Map<String, Object?>? scale;

  /// 样本标签（同一能力多个样本时区分）。
  final String sampleLabel;

  /// 口径备注（如「本机为开发机，判定以 Android 主力机为准」）。
  final List<String> notes;

  /// 中位数（毫秒）；无样本时为 `null`。
  int? get median {
    if (samples.isEmpty) return null;
    final List<int> sorted = List<int>.of(samples)..sort();
    final int mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : ((sorted[mid - 1] + sorted[mid]) / 2).round();
  }

  int? get min => samples.isEmpty ? null : samples.reduce((a, b) => a < b ? a : b);

  int? get max => samples.isEmpty ? null : samples.reduce((a, b) => a > b ? a : b);

  /// p90（取「第 90 百分位」的较保守实现：升序后按 `ceil(0.9n)-1` 取）。
  int? get p90 {
    if (samples.isEmpty) return null;
    final List<int> sorted = List<int>.of(samples)..sort();
    final int index = ((sorted.length * 0.9).ceil() - 1).clamp(0, sorted.length - 1);
    return sorted[index];
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'capability': capability,
        'device': device,
        'os': os,
        'sample': sampleLabel,
        'samples': samples,
        'median': median,
        'min': min,
        'max': max,
        'p90': p90,
        'bytesInMemory': bytesInMemory,
        'peakMemBytes': peakMemBytes,
        if (coldReadMs != null) 'coldReadMs': coldReadMs,
        'thresholdNo': thresholdNo,
        'verdict': verdict,
        'judging': judging,
        if (scale != null) 'scale': scale,
        'conclusion': conclusion,
        if (notes.isNotEmpty) 'notes': notes,
      };
}
