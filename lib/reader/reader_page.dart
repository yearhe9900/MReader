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
//   · **`TYP-09` 默认全屏与进度指示**：进阅读页**默认沉浸全屏**（隐藏 AppBar
//     与底部控制条），**不设全屏切换按钮**——chrome 由点正文**九宫格中宫**
//     唤出 / 收起（2026-10-10 改口径：整屏划 3×3，只有最中间宫格的落点响应，
//     见 [_onContentTapUp] / [_toggleFullscreen]）；底部常驻读数「当前章标题 · 当前章 n/N · 全书 x.y%」
//     **随滚动 / 翻页实时更新**（[_updateLiveProgress] 只写显示字段 `_liveIndex` /
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

import '../ai/ai_client.dart';
import '../ai/provider_store.dart';
import '../ai/rag.dart';
import '../ai/recap.dart';
import '../ai/summary_cache.dart';
import '../ai/vocab_store.dart';
import '../diagnostics/open_trace.dart';
import '../diagnostics/perf_log.dart';
import '../format/book_source.dart';
import '../library/book_record.dart';
import '../library/library_repository.dart';
import '../stats/reading_session.dart';
import '../stats/stats_service.dart';
import '../sync/sync_trigger.dart';
import '../task/search_session.dart';
import '../tts/audio_session.dart';
import '../tts/online_tts.dart';
import '../tts/sleep_timer.dart';
import '../tts/system_tts.dart';
import '../tts/tts_settings.dart';
import '../tts/tts_controller.dart';
import '../tts/tts_engine.dart';
import '../typography/anchor.dart';
import '../typography/reader_settings.dart';
import '../typography/text_style_resolver.dart';
import '../typography/typeset.dart';
import '../ui/ask_panel.dart';
import '../ui/entity_page.dart';
import '../ui/glass_kit.dart';
import '../ui/reader_control_chrome.dart';
import '../ui/search_sheet.dart';
import 'bookmark.dart';
import 'bookmark_sheet.dart';
import 'bookmark_store.dart';
import 'chapter_cache.dart';
import 'control_bar.dart';
import 'image_cache.dart';
import 'image_dimensions.dart';
import 'highlight_follow.dart';
import 'link_navigator.dart';
import 'reader_ai_panel.dart';
import 'reader_open_transition.dart';
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
import 'selection_ai_sheet.dart';
import 'selection_overlay.dart';
import 'summary_sheet.dart';
import 'toc_sheet.dart';
import 'tts_settings_sheet.dart';

/// 恢复滚动时的最大校正帧数（`RD-04`：估算后迭代收敛；`RC2`：≤8 帧）。
const int _kMaxRestoreFrames = 8;

/// 占位块在「尚无任何已加载章可测」时的默认高度（逻辑像素）。
const double _kDefaultChapterHeight = 480;

/// 章标题块顶部空档（**章间空行隔离**，2026-10-09 负责人拍板）。
///
/// 每个章标题块都带这段空档 ⇒ 分页长卷里章与章之间恒隔一个空行量级
/// （改前两章几乎贴着——旧版的 `Divider` 是题-文分隔，不管章间距）。
const double _kHeadingGapTop = 24;

/// 章标题与正文的呼吸（旧留白链 6+1+12 里的「12」；横线删除后保留题-文间距）。
const double _kHeadingGapBottom = 12;

/// 正文底部为常驻 [ReaderProgressIndicator] 预留的高度（dp，**不含**底部系统栏）。
///
/// 实测：该条= 2dp 细条 + `EdgeInsets.symmetric(vertical: 4)` + 一行 `bodySmall`
/// ≈ 26dp，留 2dp 余量。改前分页模式页高 = 满屏视口高，**末页最后一行被这条压住**
/// （真机截图「字没显示全」）。此常量给正文留出这段高度。
///
/// 2026-10-08：默认全屏后指示器还要让开手势导航条，那部分**另算**——正文预算取
/// `本常量 + 系统 padding.bottom`（Scaffold **外层**的 MediaQuery，见 `_buildBody`
/// 的 `reserve`），本常量只描述指示器自身的文字高度，不随机型变。
///
/// 2026-10-09（`TYP-09`）：底部层改挂 Scaffold 的 `bottomNavigationBar` 槽 +
/// `extendBody`，这段让位因此**不再**依赖「全屏时 `Scaffold` 恰好不
/// `removeBottomPadding`」那种巧合——一律取外层系统 inset（`systemMq`），
/// chrome 显隐不影响它。
const double _kProgressIndicatorReserve = 28;

