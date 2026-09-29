// 玻璃质量档位的**设置 UI**（PRD `UI-05` / `UI-06`，M2b-T07）。
//
// 档位 → 玻璃库配置的唯一映射与运行时生效配置在 [GlassRuntime]（`glass_runtime.dart`）；
// 本文件只做设置页「玻璃效果」分组 UI（[GlassSettingsSection]）：质量档位（高 / 中 / 低 / 关）
// +「降低视觉特效」开关，经 [PerfPrefsStore] 持久化（`UI-06` ③）。
//
// 档位 → 渲染生效的接线（`GlassRuntime` → `glass_kit.dart` 薄封装 + `GlassScopeProvider`
// 根部下发）已随 M2b-T07 接线批落地：切档即全局生效（高档 premium 提升 / 中档取消提升 /
// 低档全部 minimal / 关档纯色回退）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-09-29 改版（参考 HyperOS 设置页风格）
// ══════════════════════════════════════════════════════════════════════════════
// 原实现是「标题 + 说明 + `SegmentedButton` 四段 + `SwitchListTile`」平铺；现改为
// [SettingsGroupCard]（不透明分组卡片）内的两行 [SettingsTile]：
//   · 「效果质量」行 —— 右侧显示当前档位，点击弹出 [showSettingsPicker] 单选弹层
//     （候选项 = 四个档位，描述取 [glassTierConfigSummary]，与原来 `SegmentedButton`
//     的 `tooltip` 同源）；
//   · 「降低视觉特效」行 —— 右侧 `Switch`，**整行也可点**（触控面积更大）；
//     关档下该行 `enabled: false`（置灰且不响应），与原 `SwitchListTile` 的
//     `onChanged: null` 等义。
// 档位说明从「脚注文本」搬到卡片 `footer`，措辞与钳制提示**逐字保留**（`UI-05` ③）。
//
// 视觉红线：卡片与行一律不透明（`settings_kit.dart` 口径 ①，PRD §11.2 已随 v2.10 改文）；
// **弹层仍走玻璃**（§11.2「浮层 = 玻璃」）——经 [showSettingsPicker] →
// [GlassOverlays.showSheet]，关档自动退化为 Material 底部弹窗。
import 'package:flutter/material.dart';

import '../settings/perf_prefs_store.dart';
import 'glass_runtime.dart';
import 'settings_kit.dart';

/// 设置页「玻璃效果」分组：质量档位（高 / 中 / 低 / 关）+「降低视觉特效」开关。
///
/// 消费 [PerfPrefsStore]：`initState` 订阅、`dispose` 退订、回调内 `setState`
/// （项目既定状态管理约定）。档位写入即原子落盘（`UI-06` ③），
/// 且经 `GlassRuntime.bind` 的偏好监听**立即全局生效**。
class GlassSettingsSection extends StatefulWidget {
  /// 创建「玻璃效果」设置分组。
  const GlassSettingsSection({super.key, required this.perfPrefs});

  /// 性能偏好服务（显式注入，非全局单例）。
  final PerfPrefsStore perfPrefs;

  @override
  State<GlassSettingsSection> createState() => _GlassSettingsSectionState();
}

class _GlassSettingsSectionState extends State<GlassSettingsSection> {
  @override
  void initState() {
    super.initState();
    widget.perfPrefs.addListener(_onPrefsChanged);
  }

  @override
  void dispose() {
    widget.perfPrefs.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onPrefsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 弹出档位单选弹层；选中后立即落盘（`GlassRuntime` 的偏好监听会整树跟档）。
  Future<void> _pickTier() async {
    final GlassQualityTier current = widget.perfPrefs.prefs.glassTier;
    final GlassQualityTier? picked = await showSettingsPicker<GlassQualityTier>(
      context: context,
      title: '效果质量',
      current: current,
      options: <SettingsPickerOption<GlassQualityTier>>[
        for (final GlassQualityTier tier in GlassQualityTier.values)
          SettingsPickerOption<GlassQualityTier>(
            value: tier,
            label: glassQualityTierLabel(tier),
            description: glassTierConfigSummary(tier),
          ),
      ],
    );
    // 弹层关闭 + 真异步落盘期间本页可能已卸载（`mounted` 必查，项目既定约定）。
    if (!mounted || picked == null || picked == current) return;
    await widget.perfPrefs.setGlassTier(picked);
  }

  /// 「降低视觉特效」开关：行点击与开关点击走同一条路径。
  void _toggleReduce() {
    final PerfPrefs prefs = widget.perfPrefs.prefs;
    widget.perfPrefs.setReduceVisualEffects(!prefs.reduceVisualEffects);
  }

  @override
  Widget build(BuildContext context) {
    final PerfPrefs prefs = widget.perfPrefs.prefs;
    // 生效档位 = 用户档位 +「降低视觉特效」强制 minimal（`UI-05` ③）。
    final GlassQualityTier effective =
        PerfDegradePolicy.resolveUserTier(prefs);
    final GlassQualityTier userTier = prefs.glassTier;
    // 关档下特效已停用，开关置灰（其状态保留，重新开特效后继续生效）。
    final bool fxAvailable = userTier != GlassQualityTier.off;

    return SettingsGroupCard(
      header: '玻璃效果',
      // 生效档位说明（措辞与改版前逐字一致，含「降低视觉特效」的钳制提示）。
      footer: effective == userTier
          ? glassTierConfigSummary(effective)
          : '${glassTierConfigSummary(effective)}（已按「降低视觉特效」钳制，所选档位：'
              '${glassQualityTierLabel(userTier)}）',
      children: <Widget>[
        SettingsTile(
          icon: Icons.blur_on_outlined,
          accent: SettingsAccents.orange,
          title: '效果质量',
          subtitle: '调整玻璃特效的质量档位；性能预算不足时自动降档（低端设备钳制到低档）。',
          value: glassQualityTierLabel(userTier),
          onTap: _pickTier,
        ),
        SettingsTile(
          icon: Icons.bolt_outlined,
          accent: SettingsAccents.green,
          title: '降低视觉特效',
          subtitle: '强制以 minimal 档运行（滚动更流畅）',
          trailing: Switch.adaptive(
            value: prefs.reduceVisualEffects,
            onChanged: fxAvailable ? (bool _) => _toggleReduce() : null,
          ),
          onTap: fxAvailable ? _toggleReduce : null,
          enabled: fxAvailable,
        ),
      ],
    );
  }
}
