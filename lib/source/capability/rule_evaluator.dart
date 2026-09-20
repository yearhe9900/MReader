// 双层判定：把「字段静态结构」与「本平台能力」合成三态结论。
//
// ─────────────────────────────────────────────────────────────────────────
// 与架构文档的一处刻意偏离（设计缺陷修正）
//
// 文档 §5.2 曾把 `evaluate` 的入参写成 `ParsedField`，但 `ParsedField` 定义在
// `lib/source/source_diagnostic.dart`，而 T02 又要求 `source_diagnostic.dart` 调用
// `RuleEvaluator` —— 这将形成 `capability/` ↔ `source_diagnostic.dart` 的循环依赖。
//
// 本实现断掉该环：在 `capability/` 内定义轻量值对象 [FieldUsage]，
// 只携带判定所需的两个事实（是否已配置 / 是否依赖 JS）。
// `capability/` 因此只依赖自己的类型；由 `source_diagnostic.dart` 侧负责把
// `ParsedField` 转换成 [FieldUsage]（见 `ParsedField.toUsage`）。
// ─────────────────────────────────────────────────────────────────────────
//
// 本文件不依赖 Flutter。

import 'capability.dart';
import 'capability_registry.dart';

/// 单字段求值结论的档位。
enum EvaluationOutcome {
  /// 纯静态可求值。
  staticOk,

  /// 依赖 JS，且本平台 JS 可用 → 可求值。
  jsRequired,

  /// 依赖 JS，但本平台不可用 → 降级。
  jsUnavailable,

  /// 依赖 WebView。
  needsWebView,

  /// 书源类型不支持（如漫画）。
  unsupportedType,
}

/// 单字段求值结论。
class FieldEvaluation {
  const FieldEvaluation({required this.outcome, required this.reason});

  /// 档位。
  final EvaluationOutcome outcome;

  /// 结论说明（给 UI 用）。
  final String reason;
}

/// 字段的「静态事实」集合 —— 供 [RuleEvaluator] 判定所需的全部输入。
///
/// 刻意只带两个 bool，不携带规则/URL 结构，避免 `capability/` 反向依赖体检层。
class FieldUsage {
  const FieldUsage({required this.isConfigured, required this.usesJs});

  /// 字段是否已配置（非空）。
  final bool isConfigured;

  /// 字段是否依赖 JS。
  final bool usesJs;
}

/// 把「字段静态结构」与「平台能力」合成双层结论。
///
/// 判定语义（与架构文档 §5.4 完全一致）：
///   1. 未配置 → `staticOk`；
///   2. 不依赖 JS → `staticOk`；
///   3. 依赖 JS 且 `registry.has(script)` 为假 → `jsUnavailable`
///      （原因取 `registry.reasonFor(script)`，为空时用「本平台无 JS 引擎」）；
///   4. 依赖 JS 且可用 → `jsRequired`。
class RuleEvaluator {
  const RuleEvaluator(this.registry);

  /// 平台能力注册表。
  final CapabilityRegistry registry;

  /// 对单个字段做双层判定。
  FieldEvaluation evaluate(FieldUsage usage) {
    if (!usage.isConfigured) {
      return const FieldEvaluation(
        outcome: EvaluationOutcome.staticOk,
        reason: '未配置',
      );
    }
    // 第 1 层：源是否依赖 JS。
    if (!usage.usesJs) {
      return const FieldEvaluation(
        outcome: EvaluationOutcome.staticOk,
        reason: '纯静态规则',
      );
    }
    // 第 2 层：本平台 JS 能力是否可用。
    if (!registry.has(Capability.script)) {
      return FieldEvaluation(
        outcome: EvaluationOutcome.jsUnavailable,
        reason: registry.reasonFor(Capability.script) ?? '本平台无 JS 引擎',
      );
    }
    return const FieldEvaluation(
      outcome: EvaluationOutcome.jsRequired,
      reason: 'JS 可求值',
    );
  }
}