/// R1②：交互挂起后台补齐的**兜底帧数**（到期自动恢复，见 `ReaderPage._pauseAutoFill`）。
///
/// 不做成「秒」而做成「补齐批次数」：补齐循环每批递减一次（[_autoFillLoop]），
/// 不依赖任何定时器（定时器在 widget 测试的 `FakeAsync` 下会留下未清的挂起物，
/// 见 `_idleGap` 头注的教训）。`kAutoFillBatchSize` 默认 5 章 ⇒ 约 20~30 批
/// ≈ 2s 量级的让位，对「一次连续滚动」足够，对「滚动中途停手」也不过太久。
const int kAutoFillPauseFrames = 20;

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
    this.aiStore,
    this.aiClient,
    this.vocabStore,
    this.summaryCache,
    this.ragStore,
    this.ttsEngine,
    this.ttsSettings,
    this.onlineTts,
    this.syncTrigger,
    this.openTrace,
    this.initialJump,
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

  /// AI 配置存储（划词翻译 / 释义，`AI-02`/`AI-03`），由组合根透传。
  ///
  /// **三个 AI 参数任一为 null → 划词功能整体禁用**（长按不选词、不出操作条，
  /// 与 [statsService] 同款降级口径；`AI-09` ② 全局开关另由 prefs.aiEnabled 控制）。
  final ProviderStore? aiStore;

  /// AI 客户端（流式调用，组合根进程内唯一实例）。
  final AiClient? aiClient;

  /// 生词本存储（释义面板「存生词本」入口）。
  final VocabStore? vocabStore;

  /// 摘要缓存（章节摘要 / 全书摘要 / 前情回顾，`AI-04`/`AI-05`），组合根透传。
  ///
  /// `null` = 未接线：摘要入口整体隐藏（与划词同款降级口径）。
  final SummaryCache? summaryCache;

  /// 跟书问答索引存储（`AI-06`，`M3-T04`），组合根透传。
  ///
  /// `null` = 未接线：问答入口整体隐藏（与摘要同款降级口径）。
  final RagIndexStore? ragStore;

  /// 系统 TTS 引擎注入（`TTS-01`，`M3-T06`）。
  ///
  /// `null` = 用 [SystemTts] 默认实例（生产接线）；测试注入假引擎。
  /// 与 [aiStore] 同款可空降级形制。
  final TtsEngine? ttsEngine;

  /// 朗读设置存储（语速 / 音色 / 定时停止，`TTS-04`/`TTS-05`；`M3-T08`），
  /// 组合根透传。
  ///
  /// `null` = 未接线：朗读设置入口隐藏、按默认值运行（同款降级口径）。
  final TtsSettingsStore? ttsSettings;

  /// 在线 TTS 配置存储（URL 模板 / OpenAI 兼容，`TTS-07`；`M3-T09`），
  /// 组合根透传。
  ///
  /// `null` = 未接线：引擎选择区整体隐藏、只用系统引擎（同款降级口径）。
  final OnlineTtsStore? onlineTts;

  /// 同步触发器（`M4-T05` `SYNC-06`）：退出阅读页时上报本书进度。
  ///
  /// `null` = 未接线：关页只落本地盘（同款降级口径）。
  final SyncTrigger? syncTrigger;

  /// 开书链路追踪（`OpenTrace`）：由书架在「用户按下书卡」时创建并透传，
  /// 本页负责补齐**阅读侧**的段落（`routeInit` / `ready` / `firstFrame` /
  /// `restoreEnd`）并输出 `open.total`（按下→首帧上屏）。
  ///
  /// `null` = 未接线（直接进本页的测试 / 深链）：本页照常打既有 [PerfLog]
  /// 分段点，只是不产出端到端的 `open.total`（同款降级口径）。
  final OpenTrace? openTrace;

  /// 开书落位目标（生词本「跳回原文」，`AI-03` ③）：按 href 覆盖存档进度，
  /// 段落级对齐。`null` = 按存档进度恢复（正常开书）。
  ///
  /// 融入既有恢复链路（ListView `_beginScrollTo(paraIndex:)` / 分页
  /// `_pagedJumpTo(charOffset:)`），**不压返回栈**（跳回不是导航历史）。
  final ({String href, int paraIndex})? initialJump;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  ReaderSettings _settings = const ReaderSettings();

  BookMeta? _meta;
  List<Chapter>? _chapters;

  /// 每章**权重估算**（`M-PAGE` T03：全书进度加权；`null` = 尚未取到 /
  /// 该源不支持（PDF/CBZ/CBR）→ 等权退化，与迁移前公式一致）。
  ///
  /// 来源 `BookSource.chapterWeightEstimates()`（**廉价估算**，EPUB = zip 条目
  /// 解压后长度、TXT = 分段长度），`_open()` 内**不阻塞**首帧异步取
  /// （取到前按等权显示，取到后 `setState` 切换；不改变开书时序）。
  ///
  /// ⚠️ 刻意**不用**精确口径 `chapterCharCounts()`：真机 1152 章的书会在主
  /// isolate 上冻住秒级（实测 300 章 = 270ms 停顿）。详见 [_loadChapterWeights]。
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

  /// R1②：用户交互中挂起后台补齐（见 [_pauseAutoFill]）。
  bool _autoFillPaused = false;

  /// [_autoFillPaused] 的**兜底到期**帧计数（见 [_pauseAutoFill] 头注）。
  int _autoFillPauseFrames = 0;

  /// 是否显示「前情回顾」入口（`AI-05` ②：开书时按上次进度时间判定，
  /// 会话内保留；本次阅读会刷新 `progress.updatedAt`，下次开书自然消失）。
  bool _showRecapEntrance = false;

  /// 当前章索引。
  int _currentIndex = 0;

  /// 当前章内进度 `0.0 ~ 1.0`（滚动停止时更新；供副标题与保存使用）。
  double _chapterPos = 0.0;

  /// 每章块的 `GlobalKey`——用于定位当前章与章内位置。
  final Map<int, GlobalKey> _chapterKeys = <int, GlobalKey>{};

  /// 正文滚动区（视口）的 `GlobalKey`——把章块全局坐标换算到视口坐标系。
  /// 正文视口（已让开上下系统栏 / 进度条）。
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

  /// 划词选区（`AI-02`/`AI-03`；null = 无选区）。滚动与翻页起手时清空——
  /// 选区是「某一屏的瞬态」，动了视口就没有继续高亮的理由。
  ParaSelection? _selection;

  /// 选区相对视口（`_viewportKey` Stack）的绘制矩形（操作条定位用；
  /// [_selection] 为 null 时无意义）。
  Rect? _selectionRect;

  /// 长按起手命中的段落（拖拽扩展期间固定在起手段落上）。
  ParagraphHit? _selHit;

  /// 起手词范围（拖拽扩展的锚：新范围 = 两者 min/max 合并）。
  ({int start, int end})? _selAnchor;

  // ── 段落朗读（`TTS-01`/`TTS-02`，M3-T06）────────────────────────────

  /// 朗读控制器（懒建：首次点朗读按钮时 [_ensureTts]）。
  TtsController? _tts;

  /// 当前控制器持有的在线引擎实现（引擎切换 / 失败时释放）。
  OnlineTts? _onlineTtsImpl;

  /// 当前控制器建在在线引擎上（失败提示分流 + 重建判定）。
  bool _ttsEngineOnline = false;

  /// 当前朗读段（`TTS-02` ① 高亮身份；null = 未在朗读）。
  ({int chapterIndex, int paraIndex})? _speaking;

  /// 自动跟随策略（`TTS-02` ③：手动滚动暂停跟随；开读时复位）。
  final HighlightFollow _ttsFollow = HighlightFollow();

  /// 后台播放会话（`TTS-03`，懒建于 [_ensureTts]；编排见 `tts/audio_session.dart`，
  /// 桌面平台 open 失败 → 恒为降级态「仅前台朗读」）。
  TtsAudioSession? _ttsAudio;

  /// 换章重启保护（`TTS-03` ②）：[TtsController.start] 内部先 stop 再开，
  /// 会经 [_onTtsChanged] 闪现「未朗读」——期间不得 end 掉系统会话。
  bool _ttsRestarting = false;

  /// 通知栏 / 锁屏元数据当前章（防同章重复上屏）。
  int _ttsMediaChapter = -1;

  /// `TTS-06` 朗读进度直写坐标：每段朗读推进时记下的**朗读语义真值**。
  ///
  /// 视口可能落后于朗读（跟随被手动滚动暂停）——[_saveProgress]（含
  /// dispose 收尾）优先取它，防陈旧视口坐标覆盖朗读落点；用户重新接管
  /// 视口（手动滚动 / 翻页起手）或程序化改位（[_beginScrollTo] /
  /// [_pagedJumpTo]）即清空，让位回视口语义值。
  ({int chapterIndex, double chapterPos})? _ttsProgress;

  /// `TTS-05` 定时停止计时器（懒建于首次开读；到点停朗读 + 提示）。
  SleepTimer? _sleepTimer;

  /// [ReaderPage.initialJump] 的段落下标：[_open] 解析写入，
  /// [_ensureController] 消费一次（融入恢复链路，不新增跳转竞态）。
  int _jumpPara = -1;

  /// 应用内亮度 `0.2 ~ 1.0`（`TYP-08`；1.0 = 不加遮罩）。
  double _brightness = ReadingPrefs.maxBrightness;

  /// 预设背景色板（`TYP-08`）。
  ReaderBackground _background = ReaderBackground.white;

  /// 书签列表（添加顺序；`TYP-06`）。
  List<Bookmark> _bookmarks = <Bookmark>[];

  /// 沉浸全屏（`TYP-09`）：`true` = 隐藏 AppBar 与底部控制条。
  ///
  /// **默认 `true`**（2026-10-08 负责人拍板「默认改为全屏」）：进阅读页即沉浸。
  /// 顶栏里原来的「进入全屏」按钮（`reader-fullscreen-enter`）与全屏时右上角的
  /// 「退出全屏」浮层按钮（`reader-fullscreen-exit`）**都已移除**——全屏是静息态、
  /// 不再是需要按钮切换的模式；两侧 chrome 一律由点正文**九宫格中宫**唤出
  /// （`reader-chrome-toggle`，落点闸门 [_onContentTapUp]，见 `_buildBody`），
  /// `TYP-09` 验收①「点中宫可唤出与收起」由此承担。
  ///
  /// 不落盘：每次进阅读页都回到全屏静息态（负责人未要求记住 chrome 显隐）。
  ///
  /// 2026-10-09（`TYP-09`，负责人拍板「点中间菜单不应修改阅读区高度」）：chrome
  /// 是**覆盖层**（`extendBody*`，见 [build]）——唤出 / 收起它**不改变正文排版区
  /// 几何**（护栏见 `reader_inset_test.dart` 的同名用例）。因为跳转类入口
  /// （搜索 / 目录 / 书签 / 摘要）落位在**页顶**、会被顶栏压住，故跳转后自动
  /// 收起 chrome（[_exitChrome]）。
  bool _fullscreen = true;

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

  /// 开书门闸挂起中：就绪信号已具备（正文可上屏）但放行条件还没齐
  /// ——转场继续按住，补报点（[_checkOpenGate]）复查后放行。
  ///
  /// 路线 A 纪律②「排到目标页才上屏」（路线 A §7①②）：
  /// ① 估算落位只是过渡帧，`_pendingLand` 二次精确落位完成前不放行——否则
  /// 「估算位置 → 精确位置」的大跳发生在纸张滑入中，就是「开书闪动」主链；
  /// ② 放行时刻视口必须是**真身**（[_viewportReal]）——残留「载入中…」占位带
  /// 时随后「占位→真」换血的高度突变同样发生在滑入中（闪动链②）。
  bool _openGatePending = false;

  /// [_checkOpenGate] 的复查回调已挂上（postFrame 单飞：防回调堆积）。
  bool _openGateCheckScheduled = false;

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

  /// 正文 tap 判定框 key（九宫格中宫闸门 [_onContentTapUp] 取 RenderBox 用）。
  ///
  /// 挂在 `reader-chrome-toggle` 外面的 `KeyedSubtree` 上——`GestureDetector`
  /// 的 key 位已被测试锚点 `Key('reader-chrome-toggle')` 占用，且这里要的
  /// 就是同一块盒（KeyedSubtree 无自身 RenderObject，落点即手势层的盒）。
  final GlobalKey _chromeToggleKey = GlobalKey(debugLabel: 'chrome-toggle-box');

  /// 停稳流程序号：用户再次滚动即作废在途的 async 停稳序列。
  int _pagedStopSeq = 0;

  /// 阅读会话采集器（`STAT-01`）：进页起表、离页 / 切后台收尾；`null` = 不采集。
  ///
  /// 切后台收尾后置空、回前台重建——两次会话、总时长不重复（验收④）。
  SessionTracker? _tracker;

  @override
  void initState() {
    super.initState();
    // 链路点「页面构造」：路由已入栈、本页 State 建立。此点到 `ready` 之间是
    // 纯数据解析段，与渲染段（ready→firstFrame）分开记，避免把两者混为一谈。
    widget.openTrace?.mark('routeInit');
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
    _sleepTimer?.cancel(); // `TTS-05`：关页撤定时（回调防呆双保险）
    _sleepTimer = null;
    // 停朗读（回调经 _disposed 闸不 setState；引擎 stop 为 unawaited 清场）。
    final TtsController? tts = _tts;
    _tts = null;
    if (tts != null) unawaited(tts.stop());
    // 释放在线引擎（`TTS-07`）：HttpClient / 播放器随页收（unawaited 清场）。
    final OnlineTts? onlineImpl = _onlineTtsImpl;
    _onlineTtsImpl = null;
    if (onlineImpl != null) unawaited(onlineImpl.dispose());
    // 撤系统会话（`TTS-03`）：_disposed 闸会拦下 onChanged 里的 end，故在此显式收。
    final TtsAudioSession? ttsAudio = _ttsAudio;
    _ttsAudio = null;
    if (ttsAudio != null) unawaited(ttsAudio.end());
    _finishSession(); // 退出阅读页：停止计时并落库（`STAT-01`；写库只在此与切后台）
    // 先落盘再上报（`SYNC-06`）：进度写完才触发同步，避免云端拿到旧值。
    final SyncTrigger? trigger = widget.syncTrigger;
    final Future<void> saved = _saveProgress();
    if (trigger == null) {
      unawaited(saved);
    } else {
      unawaited(
        saved.whenComplete(() => trigger.onReaderClosed(widget.record)),
      );
    }
    _imageCache.dispose();
    _controller?.dispose();
    // 书源不在这里直接销毁：交回仓库的**复用池**（§2.108）——同一本书再打开时
    // 就是零读盘零解析。池内部按字节上限判定，超限/不可驻留者当场 dispose，
    // 故这条路径恒不泄漏；`repository` 是必填参数（`shelf_page` / 详情页都传）。
    unawaited(widget.repository.recycleBookSource(widget.record, widget.source));
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
      // 切后台也落一次进度（`SYNC-06` 退出 App 上报的真值别停在上次关页）。
      unawaited(_saveProgress());
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
      // ## 开书关键路径（2026-10-08 改：三份 store 并发起跑）
      //
      // 改前是 `load() → chapters() → progress → bookmarks → prefs` 六段**串行**
      // await；探针（`_probe_layout`）实测开书 222ms 里 `reader.stores` 占
      // **130ms（59%）**，而这三份都是互不依赖的小 JSON 读——纯属白等。
      // 现在三份 store 与书源解析**同时起跑**，只 await 首帧真正要用的部分：
      //   · `progress`：决定恢复章节 / 章内位置；
      //   · `prefs`：决定排版参数（字号 / 行距 / 页边距 / 翻页方式）；
      //   · `bookmarks`：首帧用不到 → 同一批 IO 照跑，到手后再 setState 补进树
      //     （顺带把「书签读取失败」从「整本书打不开」降级成「书签暂时没有」）。
      final PerfWatch storesWatch = PerfLog.watch('reader.stores');
      final Future<ReadingProgress?> progressF =
          widget.progressStore.load(widget.record.bookId);
      final Future<ReadingPrefs?> prefsF =
          widget.readingPrefsStore?.load() ?? Future<ReadingPrefs?>.value();
      final Future<List<Bookmark>> bookmarksF =
          widget.bookmarkStore?.load(widget.record.bookId) ??
              Future<List<Bookmark>>.value(const <Bookmark>[]);

      // ## 元数据（含封面解码）**不在首帧关键路径上**（2026-10-20，§2.107）
      //
      // 改前这里是 `await widget.source.load()` 再 `await chapters()`：而 `load()`
      // 内部的 `buildEpubMeta` 会把封面候选**解压出来嗅探图片格式**（最大一块
      // 是 1~3MB 的 JPEG inflate）——首帧一个字都用不到它：`_meta` 唯一的消费者
      // 是 `_title` 的兜底（`record.title` 非空时根本不看）。真机开书 335~509ms
      // 的分解里，这一段属于纯属白等。
      // 现在：首帧只等章节表；`load()` 推迟到首帧上屏后、且**只有书名缺记录时**才跑。
      final PerfWatch chaptersWatch = PerfLog.watch('reader.chapters');
      final List<Chapter> chapters = await widget.source.chapters();
      chaptersWatch.done('count=${chapters.length}');
      // `reader.stores` 现在量的是**关键路径上的净等待**（store 起跑早于
      // `reader.chapters`，源解析期间它们已完成 ⇒ 取值趋 0 即「已不在关键路径上」）。
      final ReadingProgress? progress = await progressF;
      final ReadingPrefs? prefs = await prefsF;
      storesWatch.done('concurrent');
      if (!mounted) return;

      // 书签后到（首帧不等）：到手前按空表显示，不影响开书。
      unawaited(() async {
        try {
          final List<Bookmark> loaded = await bookmarksF;
          if (!mounted || _disposed) return;
          setState(() => _bookmarks = loaded);
        } catch (_) {
          // 书签读取失败：保持空表（不阻断阅读）。
        }
      }());

      // 定位：先按 href（稳定身份）匹配，匹配不到退回 index 并 clamp。
      int index = _resolveIndex(chapters, progress);
      double pos = progress?.chapterPos ?? 0.0;
      // `AI-03` ③ 生词跳回：[ReaderPage.initialJump] 覆盖存档进度（href 匹配
      // 不到则忽略、照常按进度恢复）；段落级落点由 [_ensureController] 消费
      // [_jumpPara]——融入既有恢复链路，不新增并行跳转（无竞态）。
      final ({String href, int paraIndex})? jump = widget.initialJump;
      if (jump != null) {
        final int jumpIndex =
            chapters.indexWhere((Chapter c) => c.href == jump.href);
        if (jumpIndex >= 0) {
          index = jumpIndex;
          // 段落粗估（与 _jumpToLink 同式）：ListView 分支随后按段落 box 精校，
          // 分页分支直接走 charOffset 精确落位。
          pos = math.min(1.0, (jump.paraIndex + 1) / 12.0);
          _jumpPara = jump.paraIndex;
          _paraKeys['$jumpIndex:${jump.paraIndex}'] = GlobalKey();
        }
      }

      setState(() {
        if (prefs != null) {
          _settings = prefs.settings;
          _brightness = prefs.brightness;
          _background = prefs.background;
          _pageTurnMode = prefs.pageMode;
        }
        // `_bookmarks` 不在这里赋值：它是异步后到的（见上面 `bookmarksF`），
        // 首帧按空表渲染、到手后单独 setState 补进（不再阻塞开书）。
        // `_meta` 同理：见 [_loadMetaAfterReady]（首帧后、且只有书名缺记录时才取）。
        _chapters = chapters;
        _currentIndex = index;
        _chapterPos = pos;
        _liveIndex = index;
        _livePos = pos;
        _restoreIndex = index;
        _restorePos = pos;
        _localHint = progress?.localHint;
        // `AI-05` ②：停读 ≥7 天开书出「前情回顾」入口（进度刚读出、还没被
        // 本次会话刷新，updatedAt 仍是上次的时间）。
        _showRecapEntrance = _summaryEnabled &&
            shouldShowRecapEntrance(
              lastReadAtMs: progress?.updatedAt,
              nowMs: DateTime.now().millisecondsSinceEpoch,
            );
        // backlog① 方案 B：恢复目标非书首时，校正全程遮罩（从头开书首帧即到位，不遮）。
        _restoreMask = index != 0 || pos > 0;
        // 章块 key **不预分配**（§2.107）：旧实现在这里
        // `for (i < chapters.length) _chapterKeys[i] = GlobalKey()`，1152 章的书
        // 一次开书就要造 1152 个 GlobalKey，而首帧真正进树的只有窗口那几章——
        // 其余全是白烧的分配。改为 `_chapterKeyAt(index)` 按需懒建（同一 index
        // 复用同一 key，`putIfAbsent` 保证稳定）。
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
          // 修法③「冷缓存收口」（路线 A §7③）：
          // 调度器按书**进程级驻留**（[sharedPaginationSchedulers]），重开书
          // 命中定稿页表、一次精确落位——不再随 State 新建冷缓存（开书闪动
          // 机制链③）。`unfreeze()`：上一 State 若在翻页动画中被 dispose，
          // 冻结态会跨开书残留（`stepIdle` 有活不动）。
          _scheduler = sharedPaginationSchedulers
              .forBook(widget.record.bookId)
            ..unfreeze();
          _restoreMask = false; // 分页一次落位、无可见中间跳转
        }
      });
      // 开书到「首帧可渲染」的总时长（用户感知的等待上限；恢复校正另计 restore.*）。
      PerfLog.step('reader.ready', openClock.elapsedMilliseconds,
          'target=$index pos=${pos.toStringAsFixed(3)} chapters=${chapters.length} paged=$paged');
      // 链路点「数据就绪」+ **立刻挂首帧探针**：
      // 上面的 `reader.ready` 打在 setState 之后、正文尚未 build/layout/paint，
      // 用户屏幕上仍是空白。探针量到的那一帧才是「看到书」，两者之差即渲染段。
      widget.openTrace?.mark('ready', 'paged=$paged chapters=${chapters.length}');
      widget.openTrace?.attachFirstFrameProbe();
      // 放行开书转场的纸张滑入（`ReaderOpenTransition`）。**必须等下一帧真正上屏**：
      // 此刻正文还没被 paint，提前放行会让纸张带着一张空白滑进来——那正是
      // 「打开书闪一下」的成因。分页模式再加一道门闸（`requireLanded`）：
      // 精确落位收敛才放行（估算落位的视口大跳不许发生在滑入中）。
      // 无门闸（深链 / 测试直进）时是 no-op。
      _signalOpenReady(requireLanded: paged);
      // 元数据后到（不阻塞首帧；见 [_loadMetaAfterReady]）。
      _loadMetaAfterReady();
      if (!paged) _scheduleEstimateRefresh(); // 估高只服务 ListView
      // **不在此处启动后台补齐**（`PERF-02` 时序修正 2026-09-28）：补齐会逐批
      // 「占位→真实」合入、改动总高，而此刻控制器还没建、首次恢复校正也还没跑
      // （真机日志：本行让 9 批合入抢在 `restore.begin` 之前，全部
      // `layout.reanchor anchored=false` 空重锚，恢复期总高被改）。
      // 补齐统一由 [_finishRestore] 触发——先落定、后补齐。
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
      // 失败也要放行滑入——否则纸张会一直停在屏幕右侧之外，
      // 用户盯着书架以为卡死了（转场被「按住」时没有任何其他退出路径）。
      _signalOpenReady();
    }
  }

  /// 首帧后补取元数据（**只在该取时才取**）。
  ///
  /// `_meta` 唯一的消费者是 [_title] 的兜底：`record.title` 非空时永远不看它。
  /// 而 `source.load()` 内部（`buildEpubMeta`）会把封面候选**解压出来嗅探图片
  /// 格式**（常见 1~3MB JPEG inflate）——首帧一个字都用不到。故把它整体移出
  /// 开书关键路径：书名有记录时一次都不跑，缺记录时才在首帧之后补，到手后
  /// `setState` 补进（此时正文早已上屏，用户无感）。
  ///
  /// 失败静默：`_title` 会回落到「阅读」，不影响任何阅读行为。
  void _loadMetaAfterReady() {
    if (widget.record.title.isNotEmpty) return;
    unawaited(() async {
      try {
        final PerfWatch watch = PerfLog.watch('reader.load');
        final BookMeta meta = await widget.source.load();
        watch.done('deferred impl=${widget.source.implId}');
        if (!mounted || _disposed) return;
        setState(() => _meta = meta);
      } catch (_) {
        // 元数据取不到不影响阅读。
      }
    }());
  }

  /// 报「阅读页就绪」，放行开书转场的纸张滑入。
  ///
  /// 走**帧回调**而不是直接调：`_ready` 的 `setState` 之后这一帧还没绘制，
  /// 放行早了纸张会带着一张空白滑进来。也刻意不用 `Future.delayed`——
  /// `testWidgets` 跑在 `FakeAsync` 里，定时器会在页面 dispose 后留下未清挂起物。
  ///
  /// [requireLanded]：分页模式的「就绪」= **目标语义坐标精确落位收敛** 且
  /// **视口真身**（路线 A 纪律②，路线 A §7①②）。
  /// 估算落位只是过渡帧——`_pendingLand` 二次精确落位完成前不放行，挂
  /// [_openGatePending] 等补报点（[_checkOpenGate]）复查；3s 兜底
  /// （`kReaderOpenHoldTimeout`）仍是「漏报就绪不卡死」的最后防线。
  void _signalOpenReady({bool requireLanded = false}) {
    if (requireLanded && !_positionConverged) {
      _openGatePending = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || _disposed) return;
      ReaderOpenTransition.signalReady();
    });
    // 帧回调要等**下一帧**才跑；收敛点可能在帧外（postFrame 阶段 / 微任务）
    // 触发，不补调度帧回调会饿死到 3s 兜底（[_startPagedFrames] 同款处理）。
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 开书门闸补报：[_openGatePending] 期间每次收敛 / 换视图都来戳一下，
  /// **postFrame 复查**放行条件后补发就绪信号（幂等：放行过 / 未挂起时 no-op）。
  ///
  /// 复查放在 postFrame（而不是调用点当场判）有两个原因：
  ///   · [_applyPagedViews] 的 setState 之后布局还没重建，当场读到的是旧视图；
  ///   · [_jumpPaged] 超域目标的帧末 clamp 也是 postFrame 回调、注册更早
  ///     （[_primeOpenSync] 收敛点在 `_jumpPaged` 之后才戳本方法）——本回调
  ///     后注册后执行，读到的像素已是 clamp 后的「放行时刻现场」。
  /// 复查不过（落位反复 / 占位带还在视口里）就保持挂起，等下一个戳点
  /// （[_syncPagedViews] 换视图后必戳）再查；单飞标记防回调堆积。
  void _checkOpenGate() {
    if (!_openGatePending || _openGateCheckScheduled) return;
    _openGateCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _openGateCheckScheduled = false;
      if (!mounted || _disposed || !_openGatePending) return;
      if (!_positionConverged || !_viewportReal()) return;
      _openGatePending = false;
      ReaderOpenTransition.signalReady();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 「视口真身」判据（路线 A 纪律②，路线 A §7②）：
  /// 可见区间 `[pixels, pixels + 视口高)` 内没有「载入中…」占位带。
  ///
  /// 占位带 = [PagedChapterView.pages] 为空的窗口视图（未分页章只占
  /// [_placeholderBandHeight] ≈96dp 一条带，区间 `[章顶, 章顶 + headingHeight)`）。
  /// 空段章（一张空页、`pages` **非空**）是真身，不挡放行——真身判据与
  /// [_buildPageViews] 同源，刻意不看段落数。
  ///
  /// 量不到现场（滚动体 / 视口未挂）时放行（`true`）：宁可早放也不把门闸
  /// 死等到 3s 兜底，「漏报就绪不卡死」优先。本判据只管放行时机，**不约束
  /// 窗口形状**——`_repairReachable` 的扩窗红线（窗口不加上界）不变。
  bool _viewportReal() {
    final PagedScrollerState? scroller = _scroller;
    final double vh = _viewportHeight;
    if (scroller == null || vh <= 0) return true;
    final PagedLayout layout = scroller.layout;
    final List<PagedChapterView> views = _pageViews;
    final double top = scroller.offset;
    final double bottom = top + vh;
    for (int i = 0; i < views.length && i < layout.chapterTops.length; i++) {
      if (views[i].pages.isNotEmpty) continue;
      final double bandTop = layout.chapterTops[i];
      final double bandBottom = bandTop + views[i].headingHeight;
      if (bandTop < bottom && bandBottom > top) return false;
    }
    return true;
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
      // `AI-03` ③ 生词跳回：段落 → 章内字符偏移（与 _jumpToLink 同式），
      // 交给 _pagedJumpTo 精确一次落位；消费一次（正常开书 jumpPara 恒 -1）。
      final int jumpPara = _jumpPara;
      _jumpPara = -1;
      int? jumpChar;
      if (jumpPara >= 0) {
        final List<String> paras =
            _cache.peek(_restoreIndex)?.paragraphList ?? const <String>[];
        int offset = 0;
        for (int p = 0; p < jumpPara && p < paras.length; p++) {
          offset += paras[p].length;
        }
        jumpChar = offset;
      }
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
        unawaited(_pagedJumpTo(
          restoreIndex,
          pos: restorePos,
          charOffset: jumpChar,
          saveOld: false,
        ));
      });
      return;
    }
    // ListView：同款消费 initialJump 段落（融进恢复参数，[_restoreStep] 按
    // 段落 box 精校；正常开书 jumpPara 恒 -1，行为一字不变）。
    final int jumpPara = _jumpPara;
    _jumpPara = -1;
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
      _beginScrollTo(_restoreIndex, _restorePos, paraIndex: jumpPara);
      return;
    }
    // 回退分支（backlog① 方案 A）：同版面时 seed，否则 0。
    final double seed = sameLayout ? hint.scrollOffset : 0.0;
    _controller = ScrollController(initialScrollOffset: seed);
    PerfLog.mark('reader.seed',
        'branch=${sameLayout ? 'fallback-seed' : 'zero'} seed=${seed.toStringAsFixed(1)}');
    _beginScrollTo(_restoreIndex, _restorePos, paraIndex: jumpPara);
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
    _ttsProgress = null; // `TTS-06`：程序化改位 → 朗读坐标让位给新落点
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
    // 链路点「位置落定」：首帧早已上屏，但内容可能还停在估算位置；到这一行
    // 才真正停在目标段落。它不进 `open.total`（那量的是「看到书」），
    // 只作为「打开后是否还在跳」的观感指标。
    widget.openTrace?.mark('restoreEnd',
        'frames=$_restoreFrames converged=$converged');
    // 首帧早已上报 `open.total`；这里补一条 `open.chain`，把「上屏之后又花了
    // 多久才停在目标段落」也纳入账——`chain` 与 `total` 的差即位置漂移耗时。
    widget.openTrace?.reportChain();
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
    _pauseAutoFill(); // R1②：用户滚动中挂起后台补齐（带时限，见 _pauseAutoFill）
    if (notification.dragDetails != null) {
      _ttsFollow.noteManualScroll(); // `TTS-02` ③ 手动滚动暂停自动跟随
      _ttsProgress = null; // `TTS-06`：视口被用户接管 → 朗读坐标让位
    }
    _clearSelection(); // 滚动起手清选区（无选区时空转）
    _updateLiveProgress();
    return false;
  }

  /// 章块的 `RenderBox`（未布局 / 不在缓存内时为 `null`）。
  ///
  /// 取 key 时用 [_chapterKeyAt]（懒建）：未进入过树的章没有 key，返回 `null`
  /// 与「已挂但未布局」同义——两条路径的消费方本来就按「拿不到 box = 未知高」处理。
  RenderBox? _chapterBoxAt(int index) {
    final BuildContext? ctx = _chapterKeys[index]?.currentContext;
    if (ctx == null) return null;
    final RenderObject? object = ctx.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }

  /// 第 [index] 章的稳定 `GlobalKey`（首次使用时创建）。
  ///
  /// 替代旧实现「开书时一次性给全书每章预分配 GlobalKey」——那对 1000+ 章的书
  /// 是纯浪费（只有窗口内几章会真正进树）。`putIfAbsent` 保证同一 index 拿到的
  /// 永远是同一个实例，故 Element 复用语义与预分配版**完全一致**。
  GlobalKey _chapterKeyAt(int index) => _chapterKeys.putIfAbsent(
        index,
        () => GlobalKey(debugLabel: 'reader-chapter-$index'),
      );

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
    _resumeAutoFillIfIdle(); // R1②：交互结束 → 恢复补齐
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

  /// R1②：用户交互中挂起后台补齐（滚动 / 拖动 / 翻页）。
  ///
  /// 补齐只为**预热邻章**（`PERF-02` 的内存收敛口径），晚几秒开始没有任何
  /// 正确性影响；而 CPU Profiler 实测它占补齐阶段 **56% 的纯 CPU**
  /// （见 [_autoFillLoop] 头注）——用户正在翻页时这些 CPU 应当让位。
  ///
  /// ##⚠️ 必须带时限兜底（2026-10-06，被 `reader_page_test` 回归④ 打回）
  ///
  /// 初版只有「[_onScrollEnd] 恢复」一条路径，**结果补齐被永久挂起**：
  /// 回归④ 用 `tester.drag(...)` 制造滚动，但**滚动通知链里 `_onScrollEnd`
  /// 并未按预期送达**（`drag` 结束后视口已被拖动逻辑接管），于是
  /// `_autoFillPaused` 永远为 `true` ⇒ 上方章的占位永不换真
  /// ⇒ `expect(find.text('第一章'), findsOneWidget)` 判红。
  ///
  /// 教训：**「靠某个事件恢复」必须同时有「靠时间恢复」的兜底**——事件可能不来
  /// （手势被接管、通知被拦截、页面路径不同），而时间一定会到。
  /// 2s 取「一次连续滚动通常不超过」的量级：既让滚动期间的 CPU 让位，
  /// 又保证任何路径下补齐都会自己恢复。
  void _pauseAutoFill() {
    _autoFillPaused = true;
    // 兜底恢复：不用定时器（见 [_idleGap] 的定时器坑），改用帧计数——
    // 每次 pause 重置计数，[_autoFillLoop] 每轮检查，到期自动恢复。
    _autoFillPauseFrames = kAutoFillPauseFrames;
  }

  /// R1②：交互结束后恢复补齐（若当前窗口还没补齐）。
  void _resumeAutoFillIfIdle() {
    if (!_autoFillPaused) return;
    _autoFillPaused = false;
    _ensureAutoFill();
  }

  /// 后台补齐循环：每批 [kLoadBatchSize] 章，逐批合入（经 [_applyLayoutChange]
  /// 做语义重锚）；直到「当前窗口内全部驻留」为止。滚动后由 [_ensureAutoFill] 再触发。
  ///
  /// ## R1：批次间让出帧 + 空闲门（2026-10-06，CPU Profiler 定案，见§2.69 附九）
  ///
  /// Profiler 实测：补齐阶段的 `RegExp` 占 **34.9%**、HTML 词法 15%、日志 7%
  /// ⇒ 后 820ms 里 **478ms（56%）是纯 CPU 空转**，且按 50ms 分桶**均匀分布**
  /// （每桶稳定 17~23ms）——它不卡首屏，但**持续吃电与发热**。
  ///
  /// 两处调整（**不改动任何正确性逻辑**：补齐范围、批大小、落库时机全不变）：
  /// ① **批次间让出一帧**（[_idleGap]）：一批 `extractSection` 是长同步段，
  ///    批间让出控制权，使下一帧绘制与用户输入有机会被处理，而不是连续占住
  ///    主isolate；
  /// ② **不在交互中补**（[_autoFillPaused]）：用户滚动 / 拖动 / 翻页期间挂起，
  ///    由 [_resumeAutoFillIfIdle] 在交互结束（停稳 [_onScrollEnd] 等）后恢复，
  ///    **并有帧计数兜底**（[kAutoFillPauseFrames]）——事件可能不来（手势被接管、
  ///    通知被拦截），时间/帧一定会到。补齐只为「预热邻章」，晚几秒无正确性影响。
  Future<void> _autoFillLoop() async {
    int batches = 0;
    final Stopwatch clock = Stopwatch()..start();
    try {
      while (mounted && !_disposed) {
        final ChapterAutoLoader? loader = _loader;
        if (loader == null) return;
        // R1②：交互中不补（滚动/拖动/翻页优先级高于预热）。
        //
        // 「挂起」不是 `return` 了事——那样循环直接退出、计数永不递减、兜底恢复
        // 形同虚设（初版正是这样把 `reader_page_test` 回归④ 判红：占位永不换真）。
        // 也不能裸`continue`——那会变成**忙等死循环**（没有 await 让出事件循环）。
        // 正确做法：**挂起时让出一帧再进下一轮**，计数随之递减，到期自动恢复。
        if (_autoFillPaused) {
          if (--_autoFillPauseFrames <= 0) _autoFillPaused = false;
          await _idleGap();
          continue;
        }
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
          // R1①：批间让出一帧再继续下一批。
          await _idleGap();
          if (!mounted || _disposed || _autoFillPaused) return;
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
        // R1①：批间让出一帧再继续下一批。
        await _idleGap();
        if (!mounted || _disposed || _autoFillPaused) return;
      }
    } finally {
      _fillRunning = false;
    }
  }

  /// R1①：批次之间让出**一帧**（R1① 的实现）。
  ///
  /// ## 三次迭代的教训（2026-10-06，都是被测试打回来的）
  ///
  /// ① `Future<void>.delayed(4ms)` → **测试判红**：`testWidgets` 跑在 `FakeAsync`
  ///    里，页面 dispose 后仍留下**未清的定时器**
  ///    ⇒ `A Timer is still pending even after the widget tree was disposed`。
  /// ② 只用 `SchedulerBinding.addPostFrameCallback` → **测试判红**（回归④
  ///    「第一章」消失）：静止态（无 `pump`）下**没有下一帧**，回调永不触发
  ///    ⇒ 补齐循环**死锁**，占位永不换真。**这是比①更严重的功能缺陷。**
  /// ③ 现方案：**微任务 + 帧回调双保险**。
  ///
  /// 微任务（`scheduleMicrotask`）保证**控制权立刻还给事件循环**（后续
  /// `scheduleFrameCallback` / 定时器 / 用户事件都能排进来），且**不留挂起
  /// 定时器**、**不依赖帧**（静止态也能推进）——① ② 两个坑同时避开。
  /// `scheduleFrameCallback` 则保证「至少让出一帧」：真机上帧驱动下，微任务
  /// 只让出一个事件循环回合，渲染仍可能被排在同一批，故额外挂一个帧回调，
  /// 下一帧真正开始绘制时补齐才继续。
  ///
  /// `[kAutoFillIdleGap]` 因此不再需要固定时长（已删除该常量）。
  Future<void> _idleGap() {
    if (!mounted || _disposed) return Future<void>.value();
    final Completer<void> micro = Completer<void>();
    // 帧回调：让「下一帧真正开始绘制」成为继续的前置条件（只在有帧时生效）。
    SchedulerBinding.instance.scheduleFrameCallback(
      (_) {
        if (!micro.isCompleted) micro.complete();
      },
      rescheduling: false,
    );
    // 微任务：无论有没有帧，都至少让出一次事件循环。
    scheduleMicrotask(() {
      if (!micro.isCompleted) micro.complete();
    });
    return micro.future;
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

  /// 章标题占高（测量与渲染**同源**）：TextPainter 行高 + 留白链
  /// （[_kHeadingGapTop] 章间空行 + [_kHeadingGapBottom] 题文呼吸）。
  double _headingHeightOf(int index, PaginationConfig cfg) {
    if (_headingTextStyle == null) return 0;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: _headingTitle(index), style: _headingTextStyle),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(cfg.textScaleFactor),
    )..layout(maxWidth: cfg.pageWidth);
    final double height = painter.height;
    painter.dispose();
    return height + _kHeadingGapTop + _kHeadingGapBottom;
  }

  /// 章标题 widget（与 [_headingHeightOf] 同一文本 / 样式 / 缩放）。
  ///
  /// 2026-10-09 负责人拍板（改 `TYP-04`「标题居中」旧口径）：**左对齐、加粗、
  /// 不要横线**；章间空行隔离 = 标题块顶部 [_kHeadingGapTop] 空档——每个章
  /// 标题块都带，章与章之间因此恒隔一个空行（此前分页长卷里两章几乎贴着）。
  Widget _headingWidget(int index, PaginationConfig cfg) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: _kHeadingGapTop),
        Text(
          _headingTitle(index),
          textAlign: TextAlign.left,
          textScaler: TextScaler.linear(cfg.textScaleFactor),
          style: _headingTextStyle,
        ),
        const SizedBox(height: _kHeadingGapBottom),
      ],
    );
  }

  /// 未分页占位块的高度：**章标题占高 + 一行「载入中」+ 呼吸**。
  ///
  /// ## ⚠️ 改前 = `cfg.pageHeight`（整屏）——2026-10-08 改（真机「章节间有大段空白」）
  ///
  /// 滚动是**连续长卷**：每个还没排完版的章都先占一整屏空白，用户往下滚时看到
  /// 的就是「上一章正文 → 一整屏空白（只有中间一行『载入中』）→ 下一章正文」。
  /// 更糟的是**占位→真实的章高突变**：占位 1 屏（探针实测 572）→ 真实章 N 屏
  /// （同夹具实测 2727，约 4.8 倍），这是滚动跳动最大的单一来源（与
  /// `_applyPagedSample` 的陈旧章内比例叠加后，视口会直接落到新章末尾）。
  ///
  /// 小占位块把两件事同时压小：空白从「一整屏」变成「一行」，高度突变从
  /// 4.8 倍压到同一量级——真实章高由测量得出后仍走既有语义重锚（
  /// `_applyPagedViews` 的 `chapterTops` 差补偿），机制不变。
  ///
  /// 占位语义（`Center('第 N 章 · 载入中…')`）刻意**不**换成真标题：占位块
  /// 与真章的区分是多条既有用例的判据（`reader_page_test` 回归①靠
  /// 「占位块只显示载入中、无正文段落」判「第 1 章还没补齐」）。
  double _placeholderBandHeight(int index, PaginationConfig cfg) {
    final double line = (cfg.textStyle.fontSize ?? 16) *
        (cfg.textStyle.height ?? 1.2) *
        cfg.textScaleFactor;
    return _headingHeightOf(index, cfg) + line + 24;
  }

  /// 构建窗口章视图：正文 + 分页结果都有 → 真视图；否则占位章
  /// （headingHeight = [_placeholderBandHeight]——**不再是整页高**）。
  List<PagedChapterView> _buildPageViews(
      List<int> window, PaginationConfig cfg) {
    final List<Chapter>? chapters = _chapters;
    final List<PagedChapterView> out = <PagedChapterView>[];
    if (chapters == null) return out;
    for (final int i in window) {
      if (i < 0 || i >= chapters.length) continue;
      final ChapterContent? content = _cache.peek(i);
      final PaginatedChapter? pag = _paginatedOf(i);
      // ## ⚠️ 真身判据 = 「内容已就绪 + 页表已出」，**刻意不看段落数**
      // （2026-10-09，真机「初次打开《枭臣》章间卡住一条『载入中…』」）
      //
      // 分章产物里存在**定稿的空段章**（如 TOC 规则把孤行「正文」切成一章、
      // 正文区间只有空行 ⇒ `_splitParagraphs` 后 0 段）。分页内核对空章天生
      // 一页空页（`PageBreaker.paginate`「每章至少一页」，`IncrementalPaginator`
      // 空段构造即完成），它就是「**只有章标题**」的真身块。判据若掺
      // `paragraphList.isNotEmpty`，空段章会**永驻**「载入中…」占位——把
      // 「这一章没有正文」错当成「正文还没来」。
      if (content != null &&
          content.imagePages == null &&
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
          headingHeight: _placeholderBandHeight(i, cfg),
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
        if (!_primeOpenSync(
            charOffset: _currentCharOffset(), keepScrollRemainder: true)) {
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
  ///
  /// [keepScrollRemainder]：自然滚动停手 / reprime 重锚时必须置 `true`——
  /// 见 [_scrollRemainderOf]；程序化落位（开书恢复 / 跳章 / 跳书签 / 跳目录 /
  /// 搜索命中）保持默认 `false` = **行顶对齐**（`§2.70` 语义）。
  bool _primeOpenSync({
    required int charOffset,
    bool keepScrollRemainder = false,
  }) {
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
    // ## ⚠️ 自然停手必须保留「行内像素余量」（2026-10-09 真机「每次滚动都跳动」）
    //
    // `offsetFor` 落位口径 = **页顶 + 目标行行顶**（`§2.70`，为「开书/跳转后
    // 不从半行开始读」而设）。但**自由滚动**的视口顶几乎不会正好落在行顶，于是
    // 每次停手都被吸附过去一次：内容整块下移「该行已被滚过的余量」⇒ 顶端原本
    // 被切掉上半截的那一行**突然露全**。探针实测（`_probe_scroll_jump_test`）
    // 连续四次停手位移恒为 **−12.0px**。
    //
    // 语义上「用户滚到哪就是哪」，`§2.71` 已定「视口顶落在行中间」不是缺陷——
    // 故把余量补回行顶，等于**位置没动**。布局未变时 `landAt_new == lineTop`
    // ⇒ 目标值与现场像素**恰好相等** ⇒ [`_jumpPaged`] 因 `|Δ| < 0.01` 直接
    // 跳过，位移为 0；布局真变了（章顶移动 / 页表增长）时仍按语义坐标跟着走。
    final double remainder = keepScrollRemainder
        ? (_scrollRemainderOf(href, charOffset) ?? 0.0)
        : 0.0;
    final ChapterContent? prev =
        index > 0 ? _cache.peek(index - 1) : null;
    final ChapterContent? next =
        index + 1 < chapters.length ? _cache.peek(index + 1) : null;
    // 邻章可分页 = 已就绪的文本章（**空段章也算**——它有一张空页的定稿页表，
    // 不登记就永远成不了真身；见 [_registerWindowUnpaginated] 同注）。
    final bool prevOk = prev != null && prev.imagePages == null;
    final bool nextOk = next != null && next.imagePages == null;
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
    double? landAt = PagedScrollerState.offsetFor(
      layout,
      views,
      href,
      charOffset,
      paragraphSpacing: cfg.paragraphSpacing,
    );
    final bool landed = landAt != null;
    if (landAt == null) {
      // 页表未覆盖目标（占位/部分页）：按窗口位置 + 章内比例估算落位，
      // 挂 pending 等空闲帧补完后二次精确落位（`RC1`：期间不写盘）。
      final int total = PagePaginator.charCountOf(content.paragraphList);
      final double frac = total > 0
          ? (charOffset / total).clamp(0.0, 1.0)
          : _chapterPos.clamp(0.0, 1.0);
      final int windowPos = _window.indexOf(index);
      // 目标章之前的窗口章高**直接取布局表的章顶**（不再按「每章一屏」估：
      // 占位块自 2026-10-08 起不是整页高，按 `pageHeight` 估会高估数倍）。
      // 目标章自身的章内偏移仍是 `frac × 页高` 的粗估——它的真实页表还没出来，
      // 随后由 `_pendingLand` 的二次精确落位收敛（`RC1`）。
      landAt = ((windowPos < 0 ? 0.0 : layout.chapterTops[windowPos]) +
              frac * cfg.pageHeight)
          .clamp(0.0, double.infinity);
      _pendingLand = (index: index, charOffset: charOffset);
      _positionConverged = false;
      _positionSampled = false;
      PerfLog.mark('paged.estimate',
          'index=$index char=$charOffset off=${landAt.toStringAsFixed(0)}');
    } else {
      // 行内余量只补在**精确落位**上：估算落位（上一分支）本来就是粗的，
      // 补余量没有意义，其二次收敛（`_syncPagedViews(tryPendingLand: true)`）
      // 属程序化落位、按行顶对齐即可。
      landAt += remainder;
      // `at` = 落位**前**的现场像素：`off - at` 就是这一次落位真正造成的位移
      // （真机排查用；布局未变时二者必须相等，差 0 = 用户看不见移动）。
      // 域外被验收拦下时本条后面**没有** `paged.move`（跳转被抑制、
      // 等帧链补完后由 `paged.land` 收口）——排查时以此判「deferred」。
      PerfLog.mark(
          'paged.prime',
          'index=$index char=$charOffset off=${landAt.toStringAsFixed(0)}'
          '${remainder == 0 ? '' : ' rem=${remainder.toStringAsFixed(1)}'}'
          ' at=${_pagedPixelsOrNull()?.toStringAsFixed(0) ?? '-'}');
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
    // 精确落位收口（可达性验收，见 [_landingReachable]）：可达 / 真书尾 →
    // 清 pending、宣告收敛；域外且分页仍在生长 → 不收敛、不跳截短中间位，
    // 挂回 [_pendingLand] 等帧链补完后 `_syncPagedViews` 二次收口。
    if (landed) {
      if (_landingReachable(landAt, layout)) {
        _pendingLand = null;
        _positionConverged = true; // `RC1`：一次精确落位即收敛
      } else {
        _pendingLand = (index: index, charOffset: charOffset);
        _positionConverged = false;
        _positionSampled = false;
        landAt = null;
        _startPagedFrames();
      }
    }
    if (cfgChanged || sig != _viewsSignature) {
      _applyPagedViews(views, cfg, sig, offset: landAt);
    } else if (landAt != null) {
      _jumpPaged(landAt, why: 'prime');
    }
    // 精确落位即收敛（上面 `landed` 分支已置 `_positionConverged`）→
    // 开书门闸在此补报放行（估算分支挂 `_pendingLand`，等 [_syncPagedViews]）。
    _checkOpenGate();
    return landed;
  }

  /// 视口顶相对「其所在行行顶」的像素余量（**自然滚动停手**再锚定用）。
  ///
  /// ## 为什么需要它（2026-10-09 真机「每次滚动，顶部文字显示一半，弹跳一下显示全部」）
  ///
  /// 落位口径 [`PagedScrollerState.offsetFor`] = 页顶 + **目标行行顶**，这是为
  /// **程序化落位**定的（开书恢复 / 跳章 / 跳书签 / 跳目录 / 搜索命中都要「从这一行
  /// 开始读」而不是从半行，见 `§2.70`）。但**自由滚动**的视口顶几乎不会正好落在行顶，
  /// 于是每次停手都被吸附一次：内容整块下移「该行已被滚过的余量」⇒ 顶端那行突然露全。
  /// 探针实测连续四次停手位移恒为 **−12.0px**（`_probe_scroll_jump_test`）。
  ///
  /// `§2.71` 已定「视口顶落在行中间」是连续排版的固有形态、**不是缺陷**；语义上
  /// 「用户滚到哪就是哪」。故把余量补回行顶 = **位置没动**：
  ///   · 布局未变 ⇒ `landAt_new == lineTop` ⇒ 目标值与现场像素**恰好相等** ⇒
  ///     [`_jumpPaged`] 被 `|Δ| < 0.01` 挡掉，位移为 0；
  ///   · 布局真变了（章顶移动 / 页表增长）⇒ 目标值随语义坐标一起移动，且保住
  ///     行内位置——比「跳到行顶」更贴近用户预期。
  ///
  /// 返回 `null` = 不可得（无滚动体 / 采样 href 对不上 / 数值异常）→ 调用方按
  /// 行顶对齐落位（等价改前行为，不做无依据的平移）。
  ///
  /// 上下界取 `±cfg.pageHeight` 作防御：采样已与落位共用行表口径（§2.84），
  /// 布局未变时余量恒等于「视口顶 − 所在行行顶」（0 ~ 行高，视口顶在段间距
  /// 空白时为负、|rem| ≤ 段间距），clamp 不会触发；但布局突变后（章顶移动 /
  /// 重排）行表已换代，旧行表余量可能越界——夹到一页以内，不至于把落点甩出
  /// 可视范围。
  double? _scrollRemainderOf(String href, int charOffset) {
    final PagedScrollerState? scroller = _scroller;
    final PaginationConfig? cfg = _pageConfig;
    if (scroller == null || cfg == null) return null;
    if (!scroller.scrollController.hasClients) return null;
    final double? lineTop = scroller.offsetForCharOffset(href, charOffset);
    if (lineTop == null) return null;
    final double rem = scroller.scrollController.offset - lineTop;
    if (rem.isNaN || rem.isInfinite) return null;
    return rem.clamp(-cfg.pageHeight, cfg.pageHeight).toDouble();
  }

  /// 现场滚动像素（滚动体未附着 → `null`；只用于日志）。
  double? _pagedPixelsOrNull() {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return null;
    return controller.position.pixels;
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

  /// 程序化跳转序号（[`_jumpPaged`] 每次调用 +1；陈旧延迟 clamp 的作废判据）。
  int _jumpSeq = 0;

  /// 单跳到 [target]：|Δ|<0.01 跳过；在旧上界内立即跳（pre-jump），
  /// 超出则帧末补跳（setState 后新布局已建，接受 1 帧滑移——
  /// 同帧先跳会被旧 `maxScrollExtent` 弹簧拉回）。
  ///
  /// [why] 只进日志（`paged.move`）：真机「跳动」排查需要**每一条程序化位移**
  /// 都留痕，光看 `paged.prime` 分不清「算出来的目标」与「真的跳了」。记的是
  /// **实际**前后值，故 `d` 就是用户看到的那次平移量。
  ///
  /// ## ⚠️ 延迟补跳必须带序号作废（2026-10-12 回归①③判红实证）
  ///
  /// 帧末 clamp 回调执行时，世界可能已被**更新的跳转**改写：实测
  /// `paged.move why=views from=0 to=1544`（收敛落位，正确）之后又来
  /// `why=views.late from=1544 to=888`——后者是更早排队的陈旧目标
  /// （占位→真合入期 delta 重锚的 888），回调晚到一步把**已收敛的落点
  /// 拖回旧目标**，采样从此停在错章（章 0 尾）。故回调开头先比
  /// [`_jumpSeq`]：期间有任何更新的跳转即作废（`skip=superseded`），
  /// 新意图永远压过旧意图，「clamp 截短/拖回 + 永不重试」的又一变体。
  void _jumpPaged(double target, {String why = 'prime'}) {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return;
    final double pixels = controller.position.pixels;
    final int seq = ++_jumpSeq;
    if ((target - pixels).abs() < 0.01) return;
    if (target >= 0 && target <= controller.position.maxScrollExtent) {
      _notePagedMove(why, pixels, target, seq: seq);
      _pagedOp(() => controller.jumpTo(target));
      return;
    }
    PerfLog.mark(
        'paged.move',
        'why=$why.q seq=$seq tgt=${target.toStringAsFixed(1)} '
        'px=${pixels.toStringAsFixed(1)} '
        'max=${controller.position.maxScrollExtent.toStringAsFixed(1)}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      if (seq != _jumpSeq) {
        PerfLog.mark('paged.move', 'why=$why.late seq=$seq skip=superseded');
        return;
      }
      final double clamped = target
          .clamp(0.0, controller.position.maxScrollExtent);
      if ((clamped - controller.position.pixels).abs() < 0.01) return;
      _notePagedMove('$why.late', controller.position.pixels, clamped,
          seq: seq);
      _pagedOp(() => controller.jumpTo(clamped));
    });
  }

  /// 记一条程序化位移（**唯一**留痕点：`paged.move`）。
  void _notePagedMove(String why, double from, double to, {int? seq}) {
    PerfLog.mark(
        'paged.move',
        'why=$why${seq == null ? '' : ' seq=$seq'} '
        'from=${from.toStringAsFixed(1)} '
        'to=${to.toStringAsFixed(1)} d=${(to - from).toStringAsFixed(1)}');
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
    // ## ⚠️ 这里**不能**给窗口加上界（2026-10-09 实测，反向证据）
    //
    // 未排页表的章只贡献一条 `_placeholderBandHeight`（≈96dp）占位带，`totalHeight`
    // 因此很难够到 `anchor + vh` ⇒ 该循环会多 append 出约 `ceil(vh / 96)` 章。
    // 看起来该收口（并会让分页缓存 LRU 挤掉当前章），但把窗口压到缓存容量
    // （5 章）后 `reader_page_test` 回归②（深章节恢复）立刻判红：窗口布局总高
    // 小于视口时 `maxScrollExtent == 0`，`_jumpPaged` 的目标被 clamp 成 0 且
    // 「与现场相等 ⇒ 直接 return」，**落位被静默丢弃且永不重试**（无 `paged.move`
    // 留痕），目标章自然进不了视图。真正该修的是「淘汰不能碰正在渲染的章」——
    // 见 `PaginationCache.setProtected`；窗口多 append 只是浪费，不是错。
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

  /// 落位可达性验收（`paged.land` / `paged.prime` 的收敛前置；`RC1` 同门）：
  /// 目标行下方必须还有 ≥ 视口高的布局内容（`landAt ≤ maxScrollExtent`）。
  ///
  /// ## ⚠️ 为什么必须验收（2026-10-12 探针 `_probe_landing` 实证）
  ///
  /// `offsetFor` 只要页表覆盖目标行就返回值，**不要求目标可滚动到位**——
  /// 页表刚排到目标页页尾时，「目标行行顶 → 已排内容底」通常不足一屏
  /// （实测差 60px 起步、随切片粒度放大），`_jumpPaged` 的超域目标会被
  /// postFrame clamp **静默截短**。而收敛一旦宣告（`_pendingLand` 已清、
  /// `_positionConverged=true`）就**永不重试**——采样从此停在截短位。
  /// 实测现场：`paged.land off=130236` → `paged.move why=views.late
  /// to=129744`（截 492px）→ 采样停在 23202（目标 23304，偏 102 字符）；
  /// 竞态另一结局只截 12px、落进段间距空隙反而贴回目标行（23301）——
  /// 同一机制两种结局，即「长章深位恢复落点偶发偏一截 / 不收敛」的根因。
  ///
  /// 分页排干（`scheduler.hasWork == false`）仍不可达 = **真书尾**：
  /// 布局不会再长，诚实 clamp（`§2.70`「由 clamp 兜住」）就是终点，验收放行。
  /// 窗口可达性（多章拼接）仍由 [_repairReachable] 负责；本验收只管
  /// 「当前章页表把目标排到可滚到位」，两层互补，不碰扩窗红线。
  bool _landingReachable(double landAt, PagedLayout layout) {
    final double vh = _viewportHeight;
    final double max = (layout.totalHeight - (vh > 0 ? vh : 0.0))
        .clamp(0.0, double.infinity)
        .toDouble();
    if (landAt <= max) return true;
    return !(_scheduler?.hasWork ?? false);
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
    if (target != null) _jumpPaged(target, why: 'views'); // pre-jump 在 setState 前
    // 窗口章 = 正在渲染的章：必须留在分页缓存里（读路径 [_paginatedOf] 走只读
    // `peek`，不参与 LRU 提位 ⇒ 被淘汰即静默退化为占位带、锚点以上布局塌陷
    // ⇒ 像素→章 采样错位并落盘。见 `PaginationCache.put`）。
    _scheduler?.cache.setProtected(
      <String>[for (final PagedChapterView v in views) v.href],
    );
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
    ({int index, int charOffset})? landTarget;
    if (tryPendingLand) {
      final ({int index, int charOffset})? pending = _pendingLand;
      if (pending != null && pending.index < (_chapters?.length ?? 0)) {
        final PagedLayout layout = PagedLayout.build(
            views, paragraphSpacing: cfg.paragraphSpacing);
        landOffset = PagedScrollerState.offsetFor(
          layout,
          views,
          _hrefAt(pending.index),
          pending.charOffset,
          paragraphSpacing: cfg.paragraphSpacing,
        );
        // 命中 ≠ 收敛：可达性验收挪到 `_repairReachable` 之后（见下方
        // `landTarget` 收口段）——`offsetFor` 只要页表覆盖目标行就给值，
        // 此刻「目标行到已排内容底」常不足一屏，立即宣告收敛会被
        // `_jumpPaged` 的超域 clamp 截短且永不重试（[_landingReachable]）。
        if (landOffset != null) landTarget = pending;
      }
    }
    if (sig == _viewsSignature && landOffset == null) {
      // 视图没换也可能有可放行时机（门闸还挂着）：戳一次复查，幂等。
      _checkOpenGate();
      return;
    }
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
    // 落位收口（可达性验收后）：可达 / 真书尾 → 清 pending、宣告收敛；
    // 域外且分页仍在生长 → **不收敛、不跳截短中间位**，保持 [_pendingLand]
    // 等下一切片重试（帧链保证续跑）。「clamp 截短 + 永不重试」的修复面。
    if (landTarget != null && landOffset != null) {
      final PagedLayout landLayout = PagedLayout.build(views,
          paragraphSpacing: cfg.paragraphSpacing);
      if (_landingReachable(landOffset, landLayout)) {
        _pendingLand = null;
        _positionConverged = true;
        // 二次精确落位收敛 → 开书门闸在此补报放行（帧回调保证落位先上屏）。
        _checkOpenGate();
        PerfLog.mark('paged.land',
            'index=${landTarget.index} off=${landOffset.toStringAsFixed(0)}');
        // **分页模式的落定信号**：`paged.land` 是分页路径（`_pagedJumpTo` 一次
        // 落位）的终点，**不经过 [_finishRestore]**（那是 ListView 路径的收口）。
        // 故「打开后是否还在跳」这条链路指标必须挂在这里，否则分页模式下
        // `open.chain` / `restoreEnd` 永不出现（真机日志实证：11 次开书全部缺失）。
        widget.openTrace?.mark('restoreEnd', 'branch=paged index=${landTarget.index}');
        widget.openTrace?.reportChain();
      } else {
        landOffset = null;
        _startPagedFrames(); // 防帧链已停：续跑到可达 / 排干为止
      }
    }
    _applyPagedViews(views, cfg, sig, offset: landOffset);
    if (landOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _samplePagedNow();
      });
    }
    // 换视图后必戳门闸：「占位→真」换血改变 [_viewportReal] 判据，
    // 放行时机可能就差这一次复查（闪动链②的收口）。
    _checkOpenGate();
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
    // **自然停手**：必须保留行内像素余量，否则每次停手都被吸附到行顶
    // （真机「底部/顶部文字弹跳」；见 [_scrollRemainderOf]）。
    _primeOpenSync(
        charOffset: _currentCharOffset(), keepScrollRemainder: true);
  }

  /// 把窗口内「已就绪但未分页」的章登记进预分页队列（prev 槽位复用，
  /// 队列按 href 去重；当前章 / 已有定稿的自动跳过）。
  ///
  /// **空段章也登记**（2026-10-09）：它是「一张空页」的定稿章（内核
  /// `PageBreaker.paginate` 空行表返回一页空页、`IncrementalPaginator` 空段
  /// 构造即完成），登记即秒完成入缓存——否则 `_paginatedOf` 恒 `null`，
  /// `_buildPageViews` 永远把它当「载入中…」占位（真机《枭臣》孤行「正文」
  /// 切出的空段章卡在章间实证）。
  void _registerWindowUnpaginated() {
    final PaginationScheduler? scheduler = _scheduler;
    final PaginationConfig? cfg = _pageConfig;
    if (scheduler == null || cfg == null) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null) return;
    for (final int i in _window) {
      if (i < 0 || i >= chapters.length) continue;
      final ChapterContent? content = _cache.peek(i);
      if (content == null || content.imagePages != null) {
        continue;
      }
      scheduler.setWindow(
        prevHref: chapters[i].href,
        prevParagraphs: content.paragraphList,
        prevHeadingHeight: _headingHeightOf(i, cfg),
      );
    }
  }

  /// 窗口**尾追加**时立刻预热新章正文（直译 legado「预载下一章」的语义）。
  ///
  /// ## 为什么不能在停稳才载
  ///
  /// 改前正文只在 [_onPagedStopped] ③（`loadFirstBatch`）才载：用户快滑到窗口
  /// 尾部 → 新章先以占位块上屏 → **要等停手**才看到正文（真机「章节间有大段
  /// 空白」，探针实测占位块曾是整屏 572dp）。这里改成「追加的那一刻就起 IO」：
  /// 正文读取本身异步、不占滚动帧；到手后登记未分页章 + 启动空闲分页帧，
  /// 于是正文通常在被滑到之前已就位，占位块只在网络/解压慢时短暂出现。
  ///
  /// 与 [`R1②`][_pauseAutoFill] 的分工：那边挂起的是**全书预热**（Profiler 实测
  /// 占补齐阶段 56% 纯 CPU，交互期该让位）；这里只为**紧邻视口的那一章**起一次
  /// IO，是「翻页不空等」的必要代价，量级是单章而非整本。
  Future<void> _preloadWindowTail(int index) async {
    final ChapterAutoLoader? loader = _loader;
    if (loader == null || index < 0 || _disposed) return;
    if (_cache.peek(index) == null) {
      await loader.loadFirstBatch(index);
      if (!mounted || _disposed || !_pagedMode) return;
    }
    _registerWindowUnpaginated();
    _startPagedFrames();
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
    _pauseAutoFill(); // R1②：用户滚动中挂起后台补齐（带时限，见 _pauseAutoFill）
    _clearSelection(); // 滚动起手清选区（无选区时空转；build 期已由上行跳过）
    if (notification.dragDetails != null) {
      _ttsFollow.noteManualScroll(); // `TTS-02` ③ 手动滚动暂停自动跟随
      _ttsProgress = null; // `TTS-06`：视口被用户接管 → 朗读坐标让位
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
          unawaited(_preloadWindowTail(book + 1));
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
    // 每次停手一行：真机录屏的「哪一帧跳了」只能靠这里对齐（`px` = 停手时
    // 的现场像素；后续 `paged.move` 的 `d` 就是那次位移）。
    PerfLog.mark(
        'paged.stop',
        'px=${_pagedPixelsOrNull()?.toStringAsFixed(1) ?? '-'} '
        'index=$_currentIndex pos=${_chapterPos.toStringAsFixed(3)}');
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
    _resumeAutoFillIfIdle(); // R1②：交互结束 → 恢复补齐
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
        // ## ⚠️ 章内比例必须一起归零（2026-10-08 修，真机「滚动时跳动」）
        //
        // `_chapterPos` 是**章内**比例，只对本章有意义。落到占位章（页表还没
        // 出来）时若只换章身份、留着上一章的比例，等该章排完版后
        // `_ensurePagedActive → _primeOpenSync(charOffset: _currentCharOffset())`
        // 会拿这个「别人的比例」去落位——探针实测：读第 2 章末 → 滚进第 3 章
        // 占位块（比例仍是第 2 章的 0.9）→ 第 3 章排版完成后视口直接落到
        // **第 3 章末尾**（offset 5454→4882 = 该章最后一屏），等于整章被跳过。
        // 占位块只表示「这一章还没排」，视口落在它的上沿 ⇒ 语义就是章首。
        setState(() {
          _currentIndex = book;
          _liveIndex = book;
          _chapterPos = 0.0;
          _livePos = 0.0;
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
        if (content != null &&
            content.imagePages == null &&
            content.paragraphList.isEmpty) {
          // 空段章：无可滚动内容，语义坐标**即达**（§2.82 只显章名的空章）——
          // 按精确落位收口，开书门闸（[_checkOpenGate]）据此放行，不等 3s 兜底。
          setState(() {
            _positionConverged = true;
          });
          // 「即达」只是落位语义；视口真身还要这一章**成真**：空段章天生
          // 「一张空页」的定稿页表（`IncrementalPaginator` 空段构造即完成，
          // `open` 突发即定稿入缓存）——不入缓存它就永驻「载入中…」占位带，
          // [_viewportReal] 恒假、门闸死等到 3s 兜底。**必须走 `open`**：
          // 调度器配置（`_config`）只由它立起，在此之前 [setWindow] 是 no-op，
          // 邻章登记会被静默吞掉（2026-10-12 空段章用例判红实证）。
          final PaginationScheduler? scheduler = _scheduler;
          final PaginationConfig? cfg = _pageConfig;
          if (scheduler != null && cfg != null) {
            scheduler.open(
              href: chapters[target].href,
              paragraphs: content.paragraphList,
              config: cfg,
              headingHeight: _headingHeightOf(target, cfg),
            );
          }
          _registerWindowUnpaginated();
          _startPagedFrames();
          _syncPagedViews();
          _checkOpenGate();
        }
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
        _ttsProgress = null; // `TTS-06`：程序化改位 → 朗读坐标让位给新落点
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
      selection: _selection,
      speaking: _speaking == null
          ? null
          : (
              href: _hrefAt(_speaking!.chapterIndex),
              paraIndex: _speaking!.paraIndex
            ),
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

  /// 语义坐标（章下标 + 章内比例）→ 当前页在视图表中的位置。
  /// `pageIndex == -1` = 占位章（页表空）；视图表不含该章 → `null`。
  ///
  /// `pos` 由调用方注入，故**同一套换算同时服务两处**：翻页体用语义坐标
  /// （`_currentIndex` / `_chapterPos`，见 [_turnPosition]），底部读数用滚动实时值
  /// （`_liveIndex` / `_livePos`，见 [_livePageNumber]）——两处页号口径因此天然一致。
  ({int viewIndex, int pageIndex})? _viewPositionAt(int index, double pos) {
    if (_pageViews.isEmpty) return null;
    final String href = _hrefAt(index);
    if (href.isEmpty) return null;
    final int v = _pageViews.indexWhere((PagedChapterView w) => w.href == href);
    if (v < 0) return null;
    final List<PageSlice> pages = _pageViews[v].pages;
    if (pages.isEmpty) return (viewIndex: v, pageIndex: -1);
    // `pos` 与 `totalChars` 同源（`charCountOf(paragraphs)`）——
    // 比例 × 总字数还原字符偏移，与保存 / 落位口径一致。
    final int total = PagePaginator.charCountOf(_pageViews[v].paragraphs);
    if (total <= 0) return (viewIndex: v, pageIndex: 0);
    final int charOffset =
        (pos.clamp(0.0, 1.0) * total).round().clamp(0, total);
    int p = PageBreaker.findPageByCharOffset(pages, charOffset);
    if (p < 0) p = 0;
    if (p >= pages.length) p = pages.length - 1;
    return (viewIndex: v, pageIndex: p);
  }

  /// 语义坐标（`_currentIndex` + `_chapterPos`）→ 当前页在视图表中的位置。
  ({int viewIndex, int pageIndex})? _turnPosition() =>
      _viewPositionAt(_currentIndex, _chapterPos);

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
        chapterHref: view.href,
        selection: _pageSelection(view.href),
        speakingPara: _pageSpeaking(view.href),
      ),
    ));
    // 内容外裹 `SingleChildScrollView(physics: Never)`：**只**为了让它给 Column
    // 无界主轴约束 + 自己裁到页框。
    //
    // ## ⚠️ 为什么不能直接返回 Column（2026-10-08，真机「滑动模式顶/底被截断」）
    //
    // 本 widget 被 `PageTurnLayers` 放进 `Stack(fit: StackFit.expand)` ⇒ **紧约束**
    // （宽高都 = 可视区）。而排版参数（页高）来自上一帧的 `_pageConfig`：chrome
    // 切换那一帧可视区已经变小、页表还是旧的 ⇒ `标题占高 + 页高 > 可视区高`
    // ⇒ Column 直接**溢出**（探针实测 debug 报 `RenderFlex overflowed by 154`，
    // 即底部约 5 行被黄黑斜纹盖住 → 用户看到的就是「底部文字被截断」）。
    // 下一帧 reprime 完成后自愈（探针：越界 142px 只存在 1 帧）。
    //
    // 换 `SingleChildScrollView` 后：Column 拿到无界高（不再触发溢出断言），
    // 外层按页框裁切——**像素结果与改前一致**（本来就该被裁），但不再有
    // 溢出条纹，也不再在 debug 控制台刷断言。
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  /// 当前朗读段在 [href] 章上的段下标投影（非该章 / 未朗读 → null）。
  int? _pageSpeaking(String href) {
    final ({int chapterIndex, int paraIndex})? speaking = _speaking;
    if (speaking == null || _hrefAt(speaking.chapterIndex) != href) return null;
    return speaking.paraIndex;
  }

  /// 当前选区在 [href] 章上的段落投影（非该章 / 无选区 → null）。
  ({int paraIndex, int start, int end})? _pageSelection(String href) {
    final ParaSelection? sel = _selection;
    if (sel == null || sel.isEmpty || sel.chapterHref != href) return null;
    return (paraIndex: sel.paraIndex, start: sel.start, end: sel.end);
  }

  /// 单段选区投影（ListView 形态的 InlineParagraph 用）：章与段都对上才给。
  ({int start, int end})? _paraSelection(String href, int paraIndex) {
    final ParaSelection? sel = _selection;
    if (sel == null || sel.isEmpty) return null;
    if (sel.chapterHref != href || sel.paraIndex != paraIndex) return null;
    return (start: sel.start, end: sel.end);
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
      _ttsFollow.noteManualScroll(); // `TTS-02` ③ 手动翻页同样暂停跟随
      _ttsProgress = null; // `TTS-06`：视口被用户接管 → 朗读坐标让位
      _clearSelection(); // 翻页起手清选区（视口要动了）
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
    // `TTS-06`：朗读直写坐标在场时优先（视口可能落后于朗读——手动滚动
    // 暂停跟随后，陈旧视口值不得覆盖「停止后接着听」的落点）。
    final ({int chapterIndex, double chapterPos})? tts = _ttsProgress;
    final int index =
        (tts?.chapterIndex ?? _currentIndex).clamp(0, chapters.length - 1);
    final double pos = tts?.chapterPos ?? _chapterPos;
    final Chapter chapter = chapters[index];
    final int now = DateTime.now().millisecondsSinceEpoch;
    final ReadingProgress progress = ReadingProgress(
      bookId: widget.record.bookId,
      chapterHref: chapter.href,
      chapterIndex: index,
      chapterPos: pos,
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
        readProgress: _overallProgress(index, pos),
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

  /// 异步取每章**权重估算**（fire-and-forget，见 [_chapterWeights] 注释）。
  ///
  /// ## ⚠️ 只走 `chapterWeightEstimates`，**绝不**回落 `chapterCharCounts`
  /// （2026-10-08 真机「EPUB 章节加载特别慢 / 快滑多章没加载」定案）
  ///
  /// 这里的返回值只喂给一个**一位小数的进度百分比**，而精确口径
  /// （`chapterCharCounts`）在 EPUB 上是「逐章解压 + 解析 XHTML」——真机 1152 章
  /// 的书实测把主 isolate **独占秒级**（探针：300 章 301ms，其中停顿 270ms；
  /// 随章数线性增长），且正好落在开书后、用户开始滚动的那一刻：帧回调与分页
  /// `step` 全部停摆 ⇒ 「章节要等很久才出来」「快滑过去好几章还是空的」。
  ///
  /// 故本方法**无条件**保证「开书路径零全书遍历」：估算取不到（源不支持）就
  /// 直接保持等权——不回落精确口径，不给自己留一条会让 UI 冻住的后路。
  /// 代价只是百分比从「精确字数加权」退化为「等权」，与迁移前公式同形。
  ///
  /// `null`（源不支持）保持等权；dispose / 竞态静默放弃，不写状态。
  Future<void> _loadChapterWeights() async {
    try {
      final List<int>? weights = await widget.source.chapterWeightEstimates();
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
  /// 顶栏副标题（[ReaderPage._subtitle]）仍在用这个整数口径。
  int get _livePercent => _livePercentValue.floor();

  /// 显示用全书进度百分比（**一位小数**，同样向下取整到 0.1）。
  ///
  /// 底部常驻指示器口径（负责人 2026-10-08 指定截图格式「22.2%」）。
  /// 向下取整的理由与 [_livePercent] 同：`overall` 即使 0.9999 也显示 99.9%，
  /// 只有真的读完（= 1.0）才显示 100.0%——避免「差一点就满格」的观感。
  double get _livePercentValue {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return 0;
    final double overall = overallReadingProgress(
      chapterIndex: _liveIndex,
      chapterPos: _livePos,
      chapterCount: chapters.length,
      chapterWeights: _chapterWeights,
    );
    return (overall.clamp(0.0, 1.0) * 1000).floor() / 10;
  }

  /// 底部读数用的当前（实时）章标题；章表未就绪 / 下标越界 → 空串。
  String get _liveChapterTitle {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null ||
        _liveIndex < 0 ||
        _liveIndex >= chapters.length) {
      return '';
    }
    return chapters[_liveIndex].title;
  }

  /// 底部读数用的**章内页位**：页码（1 基）+ 本章总页数。
  ///
  /// 页表未就绪（增量分页首帧 / 占位章）→ `(0, 0)`，指示器退化为只显示百分比
  /// （不显示「0/0」这种没有信息量的读数）。
  ({int number, int total}) get _livePageNumber {
    final ({int viewIndex, int pageIndex})? pos =
        _viewPositionAt(_liveIndex, _livePos);
    if (pos == null || pos.pageIndex < 0) return (number: 0, total: 0);
    final int total = _pageViews[pos.viewIndex].pages.length;
    if (total <= 0) return (number: 0, total: 0);
    return (number: pos.pageIndex + 1, total: total);
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
              _exitChrome(); // 落到目标页顶 ⇒ 必须收起顶栏，否则目标被它压住。
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
              _exitChrome(); // 落到目标页顶 ⇒ 必须收起顶栏，否则目标被它压住。
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
              _exitChrome(); // 落到目标页顶 ⇒ 必须收起顶栏，否则目标被它压住。
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

  /// 打开朗读设置面板（`TTS-04` 语速 / 音色，`TTS-05` 定时停止）。
  ///
  /// 音色列表要问引擎：顺带懒建控制器（未开读过时）再取一次可用音色；
  /// 引擎侧无实现平台（Linux 等）回空列表 → 面板隐藏音色区（诚实降级）。
  Future<void> _openTtsSettings() async {
    final TtsSettingsStore? store = widget.ttsSettings;
    if (store == null || !mounted || _disposed) return;
    final List<TtsVoice> voices = await _ensureTts().getVoices();
    if (!mounted || _disposed) return;
    await GlassOverlays.showSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => OpaqueContentSurface(
        child: TtsSettingsSheet(
          settings: store.value,
          voices: voices,
          onChanged: _onTtsSettingsChanged,
          onlineTts: widget.onlineTts,
          aiStore: widget.aiStore,
        ),
      ),
    );
  }

  /// 面板回传（整份值对象）：逐项 setter 落盘（store 内部等值短路）；
  /// 语速 / 音色**立即应用**引擎（`TTS-04`①），定时随设定重设（`TTS-05`）。
  void _onTtsSettingsChanged(TtsSettings next) {
    final TtsSettingsStore? store = widget.ttsSettings;
    if (store == null) return;
    final TtsSettings prev = store.value;
    // `TTS-07` 引擎切换：先落盘 + 停掉旧朗读、丢弃控制器——下次开读
    // [_ensureTts] 按新引擎重建（在线引擎的配置修改同理走重建路径）。
    if (next.engine != prev.engine) {
      unawaited(store.setEngine(next.engine));
      unawaited(_dropTtsController(stopFirst: true));
    }
    final bool engineChanged = next.rate != prev.rate ||
        next.followSystemRate != prev.followSystemRate ||
        next.voiceName != prev.voiceName ||
        next.voiceLocale != prev.voiceLocale;
    unawaited(store.setRate(next.rate));
    unawaited(store.setFollowSystemRate(next.followSystemRate));
    unawaited(store.setVoice(name: next.voiceName, locale: next.voiceLocale));
    unawaited(store.setSleepMinutes(next.sleepMinutes));
    if (next.sleepMinutes != prev.sleepMinutes) _syncSleepTimer();
    if (engineChanged) unawaited(_applyTtsSettings());
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
  ///
  /// 两个入口，都在 `_buildBody`：点正文**九宫格中宫**（`reader-chrome-toggle`，
  /// 落点判定见 [_onContentTapUp]）与点常驻读数行
  /// （`reader-chrome-toggle-status`，图片页里中央点击被「点页全屏缩放」占用，
  /// 故需要一个模式无关的入口）；顶栏与全屏浮层的两个切换按钮已按负责人要求移除
  /// （详见 `_fullscreen` 字段注释）。
  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
  }

  /// 正文层 tap 的落点闸门（2026-10-10 负责人拍板：「将阅读页划为9宫格，
  /// 只有最中间的宫格位置，才能点击呼出菜单」）。
  ///
  /// 判定框 = `reader-chrome-toggle` 自身的盒（与正文排版区同框）；按
  /// **三分线**划 3×3，只有落进中宫 `[w/3, 2w/3] × [h/3, 2h/3]`（含边界）的
  /// tap 才调 [_toggleFullscreen]，其余八格落点一律无事（防阅读时侧边 / 角落
  /// 误触把 chrome 翻出来）。
  ///
  /// ⚠️ 落点换算用 **`globalToLocal(globalPosition)`**，不用
  /// `TapUpDetails.localPosition`：后者构造兜底是 `localPosition ?? globalPosition`
  /// （`gestures/tap.dart`）——两处坐标系不一致时会静默退化成全局坐标，
  /// 而测试窗原点即全局原点、两种写法**恒等**，这类错位测试照绿真机才炸。
  /// 显式过一次 `RenderBox.globalToLocal` 把口径钉死在判定框上。
  ///
  /// 语义不变的邻居：正文链接（`CNT-04`）、图片页点页缩放（`FMT-02`）、
  /// 长按划词（`AI-02`）各有自己的识别器，赢竞技场后本回调根本不触发
  /// （`handleTapUp` 只在本识别器胜出时走），中宫判定不碰它们。
  void _onContentTapUp(TapUpDetails details) {
    final RenderObject? obj =
        _chromeToggleKey.currentContext?.findRenderObject();
    final RenderBox? box = obj is RenderBox ? obj : null;
    if (box == null || !box.hasSize) return;
    final Offset local = box.globalToLocal(details.globalPosition);
    final Size size = box.size;
    final bool inCenterCell = local.dx >= size.width / 3 &&
        local.dx <= size.width * 2 / 3 &&
        local.dy >= size.height / 3 &&
        local.dy <= size.height * 2 / 3;
    if (inCenterCell) _toggleFullscreen();
  }

  /// 从弹层里选定一个位置跳过去后**收起 chrome**（`TYP-09`）。
  ///
  /// 为什么必须有这一步：chrome 现在是**覆盖层**（`extendBody*`，见 [build]），
  /// 顶栏压在正文上沿 56dp；而搜索命中 / 目录 / 书签 / 摘要的落位一律是
  /// 「目标在页顶」（`§2.70` 行顶对齐）⇒ 若跳转时 chrome 还开着，用户跳过去
  /// 第一眼看到的目标恰好压在顶栏底下（探针实测：目标段落矩形
  /// `Rect(8,0,792,29)` 落在顶栏 `0..56` 之内 ⇒ 不可命中、看不见）。
  ///
  /// 语义上也本该如此：「从弹层里挑一个位置」＝「我要开始读这里」，
  /// 参考实现（legado）的目录 / 搜索是独立页面，回到阅读页时菜单本就是收起的。
  ///
  /// 只在「控制条上/下一章」这类**就地操作**里保持 chrome（那时用户正在用控制条，
  /// 收掉会让他找不到按钮）。
  void _exitChrome() {
    if (_fullscreen) return;
    setState(() => _fullscreen = true);
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
    // 正文预算与底部读数**只吃系统 inset**，故取 Scaffold **外层**的 MediaQuery。
    //
    // ⚠️ 不能用 body 里那份：`Scaffold` 会给 body 单独加工一个 MediaQuery
    // （`scaffold.dart:3030-3033` 定 removeTop/removeBottom，`_BodyBuilder`
    // （`scaffold.dart:960-985`）再按 extendBody* 改写），唤出 chrome 时
    // 顶部 44→0、底部 34→0（探针实测）。正文几何若跟着它走，就等于让 chrome
    // 参与排版 —— 正是本次要修掉的缺陷。
    final MediaQueryData systemMq = MediaQuery.of(context);

    return Scaffold(
      backgroundColor: _pageColor(theme),
      // `TYP-09` 契约（2026-10-09 负责人拍板）：**唤出 / 收起 chrome 不得改变
      // 正文排版区高度**。
      //
      // 改前 `appBar` / `bottomNavigationBar` 是**占位**槽：`_ScaffoldLayout`
      // 用 `contentTop = appBarHeight`、`contentBottom = bottom −
      // max(minInsets.bottom, bottomWidgetsHeight)` 把 body 挤矮
      // （`scaffold.dart:1041-1104`），探针实测 body 高 852 → 615 ⇒ 正文可排版高
      // 746 → 587（−159px，约 5 行），整页重排、阅读位置肉眼可见地跳。
      //
      // 两个 `extendBody*` 让 body **恒占满整屏**（`contentTop = 0`；`extendBody`
      // 还会把底部层高度加回 `bodyMaxHeight`，见 `scaffold.dart:1098-1101`），
      // chrome 退化成**覆盖层**：顶栏盖住正文上沿、底部层盖住正文下沿，
      // 正文自己一像素都不动。
      extendBody: true,
      extendBodyBehindAppBar: true,
      // `TYP-09` 验收①：默认全屏 ⇒ `_fullscreen` 初值 `true`，此处即 `null`；
      // 点正文唤出 chrome 后顶栏原样出现（验收①「唤出与收起」）。
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
                // 分组① 检索与标记：书内搜索（`CNT-06`）、书签（`TYP-06`）。
                ReaderAppBarGroup(
                  leadingDivider: false,
                  children: <Widget>[
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
                  ],
                ),
                // 分组② AI 增强：原 4 个平铺图标（前情回顾 / 摘要 / 问答 / 人物）
                // 收进单个入口，见 [showReaderAiPanel] 的划分依据。
                if (_aiPanelEnabled)
                  ReaderAppBarGroup(
                    children: <Widget>[
                      IconButton(
                        key: const Key('reader-ai-panel'),
                        tooltip: 'AI 助手',
                        icon: const Icon(Icons.auto_awesome),
                        onPressed: ready ? _openAiPanel : null,
                      ),
                    ],
                  ),
                // 分组③ 外观与视图：外观面板（`TYP-03`/`TYP-07`/`TYP-08`）、
                // 目录（`NAV-01` 要求 AppBar 目录按钮）。
                // 全屏切换按钮（`reader-fullscreen-enter`）已移除（2026-10-08）：
                // 默认即全屏、切换改走点正文，详见 `_fullscreen` 字段注释。
                ReaderAppBarGroup(
                  children: <Widget>[
                    IconButton(
                      key: const Key('reader-appearance'),
                      tooltip: '外观',
                      icon: const Icon(Icons.tune),
                      onPressed: ready ? _openAppearance : null,
                    ),
                    IconButton(
                      key: const Key('reader-toc'),
                      tooltip: '目录',
                      icon: const Icon(Icons.list),
                      onPressed: ready ? _openToc : null,
                    ),
                  ],
                ),
              ],
            ),
      // 底部层 = 常驻读数（恒在）+ 控制条（chrome 唤出时）。
      //
      // 合成**同一个槽**、且读数排在**上面**（`[读数, 控制条]`）：
      //   ① 读数必须落在控制条**正上方**——`control_bar.dart` 的窄屏让位
      //      （`kReaderControlProgressMinWidth`）明确依赖这一条；
      //   ② 收起 chrome 时槽里只剩读数 ⇒ 它自然贴屏幕底边（与改前逐像素一致）；
      //   ③ 配合 `extendBody`，二者只是**覆盖**正文、不参与正文预算 ⇒
      //      增删控制条不会改动正文排版区高度（`TYP-09`）。
      //
      // 读数在槽内**恒在**（`TYP-09` 验收①：chrome 全隐藏时它必须仍在），
      // 且它自身就是 chrome 切换入口（`reader-chrome-toggle-status`）——
      // 图片页中央点击被「点页全屏缩放」占用，需要一个模式无关的入口。
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GestureDetector(
            key: const Key('reader-chrome-toggle-status'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggleFullscreen,
            child: ReaderProgressIndicator(
              chapterTitle: _liveChapterTitle,
              pageNumber: _livePageNumber.number,
              pageCount: _livePageNumber.total,
              percent: _livePercentValue,
              // 只有落在**屏幕底边**（chrome 收起）时才让开系统手势导航条；
              // 控制条在它下面时，那一条由控制条自己的 `SafeArea(bottom: true)`
              // 承担——重复计入会在两者之间留一条 34dp 空带。
              bottomInset: _fullscreen ? systemMq.padding.bottom : 0,
            ),
          ),
          if (ready && !_fullscreen)
            ReaderControlBar(
              settings: _settings,
              onSettingsChanged: _onSettingsChanged,
              chapterNumber: _liveIndex + 1,
              chapterCount: chapters.length,
              percent: _livePercent,
              canGoPrev: _currentIndex > 0,
              canGoNext: _currentIndex < chapters.length - 1,
              onPrevChapter: () => unawaited(_goToChapter(_currentIndex - 1)),
              onNextChapter: () => unawaited(_goToChapter(_currentIndex + 1)),
              onAi: _summaryEnabled
                  ? () => _openSummarySheet(SummaryMode.chapter)
                  : null,
              onTts: _toggleTts,
              ttsActive: _tts?.isRunning ?? false,
              onTtsSettings: widget.ttsSettings == null
                  ? null
                  : () => unawaited(_openTtsSettings()),
            ),
        ],
      ),
      // CNT-04c 验收②：链接返回栈非空时显示「返回」按钮，弹栈恢复原位置；
      // 栈空隐藏（普通 Material，玻璃留给 M2a-T04）。
      floatingActionButton: _linkStack.isNotEmpty
          ? FloatingActionButton(
              onPressed: () => unawaited(_goBack()),
              tooltip: '返回',
              child: const Icon(Icons.arrow_back),
            )
          : null,
      body: _buildBody(theme, systemMq),
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

  // ── 划词选区（`AI-02`/`AI-03`；命中与值对象见 selection_overlay.dart）──

  /// 划词可用性：三个 AI 依赖齐备 + `AI-09` ② 全局开关开启
  /// （任一为 null → 整体禁用，与 [statsService] 同款降级口径）。
  bool get _selectionEnabled {
    final ProviderStore? store = widget.aiStore;
    return store != null &&
        widget.aiClient != null &&
        widget.vocabStore != null &&
        store.prefs.aiEnabled;
  }

  /// 摘要可用性（`AI-04`/`AI-05`）：AI 配置 + 客户端 + 摘要缓存三参齐 +
  /// `AI-09` ② 全局开关开启（任一为 null → 摘要入口整体隐藏）。
  bool get _summaryEnabled {
    final ProviderStore? store = widget.aiStore;
    return store != null &&
        widget.aiClient != null &&
        widget.summaryCache != null &&
        store.prefs.aiEnabled;
  }

  /// AI 分组入口是否可用：**摘要 / 问答 / 人物** 任一可用即渲染该分组按钮
  /// （`AI-04`~`AI-07` + `AI-09` ② 全局开关；三者全关时分组整体隐藏，与改前
  /// 「三个按钮各自隐藏」的总可见效果一致）。
  ///
  /// 前情回顾（`AI-05` ②）**不计入**本判定：它是会话内一次性的提醒入口
  /// （[_showRecapEntrance]），只在面板内作为附加行出现，不单独撑起分组按钮。
  bool get _aiPanelEnabled =>
      _summaryEnabled || _askEnabled || _entitiesEnabled;

  /// 打开 AI 助手面板（`AI-04`~`AI-07` 的分组入口）。
  ///
  /// 面板内每行 = 改前 AppBar 的一个按钮，回调原样传入（[_openSummarySheet] /
  /// [_openAskSheet] / [_openEntityPage]），故功能与可用性判定完全不变。
  void _openAiPanel() {
    unawaited(showReaderAiPanel(
      context: context,
      onSummary: () => _openSummarySheet(SummaryMode.chapter),
      onAsk: _openAskSheet,
      onEntities: _openEntityPage,
      // `AI-05` ②：停读 ≥7 天开书出现的前情回顾入口（会话内一次性）。
      onRecap: _showRecapEntrance && _summaryEnabled
          ? () {
              // 与改前一致：进入回顾后本会话不再提示，故在**开面板前**即复位。
              setState(() => _showRecapEntrance = false);
              _openSummarySheet(SummaryMode.recap);
            }
          : null,
    ));
  }

  /// 递进生成的章文本加载器（`PERF-02`：LRU 未命中才回源，不假设全书常驻）。
  Future<String> _summaryTextAt(int index) async {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || index < 0 || index >= chapters.length) return '';
    final ChapterContent? cached = _cache.peek(index);
    final ChapterContent content = cached ?? await _contentAt(index);
    return content.paragraphList.map(plainParagraphText).join('\n');
  }

  /// 弹出摘要面板（`AI-04` 默认章摘要 / `AI-05` 前情回顾入口复用）。
  void _openSummarySheet(SummaryMode mode) {
    final ProviderStore? store = widget.aiStore;
    final AiClient? client = widget.aiClient;
    final SummaryCache? cache = widget.summaryCache;
    final List<Chapter>? chapters = _chapters;
    if (!_summaryEnabled ||
        store == null ||
        client == null ||
        cache == null ||
        chapters == null ||
        chapters.isEmpty) {
      return;
    }
    if (mode == SummaryMode.recap) {
      setState(() => _showRecapEntrance = false); // 已进入，本会话不再提示
    }
    unawaited(showSummarySheet(
      context,
      initialMode: mode,
      aiStore: store,
      aiClient: client,
      summaryCache: cache,
      bookId: widget.record.bookId,
      chapters: chapters,
      currentIndex: _currentIndex.clamp(0, chapters.length - 1),
      loadText: _summaryTextAt,
    ));
  }

  /// 跟书问答可用性（`AI-06`）：AI 配置 + 客户端 + 索引存储三参齐 +
  /// `AI-09` ② 全局开关开启（任一为 null → 问答入口整体隐藏）。
  ///
  /// 注意与摘要不同：**不因 selectionOnly 隐藏入口**——`AI-09` ③ 要求
  /// 「明确标注为受限」，受限状态由面板内展示（`ask-scope` 行）。
  bool get _askEnabled {
    final ProviderStore? store = widget.aiStore;
    return store != null &&
        widget.aiClient != null &&
        widget.ragStore != null &&
        store.prefs.aiEnabled;
  }

  /// 取（或构建）本书的问答索引（注入面板的 [showAskSheet.ensureIndex]）。
  ///
  /// 构建按章取文走 `_summaryTextAt`（纯文本 + LRU 未命中才回源，
  /// `PERF-02` 口径与摘要共用）；落盘 / 命中由 [RagIndexStore] 收口。
  Future<RagIndex> _ensureRagIndex() {
    final RagIndexStore? store = widget.ragStore;
    final List<Chapter>? chapters = _chapters;
    if (store == null || chapters == null) {
      return Future<RagIndex>.error(StateError('问答索引未就绪'));
    }
    return store.ensure(
      bookId: widget.record.bookId,
      titles: <String>[for (final Chapter c in chapters) c.title],
      loadText: _summaryTextAt,
    );
  }

  /// 打开问答面板（`AI-06` / F5：输入 → 检索 → 流式 → 引用跳转）。
  void _openAskSheet() {
    final ProviderStore? store = widget.aiStore;
    final AiClient? client = widget.aiClient;
    final List<Chapter>? chapters = _chapters;
    if (!_askEnabled ||
        store == null ||
        client == null ||
        chapters == null ||
        chapters.isEmpty) {
      return;
    }
    unawaited(showAskSheet(
      context,
      aiStore: store,
      aiClient: client,
      ensureIndex: _ensureRagIndex,
      loadText: _summaryTextAt,
      // 与 [SearchSheet] 同契约：调用方关弹窗 + 跳转（跳转链路复用
      // `_jumpToSearchHit` 的段落级对齐）。
      onJump: (SearchHit hit, String query) {
        Navigator.of(context).pop();
        unawaited(_jumpToSearchHit(hit, query));
      },
    ));
  }

  // ── 段落朗读（`TTS-01`/`TTS-02`，M3-T06）──────────────────────────────

  /// 取（或首次创建）朗读控制器：引擎注入优先，缺省按设置选
  /// [SystemTts] / [OnlineTts]（`TTS-07`，`M3-T09`）。
  /// 同时懒建系统会话（`TTS-03`）并注入播控回调（通知栏 / 耳机 / 焦点入站口）。
  TtsController _ensureTts() {
    final TtsController? existing = _tts;
    if (existing != null) return existing;
    // 注：cascade 赋值里的箭头闭包必须再包一层括号——否则 `=> expr..next`
    // 会被解析成「在 expr 上开级联」（`Future<void>` 上找不到 setter）。
    _ttsAudio ??= (TtsAudioSession()
      ..onPlay = _ttsResumeOrStart
      ..onPause = _ttsPauseFromSystem
      ..onStop = _ttsStopFromSystem
      ..onSkipToPrevious = (() => _ttsSkipChapter(-1))
      ..onSkipToNext = (() => _ttsSkipChapter(1)));
    final TtsEngine engine = widget.ttsEngine ?? _buildTtsEngine();
    final TtsController created = TtsController(
      engine,
      _ttsLoadChapter,
      _chapters?.length ?? 0,
      onActive: _onTtsActive,
      onError: _onTtsError,
      onChanged: _onTtsChanged,
      // `TTS-07` ③：在线引擎下载失败 → 暂停留位 + 中文提示（系统引擎保持
      // 原「停止」语义，开关只在在线分支打开）。
      pauseOnError: engine is OnlineTts,
    );
    _tts = created;
    return created;
  }

  /// 按当前设置建引擎实例（`TTS-07`）：设置为在线且配置已接线 → 建
  /// [OnlineTts] 并记入 [_onlineTtsImpl]（dispose 释放）；否则系统引擎。
  TtsEngine _buildTtsEngine() {
    final OnlineTtsStore? onlineStore = widget.onlineTts;
    final bool useOnline =
        onlineStore != null &&
        widget.ttsSettings?.value.engine == TtsEngineKind.online;
    if (!useOnline) {
      _ttsEngineOnline = false;
      return SystemTts();
    }
    final OnlineTts impl = OnlineTts(onlineStore);
    unawaited(_onlineTtsImpl?.dispose()); // 防御：重建前收上一份（正常不会在场）
    _onlineTtsImpl = impl;
    _ttsEngineOnline = true;
    return impl;
  }

  /// 丢弃当前控制器（引擎切换 / 在线启动失败）：先按需 stop，再释放
  /// 在线引擎实现——下次 [_ensureTts] 按新设置重建、重跑 init 探测。
  Future<void> _dropTtsController({bool stopFirst = false}) async {
    final TtsController? tts = _tts;
    _tts = null;
    if (tts != null && stopFirst) await tts.stop();
    final OnlineTts? impl = _onlineTtsImpl;
    _onlineTtsImpl = null;
    if (impl != null) await impl.dispose();
    _ttsEngineOnline = false;
  }

  /// 系统侧「播放」（通知栏 / 耳机键 / 焦点恢复）：暂停中续读；
  /// 未在读（竞态残留）则从当前段开读。换章重启窗口内忽略。
  void _ttsResumeOrStart() {
    final TtsController? tts = _tts;
    if (tts == null || _ttsRestarting) return;
    if (tts.isRunning) {
      if (tts.isPaused) unawaited(tts.resume());
      return;
    }
    unawaited(_toggleTts());
  }

  /// 系统侧「暂停」（通知栏 / 耳机键 / 焦点丢失 / 耳机拔出）：仅在播时生效。
  void _ttsPauseFromSystem() {
    final TtsController? tts = _tts;
    if (tts == null || !tts.isActive) return;
    unawaited(tts.pause());
  }

  /// 系统侧「停止」：停朗读（[_onTtsChanged] 随之 end 撤通知）。
  void _ttsStopFromSystem() {
    final TtsController? tts = _tts;
    if (tts == null || !tts.isRunning) return;
    unawaited(tts.stop());
  }

  /// 通知栏上一章 / 下一章（`TTS-03` ②）：朗读中 = 换章续读（新章起点）；
  /// 未朗读（竞态残留）= 只跳视图。首/末章越界处原地不动。
  Future<void> _ttsSkipChapter(int delta) async {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final TtsController? tts = _tts;
    if (tts == null || !tts.isRunning) {
      final int target = (_liveIndex + delta).clamp(0, chapters.length - 1);
      if (target != _liveIndex) await _jumpToLink(target, 0);
      return;
    }
    final int cur = tts.current?.chapterIndex ?? _liveIndex;
    final int target = (cur + delta).clamp(0, chapters.length - 1);
    if (target == cur) return;
    _ttsFollow.reset(); // 换章 = 恢复自动跟随（同开读侧语义）
    _ttsRestarting = true;
    try {
      await tts.start(target, 0); // start 自带先 stop 再开
    } finally {
      _ttsRestarting = false;
    }
  }

  /// 通知栏 / 锁屏用章节名：章标题空则回落「第N章」（同副标题口径）。
  String _ttsChapterTitle(int index) {
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || index < 0 || index >= chapters.length) return '';
    final String title = chapters[index].title;
    return title.isNotEmpty ? title : '第${index + 1}章';
  }

  /// 朗读推进取章段落：缓存命中直接回，未命中走增量加载（渲染侧同源入
  /// 缓存——跟随滚动要的几何由同一次加载带上）；loader 缺席才直接回源。
  Future<List<String>?> _ttsLoadChapter(int index) async {
    if (_disposed) return null;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || index < 0 || index >= chapters.length) return null;
    final ChapterContent? cached = _cache.peek(index);
    if (cached != null) return cached.paragraphList;
    await _loader?.loadFirstBatch(index);
    if (_disposed) return null;
    final ChapterContent? loaded = _cache.peek(index);
    if (loaded != null) return loaded.paragraphList;
    return (await _contentAt(index)).paragraphList;
  }

  /// 朗读按钮（`TTS-01` ①：从当前段起读；朗读中再点 = 停止）。
  Future<void> _toggleTts() async {
    final TtsController tts = _ensureTts();
    if (tts.isRunning) {
      unawaited(tts.stop());
      return;
    }
    final ({int chapterIndex, int paraIndex}) from = _ttsStartPoint();
    _ttsFollow.reset(); // 重新开读 → 恢复自动跟随（`TTS-02` ③ 复位侧）
    await _applyTtsSettings(); // `TTS-04`：开读前把存储的语速 / 音色备好
    final bool ok = await tts.start(from.chapterIndex, from.paraIndex);
    if (!ok) {
      if (mounted && !_disposed) {
        // PRD §15.3：无语音引擎（Linux 等）必须中文提示，不得静默失败；
        // `TTS-07` ①：在线引擎失败（未配置 / validate 不过 / init 失败）
        // 换一条对应文案，并丢弃控制器——下次开读按新配置重建重探测。
        GlassOverlays.showToast(
          context: context,
          message: _ttsEngineOnline ? '在线 TTS 未配置或配置无效' : '本机未安装语音引擎',
          type: GlassToastType.error,
        );
      }
      if (_ttsEngineOnline) unawaited(_dropTtsController());
      return;
    }
    // `TTS-03`：开系统会话（通知栏 / 锁屏 / 媒体键 / 焦点）。降级档或
    // 插件初始化失败 → begin 回 false，朗读照常仅前台、不提示（§15.3 拍板）。
    if (!mounted || _disposed) return;
    _ttsMediaChapter = from.chapterIndex;
    _syncSleepTimer(); // `TTS-05`：按设定启动定时（0 = 关闭不计时）
    final TtsAudioSession? audio = _ttsAudio;
    if (audio != null) {
      unawaited(audio.begin(
        bookId: widget.record.bookId,
        bookTitle: _title,
        chapterTitle: _ttsChapterTitle(from.chapterIndex),
      ));
    }
  }

  /// `TTS-04`：把存储的语速 / 音色应用到引擎（开读前与面板调整时调用）。
  ///
  /// 「跟随系统语速」开 → 写回默认 0.5（flutter_tts 初始语速即系统正常速，
  /// Android 侧 `rate × 2 = 1.0`）——保证开关切换**立即**回到正常速。
  Future<void> _applyTtsSettings() async {
    final TtsController? tts = _tts;
    if (tts == null || _disposed) return;
    final TtsSettings s = widget.ttsSettings?.value ?? const TtsSettings();
    await tts.setRate(s.followSystemRate ? TtsSettings.defaultRate : s.rate);
    final String? name = s.voiceName;
    await tts.setVoice(name == null || name.isEmpty
        ? null
        : TtsVoice(name: name, locale: s.voiceLocale ?? ''));
  }

  /// `TTS-05`：按当前设定重设定时（开读成功后与设定变更时调用）。
  ///
  /// 未在读不动计时（开读时再启）；设定为 0 = 关闭并取消既有计时。
  void _syncSleepTimer() {
    final TtsSettings s = widget.ttsSettings?.value ?? const TtsSettings();
    if (s.sleepMinutes <= 0) {
      _sleepTimer?.cancel();
      return;
    }
    if (!(_tts?.isRunning ?? false)) return;
    final SleepTimer timer = _sleepTimer ??= SleepTimer(onFire: _onSleepFire);
    timer.startMinutes(s.sleepMinutes);
  }

  /// `TTS-05` 到点：停朗读（`_onTtsChanged` 随之撤通知 / 高亮 / 落盘）+ 轻提示。
  void _onSleepFire() {
    final TtsController? tts = _tts;
    if (tts != null && tts.isRunning) unawaited(tts.stop());
    if (!mounted || _disposed) return;
    GlassOverlays.showToast(
      context: context,
      message: '定时到了，朗读已停止',
    );
  }

  /// 朗读起点（`TTS-01` ①「从当前段开始」）：视口**中心**命中的段落
  /// （中心 50% / 25% / 75% 三探，标题 / 图片 / 空白上落空再降级），
  /// 全部落空 → 当前章第 0 段。
  ({int chapterIndex, int paraIndex}) _ttsStartPoint() {
    final RenderBox? viewport = _viewportBox();
    final List<Chapter>? chapters = _chapters;
    if (viewport != null && viewport.hasSize && chapters != null) {
      final double h = viewport.size.height;
      final Offset top = viewport.localToGlobal(Offset.zero);
      for (final double ratio in const <double>[0.5, 0.25, 0.75]) {
        final ParagraphHit? hit =
            findParagraphAt(context, top + Offset(0, h * ratio));
        if (hit == null) continue;
        final int index =
            chapters.indexWhere((Chapter c) => c.href == hit.href);
        if (index >= 0) {
          return (chapterIndex: index, paraIndex: hit.paraIndex);
        }
      }
    }
    return (chapterIndex: _liveIndex, paraIndex: 0);
  }

  /// 当前朗读段变化：刷高亮 +（跟随开着且段落不够可见时）滚入可视区。
  void _onTtsActive(int chapterIndex, int paraIndex) {
    if (!mounted || _disposed) return;
    setState(() {
      _speaking = (chapterIndex: chapterIndex, paraIndex: paraIndex);
    });
    // `TTS-06`：每段推进即写朗读进度（F6「每段读完写入进度」——书架百分比
    // 与「停止后接着听」的落点都以朗读坐标为准，不走 `RC1` 视口闸门）。
    unawaited(_writeTtsProgress(chapterIndex, paraIndex));
    // `TTS-03`：跨章续读时通知栏 / 锁屏副标题跟着换章（同章不重复上屏）。
    if (chapterIndex != _ttsMediaChapter) {
      _ttsMediaChapter = chapterIndex;
      _ttsAudio?.updateChapter(_ttsChapterTitle(chapterIndex));
    }
    // `TTS-02` ②：可见就不滚（避免短段逐段抖动）；③ 跟随被手动滚动暂停则不滚。
    if (!_ttsFollow.shouldFollow) return;
    if (_speakingVisible(chapterIndex, paraIndex)) return;
    if (_pagedMode) {
      unawaited(_followSpeakingPaged(chapterIndex, paraIndex));
    } else {
      _followSpeakingList(chapterIndex, paraIndex);
    }
  }

  /// 朗读段是否已足够可见（`TTS-02` ② 的几何面）。
  ///
  /// 按段落 key 找渲染盒（[findParagraphBox]：懒构建未上屏 → null = 不可见；
  /// 翻页态 Offstage 下仍布局，照常可测），与视口做 [isParagraphVisible] 判定。
  bool _speakingVisible(int chapterIndex, int paraIndex) {
    final String href = _hrefAt(chapterIndex);
    if (href.isEmpty) return false;
    final RenderBox? viewport = _viewportBox();
    if (viewport == null || !viewport.hasSize) return true; // 测不了就不动
    final RenderBox? box = findParagraphBox(context, href, paraIndex);
    if (box == null) return false;
    final Rect paraRect = box.localToGlobal(Offset.zero) & box.size;
    final Rect viewRect =
        viewport.localToGlobal(Offset.zero) & viewport.size;
    return isParagraphVisible(paraRect, viewRect);
  }

  /// ListView 路径跟随滚动：复用 `CNT-04c` 的段落级「估算 + 校正」底座，
  /// **不压返回栈**（跟随是朗读的内部移动，不是导航历史）。
  void _followSpeakingList(int chapterIndex, int paraIndex) {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return;
    _paraKeys['$chapterIndex:$paraIndex'] ??= GlobalKey();
    final double roughPos = math.min(1.0, (paraIndex + 1) / 12.0);
    _beginScrollTo(chapterIndex, roughPos, paraIndex: paraIndex);
  }

  /// 分页路径跟随滚动：段首字符偏移一次落位（与 `CNT-04c` 分页分支同
  /// 算法，**不压返回栈**；`_pagedJumpTo` 内部自带互斥与语义坐标直写）。
  Future<void> _followSpeakingPaged(int chapterIndex, int paraIndex) async {
    if (!mounted || _disposed || !_pagedMode) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final int target = chapterIndex.clamp(0, chapters.length - 1);
    if (_cache.peek(target) == null) {
      await _loader?.loadFirstBatch(target);
      if (!mounted || _disposed) return;
    }
    final List<String> paragraphs =
        _cache.peek(target)?.paragraphList ?? const <String>[];
    int charOffset = 0;
    for (int p = 0; p < paraIndex && p < paragraphs.length; p++) {
      charOffset += paragraphs[p].length;
    }
    final int total = PagePaginator.charCountOf(paragraphs);
    await _pagedJumpTo(
      target,
      pos: total > 0 ? charOffset / total : 0.0,
      charOffset: charOffset,
      // `TTS-06`：直写已在本段入场时同异步落盘（坐标与 saveOld 逐位相同），
      // 且 saveOld 与直写共挤同路径写队列会拖过跟随落位窗口、被下一段
      // `++_primeSeq` 作废 → 跟随跳不 saveOld。
      saveOld: false,
    );
  }

  /// `TTS-06` 进度直写：把朗读坐标写入阅读进度 + 回写书架百分比
  /// （F6「每段读完写入进度」；TTS-06 ①② 的数据面）。
  ///
  /// 不走 [_saveProgress] 的 `RC1` 闸门——朗读坐标来自段落下标（真值不依赖
  /// 视口几何，闸门防的「几何误差当真值」在此不存在）；字数换算与
  /// [_followSpeakingPaged] 同源（段落前缀和 / 全章字数）。
  ///
  /// 同时记入 [_ttsProgress]：视口可能落后于朗读（跟随被手动滚动暂停），
  /// [_saveProgress]（含 dispose 收尾）优先取它防陈旧视口坐标覆盖。
  /// 失败静默：下一段推进重试，不影响朗读。
  Future<void> _writeTtsProgress(int chapterIndex, int paraIndex) async {
    if (_disposed) return;
    final List<Chapter>? chapters = _chapters;
    if (chapters == null || chapters.isEmpty) return;
    final int index = chapterIndex.clamp(0, chapters.length - 1);
    final List<String> paragraphs =
        _cache.peek(index)?.paragraphList ?? const <String>[];
    int charOffset = 0;
    for (int p = 0; p < paraIndex && p < paragraphs.length; p++) {
      charOffset += paragraphs[p].length;
    }
    final int total = PagePaginator.charCountOf(paragraphs);
    final double pos = total > 0 ? charOffset / total : 0.0;
    _ttsProgress = (chapterIndex: index, chapterPos: pos);
    // 恢复中途不重测版面（mid-flight offset 不进快照），其余时间取现场。
    final LocalLayoutHint? hint =
        _restoring ? _lastLocalHint : _buildLocalHint() ?? _lastLocalHint;
    final int now = DateTime.now().millisecondsSinceEpoch;
    try {
      await widget.progressStore.save(ReadingProgress(
        bookId: widget.record.bookId,
        chapterHref: chapters[index].href,
        chapterIndex: index,
        chapterPos: pos,
        updatedAt: now,
        localHint: hint,
      ));
      await widget.repository.markRead(
        widget.record.bookId,
        lastReadAt: now,
        readProgress: _overallProgress(index, pos),
      );
    } catch (_) {
      // 保存失败不影响朗读；下一段推进重试。
    }
  }

  /// 朗读引擎致命错误 → 中文 toast（按钮随 onChanged 复位）。
  void _onTtsError(String message) {
    if (!mounted || _disposed) return;
    GlassOverlays.showToast(
      context: context,
      message: message,
      type: GlassToastType.error,
    );
  }

  /// 朗读运行态变化 → 刷按钮；彻底停止时撤高亮。
  /// 同步刷系统会话（`TTS-03`）：在播 ↔ 暂停映射通知栏按钮，停止即撤通知。
  void _onTtsChanged() {
    if (!mounted || _disposed) return;
    final TtsController? tts = _tts;
    final ({int chapterIndex, int paraIndex})? speaking = _speaking;
    setState(() {
      if (!(tts?.isRunning ?? false)) _speaking = null;
    });
    if (tts == null) return;
    if (_ttsRestarting) return; // 换章重启的过渡态：会话保持不动
    if (tts.isRunning) {
      _ttsAudio?.setPlaying(tts.isActive);
      if (!tts.isActive && speaking != null) {
        // `TTS-06`（F6）：暂停也落盘——停在哪段就记哪段（接着听的落点）。
        unawaited(_writeTtsProgress(speaking.chapterIndex, speaking.paraIndex));
      }
    } else {
      unawaited(_ttsAudio?.end());
      _sleepTimer?.cancel(); // `TTS-05`：停读撤定时（下次开读按设定重启）
      if (speaking != null) {
        // `TTS-06`（F6）：停止 → 落盘当前朗读段（重开接着听的落点）。
        unawaited(_writeTtsProgress(speaking.chapterIndex, speaking.paraIndex));
      }
    }
  }

  /// 人物梳理可用性（`AI-07`）：依赖与摘要同组（配置 + 客户端 + 摘要缓存，
  /// 成品复用 `aiCache/` 合并级条目）+ `AI-09` ② 全局开关。
  ///
  /// 与问答不同，不涉及 `AI-09` ③ 受限标注（PRD 原文该项为问答专属）——
  /// 发送范围由页面内「仅已读 / 全书」自选，范围行照常可见。
  bool get _entitiesEnabled {
    final ProviderStore? store = widget.aiStore;
    return store != null &&
        widget.aiClient != null &&
        widget.summaryCache != null &&
        store.prefs.aiEnabled;
  }

  /// 打开人物与设定梳理页（`AI-07`：范围可切「仅已读」，点出场章节
  /// 引用关本页并跳回原文）。
  void _openEntityPage() {
    final ProviderStore? store = widget.aiStore;
    final AiClient? client = widget.aiClient;
    final SummaryCache? cache = widget.summaryCache;
    final List<Chapter>? chapters = _chapters;
    if (!_entitiesEnabled ||
        store == null ||
        client == null ||
        cache == null ||
        chapters == null ||
        chapters.isEmpty) {
      return;
    }
    unawaited(Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => EntityPage(
          aiStore: store,
          aiClient: client,
          summaryCache: cache,
          bookId: widget.record.bookId,
          chapters: chapters,
          // 「仅已读」上界 = 滚动实时章（`RD-04` `chapterIndex` 的显示口径）。
          readUptoIndex: _liveIndex,
          loadText: _summaryTextAt,
          onJump: (int index) {
            Navigator.of(ctx).pop();
            _exitChrome(); // 落到目标页顶 ⇒ 必须收起顶栏，否则目标被它压住。
            unawaited(_goToChapter(index));
          },
        ),
      ),
    ));
  }

  /// 渲染文本空间的纯文本（偏移与 [RenderParagraph] 位置对齐：
  /// placeholder 计 1、不吞语义标签）。
  String _renderTextOf(ParagraphHit hit) =>
      hit.render.text.toPlainText(includeSemanticsLabels: false);

  /// 长按起手：命中段落 → 词级选区 + 操作条；点在空白 / 标题上清选区。
  void _onSelectionStart(Offset global) {
    final ParagraphHit? hit = findParagraphAt(context, global);
    if (hit == null) {
      _clearSelection();
      return;
    }
    final TextPosition pos =
        hit.render.getPositionForOffset(hit.render.globalToLocal(global));
    final TextRange range = hit.render.getWordBoundary(pos);
    final String text = _renderTextOf(hit);
    final ({int start, int end}) word = normalizeWordRange(
      text,
      range.start,
      range.end,
      pos.offset,
    );
    if (word.start >= word.end) {
      _clearSelection();
      return;
    }
    _selHit = hit;
    _selAnchor = word;
    _applySelRange(hit, word);
  }

  /// 拖拽扩展：以起手词为锚，向指针处的词边界取 min/max 合并。
  void _onSelectionMove(Offset global) {
    final ParagraphHit? hit = _selHit;
    final ({int start, int end})? anchor = _selAnchor;
    if (hit == null || anchor == null || !hit.render.attached) return;
    final TextPosition pos =
        hit.render.getPositionForOffset(hit.render.globalToLocal(global));
    final TextRange range = hit.render.getWordBoundary(pos);
    final String text = _renderTextOf(hit);
    final ({int start, int end}) word = normalizeWordRange(
      text,
      range.start,
      range.end,
      pos.offset,
    );
    final int start = math.min(anchor.start, word.start);
    final int end = math.max(anchor.end, word.end);
    if (start >= end) return;
    _applySelRange(hit, (start: start, end: end));
  }

  /// 起手结束：保留选区与操作条（没选上则收尾清场）。
  void _onSelectionEnd() {
    _selHit = null;
    _selAnchor = null;
    if (_selection == null) _clearSelection();
  }

  /// 把 [range] 写入选区状态（范围未变则不 rebuild——拖拽逐帧移动只在
  /// 跨词 / 跨字时才标脏）。
  void _applySelRange(ParagraphHit hit, ({int start, int end}) range) {
    final ParaSelection? cur = _selection;
    if (cur != null &&
        cur.chapterHref == hit.href &&
        cur.paraIndex == hit.paraIndex &&
        cur.start == range.start &&
        cur.end == range.end) {
      return;
    }
    final Rect? rect = _selRectFor(hit, range);
    if (rect == null) return;
    final String snapshot = _renderTextOf(hit)
        .substring(range.start, range.end)
        .replaceAll('\uFFFC', '')
        .trim();
    if (snapshot.isEmpty) return;
    setState(() {
      _selection = ParaSelection(
        chapterHref: hit.href,
        paraIndex: hit.paraIndex,
        start: range.start,
        end: range.end,
        text: snapshot,
      );
      _selectionRect = rect;
    });
  }

  /// 选区盒 → 视口 Stack 局部坐标（操作条钉位用；多行取包围盒）。
  Rect? _selRectFor(ParagraphHit hit, ({int start, int end}) range) {
    final List<TextBox> boxes = hit.render.getBoxesForSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    );
    if (boxes.isEmpty) return null;
    Rect rect = boxes.first.toRect();
    for (final TextBox box in boxes.skip(1)) {
      rect = rect.expandToInclude(box.toRect());
    }
    final RenderBox? stack = _viewportBox();
    if (stack == null) return null;
    final Offset local =
        stack.globalToLocal(hit.render.localToGlobal(rect.topLeft));
    return local & rect.size;
  }

  /// 清选区（起手点空 / 关闭按钮 / 滚动与翻页起手；无选区时零开销）。
  void _clearSelection() {
    _selHit = null;
    _selAnchor = null;
    if (_selection == null && _selectionRect == null) return;
    setState(() {
      _selection = null;
      _selectionRect = null;
    });
  }

  /// 选区操作条（[_selection] 非空时钉在选区上方；顶到边则落到下方）。
  Widget _buildSelectionBar() {
    final Rect rect = _selectionRect ?? Rect.zero;
    const double barW = 200;
    const double barH = 44;
    double left = rect.center.dx - barW / 2;
    final double viewW = _viewportWidth;
    if (viewW > 0) {
      left = left.clamp(8.0, math.max(8.0, viewW - barW - 8));
    } else if (left < 8) {
      left = 8;
    }
    double top = rect.top - barH - 8;
    if (top < 8) top = rect.bottom + 8;
    return Positioned(
      left: left,
      top: top,
      child: SelectionActionBar(
        onTranslate: () => _openSelectionSheet(SelectionAiMode.translate),
        onExplain: () => _openSelectionSheet(SelectionAiMode.explain),
        onClear: _clearSelection,
      ),
    );
  }

  /// 打开划词面板（`AI-09`：最保守模式只发选文，否则带前后段落上下文）。
  void _openSelectionSheet(SelectionAiMode mode) {
    final ParaSelection? sel = _selection;
    final ProviderStore? store = widget.aiStore;
    final AiClient? client = widget.aiClient;
    final VocabStore? vocab = widget.vocabStore;
    if (sel == null || store == null || client == null || vocab == null) {
      return;
    }
    String? before;
    String? after;
    if (!store.prefs.selectionOnly) {
      final List<Chapter>? chapters = _chapters;
      final int ci =
          chapters?.indexWhere((Chapter c) => c.href == sel.chapterHref) ?? -1;
      if (ci >= 0) {
        final List<String>? paras = _cache.peek(ci)?.paragraphList;
        if (paras != null) {
          if (sel.paraIndex > 0 && sel.paraIndex - 1 < paras.length) {
            before = plainParagraphText(paras[sel.paraIndex - 1]);
          }
          if (sel.paraIndex + 1 < paras.length) {
            after = plainParagraphText(paras[sel.paraIndex + 1]);
          }
        }
      }
    }
    unawaited(showSelectionAiSheet(
      context,
      mode: mode,
      selection: sel,
      aiStore: store,
      aiClient: client,
      vocabStore: vocab,
      bookId: widget.record.bookId,
      bookTitle: widget.record.title,
      before: before,
      after: after,
    ));
  }

  /// 正文容器。
  ///
  /// [systemMq] 必须是 **Scaffold 外层**的 MediaQuery（由 [build] 传入）：正文预算
  /// 只吃系统 inset，不吃 chrome（见下方 `topInset` / `bottomInset` 注释）。
  Widget _buildBody(ThemeData theme, MediaQueryData systemMq) {
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
        // 正文**可用**高度：扣掉顶部系统栏 + 底部常驻读数让位。
        //
        // ⚠️ 这里的 `context` 是 **LayoutBuilder 的**（遮蔽了 `State.context`），
        // `MediaQuery.of(context)` 拿到的是 `Scaffold` 给 **body** 加工过的那份：
        // 唤出 chrome 时 `appBar != null` ⇒ `removeTop`、`bottomNavigationBar != null`
        // ⇒ `removeBottom`（`scaffold.dart:3030-3033`），于是顶部 44→0、底部 34→0
        // （探针实测）。**几何一律取外层的 [systemMq]**——body 那份只该影响其子孙
        // 自己的 `SafeArea`，不该影响排版。
        //
        // 这是 `TYP-09` 契约（chrome 不改正文排版区高度）的另一半：`Scaffold` 侧已用
        // `extendBody*` 把 body 钉成满屏，此处再把两条 inset 钉成系统值 ⇒
        // `usableHeight` 与 chrome 状态**完全无关**（探针实测 746 → 恒定 746，
        // 改前唤出 chrome 会掉到 587）。
        final double topInset = systemMq.padding.top;
        // 底部系统栏让位（手势导航条，真机约 34dp）。
        //
        // ⚠️ 只让开「文字」不让开「底色」：让位由 [ReaderProgressIndicator] 内部
        // 吃掉（它的底色须铺到屏幕下缘）。同一个量已由 [build] 传给底部层，
        // 这里负责把它算进正文预算——两处**必须同源**，否则正文会被多盖住一条。
        final double bottomInset = systemMq.padding.bottom;
        final double reserve = _kProgressIndicatorReserve + bottomInset;
        final double usableHeight = math.max(
          0.0,
          constraints.maxHeight - topInset - reserve,
        );
        _syncPageConfig(PaginationConfig(
          pageWidth: constraints.maxWidth - _settings.pageMargin.horizontal,
          // 页高按**可用**高度算：否则每页都会被上下各切掉一截。
          pageHeight: usableHeight > 0
              ? usableHeight
              : constraints.maxHeight,
          textStyle: bodyStyle,
          paragraphSpacing: 16,
          textScaleFactor: systemMq.textScaler.scale(1.0),
        ));
        _ensureController();
        // 划词操作条（选区非空时钉在选区上方——构建期算好，按层序插入）。
        final Widget? selBar =
            _selection != null ? _buildSelectionBar() : null;
        return Padding(
          // **只让顶部**（让系统状态栏）；底部一律不加，见下。
          //
          // 顶部让位与 chrome 无关：`topInset` 取自 Scaffold **外层**的系统 inset
          // （见上方注释），且 `extendBodyBehindAppBar: true` 让 body 从 y=0 起画，
          // 所以**两种 chrome 状态下这里都是同一个值**——正文顶不会因为唤出顶栏
          // 而挪位（改前非全屏时 body 被 `contentTop = appBarHeight` 顶下去）。
          //
          // 底部**不能**加在这一层：常驻读数挂在 Stack 的 `bottom: 0`（现在移到了
          // Scaffold 的底部层，见 [build]），把 28dp 加在 Stack **外面**只会把
          // 「正文 + 读数」整体上移、两者照旧重叠，还在控制条上方白留一条 28dp
          // 空带——真机截图实测即「末行被读数盖住变暗 + 被切」。正确做法：在 Stack
          // **内部**只给正文让位（见 `Positioned.fill` 里那个 Padding）。
          //
          // 底部也不加系统 inset：那个量由底部层（[ReaderProgressIndicator] 的
          // `bottomInset`）自己吃掉，它的底色要铺到屏幕下缘；这里重复计入会让正文
          // 白让一条、且与控制条口径打架。
          padding: EdgeInsets.only(top: topInset),
          // 正文容器（已让开上下 inset）：测试与选区定位都以此为视口基准。
          child: SizedBox.expand(
            key: const ValueKey<String>('reader-viewport'),
            child: KeyedSubtree(
              key: _viewportKey,
              child: Stack(
              children: <Widget>[
              // 正文让开常驻读数：Padding 必须在 Stack **内部**、只裹滚动体，
              // 读数自身在外层贴屏幕底边——这样「内容底」与「读数顶」才真的错开
              // （`usableHeight` 同样扣这段 reserve，两侧口径一致）。
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(bottom: reserve),
                  // 正文可排版区（测试用它钉「内容底 ≤ 读数顶」）。
                  // 与 `reader-viewport` 同款：key 挂在 **Padding 之内**的盒上，
                  // 否则量到的是含 padding 的外框、与视口等底，量不出让位。
                  child: SizedBox.expand(
                    key: const ValueKey<String>('reader-content-area'),
                    child: NotificationListener<ScrollUpdateNotification>(
                  // `TYP-09` 验收②：滚动实时刷新进度显示（只写显示字段）。
                  onNotification:
                      _pagedMode ? _onPagedScrollUpdate : _onScrollUpdate,
                  child: NotificationListener<ScrollEndNotification>(
                    onNotification:
                        _pagedMode ? _onPagedScrollEnd : _onScrollEnd,
                    // `TYP-09` 验收③（2026-10-08 改口径；2026-10-10 再收窄）：
                    // chrome 切换的唯一入口——点正文**九宫格中宫**（落点闸门
                    // [_onContentTapUp]：整屏 3×3，只有落进中宫的 tap 响应，
                    // 其余八格无事——防阅读时侧边 / 角落误触翻出 chrome）。
                    //
                    // ⚠️ 这一层**必须是正文的祖先**（包在外面），不能做 Stack 里
                    // 覆盖在正文之上的兄弟层：`HitTestBehavior.translucent` 的
                    // 兄弟层会把自己先加进 `HitTestResult.path`，而手势竞技场按
                    // path 顺序判定（`GestureBinding.dispatchEvent` 从 index 0 起
                    // 派发、`sweep` 取首个成员）⇒ 覆盖层的 tap 会**抢掉**正文里
                    // 链接的 `TapGestureRecognizer`（`CNT-04` 链接点击会失效）。
                    // 做祖先时 path 是「链接 → 本层」，链接先入竞技场即胜出。
                    //
                    // 不干扰滚动：`TapGestureRecognizer` 一旦超出 `kTouchSlop`
                    // 就自我拒绝，拖拽 / 惯性 / 长按划词都不受影响。
                    child: KeyedSubtree(
                      key: _chromeToggleKey,
                      child: GestureDetector(
                        key: const Key('reader-chrome-toggle'),
                        behavior: HitTestBehavior.translucent,
                        onTapUp: _onContentTapUp,
                        child: _pagedMode
                            ? _buildPagedBody()
                            : ListView.builder(
                                controller: _controller,
                                // 进度指示条的占位已由**上方那个 Padding**
                                // （`reserve`）统一提供，
                                // 此处只需章节间的呼吸留白（改前 40 是在重复为同一条让位）。
                                padding:
                                    const EdgeInsets.only(top: 8, bottom: 12),
                                itemCount: chapters.length,
                                itemBuilder:
                                    (BuildContext context, int index) =>
                                        _buildChapterItem(theme, bodyStyle, index),
                              ),
                      ),
                    ),
                  ),
                    ),
                  ),
                ),
              ),
              // `AI-02`/`AI-03`：划词手势层——只注册长按族（不拦 tap /
              // 滚动拖拽 / 翻页横滑，arena 竞争照常）；translucent 让下方
              // 滚动体与链接照常参与命中。恢复遮罩盖在其上（恢复期不选词）。
              if (_selectionEnabled)
                Positioned.fill(
                  child: GestureDetector(
                    key: const Key('reader-selection-gesture'),
                    behavior: HitTestBehavior.translucent,
                    onLongPressStart: (LongPressStartDetails d) =>
                        _onSelectionStart(d.globalPosition),
                    onLongPressMoveUpdate: (LongPressMoveUpdateDetails d) =>
                        _onSelectionMove(d.globalPosition),
                    onLongPressEnd: (LongPressEndDetails d) =>
                        _onSelectionEnd(),
                    // 无子则代理盒零尺寸、永不命中——铺满当命中面。
                    child: const SizedBox.expand(),
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
              // `AI-02`/`AI-03`：选区操作条（层序：恢复遮罩之上、亮度遮罩之下）。
              ?selBar,
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
              // `TYP-09`：常驻读数**不在这里**——它已移到 Scaffold 的底部层
              // （见 [build] 的 `bottomNavigationBar`），与控制条同槽、上下相邻。
              //
              // 为什么必须挪出去：`extendBody: true` 之后正文铺满整屏，读数的
              // `bottom: 0` 会被控制条整块盖住（`control_bar.dart` 的窄屏让位
              // 明确依赖「读数在控制条正上方」）。放进底部层则两态都正确：
              // chrome 收起时它贴屏幕底边，唤出时自动排在控制条之上。
              ],
              ),
            ),
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
        key: _chapterKeyAt(index),
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
        key: _chapterKeyAt(index),
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
      key: _chapterKeyAt(index),
      padding: EdgeInsets.fromLTRB(marginH, 16, marginH, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 标题左对齐加粗、无横线（2026-10-09 负责人拍板，改 TYP-04「居中」旧
          // 口径）；颜色随背景色板（TYP-08 对比度 / 夜间无白底）。章间空行由
          // 本块外层 Padding（top 16 + 上一章 bottom 24）提供，分页路径则挂在
          // 标题块顶部 [_kHeadingGapTop]——两条路径都保证章与章隔开。
          Text(
            heading,
            textAlign: TextAlign.left,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: bodyStyle.color,
            ),
          ),
          const SizedBox(height: _kHeadingGapBottom),
          for (int p = 0; p < paragraphs.length; p++)
            Padding(
              // CNT-04c：链接跳转的目标段落懒挂 key（仅跳转目标段有 key，
              // 其余段为 null key，不影响渲染），供 _paragraphPointOffset 精确测量。
              key: _paraKeys['$index:$p'],
              padding: const EdgeInsets.only(bottom: 16),
              // TYP-04：首行缩进 + `<b>`/`<i>` 内联样式（白名单）+ `<img>` 图片（CNT-01）。
              // CNT-04c：`onLinkTap` 接链接跳转（同步 tear-off，跨帧相等防 recognizer 重建）。
              child: SpeakingHighlight(
                // `TTS-02` ①：朗读段底色（恒定包装，翻转零重建）。
                active: _speaking?.chapterIndex == index &&
                    _speaking?.paraIndex == p,
                child: InlineParagraph(
                  // `AI-02`/`AI-03`：段落 key 供 findParagraphAt 命中（划词起点），
                  // selection 叠选区底色（与分页 PageContent 同款投影）。
                  key: paragraphKey(chapter.href, p),
                  text: withFirstLineIndent(paragraphs[p]),
                  style: bodyStyle,
                  resolveImage: _resolveImage,
                  onLinkTap: _onLinkTapped,
                  // CNT-06 验收②：搜索跳转后关键词高亮（空 = 不高亮）。
                  highlightQuery:
                      _searchHighlight.isEmpty ? null : _searchHighlight,
                  selection: _paraSelection(chapter.href, p),
                ),
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
