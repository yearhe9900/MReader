// `CNT-06` 书内搜索面板（M2b-T04）：输入关键词 → 全书搜索 → 「章节名 +
// 上下文片段」列表 → 点击跳转并高亮。
//
// 验收映射（CNT-06）：
//   ① 命中数与实际出现次数一致 —— 状态行「共命中 N 处」与列表行数**同源**
//      （都来自事件流逐条累计，无独立计数器可分歧）；
//   ② 点击跳转且关键词高亮 —— 行点击 → [SearchSheet.onJump]（跳转与高亮由
//      阅读页执行，面板只传出命中 + 当前搜索词）；
//   ③ 搜索中可取消且 UI 不卡死 —— 搜索期间显示进度条 + 实时命中计数 +
//      「取消」按钮；取消即 [SearchSession.cancel]（协议级取消：后台 isolate
//      随即退出、不留后台线程，见 `task/search_session.dart`）。
//
// 执行路径由调用方的 [SearchSession] 决定（后台 isolate / 本 isolate 流式），
// 面板只消费事件流——搜索驱动与 UI 解耦。
// 列表行下垫不透明表面（`UI-04`）由调用方的 [OpaqueContentSurface] 外壳负责
// （与 [BookmarkSheet] / [TocSheet] 同款玻璃弹层套路）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../format/book_source.dart';
import '../task/search_session.dart';
import '../typography/typeset.dart';

/// 全书搜索底部弹窗。
class SearchSheet extends StatefulWidget {
  const SearchSheet({
    super.key,
    required this.startSearch,
    required this.onJump,
  });

  /// 发起一次搜索（参数为已 trim 的非空关键词）：返回 [SearchSession]。
  final SearchSession Function(String query) startSearch;

  /// 点击命中行：调用方负责关弹窗 + 跳转 + 高亮（query = 当前搜索词）。
  final void Function(SearchHit hit, String query) onJump;

  @override
  State<SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<SearchSheet> {
  final TextEditingController _input = TextEditingController();

  /// 当前（或最近一次完成的）搜索词——点击命中行时随 [SearchHit] 一并传出。
  String _query = '';

  /// 命中列表（按到达顺序；`SearchEvent.hit` 逐条追加）。
  final List<SearchHit> _hits = <SearchHit>[];

  SearchSession? _session;
  StreamSubscription<SearchEvent>? _sub;

  /// 进度 `0.0 ~ 1.0`（`SearchEvent.progress` 单调递增；`null` = 尚无进度事件）。
  double? _progress;

  bool _running = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    // 弹层拆树时仍在搜索 → 取消（协议级：后台 isolate 随即退出，不留后台线程）。
    _stop();
    _input.dispose();
    super.dispose();
  }

  /// 取消并放下当前会话（不改 UI 状态；调用方负责 setState 口径）。
  void _stop() {
    _session?.cancel();
    _sub?.cancel();
    _sub = null;
    _session = null;
  }

  void _start(String raw) {
    final String query = raw.trim();
    // 空词不发起（也不打断进行中的搜索）。
    if (query.isEmpty) return;
    // 重复提交：先取消旧会话再开新的（旧会话迟到事件被会话层丢弃）。
    _stop();
    setState(() {
      _query = query;
      _hits.clear();
      _progress = null;
      _error = null;
      _done = false;
      _running = true;
    });
    final SearchSession session = widget.startSearch(query);
    _session = session;
    _sub = session.events.listen(
      (SearchEvent event) {
        if (!mounted) return;
        final SearchHit? hit = event.hit;
        if (hit != null) {
          setState(() => _hits.add(hit));
        } else if (event.progress != null) {
          setState(() => _progress = event.progress);
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _done = true;
          // 格式错误文案唯一来源 `error_messages.dart`（RD-05）；
          // 非格式错误是驱动层意外兜底（isolate 派发失败等）。
          _error = error is MReaderFormatException
              ? error.message
              : '搜索失败，请重试。';
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _running = false;
          _done = true;
        });
      },
    );
  }

  /// 验收③「搜索中可取消」：取消会话（协议级）+ 保留已收集的命中。
  void _cancel() {
    _stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _done = true;
    });
  }

  /// 空列表区提示（随状态切换）。
  String get _emptyHint {
    if (_running) return '搜索中…';
    if (_error != null) return '';
    if (_done) return '没有找到「$_query」。';
    return '输入关键词搜索全书。';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('search-input'),
                    controller: _input,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: '输入关键词搜索全书',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: _start,
                  ),
                ),
                IconButton(
                  key: const Key('search-submit'),
                  tooltip: '搜索',
                  icon: const Icon(Icons.search),
                  onPressed: () => _start(_input.text),
                ),
              ],
            ),
          ),
          _buildStatus(theme),
          const Divider(height: 1),
          if (_hits.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_emptyHint, style: theme.textTheme.bodyMedium),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _hits.length,
                itemBuilder: (BuildContext context, int index) {
                  final SearchHit hit = _hits[index];
                  return ListTile(
                    key: Key('search-hit-$index'),
                    title: Text(
                      hit.chapterTitle.isNotEmpty
                          ? hit.chapterTitle
                          : '第 ${hit.chapterIndex + 1} 节',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // 上下文片段 = 命中所在整段；命中词叠高亮底色（与正文同款
                    // `highlightSpans`，口径一致）。
                    subtitle: Text.rich(
                      TextSpan(
                        children: highlightSpans(
                          <InlineSpan>[TextSpan(text: hit.context)],
                          _query,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => widget.onJump(hit, _query),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 状态行：错误 / 搜索中（进度 + 计数 + 取消）/ 完成计数 / 初始（留空）。
  Widget _buildStatus(ThemeData theme) {
    final String? error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          error,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.error),
        ),
      );
    }
    if (_running) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: LinearProgressIndicator(
                key: const Key('search-progress'),
                value: _progress, // null = 不确定进度（无进度事件时）
                minHeight: 4,
              ),
            ),
            const SizedBox(width: 12),
            Text('已命中 ${_hits.length} 处', style: theme.textTheme.bodySmall),
            TextButton(
              key: const Key('search-cancel'),
              onPressed: _cancel,
              child: const Text('取消'),
            ),
          ],
        ),
      );
    }
    if (_done) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '共命中 ${_hits.length} 处',
            key: const Key('search-count'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
