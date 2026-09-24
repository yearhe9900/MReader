// `M2b-T07`：玻璃质量档位偏好持久化 + 性能预算降级策略单测（`UI-05` / `UI-06`）。
//
// 纯 Dart `test()`、临时目录真异步 IO，**不用** `testWidgets`（FakeAsync 区会挂死
// 真 IO，口径同 `session_store_test.dart`）。
//
// 覆盖：档位解析与视觉强度序、JSON 往返与类型回退、store 持久化 / 监听 / 损坏回退、
// 降级策略（强制 minimal、降档下限、低端设备钳制、生效档位合成）、连续超预算帧计数。
// 断言预期值均先**人工推演**（各用例注释给出推演式）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/perf_prefs_store.dart';

void main() {
  group('GlassQualityTier（档位解析与强度序）', () {
    test('fromName 逐档解析', () {
      // 推演：名字与枚举一一对应。
      expect(GlassQualityTier.fromName('high'), GlassQualityTier.high);
      expect(GlassQualityTier.fromName('medium'), GlassQualityTier.medium);
      expect(GlassQualityTier.fromName('low'), GlassQualityTier.low);
      expect(GlassQualityTier.fromName('off'), GlassQualityTier.off);
    });

    test('fromName 未知 / null 回退默认档 high', () {
      // 推演：与 PerfPrefs.fromJson 的缺省口径一致（默认档 = high）。
      expect(GlassQualityTier.fromName('bogus'), GlassQualityTier.high);
      expect(GlassQualityTier.fromName(null), GlassQualityTier.high);
      expect(GlassQualityTier.fromName(''), GlassQualityTier.high);
    });

    test('visualRank：high(3) > medium(2) > low(1) > off(0)', () {
      // 推演：枚举声明序即强度序的反向，按定义逐个核对。
      expect(GlassQualityTier.high.visualRank, 3);
      expect(GlassQualityTier.medium.visualRank, 2);
      expect(GlassQualityTier.low.visualRank, 1);
      expect(GlassQualityTier.off.visualRank, 0);
    });
  });

  group('PerfPrefs（值对象与 JSON）', () {
    test('默认值：高档 + 不降特效 + 特效总开关开', () {
      const PerfPrefs prefs = PerfPrefs();
      expect(prefs.glassTier, GlassQualityTier.high);
      expect(prefs.reduceVisualEffects, isFalse);
      expect(prefs.effectsEnabled, isTrue);
    });

    test('effectsEnabled 是档位的布尔视图（关档 = 总开关关）', () {
      // 推演：off → false；其余三档 → true。
      expect(
        const PerfPrefs(glassTier: GlassQualityTier.off).effectsEnabled,
        isFalse,
      );
      expect(
        const PerfPrefs(glassTier: GlassQualityTier.low).effectsEnabled,
        isTrue,
      );
    });

    test('JSON 往返逐字段一致', () {
      const PerfPrefs prefs = PerfPrefs(
        glassTier: GlassQualityTier.off,
        reduceVisualEffects: true,
      );
      // 推演：toJson 写枚举名与 bool，fromJson 同构还原。
      expect(PerfPrefs.fromJson(prefs.toJson()), prefs);
      expect(prefs.toJson(), <String, Object?>{
        'glassTier': 'off',
        'reduceVisualEffects': true,
      });
    });

    test('字段缺失回退默认值', () {
      // 推演：{glassTier: medium} → 档位 medium、开关缺省 false。
      final PerfPrefs prefs = PerfPrefs.fromJson(<String, Object?>{
        'glassTier': 'medium',
      });
      expect(prefs.glassTier, GlassQualityTier.medium);
      expect(prefs.reduceVisualEffects, isFalse);
    });

    test('类型异常 / 未知值逐项回退默认值', () {
      // 推演：'bogus' 非枚举名 → high；'yes' 非 bool → false；42 非 String → high。
      final PerfPrefs prefs = PerfPrefs.fromJson(<String, Object?>{
        'glassTier': 'bogus',
        'reduceVisualEffects': 'yes',
      });
      expect(prefs.glassTier, GlassQualityTier.high);
      expect(prefs.reduceVisualEffects, isFalse);

      final PerfPrefs typed = PerfPrefs.fromJson(<String, Object?>{
        'glassTier': 42,
        'reduceVisualEffects': 1,
      });
      expect(typed.glassTier, GlassQualityTier.high);
      expect(typed.reduceVisualEffects, isFalse);
    });

    test('整体非 Map（null / 列表 / 数字）→ 全默认', () {
      // 推演：顶层不是对象一律整个回退默认值。
      expect(PerfPrefs.fromJson(null), const PerfPrefs());
      expect(PerfPrefs.fromJson(<Object?>[]), const PerfPrefs());
      expect(PerfPrefs.fromJson(7), const PerfPrefs());
    });

    test('copyWith 逐字段替换', () {
      // 推演：只改传入字段，未传字段保持原值。
      const PerfPrefs base = PerfPrefs();
      expect(
        base.copyWith(reduceVisualEffects: true),
        const PerfPrefs(reduceVisualEffects: true),
      );
      expect(
        base.copyWith(glassTier: GlassQualityTier.low).glassTier,
        GlassQualityTier.low,
      );
    });
  });

  group('PerfPrefsStore（持久化 / 监听，真 IO）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('perf_prefs_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('无文件时 load 回退默认值并置 isLoaded', () async {
      // 推演：从未写入 → JsonStore.read() = null → fromJson(null) = 默认。
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      expect(store.isLoaded, isFalse);
      await store.load();
      expect(store.isLoaded, isTrue);
      expect(store.prefs, const PerfPrefs());
    });

    test('setGlassTier 更新内存 + 通知监听 + 落盘可往返（UI-06 ③）', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      int notified = 0;
      store.addListener(() => notified++);

      await store.setGlassTier(GlassQualityTier.medium);
      expect(store.prefs.glassTier, GlassQualityTier.medium);
      expect(notified, 1);

      // 推演：新实例读同一目录应还原 medium（重启不丢 = 持久化）。
      final PerfPrefsStore reloaded = PerfPrefsStore(tempDir);
      await reloaded.load();
      expect(reloaded.prefs.glassTier, GlassQualityTier.medium);
    });

    test('「降低视觉特效」开关持久化往返（UI-05 ③）', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setReduceVisualEffects(true);
      await store.setGlassTier(GlassQualityTier.low);

      // 推演：两个字段独立落盘，重开均还原。
      final PerfPrefsStore reloaded = PerfPrefsStore(tempDir);
      await reloaded.load();
      expect(reloaded.prefs.reduceVisualEffects, isTrue);
      expect(reloaded.prefs.glassTier, GlassQualityTier.low);
    });

    test('关档（特效总开关关）同样持久化', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.off);

      final PerfPrefsStore reloaded = PerfPrefsStore(tempDir);
      await reloaded.load();
      expect(reloaded.prefs.glassTier, GlassQualityTier.off);
      expect(reloaded.prefs.effectsEnabled, isFalse);
    });

    test('set 同值为 no-op（不通知、不改状态）', () async {
      // 推演：默认已是 high / false，同值 set 直接短路。
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      int notified = 0;
      store.addListener(() => notified++);

      await store.setGlassTier(GlassQualityTier.high);
      await store.setReduceVisualEffects(false);
      expect(notified, 0);
    });

    test('resetToDefaults 恢复高档 + 关闭降特效', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.off);
      await store.setReduceVisualEffects(true);

      await store.resetToDefaults();
      expect(store.prefs, const PerfPrefs());
    });

    test('removeListener 后不再被通知', () async {
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      int notified = 0;
      void listener() => notified++;
      store.addListener(listener);
      await store.setGlassTier(GlassQualityTier.medium);
      store.removeListener(listener);
      await store.setGlassTier(GlassQualityTier.low);
      // 推演：第一次 set 通知 1 次，退订后第二次 set 不再计数。
      expect(notified, 1);
    });

    test('文件损坏（非法 JSON）→ 回退默认值，不抛异常', () async {
      // 推演：JsonStore 把损坏文件隔离为 .corrupt，.bak 缺失 → read() = null
      //      → fromJson(null) = 默认值。
      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}perf_prefs.json',
      );
      await file.writeAsString('not-json{{');
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      expect(store.prefs, const PerfPrefs());
    });

    test('落盘内容为 JSON 对象且字段名稳定', () async {
      // 推演：{glassTier: 'low', reduceVisualEffects: true} 两键逐字核对。
      final PerfPrefsStore store = PerfPrefsStore(tempDir);
      await store.load();
      await store.setGlassTier(GlassQualityTier.low);
      await store.setReduceVisualEffects(true);

      final File file = File(
        '${tempDir.path}${Platform.pathSeparator}perf_prefs.json',
      );
      final Map<String, Object?> written =
          (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
      expect(written, <String, Object?>{
        'glassTier': 'low',
        'reduceVisualEffects': true,
      });
    });
  });

  group('PerfDegradePolicy（降级策略）', () {
    test('resolveUserTier：「降低视觉特效」强制 minimal（UI-05 ③）', () {
      // 推演：非关档 + 开关开 → low；开关关 → 原档；关档 → 恒 off（总开关优先）。
      PerfPrefs prefs(GlassQualityTier tier, bool reduce) =>
          PerfPrefs(glassTier: tier, reduceVisualEffects: reduce);
      expect(
        PerfDegradePolicy.resolveUserTier(prefs(GlassQualityTier.high, true)),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.resolveUserTier(prefs(GlassQualityTier.medium, true)),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.resolveUserTier(prefs(GlassQualityTier.low, true)),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.resolveUserTier(prefs(GlassQualityTier.high, false)),
        GlassQualityTier.high,
      );
      expect(
        PerfDegradePolicy.resolveUserTier(prefs(GlassQualityTier.medium, false)),
        GlassQualityTier.medium,
      );
      expect(
        PerfDegradePolicy.resolveUserTier(prefs(GlassQualityTier.off, true)),
        GlassQualityTier.off,
      );
      expect(
        PerfDegradePolicy.resolveUserTier(prefs(GlassQualityTier.off, false)),
        GlassQualityTier.off,
      );
    });

    test('degradeOnce：逐档下调，下限 low，off 不动', () {
      // 推演：high→medium→low→low（自动降级到 minimal 为止）；off→off。
      expect(
        PerfDegradePolicy.degradeOnce(GlassQualityTier.high),
        GlassQualityTier.medium,
      );
      expect(
        PerfDegradePolicy.degradeOnce(GlassQualityTier.medium),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.degradeOnce(GlassQualityTier.low),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.degradeOnce(GlassQualityTier.off),
        GlassQualityTier.off,
      );
    });

    test('capForDevice：低端设备钳到 low（off 除外）', () {
      // 推演：minTier(·, low)：high→low、medium→low、low→low、off→off（off 强度 0
      // 最低，minTier 取 off）。
      expect(
        PerfDegradePolicy.capForDevice(
          GlassQualityTier.high,
          isLowEndDevice: true,
        ),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.capForDevice(
          GlassQualityTier.medium,
          isLowEndDevice: true,
        ),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.capForDevice(
          GlassQualityTier.off,
          isLowEndDevice: true,
        ),
        GlassQualityTier.off,
      );
      // 非低端设备：原样通过。
      expect(
        PerfDegradePolicy.capForDevice(
          GlassQualityTier.high,
          isLowEndDevice: false,
        ),
        GlassQualityTier.high,
      );
    });

    test('minTier 取视觉强度更低者（off 最低）', () {
      // 推演：按 visualRank 比较，相等时取 a。
      expect(
        PerfDegradePolicy.minTier(GlassQualityTier.high, GlassQualityTier.low),
        GlassQualityTier.low,
      );
      expect(
        PerfDegradePolicy.minTier(
          GlassQualityTier.off,
          GlassQualityTier.medium,
        ),
        GlassQualityTier.off,
      );
      expect(
        PerfDegradePolicy.minTier(
          GlassQualityTier.medium,
          GlassQualityTier.medium,
        ),
        GlassQualityTier.medium,
      );
    });

    test('effectiveTier 合成：预算只降不升、off 恒不被抬高', () {
      // 推演：min(min(user, low?), budget)。
      // ① 预算 medium 压过用户 high → medium；
      expect(
        PerfDegradePolicy.effectiveTier(
          userTier: GlassQualityTier.high,
          isLowEndDevice: false,
          budgetTier: GlassQualityTier.medium,
        ),
        GlassQualityTier.medium,
      );
      // ② 预算 high 不会把用户 medium 抬高 → medium；
      expect(
        PerfDegradePolicy.effectiveTier(
          userTier: GlassQualityTier.medium,
          isLowEndDevice: false,
          budgetTier: GlassQualityTier.high,
        ),
        GlassQualityTier.medium,
      );
      // ③ 低端设备把 high 钳到 low，预算 high 不抬 → low；
      expect(
        PerfDegradePolicy.effectiveTier(
          userTier: GlassQualityTier.high,
          isLowEndDevice: true,
          budgetTier: GlassQualityTier.high,
        ),
        GlassQualityTier.low,
      );
      // ④ 无预算降级、非低端：原样；
      expect(
        PerfDegradePolicy.effectiveTier(
          userTier: GlassQualityTier.high,
          isLowEndDevice: false,
        ),
        GlassQualityTier.high,
      );
      // ⑤ 用户关档：任何钳制都不抬高 → off。
      expect(
        PerfDegradePolicy.effectiveTier(
          userTier: GlassQualityTier.off,
          isLowEndDevice: true,
          budgetTier: GlassQualityTier.low,
        ),
        GlassQualityTier.off,
      );
    });

    test('预算常量与玻璃库口径一致（16ms / 60 帧）', () {
      // 推演：PRD §11.4「连续 60 帧超预算」+ 60fps 帧预算 16ms。
      expect(PerfDegradePolicy.frameBudget, const Duration(milliseconds: 16));
      expect(PerfDegradePolicy.sustainedOverBudgetFrames, 60);
    });
  });

  group('PerfBudgetTracker（连续超预算帧计数）', () {
    test('连续满阈值触发一次（边沿触发，触发后清零）', () {
      // 推演（threshold=3）：over,over → false,false；第 3 帧 over → true（计数清零）；
      // 再 3 帧 over → 又一次 true。
      final PerfBudgetTracker tracker = PerfBudgetTracker(threshold: 3);
      expect(tracker.recordFrame(overBudget: true), isFalse);
      expect(tracker.recordFrame(overBudget: true), isFalse);
      expect(tracker.recordFrame(overBudget: true), isTrue);
      expect(tracker.consecutiveOverBudgetFrames, 0);
      expect(tracker.recordFrame(overBudget: true), isFalse);
      expect(tracker.recordFrame(overBudget: true), isFalse);
      expect(tracker.recordFrame(overBudget: true), isTrue);
    });

    test('预算内帧打断连续计数', () {
      // 推演：over,over,good → 计数归 0；再来 over,over 只到 2 < 3，不触发。
      final PerfBudgetTracker tracker = PerfBudgetTracker(threshold: 3);
      tracker.recordFrame(overBudget: true);
      tracker.recordFrame(overBudget: true);
      expect(tracker.recordFrame(overBudget: false), isFalse);
      expect(tracker.consecutiveOverBudgetFrames, 0);
      expect(tracker.recordFrame(overBudget: true), isFalse);
      expect(tracker.recordFrame(overBudget: true), isFalse);
    });

    test('默认阈值 60 帧（≈1 秒 @60fps）', () {
      // 推演：前 59 帧 over 均 false，第 60 帧 over → true。
      final PerfBudgetTracker tracker = PerfBudgetTracker();
      expect(tracker.threshold, 60);
      for (int i = 0; i < 59; i++) {
        expect(tracker.recordFrame(overBudget: true), isFalse,
            reason: '第 ${i + 1} 帧不应触发');
      }
      expect(tracker.recordFrame(overBudget: true), isTrue);
    });

    test('reset 清零计数', () {
      // 推演：over,over 后 reset → 计数 0，再 2 帧 over 不触发。
      final PerfBudgetTracker tracker = PerfBudgetTracker(threshold: 3);
      tracker.recordFrame(overBudget: true);
      tracker.recordFrame(overBudget: true);
      tracker.reset();
      expect(tracker.consecutiveOverBudgetFrames, 0);
      expect(tracker.recordFrame(overBudget: true), isFalse);
      expect(tracker.recordFrame(overBudget: true), isFalse);
    });
  });
}
