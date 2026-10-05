// 生词本页（M3-T02：`AI-03` ②「存入后退出重进仍在」的浏览面 + ③「点生词
// 跳回原文」）。
//
// 列表数据 = [VocabStore]（进程内共享 + 原子落盘，增删由阅读页释义面板写入，
// 本页订阅刷新）。点击条目走**自持的开书管道**（读字节 → 结构缓存 key →
// `openBook` → push `ReaderPage(initialJump:)`）——与书架点卡同一套原语，
// 但不复用其守卫 / 卡片 loading 状态（本页没有卡片）。
//   · 书已移出书架（bookId 查不到）→ 提示「已不在书架」；
//   · 文件丢失 / 解析失败 → 明确错误提示（`NF-C8` 诚实降级）。
// 长按条目 → 确认框删除（`AI-03` 生词本的清理入口）。
//
// 视觉红线（`UI-04`）：内容由 [OpaqueContentSurface] 承载，玻璃只在顶栏。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/provider_store.dart';
import '../ai/rag.dart';
import '../ai/summary_cache.dart';
import '../ai/vocab_store.dart';
import '../format/book_registry.dart';
import '../format/book_source.dart';
import '../format/structure_cache.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../reader/bookmark_store.dart';
import '../reader/progress_store.dart';
import '../reader/reader_page.dart';
import '../reader/reading_prefs_store.dart';
import '../stats/stats_service.dart';
import '../sync/sync_trigger.dart';
import '../tts/online_tts.dart';
import '../tts/tts_settings.dart';
import 'glass_kit.dart';

/// 生词本页。
class VocabPage extends StatefulWidget {
  /// 创建生词本页。
  const VocabPage({
    super.key,
    required this.repository,
    required this.progressStore,
    required this.vocabStore,
    this.aiStore,
    this.aiClient,
    this.statsService,
    this.summaryCache,
    this.ragStore,
    this.ttsSettings,
    this.onlineTts,
    this.bookmarkStore,
    this.readingPrefsStore,
    this.syncTrigger,
  });

  /// 书库仓库（查记录 / 读字节 / 结构缓存）。
  final LibraryRepository repository;

  /// 阅读进度存储（跳回原文后由阅读页续写）。
  final ProgressStore progressStore;

  /// 生词本存储（进程内共享实例，订阅刷新）。
  final VocabStore vocabStore;

  /// AI 配置 / 客户端（透传阅读页；null = 划词禁用，与其它注入同款降级）。
  final ProviderStore? aiStore;
  final AiClient? aiClient;

  /// 统计服务（透传阅读页，跳回不丢采集）。
  final StatsService? statsService;

  /// 摘要缓存（透传阅读页，跳回后摘要入口不丢；`AI-04`/`AI-05`）。
  final SummaryCache? summaryCache;

  /// 问答索引存储（透传阅读页，跳回后问答入口不丢；`AI-06`）。
  final RagIndexStore? ragStore;

  /// 朗读设置存储（透传阅读页，跳回后朗读设置入口不丢；`TTS-04`/`TTS-05`）。
  final TtsSettingsStore? ttsSettings;

  /// 在线 TTS 配置存储（透传阅读页，`TTS-07`；`M3-T09`）。
  final OnlineTtsStore? onlineTts;

  /// 书签存储（透传阅读页；`M4-T05` 接上生产链路）。
  final BookmarkStore? bookmarkStore;

  /// 阅读偏好存储（透传阅读页；同 [bookmarkStore]）。
  final ReadingPrefsStore? readingPrefsStore;

  /// 同步触发器（透传阅读页：退出阅读页上报进度，`SYNC-06`）。
  final SyncTrigger? syncTrigger;

  @override
  State<VocabPage> createState() => _VocabPageState();
}

