// 入口：初始化平台能力 → 加载设置 → 构造书库 → runApp。
//
// 纯 Flutter 自绘：不使用 WebView / foliate-js。
// 目标平台：Android / iOS / Windows / macOS / Linux（平台能力差异按 PRD §15.3 降级表处理）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'library/library_repository.dart';
import 'meta/cover_store.dart';
import 'platform/app_paths.dart';
import 'platform/path_provider_app_paths.dart';
import 'platform/pdf_engine.dart';
import 'platform/pdfrx_pdf_engine.dart';
import 'reader/progress_store.dart';
import 'settings/settings_store.dart';
import 'ui/shelf_page.dart';

Future<void> main() async {
  // path_provider 等插件在访问前需要先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();

  // `FMT-01` / `META-10` ③：PDF 渲染内核经**注入缝**接入（`Q4 ①` 拍板 pdfrx 2.6.5）。
  // 全仓唯一 import pdfrx 的文件是右边这个适配器；格式层（`PdfSource`）只认
  // `PdfEngine` 抽象，因此换内核不动格式层与 UI。pdfrx 自身的初始化（原生库准备）
  // 是惰性的，首次开 PDF 才发生，不拖慢冷启动。
  PdfEngineProvider.current = PdfrxPdfEngine();

  // `UI-01` ① + 平台能力经抽象注入（PRD §15.1）：
  // 玻璃着色器预热与数据目录解析/设置加载**并行**——两者完全独立，
  // 串行会把冷启动叠加一段着色器预编译时间（`v2.3` 冷启动是硬指标）。
  // 预热失败不阻塞启动——降级为「无玻璃效果但仍可运行」（诚实降级）。
  final AppPaths appPaths = PathProviderAppPaths();
  final Directory dataDir = await appPaths.dataDir();
  final SettingsStore settings = SettingsStore(dataDir);
  await Future.wait(<Future<void>>[
    _warmUpGlassShaders(),
    settings.load(),
  ]);

  // M1-T03：构造封面存储 + 书库仓库（LIB-01~06 的后端）。
  final CoverStore coverStore = FileCoverStore(appPaths);
  final LibraryRepository repository = LibraryRepository(
    paths: appPaths,
    coverStore: coverStore,
  );

  // M1-T04：阅读进度持久化（`RD-04`），注入书架 → 阅读页。
  final ProgressStore progressStore = ProgressStore(appPaths);

  // `UI-01` ②：`brightnessResolver: Theme.maybeBrightnessOf` 让玻璃控件跟随
  // **应用 ThemeMode**（light / dark / system），而非仅系统亮度。
  // 包裹位置在 `MReaderApp` **之外**，`app.dart` 里 builder 的透明 Material 地基一字不动。
  runApp(
    LiquidGlassWidgets.wrap(
      child: MReaderApp(
        settings: settings,
        home: ShelfPage(
          repository: repository,
          coverStore: coverStore,
          progressStore: progressStore,
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
