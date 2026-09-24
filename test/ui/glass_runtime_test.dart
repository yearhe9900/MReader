// `M2b-T07`：玻璃档位生效链单测（`glass_runtime.dart` 的映射 + `GlassRuntime` 生效态）。
//
// 纯 Dart `test()` + 临时目录真异步 IO（口径同 `perf_prefs_store_test.dart`），
// 不用 `testWidgets`（FakeAsync 区会挂死真 IO）。
//
// 覆盖：档位 → 配置唯一映射、premium 红线、生效折算链（用户档位 →「降低视觉特效」
// → 低端钳制 → 帧预算降档）、变化才通知、降档不持久化、到底档不钉死生效档、
// resetForTest 隔离。断言预期值均先**人工推演**（各用例注释给出推演式）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_runtime.dart';

void main() {
  // 进程内静态态隔离（flutter test 文件内串行；每用例前后复位）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  group('glassTierConfigFor（档位 → 配置唯一映射）', () {
    test('高档：不覆盖固定表面（库自动提升）+ 滚动区 standard', () {
      // 推演：高档 = 现行 P0 口径（PRD §11.3）。
      final GlassTierConfig config = glassTierConfigFor(GlassQualityTier.high);
      expect(config.glassEnabled, isTrue);
      expect(config.fixedSurfaceQualityOverride, isNull);
      expect(config.scrollQuality, GlassQuality.standard);
    });

    test('中档：固定表面取消提升（standard）+ 滚动区 standard', () {
      // 推演：中档省掉 premium 着色器开销（映射表第二行）。
      final GlassTierConfig config = glassTierConfigFor(GlassQualityTier.medium);
      expect(config.glassEnabled, isTrue);
      expect(config.fixedSurfaceQualityOverride, GlassQuality.standard);
      expect(config.scrollQuality, GlassQuality.standard);
    });

    test('低档：全部 minimal（UI-05 ③ 强制 minimal，零着色器）', () {
      final GlassTierConfig config = glassTierConfigFor(GlassQualityTier.low);
      expect(config.glassEnabled, isTrue);
      expect(config.fixedSurfaceQualityOverride, GlassQuality.minimal);
      expect(config.scrollQuality, GlassQuality.minimal);
    });

    test('关档：无玻璃（UI-06 ②），scrollQuality 取 minimal 兜底且非 premium', () {
      // 推演：glassEnabled=false 是唯一开关；scrollQuality 仍须守 premium 红线。
      final GlassTierConfig config = glassTierConfigFor(GlassQualityTier.off);
      expect(config.glassEnabled, isFalse);
      expect(config.fixedSurfaceQualityOverride, isNull);
      expect(config.scrollQuality, GlassQuality.minimal);
    });
  });

  group('GlassTierConfig（premium 红线与值语义）', () {
    test('scrollQuality == premium 构造期拒绝（UI-05 ②）', () {
      // 推演：debug 断言拦截；premium 进滚动区会渲染异常（PRD §11.4）。
      // 注意：必须**非 const** 构造才能在运行期触发断言（const 会在编译期报错）。
      expect(
        () => GlassTierConfig(
          glassEnabled: true,
          fixedSurfaceQualityOverride: null,
          scrollQuality: GlassQuality.premium,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('值语义相等（同字段同值 = ==，变更短路判断用）', () {
      // 推演：与 glassTierConfigFor(medium) 逐字段相同 → 相等；任一字段不同 → 不等。
      const GlassTierConfig medium = GlassTierConfig(
        glassEnabled: true,
        fixedSurfaceQualityOverride: GlassQuality.standard,
        scrollQuality: GlassQuality.standard,
      );
      expect(glassTierConfigFor(GlassQualityTier.medium), medium);
      expect(glassTierConfigFor(GlassQualityTier.low) == medium, isFalse);
    });
  });

  group('GlassRuntime（生效态折算，真 IO）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('glass_runtime_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('未绑定 store = 默认高档', () {
      // 推演：PerfPrefs.defaultGlassTier = high。
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.high));
    });

    test('bind 跟随用户档位；仅变化时通知', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      GlassRuntime.bind(store);
      int notified = 0;
      GlassRuntime.addListener(() => notified++);

      // 推演：high → medium 配置变 → 通知 1；medium → high → 通知 2。
      await store.setGlassTier(GlassQualityTier.medium);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.medium));
      expect(notified, 1);

      await store.setGlassTier(GlassQualityTier.high);
      expect(notified, 2);

      // 推演：同值 set 是 store 层短路（不发通知）→ 仍 2。
      await store.setGlassTier(GlassQualityTier.high);
      expect(notified, 2);
    });

    test('「降低视觉特效」强制 minimal；生效配置不变时不通知（UI-05 ③）', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.high);
      GlassRuntime.bind(store);
      int notified = 0;
      GlassRuntime.addListener(() => notified++);

      // 推演：high + 降特效 → resolveUserTier = low → 低档配置 → 通知 1。
      await store.setReduceVisualEffects(true);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.low));
      expect(notified, 1);

      // 推演：再把档位设为 low（降特效仍开）→ resolveUserTier 仍是 low →
      // 生效配置不变 → 不通知。
      await store.setGlassTier(GlassQualityTier.low);
      expect(notified, 1);
    });

    test('关档优先于「降低视觉特效」（off 恒为 off）', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.off);
      await store.setReduceVisualEffects(true);
      GlassRuntime.bind(store);

      // 推演：resolveUserTier 先短路 off → 不受降特效开关影响。
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.off));
    });

    test('低端设备钳制到低档（UI-06 / PRD §11.5），可恢复', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      GlassRuntime.bind(store);

      // 推演：capForDevice(high, lowEnd) = minTier(high, low) = low；
      // 关掉低端判定后恢复 high。
      GlassRuntime.setLowEndDevice(true);
      expect(GlassRuntime.isLowEndDevice, isTrue);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.low));

      GlassRuntime.setLowEndDevice(false);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.high));
    });

    test('帧预算降档链：高档 → 中 → 低 → 到底（会话内）', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      GlassRuntime.bind(store);

      // 推演：degradeOnce(high) = medium → medium 配置；再 degradeOnce(medium)
      // = low → 低档配置；第三次 degradeOnce(low) = low 到底不动。
      GlassRuntime.noteBudgetDegraded();
      expect(GlassRuntime.budgetTier, GlassQualityTier.medium);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.medium));

      GlassRuntime.noteBudgetDegraded();
      expect(GlassRuntime.budgetTier, GlassQualityTier.low);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.low));

      GlassRuntime.noteBudgetDegraded();
      expect(GlassRuntime.budgetTier, GlassQualityTier.low);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.low));
    });

    test('降档不持久化（瞬时卡顿不改写用户偏好）', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      GlassRuntime.bind(store);
      GlassRuntime.noteBudgetDegraded();
      GlassRuntime.noteBudgetDegraded();

      // 推演：noteBudgetDegraded 只改会话内 _budgetTier，store.prefs 与磁盘不动。
      expect(store.prefs.glassTier, GlassQualityTier.high);
      final PerfPrefsStore reloaded = PerfPrefsStore(tempDir);
      await reloaded.load();
      expect(reloaded.prefs.glassTier, GlassQualityTier.high);
    });

    test('到底档不钉死生效档（off 不被自动降级「带出」）', () async {
      // 回归（人工推演抓出）：off 下降档到底后若把 off 写进 _budgetTier 残留，
      // 用户切回高档会被 min(high, off) = off 钳死——再也开不了玻璃。
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.off);
      GlassRuntime.bind(store);
      GlassRuntime.noteBudgetDegraded();
      GlassRuntime.noteBudgetDegraded();

      // 推演：off 到底短路 → 不留降档残留，配置恒 off。
      expect(GlassRuntime.budgetTier, isNull);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.off));

      // 推演：用户显式切回 high → 不被残留钳住，恢复高档。
      await store.setGlassTier(GlassQualityTier.high);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.high));
    });

    test('到底档不钉死生效档（用户低档后可恢复高档）', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.low);
      GlassRuntime.bind(store);
      GlassRuntime.noteBudgetDegraded();

      // 推演：low→low 到底短路，_budgetTier 不写残留 → 切回 high 即高档。
      expect(GlassRuntime.budgetTier, isNull);
      await store.setGlassTier(GlassQualityTier.high);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.high));
    });

    test('resetForTest 复位生效态并解除绑定', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.off);
      GlassRuntime.bind(store, isLowEndDevice: true);
      GlassRuntime.noteBudgetDegraded();

      GlassRuntime.resetForTest();
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.high));
      expect(GlassRuntime.budgetTier, isNull);
      expect(GlassRuntime.isLowEndDevice, isFalse);

      // 推演：解绑后 store 变更不再影响生效态。
      await store.setGlassTier(GlassQualityTier.medium);
      expect(GlassRuntime.config, glassTierConfigFor(GlassQualityTier.high));
    });
  });

  group('档位文案（设置页标签与脚注）', () {
    test('四档均有标签与一句话说明', () {
      // 推演：逐档非空；标签为单字 高 / 中 / 低 / 关。
      for (final GlassQualityTier tier in GlassQualityTier.values) {
        expect(glassQualityTierLabel(tier), isNotEmpty);
        expect(glassTierConfigSummary(tier), isNotEmpty);
      }
      expect(glassQualityTierLabel(GlassQualityTier.high), '高');
      expect(glassQualityTierLabel(GlassQualityTier.medium), '中');
      expect(glassQualityTierLabel(GlassQualityTier.low), '低');
      expect(glassQualityTierLabel(GlassQualityTier.off), '关');
    });
  });
}
