// 玻璃特效的性能偏好持久化 + 质量档位与降级策略（PRD `UI-05` / `UI-06`）。
//
// 设计约定（与 `settings_store.dart` 同风格，项目已固化）：
//   · 跨页面共享状态用「进程内共享实例 + 监听回调」，页面在 `initState` 订阅、
//     `dispose` 退订并在回调里 `setState`；**不引入 Provider / Riverpod**；
//   · **不使用可变全局单例**：实例在 `main()` 里显式创建，通过构造注入；
//     [PerfPrefsStore.isLoaded] 作为显式初始化标志；
//   · 落盘一律经 [JsonStore] → [AtomicFile]，满足 `DATA-01` 原子写入（不引第三方持久化库）。
//
// 本文件是**纯 Dart**（零 Flutter / 玻璃库依赖）：档位 → 玻璃库 `GlassQuality`
// 的映射在 `lib/ui/glass_runtime.dart`，便于纯单测。
//
// **注**：设置页的「效果质量 / 降低视觉特效」两行已按负责人口径移除，
// 本 store 因此**暂无 UI 修改入口**——偏好恒为默认值（[PerfPrefs.defaultGlassTier]
// + 降低特效关），但实例仍在 `main()` 加载并 `GlassRuntime.bind`，档位折算链与
// 关档退化路径（`UI-06` ②）保持可用。
//
// 档位与开关（口径说明）：
//   · 质量档位 [GlassQualityTier]：高 / 中 / 低 / 关（`UI-05`）；
//   · 「降低视觉特效」开关 [PerfPrefs.reduceVisualEffects]：开启后**强制 minimal**
//     （`UI-05` ③ 的性能兜底）；
//   · 「特效总开关」（`UI-06`）以**「关」档**呈现——[PerfPrefs.effectsEnabled]
//     是其布尔视图，持久化的是档位本身（`UI-06` ③）。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 玻璃效果质量档位（`UI-05`）：高 / 中 / 低 / 关。
///
/// 与玻璃库 `GlassQuality`（`standard` / `premium` / `minimal`）的映射
/// 见 `glassTierConfigFor`（`lib/ui/glass_runtime.dart`）。
enum GlassQualityTier {
  /// 高：固定表面（顶栏 / 底栏）由库自动提升 `premium`，滚动区 / 浮层 `standard`
  /// ——现行 P0 口径（PRD §11.3）。
  high,

  /// 中：固定表面取消 `premium` 提升（`standard`），滚动区 / 浮层 `standard`
  /// ——省掉全量着色器开销。
  medium,

  /// 低：全部 `minimal`（`UI-05` ③ 强制 minimal；零着色器开销，滚动零 shader 调用）。
  low,

  /// 关：无玻璃，纯色 UI（`UI-06` 特效总开关关闭；功能完整）。
  off;

  /// 由持久化字符串解析；未知或缺失时回退 [GlassQualityTier.high]（默认档）。
  static GlassQualityTier fromName(String? name) {
    for (final GlassQualityTier tier in GlassQualityTier.values) {
      if (tier.name == name) {
        return tier;
      }
    }
    return GlassQualityTier.high;
  }

  /// 视觉强度序（大 = 特效更强）：high(3) > medium(2) > low(1) > off(0)。
  ///
  /// 自动降级 / 设备钳制一律「取序更小者」，见 [PerfDegradePolicy.minTier]。
  int get visualRank => switch (this) {
        GlassQualityTier.high => 3,
        GlassQualityTier.medium => 2,
        GlassQualityTier.low => 1,
        GlassQualityTier.off => 0,
      };
}

/// 性能偏好的值对象（不可变）。
class PerfPrefs {
  const PerfPrefs({
    this.glassTier = GlassQualityTier.high,
    this.reduceVisualEffects = false,
  });

  /// 默认档位（高 = 现行 P0 口径）。
  static const GlassQualityTier defaultGlassTier = GlassQualityTier.high;

  /// 质量档位（高 / 中 / 低 / 关；「关」即 `UI-06` 特效总开关关闭）。
  final GlassQualityTier glassTier;

  /// 「降低视觉特效」开关（`UI-05` ③）：开启后强制 minimal。
  final bool reduceVisualEffects;

  /// `UI-06` 特效总开关的开关态（= 档位是否为「关」）。
  ///
  /// 持久化的是 [glassTier]，本 getter 只是其布尔视图
  /// （`UI-06` ③「特效开关状态持久化」经档位持久化满足）。
  bool get effectsEnabled => glassTier != GlassQualityTier.off;

