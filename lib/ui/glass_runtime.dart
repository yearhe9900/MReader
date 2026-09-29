// 玻璃质量档位的**映射与运行时生效配置**（PRD `UI-05` / `UI-06`，M2b-T07 接线批）。
//
// 本文件收敛三件事（依赖图最底层，**不得**反向 import glass_kit / glass_scope）：
//   ① 档位 → 玻璃库配置的唯一映射 [glassTierConfigFor]（[GlassTierConfig]）；
//   ② 进程内生效配置入口 [GlassRuntime]（组合根注册，模式同 `PdfEngineProvider`）：
//      用户偏好 ×「降低视觉特效」强制 minimal × 低端设备钳制 × 帧预算降档，
//      经 [PerfDegradePolicy.effectiveTier] 逐层收口后折算成 [GlassTierConfig]；
//   ③ 档位标签 / 脚注文案（设置页与降级提示共用）。
//
// 消费方式（薄封装层 `glass_kit.dart` 与作用域 `glass_scope.dart` 均从此取值）：
//   · 有 [BuildContext] 时优先 `GlassScope.configOf(context)`（可被子树覆盖、
//     且建立依赖以便档位切换时自动重建）；
//   · 无 context 的静态调用点读 [GlassRuntime.config]。
//
// 视觉红线（`UI-04`）：`GlassTierConfig.scrollQuality` **严禁 `premium`**（进滚动区
// 会渲染异常，PRD §11.4），构造期 assert 守住；「关」档 = 无玻璃纯色回退（`UI-06` ②）。
//
// 自动降级（`UI-06`）触发源：
//   · 低端设备钳制 —— [GlassRuntime.bind] 的 `isLowEndDevice` 注入位（PRD 未给
//     判定标准，探测策略待拍板；缝已留，默认不钳制）；
//   · 帧预算失守 —— `PerfFrameMonitor` 连续超预算后调 [GlassRuntime.noteBudgetDegraded]，
//     会话内降档（不持久化，瞬时卡顿不改写用户偏好）。
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../settings/perf_prefs_store.dart';

/// 一个档位对应的玻璃库配置（档位 → `GlassQuality` 映射结果）。
class GlassTierConfig {
  /// 创建档位配置。
  ///
  /// [fixedSurfaceQualityOverride] 为 `null` 表示**不覆盖**——库在 `GlassScaffold`
  /// 内把固定表面自动提升为 `premium`（`UI-05` ①）；传值则显式钉档。
  /// [scrollQuality] 用于可滚动区 / 浮层，**严禁 `premium`**（`UI-05` ②，
  /// PRD §11.4：`premium` 进滚动区会渲染异常），debug 下用 [assert] 守住。
  const GlassTierConfig({
    required this.glassEnabled,
    required this.fixedSurfaceQualityOverride,
    required this.scrollQuality,
  }) : assert(
          scrollQuality != GlassQuality.premium,
          'UI-05 ②：滚动区 / 浮层严禁 premium（进滚动区会渲染异常）',
        );

  /// 是否启用玻璃；`false` = 「关」档（`UI-06` 特效总开关关闭 → 纯色回退）。
  final bool glassEnabled;

  /// 固定表面（顶栏 / 底栏）的档位覆盖值；`null` = 不覆盖（库自动提升 `premium`）。
  final GlassQuality? fixedSurfaceQualityOverride;

  /// 可滚动区 / 浮层的档位（永不 `premium`）。
  final GlassQuality scrollQuality;

  /// 值语义相等（[GlassRuntime] 变更短路判断用）。
  @override
  bool operator ==(Object other) =>
      other is GlassTierConfig &&
      other.glassEnabled == glassEnabled &&
      other.fixedSurfaceQualityOverride == fixedSurfaceQualityOverride &&
      other.scrollQuality == scrollQuality;

  @override
  int get hashCode =>
      Object.hash(glassEnabled, fixedSurfaceQualityOverride, scrollQuality);
}

/// 档位 → 玻璃库配置的**唯一映射**（`UI-05` 质量档位策略的可判定形式）。
///
/// | 档位 | 固定表面 | 滚动区 / 浮层 | 说明 |
/// |---|---|---|---|
/// | 高 | 自动 `premium`（不覆盖） | `standard` | 现行 P0 口径（PRD §11.3） |
/// | 中 | `standard`（取消提升） | `standard` | 省掉全量着色器开销 |
/// | 低 | `minimal` | `minimal` | 强制 minimal（`UI-05` ③，零着色器） |
/// | 关 | —（无玻璃） | —（无玻璃） | 纯色 UI（`UI-06` ②，功能完整） |
GlassTierConfig glassTierConfigFor(GlassQualityTier tier) {
  switch (tier) {
    case GlassQualityTier.high:
      return const GlassTierConfig(
        glassEnabled: true,
        fixedSurfaceQualityOverride: null,
        scrollQuality: GlassQuality.standard,
      );
    case GlassQualityTier.medium:
      return const GlassTierConfig(
        glassEnabled: true,
        fixedSurfaceQualityOverride: GlassQuality.standard,
        scrollQuality: GlassQuality.standard,
      );
    case GlassQualityTier.low:
      return const GlassTierConfig(
        glassEnabled: true,
        fixedSurfaceQualityOverride: GlassQuality.minimal,
        scrollQuality: GlassQuality.minimal,
      );
    case GlassQualityTier.off:
      return const GlassTierConfig(
        glassEnabled: false,
        fixedSurfaceQualityOverride: null,
        scrollQuality: GlassQuality.minimal,
      );
  }
}

