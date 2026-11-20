// 书架滚动帧率压测（性能剖析用具；不进 CI 断言，`flutter drive` 手动跑）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 目的与口径
// ══════════════════════════════════════════════════════════════════════════════
// 量化书架页滚动时的 UI（build）/ 光栅（raster）帧耗时分布，定位 120Hz 屏上的
// 丢帧来源（浮动头部多段 `BackdropFilter` 磨砂 / 书卡投影与裁切 / 图片解码等），
// 并给优化前后提供**同口径**对比数据：
//   · 120Hz 帧预算 = 8.333ms（`FrameTiming.totalSpan`，含 build + raster + 合成）；
//   · 视口 = 手机逻辑尺寸 393.3×885.3（列数 3），物理像素 1179×2556 ≈ 3.0M px
//     （与 120Hz 安卓旗舰屏同像素量级）——桌面剖析时把 Flutter 窗口客户区调到
//     目标物理像素，让光栅负载与真机同量级；真机可直接 `-d <device>` 换目标跑；
//   · 数据集 = 120 本真实入库的 TXT 书（2/3 带真封面缩略图 `Image.memory`），
//     覆盖真机书架的「几百本」量级。
//
// ⚠️ 桌面（Windows）与安卓真机的光栅器（Skia / Impeller）实现不同，绝对值仅供
// 归因与前后对比；「120Hz 真机能否稳住」最终以真机跑本压测为准。
//
// 运行：
//   flutter drive --profile -d windows \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/shelf_scroll_bench_test.dart \
//     [--dart-define=BENCH_VARIANT=baseline]
//
// 可调参数（`--dart-define`）：BENCH_VARIANT（结果文件名标签）、BENCH_SCENE
// （归因场景：full = 真实完整壳层；gridblur = 书卡网格 + 同款9段头部磨砂；
// gridblurfast = 同上但 σ×0.6（运动降档效果）；gridfrost = 书卡网格 + 零件
// 磨砂膜（搜索胶囊 / 胶囊行 / 底栏）；grid = 只剩书卡网格；gridlite = 书卡
// 去投影/裁切/墨迹/Hero 的简化卡）、
// BENCH_BOOKS（书数，默认120）、BENCH_PHYS_W / BENCH_PHYS_H（目标物理像素，
// 默认 1179×2556）。场景间跑同口径阶段，差值即各块绘制成本的归因依据。
//
// 输出：stdout 摘要 + `build/shelf_bench/<variant>.json`（各阶段 build / raster /
// total 的 p50/p90/p99/max、超 8.33ms 与 16.67ms 帧数、平均帧率）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/app.dart' show MReaderApp;
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/highperf/ffi/high_perf_ffi_engine.dart';
import 'package:mreader/highperf/high_perf_registry.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/model/book_meta.dart' show StoredCover;
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/settings/perf_frame_monitor.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/settings/shelf_layout_store.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';
import 'package:mreader/stats/stats_service.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/glass_material.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_nav_host.dart' show GlassNavHost;
import 'package:mreader/ui/home_shell.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart'
    show
        MiFilterCache,
        MiGlassNavItem,
        MiPillTabBar,
        MiSearchBar,
        MiThemeMode,
        MiTopBar,
        MiTopBarBlurBand,
        MiTopBarPalette,
        MiTransparencyTokens,
        SmileyBeretIconPainter;
import 'package:mreader/ui/nav_icons.dart';
import 'package:mreader/ui/scroll_sigma.dart';
import 'package:mreader/ui/shelf_grid.dart';

/// 120Hz 帧预算（ms）。
const double kBudget120Ms = 1000 / 120;

/// 60Hz 帧预算（ms）。
const double kBudget60Ms = 1000 / 60;

/// 低于该 totalSpan 的帧视作「空转 pump 帧」（无脏区、非真实绘制），不计入统计。
const double kIdleFrameMs = 0.5;

