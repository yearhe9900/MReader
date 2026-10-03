// 人物关系与设定梳理页（M3-T05：`AI-07`，push 进入的整页 UI）。
//
// 验收对应：
//   · `AI-07` ① 名字与书中一致：成品原样展示（[EntityItem.name] 不改写）；
//   · `AI-07` ② 每条含出场章节引用：章 chip 点击 → [EntityPage.onJump]
//     （阅读页关本页 + `_goToChapter` 跳回原文）；
//   · `AI-07` ③ 「仅已读部分」防剧透：范围二选一——仅已读（章
//     0..[readUptoIndex]，RD-04 `chapterIndex` 口径）/ 全书，默认全书、
//     随时切换（切范围即按新范围重新生成，缓存键含范围天然分流）；
//   · `AI-08` ① 流式（[EntityJob] JSONL 逐行回调，边抽边渲染）/ 可取消
//     （停止；dispose 也中止在途）/ 失败可重试 / 结果缓存（缓存 tag）；
//   · `AI-09` ① 顶部范围行常驻（逐范围说明本次发什么）。
//
// 配置路由与摘要面板同款（`AI-01`：summarize 用途优先，回退 chat）。
// `AI-09` ③ 的「最保守模式受限」按 PRD 原文是**问答专属**，本页与摘要面板
// 同口径不拦截——范围行照常可见，发送范围由用户在范围行内自选。
//
// 形制照 `_SummarySheet`：prepare → 自动发起（每范围一次）→ 流式 → 停止/重试。
import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/entities.dart';
import '../ai/provider_config.dart';
import '../ai/provider_store.dart';
import '../ai/summary_cache.dart';
import '../model/chapter.dart';

/// 生成范围（`AI-07` ③）。
enum EntityRange {
  /// 仅已读：章 0..readUptoIndex（防剧透）。
  read,

  /// 全书：章 0..末章。
  full,
}

/// 人物与设定梳理页（调用方 push；dispose 即取消在途抽取）。
class EntityPage extends StatefulWidget {
  const EntityPage({
    super.key,
    required this.aiStore,
    required this.aiClient,
    required this.summaryCache,
    required this.bookId,
    required this.chapters,
    required this.readUptoIndex,
    required this.loadText,
    required this.onJump,
  });

  final ProviderStore aiStore;
  final AiClient aiClient;
  final SummaryCache summaryCache;
  final String bookId;
  final List<Chapter> chapters;

  /// 「仅已读」上界（含）：阅读页传滚动实时章 `_liveIndex`。
  final int readUptoIndex;

  /// 章文本加载器（阅读页 `_summaryTextAt`：纯文本，LRU 未命中才回源）。
  final Future<String> Function(int index) loadText;

  /// 点出场章节引用：调用方负责关本页并跳到该章章首。
  final void Function(int index) onJump;

  @override
  State<EntityPage> createState() => _EntityPageState();
}

class _EntityPageState extends State<EntityPage> {
  AiProviderConfig? _config;
  String? _key;
  bool _preparing = true;
  bool _running = false;
  String? _err;
  String? _notice;
  bool _fromCache = false;
  int _done = 0;
  int _total = 0;
  EntityRange _range = EntityRange.full;
  List<EntityItem> _items = <EntityItem>[];
  EntityJob? _job;

