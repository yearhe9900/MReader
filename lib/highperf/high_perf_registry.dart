// 加速能力注册表（架构文档 §A.2 / §A.3 / §A.5；`RUST-01` / `RUST-10`）。
//
// ## 它回答的唯一问题
//
// 「**这项重量级能力，此刻能不能用加速层**」——上层（`BookRegistry`）只问
// `has(capability)`，问完就走；**它拿到的永远是 `BookSource` 抽象**，不感知来源。
//
// ## 与 `capability_registry.dart` 的关系（形制照搬，代码另立）
//
// 逐字段照搬的形制：幂等 `warmUp()` + **三态**探测结果 + `reasonFor()` +
// 静态降级工厂 + 「用显式标志而非推导」（`ScriptResult._success` 的教训）。
// 另立的是契约类型；理由见架构文档 §A.4。
//
// ## 两条刻意的设计取舍（与 §A.2 的显式对齐）
//
// 1. **探测结论是实例字段，不是可变全局单例**：本项目不用 Riverpod / Provider，
//    需要注册表的地方一律**构造注入**。唯一的下沉读取点是 [HighPerfRegistryProvider]
//    （组合根写入一次，与既有 `PdfEngineProvider` 同款），见该类的注释。
// 2. **三态 `bool?`，不推导**：`null` = 尚未探测、`false` = 探测失败、`true` = 可用。
//    「未探测」与「探测失败」在 `reasonFor()` 里是两句不同的话，也是「抖动探针不得
//    把结论翻回来」（幂等）的前提。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`（因此可被 isolate 任务引用）。
import 'dart:async';

import 'high_perf_capability.dart';
import 'high_perf_error.dart';
import 'null_high_perf_engine.dart';

/// 探测硬超时（§A.2）：加载 `dlopen` + 一次轻量版本调用，正常毫秒级；3s 已是宽裕上限。
///
/// **比 JS 引擎的 5s 短**——Rust 是本地库加载，没有解释器初始化成本。
const Duration kHighPerfProbeTimeout = Duration(seconds: 3);

/// 同一能力**连续失败**多少次后惰性降级该能力（§A.3 情形 5）。
///
/// 取 2 而不是 1：一次「某本书的坏字节」不应让整个能力下线。
const int kHighPerfFailureStreakLimit = 2;

/// 编译期强制纯 Dart（`RUST-10`）：`--dart-define=MRUN_FORCE_PURE_DART=true`。
///
/// 用于对照测试（`RUST-10 ①`）与 CI——与隐藏设置项同源、同效，见 `fromEnvironment`。
const bool kForcePureDartFromEnvironment =
    bool.fromEnvironment('MRUN_FORCE_PURE_DART');

/// 强制纯 Dart 生效时的原因串（**唯一取值**，测试与日志都断言它）。
const String kForcedPureDartReason = '强制仅纯 Dart（RUST-10 开关）';

/// 未注入加速引擎时的原因串（默认回落实例的固定取值）。
const String kPureDartFallbackReason = '纯 Dart 回落（未接入加速层）';

/// 加速能力注册表：**探测一次、缓存结论、按能力回答可用性**。
///
/// 生命周期约定（`RUST-01 ③`「探测只做一次」）：
/// 组合根（`main()`）构造 → `await warmUp()` → 注入 `BookRegistry`；
/// 打开书时**不再探测**，无 IO 成本。
class HighPerfRegistry {
  /// 常规构造：**尚未探测**（`warmUp()` 才探测）。
  HighPerfRegistry({required HighPerfEngine engine, String? reason})
      : _impl = engine,
        _unavailableReason = reason;

  /// 已定型实例：探测结论直接给定，`warmUp()` 不再探测（幂等短路）。
  HighPerfRegistry._settled({
    required HighPerfEngine engine,
    required bool probeOk,
    required String reason,
  })  : _impl = engine,
        // 私有字段无法作为**命名**初始化形参（`this._x` 只允许出现在位置参数上），
        // 而 `_probeOk` 是架构 §A.2 点名的字段名（gate 审查要按名对照），
        // 不改名 → 只能显式赋值。
        // ignore: prefer_initializing_formals
        _probeOk = probeOk,
        _unavailableReason = reason;

  /// 纯 Dart 回落注册表：**进程内共享的只读实例**。
  ///
  /// 与「不引入可变全局单例」不冲突：它的 `_probeOk` 已定死为 `false`、引擎是
  /// [NullHighPerfEngine]，`noteFailure` / `noteSuccess` 对已定型实例直接短路
  /// （见各自实现），因此它**没有任何可观测的可变状态**。
  ///
  /// 共享实例换来两件事：① `const BookRegistry()` 依然成立（默认值需是非空常量路径）；
  /// ②「未注入 = 纯 Dart」这一事实在测试里可用 `identical` 取证，不必靠行为反推。
  static final HighPerfRegistry _pureDartFallback = HighPerfRegistry._settled(
    engine: const NullHighPerfEngine(),
    probeOk: false,
    reason: kPureDartFallbackReason,
  );

  /// 纯 Dart 回落（= 空引擎 + 结论 false）。
  factory HighPerfRegistry.fallback() => _pureDartFallback;