/// 手机逻辑宽（dp）——决定列数 `393 ~/ 120 = 3`。
const double kLogicalWidth = 393.3;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String variant = String.fromEnvironment(
    'BENCH_VARIANT',
    defaultValue: 'baseline',
  );
  const int bookCount = int.fromEnvironment('BENCH_BOOKS', defaultValue: 120);
  const int physW = int.fromEnvironment('BENCH_PHYS_W', defaultValue: 1179);
  const int physH = int.fromEnvironment('BENCH_PHYS_H', defaultValue: 2556);
  const String scene = String.fromEnvironment(
    'BENCH_SCENE',
    defaultValue: 'full',
  );

  final List<FrameTiming> timings = <FrameTiming>[];
  bool recording = false;

  testWidgets('shelf scroll bench ($variant/$scene)', (WidgetTester tester) async {
    // benchmarkLive：`pump` 只做真实等待，帧完全由引擎 vsync 驱动——帧间隔才是
    // 「掉不掉帧」的真身指标（GPU 受限时 rasterDuration 不一定变长，帧间隔会拉）。
    LiveTestWidgetsFlutterBinding.instance.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
    tester.binding.addTimingsCallback((List<FrameTiming> list) {
      if (recording) timings.addAll(list);
    });

    // 1) 桌面：把 Flutter 窗口客户区调到目标物理像素（对齐手机光栅负载）。
    Size surface = Size(physW.toDouble(), physH.toDouble());
    String windowNote = 'target $physW x $physH';
    if (Platform.isWindows) {
      final ({Size? size, String note}) r =
          await _resizeFlutterWindow(physW, physH);
      if (r.size != null) surface = r.size!;
      windowNote = r.note;
    }
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = surface.width / kLogicalWidth;
    addTearDown(tester.view.reset);

    // 2) 解析内核探测（同 main.dart `RUST-01`）：入库解析走内核，不探测会抛
    //    「flutter_rust_bridge has not been initialized」。
    final HighPerfRegistry highPerf = HighPerfRegistry.fromEnvironment(
      engine: HighPerfFfiEngine(),
    );
    await highPerf.warmUp();
    HighPerfRegistryProvider.current = highPerf;

    // 3) 造数据：120 本真实入库 TXT，2/3 带真封面缩略图。
    final _BenchLibrary lib = await _BenchLibrary.seed(bookCount: bookCount);

    // 4) 玻璃着色器预热（真实启动链路也有；不计入测量）。
    try {
      await LiquidGlassWidgets.initialize();
    } catch (_) {
      // 预热失败仅降级为无玻璃着色器，不阻塞压测（同 main.dart 口径）。
    }

    // 5) 与 main.dart 同款玻璃档位链（自动降级是产品行为，压测保持生效）。
    final PerfPrefsStore perfPrefs = PerfPrefsStore(lib.root);
    await perfPrefs.load();
    GlassRuntime.bind(perfPrefs);
    PerfFrameMonitor(onBudgetExceeded: GlassRuntime.noteBudgetDegraded).start();

    // 6) 泵应用。场景（归因用，见文件头注）：
    //    full = 真实完整壳层（书架页 + 浮动头部磨砂 + 玻璃底栏）；
    //    gridblur = 书卡网格 + 与货架同款的9段头部磨砂（磨砂成本）；
    //    grid = 只剩书卡网格（书卡成本）；
    //    gridlite = 书卡去投影/裁切/墨迹/Hero 的简化卡（书卡装饰成本）。
    final List<BookRecord> records = await lib.repo.loadBooks();
    final Widget app = switch (scene) {
      'full' => _fullApp(lib),
      'gridblur' => _gridScene(
          lib,
          records: records,
          headerBlurSigmaScale: 1.0,
          frostSigmaScale: 1.0,
          withFrosts: false,
          realParts: false,
          lite: false,
        ),
      'gridblurfast' => _gridScene(
          lib,
          records: records,
          headerBlurSigmaScale: 0.6,
          frostSigmaScale: 1.0,
          withFrosts: false,
          realParts: false,
          lite: false,
        ),
      'gridfrost' => _gridScene(
          lib,
          records: records,
          headerBlurSigmaScale: null,
          frostSigmaScale: 1.0,
          withFrosts: true,
          realParts: false,
          lite: false,
        ),
      'gridfastall' => _gridScene(
          lib,
          records: records,
          headerBlurSigmaScale: 0.6,
          frostSigmaScale: 0.6,
          withFrosts: true,
          realParts: false,
          lite: false,
        ),
      'gridparts' => _gridScene(
          lib,
          records: records,
          headerBlurSigmaScale: null,
          frostSigmaScale: 1.0,
          withFrosts: false,
          realParts: true,
          lite: false,
        ),
      'grid' => _gridScene(
          lib,
          records: records,
          headerBlurSigmaScale: null,
          frostSigmaScale: 1.0,
          withFrosts: false,
          realParts: false,
          lite: false,
        ),
      'gridlite' => _gridScene(
          lib,
          records: records,
          headerBlurSigmaScale: null,
          frostSigmaScale: 1.0,
          withFrosts: false,
          realParts: false,
          lite: true,
        ),
      _ => throw ArgumentError('未知 BENCH_SCENE: $scene'),
    };
    await tester.pumpWidget(app);
    await _settleReal(400);
    // 等书卡上屏（_loadBooks 真异步）再热身。
    for (int i = 0; i < 40 && find.byType(BookCard).evaluate().isEmpty; i++) {
      await _settleReal(100);
    }
    debugPrint(
      '[bench] cards=${find.byType(BookCard).evaluate().length} '
      'view=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio}',
    );
    await _settleReal(600);

    final Map<String, Object?> phases = <String, Object?>{};

    // 7) 预热（不计数）：让缩略图解码 / 图层缓存 / 磨砂 filter 全部就位。
    phases['warmup'] = await _runPhase(
      tester,
      timings: timings,
      setRecording: (bool v) => recording = v,
      action: () => _flingBurst(tester, flings: 2),
      record: false,
    );

    // 8) 快速滑动（丢帧主场景）：6 次来回 fling。
    phases['fling'] = await _runPhase(
      tester,
      timings: timings,
      setRecording: (bool v) => recording = v,
      action: () => _flingBurst(tester, flings: 6),
    );

    // 9) 慢速拖动（持续滚动场景）：2 次 800px/s 匀速拖。
    phases['slowDrag'] = await _runPhase(
      tester,
      timings: timings,
      setRecording: (bool v) => recording = v,
      action: () async {
        for (int i = 0; i < 2; i++) {
          await tester.timedDrag(
            find.byType(GridView).first,
            Offset(0, i.isEven ? -2400 : 2400),
            const Duration(milliseconds: 3000),
          );
          await _settleScroll(tester);
        }
      },
    );

    // 10) 落盘 + 打印摘要。
    final Map<String, Object?> report = <String, Object?>{
      'variant': variant,
      'scene': scene,
      'books': bookCount,
      'surfacePx': <double>[surface.width, surface.height],
      'logical': <double>[
        surface.width / (surface.width / kLogicalWidth),
        surface.height / (surface.width / kLogicalWidth),
      ],
      'devicePixelRatio': surface.width / kLogicalWidth,
      'windowResize': windowNote,
      'budget120HzMs': kBudget120Ms,
      'platform': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'phases': phases,
    };
    final Directory outDir = Directory('build/shelf_bench');
    await outDir.create(recursive: true);
    final File out = File(
      '${outDir.path}${Platform.pathSeparator}$scene-$variant.json',
    );
    await out.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    debugPrint('════ 书架滚动压测摘要 [$variant/$scene] → ${out.path} ════');
    for (final MapEntry<String, Object?> e in phases.entries) {
      debugPrint(_summaryLine(e.key, e.value! as Map<String, Object?>));
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

/// 「书架滚动 σ 降档」采样（`ScrollSigma.shared`）：验证降档链路在压测手势下
/// 真的生效（min 应落到 ≈0.6）；静止后回 1.0。
final List<double> _sigmaSamples = <double>[];

/// 压测阶段执行器：[action] 前后包上帧采集窗口，产出该阶段的统计。
///
/// ⚠️ 指标口径：`rasterDuration` 只统计光栅线程的 CPU 侧耗时，BackdropFilter 的
/// GPU 高斯几乎不计入——GPU 被拖慢时它的真身是**帧与帧之间的间隔拉长**（丢
/// vsync）。因此核心指标是相邻帧 `vsyncStart` 间隔（gapMs）与由它换算的
/// 有效帧率；>200ms 的间隔视作手势间歇，不计入（避免停手空档拉爆分位数）。
Future<Map<String, Object?>> _runPhase(
  WidgetTester tester, {
  required List<FrameTiming> timings,
  required void Function(bool) setRecording,
  required Future<void> Function() action,
  bool record = true,
}) async {
  timings.clear();
  _sigmaSamples.clear();
  setRecording(record);
  final Stopwatch sw = Stopwatch()..start();
  await action();
  sw.stop();
  setRecording(false);
  await _settleReal(80); // 排空尾帧回调
  final Map<String, Object?> stats = _stats(
    List<FrameTiming>.of(timings),
    sw.elapsedMilliseconds,
  );
  final List<double> sigmas = List<double>.of(_sigmaSamples)..sort();
  stats['sigmaMin'] = sigmas.isEmpty ? 1.0 : sigmas.first;
  stats['sigmaP50'] = sigmas.isEmpty
      ? 1.0
      : sigmas[(sigmas.length * 0.5).clamp(0, sigmas.length - 1).toInt()];
  return stats;
}

/// 来回快速 fling（每发后等阻尼滑停）。
Future<void> _flingBurst(WidgetTester tester, {required int flings}) async {
  final Finder grid = find.byType(GridView).first;
  for (int i = 0; i < flings; i++) {
    await tester.fling(grid, Offset(0, i.isEven ? -1500 : 1500), 2200);
    await _settleScroll(tester);
  }
}

/// 真实时间等待（benchmarkLive 下帧由引擎 vsync 驱动，无需手动 pump）。
Future<void> _settleReal(int ms) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// 等当前惯性滑动自然停稳（每 100ms 轮询位移；上限 [maxMs]）。
Future<void> _settleScroll(WidgetTester tester, {int maxMs = 8000}) async {
  final ScrollableState scrollable = tester
      .state<ScrollableState>(find.byType(Scrollable).first);
  double last = scrollable.position.pixels;
  int stable = 0;
  for (int waited = 0; waited < maxMs; waited += 100) {
    await _settleReal(100);
    _sigmaSamples.add(ScrollSigma.shared.value);
    final double now = scrollable.position.pixels;
    stable = (now - last).abs() < 0.5 ? stable + 1 : 0;
    if (stable >= 2) return;
    last = now;
  }
}

/// 帧统计：剔除空转 pump 帧后给 build / raster / total 的分位数、超预算计数，
/// 以及相邻帧间隔（有效帧率，GPU 受限的真身指标）。
Map<String, Object?> _stats(List<FrameTiming> all, int wallMs) {
  final List<FrameTiming> real = all
      .where((FrameTiming t) =>
          t.totalSpan.inMicroseconds / 1000.0 >= kIdleFrameMs)
      .toList();
  final List<double> build = real
      .map((FrameTiming t) => t.buildDuration.inMicroseconds / 1000.0)
      .toList()
    ..sort();
  final List<double> raster = real
      .map((FrameTiming t) => t.rasterDuration.inMicroseconds / 1000.0)
      .toList()
    ..sort();
  final List<double> total = real
      .map((FrameTiming t) => t.totalSpan.inMicroseconds / 1000.0)
      .toList()
    ..sort();
  // 相邻帧 vsyncStart 间隔（ms）：GPU / 合成受限时拉长，是「丢帧」的直接证据。
  final List<double> gaps = <double>[];
  for (int i = 1; i < real.length; i++) {
    final double gap =
        (real[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
            real[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart)) /
        1000.0;
    if (gap > 0 && gap <= 200) gaps.add(gap);
  }
  gaps.sort();
  final double activeSpanMs = gaps.fold<double>(0, (double s, double g) => s + g);
  final double effectiveFps =
      gaps.isEmpty ? 0 : (gaps.length + 1) * 1000.0 / activeSpanMs;
  return <String, Object?>{
    'frames': real.length,
    'idleFramesDropped': all.length - real.length,
    'wallMs': wallMs,
    'effectiveFps': effectiveFps.toStringAsFixed(1),
    'gapMs': _dist(gaps),
    'buildMs': _dist(build),
    'rasterMs': _dist(raster),
    'totalMs': _dist(total),
    'gapsOver120Budget': gaps.where((double v) => v > kBudget120Ms * 1.05).length,
    'gapsOver60Budget': gaps.where((double v) => v > kBudget60Ms * 1.05).length,
    'overBudget120Hz':
        total.where((double v) => v > kBudget120Ms).length,
    'overBudget60Hz': total.where((double v) => v > kBudget60Ms).length,
  };
}

Map<String, double> _dist(List<double> sorted) {
  if (sorted.isEmpty) return <String, double>{};
  double pct(double p) =>
      sorted[(sorted.length * p).clamp(0, sorted.length - 1).toInt()];
  return <String, double>{
    'p50': pct(0.5),
    'p90': pct(0.9),
    'p99': pct(0.99),
    'max': sorted.last,
  };
}

String _summaryLine(String name, Map<String, Object?> s) {
  String fmt(Object? d) {
    if (d is! Map<String, double> || d.isEmpty) return '-';
    String x(double v) => v.toStringAsFixed(2);
    return 'p50 ${x(d['p50']!)} / p90 ${x(d['p90']!)} / '
        'p99 ${x(d['p99']!)} / max ${x(d['max']!)} ms';
  }

  return '[$name] frames=${s['frames']} effFps=${s['effectiveFps']} '
      'σmin=${s['sigmaMin']} σp50=${s['sigmaP50']} | '
      'gap ${fmt(s['gapMs'])} | build ${fmt(s['buildMs'])} | '
      'raster ${fmt(s['rasterMs'])} | total ${fmt(s['totalMs'])} | '
      'gap>8.33=${s['gapsOver120Budget']} gap>16.67=${s['gapsOver60Budget']} '
      'total>8.33=${s['overBudget120Hz']}';
}

// ---------------------------------------------------------------------------
// 合成封面（320×480 PNG，渐变 + 图形，接近真实封面的绘制复杂度）
// ---------------------------------------------------------------------------

Future<Uint8List> _synthCoverPng(int seed) async {
  const int w = 320;
  const int h = 480;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Rect rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final List<Color> colors = <Color>[
    const Color(0xFF6A8DFF),
    const Color(0xFFFF8A5C),
    const Color(0xFF5CC98B),
    const Color(0xFFB06AF0),
    const Color(0xFFE8C547),
  ];
  final Color c1 = colors[seed % colors.length];
  final Color c2 = colors[(seed * 3 + 1) % colors.length];
  canvas.drawRect(
    rect,
    Paint()..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, <Color>[c1, c2]),
  );
  final RandomStub rng = RandomStub(seed);
  for (int i = 0; i < 18; i++) {
    canvas.drawCircle(
      Offset(rng.next() * w, rng.next() * h),
      8 + rng.next() * 46,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.05 + rng.next() * 0.12),
    );
  }
  canvas.drawRect(
    Rect.fromLTWH(24, h * 0.62, w - 48, 18),
    Paint()..color = Colors.white.withValues(alpha: 0.8),
  );
  canvas.drawRect(
    Rect.fromLTWH(24, h * 0.62 + 30, w - 120, 12),
    Paint()..color = Colors.white.withValues(alpha: 0.55),
  );
  final ui.Image image = await recorder.endRecording().toImage(w, h);
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 极简确定性伪随机（避免引 dart:math 的 Random 状态管理）。
class RandomStub {
  RandomStub(this._s);
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }
}

// ---------------------------------------------------------------------------
// 归因场景（只存在于压测装具；生产代码零改动）
// ---------------------------------------------------------------------------

/// 真实完整壳层（与 main.dart 同款接线）。
Widget _fullApp(_BenchLibrary lib) {
  return LiquidGlassWidgets.wrap(
    child: MReaderApp(
      settings: lib.settings,
      home: HomeShell(
        repository: lib.repo,
        coverStore: lib.coverStore,
        progressStore: lib.progress,
        shelfPrefs: lib.prefs,
        shelfLayout: lib.layout,
        settings: lib.settings,
        statsService: StatsService(lib.paths),
        aiStore: ProviderStore(
          lib.root,
          AiKeyVault(FileSecureStore(directory: lib.root)),
        ),
        aiClient: AiClient(),
      ),
    ),
    brightnessResolver: Theme.maybeBrightnessOf,
    theme: GlassMaterial.themeData,
  );
}

/// 书卡网格场景（± 同款头部磨砂（σ 可缩）；± 零件磨砂膜；± 真实零件；± 书卡装饰）。
Widget _gridScene(
  _BenchLibrary lib, {
  required List<BookRecord> records,
  required double? headerBlurSigmaScale,
  required double frostSigmaScale,
  required bool withFrosts,
  required bool realParts,
  required bool lite,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) {
          final double topInset = MediaQuery.paddingOf(context).top;
          final Widget grid = lite
              ? _liteGrid(records, lib.coverStore, topInset)
              : ShelfGrid(
                  books: records,
                  coverStore: lib.coverStore,
                  padding: shelfGridPadding(topInset),
                  onOpenBook: (BookRecord _) {},
                  onBookActions: (BookRecord _) async {},
                );
          return Stack(
            children: <Widget>[
              grid,
              if (headerBlurSigmaScale != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topInset + kShelfHeaderHeight,
                  child: _replicaHeaderBlur(
                    topInset + kShelfHeaderHeight,
                    sigmaScale: headerBlurSigmaScale,
                  ),
                ),
              if (withFrosts) _replicaFrosts(topInset, sigmaScale: frostSigmaScale),
              if (realParts) _realParts(topInset),
            ],
          );
        },
      ),
    ),
  );
}

