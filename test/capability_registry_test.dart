// 能力抽象层测试（纯 Dart）：锁定契约与四态判定。
//
// 这里锁住的是「无引擎时如何优雅降级」这件事本身 ——
// 它是「纯 Dart 核心 + 可插拔能力」这条主线最容易退化的地方：
//   · NullScriptCapability 的行为契约（尤其 **evaluate 不得抛异常**）；
//   · CapabilityRegistry.has 的 script / 其余能力分支；
//   · warmUp 在任何失败下都**不抛异常**且写入原因；
//   · RuleEvaluator 的四条判定分支。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/source/capability/capability.dart';
import 'package:mreader/source/capability/capability_registry.dart';
import 'package:mreader/source/capability/null_script_capability.dart';
import 'package:mreader/source/capability/rule_evaluator.dart';
import 'package:mreader/source/capability/script_capability.dart';

/// 假引擎：可控 `isAvailable` / `probe` 行为，用来验证注册表与判定器。
class _FakeEngine implements ScriptCapability {
  _FakeEngine({
    this.available = true,
    this.probeResult = true,
    this.throwOnProbe = false,
  });

  final bool available;
  final bool probeResult;
  final bool throwOnProbe;

  @override
  String get id => 'fake';

  @override
  ScriptEngineKind get kind => ScriptEngineKind.quickJs;

  @override
  String get label => '假引擎';

  @override
  bool get isAvailable => available;

  @override
  Set<ScriptBinding> get supportedBindings =>
      const <ScriptBinding>{ScriptBinding.ajax, ScriptBinding.variableIO};

  @override
  Future<bool> probe() async {
    if (throwOnProbe) {
      throw StateError('boom');
    }
    return probeResult;
  }

  @override
  Future<ScriptResult> evaluate(ScriptRequest request) async =>
      ScriptResult.ok('ok');

  @override
  void dispose() {}
}

