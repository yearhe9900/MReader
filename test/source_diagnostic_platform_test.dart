// 体检双层升级测试：第 1 层（源固有）不变，第 2 层（平台相对）按注入变化。
//
// 核心设计原则要在这里被**断言锁死**：
//   换平台时第 1 层结果不变 —— 第 1 层是「事实」，第 2 层才是「当前环境下的结论」。
// 夹具用真实书源 shenshi.json（25 个已配置字段中 10 个依赖 JS）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/source/book_source.dart';
import 'package:mreader/source/capability/capability.dart';
import 'package:mreader/source/capability/capability_registry.dart';
import 'package:mreader/source/capability/rule_evaluator.dart';
import 'package:mreader/source/capability/script_capability.dart';
import 'package:mreader/source/source_diagnostic.dart';

/// 假引擎：`isAvailable=true`，用于模拟「能力齐备」的平台。
class _FakeEngine implements ScriptCapability {
  @override
  String get id => 'fake';

  @override
  ScriptEngineKind get kind => ScriptEngineKind.quickJs;

  @override
  String get label => '假引擎';

  @override
  bool get isAvailable => true;

  @override
  Set<ScriptBinding> get supportedBindings =>
      const <ScriptBinding>{ScriptBinding.ajax, ScriptBinding.variableIO};

  @override
  Future<bool> probe() async => true;

  @override
  Future<ScriptResult> evaluate(ScriptRequest request) async =>
      ScriptResult.ok('ok');

  @override
  void dispose() {}
}

BookSource loadShenshi() {
  final String text =
      File('test/fixtures/shenshi.json').readAsStringSync(encoding: utf8);
  return BookSource.fromJson(
    ((jsonDecode(text) as List<dynamic>).single as Map<dynamic, dynamic>)
        .cast<String, dynamic>(),
  );
}

ParsedField fieldOf(SourceDiagnostic d, String key) =>
    d.fields.firstWhere((ParsedField f) => '${f.groupKey}/${f.fieldName}' == key);

DiagnosticFinding jsBlockerOf(SourceDiagnostic d) => d.findings
    .firstWhere((DiagnosticFinding f) => f.title.contains('依赖 JS 引擎'));

/// 只由「等级 + 标题」构成签名 —— 用来对比第 1 层是否被平台层改动。
String titleSig(SourceDiagnostic d) => d.findings
    .map((DiagnosticFinding f) => '${f.level.index}|${f.title}')
    .join('\n');

