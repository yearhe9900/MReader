// `RD-03` / `RD-04` / `NAV-01`：阅读页——**章节连续滚动**（从第 1 章一路滚到最后一章）。
//
// 设计要点：
//   · **连续滚动**：**全部章节塞进一个 `ListView.builder`**，每章一个 item（一个
//     `Column`：章节标题 + 该章全部段落）。章与章之间不切页，滚到底自然进入下一章；
//   · **正文逐段渲染**：每段各自成 widget（`PERF-03`：**禁 `join('\n\n')` 巨型 `Text`**）；
//   · **当前章 + 章内位置**：每章块挂一个 `GlobalKey`；滚动停止时从「上次索引」向两侧
//     ±4 探测 `findRenderObject`，找出覆盖视口顶部的章块，算出 `chapterIndex` 与
//     `chapterPos = (视口顶 - 章块顶) / 章块高`（即 `RD-04` 的「章索引 + 章内 0.0~1.0」）；
//   · **进度以 `Chapter.href` 为稳定身份**：恢复时先按 href 匹配，匹配不到退回 index 并 clamp；
//   · **恢复（`RD-04`「落点误差 ≤ 1 屏」）**：进度带**设备本地版面快照** `localHint`——
//     版面签名一致（同字号 / 行距 / 视口）→ 用 `initialScrollOffset` **精确落回**；
//     否则 → 按「章索引 + 章内位置」估算 + `addPostFrameCallback` 校正（最多 3 帧、
//     `|delta| ≤ 1px` 即停）；
//   · **进度保存时机 3 个**：滚动停止 / 切章（含目录跳转、恢复落定）/ `dispose()`；
//   · **`RD-03`**：AppBar 标题取 `BookRecord.title`、副标题为「第N章 · X%」，
//     **不出现 implId 等诊断信息**；
//   · **`NAV-01`**：AppBar 目录按钮 → 底部 [TocSheet]，当前章高亮、点击跳章。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider / Freezed）。
// **不引入任何新依赖**（不使用 `scrollable_positioned_list` 等）。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../ui/reader_settings_bar.dart';
import 'control_bar.dart';
import 'progress_store.dart';
import 'reading_progress.dart';
import 'toc_sheet.dart';

/// 探测当前章时，从「上次索引」向两侧各探测多少章。
const int _kProbeRadius = 4;

/// 恢复滚动时的最大校正帧数（`RD-04`：估算后迭代收敛）。
const int _kMaxRestoreFrames = 3;