/// 真实零件（搜索胶囊 / 分组胶囊行 / 玻璃底栏）按壳层同位摆放（归因装具；
/// 与真件差异：无 rim 亮边参数、底栏 FAB 以占位代替）。
Widget _realParts(double topInset) {
  final List<MiGlassNavItem> items = <MiGlassNavItem>[
    MiGlassNavItem(label: '书架', painter: ShelfBooksIconPainter(Colors.black)),
    MiGlassNavItem(label: '笔记', painter: NotesIconPainter(Colors.black)),
    MiGlassNavItem(
      label: '我的',
      painter: SmileyBeretIconPainter(Colors.black),
    ),
  ];
  return Stack(
    children: <Widget>[
      Positioned(
        left: kShelfPageInset,
        right: kShelfPageInset,
        top: topInset + 12,
        height: kShelfSearchRowHeight,
        child: MiSearchBar(
          hint: '搜索书名、作者',
          onTap: () {},
          themeMode: MiThemeMode.light,
          frosted: true,
          overContent: true,
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        top: topInset + 12 + kShelfSearchRowHeight + kShelfHeaderRowGap,
        height: kShelfChipsRowHeight,
        child: MiPillTabBar(
          labels: const <String>['全部', '分组一', '分组二'],
          selectedIndex: 0,
          themeMode: MiThemeMode.light,
          overContent: true,
          onTap: (int _) {},
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 24.2,
        child: GlassNavHost(
          items: items,
          selectedIndex: 0,
          onTabSelected: (int _) {},
          themeMode: MiThemeMode.light,
        ),
      ),
    ],
  );
}

/// 与 `ShelfPage._buildHeaderBlur` 同款的9段磨砂（公开 API 复刻；
/// [sigmaScale] 传 <1 复现 `ScrollSigma` 运动降档（`headerBlurBands` 同时
/// 把9段并成3段），1.0 = 静止满档）。
Widget _replicaHeaderBlur(double extent, {double sigmaScale = 1.0}) {
  final List<MiTopBarBlurBand> bands = MiTopBar.headerBlurBands(
    MiTopBarPalette.of(MiThemeMode.light),
    extent: extent,
    underSurface: false,
    sigmaScale: sigmaScale,
  );
  return ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (final MiTopBarBlurBand band in bands)
          Positioned(
            left: 0,
            right: 0,
            top: band.top,
            height: band.height,
            child: ClipRect(
              child: BackdropFilter(
                filter: MiFilterCache.blur(band.sigma),
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    ),
  );
}

/// 与真实零件同包围盒的三块磨砂膜（归因装具）：搜索胶囊（44.1 高、stadium）/
/// 分组胶囊行（40 高）/ 底栏胶囊（55.4 高、距屏底 24.2）——σ 取零件同款
/// [MiTransparencyTokens.blurSigma]，几何取 `shelf_geometry` / `MiGlassNavMetrics`
/// 同源值。与真实件的差异只有形状细节（无渐变羽化、无内缘亮边），量级同款。
Widget _replicaFrosts(double topInset, {double sigmaScale = 1.0}) {
  Widget frost(double radius) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: MiFilterCache.blur(
            MiTransparencyTokens.frostSigma(sigmaScale),
          ),
          child: const SizedBox.expand(),
        ),
      );
  return Stack(
    children: <Widget>[
      Positioned(
        left: kShelfPageInset,
        right: kShelfPageInset,
        top: topInset + 12,
        height: kShelfSearchRowHeight,
        child: frost(kShelfSearchRowHeight / 2),
      ),
      Positioned(
        left: kShelfPageInset,
        right: kShelfPageInset,
        top: topInset + 12 + kShelfSearchRowHeight + kShelfHeaderRowGap,
        height: kShelfChipsRowHeight,
        child: frost(20),
      ),
      Positioned(
        left: 24,
        right: 24,
        bottom: 24.2,
        height: 55.4,
        child: frost(55.4 / 2),
      ),
    ],
  );
}

/// 与 [ShelfGrid] 同几何、书卡换简化版的网格（归因用）。
Widget _liteGrid(
  List<BookRecord> books,
  CoverStore coverStore,
  double topInset,
) {
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double width = constraints.maxWidth;
      int columns = width.isFinite
          ? width ~/ kShelfCoverTargetWidth
          : kShelfFallbackColumns;
      if (columns < kShelfMinColumns) columns = kShelfMinColumns;
      if (columns > kShelfMaxColumns) columns = kShelfMaxColumns;
      final EdgeInsets padding = shelfGridPadding(topInset);
      final EdgeInsets resolved = padding.resolve(Directionality.of(context));
      final double contentWidth = width - resolved.left - resolved.right;
      final double cellWidth =
          (contentWidth - kShelfCrossAxisSpacing * (columns - 1)) / columns;
      return GridView.builder(
        padding: padding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          childAspectRatio: shelfChildAspectRatio(cellWidth),
          mainAxisSpacing: kShelfMainAxisSpacing,
          crossAxisSpacing: kShelfCrossAxisSpacing,
        ),
        itemCount: books.length,
        itemBuilder: (BuildContext context, int index) =>
            _LiteCard(record: books[index], coverStore: coverStore),
      );
    },
  );
}

