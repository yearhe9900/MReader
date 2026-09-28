// `STAT-*` 阅读统计页（**占位骨架**）。
//
// 数据层已就绪：`lib/stats/reading_session.dart`（会话模型）+
// `lib/stats/session_store.dart`（按月分片、跨设备按 id 并集幂等）。
// 本页本轮只保证「导航可达 + 形制一致」，聚合指标与图表排在 M3-T10~T13。
import 'package:flutter/material.dart';

import 'placeholder_page.dart';

/// 阅读统计页（占位）。
class StatsPage extends StatelessWidget {
  /// 创建统计页。
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: '统计',
      icon: Icons.insights_outlined,
      message: '阅读时长、阅读天数、书目分布与排行将在本页呈现。',
      hint: '会话采集数据层已就绪，聚合与图表安排在 M3-T10~T13。',
    );
  }
}
