// `AI-*` 智能能力页（**占位骨架**）。
//
// 定案（PRD §16）：AI = OpenAI 兼容接口的四项能力（划词问答 / 章节摘要 /
// 全书对话 / 笔记助手）。本页本轮只保证「导航可达 + 形制一致」，
// 功能本身排在 M4（晚于统计与阅读器打磨，见 §6 执行序）。
import 'package:flutter/material.dart';

import 'placeholder_page.dart';

/// 智能能力页（占位）。
class AiPage extends StatelessWidget {
  /// 创建 AI 页。
  const AiPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: 'AI',
      icon: Icons.auto_awesome_outlined,
      message: '划词问答、章节摘要、全书对话与笔记助手将从这里进入。',
      hint: '按执行序排在 M4；接口按 OpenAI 兼容协议接入。',
    );
  }
}