  /// 按环境构造（§A.5）：开关来源优先级 **编译期 `--dart-define` >
  /// 隐藏设置项 [debugForcePureDart] > 默认自动探测**。
  ///
  /// **不给 [engine] 与「给了一个空引擎」是两件事**：前者是「本次构建根本没有加速层」
  /// ——直接取 [fallback]（结论已定型为不可用、原因 [kPureDartFallbackReason]），
  /// **不 probe**、也不编造「版本不匹配」这类失败原因；后者才进入真实探测路径。
  ///
  /// 强制纯 Dart 时**不接管**调用方传进来的 [engine]（不 probe、不 dispose），
  /// 与 §A.5 原型一致——调用方仍应把 `engine` 交给本方法，由本方法决定用不用。
  factory HighPerfRegistry.fromEnvironment({HighPerfEngine? engine}) {
    if (_forcedPureDart) {
      return HighPerfRegistry._settled(
        engine: const NullHighPerfEngine(),
        probeOk: false,
        reason: kForcedPureDartReason,
      );
    }
    if (engine == null) return _pureDartFallback;
    return HighPerfRegistry(engine: engine);
  }

  /// 隐藏设置项（`RUST-10 ④`：**不进用户主流程、无文案**）。
  ///
  /// 设置页的「强制回落」开关（M35-T05）与测试写入这里；默认 `false`。
  /// 与编译期开关是**或**关系（见 [fromEnvironment]）。
  static bool debugForcePureDart = false;

  static bool get _forcedPureDart =>
      kForcePureDartFromEnvironment || debugForcePureDart;

  final HighPerfEngine _impl;

  /// 三态：`null` = 尚未探测、`false` = 不可用（含强制纯 Dart）、`true` = 可用。
  bool? _probeOk;

  /// 不可用时的**单一中文原因**（只进调试日志 / `describe()`，不进用户文案）。
  String? _unavailableReason;

  /// 惰性降级的能力（§A.3 情形 5：连续失败 ≥ [kHighPerfFailureStreakLimit] 次）。
  final Set<HighPerfCapability> _degraded = <HighPerfCapability>{};

  /// 各能力的**连续**失败计数（成功即清零）。
  final Map<HighPerfCapability, int> _failureStreak =
      <HighPerfCapability, int>{};

  /// 当前引擎标识（可观测用）。
  String get engineId => _impl.id;

  /// 探测是否已进行（幂等的判据；`RUST-01 ③`）。
  bool get isProbed => _probeOk != null;

  /// 是否整体走纯 Dart 回落（未探测时也返回 true——**宁保守不冒进**）。
  bool get isPureDart => _probeOk != true;

  /// 探测失败 / 强制纯 Dart 的原因；可用时为 `null`。
  String? get reason => _unavailableReason;

  /// 当前引擎的 ABI 版本串（未探测时为空串）。
  String get abiVersion => _impl.abiVersion;

  /// 已惰性降级的能力（不可变视图，供 `describe()` 与测试）。
  Set<HighPerfCapability> get degraded =>
      Set<HighPerfCapability>.unmodifiable(_degraded);

  /// 探测（**幂等**：已探测过直接返回，抖动探针不会把结论翻回来）。
  ///
  /// 五种失败情形的处置见架构文档 §A.3，逐条落点：
  ///   · 情形 1/2/3 → 引擎的 `probe()` 抛 [HighPerfException]（kind 区分），此处转成
  ///     `probeOk = false` + 中文原因；
  ///   · 情形 4 → [kRustSupportedPlatform] 编译期短路，**不尝试加载**；
  ///   · 情形 5 → **不在此处**（运行期单点失败，见 [noteFailure]）。
  ///
  /// 任何失败都**不抛出**（`RUST-01`：不阻塞主链路、不崩溃、不向用户报错）。
  Future<void> warmUp({Duration timeout = kHighPerfProbeTimeout}) async {
    if (_probeOk != null) return;

    // 情形 4：编译期判定平台不在交付面内 —— 直接短路，不给「加载必然失败」留位置。
    if (!kRustSupportedPlatform) {
      _settle(
        false,
        kHighPerfProbeReasonZh[HighPerfErrorKind.platformUnsupported],
      );
      return;
    }

    try {
      await _impl.probe().timeout(timeout);
    } on HighPerfException catch (error) {
      _settle(false, error.messageZh);
      return;
    } on TimeoutException {
      _settle(false, '加速层探测超时（>${timeout.inMilliseconds}ms）');
      return;
    } catch (_) {
      // 兜底：引擎实现未把意外收敛成 HighPerfException。
      // **不把原始报错拼进中文原因**（§D.1：不得含 Rust 类型名 / 英文 panic 原文）。
      // 文案独立成句而不复用 `kHighPerfProbeReasonZh[internal]`——那张表按定义
      // 只覆盖探测期 4 类，「内部错误」是调用期类别，借它会让边界变糊。
      _settle(false, '加速层探测失败（内部错误）');
      return;
    }

    // 情形 3：版本不匹配是**唯一可靠哨兵**——符号在、约定不在了，只靠符号查不出来。
    final String expected = kRustAbiVersion;
    final String actual = _impl.abiVersion;
    if (actual != expected) {
      _settle(
        false,
        '${kHighPerfProbeReasonZh[HighPerfErrorKind.abiMismatch]}：'
        '期望 $expected，实际 ${actual.isEmpty ? '未知' : actual}',
      );
      return;
    }

    _settle(true, null);
  }

