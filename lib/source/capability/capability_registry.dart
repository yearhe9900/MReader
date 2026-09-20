// 能力注册表：装配点，也是唯一的注入点。
//
// ─────────────────────────────────────────────────────────────────────────
// 与架构文档的一处刻意偏离（设计缺陷修正）
//
// 文档 §5.2 曾写成：
//     static final CapabilityRegistry instance = CapabilityRegistry();
//     // 默认无引擎，UI/main 可覆盖
// 该写法自相矛盾 —— `static final` 只能赋值一次，「可覆盖」根本无从实现。
//
// 本实现改为：
//   · 提供静态工厂 [fallback] 返回「无引擎」的降级注册表，供默认值与测试使用；
//   · **不引入可变全局单例**（本项目不用 Riverpod/Provider，全局可变态不符项目风格）。
//     需要 registry 的地方一律**通过构造函数显式传入**（`RuleEvaluator` 已如此设计，
//     `SourceDiagnostic.inspectFor` 亦然）。
// ─────────────────────────────────────────────────────────────────────────
//
// 本文件不依赖 Flutter。

import 'capability.dart';
import 'null_script_capability.dart';
import 'script_capability.dart';

/// 能力注册表。
///
/// 它是一次「本平台有什么能力」的快照：脚本能力走注入的实现，
/// 其余能力走静态集合。**不可变**（除 [warmUp] 写入的失败原因外），
/// 也不提供全局单例 —— 由调用方显式持有并传递。
class CapabilityRegistry {
  /// 构造一个注册表。
  ///
  /// [script] 缺省为 [NullScriptCapability]（无引擎）；
  /// [extra] 缺省只含 [Capability.network]（纯 Dart 的 HTTP 六平台可用）。
  CapabilityRegistry({
    ScriptCapability? script,
    Set<Capability>? extra,
    Map<Capability, String>? unavailableReasons,
  })  : _script = script ?? const NullScriptCapability(),
        _extra = extra ?? <Capability>{Capability.network} {
    if (unavailableReasons != null && unavailableReasons.isNotEmpty) {
      _unavailableReasons.addAll(unavailableReasons);
    }
  }

  /// 降级注册表：无脚本引擎，仅具备基础网络能力。
  ///
  /// 供默认值与测试使用；需要真实能力时请显式构造并注入实现。
  static CapabilityRegistry fallback() => CapabilityRegistry();

  final ScriptCapability _script;

  final Set<Capability> _extra;

  /// 不可用原因（构造时预置 + [warmUp] 探测失败写入）。
  final Map<Capability, String> _unavailableReasons = <Capability, String>{};

  /// 注入的脚本能力实现。
  ScriptCapability get script => _script;

  /// 是否具备某项能力（`script` 走脚本实现判定，其余走静态集合）。
  bool has(Capability c) =>
      c == Capability.script ? _script.isAvailable : _extra.contains(c);

  /// 不可用时的原因（给体检 / UI 用）；可用或未记录时为 null。
  String? reasonFor(Capability c) => _unavailableReasons[c];

  /// 探针：初始化引擎并记录失败原因。
  ///
  /// `main.dart` 启动时调用一次。**绝不抛异常、绝不阻塞启动**：
  /// 探测失败只写进 [reasonFor]，由体检 UI 呈现，主链路照常走纯规则。
  Future<void> warmUp() async {
    if (!_script.isAvailable) return;
    try {
      if (!await _script.probe()) {
        _unavailableReasons[Capability.script] = '引擎探测失败';
      }
    } catch (error) {
      _unavailableReasons[Capability.script] = '引擎初始化异常：$error';
    }
  }
}
