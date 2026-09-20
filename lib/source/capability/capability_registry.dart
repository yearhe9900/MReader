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

  /// 不可用原因（构造时预置 + [warmUp] 探测失败写入，探测成功时移除）。
  final Map<Capability, String> _unavailableReasons = <Capability, String>{};

  /// 脚本引擎的**探测结果**，三态：
  /// `null` = 未探测（乐观）；`true` = 探测通过；`false` = 探测失败。
  ///
  /// 它是「库能加载但引擎初始化失败」这类失败形式的唯一记录点 ——
  /// 此时 [ScriptCapability.isAvailable] 仍为 true，只有本字段能把它翻成不可用。
  bool? _scriptProbeOk;

  /// 注入的脚本能力实现。
  ScriptCapability get script => _script;

  /// 是否**可用**某项能力。
  ///
  /// 语义契约（重要）：
  ///   · `script` 判定的是「**可用**」而非「**存在**」——
  ///     [ScriptCapability.isAvailable] 只表示实现类存在，不代表引擎能跑；
  ///     必须再叠加 [warmUp] 的探测结果 `_scriptProbeOk != false`。
  ///   · 未探测（`_scriptProbeOk == null`）时**按 `isAvailable` 乐观判断**,
  ///     以保证「`warmUp()` 是可选调用」——纯 Dart 测试与尚未装配 `main` 的
  ///     场景不应因缺少探测而改变结论。
  ///   · 因此**读取 `has(Capability.script)` 之前应先调用 [warmUp]**，
  ///     否则只能拿到乐观结论；`probe()` 失败后 `has(script)` 会翻为 false。
  ///   · 其余能力走静态集合 `_extra`。
  bool has(Capability c) => c == Capability.script
      ? _script.isAvailable && _scriptProbeOk != false
      : _extra.contains(c);

  /// 不可用时的原因（给体检 / UI 用）；可用或未记录时为 null。
  String? reasonFor(Capability c) => _unavailableReasons[c];

  /// 探针：初始化引擎、**翻转可用状态**并记录失败原因。
  ///
  /// `main.dart` 启动时调用一次。**绝不抛异常、绝不阻塞启动**：
  ///   · `probe()` 返回 false / 抛异常 → `_scriptProbeOk = false`
  ///     （于是 [has]`(Capability.script)` 立即翻为 false，降级生效）并写原因；
  ///   · `probe()` 通过 → `_scriptProbeOk = true` 并**移除**过时的不可用原因。
  ///
  /// 所以它同时影响 [has] 与 [reasonFor] —— 调用方应在读取能力结论前调用它。
  Future<void> warmUp() async {
    if (!_script.isAvailable) return;
    try {
      if (await _script.probe()) {
        _scriptProbeOk = true;
        _unavailableReasons.remove(Capability.script);
      } else {
        _scriptProbeOk = false;
        _unavailableReasons[Capability.script] = '引擎探测失败';
      }
    } catch (error) {
      _scriptProbeOk = false;
      _unavailableReasons[Capability.script] = '引擎初始化异常：$error';
    }
  }
}
