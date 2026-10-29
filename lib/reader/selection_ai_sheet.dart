// 划词翻译 / 释义结果面板（`AI-02`/`AI-03`/`AI-08`/`AI-09` 的 UI 收口）。
//
// 一个面板覆盖两模式（[SelectionAiMode]），差异只有标题、提示词与
// 「存生词本」按钮（仅释义出——`AI-03` ②）。
//
// 验收对应：
//   · `AI-02` ②逐字流式（initState 自动发起，onData 增量拼接）；
//   · `AI-02` ③可中途取消（停止按钮 → [AiCall.cancel]，静默收流）；
//   · `AI-02` ④失败给原因可重试（[AiException.message] 回显 + 重试按钮）；
//   · `AI-08` ②断网明确错误（底座分类的中文 message 直接展示）；
//   · `AI-09` ①上下文范围行（顶部常驻：最保守模式 vs 选段+前后段）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_client.dart';
import '../ai/explain.dart';
import '../ai/provider_config.dart';
import '../ai/provider_store.dart';
import '../ai/translate.dart';
import '../ai/vocab_store.dart';
import '../ui/glass_kit.dart';
import 'selection_overlay.dart';

/// 面板模式（翻译 / 释义）。
enum SelectionAiMode {
  /// 划词翻译（`AI-02`）。
  translate,

  /// 划词释义（`AI-03`）。
  explain,
}

/// 弹出划词 AI 面板（底部弹窗，自动发起流式请求）。
Future<void> showSelectionAiSheet(
  BuildContext context, {
  required SelectionAiMode mode,
  required ParaSelection selection,
  required ProviderStore aiStore,
  required AiClient aiClient,
  required VocabStore vocabStore,
  required String bookId,
  required String bookTitle,
  String? before,
  String? after,
}) {
  return GlassOverlays.showSheet<void>(
    context: context,
    isScrollable: false,
    builder: (BuildContext sheetContext) => _SelectionAiSheet(
      mode: mode,
      selection: selection,
      aiStore: aiStore,
      aiClient: aiClient,
      vocabStore: vocabStore,
      bookId: bookId,
      bookTitle: bookTitle,
      before: before,
      after: after,
    ),
  );
}

class _SelectionAiSheet extends StatefulWidget {
  const _SelectionAiSheet({
    required this.mode,
    required this.selection,
    required this.aiStore,
    required this.aiClient,
    required this.vocabStore,
    required this.bookId,
    required this.bookTitle,
    this.before,
    this.after,
  });

  final SelectionAiMode mode;
  final ParaSelection selection;
  final ProviderStore aiStore;
  final AiClient aiClient;
  final VocabStore vocabStore;
  final String bookId;
  final String bookTitle;

  /// 选段前一段落（非最保守模式才有；null = 不发送）。
  final String? before;

  /// 选段后一段落（同上）。
  final String? after;

  @override
  State<_SelectionAiSheet> createState() => _SelectionAiSheetState();
}