  PerfPrefs copyWith({
    GlassQualityTier? glassTier,
    bool? reduceVisualEffects,
  }) {
    return PerfPrefs(
      glassTier: glassTier ?? this.glassTier,
      reduceVisualEffects: reduceVisualEffects ?? this.reduceVisualEffects,
    );
  }

  /// 值语义相等（快照比较用）。
  @override
  bool operator ==(Object other) =>
      other is PerfPrefs &&
      other.glassTier == glassTier &&
      other.reduceVisualEffects == reduceVisualEffects;

  @override
  int get hashCode => Object.hash(glassTier, reduceVisualEffects);

  Map<String, Object?> toJson() => <String, Object?>{
        'glassTier': glassTier.name,
        'reduceVisualEffects': reduceVisualEffects,
      };

  /// 由持久化 JSON 还原；字段缺失 / 类型异常时逐项回退默认值。
  static PerfPrefs fromJson(Object? json) {
    if (json is! Map) {
      return const PerfPrefs();
    }
    final Object? tier = json['glassTier'];
    return PerfPrefs(
      glassTier: tier is String
          ? GlassQualityTier.fromName(tier)
          : GlassQualityTier.high,
      // 非 bool 一律视为 false（= 开关默认关）。
      reduceVisualEffects: json['reduceVisualEffects'] == true,
    );
  }
}