  /// 该能力**此刻**能不能用（`BookRegistry` 择实现的唯一依据）。
  bool has(HighPerfCapability capability) {
    if (_probeOk != true) return false;
    if (_degraded.contains(capability)) return false;
    return _impl.capabilities.contains(capability);
  }

  /// 该能力为何不可用；可用时返回 `null`（`RUST-10 ②` 可观测性）。
  String? reasonFor(HighPerfCapability capability) {
    if (_probeOk == null) return '尚未探测（warmUp 未执行）';
    if (_probeOk == false) return _unavailableReason ?? '加速层不可用';
    if (_degraded.contains(capability)) {
      return '该能力连续失败 ≥$kHighPerfFailureStreakLimit 次，已惰性降级';
    }
    if (!_impl.capabilities.contains(capability)) {
      return '当前引擎（${_impl.id}）未提供该能力';
    }
    return null;
  }

  /// 记录一次**真实调用成功**：清零该能力的连续失败计数。
  ///
  /// 对已定型为不可用的实例（含纯 Dart 回落实例）是**空操作**——不回写状态，
  /// 这是共享回落实例可安全复用为进程内常量的前提。
  void noteSuccess(HighPerfCapability capability) {
    if (_probeOk != true) return;
    _failureStreak.remove(capability);
  }

  /// 记录一次**真实调用失败**（§A.3 情形 5）。
  ///
  /// 两条写死的语义：
  ///   · **不翻转 [probeOk]**——否则「某本书的坏字节」会永久禁用整个加速层；
  ///   · 同一能力**连续**失败 ≥ [kHighPerfFailureStreakLimit] 次 → 该能力惰性降级，
  ///     避免每次调用都踩同一个坑。
  ///
  /// 降级只针对**具体能力**，其余能力不受影响；上层始终拿到 `BookSource`，无感。
  void noteFailure(HighPerfCapability capability) {
    if (_probeOk != true) return;
    final int streak = (_failureStreak[capability] ?? 0) + 1;
    _failureStreak[capability] = streak;
    if (streak >= kHighPerfFailureStreakLimit) {
      _degraded.add(capability);
    }
  }

  /// 可观测快照（`RUST-10 ②`）：**只写调试日志**，不做 UI、不进用户文案。
  ///
  /// 字段与 §A.5 约定一致（`engineId` / `probeOk` / `degraded[]` / `abiVersion`），
  /// 另补 `forcedPureDart` 与逐能力结论——「能通过日志判断当前生效的是哪一份实现」
  /// 需要这两项才可判定。
  Map<String, Object?> describe() {
    return <String, Object?>{
      'engineId': _impl.id,
      'probeOk': _probeOk,
      'probeReason': _unavailableReason,
      'abiVersion': _impl.abiVersion,
      'expectedAbiVersion': kRustAbiVersion,
      'forcedPureDart': _forcedPureDart,
      'degraded': (_degraded.map((c) => c.wireId).toList()..sort()),
      'capabilities': <String, bool>{
        for (final HighPerfCapability c in HighPerfCapability.values)
          c.wireId: has(c),
      },
    };
  }

  void _settle(bool ok, String? reason) {
    _probeOk = ok;
    _unavailableReason = reason;
  }
}

/// 组合根注入点（与既有 `PdfEngineProvider` / `RarExtractor` 同款模式）。
///
/// ## 它解决什么
///
/// 派发点在 `BookRegistry.open()`，而 `openBook()`（便捷函数）被深层的纯层调用
/// （`lib/library/import_service.dart`、`lib/task/search_session.dart`、
/// `lib/ui/shelf_page.dart`）——**逐层穿参**会把加速层概念泄进这些调用点，
/// 恰好违反 `RUST-01 ④`（业务层不感知实现来源）。因此在组合根**写入一次**、
/// 深层**只读**。
///
/// ## 与架构 §A.2「不引入可变全局单例」的关系（显式取舍，别误当成违规）
///
/// §A.2 反对的是「把**探测结论**放全局，导致到处 `HighPerfRegistry.instance`」。
/// 这里不是：① 探测结论仍在实例字段里，`HighPerfRegistryProvider.current` 只是
/// **引用**；② 写入点是组合根（`main()`）与测试，**业务层无写入口**；
/// ③ 需要细粒度控制的调用点仍可走 `BookRegistry(highPerf: …)` 构造注入（优先）。
/// 这与 M2b-T01 为 `PdfEngine` 引入 `PdfEngineProvider.current` 是同一条取舍，
/// 两处保持同一形制，避免本项目出现两套 `Provider` 风格。
class HighPerfRegistryProvider {
  HighPerfRegistryProvider._();

  static HighPerfRegistry current = HighPerfRegistry.fallback();
}
