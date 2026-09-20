// 书源列表页：导入书源 JSON + 列表展示 + 进入详情。
//
// 与首页的 EPUB 入口并列，是「书源解析」这条链路的起点。
//
// 说明：书源只存在内存里（demo 定位），退出即失。要持久化得接 sqflite / shared_preferences，
// 参考实现用的是 sqflite（`lib/data/database/app_database.dart`）。
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
// `hide DiagnosticLevel`：flutter/material.dart 里也有一个同名的 foundation
// 枚举（`DiagnosticsNode` 用的），不藏起来会 ambiguous_import。
// 本页要的是书源体检的等级枚举。
import 'package:flutter/material.dart' hide DiagnosticLevel;

import '../../source/book_source.dart';
import '../../source/book_source_parser.dart';
import '../../source/source_diagnostic.dart';
import 'source_detail_page.dart';

/// 书源列表页。
class SourceListPage extends StatefulWidget {
  const SourceListPage({super.key});

  @override
  State<SourceListPage> createState() => _SourceListPageState();
}

class _SourceListPageState extends State<SourceListPage> {
  bool _loading = false;
  String? _error;

  /// 已导入的书源 + 它的体检结果。
  ///
  /// 体检在导入时一次算完并存下来：它是纯 CPU 的静态分析，
  /// 没必要每次 build 都重算（列表滚动的每一帧都会 build）。
  final List<_SourceEntry> _entries = <_SourceEntry>[];

  /// 最近一次导入的统计，用于顶部摘要条。
  BookSourceImportResult? _lastImport;

  Future<void> _pickAndImport() async {
    setState(() {
      _error = null;
    });
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['json', 'txt'],
        // 与 EPUB 入口同一约定：统一走 bytes，避免 dart:io 让 Web 编译失败。
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return; // 用户取消
      }

      final PlatformFile picked = result.files.single;
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _error = '未能读取文件内容（bytes 为空）。');
        return;
      }

      setState(() => _loading = true);

      // 书源是文本，但真实文件可能带 BOM 或 GBK 兜底需求；
      // 这里先用 UTF-8 严格解码，失败再退回允许替换字符，保证不会卡在编码上。
      final String text = _decode(bytes);

      final BookSourceImportResult imported = BookSourceParser.parse(text);
      final List<_SourceEntry> newEntries = <_SourceEntry>[
        ..._entries,
        for (final BookSource source in imported.sources)
          _SourceEntry(source: source, diagnostic: SourceDiagnostic.inspect(source)),
      ];

      if (!mounted) return;
      setState(() {
        _loading = false;
        _lastImport = imported;
        _entries
          ..clear()
          ..addAll(newEntries);
        if (imported.isEmpty) {
          _error = imported.skipped.isEmpty
              ? '文件里没有书源。'
              : '没有解析出可用书源：\n${imported.skipped.take(3).join('\n')}';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '导入失败：$error';
      });
    }
  }

  /// 宽松解码：UTF-8 严格 → UTF-8 容错。
  static String _decode(List<int> bytes) {
    try {
      return const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        actions: <Widget>[
          IconButton(
            tooltip: '导入书源 JSON',
            onPressed: _loading ? null : _pickAndImport,
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_loading) const LinearProgressIndicator(),
          if (_lastImport != null) _ImportSummary(result: _lastImport!),
          if (_error != null) _ErrorBanner(message: _error!),
          Expanded(
            child: _entries.isEmpty
                ? _EmptyState(onImport: _loading ? null : _pickAndImport)
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) =>
                        _SourceTile(entry: _entries[index]),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 列表项 = 书源 + 已算好的体检结果。
class _SourceEntry {
  const _SourceEntry({required this.source, required this.diagnostic});

  final BookSource source;
  final SourceDiagnostic diagnostic;
}

/// 顶部导入摘要：解析了 N 条、成功几条、跳过几条。
class _ImportSummary extends StatelessWidget {
  const _ImportSummary({required this.result});

  final BookSourceImportResult result;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(result.summary, style: theme.textTheme.bodyMedium),
          if (result.skipped.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              result.skipped.first.toString(),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            if (result.skipped.length > 1)
              Text(
                '（另有 ${result.skipped.length - 1} 条跳过，见控制台/详情）',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ],
      ),
    );
  }
}

/// 错误提示条。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        message,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }
}

/// 空态。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});

  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.rule_folder_outlined, size: 72),
            const SizedBox(height: 16),
            const Text(
              '导入 legado 书源 JSON\n解析书源结构并做能力体检',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('选择书源文件'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个书源列表项。
class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.entry});

  final _SourceEntry entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BookSource source = entry.source;
    final SourceDiagnostic diagnostic = entry.diagnostic;

    return ListTile(
      title: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              source.displayName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          _LevelBadge(level: diagnostic.worstLevel),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 4),
          Text(
            source.bookSourceUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              _Chip(text: source.bookSourceType.label, dense: true),
              for (final String group in source.groups.take(3))
                _Chip(text: group, dense: true),
              _Chip(
                text: '字段 ${diagnostic.configuredFieldCount}/'
                    '${diagnostic.fields.length}',
                dense: true,
              ),
              if (diagnostic.jsFieldCount > 0)
                _Chip(text: 'JS ${diagnostic.jsFieldCount}', dense: true),
              _Chip(text: '能力 ${diagnostic.capabilities.length}', dense: true),
            ],
          ),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SourceDetailPage(
              source: source,
              diagnostic: diagnostic,
            ),
          ),
        );
      },
    );
  }
}

/// 诊断等级徽标。
class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.level});

  final DiagnosticLevel level;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (Color bg, Color fg) = switch (level) {
      DiagnosticLevel.blocker => (
          theme.colorScheme.errorContainer,
          theme.colorScheme.onErrorContainer,
        ),
      DiagnosticLevel.warn => (
          theme.colorScheme.tertiaryContainer,
          theme.colorScheme.onTertiaryContainer,
        ),
      DiagnosticLevel.info => (
          theme.colorScheme.secondaryContainer,
          theme.colorScheme.onSecondaryContainer,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        level.label,
        style: theme.textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// 小标签。
class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.dense = false});

  final String text;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: (dense ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
