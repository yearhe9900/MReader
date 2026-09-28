// `LIB-01`：书架首页（替代 M0 验证台的 `HomePage`）。
//
// 空态：引导文案 + 导入按钮。
// 有书：网格展示 [BookCard]（封面缩略图 + 书名 + 作者 + 格式标签）。
// 导入：`FilePicker` 多选 → 逐个调 `importFile`，展示进度 + 失败清单。
// 删除：长按书卡 → 确认对话框 → `deleteBook`（`LIB-06` 二次确认）+ 连带清理阅读进度。
// 点击书卡 → 进入书籍详情页（`F9` / `META-08`）；详情页底部「继续阅读」经**注入的**
// `_openBook` 开书（详情页**不复制**开书管道），详情页 pop 后刷新列表
// （编辑 / 移出 / 进度都靠这次刷新同步）。
// 开书守卫 `_opening` **只覆盖 push 前的准备阶段**（修复「首点无响应」：守卫若覆盖
// 整个阅读会话 + 关书刷新，关书后首点会被静默吞掉）；准备期被点卡片显示 loading。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider）。
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/perf_log.dart';
import '../format/book_registry.dart';
import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../meta/cover_store.dart';
import '../reader/progress_store.dart';
import '../reader/reader_page.dart';
import 'book_card.dart';
import 'book_detail_page.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'library_search_page.dart';

/// 书架首页。
class ShelfPage extends StatefulWidget {
  const ShelfPage({
    super.key,
    required this.repository,
    required this.coverStore,
    required this.progressStore,
  });

  /// 书库仓库。
  final LibraryRepository repository;

  /// 封面存储（传给 [BookCard] 加载缩略图）。
  final CoverStore coverStore;

  /// 阅读进度存储（`RD-04`）：传给阅读页；删书时连带清理。
  final ProgressStore progressStore;

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  List<BookRecord> _books = <BookRecord>[];
  bool _loading = true;
  bool _importing = false;
  List<String> _importErrors = <String>[];

  /// 防重复开书：**只覆盖 push 前的准备阶段**（readBookBytes + openBook）。
  /// 路由一入栈立即释放——阅读会话期间绝不占用（否则关书后首点被静默吞掉，
  /// 表现为「首点无响应、必须再点一次」）。
  bool _opening = false;

  /// 正在准备打开的书（bookId）：对应卡片显示 loading 覆盖层；`null` = 无。
  String? _openingBookId;

