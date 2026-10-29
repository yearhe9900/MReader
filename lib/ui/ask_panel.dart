// 跟书问答面板（`AI-06` / F5 流程的 UI 收口）。
//
// 验收映射：
//   · F5 逐字流程：输入问题 → 本地检索 Top-K 片段 → 范围行「将发送 K 个片段，
//     共 X 字」→ 流式答案 + 引用条目 → 点引用关面板跳原文；零片段时直接展示
//     「书中未提及」（不发请求，`AI-06` ②）；
//   · `AI-06` ③ 不发全书：范围行字数即实际发送字数（rag 层已封顶）；
//   · `AI-08` ① 流式 / 可取消 / ② 失败回显可重试（[RagJob] + 底座错误分类）；
//   · `AI-09` ① 范围行常驻、③ 最保守模式（仅发送选中文本）下问答**标注受限**
//     并禁用发送（片段检索属于章节上下文，违反 selectionOnly 口径）。
//
// 形制照 [showSummarySheet]（五态 body + 范围行 + 动作行）+
// [SearchSheet]（输入框 + 提交按钮 + 引用列表 onJump 回调）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_client.dart';
import '../ai/provider_config.dart';
import '../ai/provider_store.dart';
import '../ai/rag.dart';
import '../format/book_source.dart';
import 'glass_kit.dart';

/// 弹出问答面板（底部弹窗；输入问题 → 检索 → 流式作答）。
Future<void> showAskSheet(
  BuildContext context, {
  required ProviderStore aiStore,
  required AiClient aiClient,
  required Future<RagIndex> Function() ensureIndex,
  required Future<String> Function(int) loadText,
  required void Function(SearchHit hit, String query) onJump,
}) {
  return GlassOverlays.showSheet<void>(
    context: context,
    isScrollable: false,
    builder: (BuildContext sheetContext) => _AskSheet(
      aiStore: aiStore,
      aiClient: aiClient,
      ensureIndex: ensureIndex,
      loadText: loadText,
      onJump: onJump,
    ),
  );
}

class _AskSheet extends StatefulWidget {
  const _AskSheet({
    required this.aiStore,
    required this.aiClient,
    required this.ensureIndex,
    required this.loadText,
    required this.onJump,
  });

  final ProviderStore aiStore;
  final AiClient aiClient;
  final Future<RagIndex> Function() ensureIndex;
  final Future<String> Function(int) loadText;

  /// 点引用：调用方负责关弹窗 + 跳转（与 [SearchSheet.onJump] 同契约；
  /// query = 当前问题，阅读页写入高亮）。
  final void Function(SearchHit hit, String query) onJump;

  @override
  State<_AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<_AskSheet> {
  final TextEditingController _input = TextEditingController();

  AiProviderConfig? _config;
  String? _key;
  bool _preparing = true;

  /// 已提交的问题（重试沿用；`''` = 尚未提问）。
  String _question = '';

  bool _retrieving = false;
  List<RagSnippet> _snippets = <RagSnippet>[];
  int _sentChars = 0;

  bool _running = false;
  String _out = '';
  String? _err;

  /// 零片段直答「书中未提及」（`AI-06` ②：不发请求）。
  bool _localAnswer = false;

  RagJob? _job;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _job?.cancel(); // 离开面板即中止在途请求（`AI-08` ①）。
    _input.dispose();
    super.dispose();
  }

  /// 配置路由（`AI-01`：对话用途优先，回退摘要）→ 读密钥。
  Future<void> _prepare() async {
    final AiProviderConfig? cfg =
        widget.aiStore.configFor(AiUseCase.chat) ??
            widget.aiStore.configFor(AiUseCase.summarize);
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
    setState(() {
      _config = cfg;
      _key = key;
      _preparing = false;
    });
  }

  /// `AI-09` ③：最保守模式（仅发送选中文本）下问答受限。
  bool get _restricted => widget.aiStore.prefs.selectionOnly;

  bool get _canSend =>
      !_preparing &&
      !_running &&
      !_retrieving &&
      !_restricted &&
      _config != null &&
      _key != null;