void main() {
  group('NullScriptCapability 行为契约', () {
    const NullScriptCapability cap = NullScriptCapability();

    test('同步元信息：无引擎、无桥接', () {
      expect(cap.id, 'none');
      expect(cap.kind, ScriptEngineKind.none);
      expect(cap.kind.label, '无');
      expect(cap.label, '未接入 JS 引擎');
      expect(cap.isAvailable, isFalse);
      expect(cap.supportedBindings, isEmpty);
    });

    test('probe 恒为 false，不抛异常', () async {
      expect(await cap.probe(), isFalse);
    });

    test('evaluate 返回 unsupported（missingBindings 含 pureCalc）且不抛异常', () async {
      final ScriptResult result =
          await cap.evaluate(const ScriptRequest(code: '1 + 1'));
      expect(result.isOk, isFalse);
      expect(result.value, isNull);
      expect(result.error, isNull);
      expect(result.missingBindings, <ScriptBinding>[ScriptBinding.pureCalc]);
    });

    test('dispose 可安全调用', () {
      expect(cap.dispose, returnsNormally);
    });
  });

  group('CapabilityRegistry.has', () {
    test('降级注册表：script=false，network=true，其余=false', () {
      final CapabilityRegistry registry = CapabilityRegistry.fallback();
      expect(registry.has(Capability.script), isFalse);
      expect(registry.has(Capability.network), isTrue);
      expect(registry.has(Capability.webView), isFalse);
      expect(registry.has(Capability.variableIO), isFalse);
      expect(registry.has(Capability.fileSystem), isFalse);
      expect(registry.has(Capability.database), isFalse);
      expect(registry.has(Capability.charset), isFalse);
      expect(registry.reasonFor(Capability.script), isNull);
    });

    test('注入可用引擎后 script=true；extra 决定其余能力', () {
      final CapabilityRegistry registry = CapabilityRegistry(
        script: _FakeEngine(),
        extra: <Capability>{Capability.network, Capability.charset},
      );
      expect(registry.has(Capability.script), isTrue);
      expect(registry.has(Capability.charset), isTrue);
      expect(registry.has(Capability.webView), isFalse);
      expect(registry.script.label, '假引擎');
    });

    test('fallback 每次返回独立实例（刻意不设全局单例）', () {
      final CapabilityRegistry a = CapabilityRegistry.fallback();
      final CapabilityRegistry b = CapabilityRegistry.fallback();
      expect(identical(a, b), isFalse);
      expect(a.has(Capability.network), b.has(Capability.network));
    });
  });

  group('CapabilityRegistry.warmUp', () {
    test('probe 返回 false：写入原因、不抛异常', () async {
      final CapabilityRegistry registry =
          CapabilityRegistry(script: _FakeEngine(probeResult: false));
      await expectLater(registry.warmUp(), completes);
      expect(registry.reasonFor(Capability.script), '引擎探测失败');
    });

    test('probe 抛异常：写入原因、不抛异常', () async {
      final CapabilityRegistry registry =
          CapabilityRegistry(script: _FakeEngine(throwOnProbe: true));
      await expectLater(registry.warmUp(), completes);
      expect(
        registry.reasonFor(Capability.script),
        startsWith('引擎初始化异常'),
      );
    });

    test('引擎不可用：提前返回，不写原因', () async {
      final CapabilityRegistry registry =
          CapabilityRegistry(script: _FakeEngine(available: false));
      await expectLater(registry.warmUp(), completes);
      expect(registry.reasonFor(Capability.script), isNull);
    });

    test('降级注册表：无可探测引擎，不写原因', () async {
      final CapabilityRegistry registry = CapabilityRegistry.fallback();
      await expectLater(registry.warmUp(), completes);
      expect(registry.reasonFor(Capability.script), isNull);
    });
  });

  group('RuleEvaluator 四态判定', () {
    const FieldUsage unconfigured =
        FieldUsage(isConfigured: false, usesJs: false);
    const FieldUsage staticField = FieldUsage(isConfigured: true, usesJs: false);
    const FieldUsage jsField = FieldUsage(isConfigured: true, usesJs: true);

    test('未配置 → staticOk', () {
      final FieldEvaluation e =
          RuleEvaluator(CapabilityRegistry.fallback()).evaluate(unconfigured);
      expect(e.outcome, EvaluationOutcome.staticOk);
      expect(e.reason, '未配置');
    });

    test('不依赖 JS → staticOk', () {
      final FieldEvaluation e =
          RuleEvaluator(CapabilityRegistry.fallback()).evaluate(staticField);
      expect(e.outcome, EvaluationOutcome.staticOk);
      expect(e.reason, '纯静态规则');
    });

    test('依赖 JS 且本平台不可用 → jsUnavailable（默认原因）', () {
      final FieldEvaluation e =
          RuleEvaluator(CapabilityRegistry.fallback()).evaluate(jsField);
      expect(e.outcome, EvaluationOutcome.jsUnavailable);
      expect(e.reason, '本平台无 JS 引擎');
    });

    test('依赖 JS 且本平台不可用 → jsUnavailable（采用注册表提供的原因）', () {
      final CapabilityRegistry registry = CapabilityRegistry(
        unavailableReasons: <Capability, String>{Capability.script: '鸿蒙未适配'},
      );
      final FieldEvaluation e = RuleEvaluator(registry).evaluate(jsField);
      expect(e.outcome, EvaluationOutcome.jsUnavailable);
      expect(e.reason, '鸿蒙未适配');
    });

    test('依赖 JS 且可用 → jsRequired', () {
      final FieldEvaluation e =
          RuleEvaluator(CapabilityRegistry(script: _FakeEngine()))
              .evaluate(jsField);
      expect(e.outcome, EvaluationOutcome.jsRequired);
      expect(e.reason, 'JS 可求值');
    });
  });

  group('warmUp 翻转 has(script)：降级失效修复', () {
    const FieldUsage jsField = FieldUsage(isConfigured: true, usesJs: true);

    test('probe 返回 false：has 由 true 翻 false，判定由 jsRequired 翻 jsUnavailable',
        () async {
      final CapabilityRegistry registry =
          CapabilityRegistry(script: _FakeEngine(probeResult: false));
      final RuleEvaluator evaluator = RuleEvaluator(registry);

      // warmUp 之前：乐观，仅按 isAvailable 判可用
      expect(registry.has(Capability.script), isTrue);
      expect(evaluator.evaluate(jsField).outcome, EvaluationOutcome.jsRequired);

      await registry.warmUp();

      // warmUp 之后：探测失败 → 降级生效
      expect(registry.has(Capability.script), isFalse);
      expect(
        evaluator.evaluate(jsField).outcome,
        EvaluationOutcome.jsUnavailable,
      );
      expect(registry.reasonFor(Capability.script), isNotNull);
    });

    test('probe 抛异常：同样翻为不可用并记录原因', () async {
      final CapabilityRegistry registry =
          CapabilityRegistry(script: _FakeEngine(throwOnProbe: true));
      final RuleEvaluator evaluator = RuleEvaluator(registry);

      expect(registry.has(Capability.script), isTrue);
      await expectLater(registry.warmUp(), completes);

      expect(registry.has(Capability.script), isFalse);
      expect(
        evaluator.evaluate(jsField).outcome,
        EvaluationOutcome.jsUnavailable,
      );
      expect(
        registry.reasonFor(Capability.script),
        startsWith('引擎初始化异常'),
      );
    });

    test('probe 通过：has 保持 true，并清除过时原因', () async {
      final CapabilityRegistry registry = CapabilityRegistry(
        script: _FakeEngine(probeResult: true),
        unavailableReasons: <Capability, String>{
          Capability.script: '过时原因',
        },
      );

      await registry.warmUp();

      expect(registry.has(Capability.script), isTrue);
      expect(registry.reasonFor(Capability.script), isNull);
      expect(
        RuleEvaluator(registry).evaluate(jsField).outcome,
        EvaluationOutcome.jsRequired,
      );
    });

    test('未调用 warmUp 时保持乐观（按 isAvailable 判断）', () {
      final CapabilityRegistry registry =
          CapabilityRegistry(script: _FakeEngine());
      expect(registry.has(Capability.script), isTrue);
    });
  });
}