class _VocabPageState extends State<VocabPage> {
  /// 开书守卫（只覆盖 push 前的准备阶段，与书架同款语义）。
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    widget.vocabStore.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.vocabStore.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// 生词变更 → 重绘（新增 / 删除即时反映）。
  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  /// 按收录时间倒序的词条（新收录在前；落盘顺序不作约定）。
  List<VocabEntry> get _entries {
    final List<VocabEntry> list = List<VocabEntry>.of(widget.vocabStore.entries);
    list.sort((VocabEntry a, VocabEntry b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<VocabEntry> entries = _entries;
    return GlassNavScaffold(
      appBar: GlassTopBar(
        centerTitle: false,
        title: Text('生词本${entries.isEmpty ? '' : ' · ${entries.length}条'}'),
      ),
      body: OpaqueContentSurface(
        child: entries.isEmpty
            ? _buildEmpty(theme)
            : Column(
                children: <Widget>[
                  if (_opening) const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) =>
                          _buildTile(context, entries[index]),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// 空态（与 [PlaceholderPage] 同形制：图标 + 标题 + 说明）。
  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.book_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('生词本还是空的', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '阅读时长按正文选词 →「释义」→ 存入生词本，\n词条会出现在这里，点击可跳回原文。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 词条行：词 + 释义（两行截断）+ 书名 · 日期；点击跳回、长按删除。
  Widget _buildTile(BuildContext context, VocabEntry entry) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      title: Text(
        entry.word,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              entry.meaning,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${entry.bookTitle.isEmpty ? '未知书籍' : entry.bookTitle} · '
              '${_fmtDate(entry.createdAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openAt(entry),
      onLongPress: () => _confirmDelete(entry),
    );
  }

  /// 长按删除（二次确认；确认后落盘 + 列表经监听自刷新）。
  Future<void> _confirmDelete(VocabEntry entry) async {
    final bool? confirmed = await GlassOverlays.showAlert<bool>(
      context: context,
      title: '删除生词',
      message: '删除「${entry.word}」？删除后不可恢复。',
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        GlassDialogAction(
          label: '删除',
          isDestructive: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (confirmed == true) {
      unawaited(widget.vocabStore.remove(entry.id));
    }
  }

  /// 点词条 → 跳回原文（开书准备 → push 阅读页 initialJump 段落级落位）。
  Future<void> _openAt(VocabEntry entry) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      // bookId → 书架记录（书可能已被移出 / 改名）。
      final List<BookRecord> books = await widget.repository.loadBooks();
      final int i =
          books.indexWhere((BookRecord b) => b.bookId == entry.bookId);
      if (i < 0) {
        _toast('该书已不在书架中');
        return;
      }
      final BookRecord record = books[i];
      final Uint8List? bytes = await widget.repository.readBookBytes(record);
      if (bytes == null || bytes.isEmpty) {
        _toast('文件已丢失：${record.fileName}');
        return;
      }
      // 结构缓存判据（M-PAGE T06）：与书架开书同款——缓存不中即不启用。
      final StructureCacheKey? cacheKey =
          await widget.repository.structureCacheKey(record);
      final BookSource source = await openBook(
        fileName: record.fileName,
        bytes: bytes,
        structureCache: widget.repository.structureCache,
        cacheKey: cacheKey,
      );
      if (!mounted) return;
      final MaterialPageRoute<void> route = MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          source: source,
          record: record,
          progressStore: widget.progressStore,
          repository: widget.repository,
          statsService: widget.statsService,
          aiStore: widget.aiStore,
          aiClient: widget.aiClient,
          vocabStore: widget.vocabStore,
          summaryCache: widget.summaryCache,
          ragStore: widget.ragStore,
          ttsSettings: widget.ttsSettings,
          onlineTts: widget.onlineTts,
          bookmarkStore: widget.bookmarkStore,
          readingPrefsStore: widget.readingPrefsStore,
          syncTrigger: widget.syncTrigger,
          // `AI-03` ③：段落级跳回（不压返回栈——恢复链路消费一次即忘）。
          initialJump: (href: entry.chapterHref, paraIndex: entry.paraIndex),
        ),
      );
      unawaited(Navigator.of(context).push(route));
    } catch (error) {
      if (mounted) _toast('打开失败：$error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 日期展示（不引 intl，本地零依赖）。
  static String _fmtDate(DateTime t) {
    final String mm = t.month.toString().padLeft(2, '0');
    final String dd = t.day.toString().padLeft(2, '0');
    return '${t.year}-$mm-$dd';
  }
}
