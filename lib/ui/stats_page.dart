// 统计页外壳 + 总览（`STAT-03`）。
//
// 形制（`UI-04` 红线）：玻璃顶栏（导航层）+ [OpaqueContentSurface] 承载正文，
// 总览卡片与设置行**一律不透明**——统计图表 / 卡片 / 列表行绝不进玻璃
// （PRD §6.2 / §11.2：仅操作按钮 / 弹窗 / 菜单可用玻璃）。
//
// 状态管理：`StatefulWidget` + `setState` + [StatsService] 监听回调
// （§15.5 禁 Riverpod / Provider）；服务实例由组合根经 `HomeShell` 注入。
// 首次进入异步 [StatsService.load]，载入完成回调里 setState 一次。
//
// 页面排布（`STAT-03`/`STAT-04`）：总览卡片（累计总时长「X 至今」/ 活跃天数 /
// 书籍数）→ 周期柱状图（点柱下钻明细）→ 热力图 → 排行 → 统计设置（起始日期 /
// 清空统计数据，形制同设置页分组卡片）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../library/library_repository.dart';
import '../stats/aggregator.dart';
import '../stats/reading_session.dart';
import '../stats/stats_service.dart';
import '../stats/streak.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'mi_like_ui/mi_like_ui.dart'
    show MiDialog, MiDialogAction, MiDialogActionStyle, showMiDialog;
import 'settings_kit.dart';
import 'stats/bar_chart.dart';
import 'stats/drill_down_page.dart';
import 'stats/heatmap.dart';
import 'stats/overview_card.dart';
import 'stats/rank_list.dart';

/// 阅读统计页。
class StatsPage extends StatefulWidget {
  /// 创建统计页（[service] 由组合根注入，进程内唯一实例）。
  const StatsPage({super.key, required this.service, this.repository});

  /// 统计服务（载入 / 聚合 / 起始日期 / 清空）。
  final StatsService service;

  /// 书库仓库（可选：下钻明细解析书名；`null` 降级显示 bookId）。
  final LibraryRepository? repository;

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
      appBar: GlassTopBar(
        title: const Text('统计'),
        // 本页只经「我的」页 push 打开 ⇒ `canPop` 时显示返回键（否则不显示）。
        leading: Navigator.of(context).canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
      ),
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
                  const SizedBox(height: 12),
                  PeriodBarChart(
                    sessions: service.sessions,
                    sinceDay: service.sinceDay,
                    onTapBar: _openDrill,
                  ),
                  const SizedBox(height: 12),
                  ReadingHeatmap(
                    sessions: service.sessions,
                    sinceDay: service.sinceDay,
                    onTapDay: _openDayDetail,
                  ),
                  const SizedBox(height: 12),
                  BookRankCard(
                    sessions: service.sessions,
                    sinceDay: service.sinceDay,
                    repository: widget.repository,
                    onTapBook: _openBookStats,
                  ),
                  const SizedBox(height: 12),
                  StreakCard(
                    streak: computeStreak(
                      service.sessions,
                      sinceDay: service.sinceDay,
                      now: DateTime.now(),
                    ),
                  ),
                  const SizedBox(height: 12),
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

  /// 点柱下钻（`STAT-04`：单日柱 → 会话明细；年视图月柱 → 按天分组明细）。
  void _openDrill(PeriodBar bar) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DrillDownPage(
        bar: bar,
        sessions: widget.service.sessions,
        sinceDay: widget.service.sinceDay,
        repository: widget.repository,
      ),
    ));
  }

  /// 点格弹当天明细（`STAT-05`：总时长 + 当天读过的书与各自时长；
  /// 数据走 [sessionsInRange] 单日过滤，与 `STAT-04` 下钻天然一致）。
  Future<void> _openDayDetail(String dayKey) async {
    final Map<String, String> titles = await _bookTitles();
    if (!mounted) {
      return;
    }
    final List<ReadingSession> list = sessionsInRange(
      widget.service.sessions,
      fromDay: dayKey,
      toDay: dayKey,
      sinceDay: widget.service.sinceDay,
    );
    int total = 0;
    for (final ReadingSession s in list) {
      total += s.duration;
    }
    final Map<String, int> byBook = StatsIndex.of(list).secondsByBook;
    final List<MapEntry<String, int>> rows = byBook.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value));
    final DateTime d = DateTime.parse(dayKey);
    // 内容型明细改形（`MiDialog` 无 content 槽）：按书行拼进多行 message。
    final String detail = list.isEmpty
        ? '该天无阅读记录'
        : rows
            .map((MapEntry<String, int> e) =>
                '${titles[e.key] ?? e.key} · ${formatReadingDuration(e.value)}')
            .join('\n');
    await showMiDialog(
      context,
      dialog: MiDialog(
        title: '${d.month}月${d.day}日',
        message: '总时长 ${formatReadingDuration(total)}\n\n$detail',
        actions: <MiDialogAction>[
          MiDialogAction(label: '关闭', onPressed: () {}),
        ],
      ),
    );
  }

  /// 书名映射（懒加载一次；repository 为 null 或失败 → 降级显示 bookId）。
  Map<String, String>? _titles;

  Future<Map<String, String>> _bookTitles() async {
    final Map<String, String>? cached = _titles;
    if (cached != null) {
      return cached;
    }
    final LibraryRepository? repo = widget.repository;
    if (repo == null) {
      return _titles = const <String, String>{};
    }
    try {
      final books = await repo.loadBooks();
      return _titles = <String, String>{
        for (final b in books) b.bookId: b.title,
      };
    } catch (_) {
      return _titles = const <String, String>{};
    }
  }

  /// 点排行行 → 单书统计页（`STAT-06`；窗口 = 排行卡当前周期）。
  void _openBookStats(String bookId, String title, RankPeriod period) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookStatsPage(
        bookId: bookId,
        title: title,
        sessions: widget.service.sessions,
        period: period,
        sinceDay: widget.service.sinceDay,
      ),
    ));
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
    // mi_like 按钮弹框：下标 1 = 清空；点遮罩 / 返回键 = null（同判不清空）。
    final int? picked = await showMiDialog(
      context,
      dialog: MiDialog(
        title: '清空统计',
        message: '确定清空全部阅读统计数据？\n书架、进度、书签与笔记不受影响。',
        actions: <MiDialogAction>[
          MiDialogAction(label: '取消', onPressed: () {}),
          MiDialogAction(
            label: '清空',
            style: MiDialogActionStyle.destructive,
            onPressed: () {},
          ),
        ],
      ),
    );
    if (picked == 1 && mounted) {
      await widget.service.clearAll();
    }
  }
}