  /// 提交（或重试）当前问题：检索 → 范围行 → 流式作答。
  ///
  /// 输入框非空时以输入为准（新问题）；为空时回落上一次问题（重试）。
  Future<void> _submit() async {
    final String typed = _input.text.trim();
    final String raw = typed.isNotEmpty ? typed : _question;
    final AiProviderConfig? cfg = _config;
    final String? key = _key;
    if (raw.isEmpty || cfg == null || key == null || !_canSend) return;
    _job?.cancel();
    setState(() {
      _question = raw;
      _retrieving = true;
      _running = false;
      _err = null;
      _out = '';
      _snippets = <RagSnippet>[];
      _sentChars = 0;
      _localAnswer = false;
    });

    List<RagSnippet> snippets;
    try {
      final RagIndex index = await widget.ensureIndex();
      snippets = await retrieveSnippets(
        question: raw,
        index: index,
        loadText: widget.loadText,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _retrieving = false;
        _err = '检索失败：$error';
      });
      return;
    }
    if (!mounted) return;
    if (snippets.isEmpty) {
      // `AI-06` ②：书内无相关信息 → 不发请求，直接「书中未提及」。
      setState(() {
        _retrieving = false;
        _localAnswer = true;
        _out = '书中未提及。';
      });
      return;
    }
    setState(() {
      _retrieving = false;
      _snippets = snippets;
      _sentChars =
          snippets.fold(0, (int sum, RagSnippet s) => sum + s.text.length);
    });
    _start(cfg, key);
  }

  /// 发起流式作答（`AI-08` ①③：单作业在途，连点不并发）。
  void _start(AiProviderConfig cfg, String key) {
    final RagJob job = RagJob(
      client: widget.aiClient,
      config: cfg,
      apiKey: key,
    );
    _job = job;
    setState(() {
      _running = true;
      _err = null;
      _out = '';
    });
    job
        .ask(
          question: _question,
          snippets: _snippets,
          onDelta: (String d) {
            if (mounted) setState(() => _out += d);
          },
        )
        .then((RagOutcome outcome) {
          if (!mounted) return;
          setState(() {
            _running = false;
            if (outcome.cancelled && _out.isEmpty) _err = '已停止';
          });
        })
        .catchError((Object error) {
          if (!mounted) return;
          setState(() {
            _running = false;
            _err = error is AiException ? error.message : '$error';
          });
        });
  }

  /// 中途停止（`AI-08` ①）：保留已生成的部分。
  void _stop() {
    _job?.cancel();
    if (mounted) setState(() => _running = false);
  }

  /// 复制答案。
  void _copy() {
    if (_out.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _out));
    GlassOverlays.showToast(context: context, message: '答案已复制');
  }

  /// 本次上下文范围说明（`AI-09` ①：面板常驻可见；F5 原文措辞）。
  String get _scopeLine {
    if (_restricted) {
      return '「仅发送选中文本」最保守模式下，跟书问答受限：'
          '检索片段属于章节上下文，不发送';
    }
    if (_localAnswer) {
      return '未检索到相关片段（0 个），已直接回答「书中未提及」';
    }
    if (_snippets.isNotEmpty) {
      return '将发送 ${_snippets.length} 个片段，共 $_sentChars 字';
    }
    return '本地 BM25 检索 Top-$kRagTopK 片段作答，不发送全书';
  }

  bool get _emptyDone =>
      !_preparing && !_retrieving && !_running && _err == null && _out.isEmpty;

  bool get _doneOk =>
      !_preparing && !_retrieving && !_running && _err == null && _out.isNotEmpty;

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
                    'AI 问答',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('ask-close'),
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            Text(
              _scopeLine,
              key: const Key('ask-scope'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: _restricted
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('ask-input'),
                    controller: _input,
                    enabled: !_restricted,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: _restricted
                          ? '最保守模式下问答受限'
                          : '针对本书提问，如：主角为什么离开京城？',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                IconButton(
                  key: const Key('ask-submit'),
                  tooltip: '发送',
                  icon: const Icon(Icons.send),
                  onPressed: _canSend ? _submit : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(child: _buildBody(theme)),
            const SizedBox(height: 8),
            _buildActions(theme),
          ],
        ),
      ),
    );
  }

  /// 输出区：准备 / 检索 / 流式 / 错误 / 空闲 五态 + 引用条目。
  Widget _buildBody(ThemeData theme) {
    if (_preparing) {
      return _statusRow(theme, '正在准备…');
    }
    if (_err != null) {
      return SingleChildScrollView(
        child: Text(
          _err!,
          key: const Key('ask-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (_retrieving) {
      return _statusRow(theme, '正在检索相关片段…');
    }
    if (_running && _out.isEmpty) {
      return _statusRow(theme, '正在生成回答…');
    }
    if (_emptyDone) {
      return Text(
        _restricted ? '最保守模式下问答受限，可关闭。' : '输入问题，检索本书作答。',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_running)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '正在生成回答…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(_out, key: const Key('ask-output'), style: theme.textTheme.bodyMedium),
                if (_snippets.isNotEmpty) _buildCitations(theme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 引用条目（F5「附引用条目 → 点引用跳原文」；编号与答案中的 [n] 对齐）。
  Widget _buildCitations(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 8),
        Text(
          '引用：',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        for (int i = 0; i < _snippets.length; i++)
          InkWell(
            key: Key('ask-citation-$i'),
            onTap: () =>
                widget.onJump(_snippets[i].hit, _question),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '[${i + 1}]',
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _snippets[i].hit.chapterTitle.isNotEmpty
                              ? _snippets[i].hit.chapterTitle
                              : '第 ${_snippets[i].hit.chapterIndex + 1} 节',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _snippets[i].text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
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

  /// 操作行：停止 / 重试 / 复制 / 关闭（按状态出现）。
  Widget _buildActions(ThemeData theme) {
    return Row(
      children: <Widget>[
        if (_running)
          TextButton.icon(
            key: const Key('ask-stop'),
            onPressed: _stop,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('停止'),
          ),
        if (!_running &&
            !_retrieving &&
            _err != null &&
            _config != null &&
            _key != null &&
            !_restricted)
          TextButton.icon(
            key: const Key('ask-retry'),
            onPressed: _submit,
            icon: const Icon(Icons.replay, size: 18),
            label: const Text('重试'),
          ),
        if (_doneOk)
          TextButton.icon(
            key: const Key('ask-copy'),
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