  /// 每个范围本会话只自动发起一次（切回来不重复烧 token，重跑走手动按钮）。
  final Set<EntityRange> _autoStarted = <EntityRange>{};

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _job?.cancel(); // 离开页面即中止在途请求（`AI-08` ①）。
    super.dispose();
  }

  /// 配置路由（`AI-01`：摘要用途优先，回退对话）→ 读密钥。
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
    setState(() {
      _config = cfg;
      _key = key;
      _preparing = false;
    });
    _autoStart();
  }

  /// 进入某范围时的自动发起（每范围一次；缓存命中零请求）。
  void _autoStart() {
    if (_autoStarted.contains(_range)) return;
    _autoStarted.add(_range);
    if (widget.chapters.isEmpty) {
      setState(() => _err = '这本书没有可梳理的章节');
      return;
    }
    _start();
  }

  int get _lastIndex => widget.chapters.isEmpty ? -1 : widget.chapters.length - 1;

  /// 「仅已读」上界（含）：夹在有效章索引内。
  int get _readLast =>
      widget.chapters.isEmpty ? 0 : widget.readUptoIndex.clamp(0, _lastIndex);

  /// 当前范围上界（含）。
  int get _rangeUpto => _range == EntityRange.read ? _readLast : _lastIndex;

  /// 发起（或重试 / 重新生成）当前范围的一次作业。
  void _start({bool force = false}) {
    final AiProviderConfig? cfg = _config;
    final String? key = _key;
    if (cfg == null || key == null || _running) return;
    _job?.cancel();
    final EntityJob job = EntityJob(
      client: widget.aiClient,
      config: cfg,
      apiKey: key,
      cache: widget.summaryCache,
    );
    _job = job;
    setState(() {
      _running = true;
      _err = null;
      _notice = null;
      _fromCache = false;
      _items = <EntityItem>[];
      _done = 0;
      _total = 0;
    });

    final Future<EntityOutcome> future = job.run(
      bookId: widget.bookId,
      fromChapter: 0,
      uptoChapter: _rangeUpto,
      hrefs: <String>[for (final Chapter c in widget.chapters) c.href],
      titles: <String>[for (final Chapter c in widget.chapters) c.title],
      loadText: widget.loadText,
      force: force,
      onProgress: (int done, int total) {
        if (mounted) setState(() { _done = done; _total = total; });
      },
      onItems: (List<EntityItem> items) {
        if (mounted) setState(() => _items = items);
      },
    );
    future.then(
      (EntityOutcome outcome) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _items = outcome.items;
          _fromCache = outcome.fromCache;
          _done = outcome.chunksDone;
          _total = outcome.chunksTotal;
          if (outcome.cancelled) {
            if (outcome.items.isEmpty) {
              _err = '已中断且无结果，可点击重试';
            } else {
              _notice = '已中断（${outcome.chunksDone}/${outcome.chunksTotal} 段），'
                  '以下为部分结果';
            }
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

  /// 中途取消（`AI-08` ①）：半截结果不落缓存，部分清单保留展示。
  void _stop() {
    _job?.cancel();
    if (mounted) setState(() => _running = false);
  }

  /// 手动重新生成（force 绕过缓存读，结果仍回写）。
  void _regenerate() => _start(force: true);

  /// 切范围（`AI-07` ③）：停掉在途作业，进入新范围的自动发起。
  void _switchRange(EntityRange range) {
    if (range == _range) return;
    _job?.cancel();
    setState(() {
      _range = range;
      _running = false;
      _err = null;
      _notice = null;
      _fromCache = false;
      _items = <EntityItem>[];
      _done = 0;
      _total = 0;
    });
    _autoStart();
  }

  /// 本次上下文范围说明（`AI-09` ①：页面常驻可见）。
  String get _scopeLine {
    if (widget.chapters.isEmpty) return '本次发送：暂无章节';
    return _range == EntityRange.read
        ? '本次发送：第 1~${_rangeUpto + 1} 章正文'
            '（仅已读部分，防剧透；分段逐次发送）'
        : '本次发送：第 1~${widget.chapters.length} 章正文'
            '（分段逐次发送，非一次全发）';
  }

  /// 配置 / 密钥都就绪才允许生成 / 重试。
  bool get _canRetry => _config != null && _key != null;

  bool get _emptyDone =>
      !_preparing && !_running && _err == null && _items.isEmpty;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: <Widget>[
            const Text('人物与设定'),
            if (_fromCache)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '缓存',
                  key: const Key('entity-cache-tag'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _scopeLine,
              key: const Key('entity-scope'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            _buildRangeRow(theme),
            const SizedBox(height: 8),
            Flexible(child: _buildBody(theme)),
            const SizedBox(height: 8),
            _buildActions(theme),
          ],
        ),
      ),
    );
  }

  /// 范围切换行（二选；TextButton 形制与摘要面板模式行一致）。
  Widget _buildRangeRow(ThemeData theme) {
    Widget chip(EntityRange range, String label, Key key) {
      final bool selected = range == _range;
      return TextButton(
        key: key,
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: _running ? null : () => _switchRange(range),
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
        chip(EntityRange.read, '仅已读（1~${_readLast + 1}章）',
            const Key('entity-range-read')),
        chip(EntityRange.full, '全书（1~${widget.chapters.length}章）',
            const Key('entity-range-full')),
      ],
    );
  }

  /// 输出区：加载 / 错误 / 抽取中 / 空完成 / 清单（含进度与中断提示）五态。
  Widget _buildBody(ThemeData theme) {
    if (_preparing) {
      return _statusRow(theme, '正在准备…');
    }
    if (_err != null) {
      return SingleChildScrollView(
        child: Text(
          _err!,
          key: const Key('entity-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (_running && _items.isEmpty) {
      return _statusRow(
        theme,
        _total > 0 ? '正在抽取（$_done/$_total 段）…' : '正在抽取…',
      );
    }
    if (_emptyDone) {
      return Text(
        '未抽取到实体，可点击重新生成。',
        key: const Key('entity-empty'),
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
              '正在抽取（$_done/$_total 段）· 已发现 ${_items.length} 项',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _notice!,
              key: const Key('entity-notice'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        Flexible(
          child: SingleChildScrollView(
            key: const Key('entity-output'),
            child: _buildList(theme),
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

  /// 分组清单（人物 / 势力 / 专有名词；空组不占位）。
  Widget _buildList(ThemeData theme) {
    final List<Widget> sections = <Widget>[];
    for (final String type in kEntityTypes) {
      final List<EntityItem> group =
          _items.where((EntityItem e) => e.type == type).toList();
      if (group.isEmpty) continue;
      sections.add(
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            type,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
      for (final EntityItem item in group) {
        sections.add(_buildItem(theme, item));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: sections,
    );
  }

  /// 单条：名字 + 描述 + 出场章节 chips（`AI-07` ②，点击跳原文）。
  Widget _buildItem(ThemeData theme, EntityItem item) {
    final List<int> refs = item.chapters
        .where((int c) => c >= 0 && c < widget.chapters.length)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            item.name,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (item.desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                item.desc,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (refs.isNotEmpty)
            Wrap(
              spacing: 4,
              runSpacing: 0,
              children: <Widget>[
                for (final int c in refs)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      foregroundColor: theme.colorScheme.primary,
                    ),
                    onPressed: () => widget.onJump(c),
                    child: Text(
                      '第${c + 1}章',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 操作行：停止 / 生成·重新生成 / 重试（按状态互斥出现）。
  Widget _buildActions(ThemeData theme) {
    return Row(
      children: <Widget>[
        if (_running)
          TextButton.icon(
            key: const Key('entity-stop'),
            onPressed: _stop,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('停止'),
          ),
        if (!_running && _err == null && _canRetry)
          TextButton.icon(
            key: const Key('entity-generate'),
            onPressed: _items.isEmpty ? _start : _regenerate,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(_items.isEmpty ? '生成' : '重新生成'),
          ),
        if (!_running && _err != null && _canRetry)
          TextButton.icon(
            key: const Key('entity-retry'),
            onPressed: _start,
            icon: const Icon(Icons.replay, size: 18),
            label: const Text('重试'),
          ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('返回'),
        ),
      ],
    );
  }
}
