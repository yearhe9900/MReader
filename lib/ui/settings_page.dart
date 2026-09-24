// 设置页（PRD §12.1 页面 7；M2b-T07 只落「玻璃效果」分组）。
//
// 本页是玻璃质量档位的**消费点**（`UI-05` / `UI-06`）：档位生效接线后，
// 「关」档纯色退化已下沉到 [GlassNavScaffold] 等薄封装（`glass_kit.dart`），
// 本页不再做档位特判——切档后经 `GlassRuntime` 全局生效、整树跟档。
//
// 视觉红线（`UI-04` + 本批口径）：内容层永远不透明（[OpaqueContentSurface]），
// 玻璃只出现在导航层；玻璃库锁定 1.7.0 不动。
import 'package:flutter/material.dart';

import '../settings/perf_prefs_store.dart';
import 'glass_kit.dart';
import 'glass_settings_section.dart';

/// 设置页。
class SettingsPage extends StatefulWidget {
  /// 创建设置页（性能偏好服务显式注入，非全局单例）。
  const SettingsPage({super.key, required this.perfPrefs});

  /// 性能偏好服务（玻璃质量档位 / 降低视觉特效开关的持久化）。
  final PerfPrefsStore perfPrefs;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
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
    // 档位生效统一走薄封装（GlassNavScaffold 内部读 `GlassScope.configOf`）：
    // 高 / 中 / 低档玻璃壳层；「关」档自动退化纯色（`UI-06` ②）。
    return GlassNavScaffold(
      appBar: const GlassTopBar(title: Text('设置')),
      body: OpaqueContentSurface(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            GlassSettingsSection(perfPrefs: widget.perfPrefs),
            // 后续分组（主题 / 同步备份 / RUST-10 加速参数…）在此追加。
          ],
        ),
      ),
    );
  }
}
