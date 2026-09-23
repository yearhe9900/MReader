// `RD-03` / `RD-04` / `NAV-01` / `PERF-02` / `PERF-03`：阅读页——**章节连续滚动**
// （从第 1 章一路滚到最后一章），且正文**增量加载**（不一次性解析全书）。
//
// 设计要点：
//   · **连续滚动**：**全部章节塞进一个 `ListView.builder`**，每章一个 item（`Column`：
//     章节标题 + 该章全部段落）。章与章之间不切页，滚到底自然进入下一章；
//   · **正文增量加载（`PERF-02`）**：首帧**只等「恢复目标章 ±1」**（见
//     [ChapterAutoLoader.loadFirstBatch]），其余章节由后台按「离当前章由近及远」
//     逐批补齐；未加载的章渲染**占位块**，高度取「已加载章渲染高度的中位数」以抑制
//     总高跳变；已加载正文由 [ChapterCache] **有界 LRU**（[kMaxLoadedChapters]=30）兜底，
//     超出即淘汰回落占位；
//   · **正文逐段渲染**：每段各自成 widget（`PERF-03`：**禁 `join('\n\n')` 巨型 `Text`**）；
//   · **当前章 + 章内位置**：每章块挂 `GlobalKey`；滚动停止时**全量扫描已构建的
//     章块**（`RC4`：原先「上次索引 ±4」的小窗口在落点偏差一大时会拿**窗口边缘章**
//     顶替真章，于是每次「开→关」都把错误章写回存档、越偏越多——这正是「多次进出后
//     已经偏离原章节太多」），找出**真正覆盖视口顶**的章块，算出 `chapterIndex` 与
//     `chapterPos = (视口顶 - 章块顶) / 章块高`；命中**估算占位高**的章时
//     **不采样** `chapterPos`（`RC3`：分母是估的，会污染跨会话的语义坐标）；
//   · **进度以 `Chapter.href` 为稳定身份**：恢复时先按 href 匹配，匹配不到退回 index 并 clamp；
//   · **恢复（`RD-04`「落点误差 ≤ 1 屏」）**：`localHint.scrollOffset` **只是首帧初始
//     近似**（仅用于减首帧跳动；它是依赖「当时已加载集合」的像素值，加载集合一变就
//     指向别处），落点一律由**语义坐标 `(chapterIndex, chapterPos)` 校正收敛**（`RC2`）：
//     「估算 + `addPostFrameCallback` 校正（≤8 帧、偏移差 ≤1px 停）」；
//   · **进度保存时机**：滚动停止 / 切章（含目录跳转）/ `dispose()`，**但都过 `RC1`
//     写盘闸门**——恢复**未收敛**（校正超帧数中途放弃）、位置**未采样**（占位高 /
//     探不到章）一律**不写盘**，否则误差会被当真值存进 `ReadingProgress` / `localHint`，
//     下一轮开书再放大（误差**复利**回路）。
//   · **`RD-03`**：AppBar 标题取 `BookRecord.title`、副标题为「第N章 · X%」，不出现 implId 诊断；
//   · **`NAV-01`**：AppBar 目录按钮 → 底部 [TocSheet]，当前章高亮、点击跳章；
//   · **`CNT-04c` 链接跳转与返回**：点正文链接（`link_navigator` 解析 href）→
//     章内锚点 / 跨文件跳章（+ 章内锚点），跳前 [ScrollAnchor.capture] 压入
//     [LinkBackStack]；栈非空显示浮动「返回」按钮，弹栈恢复原位置。
//     段落级精确定位：目标段落懒挂 `GlobalKey`，恢复迭代里优先按段落 box
//     对齐视口顶（未构建时回落「章内相对位置」估算）。目标不存在一律静默忽略。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider / Freezed）。
// **不引入任何新依赖**（不使用 `scrollable_positioned_list` 等）。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../typography/anchor.dart';
import '../typography/reader_settings.dart';
import '../typography/text_style_resolver.dart';
import '../typography/typeset.dart';
import '../ui/glass_kit.dart';
import 'chapter_cache.dart';
import 'control_bar.dart';
import 'image_cache.dart';
import 'link_navigator.dart';
import 'progress_store.dart';
import 'reading_progress.dart';
import 'toc_sheet.dart';

/// 恢复滚动时的最大校正帧数（`RD-04`：估算后迭代收敛；`RC2`：≤8 帧）。
const int _kMaxRestoreFrames = 8;

