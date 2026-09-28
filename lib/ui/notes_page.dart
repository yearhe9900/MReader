// 笔记汇聚页（**占位骨架**）。
//
// 规划内容：全部书籍的划线 / 批注 / 书签汇聚成一处，支持按书筛选、
// 搜索，并可跳回原文位置（复用阅读页的语义坐标跳转链路）。
// 依赖阅读页标注能力（`HOOK` 类需求）先落地，故本轮只做入口。
import 'package:flutter/material.dart';

import 'placeholder_page.dart';

/// 笔记页（占位）。
class NotesPage extends StatelessWidget {
  /// 创建笔记页。
  const NotesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: '笔记',
      icon: Icons.sticky_note_2_outlined,
      message: '所有书籍的划线、批注与书签将在这里汇聚，并可跳回原文。',
      hint: '依赖阅读页标注能力，本轮先提供入口。',
    );
  }
}