/// 连续滚动阅读页。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.source,
    required this.record,
    required this.progressStore,
    required this.repository,
  });

  /// 书籍内容来源（`BookSource` 抽象，EPUB / TXT 通用）。
  ///
  /// 生命周期：**由本页持有**，在 [State.dispose] 时释放。
  final BookSource source;

  /// 本书在库记录（标题 / bookId）。
  final BookRecord record;

  /// 阅读进度持久化（`RD-04`）。
  final ProgressStore progressStore;

  /// 书库仓库（进度变化时回写 `BookRecord.lastReadAt` / `readProgress`）。
  final LibraryRepository repository;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  ReaderSettings _settings = const ReaderSettings();

  BookMeta? _meta;
  List<Chapter>? _chapters;

  /// 每章正文（与 `_chapters` 同序；全部就绪后才进入连续滚动）。
  List<ChapterContent>? _contents;

  Object? _error;

  /// 当前章索引。
  int _currentIndex = 0;

  /// 当前章内进度 `0.0 ~ 1.0`（滚动停止时更新；供副标题与保存使用）。
  double _chapterPos = 0.0;

  /// 每章块的 `GlobalKey`（挂在章块 `Column` 上）——用于定位当前章与章内位置。
  final Map<int, GlobalKey> _chapterKeys = <int, GlobalKey>{};

  /// 正文滚动区（视口）的 `GlobalKey`——把章块全局坐标换算到视口坐标系。
  final GlobalKey _viewportKey = GlobalKey();

  /// 整本连续滚动列表的控制器。
  ///
  /// **内容就绪后**才创建：版面签名一致时带 `initialScrollOffset` 精确恢复（`RD-04`）。
  ScrollController? _controller;

  /// 视口尺寸（每次布局记录；用于保存 / 校验版面签名）。
  double _viewportWidth = 0;
  double _viewportHeight = 0;

  /// 设备本地版面快照（来自进度；`null` = 无 / 不可用）。
  LocalLayoutHint? _localHint;

  /// 正在程序化恢复 / 跳转：期间忽略滚动停止的保存，避免把中间值写回磁盘。
  bool _restoring = false;

  /// 恢复 / 跳转目标：章索引 + 章内位置。
  int _restoreIndex = 0;
  double _restorePos = 0.0;

  /// 已消耗的校正帧数。
  int _restoreFrames = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    // 关闭阅读页：先保存进度（不能 await，故 unawaited），再释放书籍资源。
    // 注：`_saveProgress` 在首个 `await` 前同步读取 `_controller.offset`，
    // 故此处「先保存、后 dispose 控制器」是安全的（不会用到已释放的控制器）。
    unawaited(_saveProgress());
    _controller?.dispose();
    unawaited(widget.source.dispose());
    super.dispose();
  }

  /// 取元数据 + 章节表 + **全部章节正文** + 已存进度 → 定位到上次阅读位置。
  ///
  /// 预取全部正文：让首帧的 `maxScrollExtent` 即为最终值，恢复偏移才落在正确处
  /// （否则会在「载入中…」的矮内容上跳转，导致落点漂移）。
  Future<void> _open() async {
    try {
      final BookMeta meta = await widget.source.load();
      final List<Chapter> chapters = await widget.source.chapters();
      final ReadingProgress? progress =
          await widget.progressStore.load(widget.record.bookId);

      final List<ChapterContent> contents = await Future.wait<ChapterContent>(
        <Future<ChapterContent>>[
          for (int i = 0; i < chapters.length; i++) _contentAt(i),
        ],
      );

      if (!mounted) return;

      // 定位：先按 href（稳定身份）匹配，匹配不到退回 index 并 clamp。
      final int index = _resolveIndex(chapters, progress);
      final double pos = progress?.chapterPos ?? 0.0;

      setState(() {
        _meta = meta;
        _chapters = chapters;
        _contents = contents;
        _currentIndex = index;
        _chapterPos = pos;
        _restoreIndex = index;
        _restorePos = pos;
        _localHint = progress?.localHint;
        for (int i = 0; i < chapters.length; i++) {
          _chapterKeys[i] = GlobalKey();
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  /// 解析恢复用的章索引（href 优先，回退 index 并 clamp）。
  int _resolveIndex(List<Chapter> chapters, ReadingProgress? progress) {
    if (progress == null || chapters.isEmpty) return 0;
    final int matched =
        chapters.indexWhere((Chapter c) => c.href == progress.chapterHref);
    if (matched >= 0) return matched;
    return progress.chapterIndex.clamp(0, chapters.length - 1);
  }

  /// 解析第 [index] 章正文；单章失败就地降级为一行提示，不拖垮整本书。
  Future<ChapterContent> _contentAt(int index) async {
    try {
      return await widget.source.content(index);
    } catch (error) {
      return ChapterContent.paragraphs(<String>['[本章解析失败] $error']);
    }
  }

  /// 内容就绪后创建控制器（仅一次）。
  ///
  /// 版面签名一致 → `initialScrollOffset` 精确恢复；否则 → 记录目标，首帧后估算 + 校正。
  void _ensureController() {
    if (_controller != null) {
      return;
    }
    final LocalLayoutHint? hint = _localHint;
    final bool exact = hint != null &&
        _viewportWidth > 0 &&
        _viewportHeight > 0 &&
        hint.matches(
          fontSize: _settings.fontSize,
          lineHeight: _settings.lineHeight,
          viewportWidth: _viewportWidth,
          viewportHeight: _viewportHeight,
        );
    if (exact) {
      _controller = ScrollController(initialScrollOffset: hint.scrollOffset);
      // 首帧后同步一次「当前章 / 章内位置」显示（此时列表已按偏移落位）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _detectCurrentChapter();
        setState(() {});
      });
      return;
    }
    _controller = ScrollController();
    _beginScrollTo(_restoreIndex, _restorePos);
  }

  /// 开始一次程序化「滚动到第 [index] 章的 [pos] 位置」（估算 + 校正）。
  void _beginScrollTo(int index, double pos) {
    _restoreIndex = index.clamp(0, math.max(0, (_chapters?.length ?? 1) - 1));
    _restorePos = pos.clamp(0.0, 1.0);
    _restoreFrames = 0;
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreStep());
  }

  /// 恢复 / 跳转的迭代校正：测量目标落点 → 跳转 → 复核，`|delta| ≤ 1px` 或超帧数即停。
  void _restoreStep() {
    final ScrollController? controller = _controller;
    if (!mounted || controller == null || !controller.hasClients) {
      _restoring = false;
      return;
    }
    final double maxExtent = controller.position.maxScrollExtent;
    final double? target = _chapterPointOffset(_restoreIndex, _restorePos);
    if (target == null) {
      // 目标章尚未布局：按章序比例估算，先把它带进视野，再于后续帧校正。
      final int total = math.max(1, _chapters?.length ?? 1);
      final double estimate =
          maxExtent * ((_restoreIndex + _restorePos) / total);
      controller.jumpTo(estimate.clamp(0.0, maxExtent));
      _restoreFrames++;
    } else {
      final double delta = target - controller.offset;
      if (delta.abs() <= 1.0) {
        _finishRestore();
        return;
      }
      controller.jumpTo(target.clamp(0.0, maxExtent));
      _restoreFrames++;
    }
    if (_restoreFrames < _kMaxRestoreFrames) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreStep());
    } else {
      _finishRestore();
    }
  }

  /// 恢复 / 跳转落定：同步显示、并保存一次（切章后的新位置写回磁盘）。
  void _finishRestore() {
    _restoring = false;
    if (!mounted) return;
    _detectCurrentChapter();
    setState(() {});
    unawaited(_saveProgress());
  }

  /// 计算「把第 [index] 章的 [pos] 位置对齐到视口顶部」所需的**内容绝对偏移**。
  ///
  /// 目标章块尚未布局（懒构建）时返回 `null`。坐标换算：
  /// `内容偏移 = (章块全局顶 - 视口全局顶) + 当前滚动偏移`。
  double? _chapterPointOffset(int index, double pos) {
    final RenderBox? box = _chapterBoxAt(index);
    final RenderBox? viewport = _viewportBox();
    final ScrollController? controller = _controller;
    if (box == null || viewport == null || controller == null) return null;
    final double chapterTopRelative = box.localToGlobal(Offset.zero).dy -
        viewport.localToGlobal(Offset.zero).dy;
    final double chapterTopContent = chapterTopRelative + controller.offset;
    return chapterTopContent + pos * box.size.height;
  }

  /// 探测当前章与章内位置（`RD-04`：章索引 + 章内 0.0~1.0）。
  ///
  /// 从「上次索引」向两侧 ±[_kProbeRadius] 探测：找**覆盖视口顶部**的章块
  /// （即 `relTop ≤ 0` 且 `relTop` 最大者），据此算 `chapterPos`。
  void _detectCurrentChapter() {
    final List<Chapter>? chapters = _chapters;
    final ScrollController? controller = _controller;
    if (chapters == null ||
        chapters.isEmpty ||
        controller == null ||
        !controller.hasClients) {
      return;
    }
    final RenderBox? viewport = _viewportBox();
    if (viewport == null) return;
    final double viewportTop = viewport.localToGlobal(Offset.zero).dy;

    int? foundIndex;
    double foundTop = double.negativeInfinity;
    final int from = math.max(0, _currentIndex - _kProbeRadius);
    final int to = math.min(chapters.length - 1, _currentIndex + _kProbeRadius);
    for (int i = from; i <= to; i++) {
      final RenderBox? box = _chapterBoxAt(i);
      if (box == null) continue;
      final double topRelative =
          box.localToGlobal(Offset.zero).dy - viewportTop;
      if (topRelative <= 0.5 && topRelative > foundTop) {
        foundTop = topRelative;
        foundIndex = i;
      }
    }
    if (foundIndex == null) {
      // 视口顶部落在章与章的间隙（或所有章块都在下方）：保持当前，不动。
      return;
    }
    final RenderBox box = _chapterBoxAt(foundIndex)!;
    final double height = box.size.height;
    final double pos =
        height > 0 ? (-foundTop / height).clamp(0.0, 1.0).toDouble() : 0.0;
    if (foundIndex != _currentIndex || (pos - _chapterPos).abs() > 1e-6) {
      setState(() {
        _currentIndex = foundIndex!;
        _chapterPos = pos;
      });
    }
  }

  /// 章块的 `RenderBox`（未布局 / 不在缓存内时为 `null`）。
  RenderBox? _chapterBoxAt(int index) {
    final BuildContext? ctx = _chapterKeys[index]?.currentContext;
    if (ctx == null) return null;
    final RenderObject? object = ctx.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }

  /// 视口（正文滚动区）的 `RenderBox`。
  RenderBox? _viewportBox() {
    final BuildContext? ctx = _viewportKey.currentContext;
    if (ctx == null) return null;
    final RenderObject? object = ctx.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }

  /// 滚动停止：更新当前章 / 章内位置 + 保存。返回 false 表示不拦截通知。
  bool _onScrollEnd(ScrollEndNotification notification) {
    if (_restoring || _controller == null || !_controller!.hasClients) {
      return false;
    }
    _detectCurrentChapter();
    unawaited(_saveProgress());
    return false;
  }

  /// 跳到第 [index] 章章首（目录点击 / 上下一章按钮）。
  Future<void> _goToChapter(int index) async {
    final List<Chapter>? chapters = _chapters;
    final ScrollController? controller = _controller;
    if (chapters == null ||
        chapters.isEmpty ||
        controller == null ||
        !controller.hasClients) {
      return;
    }
    final int target = index.clamp(0, chapters.length - 1);
    // 保存旧位置（此时 _currentIndex / _chapterPos 仍是旧位置）。
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _currentIndex = target;
      _chapterPos = 0.0;
    });
    _beginScrollTo(target, 0.0);
  }

  /// 保存当前阅读进度（进度文件 + 回写 `BookRecord` 阅读字段）。
  ///
  /// 失败静默（不影响阅读，下次保存重试）。
  Future<void> _saveProgress() async {
    final List<Chapter>? chapters = _chapters;
    final List<ChapterContent>? contents = _contents;
    if (chapters == null || chapters.isEmpty || contents == null) return;
    final int index = _currentIndex.clamp(0, chapters.length - 1);
    final Chapter chapter = chapters[index];
    final int now = DateTime.now().millisecondsSinceEpoch;
    final ReadingProgress progress = ReadingProgress(
      bookId: widget.record.bookId,
      chapterHref: chapter.href,
      chapterIndex: index,
      chapterPos: _chapterPos,
      updatedAt: now,
      localHint: _buildLocalHint(),
    );
    try {
      await widget.progressStore.save(progress);
      await widget.repository.markRead(
        widget.record.bookId,
        lastReadAt: now,
        readProgress: _overallProgress(index, _chapterPos),
      );
    } catch (_) {
      // 保存失败不影响阅读；下次保存重试。
    }
  }

  /// 组装设备本地版面快照（`localHint`）；视口 / 控制器未就绪时返回 `null`。
  LocalLayoutHint? _buildLocalHint() {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return null;
    if (_viewportWidth <= 0 || _viewportHeight <= 0) return null;
    return LocalLayoutHint(
      scrollOffset: controller.offset,
      fontSize: _settings.fontSize,
      lineHeight: _settings.lineHeight,
      viewportWidth: _viewportWidth,
      viewportHeight: _viewportHeight,
    );
  }

  /// 全书进度 `0.0 ~ 1.0`：分母为总章数，末章 `chapterPos == 1.0` 才恰好 100%。
  double _overallProgress(int index, double chapterPos) {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return 0.0;
    return ((index + chapterPos) / chapters.length).clamp(0.0, 1.0).toDouble();
  }

  /// 全书进度百分比（整数，向下取整——避免「差一点」就显示 100%）。
  int get _percent {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return 0;
    return (_overallProgress(_currentIndex, _chapterPos) * 100).floor();
  }

  /// 打开目录弹窗（`NAV-01`）。
  void _openToc() {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => TocSheet(
        chapters: chapters,
        currentIndex: _currentIndex,
        onSelect: (int index) {
          Navigator.of(sheetContext).pop();
          unawaited(_goToChapter(index));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Chapter>? chapters = _chapters;
    final bool ready =
        chapters != null && chapters.isNotEmpty && _contents != null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              _subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '目录',
            icon: const Icon(Icons.list),
            onPressed: ready ? _openToc : null,
          ),
        ],
      ),
      bottomNavigationBar: ready
          ? ReaderControlBar(
              settings: _settings,
              onSettingsChanged: (ReaderSettings value) {
                setState(() => _settings = value);
              },
              chapterNumber: _currentIndex + 1,
              chapterCount: chapters.length,
              percent: _percent,
              canGoPrev: _currentIndex > 0,
              canGoNext: _currentIndex < chapters.length - 1,
              onPrevChapter: () => unawaited(_goToChapter(_currentIndex - 1)),
              onNextChapter: () => unawaited(_goToChapter(_currentIndex + 1)),
            )
          : null,
      body: _buildBody(theme),
    );
  }

  /// AppBar 主标题：**书库记录标题**（`RD-03`，不依赖格式解析）。
  ///
  /// 记录标题意外为空时依次回落到解析出的 `BookMeta.title`、再回落「阅读」。
  String get _title {
    final String recorded = widget.record.title;
    if (recorded.isNotEmpty) return recorded;
    final String parsed = _meta?.title ?? '';
    return parsed.isNotEmpty ? parsed : '阅读';
  }

  /// AppBar 副标题：`第N章 · X%`（`RD-03` 取代 M0 遗留的「N 章 · implId」诊断信息）。
  String get _subtitle {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null) return '载入中…';
    if (chapters.isEmpty) return '无章节';
    return '第${_currentIndex + 1}章 · $_percent%';
  }

  Widget _buildBody(ThemeData theme) {
    final Object? error = _error;
    if (error != null) {
      // 打开 / 解析失败：给出可读提示（格式错误的 `message` 已中文化）。
      final String message = error is MReaderFormatException
          ? error.message
          : '打开失败：$error';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }

    final List<Chapter>? chapters = _chapters;
    if (chapters == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (chapters.isEmpty) {
      // 解析成功但没有任何章节：必须显式告知，否则就是一片空白。
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这本书没有解析出任何可阅读的章节。\n\n'
            '可能原因：源文件没有可识别的章节结构，'
            '或内容为空 / 全部为非文本资源。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    final List<ChapterContent>? contents = _contents;
    if (contents == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final TextStyle bodyStyle = TextStyle(
      fontSize: _settings.fontSize,
      height: _settings.lineHeight,
    );

    // 在布局期拿到视口尺寸（用于版面签名与坐标换算），并据内容就绪创建控制器。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewportWidth = constraints.maxWidth;
        _viewportHeight = constraints.maxHeight;
        _ensureController();
        return SizedBox.expand(
          key: _viewportKey,
          child: NotificationListener<ScrollEndNotification>(
            onNotification: _onScrollEnd,
            child: ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: chapters.length,
              itemBuilder: (BuildContext context, int index) =>
                  _buildChapterBlock(theme, bodyStyle, index),
            ),
          ),
        );
      },
    );
  }

  /// 渲染第 [index] 章块：章节标题 + **逐段**正文（`PERF-03`：不合成巨型 `Text`）。
  ///
  /// 整段 `Column` 挂 [_chapterKeys]，其 `RenderBox` 尺寸即该章内容高度，
  /// 供 [_detectCurrentChapter] / [_chapterPointOffset] 定位。
  Widget _buildChapterBlock(ThemeData theme, TextStyle bodyStyle, int index) {
    final List<Chapter> chapters = _chapters!;
    final List<ChapterContent> contents = _contents!;
    final Chapter chapter = chapters[index];
    final String heading =
        chapter.title.isNotEmpty ? chapter.title : '第 ${index + 1} 节';
    final List<String> paragraphs = contents[index].paragraphList;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        key: _chapterKeys[index],
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            heading,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Divider(height: 1),
          const SizedBox(height: 12),
          for (int p = 0; p < paragraphs.length; p++)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(paragraphs[p], style: bodyStyle),
            ),
        ],
      ),
    );
  }
}