/// 性能偏好持久化服务（进程内共享，显式注入；`UI-06` ③ 持久化）。
///
/// 用法（见 `main.dart` 接线说明）：
///   ① 启动时 `final store = PerfPrefsStore(dataDir); await store.load();`
///   ② 把实例通过构造参数注入设置页 / 消费点（显式注入，不用全局变量）；
///   ③ 页面在 `initState` 里 `store.addListener(_onChanged)`、
///      在 `dispose` 里 `store.removeListener(_onChanged)`，回调内 `setState`。
class PerfPrefsStore {
  PerfPrefsStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}perf_prefs.json',
          ),
        );

  final JsonStore _store;

  PerfPrefs _prefs = const PerfPrefs();
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前性能偏好（只读快照）。未 [load] 时返回默认值。
  PerfPrefs get prefs => _prefs;

  /// 是否已完成一次加载（显式初始化标志）。
  bool get isLoaded => _loaded;

  /// 从磁盘加载；文件缺失或损坏时回退默认值（回退语义见 [JsonStore]）。
  Future<void> load() async {
    final Object? json = await _store.read();
    _prefs = PerfPrefs.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 设置玻璃质量档位（`UI-05`）。
  Future<void> setGlassTier(GlassQualityTier tier) {
    if (_prefs.glassTier == tier) {
      return Future<void>.value();
    }
    return _update(_prefs.copyWith(glassTier: tier));
  }

  /// 设置「降低视觉特效」开关（`UI-05` ③：开启后强制 minimal）。
  Future<void> setReduceVisualEffects(bool value) {
    if (_prefs.reduceVisualEffects == value) {
      return Future<void>.value();
    }
    return _update(_prefs.copyWith(reduceVisualEffects: value));
  }

  /// 恢复默认（高档 + 关闭「降低视觉特效」）。
  Future<void> resetToDefaults() => _update(const PerfPrefs());

  /// 订阅偏好变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订偏好变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 更新内存状态 → 通知监听者 → 原子落盘。
  Future<void> _update(PerfPrefs next) async {
    _prefs = next;
    _notify();
    await _store.write(next.toJson());
  }

  /// 通知所有监听者；遍历副本以容忍回调内的订阅 / 退订。
  void _notify() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

/// 性能预算与自动降级策略（`UI-06`）——**纯函数**，预期值可人工推演。
///
/// 降级链（只会更省、绝不更费）：
///   用户档位 →「降低视觉特效」强制 minimal → 低端设备钳制 → 性能预算降级。
/// 自动降级的下限是 [GlassQualityTier.low]（PRD §11.5：低端机以 `minimal` 保证可用）；
/// [GlassQualityTier.off] 只由用户显式选择，自动降级**不进入**关档。
abstract final class PerfDegradePolicy {
  /// 单帧光栅预算（60fps）——与玻璃库 `GlassPerformanceMonitor.rasterBudget` 默认一致。
  static const Duration frameBudget = Duration(milliseconds: 16);

  /// 连续超预算帧阈值——与 `GlassPerformanceMonitor.sustainedFrameThreshold`、
  /// PRD §11.4「连续 60 帧超预算」的口径一致（≈ 1 秒）。
  static const int sustainedOverBudgetFrames = 60;

  /// 用户偏好的生效档位（`UI-05` ③「降低视觉特效」的强制 minimal 在此收口）。
  ///
  /// 推演：`off` 恒为 `off`（总开关优先级最高）；否则开「降低视觉特效」→ `low`；
  /// 否则取用户档位。
  static GlassQualityTier resolveUserTier(PerfPrefs prefs) {
    if (prefs.glassTier == GlassQualityTier.off) {
      return GlassQualityTier.off;
    }
    return prefs.reduceVisualEffects ? GlassQualityTier.low : prefs.glassTier;
  }

  /// 取视觉强度更低的一档（[GlassQualityTier.visualRank] 更小者）。
  static GlassQualityTier minTier(GlassQualityTier a, GlassQualityTier b) {
    return a.visualRank <= b.visualRank ? a : b;
  }

  /// 性能预算失守一次 → 下调一档；下限 [GlassQualityTier.low]。
  ///
  /// 推演：high→medium→low→low；off→off（`off` 不是「更低的特效」而是「无特效」，
  /// 只能由用户显式选择）。
  static GlassQualityTier degradeOnce(GlassQualityTier tier) {
    return switch (tier) {
      GlassQualityTier.high => GlassQualityTier.medium,
      GlassQualityTier.medium => GlassQualityTier.low,
      GlassQualityTier.low => GlassQualityTier.low,
      GlassQualityTier.off => GlassQualityTier.off,
    };
  }

  /// 低端设备的档位上限（PRD §11.5：低端机以 `minimal` 保证可用 → 钳到 `low`）。
  ///
  /// 推演：低端设备 high→low、medium→low、low→low、off→off（[minTier] 只会更低）。
  static GlassQualityTier capForDevice(
    GlassQualityTier tier, {
    required bool isLowEndDevice,
  }) {
    return isLowEndDevice ? minTier(tier, GlassQualityTier.low) : tier;
  }

  /// 最终生效档位：用户档位 → 低端设备钳制 → 性能预算上限逐层收口。
  ///
  /// [budgetTier] 由 [PerfBudgetTracker] 触发 [degradeOnce] 累积而来（会话内状态，
  /// 不持久化——瞬时卡顿不应永久改写用户偏好）。任何钳制都只取「更低」，
  /// 因此 `off`（用户显式关闭）永不被抬高。
  static GlassQualityTier effectiveTier({
    required GlassQualityTier userTier,
    required bool isLowEndDevice,
    GlassQualityTier? budgetTier,
  }) {
    GlassQualityTier result =
        capForDevice(userTier, isLowEndDevice: isLowEndDevice);
    if (budgetTier != null) {
      result = minTier(result, budgetTier);
    }
    return result;
  }
}

/// 连续超预算帧计数器（`UI-06` 自动降级的触发器）——纯逻辑，无计时器、无 Flutter 依赖。
///
/// 用法：每帧调用 [recordFrame]（`overBudget` = 该帧光栅耗时 > [PerfDegradePolicy.frameBudget]）；
/// 返回 `true` 表示「刚刚连续 [threshold] 帧超预算，应立即
/// [PerfDegradePolicy.degradeOnce] 一档」。**边沿触发**：触发后计数清零，
/// 再连续超预算 [threshold] 帧才会触发下一档（high → medium → low 分三段推进）。
class PerfBudgetTracker {
  /// 创建计数器；[threshold] 缺省取 [PerfDegradePolicy.sustainedOverBudgetFrames]。
  PerfBudgetTracker({
    this.threshold = PerfDegradePolicy.sustainedOverBudgetFrames,
  }) : assert(threshold > 0);

  /// 触发降级所需的连续超预算帧数。
  final int threshold;

  int _consecutiveOverBudget = 0;

  /// 当前连续超预算帧数。
  int get consecutiveOverBudgetFrames => _consecutiveOverBudget;

  /// 记录一帧；返回 `true` = 刚跨过阈值、应降一档。
  bool recordFrame({required bool overBudget}) {
    if (!overBudget) {
      _consecutiveOverBudget = 0;
      return false;
    }
    _consecutiveOverBudget += 1;
    if (_consecutiveOverBudget >= threshold) {
      _consecutiveOverBudget = 0;
      return true;
    }
    return false;
  }

  /// 清零（会话切换 / 用户改档位后重来）。
  void reset() {
    _consecutiveOverBudget = 0;
  }
}
