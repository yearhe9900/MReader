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
// 视觉红线（本批口径，与 `UI-04` 一致）：正文内容层永远不透明、玻璃不嵌套；
// 本批玻璃只用于导航层（设置页顶栏见 `settings_page.dart`），故设置分组用
// [OpaqueContentSurface] 承载、控件用 Material 原生件（PRD §11.2 建议设置控件用玻璃，
// 与本红线冲突时按红线走——见回报「不确定点」）。
import 'package:flutter/material.dart';

import '../settings/perf_prefs_store.dart';
import 'glass_kit.dart';
import 'glass_runtime.dart';

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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PerfPrefs prefs = widget.perfPrefs.prefs;
    // 生效档位 = 用户档位 +「降低视觉特效」强制 minimal（`UI-05` ③）。
    final GlassQualityTier effective =
        PerfDegradePolicy.resolveUserTier(prefs);
    final GlassQualityTier userTier = prefs.glassTier;

    // 内容层不透明（`UI-04` 红线的唯一出口）；玻璃不进内容层（本批红线口径）。
    return OpaqueContentSurface(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('玻璃效果', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '调整玻璃特效的质量档位；性能预算不足时自动降档（低端设备钳制到低档）。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text('效果质量', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<GlassQualityTier>(
              segments: GlassQualityTier.values
                  .map(
                    (GlassQualityTier tier) => ButtonSegment<GlassQualityTier>(
                      value: tier,
                      label: Text(glassQualityTierLabel(tier)),
                      tooltip: glassTierConfigSummary(tier),
                    ),
                  )
                  .toList(),
              selected: <GlassQualityTier>{userTier},
              onSelectionChanged: (Set<GlassQualityTier> selection) {
                widget.perfPrefs.setGlassTier(selection.first);
              },
            ),
            const SizedBox(height: 8),
            // 「降低视觉特效」开关（`UI-05` ③）：强制 minimal。关档下特效已停用，
            // 开关置灰（其状态保留，重新开特效后继续生效）。
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('降低视觉特效'),
              subtitle: const Text('强制以 minimal 档运行（滚动更流畅）'),
              value: prefs.reduceVisualEffects,
              onChanged: userTier == GlassQualityTier.off
                  ? null
                  : (bool value) {
                      widget.perfPrefs.setReduceVisualEffects(value);
                    },
            ),
            const SizedBox(height: 4),
            Text(
              effective == userTier
                  ? glassTierConfigSummary(effective)
                  : '${glassTierConfigSummary(effective)}（已按「降低视觉特效」钳制，所选档位：'
                      '${glassQualityTierLabel(userTier)}）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