/// 档位的人类可读名（设置页「效果质量」行的**当前值**与单选弹层候选项文案）。
///
/// 2026-09-29：原消费点是 `SegmentedButton` 的分段标签，该控件已随设置页改版
/// 换成「行 + 弹层单选」；本函数的契约（返回「高 / 中 / 低 / 关」）不变。
String glassQualityTierLabel(GlassQualityTier tier) {
  switch (tier) {
    case GlassQualityTier.high:
      return '高';
    case GlassQualityTier.medium:
      return '中';
    case GlassQualityTier.low:
      return '低';
    case GlassQualityTier.off:
      return '关';
  }
}

/// 当前配置的一句话说明（设置页脚注；直接消费 [glassTierConfigFor]）。
String glassTierConfigSummary(GlassQualityTier tier) {
  switch (tier) {
    case GlassQualityTier.high:
      return '顶栏 / 底栏 premium（自动提升），滚动区与浮层 standard';
    case GlassQualityTier.medium:
      return '顶栏 / 底栏与滚动区统一 standard（省掉 premium 着色器开销）';
    case GlassQualityTier.low:
      return '全部 minimal（降低视觉特效：零着色器开销，滚动更流畅）';
    case GlassQualityTier.off:
      return '特效已关闭：界面退化为纯色，功能完整可用';
  }
}

/// 玻璃档位的**运行时生效配置**（进程内共享入口，组合根注册）。
///
/// 用法（`main.dart` 接线）：
///   ① 启动时 `GlassRuntime.bind(perfPrefsStore)`（内部订阅偏好变更自动重算）；
///   ② 帧预算失守时 `PerfFrameMonitor` 调 [noteBudgetDegraded]（会话内降档）；
///   ③ 低端设备探测（策略待拍板）就绪后调 [setLowEndDevice]；
///   ④ 消费方经 `GlassScope.configOf(context)`（推荐，带重建依赖）或
///      [config]（静态点）读取。
///
/// 生效链（[PerfDegradePolicy.effectiveTier]，只会更省、绝不更费）：
///   用户档位 →「降低视觉特效」强制 minimal → 低端设备钳制 → 帧预算降档。
abstract final class GlassRuntime {
  static GlassTierConfig _config =
      glassTierConfigFor(PerfPrefs.defaultGlassTier);
  static final List<void Function()> _listeners = <void Function()>[];
  static PerfPrefsStore? _store;
  static bool _isLowEndDevice = false;

  /// 会话内帧预算降档上限（`null` = 尚未降档）；不持久化。
  static GlassQualityTier? _budgetTier;

  /// 当前生效的玻璃配置（含「关」档纯色回退标志）。
  static GlassTierConfig get config => _config;

  /// 会话内帧预算降档上限（诊断 / 测试用）。
  static GlassQualityTier? get budgetTier => _budgetTier;

  /// 低端设备判定注入位当前值。
  static bool get isLowEndDevice => _isLowEndDevice;

  /// 绑定偏好服务并立即折算一次（幂等：重复 bind 换绑最新实例）。
  static void bind(PerfPrefsStore store, {bool isLowEndDevice = false}) {
    final PerfPrefsStore? old = _store;
    old?.removeListener(_resync);
    _store = store;
    _isLowEndDevice = isLowEndDevice;
    store.addListener(_resync);
    _resync();
  }

  /// 更新低端设备判定（探测策略就绪后由组合根调用；`UI-06` 低端钳制）。
  static void setLowEndDevice(bool value) {
    if (_isLowEndDevice == value) return;
    _isLowEndDevice = value;
    _resync();
  }

  /// 帧预算失守一次 → 会话内降一档（[PerfDegradePolicy.degradeOnce]：
  /// high→medium→low→low，`off` 恒不动、不被自动降级抬入或带出）。
  static void noteBudgetDegraded() {
    final GlassQualityTier current = _budgetTier ??
        PerfDegradePolicy.effectiveTier(
          userTier: _resolvedUserTier(),
          isLowEndDevice: _isLowEndDevice,
        );
    final GlassQualityTier next = PerfDegradePolicy.degradeOnce(current);
    // 到底档（low→low、off→off）**直接短路、不留状态**：不得把「到底」写进
    // _budgetTier 当残留上限，否则用户之后切回高档会被残留钳住（min(high, off)
    // = off 就再也开不了玻璃 = off 被自动降级「带出」，违反本类契约）。
    if (next == current) return;
    _budgetTier = next;
    _resync();
  }

  /// 订阅生效配置变更（`GlassScopeProvider` 等重建触点用）。
  static void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订生效配置变更。
  static void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 测试复位（恢复默认生效配置、清空绑定与降档状态）。
  static void resetForTest() {
    _store?.removeListener(_resync);
    _store = null;
    _isLowEndDevice = false;
    _budgetTier = null;
    _config = glassTierConfigFor(PerfPrefs.defaultGlassTier);
    _listeners.clear();
  }

  /// 用户偏好折算出的档位（含「降低视觉特效」强制 minimal）。
  static GlassQualityTier _resolvedUserTier() {
    final PerfPrefsStore? store = _store;
    if (store == null) return PerfPrefs.defaultGlassTier;
    return PerfDegradePolicy.resolveUserTier(store.prefs);
  }

  /// 重算生效配置；变化才通知（遍历副本容忍回调内订阅 / 退订）。
  static void _resync() {
    final GlassQualityTier tier = PerfDegradePolicy.effectiveTier(
      userTier: _resolvedUserTier(),
      isLowEndDevice: _isLowEndDevice,
      budgetTier: _budgetTier,
    );
    final GlassTierConfig next = glassTierConfigFor(tier);
    if (next == _config) return;
    _config = next;
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
