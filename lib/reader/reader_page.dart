// `RD-03` / `RD-04` / `NAV-01` / `PERF-02` / `PERF-03`：阅读页——**章节连续滚动**
// （从第 1 章一路滚到最后一章），且正文**增量加载**（不一次性解析全书）。
//
// 设计要点：
//   · **双模式（T05-c c3 分叉）**：目标章是**文本**（EPUB/TXT）→ `_pagedMode = true`
//     走 [PagedScroller] 页拼接（`PaginationScheduler` 增量分页 + 三章窗口，
//     分页层细节见 `lib/reader/pagination/`）；目标章是**图片页**（CBZ/CBR/PDF）
//     → `_pagedMode = false` 保留下面的旧 `ListView` 路径（异步图片高不进静态
//     布局表，FMT-02 P1 不迁）。分页模式一次落位、无可见中间跳转（不盖遮罩）；
//   · **连续滚动**：**全部章节塞进一个 `ListView.builder`**，每章一个 item（`Column`：
//     章节标题 + 该章全部段落）。章与章之间不切页，滚到底自然进入下一章；
//   · **正文增量加载（`PERF-02`）**：首帧**只等恢复目标章**（±1 邻章预取不阻塞；见
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
//   · **开书可见滚动优化（backlog① 2026-09-23）**：冷启动读中段时 `coversPrefix`
//     恒 false（首帧只载「目标章 ±1」），若从 0 起跳，用户会先看到「前几页」再被
//     拉到「当前页」。两个互补的对策：
//     **A. 回退分支 seed**——同版面签名时用 `hint.scrollOffset` 做首帧初始近似
//     （像素仍只作 seed，落点照旧走语义坐标校正）：目标章大概率首帧即进布局窗口，
//     `_chapterPointOffset` 直接可测，跳过「`maxScrollExtent` 外推估计」的比例估算
//     （ListView 懒构建下该值 = 已布局子项均值 × 剩余项数，探针实测同夹具内
//     26157 ↔ 290816 振荡，估算落点会一路冲到书尾占位区）；
//     **B. 首跳遮罩**——恢复校正全程（含超帧数放弃）盖住正文滚动区
//     （[_restoreMask]），中间跳转一律不可见，[_finishRestore] 统一撤除。
//   · **布局突变语义重锚（修 A，2026-09-23）**：占位→真实合入 / 占位高估计
//     刷新会改 ListView 总高——像素偏移不动即指向别处（「进书从 40 多章跳到
//     300 多章」的漂移源）。突变前 [ScrollAnchor] 记「视口顶在当前章的相对
//     位置」，突变后 [_beginScrollTo] 按语义坐标重锚（等价于 567Reader
//     「已发布页高不可变、增量刷新不动滚动锚点」的保障，见 [_applyLayoutChange]）；
//     **采样置后（修 C）**：重锚收敛后才 [_detectCurrentChapter]，突变中间态
//     不进存档（旧 `_resampleAfterLoad` 合入后立即采样，会把漂移位置当真值）；
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
//   · **`TYP-06` 书签**：当前位置添加书签 / 列表逐条删除，按书持久化
//     （[BookmarkStore]，增删即时落盘）；列表行点击跳回该语义位置
//     （href 优先，回退 index）；
//   · **`CNT-06` 书内搜索**：AppBar 搜索按钮 → [SearchSheet] 全书搜索
//     （[SearchSession] 按源能力分流后台 isolate / 本 isolate 流式，可取消）；
//     点命中 → 章内字符偏移换算段落下标 → [_jumpToLink] 段落级对齐 +
//     关键词高亮（[InlineParagraph.highlightQuery]）；
//   · **`TYP-07` 字体族**：外观面板三选一（系统默认 / 衬线 / 无衬线），
//     **不内嵌字体文件**（`pubspec.yaml` 无 `fonts:` 段）——平台族名 +
//     `reader_fonts.dart` 回退链（Windows 不认通用族名，回退链保中文无豆腐块）；
//     字体族只能由外观面板改：控制条的 `ReaderSettings.copyWith` 会把
//     未传入的 fontFamily 清掉，故 [_onSettingsChanged] 在页面边界续上现值；
//   · **`TYP-08` 亮度与背景色**：应用内亮度遮罩（黑色叠加层，不透明度
//     `1 - brightness`，实时 + 持久化）+ 预设背景色板（白 / 米黄 / 灰 / 纯黑，
//     夜间一律映射暗色——验收③「夜间模式不产生白底」）；
//   · **`TYP-09` 全屏与进度指示**：沉浸全屏（隐藏 AppBar 与底部控制条，
//     右上浮动按钮退出并恢复）+ 细粒度进度指示「第 N/M 章 · X%」——
//     **滚动实时更新**（[_updateLiveProgress] 只写显示字段 `_liveIndex` /
//     `_livePos`，滚动中间态**不进** `_currentIndex` / `_chapterPos`，
//     `RC1` 写盘闸门与「采样置后」原则不动）。
//
// 状态管理：`StatefulWidget` + `setState`（禁 Riverpod / Provider / Freezed）。
// **不引入任何新依赖**（不使用 `scrollable_positioned_list` 等）。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../diagnostics/perf_log.dart';
import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../stats/reading_session.dart';
import '../stats/stats_service.dart';
import '../task/search_session.dart';
import '../typography/anchor.dart';
import '../typography/reader_settings.dart';
import '../typography/text_style_resolver.dart';
import '../typography/typeset.dart';
import '../ui/glass_kit.dart';
import '../ui/search_sheet.dart';
import 'bookmark.dart';
import 'bookmark_sheet.dart';
import 'bookmark_store.dart';
import 'chapter_cache.dart';
import 'control_bar.dart';
import 'image_cache.dart';
import 'image_dimensions.dart';
import 'link_navigator.dart';
import 'pagination/incremental_paginator.dart';
import 'pagination/page_breaker.dart';
import 'pagination/page_paginator.dart';
import 'pagination/page_renderer.dart';
import 'pagination/page_turn_controller.dart';
import 'pagination/paged_scroller.dart';
import 'pagination/paged_turn_body.dart';
import 'pagination/pagination_cache.dart';
import 'pagination/pagination_scheduler.dart';
import 'progress_store.dart';
import 'reader_fonts.dart';
import 'reader_progress_indicator.dart';
import 'reading_appearance_sheet.dart';
import 'reading_background.dart';
import 'reading_prefs.dart';
import 'reading_prefs_store.dart';
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
    this.bookmarkStore,
    this.readingPrefsStore,
    this.statsService,
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

  /// 书签持久化（`TYP-06`）。
  ///
  /// `null` = 尚未接线（main.dart 接线前的降级）：书签功能照常可用，
  /// 但只保留在本会话内存里，不落盘。
  final BookmarkStore? bookmarkStore;

  /// 阅读偏好持久化（`TYP-07~09`：排版 / 亮度 / 背景色）。
  ///
  /// `null` = 尚未接线：偏好本会话内有效，不落盘。
  final ReadingPrefsStore? readingPrefsStore;

  /// 阅读时长采集（`STAT-01`），由书架从组合根透传。
  ///
  /// `null` = 尚未接线：不计时、不写库（与 [bookmarkStore] 同款降级口径）。
  final StatsService? statsService;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  ReaderSettings _settings = const ReaderSettings();

  BookMeta? _meta;
  List<Chapter>? _chapters;

  /// 每章字数权重（`M-PAGE` T03：全书进度**字数加权**；`null` = 尚未取到 /
  /// 该源不支持（PDF/CBZ/CBR）→ 等权退化，与迁移前公式一致）。
  ///
  /// 来源 `BookSource.chapterCharCounts()`，`_open()` 内**不阻塞**首帧异步取
  /// （取到前按等权显示，取到后 `setState` 切换；不改变开书时序）。
  List<int>? _chapterWeights;

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

  /// 本会话最后一次**成功测得**的版面快照（关书时兜底）。
  ///
  /// 关书时 `Scrollable` 子节点**先于本 State** 卸载，控制器已 detach
  /// （`hasClients == false`）→ 现场读不到 `offset`。若无兜底，最后一次保存会把
  /// `localHint` **写成 null**、覆盖掉会话中已存的有效快照，下次开书即失去
  /// 首帧精确落点（`RC2` 的 `initialScrollOffset` 前提被自己抹掉）。
  LocalLayoutHint? _lastLocalHint;

  /// 占位块高度估计：已加载章渲染高度的中位数（随加载推进收敛）。
  double _estimatedChapterHeight = _kDefaultChapterHeight;

  /// **章高模型**（`RD-04` 恢复定位的坐标底座）：已实测过的**真实章**高度（像素）。
  ///
  /// 为什么需要它：`ListView` 懒构建下 `maxScrollExtent` 是「**已构建子项均值 ×
  /// 剩余项数**」的**外推估计**——本工程的布局是「少数真实章（数千 px）+ 大量等高
  /// 占位块（`_estimatedChapterHeight`，初始 480）」的混合体，一旦构建窗口里混进
  /// 真实章，该外推就会在数倍量级间摆动。真机实证（2026-09-28，绍宋 447 章 EPUB）：
  /// 恢复期间 `maxScrollExtent` 在 214009 / 602772 / 1133858 / 706186 之间振荡，
  /// 按比例 (`maxExtent × (index+pos)/total`) 算出的落点来回乱跳，**8 帧全是
  /// `kind=estimate`、`converged=false`**，遮罩白等 1.2s 且最终没落到目标章。
  ///
  /// 模型口径（与真实布局**逐项一致**）：
  ///   · 未构建 / 未加载的章 → 渲染的就是占位块，高度恒为 `_estimatedChapterHeight`；
  ///   · 已加载且已构建的章 → 实测 `RenderBox.size.height`（写回本表）；
  ///   · **只有**「已加载但从未构建过」的章是未知量——首帧只载「目标章 ±1」
  ///     （`kFirstBatchRadius`）时未知量 ≤ 1 章，故模型误差 ≤ 一章高度。
  ///
  /// 维护规则见 [_captureBuiltHeights]：构建中的章被**回落成占位块**（LRU 淘汰后
  /// 重新渲染）时删除旧记忆，避免用「过期的真实高度」当占位高。
  final Map<int, double> _chapterHeights = <int, double>{};

  /// 正在程序化恢复 / 跳转：期间忽略滚动停止的保存，避免把中间值写回磁盘。
  bool _restoring = false;

  /// 开书首跳遮罩（backlog① 方案 B）：校正全程盖住正文滚动区，
  /// 用户看不到「前几页 → 当前页」的中间跳转；[_finishRestore] 统一撤除。
  ///
  /// 仅**开书恢复**（目标非书首）时点亮；目录 / 链接 / 上下章等用户主动跳转
  /// 有明确预期、校正一两帧即完，不遮。
  bool _restoreMask = false;

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
  /// 原值、且本轮不得写盘。占位章真正加载后由 [_applyLayoutChange] 的
  /// 语义重锚收敛（[_finishRestore] 内）重采样置回。
  bool _positionSampled = false;

  /// 目标段落的 `GlobalKey`（懒创建，键 = `'章索引:段落下标'`；`CNT-04c`）。
  ///
  /// 只给「要跳过去的那一段」建 key（一本书几百段全挂 key 太重），
  /// [_buildChapterItem] 渲染时挂到对应段落的 Padding 上，
  /// [_paragraphPointOffset] 据此精确测量段落顶。
  final Map<String, GlobalKey> _paraKeys = <String, GlobalKey>{};

  /// 搜索高亮关键词（`CNT-06` 验收②；空串 = 不高亮）。
  ///
  /// 搜索跳转（[_jumpToSearchHit]）时写入，喂给正文 [InlineParagraph] 的
  /// `highlightQuery` 做命中高亮；下次跳转到新命中时更新。
  String _searchHighlight = '';

  /// 链接返回栈（`CNT-04c` 验收②）：跳转前压入原位置快照，「返回」按钮弹栈恢复。
  final LinkBackStack _linkStack = LinkBackStack();

  /// 应用内亮度 `0.2 ~ 1.0`（`TYP-08`；1.0 = 不加遮罩）。
  double _brightness = ReadingPrefs.maxBrightness;

  /// 预设背景色板（`TYP-08`）。
  ReaderBackground _background = ReaderBackground.white;

  /// 书签列表（添加顺序；`TYP-06`）。
  List<Bookmark> _bookmarks = <Bookmark>[];

  /// 沉浸全屏（`TYP-09`）：`true` = 隐藏 AppBar 与底部控制条。
  bool _fullscreen = false;

  /// 滚动**实时显示**用的章索引 / 章内位置（`TYP-09` 验收②）。
  ///
  /// 只喂进度显示（副标题 / 控制条 / [ReaderProgressIndicator]），
  /// **绝不进存档**：存档只采信滚动停止时的采样（`RC1` 闸门语义不变），
  /// 滚动中间态、占位章探测（`RC3`）都不污染 `_currentIndex` / `_chapterPos`。
  int _liveIndex = 0;
  double _livePos = 0.0;

  /// 当前渲染几何所对应的滚动偏移（帧末 post-frame 采样，即「布局生效时的
  /// `pixels`」）。
  ///
  /// 为什么需要：`ScrollUpdateNotification` 派发于 layout **之前**
  /// （`setPixels` → 派发通知 + `markNeedsLayout`，布局在本帧稍后才跑），
  /// 通知处理器里读 `localToGlobal` 拿到的是**上一帧**几何——「滚动已发生、
  /// 布局未跟上」的滞后会被当成真实位置（实证：拖 150px 后块顶仍报旧值，
  /// 章内位置算出 0，进度不动）。故采样时按
  /// `top - (pixels - _laidOutPixels)` 把滞后补回（见 [_buildBlockSnapshots]）。
  /// `null` = 尚无布局基线，不校正。
  double? _laidOutPixels;

  // ── T05-c c3：分页模式状态（`_pagedMode == false` 时全部闲置）──

  /// 分页模式（c3 分叉）：首帧批次的目标章是**文本**（EPUB/TXT）→ `true`
  /// 走 `PagedScroller` 页拼接；**图片章**（CBZ/CBR/PDF 出图）→ `false`
  /// 保留旧 `ListView` 路径（异步图片高不进静态布局表，FMT-02 P1 不迁）。
  bool _pagedMode = false;

  /// 翻页方式（`M-PAGE T05-d`）：`scroll` = 滚动拼接（[PagedScroller] 可见）；
  /// 其余（slide / cover / none）= 翻页体叠层（[PageTurnBody] 可见，滚动体
  /// 藏进 `Offstage` 但保持挂载——布局 / 采样 / `jumpToCharOffset` 照常有效）。
  ReaderPageMode _pageTurnMode = ReaderPageMode.scroll;

  /// 当前是否处于翻页形态（`scroll` 之外皆是）。
  bool get _pageTurnModeAsTurn => _pageTurnMode != ReaderPageMode.scroll;

  /// 翻页手势活跃中（拖拽或 settle 动画未落定）。
  /// 为 `true` 时：[`_kickReprime`] 让位、父级换视图 / 跳转被抑制，
  /// 防止动画期底下的页表被抽换（`T05-d` 三重闸之一）。
  bool _turnGestureActive = false;

  /// 分页调度器（目标页优先 + ±1 章窗口预分页；文本模式在 `_open` 创建）。
  PaginationScheduler? _scheduler;

  /// 三章窗口 `[current−1, current, current+1]`（连续章下标；滚动中**只增不移**，
  /// trim 只在停稳后执行）。
  List<int> _window = const <int>[];

  /// 窗口章视图（与 [_window] 同序；只在应用时机整批换新，见 [_applyPagedViews]）。
  List<PagedChapterView> _pageViews = const <PagedChapterView>[];

  /// 已应用视图的签名（`_computeSignature` 产物；链式补页后比对判重建）。
  String _viewsSignature = '';

  /// 生效排版参数（与 `_pageViews` 同批换新——config 与视图**原子一致**）。
  PaginationConfig? _pageConfig;

  /// 待换排版参数（字号 / 页边距 / 视口变化后挂起；prime 同步段交换）。
  PaginationConfig? _pendingConfig;

  /// 待落位目标（跳转 / reprime：页表未覆盖时挂起，`stepIdle` 链补完后
  /// 二次落位；`null` = 无挂起）。
  ({int index, int charOffset})? _pendingLand;

  /// 程序化跳转中（`jumpTo` 同步派发的通知基于陈旧布局 → 处理器抑制）。
  bool _inPagedOp = false;

  /// 跳转流进行中（含异步图片 ensure 段；reprime 见此让位防互相踩踏）。
  bool _jumpInFlight = false;

  /// `stepIdle` 空闲帧链是否在跑（postFrame 链，每帧一个切片）。
  bool _pagedFramesRunning = false;

  /// prime 序号（异步 ensure 后校验：更新的 prime 已接管则本次作废）。
  int _primeSeq = 0;

  /// reprime 请求 / 运行标志（config 换新或图片尺寸入表后的重分页）。
  bool _reprimeRequested = false;
  bool _reprimeRunning = false;

  /// 图片尺寸预 ensure 深度（>0 时 `_resolveImage` 的尺寸钩子不触发 reprime：
  /// open 即将吃到新尺寸，无需失效重分页）。
  int _ensuringSizes = 0;

  /// 章标题样式（测量与渲染**同源**——`_headingHeightOf` / `_headingWidget` 共用）。
  TextStyle? _headingTextStyle;

  /// 占位章文字样式（「第N章 · 载入中…」）。
  TextStyle? _placeholderTextStyle;

  /// 分页滚动容器 key（取 [PagedScrollerState] 的布局表 / 采样口）。
  final GlobalKey<PagedScrollerState> _scrollerKey = GlobalKey<PagedScrollerState>();

  /// 停稳流程序号：用户再次滚动即作废在途的 async 停稳序列。
  int _pagedStopSeq = 0;

  /// 阅读会话采集器（`STAT-01`）：进页起表、离页 / 切后台收尾；`null` = 不采集。
  ///
  /// 切后台收尾后置空、回前台重建——两次会话、总时长不重复（验收④）。
  SessionTracker? _tracker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.statsService != null) {
      _tracker = SessionTracker(bookId: widget.record.bookId);
      _noteReading(); // 进页起表（`STAT-01`：进入阅读页开始计时）
    }
    _open();
  }

  @override
  void dispose() {
    // 关闭阅读页：先保存进度（不能 await，故 unawaited），再释放书籍资源。
    // 注：`Scrollable` 子节点**先于本 State** 卸载，进到这里控制器通常已 detach
    // （`hasClients == false`）→ 现场版面快照读不到，`_saveProgress` 会回退
    // [_lastLocalHint]（见 [_buildLocalHint]），**不会用 null 覆盖已存快照**。
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _finishSession(); // 退出阅读页：停止计时并落库（`STAT-01`；写库只在此与切后台）
    unawaited(_saveProgress());
    _imageCache.dispose();
    _controller?.dispose();
    unawaited(widget.source.dispose());
    super.dispose();
  }

  /// 切后台停止计时并落库、回前台另起会话（`STAT-01` ④：两次会话、不重复计时）。
  ///
  /// 只响应 [AppLifecycleState.paused]（真正离开前台）；`inactive` / `hidden`
  /// 是瞬态（通知栏下拉、任务切换预览），不拆会话。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _finishSession();
    } else if (state == AppLifecycleState.resumed &&
        _tracker == null &&
        !_disposed) {
      _tracker = SessionTracker(bookId: widget.record.bookId);
      _noteReading();
    }
  }

  /// 记一次阅读活跃（交互汇聚点统一入口；`STAT-01`）。
  ///
  /// 只采集不写库（验收⑤：翻页期间统计文件 0 写入）；未注入服务 /
  /// 已收尾（切后台后未回前台）/ 已释放时静默跳过。
  void _noteReading() {
    final SessionTracker? tracker = _tracker;
    if (tracker == null || _disposed) return;
    tracker.noteActivity(
      at: DateTime.now().millisecondsSinceEpoch,
      chapterHref: _hrefAt(_currentIndex),
      chapterPos: _chapterPos,
    );
  }

  /// 收尾当前会话并落库（退出阅读页 / 切后台；`STAT-01`）。
  ///
  /// [SessionTracker.finish] 幂等，但本方法**置空**采集器，保证一个活跃段
  /// 只收尾一次；空会话（瞬开瞬关，`duration <= 0`）不落库。
  void _finishSession() {
    final SessionTracker? tracker = _tracker;
    _tracker = null;
    final StatsService? service = widget.statsService;
    if (tracker == null || service == null) return;
    final List<ReadingSession> sessions = tracker.finish(
      at: DateTime.now().millisecondsSinceEpoch,
      chapterHref: _hrefAt(_currentIndex),
      chapterPos: _chapterPos,
    );
    if (sessions.isEmpty) return;
    unawaited(service.ingest(sessions));
  }

  /// 取元数据 + 章节表 + 已存进度 → 定位；**首帧只等「目标章 ±1」**，随后后台补齐。
  Future<void> _open() async {
    final Stopwatch openClock = Stopwatch()..start();
    try {
      final PerfWatch loadWatch = PerfLog.watch('reader.load');
      final BookMeta meta = await widget.source.load();
      loadWatch.done('impl=${widget.source.implId}');
      final PerfWatch chaptersWatch = PerfLog.watch('reader.chapters');
      final List<Chapter> chapters = await widget.source.chapters();
      chaptersWatch.done('count=${chapters.length}');
      final PerfWatch storesWatch = PerfLog.watch('reader.stores');
      final ReadingProgress? progress =
          await widget.progressStore.load(widget.record.bookId);
      // TYP-06~09：书签（按书）与阅读偏好（全局）。store 未接线时为 null / 空，
      // 走内存态默认（构造注释里的降级口径）。
      final List<Bookmark> bookmarks =
          await widget.bookmarkStore?.load(widget.record.bookId) ??
              <Bookmark>[];
      final ReadingPrefs? prefs = await widget.readingPrefsStore?.load();
      storesWatch.done();
      if (!mounted) return;

      // 定位：先按 href（稳定身份）匹配，匹配不到退回 index 并 clamp。
      final int index = _resolveIndex(chapters, progress);
      final double pos = progress?.chapterPos ?? 0.0;

      setState(() {
        if (prefs != null) {
          _settings = prefs.settings;
          _brightness = prefs.brightness;
          _background = prefs.background;
          _pageTurnMode = prefs.pageMode;
        }
        _bookmarks = bookmarks;
        _meta = meta;
        _chapters = chapters;
        _currentIndex = index;
        _chapterPos = pos;
        _liveIndex = index;
        _livePos = pos;
        _restoreIndex = index;
        _restorePos = pos;
        _localHint = progress?.localHint;
        // backlog① 方案 B：恢复目标非书首时，校正全程遮罩（从头开书首帧即到位，不遮）。
        _restoreMask = index != 0 || pos > 0;
        for (int i = 0; i < chapters.length; i++) {
          _chapterKeys[i] = GlobalKey();
        }
      });
      if (chapters.isEmpty) return;
      _noteReading(); // 定位完成：补记一次带真实坐标的活跃（起表在 initState）

      // `M-PAGE` T03：字数权重**不阻塞**首帧——fire-and-forget，取到前全书
      // 进度按等权显示（与旧行为一致），取到后切换为字数加权。
      _loadChapterWeights();

      final ChapterAutoLoader loader = ChapterAutoLoader(
        chapterCount: chapters.length,
        loadContent: _contentAt,
        cache: _cache,
      );
      _loader = loader;

      // 首帧：只等目标章（±1 邻章预取不阻塞；`PERF-02`：不一次性解析全书）。
      final PerfWatch firstWatch = PerfLog.watch('reader.firstBatch');
      await loader.loadFirstBatch(index);
      firstWatch.done('target=$index');
      if (!mounted || _disposed) return;
      // T05-c c3 分叉：首帧批次的目标章是文本 → 分页模式（图片章保留 ListView）。
      final bool paged = _cache.peek(index)?.imagePages == null;
      setState(() {
        _ready = true;
        _pagedMode = paged;
        if (paged) {
          _scheduler = PaginationScheduler();
          _restoreMask = false; // 分页一次落位、无可见中间跳转
        }
      });
      // 开书到「首帧可渲染」的总时长（用户感知的等待上限；恢复校正另计 restore.*）。
      PerfLog.step('reader.ready', openClock.elapsedMilliseconds,
          'target=$index pos=${pos.toStringAsFixed(3)} chapters=${chapters.length} paged=$paged');
      if (!paged) _scheduleEstimateRefresh(); // 估高只服务 ListView
      // **不在此处启动后台补齐**（`PERF-02` 时序修正 2026-09-28）：补齐会逐批
      // 「占位→真实」合入、改动总高，而此刻控制器还没建、首次恢复校正也还没跑
      // （真机日志：本行让 9 批合入抢在 `restore.begin` 之前，全部
      // `layout.reanchor anchored=false` 空重锚，恢复期总高被改）。
      // 补齐统一由 [_finishRestore] 触发——先落定、后补齐。
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
    final PerfWatch watch = PerfLog.watch('reader.content');
    try {
      final ChapterContent content = await widget.source.content(index);
      watch.done('index=$index paras=${content.paragraphList.length}');
      return content;
    } catch (error) {
      watch.done('index=$index FAILED');
      return ChapterContent.paragraphs(<String>['[本章解析失败] $error']);
    }
  }

  /// 读取包内图片资源（`CNT-01`）：先查字节缓存，未命中再调 `readResource`。
  ///
  /// 返回的字节交给 `Image.memory` 渲染；Flutter 内部缓存解码结果。
  Future<Uint8List?> _resolveImage(String href) async {
    final Uint8List? cached = _imageCache.get(href);
    if (cached != null) {
      _noteImageSize(href, cached);
      return cached;
    }
    if (_disposed) return null;
    final Uint8List? bytes = await widget.source.readResource(href);
    if (bytes != null && !_disposed) {
      _imageCache.put(href, bytes);
      _noteImageSize(href, bytes);
    }
    return bytes;
  }

  /// 点页 → 全屏缩放查看（`FMT-02` 验收②「缩放后不糊」，M2b-T02）。
  ///
  /// 「不糊」口径：全屏查看器对**原始字节**解码（不设 `cacheWidth` 降采样），
  /// 捏合缩放矩阵作用在原始分辨率位图上；列表内的 fitWidth 适配只影响显示层。
  /// 单/双页切换（US-12 描述面）不在 FMT-02 验收①②③内，本批未覆盖。
  void _openImageZoom(Uint8List bytes) {
    unawaited(Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => _ImageZoomPage(bytes: bytes),
      ),
    ));
  }

  /// 内容就绪后创建控制器（仅一次）。
  ///
  /// 同版面签名时用 `initialScrollOffset` 给出**首帧初始近似**（`RC2`：仅减首帧
  /// 跳动）；无论哪条路径，落点都由 [_beginScrollTo] 按**语义坐标
  /// `(chapterIndex, chapterPos)` 校正收敛**——`scrollOffset` 依赖「当时已加载
  /// 集合」（`PERF-02` 增量加载下未载章是估算高），加载集合一变同一像素就指向
  /// 别处，单独照搬不校正即进度漂移（`RC2`）。
  ///
  /// 两条分支的差别只在 seed 的「贴合度」（backlog① 方案 A）：
  ///   · **精确分支**（同版面 + `coversPrefix`）：目标前所有章已驻留，像素语义
  ///     完整一致 → `hint.scrollOffset` 即首帧落点，校正 1~2 帧内确认收敛；
  ///   · **回退分支**（其余一切）：同版面时**仍 seed** `hint.scrollOffset`——
  ///     冷启动读中段 `coversPrefix` 恒 false（首帧只载 ±1），若从 0 起跳，
  ///     目标章不在首帧布局窗口里，只能走「`maxScrollExtent` 外推估计」的比例
  ///     估算（探针实测 26157 ↔ 290816 振荡、8 帧不收敛）；seed 让目标章大概率
  ///     首帧即可精确测量，跳过估算直接校正。签名不匹配（字号 / 视口变了）
  ///     则像素语义已失效，seed 无意义 → 从 0 起跳照常估算。
  void _ensureController() {
    if (_controller != null) return;
    if (_pagedMode) {
      // 分页模式：窗口 + 视图先同步建好，seed 落在目标章占位块内；
      // 真实落位由 postFrame 的 [_pagedJumpTo] 一次完成（无遮罩中间跳转）。
      final PaginationConfig? cfg = _pageConfig;
      final List<Chapter>? chapters = _chapters;
      if (cfg == null || chapters == null || chapters.isEmpty) return;
      _window = _computeWindow(_restoreIndex);
      _pageViews = _buildPageViews(_window, cfg);
      _viewsSignature = _computeSignature(_window);
      final int windowPos = math.max(0, _window.indexOf(_restoreIndex));
      final double seed = (windowPos * cfg.pageHeight +
              _restorePos.clamp(0.0, 1.0) * cfg.pageHeight)
          .clamp(0.0, double.infinity);
      _controller = ScrollController(initialScrollOffset: seed);
      PerfLog.mark('reader.seed', 'branch=paged seed=${seed.toStringAsFixed(1)}');
      final int restoreIndex = _restoreIndex;
      final double restorePos = _restorePos;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _disposed) return;
        unawaited(_pagedJumpTo(restoreIndex, pos: restorePos, saveOld: false));
      });
      return;
    }
    final LocalLayoutHint? hint = _localHint;
    final bool sameLayout = hint != null &&
        _viewportWidth > 0 &&
        _viewportHeight > 0 &&
        hint.matches(
          fontSize: _settings.fontSize,
          lineHeight: _settings.lineHeight,
          viewportWidth: _viewportWidth,
          viewportHeight: _viewportHeight,
        );
    if (sameLayout && _cache.coversPrefix(_restoreIndex)) {
      // `RC2`：`scrollOffset` 只作首帧初始近似（减首帧跳动），照搬后
      // **仍要**走语义坐标校正收敛（[_beginScrollTo] 会重置恢复状态并迭代
      // ≤8 帧）——不允许「复制完就返回」。
      _controller = ScrollController(initialScrollOffset: hint.scrollOffset);
      _cache.touch(_restoreIndex);
      PerfLog.mark('reader.seed',
          'branch=exact seed=${hint.scrollOffset.toStringAsFixed(1)}');
      _beginScrollTo(_restoreIndex, _restorePos);
      return;
    }
    // 回退分支（backlog① 方案 A）：同版面时 seed，否则 0。
    final double seed = sameLayout ? hint.scrollOffset : 0.0;
    _controller = ScrollController(initialScrollOffset: seed);
    PerfLog.mark('reader.seed',
        'branch=${sameLayout ? 'fallback-seed' : 'zero'} seed=${seed.toStringAsFixed(1)}');
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
    PerfLog.mark('restore.begin',
        'index=$_restoreIndex pos=${_restorePos.toStringAsFixed(3)} para=$paraIndex');
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreStep());
  }

  /// 恢复 / 跳转的迭代校正：测量目标落点 → 跳转 → 复核，偏移差 ≤1px 或超帧数即停。
  void _restoreStep() {
    final ScrollController? controller = _controller;
    if (!mounted || controller == null || !controller.hasClients) {
      // 统一收口（backlog① 方案 B）：异常路径也要经 [_finishRestore] 撤遮罩，
      // 否则遮罩永久留在屏幕上；`converged: false` → `RC1` 闸门照旧关闭不写盘。
      _finishRestore(converged: false);
      return;
    }
    final double maxExtent = controller.position.maxScrollExtent;
    // 章高模型保鲜：把本帧已构建真实章的实测高度写回（seek 与重锚共用底座）。
    _captureBuiltHeights();
    // 段落级目标优先（CNT-04c）：段落 box 精确对齐视口顶；
    // 未构建（章 item 不在树上）时回落「章内相对位置」估算，后续帧再校正。
    double? target;
    final int? paraIndex = _restoreParaIndex;
    if (paraIndex != null) {
      target = _paragraphPointOffset(_restoreIndex, paraIndex);
    }
    target ??= _chapterPointOffset(_restoreIndex, _restorePos);
    if (target == null) {
      // 目标章尚未布局：用**章高模型**把它的章首带进布局窗口。
      //
      // 这里**刻意不用** `maxScrollExtent × (index + pos) / total` 的比例外推：
      // 懒构建下 `maxScrollExtent` 是 sliver 按「已构建子项均值 × 剩余项数」的
      // 外推值，在「少数真实章 + 大量等高占位块」的混合布局里会在数倍量级间摆动
      // → 估算落点来回乱跳（真机 8 帧全 estimate、`converged=false`，见
      // [_chapterHeights] 注释）。模型只依赖「占位高已知 + 实测高已记忆」两件事，
      // 误差上界 ≈ 目标章附近**未知高度**的章数（首帧批次下 ≤1 章），因此每次
      // seek 都是**朝目标单向逼近**，通常 1~3 帧即测到 box 转入精确校正。
      //
      // 只 seek **章首**（不含 `_restorePos`）：落到章内即可测到 box，`pos` 部分
      // 留给下一帧的实测校正 `_chapterPointOffset(index, pos)`（否则把章首顶到
      // 视口上方过远、超出构建缓存区时 box 反而建不出来）。
      final double seek = _chapterTopModel(_restoreIndex);
      PerfLog.mark('restore.step',
          'frame=${_restoreFrames + 1} kind=model jumpTo=${seek.clamp(0.0, maxExtent).toStringAsFixed(0)} maxExtent=${maxExtent.toStringAsFixed(0)}');
      controller.jumpTo(seek.clamp(0.0, maxExtent));
      _restoreFrames++;
    } else {
      final double delta = target - controller.offset;
      PerfLog.mark('restore.step',
          'frame=${_restoreFrames + 1} kind=${paraIndex != null ? 'para' : 'chapter'} delta=${delta.toStringAsFixed(1)} target=${target.toStringAsFixed(0)} offset=${controller.offset.toStringAsFixed(0)}');
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

  /// 恢复 / 跳转落定：同步显示、撤首跳遮罩、触发后台补齐、尝试保存一次。
  ///
  /// [converged]：落点是否**真正收敛**（偏移差 ≤1px）。`RC1`：未收敛时
  /// 闸门保持关闭——是否真的落盘由 [_saveProgress] 内的写盘闸门最终裁决，
  /// 未收敛 / 未采样一律不写。
  void _finishRestore({required bool converged}) {
    _restoring = false;
    _restoreMask = false; // backlog① 方案 B：校正结束（含放弃）即撤遮罩
    _positionConverged = converged;
    if (!mounted) return;
    _positionSampled = _detectCurrentChapter();
    PerfLog.mark('restore.end',
        'frames=$_restoreFrames converged=$converged sampled=$_positionSampled');
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

    // `RC4`：全量扫描已构建的章块（见 [_buildBlockSnapshots]），交给纯函数判定。
    final ({int chapterIndex, double? chapterPos})? hit =
        detectChapterAt(_buildBlockSnapshots(viewport));
    if (hit == null) {
      return false; // `RC4`：探不到 → 不动旧值、不写盘。
    }

    final int index = hit.chapterIndex;
    final double? pos = hit.chapterPos;
    if (pos == null) {
      // `RC3`：占位高章盖住视口顶——章级身份可信，但章内位置不可采样。
      if (index != _currentIndex || index != _liveIndex) {
        setState(() {
          _currentIndex = index;
          _liveIndex = index;
        });
      }
      return false;
    }
    if (index != _currentIndex ||
        (pos - _chapterPos).abs() > 1e-6 ||
        index != _liveIndex ||
        (pos - _livePos).abs() > 1e-6) {
      setState(() {
        _currentIndex = index;
        _chapterPos = pos;
        // 显示值与语义值在同一采样点对齐（`TYP-09` 的实时显示见
        // [_updateLiveProgress]，滚动停止后两者必然收敛到同一检测结果）。
        _liveIndex = index;
        _livePos = pos;
      });
    }
    return true;
  }

  /// 构建**全部已布局章块**的几何 / 加载态快照（[detectChapterAt] 的输入）。
  ///
  /// `RC4`：全量扫描已构建的章块，不再只探「上次索引 ±4」——落点偏差一大，
  /// 真章就在小窗口之外，旧逻辑会拿**窗口边缘章**顶替并写回存档，每轮「开→关」
  /// 都把错误章写回去，越偏越多（「多次进出后偏离原章节太多」的来源）。
  ///
  /// 返回的 `top` 已按 [_laidOutPixels] **补回布局滞后**（滚动通知派发于
  /// layout 之前，此刻几何还是上一帧的）。
  List<ChapterBlockSnapshot> _buildBlockSnapshots(RenderBox viewport) {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null) return const <ChapterBlockSnapshot>[];
    // 布局滞后量 = 当前滚动偏移 − 几何所对应的滚动偏移（基线）。
    // 向下滚（pixels 增）时内容上移、真实 top 更小，故校正为 `top - lag`。
    final ScrollController? controller = _controller;
    final double? baseline = _laidOutPixels;
    final double lag = (controller != null &&
            controller.hasClients &&
            baseline != null)
        ? controller.position.pixels - baseline
        : 0.0;
    // 帧末（布局已生效）记下几何所对应的 `pixels`，作下次采样的基线。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ScrollController? c = _controller;
      if (c != null && c.hasClients) {
        _laidOutPixels = c.position.pixels;
      }
    });
    final double viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final List<ChapterBlockSnapshot> blocks = <ChapterBlockSnapshot>[];
    for (int i = 0; i < chapters.length; i++) {
      final RenderBox? box = _chapterBoxAt(i);
      if (box == null) continue; // 未构建（不在视口及缓存区内）。
      blocks.add(
        ChapterBlockSnapshot(
          index: i,
          top: box.localToGlobal(Offset.zero).dy - viewportTop - lag,
          height: box.size.height,
          // 「真实加载」判定用现成的 `ChapterCache.peek`（正文已解析），
          // 不新造谓词；占位块渲染时 `peek` 必为 `null`。
          reallyLoaded: _cache.peek(i) != null,
        ),
      );
    }
    return blocks;
  }

  /// 滚动过程中的**显示级**位置采样（`TYP-09` 验收②「进度随滚动实时更新」）。
  ///
  /// 与 [_detectCurrentChapter] 同一判定（[detectChapterAt]），但**只写显示字段**
  /// `_liveIndex` / `_livePos`：滚动中间态不进 `_currentIndex` / `_chapterPos`，
  /// `RC1` 写盘闸门与「采样置后」原则一点不动。命中占位高章时
  /// （`detectChapterAt` 返回 `chapterPos == null`）章级身份照常刷新、
  /// 章内位置保持原显示值。
  void _updateLiveProgress() {
    final ScrollController? controller = _controller;
    if (_chapters == null ||
        _chapters!.isEmpty ||
        controller == null ||
        !controller.hasClients) {
      return;
    }
    final RenderBox? viewport = _viewportBox();
    if (viewport == null) return;
    final ({int chapterIndex, double? chapterPos})? hit =
        detectChapterAt(_buildBlockSnapshots(viewport));
    if (hit == null) return;
    final int index = hit.chapterIndex;
    final double pos = hit.chapterPos ?? _livePos;
    if (index != _liveIndex || (pos - _livePos).abs() > 1e-6) {
      setState(() {
        _liveIndex = index;
        _livePos = pos;
      });
    }
  }

  /// 滚动中实时刷新进度显示（返回 false 表示不拦截通知）。
  bool _onScrollUpdate(ScrollUpdateNotification notification) {
    _updateLiveProgress();
    return false;
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

  /// 章高模型的单章高度：**实测值优先，未测到按占位高**（占位块的真实高度就是它）。
  double _chapterHeightAt(int index) =>
      _chapterHeights[index] ?? _estimatedChapterHeight;

  /// 章高模型算出的「第 [index] 章块顶的内容绝对偏移」= 上方各章高度之和。
  ///
  /// 不再用 `maxScrollExtent` 做比例外推（理由见 [_chapterHeights] 字段注释与
  /// [_restoreStep] 的 seek 分支）。O(章数) 纯算术，恢复期每帧一次，可忽略。
  double _chapterTopModel(int index) {
    double sum = 0;
    for (int i = 0; i < index; i++) {
      sum += _chapterHeightAt(i);
    }
    return sum;
  }

  /// 把当前**已构建真实章块**的实测高度写回章高模型（恢复/重锚前调用）。
  ///
  /// · 未构建的章：**保持既有记忆**（它仍是「最近一次实测的真实高」的唯一来源）；
  /// · 构建中且已回落成**占位块**（LRU 淘汰）的章：删除记忆——此后它的真实高度
  ///   就是 `_estimatedChapterHeight`，留着旧值会让模型与实际布局不一致；
  /// · 构建中的真实章：写入实测高度（模型因此逐帧收敛到真实布局）。
  void _captureBuiltHeights() {
    final int count = _chapters?.length ?? 0;
    for (int i = 0; i < count; i++) {
      final RenderBox? box = _chapterBoxAt(i);
      if (box == null) continue; // 未构建：保持既有记忆
      if (_cache.peek(i) == null) {
        _chapterHeights.remove(i); // 已回落占位块 → 旧记忆作废
        continue;
      }
      final double height = box.size.height;
      if (height > 1) _chapterHeights[i] = height;
    }
  }

  /// 滚动停止：更新当前章 / 章内位置 + 触发补齐 + 保存。返回 false 表示不拦截通知。
  bool _onScrollEnd(ScrollEndNotification notification) {
    if (_restoring || _controller == null || !_controller!.hasClients) {
      return false;
    }
    // `RC1`：用户主动滚动 → 当前落点即用户认可的位置（视为已收敛）；
    // 是否可写还取决于本轮是否采到完整语义坐标（未采到则闸门关、不落盘）。
    _positionConverged = true;
    final PerfWatch watch = PerfLog.watch('scroll.detect');
    _positionSampled = _detectCurrentChapter();
    watch.done('index=$_currentIndex sampled=$_positionSampled');
    _cache.touch(_currentIndex);
    _ensureAutoFill();
    _noteReading(); // 滚动停稳 = 交互（`STAT-01`）
    unawaited(_saveProgress());
    return false;
  }

  /// 启动后台补齐循环（已在跑 / 未就绪 / 已释放则忽略）。
  void _ensureAutoFill() {
    if (_fillRunning || !_ready || _disposed) return;
    _fillRunning = true;
    unawaited(_autoFillLoop());
  }

  /// 后台补齐循环：每批 [kLoadBatchSize] 章，逐批合入（经 [_applyLayoutChange]
  /// 做语义重锚）；直到「当前窗口内全部驻留」为止。滚动后由 [_ensureAutoFill] 再触发。
  Future<void> _autoFillLoop() async {
    int batches = 0;
    final Stopwatch clock = Stopwatch()..start();
    try {
      while (mounted && !_disposed) {
        final ChapterAutoLoader? loader = _loader;
        if (loader == null) return;
        final PerfWatch batchWatch = PerfLog.watch('autofill.batch');
        final bool more = await loader.fillOnce(_currentIndex);
        batches++;
        batchWatch.done('current=$_currentIndex batch=$batches more=$more');
        if (!mounted || _disposed) return;
        if (_pagedMode) {
          // 分页模式：内容补齐后登记窗口未分页章 + 推进空闲分页帧；
          // 不走 `_applyLayoutChange` / 估高刷新（那是 ListView 的总高重锚）。
          _registerWindowUnpaginated();
          _startPagedFrames();
          if (!more) {
            PerfLog.mark('autofill.end',
                'batches=$batches ms=${clock.elapsedMilliseconds}');
            return;
          }
          continue;
        }
        if (!more) {
          PerfLog.mark('autofill.end',
              'batches=$batches ms=${clock.elapsedMilliseconds}');
          return;
        }
        // 修 A：占位→真实合入会改总高，重锚后再采样（修 C，随收敛走）。
        _applyLayoutChange(() => setState(() {}), reason: 'autofill-merge');
        _scheduleEstimateRefresh();
      }
    } finally {
      _fillRunning = false;
    }
  }

  /// 布局突变（占位→真实合入 / 占位高估计刷新）后的**语义重锚**（修 A）。
  ///
  /// `PERF-02` 增量加载下「占位块 ↔ 真实章」互换会改 ListView 总高——像素
  /// 偏移不动、同一 offset 就指向别处：上方占位补齐后缩短，视口内容整体后移
  /// （实机「进书从 40 多章跳到 300 多章」即此漂移在长书上的放大形态）。
  /// 567Reader 的等价保障是「已发布排版页高度不可变、增量刷新不动滚动锚点」；
  /// 连续滚动模型高度必变，故在突变前用 [ScrollAnchor] 记「视口顶在当前章的
  /// 相对位置」，突变后按**语义坐标** [_beginScrollTo] 重锚。
  ///
  /// 为何走「估算 + 校正收敛」而非 [_onSettingsChanged] 式单跳 `correction`：
  /// 单跳校正在「跳转尚未渲染就因再次突变而再次捕获」时，会把多个 delta
  /// **叠加**（过校正）；[_beginScrollTo] 每帧重测目标、按语义坐标收敛，
  /// 天然吸收后续突变（重锚迭代中再突变 → [_restoreStep] 下一帧重测即纠偏）。
  ///
  /// 采样（修 C）天然置后：[_finishRestore] 在收敛后才 [_detectCurrentChapter]，
  /// 不会把突变中间态写进 `_currentIndex` / `_chapterPos`（旧 `_resampleAfterLoad`
  /// 在 `setState` 后立即采样，会把漂移位置当真值采走入档）。
  ///
  /// 不重锚的三种情形（保持原状，交给既有采样点兜底）：
  ///   · 恢复 / 重锚迭代进行中（[_restoring]）——在跑的迭代每帧重测目标，
  ///     自会吸收本次突变（也防叠加过校正）；
  ///   · 用户手势滚动中（`isScrolling`）——`jumpTo` 会掐掉用户的甩动；
  ///   · 锚点抓取失败（章块未布局 / 控制器未挂）——无可锚语义。
  void _applyLayoutChange(VoidCallback mutate, {String reason = 'merge'}) {
    final ScrollController? controller = _controller;
    final bool canAnchor = !_restoring &&
        controller != null &&
        controller.hasClients &&
        !controller.position.isScrollingNotifier.value;
    final ScrollAnchor? anchor = canAnchor
        ? ScrollAnchor.capture(
            controller: controller,
            viewportBox: _viewportBox(),
            chapterBox: _chapterBoxAt(_currentIndex),
            chapterIndex: _currentIndex,
          )
        : null;
    PerfLog.mark(
        'layout.reanchor', 'reason=$reason anchored=${anchor != null}');
    mutate();
    if (anchor != null) {
      _beginScrollTo(anchor.chapterIndex, anchor.relativePos);
    }
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
    // 章高模型保鲜（与占位高估计同源：都建立在「已构建真实章」之上）。
    _captureBuiltHeights();
    final List<double> heights = <double>[];
    for (final int i in _cache.loadedIndices) {
      final RenderBox? box = _chapterBoxAt(i);
      if (box != null && box.size.height > 1) heights.add(box.size.height);
    }
    if (heights.isEmpty) return;
    heights.sort();
    final double median = heights[heights.length ~/ 2];
    if ((median - _estimatedChapterHeight).abs() > 0.5) {
      // 修 A：占位高是**所有**未加载章的渲染高度——一改就是全局高度突变，
      // 与合入同样走语义重锚（`_applyLayoutChange`）。
      PerfLog.mark('layout.height',
          'old=${_estimatedChapterHeight.toStringAsFixed(1)} new=${median.toStringAsFixed(1)}');
      _applyLayoutChange(
          () => setState(() => _estimatedChapterHeight = median),
          reason: 'height-refresh');
    }
  }

  // ── T05-c c3：分页模式方法组（`_pagedMode == false` 时全部不被调用）──

  /// 分页滚动容器状态（取布局表 / 采样口；未挂载为 null）。
  PagedScrollerState? get _scroller => _scrollerKey.currentState;

  /// 三章窗口 `[index−1, index, index+1]`（连续章下标，clamp 书边界）。
  List<int> _computeWindow(int index) {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return const <int>[];
    final int center = index.clamp(0, chapters.length - 1);
    final int lo = math.max(0, center - 1);
    final int hi = math.min(chapters.length - 1, center + 1);
    return <int>[for (int i = lo; i <= hi; i++) i];
  }

  /// 第 [index] 章在 [_pageConfig] 下的分页结果：进行中任务的快照优先，
  /// 否则查缓存（只读 peek，不触 LRU 序）。
  PaginatedChapter? _paginatedOf(int index) {
    final PaginationScheduler? scheduler = _scheduler;
    final PaginationConfig? cfg = _pageConfig;
    final List<Chapter>? chapters = _chapters;
    if (scheduler == null || cfg == null || chapters == null) return null;
    if (index < 0 || index >= chapters.length) return null;
    final String href = chapters[index].href;
    final IncrementalPaginator? active = scheduler.active;
    if (active != null && active.href == href && active.config == cfg) {
      return active.snapshot();
    }
    return scheduler.cache.peek(href, cfg);
  }

  /// 章标题文本（渲染与测量同源；空标题回落「第 N 节」，同 ListView 口径）。
  String _headingTitle(int index) {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || index < 0 || index >= chapters.length) return '';
    final String title = chapters[index].title;
    return title.isNotEmpty ? title : '第 ${index + 1} 节';
  }

  /// 章标题占高（测量与渲染**同源**）：TextPainter 行高 + 19（6+1+12 留白链）。
  double _headingHeightOf(int index, PaginationConfig cfg) {
    if (_headingTextStyle == null) return 0;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: _headingTitle(index), style: _headingTextStyle),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(cfg.textScaleFactor),
    )..layout(maxWidth: cfg.pageWidth);
    final double height = painter.height;
    painter.dispose();
    return height + 19;
  }

  /// 章标题 widget（与 [_headingHeightOf] 同一文本 / 样式 / 缩放）。
  Widget _headingWidget(int index, PaginationConfig cfg) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          _headingTitle(index),
          textAlign: TextAlign.center,
          textScaler: TextScaler.linear(cfg.textScaleFactor),
          style: _headingTextStyle,
        ),
        const SizedBox(height: 6),
        const Divider(height: 1),
        const SizedBox(height: 12),
      ],
    );
  }

  /// 构建窗口章视图：正文 + 分页结果都有 → 真视图；否则占位章
  /// （headingHeight = 整页高，seed / 估算落位正好落在占位块内）。
  List<PagedChapterView> _buildPageViews(
      List<int> window, PaginationConfig cfg) {
    final List<Chapter>? chapters = _chapters;
    final List<PagedChapterView> out = <PagedChapterView>[];
    if (chapters == null) return out;
    for (final int i in window) {
      if (i < 0 || i >= chapters.length) continue;
      final ChapterContent? content = _cache.peek(i);
      final PaginatedChapter? pag = _paginatedOf(i);
      if (content != null &&
          content.imagePages == null &&
          content.paragraphList.isNotEmpty &&
          pag != null) {
        out.add(PagedChapterView(
          href: chapters[i].href,
          paragraphs: content.paragraphList,
          lines: pag.lines,
          pages: pag.pages,
          headingHeight: _headingHeightOf(i, cfg),
          heading: _headingWidget(i, cfg),
        ));
      } else {
        out.add(PagedChapterView(
          href: chapters[i].href,
          paragraphs: const <String>[],
          lines: const <MeasuredLine>[],
          pages: const <PageSlice>[],
          headingHeight: cfg.pageHeight,
          heading: Center(
            child: Text(
              '第 ${i + 1} 章 · 载入中…',
              style: _placeholderTextStyle,
            ),
          ),
        ));
      }
    }
    return out;
  }

  /// 窗口签名（逐章「页数 + 完整标记」）：链式补页 / 占位→真 视图切换的判据。
  String _computeSignature(List<int> window) {
    final StringBuffer sb = StringBuffer();
    for (int k = 0; k < window.length; k++) {
      if (k > 0) sb.write('|');
      final PaginatedChapter? pag = _paginatedOf(window[k]);
      sb.write('${window[k]}:'
          '${pag == null ? 'ph' : '${pag.pages.length}${pag.complete ? 'c' : 'p'}'}');
    }
    return sb.toString();
  }

  /// 收新排版参数（LayoutBuilder 每帧调用）：首次直接生效；变更挂
  /// [_pendingConfig] 并 [_requestReprime]（build 期不 prime，帧末再跑）。
  void _syncPageConfig(PaginationConfig cfg) {
    if (!_pagedMode) return;
    final PaginationConfig? current = _pageConfig;
    if (current == cfg) return;
    if (current == null) {
      _pageConfig = cfg; // 首次：[_ensureController] 随后消费（build 内直接赋字段）
      return;
    }
    _pendingConfig = cfg;
    _requestReprime();
  }

  /// 请求 reprime（config 换新 / 图片尺寸入表）：build 期挂帧末，
  /// 跳转中 / 已在跑则只置标志等收尾重入。
  void _requestReprime() {
    _reprimeRequested = true;
    if (_reprimeRunning || _jumpInFlight) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _kickReprime());
    } else {
      _kickReprime();
    }
  }

  /// 真正启动 reprime：滚动中推迟（jumpTo 会掐断甩动），等 ScrollEnd 停稳
  /// 流程⑦再 kick；翻页手势中让位（`T05-d` 三重闸——动画期不许抽换页表）。
  void _kickReprime() {
    if (!mounted || _disposed || !_pagedMode) return;
    if (_reprimeRunning || _jumpInFlight) return;
    if (_turnGestureActive) return;
    final ScrollController? controller = _controller;
    if (controller != null &&
        controller.hasClients &&
        controller.position.isScrollingNotifier.value) {
      return;
    }
    _runReprime();
  }

  /// reprime 循环：对齐现场身份 → [_primeOpenSync] 按当前语义坐标重分页。
  /// 内容未就绪返回 false 时保留待办（下次 kick 续跑）。
  void _runReprime() {
    if (_reprimeRunning || !mounted || _disposed) return;
    _reprimeRunning = true;
    try {
      while (_reprimeRequested) {
        _reprimeRequested = false;
        if (_jumpInFlight) {
          _reprimeRequested = true; // 跳转流收尾的 finally 会再 kick
          return;
        }
        final PaginationScheduler? scheduler = _scheduler;
        if (scheduler == null || _pageConfig == null) continue;
        if (_pendingLand == null) _syncPagedIdentity();
        if (!_primeOpenSync(charOffset: _currentCharOffset())) {
          _reprimeRequested = true; // 内容未就绪：保留待办
          return;
        }
      }
    } finally {
      _reprimeRunning = false;
    }
  }

  /// 当前语义字符偏移：挂起落位优先 → 现场采样（href 匹配）→ 存档比例换算。
  ///
  /// 翻页模式（`T05-d`）：滚动体藏在 Offstage 里、拖拽期停在旧位——采样
  /// 不作数，直接按 `_chapterPos × total` 换算（与写入口同源无二义）。
  int _currentCharOffset() {
    final ({int index, int charOffset})? pending = _pendingLand;
    if (pending != null) return pending.charOffset;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return 0;
    final int index = _currentIndex.clamp(0, chapters.length - 1);
    final PaginatedChapter? pag = _paginatedOf(index);
    if (_pageTurnModeAsTurn) {
      final int total = pag?.totalChars ??
          PagePaginator.charCountOf(
              _cache.peek(index)?.paragraphList ?? const <String>[]);
      if (total <= 0) return 0;
      return (_chapterPos.clamp(0.0, 1.0) * total).round().clamp(0, total);
    }
    final PagedScrollerState? scroller = _scroller;
    if (scroller != null && pag != null) {
      final ScrollSample? sample = scroller.sampleNow();
      if (sample != null && sample.href == chapters[index].href) {
        return sample.charOffset.clamp(0, pag.totalChars);
      }
    }
    final int total = pag?.totalChars ??
        PagePaginator.charCountOf(
            _cache.peek(index)?.paragraphList ?? const <String>[]);
    if (total <= 0) return 0;
    return (_chapterPos.clamp(0.0, 1.0) * total).round().clamp(0, total);
  }

  /// prime 同步段（**不得在 build 期调用**）：消费 [_pendingConfig] →
  /// [PaginationScheduler.open]（首屏突发 + 登记 ±1）→ 预计算视图与布局 →
  /// 精确落位（offsetFor）或估算挂 [_pendingLand]。返回 `true` = 已精确落位。
  bool _primeOpenSync({required int charOffset}) {
    if (!mounted || _disposed || !_pagedMode) return false;
    final PaginationScheduler? scheduler = _scheduler;
    final PaginationConfig? pendingCfg = _pendingConfig;
    final PaginationConfig? currentCfg = _pageConfig;
    if (scheduler == null || (pendingCfg == null && currentCfg == null)) {
      return false;
    }
    if (_window.isEmpty) {
      _window = _computeWindow(_currentIndex);
      if (_window.isEmpty) return false;
    }
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return false;
    final int index = _currentIndex.clamp(0, chapters.length - 1);
    final ChapterContent? content = _cache.peek(index);
    if (content == null ||
        content.imagePages != null ||
        content.paragraphList.isEmpty) {
      return false; // 内容未就绪：调用方保留待办
    }
    final PaginationConfig cfg = pendingCfg ?? currentCfg!;
    final bool cfgChanged = currentCfg != cfg;
    _pendingConfig = null;
    _pageConfig = cfg; // 消费待换参数（视图与 config 同批换新）

    final String href = chapters[index].href;
    final ChapterContent? prev =
        index > 0 ? _cache.peek(index - 1) : null;
    final ChapterContent? next =
        index + 1 < chapters.length ? _cache.peek(index + 1) : null;
    final bool prevOk = prev != null &&
        prev.imagePages == null &&
        prev.paragraphList.isNotEmpty;
    final bool nextOk = next != null &&
        next.imagePages == null &&
        next.paragraphList.isNotEmpty;
    scheduler.open(
      href: href,
      paragraphs: content.paragraphList,
      config: cfg,
      targetCharOffset: charOffset,
      headingHeight: _headingHeightOf(index, cfg),
      prevHref: prevOk ? chapters[index - 1].href : null,
      prevParagraphs: prevOk ? prev.paragraphList : null,
      prevHeadingHeight: prevOk ? _headingHeightOf(index - 1, cfg) : 0,
      nextHref: nextOk ? chapters[index + 1].href : null,
      nextParagraphs: nextOk ? next.paragraphList : null,
      nextHeadingHeight: nextOk ? _headingHeightOf(index + 1, cfg) : 0,
    );

    List<PagedChapterView> views = _buildPageViews(_window, cfg);
    String sig = _computeSignature(_window);
    PagedLayout layout =
        PagedLayout.build(views, paragraphSpacing: cfg.paragraphSpacing);
    double? landAt =
        PagedScrollerState.offsetFor(layout, views, href, charOffset);
    final bool landed = landAt != null;
    if (landAt == null) {
      // 页表未覆盖目标（占位/部分页）：按窗口位置 + 章内比例估算落位，
      // 挂 pending 等空闲帧补完后二次精确落位（`RC1`：期间不写盘）。
      final int total = PagePaginator.charCountOf(content.paragraphList);
      final double frac = total > 0
          ? (charOffset / total).clamp(0.0, 1.0)
          : _chapterPos.clamp(0.0, 1.0);
      final int windowPos = _window.indexOf(index);
      landAt = ((windowPos < 0 ? 0 : windowPos) * cfg.pageHeight +
              frac * cfg.pageHeight)
          .clamp(0.0, double.infinity);
      _pendingLand = (index: index, charOffset: charOffset);
      _positionConverged = false;
      _positionSampled = false;
      PerfLog.mark('paged.estimate',
          'index=$index char=$charOffset off=${landAt.toStringAsFixed(0)}');
    } else {
      _pendingLand = null;
      _positionConverged = true; // `RC1`：一次精确落位即收敛
      PerfLog.mark('paged.prime',
          'index=$index char=$charOffset off=${landAt.toStringAsFixed(0)}');
    }
    // 锚点可达性：窗口截断出「伪书尾」时锚点超滚动域 → 必越界 clamp 掉进
    // 上一章（身份漂移）。不足则扩窗补足（当前章在窗口中部，append 不改
    // windowPos / 落点）。
    final repaired = _repairReachable(
        views: views,
        layout: layout,
        sig: sig,
        anchor: landAt,
        cfg: cfg);
    views = repaired.views;
    layout = repaired.layout;
    sig = repaired.sig;
    if (cfgChanged || sig != _viewsSignature) {
      _applyPagedViews(views, cfg, sig, offset: landAt);
    } else {
      _jumpPaged(landAt);
    }
    return landed;
  }

  /// 程序化跳转包装：期间派发的通知基于陈旧布局，处理器抑制。
  void _pagedOp(VoidCallback op) {
    _inPagedOp = true;
    try {
      op();
    } finally {
      _inPagedOp = false;
    }
  }

  /// 单跳到 [target]：|Δ|<0.01 跳过；在旧上界内立即跳（pre-jump），
  /// 超出则帧末补跳（setState 后新布局已建，接受 1 帧滑移——
  /// 同帧先跳会被旧 `maxScrollExtent` 弹簧拉回）。
  void _jumpPaged(double target) {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return;
    final double pixels = controller.position.pixels;
    if ((target - pixels).abs() < 0.01) return;
    if (target >= 0 && target <= controller.position.maxScrollExtent) {
      _pagedOp(() => controller.jumpTo(target));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final double clamped = target
          .clamp(0.0, controller.position.maxScrollExtent);
      if ((clamped - controller.position.pixels).abs() < 0.01) return;
      _pagedOp(() => controller.jumpTo(clamped));
    });
  }

  /// 窗口可达性修补：锚点 [anchor] 所需滚动域（`anchor + 视口高`）超出窗口
  /// 布局总高时，顺次 append 后续章重建，直到可达或书尾。三章窗口会把书
  /// 截断出「伪书尾」——不补则越界 clamp 掉进上一章，采样身份漂到上一章尾
  /// （进度回退）；真书尾仍不足则原样返回诚实 clamp（与滚动到底同语义）。
  ({List<PagedChapterView> views, PagedLayout layout, String sig})
      _repairReachable({
    required List<PagedChapterView> views,
    required PagedLayout layout,
    required String sig,
    required double anchor,
    required PaginationConfig cfg,
  }) {
    final List<Chapter>? chapters = _chapters;
    final double vh = _viewportHeight;
    if (chapters == null || vh <= 0 || anchor < 0) {
      return (views: views, layout: layout, sig: sig);
    }
    final int before = _window.length;
    while (layout.totalHeight < anchor + vh &&
        _window.last < chapters.length - 1) {
      _window.add(_window.last + 1);
      views = _buildPageViews(_window, cfg);
      layout =
          PagedLayout.build(views, paragraphSpacing: cfg.paragraphSpacing);
      sig = _computeSignature(_window);
    }
    if (_window.length != before) {
      PerfLog.mark('paged.extend',
          'window=$_window total=${layout.totalHeight.toStringAsFixed(0)} '
          'anchor=${anchor.toStringAsFixed(0)}');
    }
    return (views: views, layout: layout, sig: sig);
  }

  /// 应用新视图（**唯一**换 [_pageViews] 的入口）：先按「当前章章顶差」
  /// pre-jump 重锚（offset 给定时直接跳该值），再 setState 换新。
  /// delta==0（尾部追加 / 当前章自身补页）零扰动不跳。
  void _applyPagedViews(
    List<PagedChapterView> views,
    PaginationConfig cfg,
    String sig, {
    double? offset,
  }) {
    if (!mounted) return;
    double? target = offset;
    if (target == null) {
      final PagedScrollerState? scroller = _scroller;
      final List<Chapter>? chapters = _chapters;
      if (scroller != null &&
          chapters != null &&
          scroller.scrollController.hasClients) {
        final List<PagedChapterView> oldViews = scroller.widget.chapters;
        final int tNew = views.indexWhere(
            (PagedChapterView v) => v.href == _hrefAt(_currentIndex));
        final int tOld = oldViews.indexWhere(
            (PagedChapterView v) => v.href == _hrefAt(_currentIndex));
        if (tNew >= 0 && tOld >= 0) {
          final double delta = PagedLayout.build(views,
                      paragraphSpacing: cfg.paragraphSpacing)
                  .chapterTops[tNew] -
              scroller.layout.chapterTops[tOld];
          if (delta.abs() >= 0.01) {
            target = scroller.scrollController.position.pixels + delta;
          }
        }
      }
    }
    if (target != null) _jumpPaged(target); // pre-jump 在 setState 前
    setState(() {
      _pageViews = views;
      _viewsSignature = sig;
      _pageConfig = cfg;
    });
  }

  /// 章下标的 href（越界返回 ''）。
  String _hrefAt(int index) {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || index < 0 || index >= chapters.length) return '';
    return chapters[index].href;
  }

  /// 按当前 [_window] 重建视图并按需换新；[tryPendingLand] 时尝试把
  /// 挂起落位收敛到精确偏移（命中 → 清 pending + postFrame 采样）。
  void _syncPagedViews({bool tryPendingLand = false}) {
    if (!mounted || _disposed || !_pagedMode) return;
    final PaginationConfig? cfg = _pageConfig;
    if (cfg == null || _window.isEmpty) return;
    List<PagedChapterView> views = _buildPageViews(_window, cfg);
    String sig = _computeSignature(_window);
    double? landOffset;
    if (tryPendingLand) {
      final ({int index, int charOffset})? pending = _pendingLand;
      if (pending != null && pending.index < (_chapters?.length ?? 0)) {
        final PagedLayout layout = PagedLayout.build(
            views, paragraphSpacing: cfg.paragraphSpacing);
        landOffset = PagedScrollerState.offsetFor(
            layout, views, _hrefAt(pending.index), pending.charOffset);
        if (landOffset != null) {
          _pendingLand = null;
          _positionConverged = true;
          PerfLog.mark('paged.land',
              'index=${pending.index} off=${landOffset.toStringAsFixed(0)}');
        }
      }
    }
    if (sig == _viewsSignature && landOffset == null) return;
    // 可达性修补：章页表收缩（占位→真）或停稳 trim 后，现场 offset 可能
    // 超出新滚动域 → 不补则被 clamp 掉进上一章（身份漂移）。
    double? anchor = landOffset;
    if (anchor == null) {
      final PagedScrollerState? scroller = _scroller;
      if (scroller != null && scroller.scrollController.hasClients) {
        anchor = scroller.scrollController.offset;
      }
    }
    if (anchor != null) {
      final repaired = _repairReachable(
          views: views,
          layout: PagedLayout.build(views,
              paragraphSpacing: cfg.paragraphSpacing),
          sig: sig,
          anchor: anchor,
          cfg: cfg);
      views = repaired.views;
      sig = repaired.sig;
    }
    _applyPagedViews(views, cfg, sig, offset: landOffset);
    if (landOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _samplePagedNow();
      });
    }
  }

  /// 停稳期把窗口收敛回 `[_currentIndex±1]`（滚动中只增不移，trim 只在此做）。
  /// 收敛带可达性护栏：尾部章不足一屏时直接 trim 会让现场 offset 越界被
  /// clamp 掉进上一章（身份漂移）——补尾章到放得下为止（或到书尾）。
  void _maintainWindowIdle() {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final List<int> desired = _computeWindow(_currentIndex);
    final PaginationConfig? cfg = _pageConfig;
    final PagedScrollerState? scroller = _scroller;
    // 尾部补章按「现场 offset + 视口」探可达性；翻页模式滚动体停在旧位
    // （探针输入不作数），只收 ±1 章窗口、不做尾探——真滚动时
    // `_onPagedScrollUpdate` 会按需尾追加。
    if (cfg != null &&
        scroller != null &&
        scroller.scrollController.hasClients &&
        _viewportHeight > 0 &&
        !_pageTurnModeAsTurn) {
      final double offset = scroller.scrollController.offset;
      while (desired.last < chapters.length - 1) {
        final PagedLayout probe = PagedLayout.build(
            _buildPageViews(desired, cfg),
            paragraphSpacing: cfg.paragraphSpacing);
        if (probe.totalHeight >= offset + _viewportHeight) break;
        desired.add(desired.last + 1);
      }
    }
    bool same = desired.length == _window.length;
    if (same) {
      for (int i = 0; i < desired.length; i++) {
        if (desired[i] != _window[i]) {
          same = false;
          break;
        }
      }
    }
    if (same) return;
    PerfLog.mark('paged.window', 'was=$_window now=$desired');
    _window = desired;
  }

  /// 确保窗口图片尺寸入表后按现场坐标重 prime（停稳流程⑤）。
  Future<void> _ensurePagedActive() async {
    await _ensureWindowImageSizes(_window);
    if (!mounted || _disposed || _jumpInFlight) return;
    _primeOpenSync(charOffset: _currentCharOffset());
  }

  /// 把窗口内「有正文但未分页」的章登记进预分页队列（prev 槽位复用，
  /// 队列按 href 去重；当前章 / 已有定稿的自动跳过）。
  void _registerWindowUnpaginated() {
    final PaginationScheduler? scheduler = _scheduler;
    final PaginationConfig? cfg = _pageConfig;
    if (scheduler == null || cfg == null) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null) return;
    for (final int i in _window) {
      if (i < 0 || i >= chapters.length) continue;
      final ChapterContent? content = _cache.peek(i);
      if (content == null ||
          content.imagePages != null ||
          content.paragraphList.isEmpty) {
        continue;
      }
      scheduler.setWindow(
        prevHref: chapters[i].href,
        prevParagraphs: content.paragraphList,
        prevHeadingHeight: _headingHeightOf(i, cfg),
      );
    }
  }

  /// 启动空闲分页帧链（postFrame 逐帧切片；防重入）。
  void _startPagedFrames() {
    if (_pagedFramesRunning || !mounted || _disposed) return;
    if (_scheduler == null) return;
    _pagedFramesRunning = true;
    WidgetsBinding.instance.addPostFrameCallback(_stepPagedIdle);
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 一个空闲分页切片：stepIdle → 合视图（含 pending 收敛）→ 有活续链。
  void _stepPagedIdle(Duration _) {
    _pagedFramesRunning = false;
    if (!mounted || _disposed || !_pagedMode) return;
    final PaginationScheduler? scheduler = _scheduler;
    if (scheduler == null) return;
    final bool more = scheduler.stepIdle();
    _syncPagedViews(tryPendingLand: true);
    if (more && mounted && !_disposed) {
      _pagedFramesRunning = true;
      WidgetsBinding.instance.addPostFrameCallback(_stepPagedIdle);
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  /// 滚动中（分页）：维护三章窗口（尾追加零扰动；首部仅**手指拖拽**时
  /// prepend + delta 跳，ballistic 等停稳）+ 实时显示采样。
  bool _onPagedScrollUpdate(ScrollUpdateNotification notification) {
    if (notification.depth != 0) return false;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      return false; // didUpdateWidget 收缩跳派发于 build 期：禁 setState
    }
    if (!_pagedMode || _inPagedOp || _jumpInFlight) return false;
    final PagedScrollerState? scroller = _scroller;
    if (scroller == null || !scroller.scrollController.hasClients) {
      return false;
    }
    // 用户接管：挂起落位作废 + 在途停稳序列作废。
    _pendingLand = null;
    _pagedStopSeq++;

    final PagedLayout layout = scroller.layout;
    final int gi = layout.chapterAtOrBefore(notification.metrics.pixels);
    final List<Chapter>? chapters = _chapters;
    if (gi >= 0 &&
        gi < scroller.widget.chapters.length &&
        chapters != null &&
        chapters.isNotEmpty) {
      final String href = scroller.widget.chapters[gi].href;
      int book = -1;
      if (gi < _window.length && _hrefAt(_window[gi]) == href) {
        book = _window[gi]; // 快路径：窗口与视图同构
      } else {
        book = chapters.indexWhere((Chapter c) => c.href == href);
      }
      if (book >= 0) {
        if (gi == scroller.widget.chapters.length - 1 &&
            book + 1 < chapters.length &&
            !_window.contains(book + 1)) {
          _window.add(book + 1); // 尾部追加：当前章顶不动，零扰动
          _syncPagedViews();
        } else if (gi == 0 &&
            book - 1 >= 0 &&
            !_window.contains(book - 1) &&
            notification.dragDetails != null) {
          // 首部插入会改布局 → 需 delta 跳；ballistic 无手指时不做，等停稳。
          _window.insert(0, book - 1);
          _syncPagedViews();
        }
        final ScrollSample? sample = scroller.sampleNow();
        if (sample != null) {
          final PaginatedChapter? pag = _paginatedOf(book);
          final int total = pag?.totalChars ?? 0;
          final double pos = total > 0
              ? (sample.charOffset / total).clamp(0.0, 1.0)
              : _livePos;
          if (book != _liveIndex || (pos - _livePos).abs() > 1e-6) {
            setState(() {
              _liveIndex = book;
              _livePos = pos;
            });
          }
        }
      }
    }
    return false;
  }

  /// 停稳通知（分页）：进入 9 步停稳流程。返回 false 不拦截。
  bool _onPagedScrollEnd(ScrollEndNotification notification) {
    if (notification.depth != 0) return false;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      return false;
    }
    if (!_pagedMode || _inPagedOp || _jumpInFlight) return false;
    if (!mounted || _disposed) return false;
    unawaited(_onPagedStopped());
    return false;
  }

  /// 停稳流程（序号防重入；任一 await 后序号变了即作废——用户又滚动 /
  /// 新跳转接管）：①同步身份 ②开闸 ③载正文 ④收敛窗口 ⑤图片尺寸+prime
  /// ⑥合视图收敛落位 ⑦排空 reprime ⑧触发补齐 ⑨postFrame 采样+落盘。
  Future<void> _onPagedStopped() async {
    final int seq = ++_pagedStopSeq;
    if (!mounted || _disposed || !_pagedMode) return;
    _syncPagedIdentity(); // ① 不保存（采样置后原则）
    if (!mounted || seq != _pagedStopSeq) return;
    _positionConverged = true; // ② `RC1`：停稳即用户认可的位置
    _noteReading(); // 分页停稳 = 交互（翻页提交与拖拽停手都汇到这）
    await _loader?.loadFirstBatch(_currentIndex); // ③ 邻章内容兜底
    if (!mounted || _disposed || seq != _pagedStopSeq) return;
    _maintainWindowIdle(); // ④ trim 只在停稳期
    await _ensurePagedActive(); // ⑤
    if (!mounted || _disposed || seq != _pagedStopSeq) return;
    _syncPagedViews(tryPendingLand: true); // ⑥
    if (_reprimeRequested && !_jumpInFlight) _kickReprime(); // ⑦
    _ensureAutoFill(); // ⑧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ⑨ 序号校验：期间又滚动则本次采样作废
      if (!mounted || _disposed || seq != _pagedStopSeq) return;
      _samplePagedNow();
      unawaited(_saveProgress());
    });
  }

  /// 停手 200ms 防抖采样回调（PagedScroller 计时器 → 事件相位）。
  void _onPagedDebounced(ScrollSample sample) {
    if (!mounted || _disposed || !_pagedMode || _inPagedOp || _jumpInFlight) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      return;
    }
    // 翻页模式：同 [_samplePagedNow] 口径——语义直写不回采。
    if (_pageTurnModeAsTurn) {
      _samplePagedNow();
      return;
    }
    _applyPagedSample(sample, save: true);
  }

  /// 同步语义身份（不落盘；停稳流程① / reprime 前对齐现场用）。
  ///
  /// 翻页模式（`T05-d`）：语义坐标由 commit / 跳转**直写**为真值，滚动体
  /// 采样（拖拽期停在旧位）不作数 → 整体跳过。
  void _syncPagedIdentity() {
    if (_pageTurnModeAsTurn) return;
    _applyPagedSample(_scroller?.sampleNow(), save: false);
  }

  /// 立即采样并落盘（postFrame 落位确认后 / 停稳⑨）。
  ///
  /// 翻页模式：不读滚动体采样（防陈旧样本回写覆盖直写语义），只做
  /// 「确认已采样 + 落盘」——`_chapterPos` 已是真值。
  void _samplePagedNow() {
    if (_pageTurnModeAsTurn) {
      if (_pendingLand != null) return;
      _positionSampled = true;
      unawaited(_saveProgress());
      return;
    }
    _applyPagedSample(_scroller?.sampleNow(), save: true);
  }

  /// 把采样写进语义坐标：有页采样 → 章 + 章内位置（RC1 闸门内可写）；
  /// 无页采样（占位章盖顶）→ 只更章身份、`_positionSampled = false`（RC3）。
  /// [_pendingLand] 挂起期间整体忽略（估算位置不可信）。
  void _applyPagedSample(ScrollSample? sample, {required bool save}) {
    if (!mounted || _disposed || !_pagedMode) return;
    if (_pendingLand != null) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;

    if (sample == null) {
      final PagedScrollerState? scroller = _scroller;
      if (scroller == null || !scroller.scrollController.hasClients) return;
      final PagedLayout layout = scroller.layout;
      int c = layout.chapterAtOrBefore(scroller.scrollController.offset);
      if (c < 0) c = 0;
      if (c >= _window.length) c = _window.length - 1;
      final int book = _window[c].clamp(0, chapters.length - 1);
      _positionSampled = false; // `RC3`：章内位置不可信，不写盘
      if (book != _currentIndex || book != _liveIndex) {
        setState(() {
          _currentIndex = book;
          _liveIndex = book;
        });
      }
      return;
    }

    int book = -1;
    for (final int i in _window) {
      if (i >= 0 && i < chapters.length && chapters[i].href == sample.href) {
        book = i;
        break;
      }
    }
    if (book < 0) return;
    final int total = _paginatedOf(book)?.totalChars ?? 0;
    final double pos =
        total > 0 ? (sample.charOffset / total).clamp(0.0, 1.0) : _chapterPos;
    final bool changed =
        book != _currentIndex || (pos - _chapterPos).abs() > 1e-9;
    if (changed) {
      setState(() {
        _currentIndex = book;
        _chapterPos = pos;
        _liveIndex = book;
        _livePos = pos;
      });
    }
    _positionSampled = true;
    if (save) unawaited(_saveProgress());
  }

  /// 分页跳转流（目录 / 链接 / 书签 / 恢复统一入口）：序号防并发
  /// （快速连点时旧流在每个 await 后自废）→ 载正文 → 预 ensure 图片尺寸
  /// （异步段全在 UI 变更前）→ setState 换窗口 → prime 同步落位 →
  /// 帧链补页 + 补齐 → 精确落位则 postFrame 采样。
  Future<void> _pagedJumpTo(
    int index, {
    double pos = 0.0,
    int? charOffset,
    bool saveOld = true,
  }) async {
    if (!mounted || _disposed || !_pagedMode) return;
    final List<Chapter>? chapters = _chapters;
    final ChapterAutoLoader? loader = _loader;
    if (chapters == null || chapters.isEmpty || loader == null) return;
    final int target = index.clamp(0, chapters.length - 1);

    final int seq = ++_primeSeq;
    _jumpInFlight = true;
    try {
      if (saveOld) await _saveProgress(); // 此刻身份仍是旧位置
      if (!mounted || seq != _primeSeq) return;
      await loader.loadFirstBatch(target);
      if (!mounted || seq != _primeSeq) return;
      final ChapterContent? content = _cache.peek(target);
      if (content == null ||
          content.imagePages != null ||
          content.paragraphList.isEmpty) {
        return;
      }
      final int total = PagePaginator.charCountOf(content.paragraphList);
      final int offset = (charOffset ??
              (pos.clamp(0.0, 1.0) * total).round())
          .clamp(0, total);
      final List<int> win = _computeWindow(target);
      await _ensureWindowImageSizes(win);
      if (!mounted || seq != _primeSeq) return;
      final double ratio = total > 0 ? offset / total : 0.0;
      setState(() {
        _currentIndex = target;
        _chapterPos = ratio;
        _liveIndex = target;
        _livePos = ratio;
        _restoreIndex = target;
        _restorePos = ratio;
        _window = win;
        _pendingLand = null;
        _positionConverged = false; // `RC1`：落位确认前不写盘
        _positionSampled = false;
      });
      final bool landed = _primeOpenSync(charOffset: offset);
      PerfLog.mark('paged.jump',
          'target=$target char=$offset/$total landed=$landed win=${win.length}');
      _startPagedFrames();
      _ensureAutoFill();
      if (landed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || seq != _primeSeq) return;
          _samplePagedNow();
        });
      }
    } finally {
      if (seq == _primeSeq) _jumpInFlight = false;
      if (_reprimeRequested) _kickReprime();
    }
  }

  /// 预 ensure 窗口内全部图片真尺寸（分页前排齐图片高，避免入表后整书
  /// 重分页）。期间 `_ensuringSizes > 0` 抑制 [_noteImageSize] 钩子——
  /// open 即将吃到新尺寸，无需失效重分页。
  Future<void> _ensureWindowImageSizes(List<int> window) async {
    final PaginationScheduler? scheduler = _scheduler;
    if (scheduler == null) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null) return;
    final List<String> srcs = <String>[];
    for (final int i in window) {
      if (i < 0 || i >= chapters.length) continue;
      final ChapterContent? content = _cache.peek(i);
      if (content == null ||
          content.imagePages != null ||
          content.paragraphList.isEmpty) {
        continue;
      }
      for (final String s in imageSrcsOf(content.paragraphList)) {
        if (!srcs.contains(s)) srcs.add(s);
      }
    }
    if (srcs.isEmpty) return;
    _ensuringSizes++;
    try {
      for (final String s in srcs) {
        await ensureImageSize(s, scheduler.imageSizes, _resolveImage);
        if (!mounted || _disposed) return;
      }
    } finally {
      _ensuringSizes--;
    }
  }

  /// 图片尺寸钩子（`_resolveImage` 出口）：分页模式下首见尺寸 →
  /// 写表 + 失效重分页 + reprime（页行高依赖真尺寸）。
  void _noteImageSize(String href, Uint8List bytes) {
    if (!_pagedMode || _disposed || _ensuringSizes > 0) return;
    final PaginationScheduler? scheduler = _scheduler;
    if (scheduler == null || scheduler.config == null) return;
    if (scheduler.imageSizes.containsKey(href)) return;
    final Size? size = parseImageSize(bytes);
    if (size == null) return;
    scheduler.imageSizes[href] = size;
    scheduler.invalidateForImageSizes();
    _requestReprime();
  }

  /// 分页滚动体（[_buildBody] LayoutBuilder 内、视图就绪后上屏）。
  ///
  /// 结构恒定（`M-PAGE T05-d` 方案 A）：`Stack[Offstage(scroller), PageTurnBody?]`
  /// ——scroll ↔ turn 切换只翻 `Offstage` 与叠层的有无，滚动体**从不重挂**
  /// （GlobalKey / ScrollController / 布局表全保留）。
  Widget _buildPagedBody() {
    final PaginationConfig? cfg = _pageConfig;
    if (cfg == null || _pageViews.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final Widget scroller = PagedScroller(
      key: _scrollerKey,
      chapters: _pageViews,
      config: cfg,
      resolveImage: _resolveImage,
      controller: _controller,
      onSampled: _onPagedDebounced,
      onLinkTap: _onLinkTapped,
      highlightQuery: _searchHighlight.isEmpty ? null : _searchHighlight,
    );
    final ({int viewIndex, int pageIndex})? pos =
        _pageTurnModeAsTurn ? _turnPosition() : null;
    if (pos == null) {
      // 滚动模式 / 翻页态瞬时解析失败（窗口不含当前章）→ 回落滚动渲染，
      // 不出空白。
      return Stack(
        fit: StackFit.passthrough,
        children: <Widget>[Offstage(offstage: false, child: scroller)],
      );
    }
    final PagedChapterView cur = _pageViews[pos.viewIndex];
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Offstage(offstage: true, child: scroller),
        Positioned.fill(
          child: PageTurnBody(
            mode: _turnControllerMode,
            current: _turnPageWidget(cur, pos.pageIndex),
            buildIncoming: _buildTurnIncoming,
            canTurn: _canTurn,
            onGestureActive: _onTurnGesture,
            onCommit: _onTurnCommitted,
            scheduler: _scheduler,
          ),
        ),
      ],
    );
  }

  // ── T05-d 翻页接线（语义坐标 ↔ 页图层）────────────────────────────────

  /// 翻页方式 → 翻页体控制器模式（`scroll` 不进翻页体，占位映射无副作用）。
  PageTurnMode get _turnControllerMode => switch (_pageTurnMode) {
        ReaderPageMode.slide => PageTurnMode.slide,
        ReaderPageMode.cover => PageTurnMode.cover,
        ReaderPageMode.none => PageTurnMode.none,
        ReaderPageMode.scroll => PageTurnMode.slide,
      };

  /// 语义坐标（`_currentIndex` + `_chapterPos`）→ 当前页在视图表中的位置。
  /// `pageIndex == -1` = 占位章（页表空）；视图表不含当前章 → `null`。
  ({int viewIndex, int pageIndex})? _turnPosition() {
    if (_pageViews.isEmpty) return null;
    final String href = _hrefAt(_currentIndex);
    if (href.isEmpty) return null;
    final int v = _pageViews.indexWhere((PagedChapterView w) => w.href == href);
    if (v < 0) return null;
    final List<PageSlice> pages = _pageViews[v].pages;
    if (pages.isEmpty) return (viewIndex: v, pageIndex: -1);
    // `_chapterPos` 与 `totalChars` 同源（`charCountOf(paragraphs)`）——
    // 比例 × 总字数还原字符偏移，与保存 / 落位口径一致。
    final int total = PagePaginator.charCountOf(_pageViews[v].paragraphs);
    if (total <= 0) return (viewIndex: v, pageIndex: 0);
    final int charOffset =
        (_chapterPos.clamp(0.0, 1.0) * total).round().clamp(0, total);
    int p = PageBreaker.findPageByCharOffset(pages, charOffset);
    if (p < 0) p = 0;
    if (p >= pages.length) p = pages.length - 1;
    return (viewIndex: v, pageIndex: p);
  }

  /// 方向 → 目标（书内章下标 + 章内页码）；书边 / 占位邻章阻塞返回 `null`。
  ///
  /// 同章翻页按页表边界判定；跨章须邻视图**有页表**（占位章 = 阻塞——
  /// 这是 `canTurn` 的语义判定，翻页不进「载入中」占位块）。
  ({int book, int page})? _turnTarget(TurnDirection dir) {
    final ({int viewIndex, int pageIndex})? pos = _turnPosition();
    if (pos == null) return null;
    final List<PageSlice> cur = _pageViews[pos.viewIndex].pages;
    if (dir == TurnDirection.next) {
      if (pos.pageIndex >= 0 && pos.pageIndex + 1 < cur.length) {
        return (book: _currentIndex, page: pos.pageIndex + 1);
      }
      final int book = _currentIndex + 1;
      final List<Chapter>? chapters = _chapters;
      if (chapters == null || book >= chapters.length) return null;
      final List<PageSlice>? pages = _turnNeighborPages(_hrefAt(book));
      if (pages == null || pages.isEmpty) return null;
      return (book: book, page: 0);
    }
    if (pos.pageIndex > 0) return (book: _currentIndex, page: pos.pageIndex - 1);
    final int book = _currentIndex - 1;
    if (book < 0) return null;
    final List<PageSlice>? pages = _turnNeighborPages(_hrefAt(book));
    if (pages == null || pages.isEmpty) return null;
    return (book: book, page: pages.length - 1); // 章末 = 邻章末页
  }

  /// 邻章视图的页表（不在视图表 / href 无效 → `null`）。
  List<PageSlice>? _turnNeighborPages(String href) {
    if (href.isEmpty) return null;
    final int v = _pageViews.indexWhere((PagedChapterView w) => w.href == href);
    return v < 0 ? null : _pageViews[v].pages;
  }

  /// 方向可翻判定（翻页体 `canTurn`）：与 [_turnTarget] 同一判据——
  /// 解析得出目标即可翻，杜绝两处口径漂移。
  bool _canTurn(TurnDirection dir) => _turnTarget(dir) != null;

  /// 单页图层 widget（页 0 含章标题区；占位章 = 整页高占位块）。
  Widget _turnPageWidget(PagedChapterView view, int pageIndex) {
    final PaginationConfig? cfg = _pageConfig;
    if (cfg == null) return const SizedBox.shrink();
    if (view.pages.isEmpty || pageIndex < 0) {
      return Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: cfg.pageWidth,
          height: view.headingHeight,
          child: view.heading,
        ),
      );
    }
    final int p = pageIndex.clamp(0, view.pages.length - 1);
    final PageSlice page = view.pages[p];
    final List<Widget> children = <Widget>[];
    if (p == 0 && view.heading != null && view.headingHeight > 0) {
      children.add(Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: cfg.pageWidth,
          height: view.headingHeight,
          child: view.heading,
        ),
      ));
    }
    children.add(Align(
      alignment: Alignment.topCenter,
      child: PageContent(
        paragraphs: view.paragraphs,
        lines: view.lines,
        page: page,
        config: cfg,
        resolveImage: _resolveImage,
        onLinkTap: _onLinkTapped,
        highlightQuery: _searchHighlight.isEmpty ? null : _searchHighlight,
        clipHeight: page.height,
      ),
    ));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  /// 目标页惰性构建（翻页体起手判定成功后调用一次）。
  Widget _buildTurnIncoming(TurnDirection dir) {
    final ({int book, int page})? target = _turnTarget(dir);
    if (target == null) return const SizedBox.shrink();
    final int v = _pageViews
        .indexWhere((PagedChapterView w) => w.href == _hrefAt(target.book));
    if (v < 0) return const SizedBox.shrink();
    return _turnPageWidget(_pageViews[v], target.page);
  }

  /// 手势会话起止（`T05-d` 三重闸）：true = 作废在途停稳序列 + 清挂起落位
  /// + 挡 reprime；false = 解闸，待办 reprime 立即补跑。
  void _onTurnGesture(bool active) {
    if (active) {
      _noteReading(); // 翻页手势起手 = 交互（含未提交就取消的滑动）
      _pagedStopSeq++;
      _pendingLand = null;
      _turnGestureActive = true;
      return;
    }
    _turnGestureActive = false;
    if (_reprimeRequested) _kickReprime();
  }

  /// 翻页 commit：语义坐标**直写**（滚动体 Offstage 下不回采）→ 停稳流
  /// 收尾（①身份同步在翻页态空跳、⑤ prime 把滚动体 re-land 到新语义位、
  /// ⑨ 确认 + 落盘）。
  void _onTurnCommitted(TurnDirection dir) {
    final ({int book, int page})? target = _turnTarget(dir);
    if (target == null) return;
    final int v = _pageViews
        .indexWhere((PagedChapterView w) => w.href == _hrefAt(target.book));
    if (v < 0) return;
    final List<PageSlice> pages = _pageViews[v].pages;
    if (pages.isEmpty) return;
    final int page = target.page.clamp(0, pages.length - 1);
    final int total = PagePaginator.charCountOf(_pageViews[v].paragraphs);
    final double pos =
        total > 0 ? (pages[page].start / total).clamp(0.0, 1.0) : 0.0;
    setState(() {
      _currentIndex = target.book;
      _chapterPos = pos;
      _liveIndex = target.book;
      _livePos = pos;
    });
    _positionSampled = true;
    unawaited(_onPagedStopped());
  }

  /// 跳到第 [index] 章章首（目录点击 / 上下一章按钮）。
  Future<void> _goToChapter(int index) async {
    _noteReading(); // 目录 / 上一章下一章按钮 = 交互
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
    PerfLog.mark('nav.goto', 'target=$target from=$_currentIndex');
    if (_pagedMode) {
      await _pagedJumpTo(target, pos: 0.0); // saveOld 在流内
      return;
    }
    // 保存旧位置（此时 _currentIndex / _chapterPos 仍是旧位置）。
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _currentIndex = target;
      _chapterPos = 0.0;
      _liveIndex = target;
      _livePos = 0.0;
    });
    // 先把目标章载入（邻章 ±1 预取不阻塞），避免跳到占位块后高度回填引起漂移。
    final PerfWatch watch = PerfLog.watch('nav.goto.firstBatch');
    await loader?.loadFirstBatch(target);
    watch.done('target=$target');
    if (!mounted) return;
    _beginScrollTo(target, 0.0);
    // 补齐留给 [_finishRestore]（先落定、后补齐；理由见 `_open` 注释）。
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
    _noteReading(); // 链接 / 书签 / 搜索命中跳转 = 交互
    if (_pagedMode) {
      // 分页：压栈用语义坐标（章索引 + 章内字符比例），跳转走统一分页流。
      final List<Chapter>? chapters = _chapters;
      if (chapters == null || chapters.isEmpty) return;
      final int target = chapterIndex.clamp(0, chapters.length - 1);
      _linkStack.push(ScrollAnchor(
          chapterIndex: _currentIndex, relativePos: _chapterPos));
      setState(() {}); // 让「返回」按钮出现。
      await _loader?.loadFirstBatch(target);
      if (!mounted) return;
      final List<String> paragraphs =
          _cache.peek(target)?.paragraphList ?? const <String>[];
      int charOffset = 0;
      for (int p = 0; p < paraIndex && p < paragraphs.length; p++) {
        charOffset += paragraphs[p].length;
      }
      final int total = PagePaginator.charCountOf(paragraphs);
      await _pagedJumpTo(target,
          pos: total > 0 ? charOffset / total : 0.0, charOffset: charOffset);
      return;
    }
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
      _liveIndex = chapterIndex;
      _livePos = roughPos;
    });
    // 先把目标章载入（邻章 ±1 预取不阻塞），避免跳到占位块后高度回填引起漂移。
    await loader?.loadFirstBatch(chapterIndex);
    if (!mounted) return;
    _beginScrollTo(chapterIndex, roughPos,
        paraIndex: paraIndex >= 0 ? paraIndex : -1);
    // 补齐留给 [_finishRestore]（先落定、后补齐；理由见 `_open` 注释）。
  }

  /// 「返回」按钮（`CNT-04c` 验收②）：弹栈恢复到跳转前的位置。
  ///
  /// 栈空（弹出 `null`）静默返回，不抛异常。
  Future<void> _goBack() async {
    _noteReading(); // 返回 = 交互
    final ScrollAnchor? anchor = _linkStack.pop();
    if (anchor == null) return;
    setState(() {}); // 栈可能已空：让「返回」按钮消失。
    // 保存旧位置（跳转后的位置）。
    await _saveProgress();
    if (!mounted) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final int target = anchor.chapterIndex.clamp(0, chapters.length - 1);
    if (_pagedMode) {
      // 分页：流内 saveOld 保存跳转后位置，弹栈按语义坐标一次落位。
      await _pagedJumpTo(target, pos: anchor.relativePos);
      return;
    }
    setState(() {
      _currentIndex = target;
      _chapterPos = anchor.relativePos;
      _liveIndex = target;
      _livePos = anchor.relativePos;
    });
    // 目标章可能已被 LRU 淘汰：先载入目标章再恢复（邻章 ±1 预取不阻塞）。
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
      // 现场测不到（关书时控制器已 detach）→ 回退本会话最后可信快照：
      // **绝不用 null 覆盖已存快照**，否则「开→关」每循环一次就丢一次像素落点。
      localHint: _buildLocalHint() ?? _lastLocalHint,
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
  ///
  /// 测得成功即写入 [_lastLocalHint] 留底（关书时现场已不可读，见字段注释）。
  LocalLayoutHint? _buildLocalHint() {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return null;
    if (_viewportWidth <= 0 || _viewportHeight <= 0) return null;
    final LocalLayoutHint hint = LocalLayoutHint(
      scrollOffset: controller.offset,
      fontSize: _settings.fontSize,
      lineHeight: _settings.lineHeight,
      viewportWidth: _viewportWidth,
      viewportHeight: _viewportHeight,
    );
    _lastLocalHint = hint;
    return hint;
  }

  /// 全书进度 `0.0 ~ 1.0`：**字数加权**（`M-PAGE` T03，选型 §6 拍板②）；
  /// 权重未就绪 / 源不支持时退化为章节等权（与迁移前公式逐位一致）。
  ///
  /// 末章 `chapterPos == 1.0` 且末章有权重时恰好 100%。
  double _overallProgress(int index, double chapterPos) {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return 0.0;
    return overallReadingProgress(
      chapterIndex: index,
      chapterPos: chapterPos,
      chapterCount: chapters.length,
      chapterWeights: _chapterWeights,
    );
  }

  /// 异步取每章字数权重（fire-and-forget，见 [_chapterWeights] 注释）。
  ///
  /// `null`（源不支持）保持等权；dispose / 竞态静默放弃，不写状态。
  Future<void> _loadChapterWeights() async {
    try {
      final List<int>? weights = await widget.source.chapterCharCounts();
      if (!mounted || _disposed || weights == null) return;
      final List<Chapter>? chapters = _chapters;
      if (chapters == null || weights.length != chapters.length) return;
      setState(() => _chapterWeights = weights);
    } catch (_) {
      // 权重取不到不影响阅读：继续等权。
    }
  }

  /// 显示用全书进度百分比（整数，向下取整——避免「差一点」就显示 100%）。
  ///
  /// `TYP-09` 验收②：取滚动实时值 `_liveIndex` / `_livePos`；
  /// 存档侧的 `markRead` 仍用语义值（[_overallProgress]），互不干扰。
  int get _livePercent {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return 0;
    final double overall = overallReadingProgress(
      chapterIndex: _liveIndex,
      chapterPos: _livePos,
      chapterCount: chapters.length,
      chapterWeights: _chapterWeights,
    );
    return (overall * 100).floor();
  }

  /// 是否夜间（暗色主题）——`TYP-08` 验收③「夜间模式不产生白底」的判定基准：
  /// 以**实际生效的主题亮度**为准（跟随系统时即系统当前亮度）。
  bool _isNight(ThemeData theme) => theme.brightness == Brightness.dark;

  /// 页面底色（`TYP-08`：背景色板 × 夜间映射）。
  Color _pageColor(ThemeData theme) =>
      _background.pageColor(night: _isNight(theme));

  /// 正文文字颜色（与页面底色配对，保证对比度）。
  Color _textColor(ThemeData theme) =>
      _background.textColor(night: _isNight(theme));

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

  /// 打开书签弹窗（`TYP-06`：添加当前位置 / 列表查看 / 跳转 / 逐条删除）。
  void _openBookmarks() {
    // 与 [TocSheet] 同款玻璃底部弹窗（`UI-03` / `UI-04`：列表行垫不透明表面）。
    GlassOverlays.showSheet<void>(
      context: context,
      isScrollable: false,
      builder: (BuildContext sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
        ),
        child: OpaqueContentSurface(
          child: BookmarkSheet(
            bookmarks: _bookmarks,
            onCreate: _addBookmarkAtCurrentPosition,
            onDelete: _removeBookmark,
            onJump: (Bookmark bookmark) {
              Navigator.of(sheetContext).pop();
              unawaited(_goToBookmark(bookmark));
            },
          ),
        ),
      ),
    );
  }

  /// 打开全书搜索面板（`CNT-06`）：输入关键词 → 「章节名 + 上下文片段」列表 →
  /// 点击跳转并高亮。与 [BookmarkSheet] 同款玻璃底部弹窗（`UI-03` / `UI-04`）。
  void _openSearch() {
    GlassOverlays.showSheet<void>(
      context: context,
      isScrollable: false,
      builder: (BuildContext sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: OpaqueContentSurface(
          child: SearchSheet(
            startSearch: _startSearch,
            onJump: (SearchHit hit, String query) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToSearchHit(hit, query));
            },
          ),
        ),
      ),
    );
  }

  /// 发起一次全书搜索：[SearchSession.start] 按源能力自动分流——可序列化
  /// `searchSpec`（EPUB / TXT）进后台 isolate；句柄源（PDF）本 isolate 流式。
  SearchSession _startSearch(String query) => SearchSession.start(
        query: query,
        spec: widget.source.searchSpec,
        localSource: widget.source,
      );

  /// 跳到搜索命中位置（`CNT-06` 验收②）：章内字符偏移 → 段落下标换算
  /// （段落字符数累加，与 `SearchHit.offset` 同口径），随后复用链接跳转
  /// 「估算 + 校正」的段落级对齐路径；关键词写入 [_searchHighlight] 高亮。
  ///
  /// 图片页（CBZ / PDF）无段落概念 → `paragraphList` 为空、`paraIndex` 保持
  /// -1，走纯跳章。offset 恰在段末之后的容错：兜到末段（不静默丢弃跳转）。
  Future<void> _jumpToSearchHit(SearchHit hit, String query) async {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final int chapterIndex = hit.chapterIndex.clamp(0, chapters.length - 1);
    // 目标章可能未加载：先载入（±1 预取不阻塞），再按字符累加定位段落。
    await _loader?.loadFirstBatch(chapterIndex);
    if (!mounted) return;
    int paraIndex = -1;
    final List<String> paragraphs =
        _cache.peek(chapterIndex)?.paragraphList ?? const <String>[];
    int consumed = 0;
    for (int p = 0; p < paragraphs.length; p++) {
      final int end = consumed + paragraphs[p].length;
      if (hit.offset < end) {
        paraIndex = p;
        break;
      }
      consumed = end;
    }
    if (paraIndex < 0 && paragraphs.isNotEmpty) {
      paraIndex = paragraphs.length - 1;
    }
    setState(() => _searchHighlight = query);
    await _jumpToLink(chapterIndex, paraIndex);
  }

  /// 打开外观面板（`TYP-07` 字体族 / `TYP-08` 亮度与背景色）。
  void _openAppearance() {
    GlassOverlays.showSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => OpaqueContentSurface(
        child: ReadingAppearanceSheet(
          prefs: ReadingPrefs(
            settings: _settings,
            brightness: _brightness,
            background: _background,
            pageMode: _pageTurnMode,
          ),
          onChanged: _onPrefsChanged,
        ),
      ),
    );
  }

  /// 抓「当前位置」创建书签并入列 + 落盘（`TYP-06`）；返回 `null` = 书未就绪。
  Bookmark? _addBookmarkAtCurrentPosition() {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return null;
    final int index = _currentIndex.clamp(0, chapters.length - 1);
    final Chapter chapter = chapters[index];
    final Bookmark bookmark = Bookmark(
      bookId: widget.record.bookId,
      chapterHref: chapter.href,
      chapterIndex: index,
      chapterPos: _chapterPos,
      chapterTitle:
          chapter.title.isNotEmpty ? chapter.title : '第 ${index + 1} 节',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _bookmarks = <Bookmark>[..._bookmarks, bookmark]);
    _persistBookmarks();
    return bookmark;
  }

  /// 删除书签（`TYP-06`）：内存列表即时移除 + 落盘（弹窗侧 UI 同步即时更新）。
  void _removeBookmark(Bookmark bookmark) {
    final List<Bookmark> next = List<Bookmark>.of(_bookmarks)
      ..remove(bookmark);
    setState(() => _bookmarks = next);
    _persistBookmarks();
  }

  /// 书签落盘（fire-and-forget；失败静默，下次保存重试，不影响阅读）。
  void _persistBookmarks() {
    final BookmarkStore? store = widget.bookmarkStore;
    if (store == null) return;
    unawaited(_persistBookmarksQuietly(store));
  }

  Future<void> _persistBookmarksQuietly(BookmarkStore store) async {
    try {
      await store.save(widget.record.bookId, _bookmarks);
    } catch (_) {
      // 保存失败不影响阅读（与 `_saveProgress` 同策略）。
    }
  }

  /// 阅读偏好落盘（fire-and-forget；失败静默）。
  void _persistPrefs() {
    final ReadingPrefsStore? store = widget.readingPrefsStore;
    if (store == null) return;
    unawaited(_persistPrefsQuietly(store));
  }

  Future<void> _persistPrefsQuietly(ReadingPrefsStore store) async {
    try {
      await store.save(ReadingPrefs(
        settings: _settings,
        brightness: _brightness,
        background: _background,
        pageMode: _pageTurnMode,
      ));
    } catch (_) {
      // 保存失败不影响阅读。
    }
  }

  /// 跳回书签位置（`TYP-06` 验收②）：href 优先，匹配不到退回 index 并 clamp。
  Future<void> _goToBookmark(Bookmark bookmark) async {
    final List<Chapter>? chapters = _chapters;
    final ChapterAutoLoader? loader = _loader;
    final ScrollController? controller = _controller;
    if (chapters == null ||
        chapters.isEmpty ||
        controller == null ||
        !controller.hasClients) {
      return;
    }
    final int matched =
        chapters.indexWhere((Chapter c) => c.href == bookmark.chapterHref);
    final int target = matched >= 0
        ? matched
        : bookmark.chapterIndex.clamp(0, chapters.length - 1);
    if (_pagedMode) {
      // 分页：saveOld 在流内保存当前位置，书签位置一次落位。
      await _pagedJumpTo(target, pos: bookmark.chapterPos);
      return;
    }
    // 保存旧位置（此时 _currentIndex / _chapterPos 仍是旧位置）。
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _currentIndex = target;
      _chapterPos = bookmark.chapterPos;
      _liveIndex = target;
      _livePos = bookmark.chapterPos;
    });
    // 先把目标章载入（邻章 ±1 预取不阻塞），避免跳到占位块后高度回填引起漂移。
    await loader?.loadFirstBatch(target);
    if (!mounted) return;
    _beginScrollTo(target, bookmark.chapterPos);
    _ensureAutoFill();
  }

  /// 沉浸全屏切换（`TYP-09`）：隐藏 / 恢复 AppBar 与底部控制条。
  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
  }

  /// 外观面板回调（`TYP-07` / `TYP-08`）：排版变化走位置锚定，亮度 / 背景只重绘。
  void _onPrefsChanged(ReadingPrefs next) {
    final bool typesetChanged = next.settings != _settings;
    final bool modeChanged = next.pageMode != _pageTurnMode;
    // 模式切换前先按**旧模式**口径取锚点（turn 分支读语义、scroll 分支读
    // 现场采样——两者在停稳时等价），postFrame 再按新口径 re-land。
    final int anchor = modeChanged ? _currentCharOffset() : 0;
    setState(() {
      _brightness = next.brightness;
      _background = next.background;
      _pageTurnMode = next.pageMode;
    });
    if (typesetChanged) {
      // 字号 / 行距 / 字体族会重排 → 与控制条同款「锚定 → setState → 校正」。
      _applySettings(next.settings);
    }
    if (modeChanged) _relandForPageMode(anchor);
    _persistPrefs();
  }

  /// 翻页方式切换后的滚动体重落位（`M-PAGE T05-d`）：Offstage 下滚动体始终
  /// 挂载，但 turn ↔ scroll 两侧的语义口径不同（turn 直写 / scroll 现场采样）——
  /// 按切换前捕获的 [anchor] 单跳对齐，保证两种模式看到同一位置。
  void _relandForPageMode(int anchor) {
    if (!_pagedMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      final PagedScrollerState? scroller = _scroller;
      if (scroller == null) return;
      final String href = _hrefAt(_currentIndex);
      if (href.isEmpty) return;
      scroller.jumpToCharOffset(href, anchor);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Chapter>? chapters = _chapters;
    final bool ready = _ready && chapters != null && chapters.isNotEmpty;

    return Scaffold(
      backgroundColor: _pageColor(theme),
      // `TYP-09` 验收①③：沉浸全屏隐藏顶部栏，退出全屏原样恢复。
      appBar: _fullscreen
          ? null
          : AppBar(
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
                  key: const Key('reader-search'),
                  tooltip: '搜索',
                  icon: const Icon(Icons.search),
                  onPressed: ready ? _openSearch : null,
                ),
                IconButton(
                  key: const Key('reader-bookmarks'),
                  tooltip: '书签',
                  icon: const Icon(Icons.bookmark),
                  onPressed: ready ? _openBookmarks : null,
                ),
                IconButton(
                  key: const Key('reader-appearance'),
                  tooltip: '外观',
                  icon: const Icon(Icons.tune),
                  onPressed: ready ? _openAppearance : null,
                ),
                IconButton(
                  tooltip: '目录',
                  icon: const Icon(Icons.list),
                  onPressed: ready ? _openToc : null,
                ),
                IconButton(
                  key: const Key('reader-fullscreen-enter'),
                  tooltip: '全屏',
                  icon: const Icon(Icons.fullscreen),
                  onPressed: ready ? _toggleFullscreen : null,
                ),
              ],
            ),
      bottomNavigationBar: ready && !_fullscreen
          ?             ReaderControlBar(
              settings: _settings,
              onSettingsChanged: _onSettingsChanged,
              chapterNumber: _liveIndex + 1,
              chapterCount: chapters.length,
              percent: _livePercent,
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
  ///
  /// 取**滚动实时显示值**（`TYP-09` 验收②；显示值语义见 `_liveIndex` 字段注释）。
  String get _subtitle {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null) return '载入中…';
    if (chapters.isEmpty) return '无章节';
    return '第${_liveIndex + 1}章 · $_livePercent%';
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
      // 首帧批次尚未就绪（只等目标章，很快）。
      return const Center(child: CircularProgressIndicator());
    }

    // `TYP-07`：字体族（系统默认 / 衬线 / 无衬线）+ 跨平台回退链（中文无豆腐块）；
    // `TYP-08`：正文颜色随背景色板（夜间映射保证对比度、夜间无白底）。
    final TextStyle bodyStyle =
        resolveTextStyle(_settings, theme: theme).copyWith(
      fontFamilyFallback: readerFontFallback(_settings.fontFamily),
      color: _textColor(theme),
    );
    final Color pageColor = _pageColor(theme);

    // 分页模式的标题 / 占位样式（与测量同源：_headingHeightOf / _headingWidget）。
    _headingTextStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
      color: bodyStyle.color,
    );
    _placeholderTextStyle = theme.textTheme.bodySmall
        ?.copyWith(color: bodyStyle.color?.withValues(alpha: 0.6));

    // 在布局期拿到视口尺寸（用于版面签名与坐标换算），并据内容就绪创建控制器。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewportWidth = constraints.maxWidth;
        _viewportHeight = constraints.maxHeight;
        _syncPageConfig(PaginationConfig(
          pageWidth: constraints.maxWidth - _settings.pageMargin.horizontal,
          pageHeight: constraints.maxHeight,
          textStyle: bodyStyle,
          paragraphSpacing: 16,
          textScaleFactor: MediaQuery.textScalerOf(context).scale(1.0),
        ));
        _ensureController();
        return SizedBox.expand(
          key: _viewportKey,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: NotificationListener<ScrollUpdateNotification>(
                  // `TYP-09` 验收②：滚动实时刷新进度显示（只写显示字段）。
                  onNotification:
                      _pagedMode ? _onPagedScrollUpdate : _onScrollUpdate,
                  child: NotificationListener<ScrollEndNotification>(
                    onNotification:
                        _pagedMode ? _onPagedScrollEnd : _onScrollEnd,
                    child: _pagedMode
                        ? _buildPagedBody()
                        : ListView.builder(
                            controller: _controller,
                            // bottom 留出进度指示条高度（约 28px）+ 留白，
                            // 避免末段正文被常驻指示条压住看不见。
                            padding:
                                const EdgeInsets.only(top: 8, bottom: 40),
                            itemCount: chapters.length,
                            itemBuilder: (BuildContext context, int index) =>
                                _buildChapterItem(theme, bodyStyle, index),
                          ),
                  ),
                ),
              ),
              // backlog① 方案 B：开书首跳校正全程遮罩——中间跳转不可见，
              // [_finishRestore] 撤除。opaque 手势层顺带吞掉恢复期间的拖动，
              // 防止用户滚动与 `jumpTo` 校正互相打架。
              if (_restoreMask)
                Positioned.fill(
                  child: GestureDetector(
                    key: const Key('reader-restore-mask'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: ColoredBox(
                      // `TYP-08` 验收③：遮罩底色跟页面底色——纯黑 / 夜间背景时
                      // 不得闪白底（旧值 `theme.scaffoldBackgroundColor` 在亮色
                      // 主题下是白的）。
                      color: pageColor,
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ),
              // `TYP-08` 验收①：应用内亮度遮罩——黑色叠加层，不透明度
              // `1 - brightness`；拖动即生效（实时），由外观面板持久化（保留）。
              if (_brightness < ReadingPrefs.maxBrightness)
                Positioned.fill(
                  key: const Key('reader-brightness-mask'),
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Color.fromRGBO(0, 0, 0, 1 - _brightness),
                    ),
                  ),
                ),
              // `TYP-09`：细粒度进度指示（常驻；全屏隐藏控制条后仍是可见进度）。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ReaderProgressIndicator(
                  chapterNumber: _liveIndex + 1,
                  chapterCount: chapters.length,
                  percent: _livePercent,
                ),
              ),
              // `TYP-09` 验收③：全屏时右上浮动按钮——退出并恢复顶部栏。
              if (_fullscreen)
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton.filledTonal(
                    key: const Key('reader-fullscreen-exit'),
                    tooltip: '退出全屏',
                    icon: const Icon(Icons.fullscreen_exit),
                    onPressed: _toggleFullscreen,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 设置变更（字号 / 行距 / 页边距 / 主题；控制条入口）。
  ///
  /// `ReaderSettings.copyWith` 的「fontFamily 传 null = 重置」语义：控制条各按钮
  /// 的 `copyWith` 调用**不带** fontFamily，会把字体族清掉。字体族只能由外观面板
  /// （`TYP-07`）修改，故这里在页面边界**续上当前字体族**（显式构造，全字段可控），
  /// 再走 [_applySettings] 的位置锚定，并落盘偏好（`TYP-07` 保留）。
  void _onSettingsChanged(ReaderSettings newSettings) {
    final ReaderSettings merged = ReaderSettings(
      fontSize: newSettings.fontSize,
      lineHeight: newSettings.lineHeight,
      fontFamily: _settings.fontFamily,
      themeMode: newSettings.themeMode,
      pageMargin: newSettings.pageMargin,
    );
    _applySettings(merged);
    _persistPrefs();
  }

  /// 应用排版设置：先锚定当前位置，再 setState，再校正。
  ///
  /// `TYP-02` 位置锚定：用 [ScrollAnchor] 记录「视口顶在当前章的相对位置」，
  /// 列表重建后用同一章块的新位置算出 delta，`jumpTo` 校正，使该段仍在视口内。
  void _applySettings(ReaderSettings newSettings) {
    if (_pagedMode) {
      // 分页：LayoutBuilder 下一帧检出 cfg 变化 → reprime 保位重分页。
      setState(() => _settings = newSettings);
      return;
    }
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
          style: theme.textTheme.bodySmall
              ?.copyWith(color: bodyStyle.color?.withValues(alpha: 0.6)),
        ),
      );
    }

    // 图片页模式（CBZ / PDF 出图，`FMT-02`，M2b-T02）：整页竖向滚动、点页全屏
    // 缩放（验收②「缩放后不糊」= 全屏查看原始字节解码）；「进度按页」（验收③）由
    // 「每页一章」的模型映射天然成立（`cbz_source.dart`：href = 页条目路径）。
    // 单/双页切换（US-12 描述面）不在 FMT-02 验收①②③内，本批未覆盖。
    final List<String>? imagePages = content.imagePages;
    if (imagePages != null) {
      return Padding(
        key: _chapterKeys[index],
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int p = 0; p < imagePages.length; p++)
              _ImagePage(
                key: Key('reader-image-page:${imagePages[p]}'),
                src: imagePages[p],
                resolveImage: _resolveImage,
                onOpen: _openImageZoom,
              ),
          ],
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
          // TYP-04：标题居中；颜色随背景色板（TYP-08 对比度 / 夜间无白底）。
          Text(
            heading,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: bodyStyle.color,
            ),
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
                // CNT-06 验收②：搜索跳转后关键词高亮（空 = 不高亮）。
                highlightQuery:
                    _searchHighlight.isEmpty ? null : _searchHighlight,
              ),
            ),
        ],
      ),
    );
  }
}