class _SelectionAiSheetState extends State<_SelectionAiSheet> {
  AiProviderConfig? _config;
  String? _key;
  bool _preparing = true;
  bool _running = false;
  bool _saved = false;
  String _out = '';
  String? _err;
  AiCall? _call;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _call?.cancel(); // 离开面板即中止在途请求（`AI-08` ①）。
    super.dispose();
  }

  /// 配置路由（`AI-01`：翻译用途优先，回退对话；释义反之）→ 读密钥 → 发起。
  Future<void> _prepare() async {
    final AiProviderConfig? cfg = widget.mode == SelectionAiMode.translate
        ? (widget.aiStore.configFor(AiUseCase.translate) ??
            widget.aiStore.configFor(AiUseCase.chat))
        : (widget.aiStore.configFor(AiUseCase.chat) ??
            widget.aiStore.configFor(AiUseCase.translate));
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
    _start();
  }

  /// 发起（或重试）一次流式请求。
  void _start() {
    final AiProviderConfig? cfg = _config;
    final String? key = _key;
    if (cfg == null || key == null) return;
    _call?.cancel();
    setState(() {
      _out = '';
      _err = null;
      _running = true;
      _saved = false;
    });
    final ParaSelection sel = widget.selection;
    final AiCall call = widget.mode == SelectionAiMode.translate
        ? translateSelection(
            client: widget.aiClient,
            config: cfg,
            apiKey: key,
            text: sel.text,
            before: widget.before,
            after: widget.after,
          )
        : explainSelection(
            client: widget.aiClient,
            config: cfg,
            apiKey: key,
            text: sel.text,
            before: widget.before,
            after: widget.after,
          );
    _call = call;
    call.stream.listen(
      (String delta) {
        if (mounted) setState(() => _out += delta);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _err = error is AiException ? error.message : '$error';
        });
      },
      onDone: () {
        if (mounted) setState(() => _running = false);
      },
    );
  }

  /// 中途取消（`AI-02` ③）：保留已生成的部分。
  void _stop() {
    _call?.cancel();
    if (mounted) setState(() => _running = false);
  }

  /// 复制结果（`AI-02` 可复制）。
  void _copy() {
    if (_out.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _out));
    GlassOverlays.showToast(context: context, message: '译文已复制');
  }

  /// 存入生词本（`AI-03` ②：落盘后退出重进仍在）。
  Future<void> _save() async {
    if (_out.isEmpty || _saved) return;
    final ParaSelection sel = widget.selection;
    await widget.vocabStore.add(
      VocabEntry(
        id: VocabStore.newId(),
        word: sel.text,
        meaning: _out,
        bookId: widget.bookId,
        bookTitle: widget.bookTitle,
        chapterHref: sel.chapterHref,
        paraIndex: sel.paraIndex,
        createdAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    setState(() => _saved = true);
    GlassOverlays.showToast(context: context, message: '已存入生词本');
  }

  /// 本次上下文范围说明（`AI-09` ①：面板常驻可见）。
  String get _scopeLine {
    if (widget.aiStore.prefs.selectionOnly) {
      return '本次仅发送选中文本（${widget.selection.text.length} 字）';
    }
    final int total = widget.selection.text.length +
        (widget.before?.length ?? 0) +
        (widget.after?.length ?? 0);
    return '本次发送：选中文本 + 前后段落（共 $total 字）';
  }

  /// 配置 / 密钥都就绪才允许重试（缺配置时重试无意义，只给引导文案）。
  bool get _canRetry => _config != null && _key != null;

  bool get _emptyDone =>
      !_preparing && !_running && _err == null && _out.isEmpty;

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
                    widget.mode == SelectionAiMode.translate
                        ? '划词翻译'
                        : '划词释义',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            Text(
              _scopeLine,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                widget.selection.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(child: _buildBody(theme)),
            const SizedBox(height: 8),
            _buildActions(theme),
          ],
        ),
      ),
    );
  }

  /// 输出区：加载 / 流式输出 / 错误 / 空完成 四态。
  Widget _buildBody(ThemeData theme) {
    if (_preparing) {
      return _statusRow(theme, '正在准备…');
    }
    if (_err != null) {
      return Text(
        _err!,
        style: TextStyle(color: theme.colorScheme.error),
      );
    }
    if (_running && _out.isEmpty) {
      return _statusRow(theme, '正在生成…');
    }
    if (_emptyDone) {
      return Text(
        '未生成内容，可点击重试。',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return SingleChildScrollView(
      child: Text(_out, style: theme.textTheme.bodyMedium),
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

  /// 操作行：停止 / 重试 / 复制 / 存生词本（按状态出现）。
  Widget _buildActions(ThemeData theme) {
    final bool done = !_preparing && !_running && _err == null && _out.isNotEmpty;
    return Row(
      children: <Widget>[
        if (_running)
          TextButton.icon(
            onPressed: _stop,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('停止'),
          ),
        if (!_running && (_err != null || _emptyDone) && _canRetry)
          TextButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        if (done) ...<Widget>[
          TextButton.icon(
            onPressed: _copy,
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制'),
          ),
          if (widget.mode == SelectionAiMode.explain)
            TextButton.icon(
              onPressed: _saved ? null : _save,
              icon: Icon(
                _saved ? Icons.check : Icons.bookmark_add_outlined,
                size: 18,
              ),
              label: Text(_saved ? '已存' : '存生词本'),
            ),
        ],
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
