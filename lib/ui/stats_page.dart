// M3-T10：统计页外壳 + 总览（`STAT-03`）。
//
// 形制（`UI-04` 红线）：玻璃顶栏（导航层）+ [OpaqueContentSurface] 承载正文，
// 总览卡片与设置行**一律不透明**——统计图表 / 卡片 / 列表行绝不进玻璃
// （PRD §6.2 / §11.2：仅操作按钮 / 弹窗 / 菜单可用玻璃）。
//
// 状态管理：`StatefulWidget` + `setState` + [StatsService] 监听回调
// （§15.5 禁 Riverpod / Provider）；服务实例由组合根经 `HomeShell` 注入。
// 首次进入异步 [StatsService.load]，载入完成回调里 setState 一次。
//
// 页面排布（`STAT-03`）：总览卡片（累计总时长「X 至今」/ 活跃天数 / 书籍数）
// → 统计设置（起始日期 / 清空统计数据，形制同设置页分组卡片）。
// 后续 M3-T11~T13 的柱状图 / 热力图 / 排行依次插在总览卡片之后。
import 'dart:async';

import 'package:flutter/material.dart';

import '../stats/stats_service.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'settings_kit.dart';
import 'stats/overview_card.dart';

/// 阅读统计页。
class StatsPage extends StatefulWidget {
  /// 创建统计页（[service] 由组合根注入，进程内唯一实例）。
  const StatsPage({super.key, required this.service});

  /// 统计服务（载入 / 聚合 / 起始日期 / 清空）。
  final StatsService service;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onStatsChanged);
    if (!widget.service.isLoaded) {
      unawaited(widget.service.load());
    }
  }

  @override
  void didUpdateWidget(covariant StatsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      oldWidget.service.removeListener(_onStatsChanged);
      widget.service.addListener(_onStatsChanged);
      if (!widget.service.isLoaded) {
        unawaited(widget.service.load());
      }
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_onStatsChanged);
    super.dispose();
  }

  void _onStatsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final StatsService service = widget.service;
    return GlassNavScaffold(
      appBar: GlassTopBar(title: const Text('统计')),
      body: OpaqueContentSurface(
        child: !service.isLoaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, kShellBottomInset),
                children: <Widget>[
                  OverviewCard(
                    overview: service.overview,
                    sinceDay: service.sinceDay,
                  ),
                  SettingsGroupCard(
                    header: '统计设置',
                    children: <Widget>[
                      SettingsTile(
                        icon: Icons.event,
                        accent: SettingsAccents.blue,
                        title: '起始日期',
                        subtitle: '累计总时长从此日起算，不影响明细记录',
                        value: service.sinceDay ?? '不限',
                        onTap: _pickSince,
                      ),
                      SettingsTile(
                        icon: Icons.delete_outline,
                        accent: SettingsAccents.orange,
                        title: '清空统计数据',
                        subtitle: '不影响书架、进度、书签与笔记',
                        onTap: _confirmClear,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  /// 起始日期：弹选择层（不限 / 选日期…），选日期再进系统日期选择器。
  Future<void> _pickSince() async {
    final String? choice = await showSettingsPicker<String>(
      context: context,
      title: '起始日期',
      options: const <SettingsPickerOption<String>>[
        SettingsPickerOption<String>(label: '不限（统计全部记录）', value: ''),
        SettingsPickerOption<String>(label: '选择日期…', value: '__pick__'),
      ],
      current: widget.service.sinceDay ?? '',
    );
    if (!mounted || choice == null) {
      return;
    }
    if (choice.isEmpty) {
      await widget.service.setSinceDate(null);
      return;
    }
    if (choice == '__pick__') {
      await _pickDate();
    }
  }

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    DateTime initial = now;
    final String? current = widget.service.sinceDay;
    if (current != null) {
      try {
        initial = DateTime.parse(current);
      } catch (_) {
        initial = now; // 配置异常按今天兜底（不炸页面）
      }
    }
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(now) ? now : initial,
      firstDate: DateTime(2000, 1, 1),
      lastDate: now,
    );
    if (picked == null || !mounted) {
      return;
    }
    await widget.service.setSinceDate(picked);
  }

  /// 清空确认（`STAT-03` ④：二次确认，明确「不影响书架与进度」）。
  Future<void> _confirmClear() async {
    final bool? confirmed = await GlassOverlays.showAlert<bool>(
      context: context,
      title: '清空统计',
      message: '确定清空全部阅读统计数据？\n书架、进度、书签与笔记不受影响。',
      barrierDismissible: true,
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(context, false),
        ),
        GlassDialogAction(
          label: '清空',
          isDestructive: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed == true && mounted) {
      await widget.service.clearAll();
    }
  }
}