/// 简化书卡：同几何 / 同缩略图 / 同文案，但**无投影、无 Squircle 裁切、
/// 无 InkWell/Hero/AnimatedScale**——与 [BookCard] 的差值即书卡装饰成本。
class _LiteCard extends StatefulWidget {
  const _LiteCard({required this.record, required this.coverStore});

  final BookRecord record;
  final CoverStore coverStore;

  @override
  State<_LiteCard> createState() => _LiteCardState();
}

class _LiteCardState extends State<_LiteCard> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.record.cover is StoredCover) {
      final Uint8List? b = await widget.coverStore.readThumb(widget.record.cover);
      if (mounted && b != null) setState(() => _bytes = b);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Uint8List? bytes = _bytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: bytes != null
              ? Image.memory(bytes, fit: BoxFit.cover)
              : ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
        ),
        const SizedBox(height: kBookCoverToInfoGap),
        SizedBox(
          height: kBookInfoHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: kBookInfoIndent),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.record.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.85, height: 1.0),
                ),
                const SizedBox(height: kBookTitleToAuthorGap),
                Text(
                  widget.record.author.isEmpty ? '未知作者' : widget.record.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, height: 1.18),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 数据装具：临时目录 + 真实入库
// ---------------------------------------------------------------------------

/// 临时目录实现 [AppPaths]（同 `test/reader/reader_harness.dart` 的测试件）。
class _LocalAppPaths implements AppPaths {
  _LocalAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir = Directory(
      '${_root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}

class _BenchLibrary {
  _BenchLibrary({
    required this.root,
    required this.paths,
    required this.repo,
    required this.coverStore,
    required this.progress,
    required this.prefs,
    required this.layout,
    required this.settings,
  });

  final Directory root;
  final AppPaths paths;
  final LibraryRepository repo;
  final FileCoverStore coverStore;
  final ProgressStore progress;
  final ShelfPrefsStore prefs;
  final ShelfLayoutStore layout;
  final SettingsStore settings;

  static Future<_BenchLibrary> seed({required int bookCount}) async {
    final Directory root = await Directory.systemTemp.createTemp(
      'mreader_shelf_bench_',
    );
    final AppPaths paths = _LocalAppPaths(root);
    final FileCoverStore coverStore = FileCoverStore(paths);
    final LibraryRepository repo = LibraryRepository(
      paths: paths,
      coverStore: coverStore,
    );
    final ProgressStore progress = ProgressStore(paths);
    final ShelfPrefsStore prefs = ShelfPrefsStore(root);
    final ShelfLayoutStore layout = ShelfLayoutStore(root);
    final SettingsStore settings = SettingsStore(root);
    await Future.wait(<Future<void>>[prefs.load(), layout.load()]);

    // 25 张合成封面循环使用；2/3 的书贴真封面（书架典型形态）。
    final List<Uint8List> covers = <Uint8List>[];
    for (int i = 0; i < 25; i++) {
      covers.add(await _synthCoverPng(i));
    }
    for (int i = 0; i < bookCount; i++) {
      final String body = '书架压测样本 $i\n' * 60;
      final ImportResult res = await repo.importFile(
        bytes: Uint8List.fromList(utf8.encode(body)),
        fileName: 'bench_${i.toString().padLeft(3, '0')}.txt',
      );
      if (i % 3 != 2) {
        await coverStore.replaceWithUserPick(
          bookId: res.record.bookId,
          bytes: covers[i % covers.length],
          previous: res.record.cover,
        );
      }
    }
    return _BenchLibrary(
      root: root,
      paths: paths,
      repo: repo,
      coverStore: coverStore,
      progress: progress,
      prefs: prefs,
      layout: layout,
      settings: settings,
    );
  }
}

// ---------------------------------------------------------------------------
// Windows 窗口客户区 → 目标物理像素（桌面剖析保真度；失败则按实际尺寸继续）
// ---------------------------------------------------------------------------

Future<({Size? size, String note})> _resizeFlutterWindow(int w, int h) async {
  final String script = '''
\$sig = @"
using System;
using System.Runtime.InteropServices;
public static class BenchW {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(String c, String t);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
}
"@
Add-Type -TypeDefinition \$sig
[BenchW]::SetProcessDPIAware() | Out-Null
\$h = [IntPtr]::Zero
foreach (\$p in [System.Diagnostics.Process]::GetProcessesByName('mreader')) {
  if (\$p.MainWindowHandle -ne [IntPtr]::Zero) { \$h = \$p.MainWindowHandle; break }
}
if (\$h -eq [IntPtr]::Zero) { \$h = [BenchW]::FindWindowW(\$null, 'MReader') }
if (\$h -eq [IntPtr]::Zero) { Write-Output 'NOTFOUND'; exit 1 }
for (\$i = 0; \$i -lt 4; \$i++) {
  \$wr = New-Object BenchW+RECT
  \$cr = New-Object BenchW+RECT
  [BenchW]::GetWindowRect(\$h, [ref]\$wr) | Out-Null
  [BenchW]::GetClientRect(\$h, [ref]\$cr) | Out-Null
  \$bw = (\$wr.R - \$wr.L) - (\$cr.R - \$cr.L)
  \$bh = (\$wr.B - \$wr.T) - (\$cr.B - \$cr.T)
  [BenchW]::SetWindowPos(\$h, [IntPtr]::Zero, 0, 0, $w + \$bw, $h + \$bh, 0x0006) | Out-Null
  Start-Sleep -Milliseconds 250
  [BenchW]::GetClientRect(\$h, [ref]\$cr) | Out-Null
  if ((\$cr.R - \$cr.L) -eq $w -and (\$cr.B - \$cr.T) -eq $h) { break }
}
[BenchW]::GetClientRect(\$h, [ref]\$cr) | Out-Null
Write-Output ("SIZE " + (\$cr.R - \$cr.L) + " " + (\$cr.B - \$cr.T))
''';
  try {
    final ProcessResult res = await Process.run(
      'powershell',
      <String>['-NoProfile', '-Command', script],
    );
    final String out = (res.stdout as String).trim();
    final String line = out.split('\n').last.trim();
    if (line.startsWith('SIZE ')) {
      final List<String> parts = line.split(' ');
      return (
        size: Size(double.parse(parts[1]), double.parse(parts[2])),
        note: 'resized: $line',
      );
    }
    return (size: null, note: 'resize failed: ${line.isEmpty ? out : line}');
  } catch (e) {
    // 任何失败（无 PowerShell / 权限 / 窗口未就绪）都按实际尺寸继续压测。
    return (size: null, note: 'resize error: $e');
  }
}
