// `META-08` 书籍详情页（`F9` 流程：书架点一本书 → 进入书籍详情页）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 玻璃态红线（PRD §11.2 + `UI-04`）—— 违反即返工
// ══════════════════════════════════════════════════════════════════════════════
// · 顶栏 = 导航层 → 玻璃（[GlassTopBar] / [GlassNavScaffold]；**从不手传 premium**，
//   固定表面档位由库自动提升，见 `GlassKit`）；
// · **封面区与简介文本区 = 内容层 → 一律不透明**：滚动内容与底部操作区整体由
//   [OpaqueContentSurface] 承载，内部不出现任何玻璃控件（不玻璃包玻璃、
//   玻璃不进滚动列表行）。
//
// 开书管道：**不复制第二份**——书架把带 `_opening` 守卫的 `onOpenBook` 回调注入本页，
// 底部「继续阅读」只转发；本页 pop 后由书架刷新列表（编辑 / 移出 / 进度都靠它同步）。
// 「移出书架」走 `LibraryRepository.deleteBook` + 既有二次确认，完成后 pop 回书架。
//
// 一次性回填（`META-08`）：加载时若四来源**全为 `none`**（旧索引条目，见
// `needsOriginBackfill` 注释），重新解析回填一次并 `updateRecord` 落盘；
// `origin == user` 的字段绝不动（`META-09 ④`）。之后不再重解析（有界 IO）。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../format/book_registry.dart';
import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../meta/cover_store.dart';
import '../meta/meta_editor.dart';
import '../reader/progress_store.dart';
import 'cover_picker.dart';
import 'glass_kit.dart';

