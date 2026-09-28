// 阈值判定器的单测（`M35-T02` / 架构 §H.4；PRD §15.6.3）。
//
// 纯 Dart `test()`。为什么这些断言重要：`RUST-06` 是**反向硬约束**（未超阈值不得上 Rust），
// 判定规则一旦漂移，要么把门槛拆松（该不做的做了），要么把门槛焊死（该做的永远不做）。
// 因此 §H.4 举的三个例子（780 / 830 / 900）与死区边界必须逐条钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/highperf/high_perf_capability.dart';

import 'threshold_judge.dart';

void main() {
  group('§H.4 三段式判定（含 10% 死区）', () {
    const Duration limit = Duration(milliseconds: 800);

    test('文档示例：780 → 不上；830 → 临界；900 → 越过', () {
      expect(judgeDuration(const Duration(milliseconds: 780), limit),
          ThresholdVerdict.under);
      expect(judgeDuration(const Duration(milliseconds: 830), limit),
          ThresholdVerdict.borderline);
      expect(judgeDuration(const Duration(milliseconds: 900), limit),
          ThresholdVerdict.over);
    });

    test('死区边界：799 under / 800 borderline / 880 borderline / 881 over', () {
      expect(judgeDuration(const Duration(milliseconds: 799), limit),
          ThresholdVerdict.under);
      expect(judgeDuration(const Duration(milliseconds: 800), limit),
          ThresholdVerdict.borderline,
          reason: '「超过」才触发：恰好 800 不算超过，落临界段');
      expect(judgeDuration(const Duration(milliseconds: 880), limit),
          ThresholdVerdict.borderline,
          reason: '880 = 800 × 1.1 的闭区间上端');
      expect(judgeDuration(const Duration(milliseconds: 881), limit),
          ThresholdVerdict.over);
    });

    test('死区系数写死为 1.1（改动必须同步 PRD，Q22）', () {
      expect(kBorderlineFactor, 1.1);
    });

    test('allowRust 只在 over 为真（RUST-06 反向硬约束的机读位）', () {
      final ThresholdSpec spec = kThresholdSpecs.firstWhere((s) => s.no == 2);
      expect(
        judgeThreshold(spec, const Duration(milliseconds: 400)).allowsRust,
        isFalse,
      );
      expect(
        judgeThreshold(spec, const Duration(milliseconds: 830)).allowsRust,
        isFalse,
        reason: '临界段明确「暂不上」',
      );
      expect(
        judgeThreshold(spec, const Duration(milliseconds: 900)).allowsRust,
        isTrue,
      );
    });

    test('结论文案含阈值编号、实测值、倍数与动作（可直接粘进留档）', () {
      final ThresholdSpec spec = kThresholdSpecs.firstWhere((s) => s.no == 3);
      final ThresholdDecision decision = judgeThreshold(
        spec,
        const Duration(milliseconds: 1200),
        sampleLabel: 'big_20mb.txt',
      );
      expect(decision.text, contains('阈值 3'));
      expect(decision.text, contains('big_20mb.txt'));
      expect(decision.text, contains('1200ms'));
      expect(decision.text, contains('1.50×'));
      expect(decision.text, contains('允许上 Rust'));
    });

    test('大样本口径（候选 2 的 50MB = 2s）单独判定并写进结论', () {
      final ThresholdSpec spec = kThresholdSpecs.firstWhere((s) => s.no == 2);
      final ThresholdDecision decision = judgeThreshold(
        spec,
        const Duration(milliseconds: 900),
        scaleMeasured: const Duration(milliseconds: 3000),
      );
      expect(decision.verdict, ThresholdVerdict.over);
      expect(decision.text, contains('50MB 口径'));
      expect(decision.text, contains('3000ms / 2000ms'));
    });
  });

  group('阈值表与 PRD §15.6.3 的一致性（防手抄漂移）', () {
    test('五行、编号 1~5、每条都挂到具体能力', () {
      expect(kThresholdSpecs.length, 5);
      expect(
        kThresholdSpecs.map((s) => s.no).toList(),
        <int>[1, 2, 3, 4, 5],
      );
      // 编号与 HighPerfCapability.thresholdNo 必须双向一致（两处任一漂移即红）。
      for (final ThresholdSpec spec in kThresholdSpecs) {
        expect(spec.capability.thresholdNo, spec.no);
      }
      for (final HighPerfCapability cap in HighPerfCapability.values) {
        expect(thresholdFor(cap)?.no, cap.thresholdNo);
      }
    });

    test('阈值取值逐条照抄 PRD：3s / 800ms / 800ms / 1.5s / 10s', () {
      expect(kThresholdSpecs[0].limit, const Duration(seconds: 3));
      expect(kThresholdSpecs[1].limit, const Duration(milliseconds: 800));
      expect(kThresholdSpecs[2].limit, const Duration(milliseconds: 800));
      expect(kThresholdSpecs[3].limit, const Duration(milliseconds: 1500));
      expect(kThresholdSpecs[4].limit, const Duration(seconds: 10));
    });

    test('候选 2 的合计口径与前置条件写死（2b 规格化 + 分层值仅归因）', () {
      final ThresholdSpec spec = kThresholdSpecs[1];
      expect(spec.scaleLimit, const Duration(seconds: 2));
      expect(spec.preconditions.length, 2);
      expect(spec.preconditions.join(), contains('仅作归因'));
      expect(spec.preconditions.join(), contains('切段规则规格化'));
    });

    test('候选 3 的前置条件写死（首版只探测编码，解码留 Dart）', () {
      expect(kThresholdSpecs[2].preconditions.join(), contains('解码仍留 Dart'));
    });

    test('候选 5 明确「基线待 AI 后补」（不是遗漏，是已登记）', () {
      expect(kThresholdSpecs[4].preconditions.join(), contains('待 AI 后补'));
    });

    test('条件原文里带上样本规模（判定文案要引用它）', () {
      expect(kThresholdSpecs[0].condition, contains('20MB AZW3'));
      expect(kThresholdSpecs[2].condition, contains('20MB TXT'));
      expect(kThresholdSpecs[3].condition, contains('50MB'));
      expect(kThresholdSpecs[4].condition, contains('20MB'));
    });

    test('每条都有取值依据（阈值是「先是数字」，依据不能空）', () {
      for (final ThresholdSpec spec in kThresholdSpecs) {
        expect(spec.basis.trim(), isNotEmpty, reason: '阈值 ${spec.no} 缺依据');
      }
    });
  });

  group('BaselineRecord 留档 schema（§H.2 固定字段）', () {
    BaselineRecord record(List<int> samples, {int? coldReadMs}) => BaselineRecord(
          capability: HighPerfCapability.epubDecompress.wireId,
          device: 'test-device',
          os: 'windows x64',
          samples: samples,
          bytesInMemory: 1234,
          peakMemBytes: 5678,
          conclusion: '测试用结论',
          thresholdNo: 2,
          verdict: 'over',
          judging: false,
          coldReadMs: coldReadMs,
        );

    test('median：奇数取中位、偶数取中间两者均值', () {
      expect(record(<int>[5, 1, 3]).median, 3);
      expect(record(<int>[4, 1, 3, 2]).median, 3); // (2+3)/2 = 2.5 → 3（四舍五入）
    });

    test('min / max / p90（p90 取升序后 ceil(0.9n)-1）', () {
      final BaselineRecord r = record(<int>[10, 20, 30, 40, 50, 60, 70]);
      expect(r.min, 10);
      expect(r.max, 70);
      expect(r.p90, 70); // ceil(6.3)-1 = 6 → 第 7 个
      final BaselineRecord r10 =
          record(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(r10.p90, 9); // ceil(9)-1 = 8 → 第 9 个
    });

    test('空样本：统计量为 null，不崩', () {
      final BaselineRecord r = record(<int>[]);
      expect(r.median, isNull);
      expect(r.min, isNull);
      expect(r.max, isNull);
      expect(r.p90, isNull);
    });

    test('toJson 字段与 §H.2 逐字对应（含 thresholdNo / verdict / judging）', () {
      final Map<String, Object?> json = record(<int>[10, 30]).toJson();
      for (final String key in <String>[
        'capability',
        'device',
        'os',
        'samples',
        'median',
        'min',
        'max',
        'p90',
        'bytesInMemory',
        'peakMemBytes',
        'conclusion',
        'thresholdNo',
        'verdict',
        'judging',
      ]) {
        expect(json.containsKey(key), isTrue, reason: '缺字段 $key');
      }
      expect(json['samples'], <int>[10, 30]);
      expect(json['median'], 20);
    });

    test('scale 与 notes 仅在有值时出现（留档 JSON 不留空壳）', () {
      expect(record(<int>[1]).toJson().containsKey('scale'), isFalse);
      expect(record(<int>[1]).toJson().containsKey('notes'), isFalse);
    });

    // §H.1 明确要求「**额外记录一次冷读总耗时**作参考，不参与判定」。
    // 该字段 T02 首跑只写进了 `notes` 人话、没进 JSON schema，
    // 于是 harness 打印出来永远是 `null`（机读拿不到）→ 这里把它钉进 schema。
    test('coldReadMs：有值时进 JSON，无值时不出现（不参与判定）', () {
      expect(record(<int>[10, 30], coldReadMs: 42).toJson()['coldReadMs'], 42);
      expect(record(<int>[10, 30]).toJson().containsKey('coldReadMs'), isFalse);
      expect(record(<int>[10, 30]).coldReadMs, isNull);
    });
  });
}
