// 书源「能力」与脚本求值的**平台无关值对象**。
//
// 本文件（以及整个 `capability/` 目录）是纯 Dart，**不 import Flutter**。
// 平台相关的实现下沉到 `lib/platform/**`，由 `main.dart` 通过注入
// [CapabilityRegistry] 接入；核心解析链路永远只依赖这里的抽象。
//
// 名字澄清：
//   · `SourceCapability`（`source_diagnostic.dart`）—— 静态体检用，回答「这条源依赖什么」；
//   · `Capability`（本文件）—— 运行期用，回答「本平台能不能提供」。
// 两者是不同的问题，刻意不合并。
//
// 本文件不依赖 Flutter。

/// 书源运行期需要的「能力」。
///
/// 与 `SourceCapability`（静态体检用）区分：那个回答「源依赖什么」，
/// 这个回答「本平台能不能提供」。
enum Capability {
  /// JS 执行。
  script,

  /// HTTP 请求。
  network,

  /// 真实浏览器内核。
  webView,

  /// 宿主变量读写（`java.get/put` / `source.*`）。
  variableIO,

  /// 文件读写。
  fileSystem,

  /// 持久化。
  database,

  /// 非 UTF-8 解码（GBK 等）。
  charset,
}

/// 脚本执行引擎种类。
enum ScriptEngineKind {
  /// 无引擎（纯规则降级）。
  none('无'),

  /// QuickJS（Android 等）。
  quickJs('QuickJS'),

  /// JavaScriptCore（iOS 系统引擎）。
  javaScriptCore('JSC'),

  /// 其它引擎/移植（如鸿蒙 `flutter_js_ohos`）。
  other('其它');

  const ScriptEngineKind(this.label);

  /// 中文显示名。
  final String label;
}

/// 脚本宿主桥接 —— 描述引擎实际暴露的**技术能力位**（不表示合规档位）。
///
/// 保留该枚举是为了表达平台差异：鸿蒙 WebView 可能缺失；`nativeClass`
/// 我们**永不实现**（真·native 反射，安全高危）。
enum ScriptBinding {
  /// 纯计算（`Math` / `String` / `JSON` / base64 / crypto）。
  pureCalc,

  /// 网络请求 `java.ajax` / `connect`。
  ajax,

  /// `java.get` / `put`、`source.*`、`cache.*`。
  variableIO,

  /// `java.webView` / `startBrowser` / `getWebViewUA`。
  webView,

  /// `Packages.*` / `org.*` / `com.*`（真·native 反射）。
  nativeClass,
}

/// 一次脚本求值请求。
class ScriptRequest {
  const ScriptRequest({
    required this.code,
    this.context = const <String, Object?>{},
    this.bindings = const <String, Object?>{},
  });

  /// 要执行的 JS 代码。
  final String code;

  /// 求值上下文（`result` / `baseUrl` / `book` 等）。
  final Map<String, Object?> context;

  /// 逐次注入的宿主对象。
  final Map<String, Object?> bindings;
}

/// 脚本求值结果。
///
/// 三个命名构造对应三种终态：成功 / 报错 / 能力缺失。
/// [isOk] 为真**仅当**由 [ScriptResult.ok] 构造 —— 注意允许
/// `value == null`（JS 返回 null/undefined 在书源求值里合法且常见）。
class ScriptResult {
  /// 成功。
  const ScriptResult.ok(this.value)
      : error = null,
        missingBindings = const <ScriptBinding>[],
        _success = true;

  /// 求值失败（引擎报错、超时等）。
  ///
  /// [error] 必须非空 —— 「失败却没有原因」不是一个合法状态。
  const ScriptResult.error(this.error)
      : assert(error != null, 'error 构造必须带非空错误信息'),
        value = null,
        missingBindings = const <ScriptBinding>[],
        _success = false;

  /// 能力缺失（如无引擎 / 缺少某项桥接）。
  ///
  /// [missingBindings] 约定非空 —— 「能力缺失却没缺什么」不是一个合法状态，
  /// 该约定由 [isOk]（恒为 false）兜底。此处**不加 `assert(…isNotEmpty)`**：
  /// 它是 `const` 构造，而 `List.length`/`isNotEmpty` 不是常量可求值表达式，
  /// 加了会让 `const ScriptResult.unsupported(<...>[...])` 编译失败。
  const ScriptResult.unsupported(this.missingBindings)
      : value = null,
        error = null,
        _success = false;

  /// 结果值（[ScriptResult.ok] 时可能有值，`null` 合法）。
  final Object? value;

  /// 错误信息（[ScriptResult.error] 时非空）。
  final String? error;

  /// 缺失的桥接能力（[ScriptResult.unsupported] 时非空）。
  final List<ScriptBinding> missingBindings;

  /// 是否由 [ScriptResult.ok] 构造。
  ///
  /// 刻意用**显式标志**而不是「`error == null && missingBindings.isEmpty` 推导」——
  /// 后者有退化空洞：`error(null)` / `unsupported(<...>[])` 会被误报成成功。
  final bool _success;

  /// 是否求值成功。
  bool get isOk => _success;
}