void main() {
  group('inspect 回归：第 1 层行为未被改变', () {
    test('关键数量不变', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(d.fields, hasLength(52));
      expect(d.configuredFieldCount, 25);
      expect(d.jsFieldCount, 10);
      expect(d.jsFreeFields, hasLength(15));
      expect(d.findings, hasLength(12));
      expect(d.findingsOf(DiagnosticLevel.blocker), hasLength(2));
      expect(d.legadoApis, hasLength(28));
      expect(d.capabilities, hasLength(11));
      expect(d.worstLevel, DiagnosticLevel.blocker);
    });

    test('inspect 不带平台层：evaluations 为空、evaluator 为 null', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(d.hasPlatformLayer, isFalse);
      expect(d.evaluator, isNull);
      expect(d.evaluations, isEmpty);
      expect(d.evaluationOf(d.fields.first), isNull);
    });

    test('第 1 层 JS blocker 文案逐字未改', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());
      final DiagnosticFinding f = jsBlockerOf(d);

      expect(f.level, DiagnosticLevel.blocker);
      expect(f.title, '依赖 JS 引擎：10/25 个已配置字段含 JS');
      expect(f.detail, contains('当前 demo 无 JS 引擎'));
      expect(f.detail, contains('参考实现用 flutter_js 承载'));
    });
  });

  group('inspectFor：第 2 层随平台注入而变', () {
    final SourceDiagnostic l1 = SourceDiagnostic.inspect(loadShenshi());
    final SourceDiagnostic noEngine =
        SourceDiagnostic.inspectFor(loadShenshi(), CapabilityRegistry.fallback());
    final SourceDiagnostic withEngine = SourceDiagnostic.inspectFor(
      loadShenshi(),
      CapabilityRegistry(script: _FakeEngine()),
    );

    test('无引擎：10 个 JS 字段全部降级', () {
      expect(noEngine.hasPlatformLayer, isTrue);
      expect(noEngine.evaluations, hasLength(52));
      expect(noEngine.jsUnavailableFieldCount, 10);
      expect(noEngine.jsRequiredFieldCount, 0);
    });

    test('有引擎：10 个 JS 字段变为 jsRequired', () {
      expect(withEngine.jsRequiredFieldCount, 10);
      expect(withEngine.jsUnavailableFieldCount, 0);
    });

    test('同一字段（ruleSearch/bookList）在两种注入下结论不同', () {
      final ParsedField inNoEngine = fieldOf(noEngine, 'ruleSearch/bookList');
      final ParsedField inEngine = fieldOf(withEngine, 'ruleSearch/bookList');

      expect(inNoEngine.usesJs, isTrue);
      expect(inEngine.usesJs, isTrue);
      expect(noEngine.evaluations[inNoEngine]?.outcome,
          EvaluationOutcome.jsUnavailable);
      expect(withEngine.evaluations[inEngine]?.outcome,
          EvaluationOutcome.jsRequired);
    });

    test('纯静态字段在两种注入下都是 staticOk', () {
      final ParsedField inNoEngine = fieldOf(noEngine, 'ruleSearch/author');
      final ParsedField inEngine = fieldOf(withEngine, 'ruleSearch/author');

      // author 是 @get:{anm} 变量引用，不依赖 JS
      expect(inNoEngine.usesJs, isFalse);
      expect(noEngine.evaluations[inNoEngine]?.outcome,
          EvaluationOutcome.staticOk);
      expect(withEngine.evaluations[inEngine]?.outcome,
          EvaluationOutcome.staticOk);
    });

    test('第 1 层结论在两种注入下保持一致（设计原则）', () {
      expect(titleSig(noEngine), titleSig(l1));
      expect(titleSig(withEngine), titleSig(l1));

      expect(noEngine.fields.length, l1.fields.length);
      expect(noEngine.configuredFieldCount, l1.configuredFieldCount);
      expect(noEngine.jsFieldCount, l1.jsFieldCount);
      expect(noEngine.legadoApis, l1.legadoApis);
      expect(withEngine.legadoApis, l1.legadoApis);
      expect(withEngine.worstLevel, l1.worstLevel);

      // Set 顺序无关，用长度 + 双向包含断言
      expect(noEngine.capabilities.length, l1.capabilities.length);
      expect(noEngine.capabilities.containsAll(l1.capabilities), isTrue);
      expect(withEngine.capabilities.length, l1.capabilities.length);
      expect(withEngine.capabilities.containsAll(l1.capabilities), isTrue);
    });
  });

  group('blocker 文案按平台分流', () {
    test('无引擎 → 「本平台不可用」+ 纯规则源/换平台', () {
      final SourceDiagnostic d = SourceDiagnostic.inspectFor(
        loadShenshi(),
        CapabilityRegistry.fallback(),
      );
      final DiagnosticFinding f = jsBlockerOf(d);

      expect(f.level, DiagnosticLevel.blocker);
      expect(f.title, '依赖 JS 引擎：10/25 个已配置字段含 JS');
      expect(f.detail, contains('本平台不可用'));
      expect(f.detail, contains('纯规则源'));
      expect(f.detail, contains('本平台无 JS 引擎'));
    });

    test('能力齐备 → 引导去实现引擎', () {
      final SourceDiagnostic d = SourceDiagnostic.inspectFor(
        loadShenshi(),
        CapabilityRegistry(script: _FakeEngine()),
      );
      final DiagnosticFinding f = jsBlockerOf(d);

      expect(f.level, DiagnosticLevel.blocker);
      expect(f.detail, contains('本平台脚本能力可用'));
      expect(f.detail, contains('接入 JS 引擎'));
      expect(f.detail, contains('CapabilityRegistry'));
    });

    test('注册表提供不可用原因 → 文案带上该原因', () {
      final SourceDiagnostic d = SourceDiagnostic.inspectFor(
        loadShenshi(),
        CapabilityRegistry(
          unavailableReasons: <Capability, String>{Capability.script: '鸿蒙未适配'},
        ),
      );

      expect(jsBlockerOf(d).detail, contains('鸿蒙未适配'));
    });
  });
}
