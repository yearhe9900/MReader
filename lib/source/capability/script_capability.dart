// 脚本执行能力（平台无关抽象）。
//
// **实现类可 import Flutter（放在 `lib/platform/**`），接口类不可。**
// 本文件位于 `lib/source/capability/`，保持纯 Dart、零平台依赖。
//
// 本文件不依赖 Flutter。

import 'capability.dart';

/// 脚本执行能力。
///
/// 这是「能力可插拔」的契约：核心链路只认这个接口，
/// 平台侧（Android / iOS / 鸿蒙 / 桌面）各自提供实现并在 `main.dart` 注入。
abstract class ScriptCapability {
  /// 引擎标识，用于体检与日志，如 `quickjs` / `jsc` / `flutter_js_ohos` / `none`。
  String get id;

  /// 引擎种类。
  ScriptEngineKind get kind;

  /// 人类可读的平台/引擎描述。
  String get label;

  /// 同步可用性（构造后即可查询，不做 IO）。
  bool get isAvailable;

  /// 该实现实际支持哪些宿主桥接 —— 语义是「**技术能力位**」，不是「合规档位」。
  ///
  /// 例：鸿蒙 WebView 插件缺失时不含 [ScriptBinding.webView]；
  /// [ScriptBinding.nativeClass] 我们永不实现。
  Set<ScriptBinding> get supportedBindings;

  /// 异步探测（真正跑一段最小 JS，验证引擎可初始化）。
  ///
  /// 返回 `false` 或抛异常都表示不可用；调用方据此降级。
  Future<bool> probe();

  /// 求值。
  ///
  /// **契约：不得抛异常** —— 失败一律走 [ScriptResult.error]，
  /// 由调用方做字段级降级，绝不炸掉整条书源。
  Future<ScriptResult> evaluate(ScriptRequest request);

  /// 释放引擎。
  void dispose();
}
