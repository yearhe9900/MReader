// 入口：初始化平台能力 → 加载设置 → 构造书库 → runApp。
//
// 纯 Flutter 自绘：不使用 WebView / foliate-js。
// 目标平台：Android / iOS / Windows / macOS / Linux（平台能力差异按 PRD §15.3 降级表处理）。
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ai/ai_client.dart';
import 'ai/provider_store.dart';
import 'ai/rag.dart';
import 'ai/secure_key_store.dart';
import 'ai/summary_cache.dart';
import 'ai/vocab_store.dart';
import 'app.dart';
import 'highperf/high_perf_registry.dart';
import 'library/book_index.dart';
import 'library/library_repository.dart';
import 'meta/cover_store.dart';
import 'platform/app_paths.dart';
import 'platform/path_provider_app_paths.dart';
import 'platform/pdf_engine.dart';
import 'platform/pdfrx_pdf_engine.dart';
import 'platform/secure_store.dart';
import 'platform/secure_store_io.dart';
import 'reader/bookmark_store.dart';
import 'reader/progress_store.dart';
import 'reader/reading_prefs_store.dart';
import 'settings/perf_frame_monitor.dart';
import 'settings/perf_prefs_store.dart';
import 'settings/settings_store.dart';
import 'settings/shelf_layout_store.dart';
import 'settings/shelf_prefs_store.dart';
import 'stats/session_store.dart';
import 'stats/stats_service.dart';
import 'stats/stats_sync.dart';
import 'sync/backup.dart';
import 'sync/book_upload.dart';
import 'sync/bookmark_sync.dart';
import 'sync/entry_sync.dart';
import 'sync/progress_sync.dart';
import 'sync/restore.dart';
import 'sync/settings_sync.dart';
import 'sync/sync_config_store.dart';
import 'sync/sync_trigger.dart';
import 'sync/webdav_client.dart';
import 'tts/online_tts.dart';
import 'tts/tts_settings.dart';
import 'ui/glass_material.dart';
import 'ui/glass_runtime.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  // path_provider 等插件在访问前需要先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();

  // `UI-08` edge-to-edge（2026-10-19 上游平板模式批）：内容铺到状态栏 /
  // 手势条下面。
  //
  // 不铺的话，应用窗口从状态栏下方开始，状态栏那一条就是**系统自己画的
  // 底色 + 压色**——平板实机看起来就是一条灰带，与页面底色对不上（上游
  // 2026-10-18 同款实拍）。铺开之后状态栏背后是页面自己的底色 / 顶栏磨砂，
  // 配合 `app.dart` 里的 `AnnotatedRegion<SystemUiOverlayStyle>`（透明状态栏 +
  // 图标随明暗翻转）才是一条连续的界面。
  //
  // 代价是浮层要自己让开安全区：侧栏顶 = `padding.top + railMargin`；底栏浮
  // 起口径本身即距**物理屏底** 24.2（edge-to-edge 下 `Positioned.bottom` 直接
  // 量到屏底，不叠 `padding.bottom`，见 `home_shell.dart`）；各页滚动容器的
  // 底部空白 `kShellBottomInset` 已含安全区与呼吸余量。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // `FMT-01` / `META-10` ③：PDF 渲染内核经**注入缝**接入（`Q4 ①` 拍板 pdfrx 2.6.5）。
  // 全仓唯一 import pdfrx 的文件是右边这个适配器；格式层（`PdfSource`）只认
  // `PdfEngine` 抽象，因此换内核不动格式层与 UI。pdfrx 自身的初始化（原生库准备）
  // 是惰性的，首次开 PDF 才发生，不拖慢冷启动。
  PdfEngineProvider.current = PdfrxPdfEngine();

  // `RUST-01 ③`：加速能力**探测只做一次**（启动时），结论缓存进注册表；
  // 打开书时不再探测、无 IO 成本。探测失败**不抛、不阻塞**——整体回落纯 Dart。
  //
  // T01（M35-T01）阶段这里**不传 engine**：`lib/highperf/ffi/**`（T04）尚未落地，
  // 如实取纯 Dart 回落实例，而不是给一个空引擎让它探出「版本不匹配」这种假原因。
  // T04/T05 接入时，本行改为传入 FFI 引擎工厂（唯一 import FRB 的文件仍在
  // `lib/highperf/ffi/high_perf_ffi_engine.dart`，本文件只做组合，不碰 FRB 细节）。
  final HighPerfRegistry highPerf = HighPerfRegistry.fromEnvironment();

  // `UI-01` ① + 平台能力经抽象注入（PRD §15.1）：
  // 玻璃着色器预热、数据目录解析/设置加载、加速层探测**三者并行**——互不依赖，
  // 串行会把冷启动叠加两段等待（`v2.3` 冷启动是硬指标）。
  // 预热失败不阻塞启动——降级为「无玻璃效果但仍可运行」（诚实降级）。
  final AppPaths appPaths = PathProviderAppPaths();
  final Directory dataDir = await appPaths.dataDir();
  final SettingsStore settings = SettingsStore(dataDir);
  final PerfPrefsStore perfPrefs = PerfPrefsStore(dataDir);
  // 书架视图偏好（筛选 / 排序）：与设置同一形制（`JsonStore` → `AtomicFile`），
  // 但独立文件——改字号不该把书架筛选状态一起重写（见 `ShelfPrefsStore` 头注）。
  final ShelfPrefsStore shelfPrefs = ShelfPrefsStore(dataDir);
  // 书架**布局**（手动排序顺序 + 文件夹归属）：与偏好分文件——改一次筛选不该
  // 连带重写布局数据；也因为不动 `BookRecord` 的序列化，**没有旧索引兼容问题**
  // （见 `ShelfLayoutStore` 头注的拍板记录）。
  final ShelfLayoutStore shelfLayout = ShelfLayoutStore(dataDir);
  // M3-T01：AI 底座（`AI-01`/`AI-08`/`AI-09`）——SecureStore（`DATA-02` 明文降级
  // 实现，M4 接系统密钥库）→ 密钥门面 → 配置存储；AiClient 是全 AI 功能共用的
  // 流式 / 取消 / 并发闸出口。三者均为进程内唯一实例。
  // 同一 SecureStore 实例同时供 AI Key（`ai.key.`）与 WebDAV 密码（`sync.password.`）
  // 两个命名空间使用（`DATA-02`：凭据统一走安全存储，不散落多份实现）。
  final SecureStore secureStore = FileSecureStore(directory: dataDir);
  final ProviderStore aiStore = ProviderStore(dataDir, AiKeyVault(secureStore));
  final AiClient aiClient = AiClient();
  // M4-T01：WebDAV 同步通道（`SYNC-01`/`SYNC-07`）——配置存储（密码经同一
  // SecureStore 的 `sync.password.` 键）+ 纯 dart:io 客户端；进程内唯一实例，
  // 测试连接与后续 T02~T06 同步任务复用同一个 client（通道只做一遍）。
  final SyncConfigStore syncStore =
      SyncConfigStore(dataDir, SyncPasswordVault(secureStore));
  final WebdavClient webdavClient = WebdavClient();
  // M3-T02：生词本（`AI-03` ②③）——进程内唯一实例，笔记页 / 生词本页 / 阅读页
  // 释义面板共用；词条数很小，加载并入下面的并行等待（不占冷启动串行）。
  final VocabStore vocabStore = VocabStore(dataDir);
  // M3-T03：摘要缓存（`AI-04`/`AI-05`）——目录 = PRD §10.3 `aiCache/`
  // （全量备份按目录整体收；WebDAV 同步默认关，本地缓存是验收硬要求）。
  final SummaryCache summaryCache =
      SummaryCache(await appPaths.subDir('aiCache'));
  // M3-T04：跟书问答索引（`AI-06`，PRD §8.3「索引本地持久化」）——与摘要缓存
  // 同目录 `aiCache/`（全量备份按目录整体收）；按书惰性构建 + 分文件缓存，
  // 无全局 load；删书连带清理在书架侧（`shelf_page`）。
  final RagIndexStore ragIndexStore =
      RagIndexStore(await appPaths.subDir('aiCache'));
  // M3-T08：朗读设置（`TTS-04`/`TTS-05`）——与偏好同一形制（`JsonStore` →
  // `AtomicFile`）、独立文件 `tts_settings.json`；注入书架 → 阅读页。
  final TtsSettingsStore ttsSettings = TtsSettingsStore(dataDir);
  // M3-T09：在线 TTS 配置（`TTS-07`）——URL 模板 / OpenAI 兼容 + 音频缓存
  // （`<dataDir>/tts_audio`）；注入书架 → 阅读页，配置页在朗读设置面板内。
  final OnlineTtsStore onlineTts = OnlineTtsStore(dataDir);
  // M4-T05：书籍上传开关（`SYNC-05` ① 默认关）——与其余偏好同一形制，
  // 独立文件 `book_upload.json`；加载并入下面的并行等待。
  final BookUploadPrefsStore bookUploadPrefs = BookUploadPrefsStore(dataDir);
  // M4-T06：阅读统计同步开关（`STAT-08` ③ 默认开）——同一形制、独立文件
  // `stats_sync.json`（缺失即开，fail-open）；加载并入下面的并行等待。
  final StatsSyncPrefsStore statsSyncPrefs = StatsSyncPrefsStore(dataDir);
  await Future.wait(<Future<void>>[
    _warmUpGlassShaders(),
    settings.load(),
    perfPrefs.load(),
    shelfPrefs.load(),
    shelfLayout.load(),
    aiStore.load(),
    syncStore.load(),
    vocabStore.load(),
    summaryCache.load(),
    ttsSettings.load(),
    onlineTts.load(),
    bookUploadPrefs.load(),
    statsSyncPrefs.load(),
    highPerf.warmUp(),
  ]);

  // `RUST-01 ④`：把探测结论写进组合根注入点，供深层纯层（`openBook()` 的调用方）
  // 读取——业务 / UI 层不感知实现来源，也不写这个位置。
  HighPerfRegistryProvider.current = highPerf;

  // `RUST-01`「回落事实只写调试日志（release 不输出）」+ `RUST-10 ②` 可观测性：
  // 一行快照足以判定「当前生效的是哪一份实现」。
  if (kDebugMode) {
    debugPrint('[MReader] 加速层：${highPerf.describe()}');
  }

  // `UI-05` / `UI-06` 档位生效接线（M2b-T07）：性能偏好 × 自动降级 → 玻璃档位。
  // `bind` 订阅偏好变更（设置页切档即全局生效）；帧预算监控连续超 16ms × 60 帧
  // 时降一档（会话内、不持久化）。低端设备判定注入位默认 false（探测策略待拍板）。
  GlassRuntime.bind(perfPrefs);
  PerfFrameMonitor(onBudgetExceeded: GlassRuntime.noteBudgetDegraded).start();

  // M1-T03：构造封面存储 + 书库仓库（LIB-01~06 的后端）。
  final CoverStore coverStore = FileCoverStore(appPaths);
  final LibraryRepository repository = LibraryRepository(
    paths: appPaths,
    coverStore: coverStore,
  );

  // M1-T04：阅读进度持久化（`RD-04`），注入书架 → 阅读页。
  final ProgressStore progressStore = ProgressStore(appPaths);

  // M3-T10：统计服务（`STAT-03` 数据侧——进程内唯一实例，注入 HomeShell →
  // 统计页；首次载入由统计页 initState 触发，不占冷启动串行等待）。
  final StatsService statsService = StatsService(appPaths);

  // M4-T05（`SYNC-06`/`SYNC-07`）：同步编排链——书签 / 阅读偏好存储先落
  // （阅读页与条目同步共用同一实例），六个引擎 + 触发器全部由组合根构造，
  // 进程内唯一实例。触发器挂在 HomeShell 生命周期上（启动拉进度、退页 /
  // 退 App 上报），入口页是设置页「同步状态与备份」。
  final BookmarkStore bookmarkStore = BookmarkStore(appPaths);
  final ReadingPrefsStore readingPrefsStore = ReadingPrefsStore(appPaths);
  final ProgressSyncState progressSyncState = ProgressSyncState(dataDir);
  final ProgressSyncEngine progressSyncEngine = ProgressSyncEngine(
    client: webdavClient,
    progressStore: progressStore,
    configStore: syncStore,
    state: progressSyncState,
  );
  // BookIndex 无状态（load() 每次读盘）：触发器与书库各持一个实例互不干扰。
  final IndexSync indexSync = IndexSync(
    client: webdavClient,
    index: BookIndex(appPaths),
    configStore: syncStore,
  );
  final BookmarkSync bookmarkSync = BookmarkSync(
    client: webdavClient,
    store: bookmarkStore,
    configStore: syncStore,
  );
  final SettingsSync settingsSync = SettingsSync(
    client: webdavClient,
    prefsStore: readingPrefsStore,
    configStore: syncStore,
  );
  // M4-T06（`STAT-08`）：阅读统计跨设备并集同步——远端 `stats/` 按月分片镜像
  // 本地 SessionStore；开关默认开（缺失即 true），判定先于一切网络请求。
  final StatsSync statsSync = StatsSync(
    client: webdavClient,
    sessionStore: SessionStore(appPaths),
    configStore: syncStore,
    prefs: statsSyncPrefs,
  );
  final BackupEngine backupEngine = BackupEngine(
    paths: appPaths,
    client: webdavClient,
    configStore: syncStore,
  );
  final RestoreEngine restoreEngine = RestoreEngine(
    paths: appPaths,
    client: webdavClient,
    configStore: syncStore,
  );
  final BookUploadEngine bookUploadEngine = BookUploadEngine(
    client: webdavClient,
    prefs: bookUploadPrefs,
    configStore: syncStore,
  );
  final SyncTrigger syncTrigger = SyncTrigger(
    progressEngine: progressSyncEngine,
    indexEngine: indexSync,
    bookmarkEngine: bookmarkSync,
    settingsEngine: settingsSync,
    statsEngine: statsSync,
    backupEngine: backupEngine,
    restoreEngine: restoreEngine,
    bookUploadEngine: bookUploadEngine,
    uploadPrefsStore: bookUploadPrefs,
    statsPrefsStore: statsSyncPrefs,
    syncState: progressSyncState,
    syncConfig: syncStore,
    booksLoader: repository.loadBooks,
    bookFileResolver: repository.bookFile,
  );

  // `UI-01` ②：`brightnessResolver: Theme.maybeBrightnessOf` 让玻璃控件跟随
  // **应用 ThemeMode**（light / dark / system），而非仅系统亮度。
  // 包裹位置在 `MReaderApp` **之外**，`app.dart` 里 builder 的透明 Material 地基一字不动。
  //
  // 2026-10-12 参考图批：补 `theme: GlassMaterial.themeData`——此前**未挂主题**，
  // 所有玻璃面吃库默认材质（玻璃色 12% / blur 5 / 无增白），离参考图
  // （HyperOS 主题商店：强磨砂 + 亮白纱罩 + 边缘光）差距明显。主题是**材质**
  // 单一出处；质量档位链不受影响（主题 quality 恒 null，见 glass_material.dart）。
  // 底栏 / 搜索胶囊 / chips 另走控件级显式 settings（`GlassMaterial.settingsFor`，
  // 主题表达不了 whitenStrength；底栏更是不吃主题的私有预设）。
  //
  // 2026-09-28：`home` 由 `ShelfPage` 改为 [HomeShell]——五 tab（书架 / 统计 / AI /
  // 笔记 / 设置）+ 玻璃浮动底栏；书架成为其中一个 tab，依赖原样透传。
  runApp(
    LiquidGlassWidgets.wrap(
      child: MReaderApp(
        settings: settings,
        home: HomeShell(
          repository: repository,
          coverStore: coverStore,
          progressStore: progressStore,
          perfPrefs: perfPrefs,
          shelfPrefs: shelfPrefs,
          shelfLayout: shelfLayout,
          settings: settings,
          statsService: statsService,
          aiStore: aiStore,
          aiClient: aiClient,
          vocabStore: vocabStore,
          summaryCache: summaryCache,
          ragStore: ragIndexStore,
          ttsSettings: ttsSettings,
          onlineTts: onlineTts,
          syncStore: syncStore,
          syncClient: webdavClient,
          bookmarkStore: bookmarkStore,
          readingPrefsStore: readingPrefsStore,
          syncTrigger: syncTrigger,
        ),
      ),
      brightnessResolver: Theme.maybeBrightnessOf,
      // 玻璃材质单一出处（2026-10-12 参考图批；参数与理由见 `glass_material.dart`）。
      theme: GlassMaterial.themeData,
    ),
  );
}

/// 预热玻璃着色器（`UI-01` ①）。
///
/// `LiquidGlassWidgets.initialize()` 是库的真入口（`lib/liquid_glass_setup.dart`）：
/// 预编译 lightweight / interactive 着色器，并在支持的平台上预编译多趟着色器，
/// 从而避免首帧白闪。这里只负责「调用 + 诚实降级」：
/// 预热失败仅记录，不抛出、不阻塞启动。
Future<void> _warmUpGlassShaders() async {
  try {
    await LiquidGlassWidgets.initialize();
  } catch (error, stackTrace) {
    debugPrint('[MReader] 玻璃着色器预热失败，降级为无玻璃效果：$error');
    debugPrint('$stackTrace');
  }
}

/// M0 验证台首页（**已由 [ShelfPage] 替代**，保留供既有测试引用）。
///
/// M1-T03 后不再作为默认首页。
@Deprecated('M1-T03 后由 ShelfPage 替代；保留供既有测试引用。')
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

@Deprecated('M1-T03 后由 ShelfPage 替代；保留供既有测试引用。')
class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('已由书架页替代')),
    );
  }
}