/// 图片页（CBZ 整页图，`FMT-02`）：异步加载原始字节 → 整页宽显示 → 点击全屏缩放。
///
/// 生命周期与 `typeset.dart` 的 `_InlineImage` 同款：`initState` 发起加载，rebuild
/// 不重载；加载中 / 失败给 240 高占位（既是骨架也是稳定的点击热区）。
/// `Image.memory` **不设 `cacheWidth` 降采样**：保留原始分辨率——验收②「缩放后不糊」
/// 的前提（全屏查看器缩放的是原始位图）。
class _ImagePage extends StatefulWidget {
  const _ImagePage({
    super.key,
    required this.src,
    required this.resolveImage,
    required this.onOpen,
  });

  /// 图片的包内条目路径（CBZ = zip 条目名）。
  final String src;

  /// 图片加载回调（`BookSource.readResource`）。
  final Future<Uint8List?> Function(String href) resolveImage;

  /// 点击回调：参数为已解出的原始字节（全屏查看器直接消费）。
  final void Function(Uint8List bytes) onOpen;

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Uint8List? bytes = await widget.resolveImage(widget.src);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
        _error = bytes == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _bytes;
    if (_loading) {
      return const SizedBox(
        height: 240,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error || bytes == null) {
      return const SizedBox(
        height: 240,
        child: Center(child: Icon(Icons.broken_image_outlined, size: 48)),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(bytes),
      child: ConstrainedBox(
        // minHeight：位图未解码完也有稳定点击热区（解码后按宽高比撑开）。
        constraints: const BoxConstraints(minHeight: 240),
        child: Image.memory(
          bytes,
          fit: BoxFit.fitWidth,
          width: double.infinity,
          gaplessPlayback: true,
        ),
      ),
    );
  }
}

/// 全屏图片缩放查看器（`FMT-02` 验收②）：`InteractiveViewer` 捏合缩放 + 拖动。
///
/// 显示**原始字节**解码的位图（不降采样）——放大到 1:1 以上像素级锐利（「不糊」）。
class _ImageZoomPage extends StatelessWidget {
  const _ImageZoomPage({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('reader-image-zoom'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('缩放查看'),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          minScale: 1,
          child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }
}