/// 占位块在「尚无任何已加载章可测」时的默认高度（逻辑像素）。
const double _kDefaultChapterHeight = 480;

/// 连续滚动 + 正文增量加载的阅读页。
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
  Object? _error;

  /// 章正文的有界 LRU 缓存（`PERF-02`）。
  final ChapterCache _cache = ChapterCache();

  /// 内嵌图片的有界字节缓存（`CNT-01`）。
  final ImageCacheLRU _imageCache = ImageCacheLRU();

  /// 增量加载驱动器（首帧批次 + 后台补齐）。
  ChapterAutoLoader? _loader;

  /// 首帧批次已就绪（可以进入连续滚动列表）。
  bool _ready = false;

  /// 后台补齐循环是否正在跑（防重复启动）。
  bool _fillRunning = false;

  /// 本页是否已释放（用于停止后台补齐循环、避免用已释放的 source）。
  bool _disposed = false;

  /// 当前章索引。
  int _currentIndex = 0;

  /// 当前章内进度 `0.0 ~ 1.0`（滚动停止时更新；供副标题与保存使用）。
  double _chapterPos = 0.0;

  /// 每章块的 `GlobalKey`——用于定位当前章与章内位置。
  final Map<int, GlobalKey> _chapterKeys = <int, GlobalKey>{};

  /// 正文滚动区（视口）的 `GlobalKey`——把章块全局坐标换算到视口坐标系。
  final GlobalKey _viewportKey = GlobalKey();

  /// 整本连续滚动列表的控制器（内容就绪后创建）。
  ScrollController? _controller;

  /// 视口尺寸（每次布局记录；用于保存 / 校验版面签名）。
  double _viewportWidth = 0;
  double _viewportHeight = 0;

  /// 设备本地版面快照（来自进度；`null` = 无 / 不可用）。
  LocalLayoutHint? _localHint;

  /// 占位块高度估计：已加载章渲染高度的中位数（随加载推进收敛）。
  double _estimatedChapterHeight = _kDefaultChapterHeight;

  /// 正在程序化恢复 / 跳转：期间忽略滚动停止的保存，避免把中间值写回磁盘。
  bool _restoring = false;

  /// 恢复 / 跳转目标：章索引 + 章内位置。
  int _restoreIndex = 0;
  double _restorePos = 0.0;

  /// 已消耗的校正帧数。
  int _restoreFrames = 0;

  /// 链接跳转的目标段落下标（`null` = 按章内相对位置定位；`CNT-04c`）。
  int? _restoreParaIndex;

  /// `RC1` 写盘闸门分量①：当前位置是否**已收敛**。
  ///
  /// 程序化恢复 / 跳转（[_beginScrollTo]）开始时清零；仅当校正真正收敛
  /// （落点偏移差 ≤1px）或**用户主动滚动**后才置回 `true`。
  /// 校正超帧数中途放弃 → 保持 `false`：误差不得当真值写回存档，
  /// 否则下一轮开书把它当真值放大（误差**复利**回路，即「多次进出后
  /// 偏离原章节太多」的来源之一）。
  bool _positionConverged = false;

  /// `RC1` 写盘闸门分量②：当前位置是否**已完整采样**。
  ///
  /// [_detectCurrentChapter] 拿到完整语义坐标 → `true`；命中估算占位高章
  /// （`RC3`）或一个章块都没探到（`RC4`）→ `false`：保持 `_chapterPos`
  /// 原值、且本轮不得写盘。占位章真正加载后由 [_resampleAfterLoad] 重采样置回。
  bool _positionSampled = false;

  /// 目标段落的 `GlobalKey`（懒创建，键 = `'章索引:段落下标'`；`CNT-04c`）。
  ///
  /// 只给「要跳过去的那一段」建 key（一本书几百段全挂 key 太重），
  /// [_buildChapterItem] 渲染时挂到对应段落的 Padding 上，
  /// [_paragraphPointOffset] 据此精确测量段落顶。
  final Map<String, GlobalKey> _paraKeys = <String, GlobalKey>{};

  /// 链接返回栈（`CNT-04c` 验收②）：跳转前压入原位置快照，「返回」按钮弹栈恢复。
  final LinkBackStack _linkStack = LinkBackStack();

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
    _disposed = true;
    unawaited(_saveProgress());
    _imageCache.dispose();
    _controller?.dispose();
    unawaited(widget.source.dispose());
    super.dispose();
  }

  /// 取元数据 + 章节表 + 已存进度 → 定位；**首帧只等「目标章 ±1」**，随后后台补齐。
  Future<void> _open() async {
    try {
      final BookMeta meta = await widget.source.load();
      final List<Chapter> chapters = await widget.source.chapters();
      final ReadingProgress? progress =
          await widget.progressStore.load(widget.record.bookId);
      if (!mounted) return;

      // 定位：先按 href（稳定身份）匹配，匹配不到退回 index 并 clamp。
      final int index = _resolveIndex(chapters, progress);
      final double pos = progress?.chapterPos ?? 0.0;

      setState(() {
        _meta = meta;
        _chapters = chapters;
        _currentIndex = index;
        _chapterPos = pos;
        _restoreIndex = index;
        _restorePos = pos;
        _localHint = progress?.localHint;
        for (int i = 0; i < chapters.length; i++) {
          _chapterKeys[i] = GlobalKey();
        }
      });
      if (chapters.isEmpty) return;

      final ChapterAutoLoader loader = ChapterAutoLoader(
        chapterCount: chapters.length,
        loadContent: _contentAt,
        cache: _cache,
      );
      _loader = loader;

      // 首帧：只等「目标章 ±1」（`PERF-02`：不一次性解析全书）。
      await loader.loadFirstBatch(index);
      if (!mounted || _disposed) return;
      setState(() => _ready = true);
      _scheduleEstimateRefresh();
      _ensureAutoFill();
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

  /// 读取第 [index] 章正文；单章失败就地降级为一行提示，不拖垮整本书。
  Future<ChapterContent> _contentAt(int index) async {
    if (_disposed) return ChapterContent.paragraphs(const <String>[]);
    try {
      final ChapterContent content = await widget.source.content(index);
      return content;
    } catch (error) {
      return ChapterContent.paragraphs(<String>['[本章解析失败] $error']);
    }
  }

  /// 读取包内图片资源（`CNT-01`）：先查字节缓存，未命中再调 `readResource`。
  ///
  /// 返回的字节交给 `Image.memory` 渲染；Flutter 内部缓存解码结果。
  Future<Uint8List?> _resolveImage(String href) async {
    final Uint8List? cached = _imageCache.get(href);
    if (cached != null) return cached;
    if (_disposed) return null;
    final Uint8List? bytes = await widget.source.readResource(href);
    if (bytes != null && !_disposed) {
      _imageCache.put(href, bytes);
    }
    return bytes;
  }

  /// 内容就绪后创建控制器（仅一次）。
  ///
  /// 同版面签名 + 已加载集合覆盖 `[0, target]` 时用 `initialScrollOffset`
  /// 给出**首帧初始近似**（`RC2`：仅减首帧跳动）；无论哪条路径，落点都由
  /// [_beginScrollTo] 按**语义坐标 `(chapterIndex, chapterPos)` 校正收敛**——
  /// `scrollOffset` 依赖「当时已加载集合」（`PERF-02` 增量加载下未载章是估算高），
  /// 加载集合一变同一像素就指向别处，单独照搬不校正即进度漂移（`RC2`）。
  void _ensureController() {
    if (_controller != null) return;
    final LocalLayoutHint? hint = _localHint;
    final bool exact = hint != null &&
        _viewportWidth > 0 &&
        _viewportHeight > 0 &&
        hint.matches(
          fontSize: _settings.fontSize,
          lineHeight: _settings.lineHeight,
          viewportWidth: _viewportWidth,
          viewportHeight: _viewportHeight,
        ) &&
        _cache.coversPrefix(_restoreIndex);
    if (exact) {
      // `RC2`：`scrollOffset` 只作首帧初始近似（减首帧跳动），照搬后
      // **仍要**走语义坐标校正收敛（[_beginScrollTo] 会重置恢复状态并迭代
      // ≤8 帧）——不允许「复制完就返回」。
      _controller = ScrollController(initialScrollOffset: hint.scrollOffset);
      _cache.touch(_restoreIndex);
      _beginScrollTo(_restoreIndex, _restorePos);
      return;
    }
    _controller = ScrollController();
    _beginScrollTo(_restoreIndex, _restorePos);
  }

  /// 开始一次程序化「滚动到第 [index] 章的 [pos] 位置」（估算 + 校正）。默认恢复路径。
  ///
  /// [paraIndex] ≥ 0 时为**段落级目标**（`CNT-04c` 链接跳转）：
  /// [_restoreStep] 优先把该段落顶对齐视口顶，段落未构建时回落 [pos] 估算。
  void _beginScrollTo(int index, double pos, {int paraIndex = -1}) {
    final int count = math.max(1, _chapters?.length ?? 1);
    _restoreIndex = index.clamp(0, count - 1);
    _restorePos = pos.clamp(0.0, 1.0).toDouble();
    _restoreParaIndex = paraIndex >= 0 ? paraIndex : null;
    _restoreFrames = 0;
    _restoring = true;
    _positionConverged = false; // `RC1`：程序化移动开始 → 先关写盘闸门
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreStep());
  }

  /// 恢复 / 跳转的迭代校正：测量目标落点 → 跳转 → 复核，偏移差 ≤1px 或超帧数即停。
  void _restoreStep() {
    final ScrollController? controller = _controller;
    if (!mounted || controller == null || !controller.hasClients) {
      _restoring = false;
      return;
    }
    final double maxExtent = controller.position.maxScrollExtent;
    // 段落级目标优先（CNT-04c）：段落 box 精确对齐视口顶；
    // 未构建（章 item 不在树上）时回落「章内相对位置」估算，后续帧再校正。
    double? target;
    final int? paraIndex = _restoreParaIndex;
    if (paraIndex != null) {
      target = _paragraphPointOffset(_restoreIndex, paraIndex);
    }
    target ??= _chapterPointOffset(_restoreIndex, _restorePos);
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
        _finishRestore(converged: true); // `RC1`：真正收敛 → 闸门开，可写盘
        return;
      }
      controller.jumpTo(target.clamp(0.0, maxExtent));
      _restoreFrames++;
    }
    if (_restoreFrames < _kMaxRestoreFrames) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreStep());
    } else {
      // 帧数耗尽（`RC1`）：按**最后一次**测量判定——最后一跳可能已落准；
      // 仍未落准则视为**未收敛**，[_finishRestore] 不写盘（等待用户滚动或
      // 下次打开重新恢复），绝不把恢复误差当真值写回存档。
      double? lastTarget;
      final int? paraIndex = _restoreParaIndex;
      if (paraIndex != null) {
        lastTarget = _paragraphPointOffset(_restoreIndex, paraIndex);
      }
      lastTarget ??= _chapterPointOffset(_restoreIndex, _restorePos);
      final bool converged =
          lastTarget != null && (lastTarget - controller.offset).abs() <= 1.0;
      _finishRestore(converged: converged);
    }
  }

  /// 恢复 / 跳转落定：同步显示、触发后台补齐、尝试保存一次。
  ///
  /// [converged]：落点是否**真正收敛**（偏移差 ≤1px）。`RC1`：未收敛时
  /// 闸门保持关闭——是否真的落盘由 [_saveProgress] 内的写盘闸门最终裁决，
  /// 未收敛 / 未采样一律不写。
  void _finishRestore({required bool converged}) {
    _restoring = false;
    _positionConverged = converged;
    if (!mounted) return;
    _positionSampled = _detectCurrentChapter();
    _cache.touch(_currentIndex);
    setState(() {});
    _ensureAutoFill();
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

  /// 计算「把第 [chapterIndex] 章第 [paraIndex] 段对齐到视口顶部」所需的
  /// **内容绝对偏移**（`CNT-04c` 段落级精确定位）。
  ///
  /// 段落未构建（章 item 不在树上）时返回 `null`，调用方回落估算路径。
  /// 段落 key 由 [_followLink] 懒创建、[_buildChapterItem] 挂上。
  double? _paragraphPointOffset(int chapterIndex, int paraIndex) {
    final BuildContext? ctx =
        _paraKeys['$chapterIndex:$paraIndex']?.currentContext;
    if (ctx == null) return null;
    final RenderObject? object = ctx.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return null;
    final RenderBox? viewport = _viewportBox();
    final ScrollController? controller = _controller;
    if (viewport == null || controller == null) return null;
    final double paraTopRelative = object.localToGlobal(Offset.zero).dy -
        viewport.localToGlobal(Offset.zero).dy;
    return paraTopRelative + controller.offset;
  }

  /// 探测当前章与章内位置（`RD-04`：章索引 + 章内 0.0~1.0；`RC3` / `RC4`）。
  ///
  /// **全量扫描已构建的章块**，交给纯函数 [detectChapterAt] 判定：
  ///   · 覆盖视口顶的是**真实加载章** → 更新 `_currentIndex` + `_chapterPos`，返回 `true`；
  ///   · 是**估算占位高章**（`RC3`）→ 只更新 `_currentIndex`（章级身份可信），
  ///     保持 `_chapterPos` 原值（分母是估的，采样会污染语义坐标），返回 `false`；
  ///   · 一个章块都没探到（`RC4`）→ 全部保持原值，返回 `false`。
  ///
  /// 返回值 = 是否拿到完整语义坐标（`RC1` 写盘闸门的「已采样」分量）。
  bool _detectCurrentChapter() {
    final List<Chapter>? chapters = _chapters;
    final ScrollController? controller = _controller;
    if (chapters == null ||
        chapters.isEmpty ||
        controller == null ||
        !controller.hasClients) {
      return false;
    }
    final RenderBox? viewport = _viewportBox();
    if (viewport == null) return false;
    final double viewportTop = viewport.localToGlobal(Offset.zero).dy;

    // `RC4`：全量扫描已构建的章块，不再只探「上次索引 ±4」——落点偏差一大，
    // 真章就在小窗口之外，旧逻辑会拿**窗口边缘章**顶替并写回存档，每轮「开→关」
    // 都把错误章写回去，越偏越多（「多次进出后偏离原章节太多」的来源）。
    final List<ChapterBlockSnapshot> blocks = <ChapterBlockSnapshot>[];
    for (int i = 0; i < chapters.length; i++) {
      final RenderBox? box = _chapterBoxAt(i);
      if (box == null) continue; // 未构建（不在视口及缓存区内）。
      blocks.add(
        ChapterBlockSnapshot(
          index: i,
          top: box.localToGlobal(Offset.zero).dy - viewportTop,
          height: box.size.height,
          // 「真实加载」判定用现成的 `ChapterCache.peek`（正文已解析），
          // 不新造谓词；占位块渲染时 `peek` 必为 `null`。
          reallyLoaded: _cache.peek(i) != null,
        ),
      );
    }

    final ({int chapterIndex, double? chapterPos})? hit =
        detectChapterAt(blocks);
    if (hit == null) {
      return false; // `RC4`：探不到 → 不动旧值、不写盘。
    }

    final int index = hit.chapterIndex;
    final double? pos = hit.chapterPos;
    if (pos == null) {
      // `RC3`：占位高章盖住视口顶——章级身份可信，但章内位置不可采样。
      if (index != _currentIndex) {
        setState(() => _currentIndex = index);
      }
      return false;
    }
    if (index != _currentIndex || (pos - _chapterPos).abs() > 1e-6) {
      setState(() {
        _currentIndex = index;
        _chapterPos = pos;
      });
    }
    return true;
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

  /// 滚动停止：更新当前章 / 章内位置 + 触发补齐 + 保存。返回 false 表示不拦截通知。
  bool _onScrollEnd(ScrollEndNotification notification) {
    if (_restoring || _controller == null || !_controller!.hasClients) {
      return false;
    }
    // `RC1`：用户主动滚动 → 当前落点即用户认可的位置（视为已收敛）；
    // 是否可写还取决于本轮是否采到完整语义坐标（未采到则闸门关、不落盘）。
    _positionConverged = true;
    _positionSampled = _detectCurrentChapter();
    _cache.touch(_currentIndex);
    _ensureAutoFill();
    unawaited(_saveProgress());
    return false;
  }

  /// 启动后台补齐循环（已在跑 / 未就绪 / 已释放则忽略）。
  void _ensureAutoFill() {
    if (_fillRunning || !_ready || _disposed) return;
    _fillRunning = true;
    unawaited(_autoFillLoop());
  }

  /// 后台补齐循环：每批 [kLoadBatchSize] 章，逐批 `setState` 合入；
  /// 直到「当前窗口内全部驻留」为止。滚动后由 [_ensureAutoFill] 再触发。
  Future<void> _autoFillLoop() async {
    try {
      while (mounted && !_disposed) {
        final ChapterAutoLoader? loader = _loader;
        if (loader == null) return;
        final bool more = await loader.fillOnce(_currentIndex);
        if (!mounted || _disposed) return;
        if (!more) return;
        setState(() {});
        _scheduleEstimateRefresh();
        _resampleAfterLoad(); // `RC3`：占位章真正加载后重采样 chapterPos
      }
    } finally {
      _fillRunning = false;
    }
  }

  /// 占位高章真正加载后重采样（`RC3`）：用真实高度刷新 `_chapterPos` 并解闸。
  ///
  /// 恢复落定时若覆盖视口顶的还是估算占位章，`chapterPos` 采样被挂起
  /// （`RC1` 写盘闸门关闭）；本批正文合入、真实高度可测后再采一次，
  /// 使语义坐标恢复可信（是否落盘仍由 [_saveProgress] 内的闸门裁决）。
  void _resampleAfterLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _restoring) return;
      if (_detectCurrentChapter()) {
        _positionSampled = true;
      }
    });
  }

  /// 在下一帧测量已加载章的渲染高度，刷新占位高度估计（中位数）。
  void _scheduleEstimateRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshEstimatedHeight());
  }

  /// 用「已加载章渲染高度的中位数」更新占位块高度，抑制总高反复跳变导致的滚动漂移。
  ///
  /// 未加载章的字符数在**不解压该章**的前提下不可知（那正是 `PERF-02` 要避免的），
  /// 故这里用「已加载章实测高度的中位数」作为其高度代理，而非「字符数 × 系数」。
  void _refreshEstimatedHeight() {
    if (!mounted) return;
    final List<double> heights = <double>[];
    for (final int i in _cache.loadedIndices) {
      final RenderBox? box = _chapterBoxAt(i);
      if (box != null && box.size.height > 1) heights.add(box.size.height);
    }
    if (heights.isEmpty) return;
    heights.sort();
    final double median = heights[heights.length ~/ 2];
    if ((median - _estimatedChapterHeight).abs() > 0.5) {
      setState(() => _estimatedChapterHeight = median);
    }
  }

  /// 跳到第 [index] 章章首（目录点击 / 上下一章按钮）。
  Future<void> _goToChapter(int index) async {
    final List<Chapter>? chapters = _chapters;
    final ChapterAutoLoader? loader = _loader;
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
    // 先把目标章（±1）载入，避免跳到占位块后高度回填引起漂移。
    await loader?.loadFirstBatch(target);
    if (!mounted) return;
    _beginScrollTo(target, 0.0);
    _ensureAutoFill();
  }

  /// 正文链接点击入口（`CNT-04c`）。
  ///
  /// 必须是**同步方法 tear-off**（不是闭包）：[InlineParagraph.didUpdateWidget]
  /// 以 `oldWidget.onLinkTap != widget.onLinkTap` 判等决定是否重建 recognizer，
  /// tear-off 跨帧相等，避免每次 build 无谓重建手势。
  void _onLinkTapped(String href) => unawaited(_followLink(href));

  /// 跟随链接 [href]：拆 path/fragment → 找章 → 找段落 → 跳转。
  ///
  /// 任一步未命中（章 -1 / 段落 -1）**静默忽略**（`CNT-04c` 验收③），绝不抛异常。
  Future<void> _followLink(String href) async {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final ({String path, String fragment}) parts = splitLinkHref(href);

    // 1) 定位目标章：path 空（章内 `#id`）→ 当前章；否则按 href 匹配。
    int chapterIndex;
    if (parts.path.isEmpty) {
      chapterIndex = _currentIndex;
    } else {
      chapterIndex = findChapterIndex(chapters, parts.path);
      if (chapterIndex < 0) return; // 目标文件不存在：静默忽略。
    }

    // 2) 定位目标段落：fragment 空（纯跳章）→ 不做段落级定位。
    int paraIndex = -1;
    if (parts.fragment.isNotEmpty) {
      // 跨文件跳转时目标章可能尚未加载：先载入（±1）再扫锚点。
      if (_cache.peek(chapterIndex) == null) {
        await _loader?.loadFirstBatch(chapterIndex);
        if (!mounted) return;
      }
      final ChapterContent? content = _cache.peek(chapterIndex);
      final List<String> paragraphs =
          content?.paragraphList ?? const <String>[];
      paraIndex = findParagraphIndex(paragraphs, parts.fragment);
      if (paraIndex < 0) return; // 目标锚点不存在：静默忽略。
    }

    if (!mounted) return;
    await _jumpToLink(chapterIndex, paraIndex);
  }

  /// 执行链接跳转（`CNT-04c`）：跳前 [ScrollAnchor.capture] 压入 [LinkBackStack]，
  /// 目标段落懒挂 [GlobalKey]，再走「估算 + 校正」恢复路径做段落级对齐。
  Future<void> _jumpToLink(int chapterIndex, int paraIndex) async {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return;
    final ChapterAutoLoader? loader = _loader;

    // 跳转前压入原位置快照（返回按钮弹栈恢复；验收②）。
    final ScrollAnchor? anchor = ScrollAnchor.capture(
      controller: controller,
      viewportBox: _viewportBox(),
      chapterBox: _chapterBoxAt(_currentIndex),
      chapterIndex: _currentIndex,
    );
    if (anchor != null) {
      _linkStack.push(anchor);
      setState(() {}); // 让「返回」按钮出现。
    }

    // 段落级目标：懒创建 key，渲染时挂到对应段落的 Padding 上。
    if (paraIndex >= 0) {
      _paraKeys['$chapterIndex:$paraIndex'] = GlobalKey();
    }
    // 估算落点（段落大致位置按章内比例估）：目标章未布局时先把它带进视野。
    final double roughPos =
        paraIndex >= 0 ? math.min(1.0, (paraIndex + 1) / 12.0) : 0.0;

    // 保存旧位置（此时 _currentIndex / _chapterPos 仍是旧位置）。
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _currentIndex = chapterIndex;
      _chapterPos = roughPos;
    });
    // 先把目标章（±1）载入，避免跳到占位块后高度回填引起漂移。
    await loader?.loadFirstBatch(chapterIndex);
    if (!mounted) return;
    _beginScrollTo(chapterIndex, roughPos,
        paraIndex: paraIndex >= 0 ? paraIndex : -1);
    _ensureAutoFill();
  }

  /// 「返回」按钮（`CNT-04c` 验收②）：弹栈恢复到跳转前的位置。
  ///
  /// 栈空（弹出 `null`）静默返回，不抛异常。
  Future<void> _goBack() async {
    final ScrollAnchor? anchor = _linkStack.pop();
    if (anchor == null) return;
    setState(() {}); // 栈可能已空：让「返回」按钮消失。
    // 保存旧位置（跳转后的位置）。
    await _saveProgress();
    if (!mounted) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final int target = anchor.chapterIndex.clamp(0, chapters.length - 1);
    setState(() {
      _currentIndex = target;
      _chapterPos = anchor.relativePos;
    });
    // 目标章可能已被 LRU 淘汰：先载入（±1）再恢复。
    await _loader?.loadFirstBatch(target);
    if (!mounted) return;
    _beginScrollTo(target, anchor.relativePos);
    _ensureAutoFill();
  }

  /// 保存当前阅读进度（进度文件 + 回写 `BookRecord` 阅读字段）。
  ///
  /// **`RC1` 写盘闸门**：恢复进行中 / 未收敛（校正超帧数放弃）/ 未采样
  /// （占位高章盖顶、探不到章）一律不写——否则误差被当真值存进
  /// `ReadingProgress` / `localHint`，下一轮开书再放大（误差**复利**回路）。
  /// 所有保存路径（滚动停止 / 切章 / `dispose()`）都经此闸门。
  ///
  /// 失败静默（不影响阅读，下次保存重试）。
  Future<void> _saveProgress() async {
    if (_restoring || !_positionConverged || !_positionSampled) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
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
    // `UI-03` 浮层玻璃：玻璃底部弹窗（`M2a-T04`）。
    // `isScrollable: false` —— TocSheet 自带 ListView（Flexible 定高），
    // 库默认的外层 SingleChildScrollView 会吃掉内层手势并撑爆非约束高度。
    GlassOverlays.showSheet<void>(
      context: context,
      isScrollable: false,
      // 库该路径给的是**无界高度**（探针实测 h<=Infinity），Flexible+ListView
      // 视口会炸 → 这里补 maxHeight 约束（60% 屏高，内容矮时仍收缩）。
      // `UI-04`：目录列表行不透明——玻璃 sheet 底上垫 OpaqueContentSurface，
      // 玻璃只留外壳（弹窗背景 / 拖拽把手），列表行下不透出玻璃。
      builder: (BuildContext sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
        ),
        child: OpaqueContentSurface(
          child: TocSheet(
            chapters: chapters,
            currentIndex: _currentIndex,
            onSelect: (int index) {
              Navigator.of(sheetContext).pop();
              unawaited(_goToChapter(index));
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Chapter>? chapters = _chapters;
    final bool ready = _ready && chapters != null && chapters.isNotEmpty;

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
          ?             ReaderControlBar(
              settings: _settings,
              onSettingsChanged: _onSettingsChanged,
              chapterNumber: _currentIndex + 1,
              chapterCount: chapters.length,
              percent: _percent,
              canGoPrev: _currentIndex > 0,
              canGoNext: _currentIndex < chapters.length - 1,
              onPrevChapter: () => unawaited(_goToChapter(_currentIndex - 1)),
              onNextChapter: () => unawaited(_goToChapter(_currentIndex + 1)),
            )
          : null,
      // CNT-04c 验收②：链接返回栈非空时显示「返回」按钮，弹栈恢复原位置；
      // 栈空隐藏（普通 Material，玻璃留给 M2a-T04）。
      floatingActionButton: _linkStack.isNotEmpty
          ? FloatingActionButton(
              onPressed: () => unawaited(_goBack()),
              tooltip: '返回',
              child: const Icon(Icons.arrow_back),
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
    if (!_ready) {
      // 首帧批次尚未就绪（只等「目标章 ±1」，很快）。
      return const Center(child: CircularProgressIndicator());
    }

    final TextStyle bodyStyle = resolveTextStyle(_settings, theme: theme);

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
                  _buildChapterItem(theme, bodyStyle, index),
            ),
          ),
        );
      },
    );
  }

  /// 设置变更（字号 / 行距 / 字体 / 页边距）：先锚定当前位置，再 setState，再校正。
  ///
  /// `TYP-02` 位置锚定：用 [ScrollAnchor] 记录「视口顶在当前章的相对位置」，
  /// 列表重建后用同一章块的新位置算出 delta，`jumpTo` 校正，使该段仍在视口内。
  void _onSettingsChanged(ReaderSettings newSettings) {
    final ScrollAnchor? anchor = ScrollAnchor.capture(
      controller: _controller,
      viewportBox: _viewportBox(),
      chapterBox: _chapterBoxAt(_currentIndex),
      chapterIndex: _currentIndex,
    );

    setState(() => _settings = newSettings);

    // 校正：列表已重建（新布局已生效），在下一帧读新位置并 jumpTo。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final double? correction = anchor?.correction(
        controller: _controller,
        viewportBox: _viewportBox(),
        chapterBox: _chapterBoxAt(_currentIndex),
      );
      if (correction != null) {
        final ScrollController? controller = _controller;
        if (controller != null && controller.hasClients) {
          controller.jumpTo(
            (controller.offset + correction)
                .clamp(0.0, controller.position.maxScrollExtent),
          );
        }
      }
    });
  }

  /// 渲染第 [index] 章：已加载则标题 + **逐段**正文，否则渲染**占位块**。
  ///
  /// 章块挂 [_chapterKeys]（占位块亦挂同一 key），其 `RenderBox` 供
  /// [_detectCurrentChapter] / [_chapterPointOffset] 定位。`PERF-03`：**不合成巨型 `Text`**。
  Widget _buildChapterItem(ThemeData theme, TextStyle bodyStyle, int index) {
    final ChapterContent? content = _cache.peek(index);
    if (content == null) {
      // 未加载：占位块，高度取「已加载章渲染高度中位数」，避免总高反复跳变。
      return Container(
        key: _chapterKeys[index],
        height: _estimatedChapterHeight,
        alignment: Alignment.center,
        child: Text(
          '第 ${index + 1} 章 · 载入中…',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    final List<Chapter> chapters = _chapters!;
    final Chapter chapter = chapters[index];
    final String heading =
        chapter.title.isNotEmpty ? chapter.title : '第 ${index + 1} 节';
    final List<String> paragraphs = content.paragraphList;
    final double marginH = _settings.pageMargin.horizontal;

    return Padding(
      key: _chapterKeys[index],
      padding: EdgeInsets.fromLTRB(marginH, 16, marginH, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // TYP-04：标题居中。
          Text(
            heading,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Divider(height: 1),
          const SizedBox(height: 12),
          for (int p = 0; p < paragraphs.length; p++)
            Padding(
              // CNT-04c：链接跳转的目标段落懒挂 key（仅跳转目标段有 key，
              // 其余段为 null key，不影响渲染），供 _paragraphPointOffset 精确测量。
              key: _paraKeys['$index:$p'],
              padding: const EdgeInsets.only(bottom: 16),
              // TYP-04：首行缩进 + `<b>`/`<i>` 内联样式（白名单）+ `<img>` 图片（CNT-01）。
              // CNT-04c：`onLinkTap` 接链接跳转（同步 tear-off，跨帧相等防 recognizer 重建）。
              child: InlineParagraph(
                text: withFirstLineIndent(paragraphs[p]),
                style: bodyStyle,
                resolveImage: _resolveImage,
                onLinkTap: _onLinkTapped,
              ),
            ),
        ],
      ),
    );
  }
}
