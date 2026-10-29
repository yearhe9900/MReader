// AI 摘要面板：`AI-04` 章节摘要 / `AI-05` 全书摘要 + 前情回顾的 UI 收口。
//
// 验收对应：`AI-04` ①可指定长度（长度档切换即重查缓存 / 重生成，键含 maxChars）、
// ②二次进入命中缓存**不发请求**、③可手动重新生成（force 绕过缓存读）；
// `AI-05` ①全书摘要（逐章递进 + 合并）、③可中断可续做（停止 → 章级缓存保留 →
// 继续只补缺的章）；`AI-08` ①流式/可取消/失败可重试（[SummaryJob] + 错误回显）；
// `AI-09` ①上下文范围行（顶部常驻，逐模式说明发什么）。
//
// 形制照 [showSelectionAiSheet]：prepare → 按模式发起 → 流式 → 停止/重试/复制。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_client.dart';
import '../ai/provider_config.dart';
import '../ai/provider_store.dart';
import '../ai/recap.dart';
import '../ai/summarize.dart';
import '../ai/summary_cache.dart';
import '../model/chapter.dart';
import '../ui/glass_kit.dart';

/// 面板模式（`AI-04` 章节 / `AI-05` 全书 / `AI-05` 前情回顾）。
enum SummaryMode {
  /// 当前章摘要（`AI-04`）。
  chapter,

  /// 全书摘要（`AI-05` ①）。
  book,

  /// 前情回顾（`AI-05` ②）。
  recap,
}

/// 弹出摘要面板（底部弹窗；章模式 prepare 后自动发起，其余模式进页自动发起）。
Future<void> showSummarySheet(
  BuildContext context, {
  required SummaryMode initialMode,
  required ProviderStore aiStore,
  required AiClient aiClient,
  required SummaryCache summaryCache,
  required String bookId,
  required List<Chapter> chapters,
  required int currentIndex,
  required Future<String> Function(int index) loadText,
}) {
  return GlassOverlays.showSheet<void>(
    context: context,
    isScrollable: false,
    builder: (BuildContext sheetContext) => _SummarySheet(
      initialMode: initialMode,
      aiStore: aiStore,
      aiClient: aiClient,
      summaryCache: summaryCache,
      bookId: bookId,
      chapters: chapters,
      currentIndex: currentIndex,
      loadText: loadText,
    ),
  );
}

class _SummarySheet extends StatefulWidget {
  const _SummarySheet({
    required this.initialMode,
    required this.aiStore,
    required this.aiClient,
    required this.summaryCache,
    required this.bookId,
    required this.chapters,
    required this.currentIndex,
    required this.loadText,
  });

  final SummaryMode initialMode;
  final ProviderStore aiStore;
  final AiClient aiClient;
  final SummaryCache summaryCache;
  final String bookId;
  final List<Chapter> chapters;
  final int currentIndex;
  final Future<String> Function(int index) loadText;

  @override
  State<_SummarySheet> createState() => _SummarySheetState();
}

class _SummarySheetState extends State<_SummarySheet> {
  late SummaryMode _mode = widget.initialMode;

  AiProviderConfig? _config;
  String? _key;
  bool _preparing = true;
  bool _running = false;
  String _out = '';
  String? _err;
  bool _fromCache = false;
  int _done = 0;
  int _total = 0;
  int _length = kSummaryDefaultChars;
  String? _chapterText;
  SummaryJob? _job;

