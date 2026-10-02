// 入口：初始化平台能力 → 加载设置 → 构造书库 → runApp。
//
// 纯 Flutter 自绘：不使用 WebView / foliate-js。
// 目标平台：Android / iOS / Windows / macOS / Linux（平台能力差异按 PRD §15.3 降级表处理）。
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ai/ai_client.dart';
import 'ai/provider_store.dart';
import 'ai/secure_key_store.dart';
import 'app.dart';
import 'highperf/high_perf_registry.dart';
import 'library/library_repository.dart';
import 'meta/cover_store.dart';
import 'platform/app_paths.dart';
import 'platform/path_provider_app_paths.dart';
import 'platform/pdf_engine.dart';
import 'platform/pdfrx_pdf_engine.dart';
import 'platform/secure_store_io.dart';
import 'reader/progress_store.dart';
import 'settings/perf_frame_monitor.dart';
import 'settings/perf_prefs_store.dart';
import 'settings/settings_store.dart';
import 'settings/shelf_layout_store.dart';
import 'settings/shelf_prefs_store.dart';
import 'stats/stats_service.dart';
import 'ui/glass_runtime.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  // path_provider 等插件在访问前需要先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();

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
  final ProviderStore aiStore = ProviderStore(
    dataDir,
    AiKeyVault(FileSecureStore(directory: dataDir)),
  );
  final AiClient aiClient = AiClient();
  await Future.wait(<Future<void>>[
    _warmUpGlassShaders(),
    settings.load(),
    perfPrefs.load(),
    shelfPrefs.load(),
    shelfLayout.load(),
    aiStore.load(),
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

  // `UI-01` ②：`brightnessResolver: Theme.maybeBrightnessOf` 让玻璃控件跟随
  // **应用 ThemeMode**（light / dark / system），而非仅系统亮度。
  // 包裹位置在 `MReaderApp` **之外**，`app.dart` 里 builder 的透明 Material 地基一字不动。
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
        ),
      ),
      brightnessResolver: Theme.maybeBrightnessOf,
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
