// 无引擎时的降级实现。
//
// 纯 Dart，保证核心链路在没有平台引擎时**可编译、可运行**：
// 所有 `evaluate` 一律返回 [ScriptResult.unsupported]，绝不抛异常。
//
// 本文件不依赖 Flutter。

import 'capability.dart';
import 'script_capability.dart';

/// 空脚本能力 —— 无 JS 引擎时的降级实现。
///
/// 它是「方案 A（纯规则模式）」的运行时形态：不接任何引擎时，
/// 书源里依赖 JS 的字段会被判为「本平台不可用」，其余纯规则字段照常可跑。
class NullScriptCapability implements ScriptCapability {
  const NullScriptCapability();

  @override
  String get id => 'none';

  @override
  ScriptEngineKind get kind => ScriptEngineKind.none;

  @override
  String get label => '未接入 JS 引擎';

  @override
  bool get isAvailable => false;

  @override
  Set<ScriptBinding> get supportedBindings => const <ScriptBinding>{};

  @override
  Future<bool> probe() async => false;

  @override
  Future<ScriptResult> evaluate(ScriptRequest request) async =>
      const ScriptResult.unsupported(<ScriptBinding>[ScriptBinding.pureCalc]);

  @override
  void dispose() {}
}