  /// 详情页路由在栈上（push 已发起、尚未 pop）：吞掉过渡期 / 会话期的重复点卡，
  /// 防「双击卡片 → 叠两个详情页」。pop 后由 [_openDetail] 的 `finally` 释放。
  bool _detailPushing = false;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    final List<BookRecord> books = await widget.repository.loadBooks();
    if (mounted) {
      setState(() {
        _books = books;
        _loading = false;
      });
    }
  }

  Future<void> _pickAndImport() async {
    setState(() {
      _importErrors = <String>[];
    });

    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['epub', 'txt'],
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    if (!mounted) return;
    setState(() => _importing = true);

    int success = 0;
    final List<String> errors = <String>[];
    for (final PlatformFile file in result.files) {
      final Uint8List? bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        errors.add('${file.name}：未能读取文件内容');
        continue;
      }
      try {
        final ImportResult importResult = await widget.repository.importFile(
          bytes: bytes,
          fileName: file.name,
        );
        if (importResult.isNew) {
          success++;
        } else {
          errors.add('${file.name}：已存在（${importResult.record.title}）');
        }
      } catch (e) {
        errors.add('${file.name}：$e');
      }
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _importErrors = errors;
    });

    // 刷新列表
    await _loadBooks();

    // 显示导入结果摘要
    if (mounted && (success > 0 || errors.isNotEmpty)) {
      final String msg = errors.isEmpty
          ? '成功导入 $success 本'
          : '成功 $success 本，失败 ${errors.length} 本';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _deleteBook(BookRecord record) async {
    // `UI-03` 浮层玻璃：玻璃确认框（`M2a-T04`）。barrier 可关（返回 null = 取消），
    // 语义与原 `showDialog<bool>` 一致：非 `true` 一律不删。
    final bool? confirmed = await GlassOverlays.showAlert<bool>(
      context: context,
      title: '删除确认',
      message: '确定删除「${record.title}」？\n删除后书架不再列出，封面文件一并清理。',
      barrierDismissible: true,
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(context, false),
        ),
        GlassDialogAction(
          label: '删除',
          isDestructive: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed == true) {
      await widget.repository.deleteBook(record);
      // `LIB-06` 连带清理：删除该书阅读进度文件（缺失时静默成功）。
      await widget.progressStore.remove(record.bookId);
      await _loadBooks();
    }
  }

  /// 点书卡 → 书籍详情页（`F9` / `META-08 ①`）。
  ///
  /// pop 后刷新列表——编辑 / 移出书架 / 进度变化都靠这次刷新同步回书架。
  /// 开书管道以 `onOpenBook: _openBook` 回调注入详情页（详情页禁止复制第二份）。
  Future<void> _openDetail(BookRecord record) async {
    if (_detailPushing) return; // 过渡期防双击叠详情页
    _detailPushing = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BookDetailPage(
            record: record,
            repository: widget.repository,
            coverStore: widget.coverStore,
            progressStore: widget.progressStore,
            onOpenBook: _openBook,
          ),
        ),
      );
    } finally {
      _detailPushing = false;
    }
    // 详情页已关闭：刷新（编辑 / 移出 / 进度都在这里同步）。
    if (mounted) unawaited(_loadBooks());
  }

  /// 打开一本书：准备（读字节 + 建源）→ push 阅读页。
  ///
  /// 守卫 [_opening] **只覆盖 push 前的准备阶段**（防准备期连点重复 push）；
  /// 路由一入栈立即释放——阅读会话期间绝不占用，否则关书后首点被静默吞掉。
  /// 准备期被点的卡片显示 loading 覆盖层（[BookCard.loading]）。
  Future<void> _openBook(BookRecord record) async {
    if (_opening) return; // 准备期防双击重复开书
    _opening = true;
    setState(() => _openingBookId = record.bookId); // 该卡显示 loading 覆盖层
    try {
      final PerfWatch readWatch = PerfLog.watch('open.readBytes');
      final Uint8List? bytes = await widget.repository.readBookBytes(record);
      readWatch.done(
          'book=${record.title} sizeKB=${(bytes?.length ?? 0) ~/ 1024}');
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件已丢失：${record.fileName}')),
          );
        }
        return;
      }

      final PerfWatch sniffWatch = PerfLog.watch('open.sniff');
      final BookSource source = await openBook(
        fileName: record.fileName,
        bytes: bytes,
      );
      sniffWatch.done('impl=${source.implId}');
      // 不在导航前 eager 解析：全量 load() 在主 isolate 同步执行会冻结 UI，
      // 导致首击「无响应」、用户补点第二次（PERF）。解析与 loading 交给
      // ReaderPage._open() 承担（其自带 spinner + 错误态，RD-05 仍满足）。

      if (!mounted) return;
      final MaterialPageRoute<void> route = MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          source: source,
          record: record,
          progressStore: widget.progressStore,
          repository: widget.repository,
        ),
      );
      // 不 await push 的 Future（它要等路由 pop 才返回）——push 一发起（路由已
      // 入栈）就往下走，finally 立即释放守卫。关书刷新走 route.popped，不占守卫。
      unawaited(Navigator.of(context).push(route));
      unawaited(route.popped.then((_) {
        // 阅读页关闭后刷新（lastReadAt / readProgress 已在 M1-T04 更新）。
        if (mounted) unawaited(_loadBooks());
      }));
    } finally {
      _opening = false;
      if (mounted) setState(() => _openingBookId = null);
    }
  }

  /// 顶栏假搜索框 → 书库搜索页；选中结果直接进详情页。
  ///
  /// 搜索做成**独立页面**（而非就地输入）：查询与书架状态解耦，
  /// 也不必在当前子树里处理键盘遮挡。与 anx-reader 的做法一致。
  Future<void> _openSearch() async {
    final BookRecord? picked = await Navigator.of(context).push<BookRecord>(
      MaterialPageRoute<BookRecord>(
        builder: (_) => LibrarySearchPage(books: _books),
      ),
    );
    if (picked != null && mounted) {
      await _openDetail(picked);
    }
  }

  /// 书架背景渐变（**两个色标都完全不透明**）。
  ///
  /// anx-reader 用 `colorScheme.primary.withAlpha(5)` 叠在 Scaffold 底色上做出
  /// 极淡的右上角光晕。本项目 `UI-04` 要求内容层不得半透明，故选**先把半透明色
  /// 与底色合成**（[Color.alphaBlend]）——合成的结果 alpha 恒为 1，
  /// 观感与「半透明叠底」等价，红线不破。
  BoxDecoration _shelfBackground(ThemeData theme) {
    final Color base = theme.scaffoldBackgroundColor;
    final Color glow = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.02),
      base,
    );
    return BoxDecoration(
      gradient: RadialGradient(
        center: Alignment.topRight,
        radius: 1,
        colors: <Color>[glow, base],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // `UI-02` 导航层玻璃化：顶栏走 GlassTopBar、壳层走 GlassNavScaffold
    // （照抄 book_detail_page 范本）；内容整体不透明（`UI-04`）。
    if (_loading) {
      return GlassNavScaffold(
        appBar: const GlassTopBar(title: Text('书架')),
        body: const OpaqueContentSurface(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return GlassNavScaffold(
      appBar: GlassTopBar(
        // 标题位放「假搜索框」——外观是搜索框，点击进搜索页（照搬 anx-reader）。
        title: _BookSearchEntry(onTap: _openSearch),
        actions: <Widget>[
          if (_importing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '导入书籍',
              onPressed: _pickAndImport,
            ),
        ],
      ),
      body: OpaqueContentSurface(
        child: DecoratedBox(
          decoration: _shelfBackground(theme),
          child: _books.isEmpty ? _buildEmptyState(theme) : _buildBookGrid(theme),
        ),
      ),
    );
  }

  /// 空态（LIB-01 验收要点 ②）。
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.menu_book_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              '书架空空如也',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '导入 EPUB / TXT 文件开始阅读',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickAndImport,
              icon: const Icon(Icons.folder_open),
              label: const Text('导入书籍'),
            ),
            if (_importErrors.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _buildErrorList(theme),
            ],
          ],
        ),
      ),
    );
  }

  /// 有书：网格展示。
  Widget _buildBookGrid(ThemeData theme) {
    return Column(
      children: <Widget>[
        Expanded(
          child: GridView.builder(
            // 底部留给壳层的浮动胶囊（[kShellBottomInset]）——胶囊是浮层、
            // 不占布局高度，不预留的话最后一行会被压住。
            padding: const EdgeInsets.fromLTRB(12, 12, 12, kShellBottomInset),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              childAspectRatio: 0.5,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _books.length,
            itemBuilder: (BuildContext context, int index) {
              final BookRecord record = _books[index];
              return BookCard(
                record: record,
                coverStore: widget.coverStore,
                loading: _openingBookId == record.bookId,
                onTap: () => unawaited(_openDetail(record)),
                onLongPress: () => _deleteBook(record),
              );
            },
          ),
        ),
        if (_importErrors.isNotEmpty) _buildErrorList(theme),
      ],
    );
  }

  /// 导入失败清单（LIB-04 验收要点 ②）。
  ///
  /// 贴在网格下方，因此也要为壳层浮动胶囊留出底部空白（[kShellBottomInset]），
  /// 否则清单末行会被胶囊盖住。
  Widget _buildErrorList(ThemeData theme) {
    return Container(
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8 + kShellBottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '导入失败 ${_importErrors.length} 项',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          ..._importErrors.map((String e) => Text(
                e,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              )),
        ],
      ),
    );
  }
}

/// 顶栏里的「假搜索框」——外观是搜索框，点击进搜索页（照搬 anx-reader）。
///
/// 为什么不做成可就地输入：搜索是**独立页面**（[LibrarySearchPage]），
/// 顶栏只做入口。就地输入会把查询状态绑进书架子树，还要在当前布局里
/// 处理键盘遮挡与结果覆盖层，收益不抵复杂度。
class _BookSearchEntry extends StatelessWidget {
  const _BookSearchEntry({required this.onTap});

  /// 点击回调（打开搜索页）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      // 玻璃库无 Material 祖先（PRD §11.4），而 `InkWell` 的水波纹由最近的
      // Material 绘制，故需自带一层。`MaterialType.transparency` 不绘制底色，
      // 不破坏玻璃观感。
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.search,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '搜索书名、作者',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