  /// 每个模式本会话只自动发起一次（切回来不重复烧 token，重跑走手动按钮）。
  final Set<SummaryMode> _autoStarted = <SummaryMode>{};

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _job?.cancel(); // 离开面板即中止在途请求（`AI-08` ①）。
    super.dispose();
  }

  /// 配置路由（`AI-01`：摘要用途优先，回退对话）→ 读密钥 → 取当前章文本。
  Future<void> _prepare() async {
    final AiProviderConfig? cfg =
        widget.aiStore.configFor(AiUseCase.summarize) ??
            widget.aiStore.configFor(AiUseCase.chat);
    if (cfg == null) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _err = '尚未配置 AI 服务：请先在「设置 → AI 服务」中添加配置并勾选用途';
      });
      return;
    }
    String? key;
    try {
      key = await widget.aiStore.readApiKey(cfg.id);
    } catch (_) {
      key = null;
    }
    if (!mounted) return;
    if (key == null || key.isEmpty) {
      setState(() {
        _config = cfg;
        _preparing = false;
        _err = '尚未设置 API Key：请在该配置中填写密钥';
      });
      return;
    }
    String? text;
    try {
      text = await widget.loadText(widget.currentIndex);
    } catch (_) {
      text = null;
    }
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _key = key;
      _chapterText = text;
      _preparing = false;
    });
    _autoStart();
  }

  /// 进入某模式时的自动发起（章模式先查缓存——命中零请求，`AI-04` ②）。
  void _autoStart() {
    if (_autoStarted.contains(_mode)) return;
    _autoStarted.add(_mode);
    if (widget.chapters.isEmpty) {
      setState(() => _err = '这本书没有可摘要的章节');
      return;
    }
    if (_mode == SummaryMode.chapter) {
      final ChapterSummaryEntry? hit = _chapterCacheHit();
      if (hit != null) {
        setState(() {
          _out = hit.text;
          _fromCache = true;
        });
        return;
      }
      final String? text = _chapterText;
      if (text == null || text.trim().isEmpty) {
        setState(() => _err = '本章没有可摘要的正文');
        return;
      }
    }
    _start();
  }

  /// 当前章的缓存命中查询（键 = bookId + href + 内容 hash + 模型 + 长度）。
  ChapterSummaryEntry? _chapterCacheHit() {
    final AiProviderConfig? cfg = _config;
    final String? text = _chapterText;
    if (cfg == null || text == null || text.isEmpty) return null;
    final int i = widget.currentIndex;
    if (i < 0 || i >= widget.chapters.length) return null;
    return widget.summaryCache.findChapter(
      bookId: widget.bookId,
      chapterHref: widget.chapters[i].href,
      contentHash: summaryContentHash(text),
      model: cfg.model,
      maxChars: _length,
    );
  }

  /// 发起（或继续 / 重试）当前模式的一次作业。
  ///
  /// [force] 仅章模式用（`AI-04` ③ 重新生成：绕过缓存读，结果仍回写缓存）。
  void _start({bool force = false}) {
    final AiProviderConfig? cfg = _config;
    final String? key = _key;
    if (cfg == null || key == null || _running) return;
    _job?.cancel();
    final SummaryJob job = SummaryJob(
      client: widget.aiClient,
      config: cfg,
      apiKey: key,
      cache: widget.summaryCache,
    );
    _job = job;

    final int upto = _mode == SummaryMode.recap
        ? widget.currentIndex
        : widget.chapters.length - 1;
    setState(() {
      _running = true;
      _err = null;
      _fromCache = false;
      if (force || _mode == SummaryMode.chapter) _out = '';
      _done = 0;
      _total = _mode == SummaryMode.chapter
          ? 1
          : upto - (_mode == SummaryMode.recap
                  ? (upto - kRecapRecentChapters + 1 < 0
                      ? 0
                      : upto - kRecapRecentChapters + 1)
                  : 0) +
              1;
    });

    final Future<SummaryOutcome> future;
    switch (_mode) {
      case SummaryMode.chapter:
        final int i = widget.currentIndex;
        future = job.chapter(
          bookId: widget.bookId,
          href: widget.chapters[i].href,
          title: widget.chapters[i].title,
          text: _chapterText ?? '',
          maxChars: _length,
          force: force,
          onDelta: (String d) {
            if (mounted) setState(() => _out += d);
          },
        );
      case SummaryMode.book:
        future = job.book(
          bookId: widget.bookId,
          uptoChapter: widget.chapters.length - 1,
          hrefs: <String>[for (final Chapter c in widget.chapters) c.href],
          titles: <String>[for (final Chapter c in widget.chapters) c.title],
          loadText: widget.loadText,
          onProgress: (int d, int t) {
            if (mounted) setState(() { _done = d; _total = t; });
          },
          onDelta: (String d) {
            if (mounted) setState(() => _out += d);
          },
        );
      case SummaryMode.recap:
        future = job.recap(
          bookId: widget.bookId,
          uptoChapter: widget.currentIndex,
          hrefs: <String>[for (final Chapter c in widget.chapters) c.href],
          titles: <String>[for (final Chapter c in widget.chapters) c.title],
          loadText: widget.loadText,
          onProgress: (int d, int t) {
            if (mounted) setState(() { _done = d; _total = t; });
          },
          onDelta: (String d) {
            if (mounted) setState(() => _out += d);
          },
        );
    }

    future.then(
      (SummaryOutcome outcome) {
        if (!mounted) return;
        setState(() {
          _running = false;
          if (outcome.text.isNotEmpty) _out = outcome.text;
          _fromCache = outcome.fromCache;
          _done = outcome.chaptersDone;
          _total = outcome.chaptersTotal;
          if (outcome.cancelled) {
            _err = outcome.text.isEmpty && _out.isEmpty
                ? '已中断（完成 ${outcome.chaptersDone}/${outcome.chaptersTotal} 章），'
                    '再次生成可从断点续做'
                : null;
          } else if (outcome.isEmpty && _out.isEmpty) {
            _err = '未生成内容，可点击重试';
          }
        });
      },
    ).catchError((Object error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _err = error is AiException ? error.message : '$error';
      });
    });
  }

  /// 中途取消（`AI-08` ①）：章级已生成部分保留在缓存 → 可续做。
  void _stop() {
    _job?.cancel();
    if (mounted) setState(() => _running = false);
  }

  /// 手动重新生成（`AI-04` ③：force 绕过缓存读）。
  void _regenerate() {
    if (_mode == SummaryMode.chapter && (_chapterText?.isEmpty ?? true)) return;
    _start(force: true);
  }

  /// 复制结果。
  void _copy() {
    if (_out.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _out));
    GlassOverlays.showToast(context: context, message: '摘要已复制');
  }

  /// 切模式：停掉在途作业，进入新模式的自动发起。
  void _switchMode(SummaryMode mode) {
    if (mode == _mode) return;
    _job?.cancel();
    setState(() {
      _mode = mode;
      _running = false;
      _out = '';
      _err = null;
      _fromCache = false;
      _done = 0;
    });
    _autoStart();
  }

  /// 切长度档（`AI-04` 可指定长度）：清输出重查缓存 / 重生成。
  void _selectLength(int chars) {
    if (chars == _length || _running) return;
    setState(() {
      _length = chars;
      _out = '';
      _err = null;
      _fromCache = false;
    });
    _autoStarted.remove(SummaryMode.chapter);
    _autoStart();
  }

  /// 本次上下文范围说明（`AI-09` ①：面板常驻可见）。
  String get _scopeLine {
    switch (_mode) {
      case SummaryMode.chapter:
        final int n = _chapterText?.length ?? 0;
        final int i = widget.currentIndex + 1;
        return '本次发送：第 $i 章全文（$n 字），目标 $_length 字梗概';
      case SummaryMode.book:
        return '本次发送：逐章发送各章全文（共 ${widget.chapters.length} 章，'
            '每章一次请求），合并时仅发送各章梗概';
      case SummaryMode.recap:
        final int upto = widget.currentIndex;
        final int from =
            upto - kRecapRecentChapters + 1 < 0 ? 0 : upto - kRecapRecentChapters + 1;
        return '本次发送：第 ${from + 1}~${upto + 1} 章全文'
            '（近 $kRecapRecentChapters 章，上次读到第 ${upto + 1} 章）';
    }
  }

  /// 配置 / 密钥都就绪才允许重试。
  bool get _canRetry => _config != null && _key != null;

  bool get _emptyDone =>
      !_preparing && !_running && _err == null && _out.isEmpty;

  bool get _doneOk =>
      !_preparing && !_running && _err == null && _out.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'AI 摘要',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_fromCache)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '缓存',
                      key: const Key('summary-cache-tag'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                IconButton(
                  key: const Key('summary-close'),
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            Text(
              _scopeLine,
              key: const Key('summary-scope'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            _buildModeRow(theme),
            if (_mode == SummaryMode.chapter) _buildLengthRow(theme),
            const SizedBox(height: 8),
            Flexible(child: _buildBody(theme)),
            const SizedBox(height: 8),
            _buildActions(theme),
          ],
        ),
      ),
    );
  }

  /// 模式切换行（三选；TextButton 形制避免玻璃弹层里的 Chip 断言依赖）。
  Widget _buildModeRow(ThemeData theme) {
    Widget chip(SummaryMode mode, String label) {
      final bool selected = mode == _mode;
      return TextButton(
        key: Key('summary-mode-${mode.name}'),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: _running ? null : () => _switchMode(mode),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            decoration: selected ? TextDecoration.underline : null,
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        chip(SummaryMode.chapter, '章节摘要'),
        chip(SummaryMode.book, '全书摘要'),
        chip(SummaryMode.recap, '前情回顾'),
      ],
    );
  }

  /// 长度档行（`AI-04` 可指定长度）。
  Widget _buildLengthRow(ThemeData theme) {
    Widget chip(int chars) {
      final bool selected = chars == _length;
      return TextButton(
        key: Key('summary-length-$chars'),
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: _running ? null : () => _selectLength(chars),
        child: Text('$chars 字'),
      );
    }

    return Row(
      children: <Widget>[
        Text(
          '长度：',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        chip(100),
        chip(200),
        chip(500),
      ],
    );
  }

  /// 输出区：加载 / 流式输出 / 进度 / 错误 / 空完成 五态。
  Widget _buildBody(ThemeData theme) {
    if (_preparing) {
      return _statusRow(theme, '正在准备…');
    }
    if (_err != null) {
      return SingleChildScrollView(
        child: Text(
          _err!,
          key: const Key('summary-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    final bool showProgress = _running &&
        (_mode != SummaryMode.chapter || _out.isEmpty);
    if (showProgress && _out.isEmpty) {
      final String label = _mode == SummaryMode.chapter
          ? '正在生成…'
          : '正在生成章摘要（$_done/$_total）…';
      return _statusRow(theme, label);
    }
    if (_emptyDone) {
      return Text(
        '未生成内容，可点击重试。',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showProgress)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '正在生成章摘要（$_done/$_total）…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Flexible(
          child: SingleChildScrollView(
            key: const Key('summary-output'),
            child: Text(_out, style: theme.textTheme.bodyMedium),
          ),
        ),
      ],
    );
  }

  Widget _statusRow(ThemeData theme, String label) {
    return Row(
      children: <Widget>[
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// 操作行：停止 / 生成·继续 / 重新生成 / 复制 / 关闭（按状态出现）。
  Widget _buildActions(ThemeData theme) {
    return Row(
      children: <Widget>[
        if (_running)
          TextButton.icon(
            key: const Key('summary-stop'),
            onPressed: _stop,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('停止'),
          ),
        if (!_running && _mode != SummaryMode.chapter && _canRetry)
          TextButton.icon(
            key: const Key('summary-generate'),
            onPressed: _start,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: Text(_out.isEmpty ? '生成' : '重新生成'),
          ),
        if (!_running && _mode == SummaryMode.chapter && _canRetry)
          TextButton.icon(
            key: const Key('summary-generate'),
            onPressed: _regenerate,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(_doneOk || _fromCache ? '重新生成' : '生成'),
          ),
        if (!_running && (_err != null || _emptyDone) && _canRetry)
          TextButton.icon(
            key: const Key('summary-retry'),
            onPressed: _start,
            icon: const Icon(Icons.replay, size: 18),
            label: const Text('重试'),
          ),
        if (_doneOk)
          TextButton.icon(
            key: const Key('summary-copy'),
            onPressed: _copy,
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制'),
          ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
