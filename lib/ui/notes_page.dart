// 笔记汇聚页：生词本入口（`AI-03`）+ 划线 / 批注占位。
//
// 生词本 = 已落地能力（M3-T02）：入口行显示词条数，点击经 [onOpenVocab]
// （组合根注入的回调，HomeShell 持有全部依赖 → push `VocabPage`）打开列表。
// 划线 / 批注 / 书签汇聚依赖阅读页标注能力（`HOOK` 类需求），本轮仍是占位。
// [vocabStore] 为 null（未接线 / 测试构造）→ 整页回退原占位骨架，行为一字不变。
//
// 视觉红线（`UI-04`）：内容由 [OpaqueContentSurface] 承载，玻璃只在顶栏。
import 'package:flutter/material.dart';

import '../ai/vocab_store.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'placeholder_page.dart';

/// 笔记页。
class NotesPage extends StatefulWidget {
  /// 创建笔记页。
  const NotesPage({super.key, this.vocabStore, this.onOpenVocab});

  /// 生词本存储（读词条数 + 订阅刷新）；null = 未接线，回退占位骨架。
  final VocabStore? vocabStore;

  /// 「生词本」入口回调（push `VocabPage`）；null = 无入口。
  final VoidCallback? onOpenVocab;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  @override
  void initState() {
    super.initState();
    widget.vocabStore?.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(covariant NotesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.vocabStore, widget.vocabStore)) {
      oldWidget.vocabStore?.removeListener(_onStoreChanged);
      widget.vocabStore?.addListener(_onStoreChanged);
    }
  }

  @override
  void dispose() {
    widget.vocabStore?.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// 生词增删 → 入口计数刷新。
  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final VocabStore? store = widget.vocabStore;
    if (store == null) {
      // 未接线：与改造前一字不差的占位骨架（既有测试 / 降级形态）。
      return const PlaceholderPage(
        title: '笔记',
        icon: Icons.sticky_note_2_outlined,
        message: '所有书籍的划线、批注与书签将在这里汇聚，并可跳回原文。',
        hint: '依赖阅读页标注能力，本轮先提供入口。',
      );
    }
    final ThemeData theme = Theme.of(context);
    final int count = store.entries.length;
    return GlassNavScaffold(
      appBar: GlassTopBar(
        centerTitle: false,
        title: const Text('笔记'),
      ),
      body: OpaqueContentSurface(
        child: ListView(
          // 壳层浮动底栏不占布局高度，内容自留底部空白（`kShellBottomInset`）。
          padding: const EdgeInsets.fromLTRB(16, 12, 16, kShellBottomInset),
          children: <Widget>[
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  foregroundColor: theme.colorScheme.onSecondaryContainer,
                  child: const Icon(Icons.book_outlined, size: 22),
                ),
                title: const Text('生词本'),
                subtitle: Text(
                  count == 0 ? '暂无生词，释义面板可存入' : '点击进入，长按词条可删除',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '$count条',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: widget.onOpenVocab,
              ),
            ),
            const SizedBox(height: 24),
            // 划线 / 批注占位（保留原占位语义，页面做实后移除）。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: <Widget>[
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 48,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '所有书籍的划线、批注与书签将在这里汇聚，并可跳回原文。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '依赖阅读页标注能力，本轮先提供生词本入口。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