/// 书籍详情页（`META-08`）。
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({
    super.key,
    required this.record,
    required this.repository,
    required this.coverStore,
    required this.progressStore,
    required this.onOpenBook,
  });

  /// 进入详情页时的记录快照（书架传入；页内编辑 / 恢复后由 State 持有最新值）。
  final BookRecord record;

  /// 书库仓库：详情页**唯一后端**（不直触 `BookIndex`）。
  final LibraryRepository repository;

  /// 封面存储（缩略图 / 大图 / 换封面物化）。
  final CoverStore coverStore;

  /// 阅读进度存储：「移出书架」时连带清理进度（`LIB-06`）。
  final ProgressStore progressStore;

  /// 开书回调：**复用书架的 `_openBook`**（含 `_opening` 守卫），本页禁止复制第二份。
  final Future<void> Function(BookRecord record) onOpenBook;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  late BookRecord _record;

  /// library 副本文件大小（字节）；未载入 / 文件缺失 → `null`（展示 `—`）。
  int? _fileSize;

  /// 封面缩略图字节（展示时现读、离页即弃，`PERF-02` 不常驻）。
  Uint8List? _coverThumb;
  bool _coverLoading = false;

  /// 「继续阅读」准备中（读字节 + 建源，直到 push 发起）。
  bool _continuing = false;

  /// 一次性回填进行中（防重入；`initState` 触发一次）。
  bool _backfilling = false;

  // —— 编辑态（`META-09`）——

  /// 是否处于编辑态：书名 / 作者 / 简介显示 `TextField`，底部换「取消 / 保存」。
  bool _editing = false;

  /// 编辑输入控制器（进入编辑态时创建、退出时 dispose；浏览态为 `null`）。
  TextEditingController? _titleCtrl;
  TextEditingController? _authorCtrl;
  TextEditingController? _introCtrl;

  /// 「恢复自动值」/ 换封面进行中（防重复点击）。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
    _startCoverLoad(); // 直接改字段（initState 期间不调 setState）
    _loadFileSize();
    if (needsOriginBackfill(_record)) {
      unawaited(_backfill());
    }
  }

  @override
  void dispose() {
    _titleCtrl?.dispose();
    _authorCtrl?.dispose();
    _introCtrl?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 载入
  // -------------------------------------------------------------------------

  /// 载入封面缩略图（仅 [StoredCover]；其它类型走占位）。
  ///
  /// 必须在 `setState` 内或 `initState` 中调用（会同步置 `_coverLoading`）。
  void _startCoverLoad() {
    final CoverRef ref = _record.cover;
    if (ref is! StoredCover) {
      _coverThumb = null;
      _coverLoading = false;
      return;
    }
    _coverLoading = true;
    widget.coverStore.readThumb(ref).then(
      (Uint8List? bytes) {
        if (!mounted) return;
        setState(() {
          _coverThumb = bytes;
          _coverLoading = false;
        });
      },
      onError: (_) {
        if (!mounted) return;
        setState(() => _coverLoading = false);
      },
    );
  }

  Future<void> _loadFileSize() async {
    final int? size = await widget.repository.bookFileSize(_record);
    if (!mounted) return;
    setState(() => _fileSize = size);
  }

  /// 重新解析本书元数据（一次性回填与「恢复自动值」共用）；文件缺失 → `null`。
  ///
  /// `load()` 无论成败都 `dispose()`（抄 `import_service.dart` 的 `try/finally`）。
  Future<BookMeta?> _reparse() async {
    final Uint8List? bytes = await widget.repository.readBookBytes(_record);
    if (bytes == null || bytes.isEmpty) return null;
    final BookSource source = await openBook(
      fileName: _record.fileName,
      bytes: bytes,
    );
    try {
      return await source.load();
    } finally {
      await source.dispose();
    }
  }

  /// 一次性回填：重新解析 → 文本与来源按 `backfillFromMeta` 回填 → 落盘一次。
  ///
  /// 失败（文件缺失 / 解析异常）静默降级：详情页按现值展示、来源显示「未知」，
  /// 不阻塞浏览、不重试（有界 IO）。
  Future<void> _backfill() async {
    if (_backfilling) return;
    _backfilling = true;
    try {
      final BookMeta? meta = await _reparse();
      if (meta == null || !mounted) return;

      // 封面：仅当来源未知、当前还没有落盘封面、且解析出内嵌封面时才物化
      // （老 EPUB 记录已有 `StoredCover` → 保留现文件不重写；`PendingCover`
      // 不得进持久化，见 `CoverRef` 不变式）。
      CoverRef cover = _record.cover;
      final CoverRef parsedCover = meta.cover;
      if (_record.coverOrigin == MetaOrigin.none &&
          cover is! StoredCover &&
          parsedCover is PendingCover) {
        cover = await widget.coverStore.materialize(
          bookId: _record.bookId,
          pending: parsedCover,
        );
      }

      final BookRecord updated =
          backfillFromMeta(_record, meta).copyWith(cover: cover);
      await widget.repository.updateRecord(updated);
      if (!mounted) return;
      setState(() {
        _record = updated;
        _startCoverLoad();
      });
    } catch (_) {
      // 回填失败静默：现值可看、来源标「未知」，不崩不重试。
    } finally {
      _backfilling = false;
    }
  }

  // -------------------------------------------------------------------------
  // 操作
  // -------------------------------------------------------------------------

  /// 进入编辑态（`META-09`）：按当前值初始化三个输入框。
  void _enterEdit() {
    _titleCtrl = TextEditingController(text: _record.title);
    _authorCtrl = TextEditingController(text: _record.author);
    _introCtrl = TextEditingController(text: _record.intro);
    // 输入变化 → 重算校验错误 / 保存按钮可用性。
    for (final TextEditingController c
        in <TextEditingController>[_titleCtrl!, _authorCtrl!, _introCtrl!]) {
      c.addListener(() {
        if (mounted && _editing) setState(() {});
      });
    }
    setState(() => _editing = true);
  }

  /// 退出编辑态：丢弃输入（取消 / 保存后都走这里），控制器即弃。
  void _exitEdit() {
    _titleCtrl?.dispose();
    _authorCtrl?.dispose();
    _introCtrl?.dispose();
    _titleCtrl = null;
    _authorCtrl = null;
    _introCtrl = null;
    setState(() => _editing = false);
  }

  /// 当前编辑输入的校验错误（`null` = 可保存）。
  String? get _editError => validateEdits(
        title: _titleCtrl?.text ?? '',
        author: _authorCtrl?.text ?? '',
      );

  /// 保存编辑（`META-09`）：只有值实际变化的字段置 `user`，随后落盘。
  Future<void> _saveEdits() async {
    if (_editError != null || _busy) return;
    setState(() => _busy = true);
    try {
      final BookRecord updated = applyEdits(
        _record,
        title: _titleCtrl!.text,
        author: _authorCtrl!.text,
        intro: _introCtrl!.text,
      );
      await widget.repository.updateRecord(updated);
      if (!mounted) return;
      setState(() => _record = updated);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    _exitEdit(); // 书架在 push 的 await 后刷新 → 书架与详情页同步（`META-09 ①`）
  }

  /// 换封面（`META-09`）：本地选图 → `replaceWithUserPick`（内建旧文件清理，
  /// `META-06 ①/②`）→ `coverOrigin` 置 `user` → 落盘。
  Future<void> _pickCover() async {
    if (_busy) return;
    final Uint8List? bytes = await pickCoverBytes();
    if (bytes == null || bytes.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final StoredCover stored = await widget.coverStore.replaceWithUserPick(
        bookId: _record.bookId,
        bytes: bytes,
        previous: _record.cover,
      );
      final BookRecord updated = _record.copyWith(
        cover: stored,
        coverOrigin: MetaOrigin.user,
      );
      await widget.repository.updateRecord(updated);
      if (!mounted) return;
      setState(() {
        _record = updated;
        _startCoverLoad();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「恢复自动值」（`META-09 ③`）：重新解析取自动值 → 文本与四来源回解析值；
  /// 封面：`PendingCover` 物化（幂等，覆盖旧文件），无内嵌封面则清掉当前封面文件。
  ///
  /// `load()` 无论成败都 `dispose()`（抄 `import_service.dart` 的 `try/finally`）。
  Future<void> _restoreAuto() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final BookMeta? meta = await _reparse();
      if (!mounted) return;
      if (meta == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件已丢失，无法恢复自动值')),
        );
        return;
      }

      // 封面引用：EPUB → PendingCover 物化（先清同 bookId 旧文件，不留孤儿）；
      // TXT 等无内嵌封面 → 按解析结果回退，并清掉当前封面文件（换过的用户封面）。
      CoverRef cover = _record.cover;
      final CoverRef parsedCover = meta.cover;
      if (parsedCover is PendingCover) {
        cover = await widget.coverStore.materialize(
          bookId: _record.bookId,
          pending: parsedCover,
        );
      } else {
        if (cover is StoredCover) {
          await widget.coverStore.delete(cover);
        }
        cover = parsedCover;
      }

      final BookRecord updated =
          restoreFromMeta(_record, meta).copyWith(cover: cover);
      await widget.repository.updateRecord(updated);
      if (!mounted) return;
      setState(() {
        _record = updated;
        _startCoverLoad();
      });
      // 编辑态下输入框同步回自动值（恢复 = 全部可编辑字段回到自动值）。
      if (_editing) {
        _titleCtrl?.text = updated.title;
        _authorCtrl?.text = updated.author;
        _introCtrl?.text = updated.intro;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('恢复自动值失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「继续阅读」：只转发给书架注入的开书回调（**不复制开书管道**）。
  Future<void> _continueReading() async {
    if (_continuing) return;
    setState(() => _continuing = true);
    try {
      await widget.onOpenBook(_record);
    } finally {
      if (mounted) setState(() => _continuing = false);
    }
  }

  /// 移出书架：二次确认 → `deleteBook`（副本 + 封面）+ 连带清进度 → pop 回书架。
  ///
  /// 本项目**导入即入架**，无「未入架」状态，故不提供「加入书架」（见交付报告偏差声明）。
  Future<void> _removeFromShelf() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('移出书架'),
        content: Text(
          '确定将「${_record.title}」移出书架？\n删除后书架不再列出，封面与副本文件一并清理。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.repository.deleteBook(_record);
    // `LIB-06` 连带清理：删除该书阅读进度文件（缺失时静默成功）。
    await widget.progressStore.remove(_record.bookId);
    if (!mounted) return;
    Navigator.of(context).pop(); // 书架在 push 的 await 后刷新列表
  }

  void _showStatsPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('单书统计在后续里程碑开放')),
    );
  }

  // -------------------------------------------------------------------------
  // 展示
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: const Text('书籍详情'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: <Widget>[
          // 编辑入口（`META-09`）；编辑态下入口隐藏（底部换「取消 / 保存」）。
          if (!_editing)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑元数据',
              onPressed: _busy ? null : _enterEdit,
            ),
        ],
      ),
      // 内容层整体不透明（`UI-04`）：滚动区 + 底部操作同在一个 OpaqueContentSurface。
      body: OpaqueContentSurface(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: _buildSections(theme),
              ),
            ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: _buildActions(theme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 详情内容段落（封面区 / 身份区 / 元信息 / 简介 / 统计入口）。
  ///
  /// 编辑态（`META-09`）：书名 / 作者 / 简介换成 `TextField`（不透明普通 Material，
  /// 仍属内容层，零玻璃），封面区追加「更换封面 / 恢复自动值」按钮。
  List<Widget> _buildSections(ThemeData theme) {
    return <Widget>[
      _buildCoverArea(theme),
      const SizedBox(height: 16),
      if (_editing) ...<Widget>[
        _buildTextField(
          controller: _titleCtrl!,
          label: '书名',
          errorText: (_titleCtrl!.text.trim().isEmpty) ? '书名不能为空' : null,
        ),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _authorCtrl!,
          label: '作者',
          errorText: (_authorCtrl!.text.trim().isEmpty)
              ? '作者不能为空（缺失时填「未知作者」）'
              : null,
        ),
      ] else ...<Widget>[
        _buildTitleRow(theme),
        const SizedBox(height: 6),
        _buildAuthorRow(theme),
      ],
      const SizedBox(height: 12),
      _buildInfoRow(theme, '格式', _FormatTag(format: _record.format)),
      _buildInfoRow(
        theme,
        '文件大小',
        Text(
          _fileSize == null ? '—' : _formatSize(_fileSize!),
          style: theme.textTheme.bodyMedium,
        ),
      ),
      _buildInfoRow(
        theme,
        '阅读进度',
        Text(
          _record.readProgress == null
              ? '未开始'
              : '${(_record.readProgress! * 100).round()}%',
          style: theme.textTheme.bodyMedium,
        ),
      ),
      _buildInfoRow(
        theme,
        // `P2-02` 分组未实现：显示「未分组」且**禁用**（不提供入口、不自造分组系统）。
        '分组',
        Text(
          '未分组',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
      const SizedBox(height: 16),
      _buildIntroSection(theme),
      const SizedBox(height: 8),
      _buildStatsEntry(theme),
    ];
  }

  /// 封面区（内容层 → 不透明；点封面看大图，`META-08 ①`）。
  ///
  /// 编辑态追加「更换封面 / 恢复自动值」（`META-09`），不透明普通按钮（非玻璃）。
  Widget _buildCoverArea(ThemeData theme) {
    final CoverRef ref = _record.cover;
    final bool tappable = ref is StoredCover && !_editing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GestureDetector(
          onTap: tappable
              ? () => unawaited(
                  showCoverFullScreen(context, widget.coverStore, ref),
                )
              : null,
          child: SizedBox(
            width: 120,
            height: 180,
            child: _buildCover(theme),
          ),
        ),
        const SizedBox(height: 6),
        _OriginBadge(origin: _record.coverOrigin), // 封面来源标记
        if (_editing) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickCover,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('更换封面'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _restoreAuto,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('恢复自动值'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildCover(ThemeData theme) {
    if (_coverThumb != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(
          _coverThumb!,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildCoverPlaceholder(theme),
        ),
      );
    }
    if (_coverLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return _buildCoverPlaceholder(theme);
  }

  /// 无封面 / 合成封面占位：书名首字 + 主题色底（同 `BookCard` 口径）。
  Widget _buildCoverPlaceholder(ThemeData theme) {
    final String initial =
        _record.title.isNotEmpty ? _record.title.characters.first : '?';
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: theme.textTheme.headlineLarge?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 书名 + 来源标记。
  Widget _buildTitleRow(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Text(
            _record.title,
            style: theme.textTheme.titleLarge,
          ),
        ),
        const SizedBox(width: 8),
        _OriginBadge(origin: _record.titleOrigin),
      ],
    );
  }

  /// 作者 + 来源标记（TXT 作者标「文件名推断」，`META-08 ②`）。
  Widget _buildAuthorRow(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Text(
            _record.author,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _OriginBadge(origin: _record.authorOrigin),
      ],
    );
  }

  /// 标签-值信息行（不透明普通 Material 行，非玻璃）。
  Widget _buildInfoRow(ThemeData theme, String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: value),
        ],
      ),
    );
  }

  /// 简介文本区（内容层 → **不透明**；无简介显示占位而非空白，`META-08 ④`）。
  ///
  /// 编辑态换成多行 `TextField`（同一不透明底，仍属内容层、零玻璃）。
  Widget _buildIntroSection(ThemeData theme) {
    final bool hasIntro = _record.intro.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      // 显式取完全不透明底色（`UI-04`：简介文本区一律不透明）。
      color: OpaqueContentSurface.fullyOpaque(
        theme.colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('简介', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              if (!_editing) _OriginBadge(origin: _record.introOrigin),
            ],
          ),
          const SizedBox(height: 8),
          if (_editing)
            TextField(
              controller: _introCtrl,
              maxLines: 6,
              minLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '暂无简介',
                isDense: true,
              ),
              style: theme.textTheme.bodyMedium,
            )
          else
            Text(
              hasIntro ? _record.intro : '暂无简介',
              style: hasIntro
                  ? theme.textTheme.bodyMedium
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                      fontStyle: FontStyle.italic,
                    ),
            ),
        ],
      ),
    );
  }

  /// 编辑态单行输入框（书名 / 作者；不透明普通 Material，零玻璃）。
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String? errorText,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        errorText: errorText,
        isDense: true,
      ),
    );
  }

  /// 单书统计入口（`STAT-09` 不在本任务实现：空态占位提示）。
  Widget _buildStatsEntry(ThemeData theme) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.bar_chart_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: const Text('单书统计'),
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.outline,
      ),
      onTap: _showStatsPlaceholder,
    );
  }

  /// 底部操作（`META-08`）：浏览态 = 移出书架 + 继续阅读；
  /// 编辑态（`META-09`）= 取消 + 保存（书名 / 作者为空时保存禁用 + 就地提示）。
  Widget _buildActions(ThemeData theme) {
    if (_editing) {
      final bool canSave = _editError == null && !_busy;
      return Row(
        children: <Widget>[
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : _exitEdit,
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: canSave ? _saveEdits : null,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _removeFromShelf,
            icon: const Icon(Icons.remove_circle_outline),
            label: const Text('移出书架'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: _continuing ? null : _continueReading,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_continuing) ...<Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                const Text('继续阅读'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 文件大小展示（B / KB / MB，保留 1 位小数）。
  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 元数据来源标记徽标（四值闭合：元数据 / 文件名推断 / 用户自定义 / 未知）。
class _OriginBadge extends StatelessWidget {
  const _OriginBadge({required this.origin});

  final MetaOrigin origin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color background;
    final Color foreground;
    switch (origin) {
      case MetaOrigin.metadata:
        background = theme.colorScheme.secondaryContainer;
        foreground = theme.colorScheme.onSecondaryContainer;
      case MetaOrigin.filename:
        background = theme.colorScheme.tertiaryContainer;
        foreground = theme.colorScheme.onTertiaryContainer;
      case MetaOrigin.user:
        background = theme.colorScheme.primaryContainer;
        foreground = theme.colorScheme.onPrimaryContainer;
      case MetaOrigin.none:
        background = theme.colorScheme.surfaceContainerHighest;
        foreground = theme.colorScheme.outline;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: OpaqueContentSurface.fullyOpaque(background),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        originLabel(origin),
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 格式标签（EPUB / TXT；同 `BookCard` 口径）。
class _FormatTag extends StatelessWidget {
  const _FormatTag({required this.format});

  final String format;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        format.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
