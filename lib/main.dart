// 入口：初始化平台能力 → 加载设置 → runApp。
//
// 纯 Flutter 自绘：不使用 WebView / foliate-js。
// 目标平台：Android / iOS / Windows / macOS / Linux（平台能力差异按 PRD §15.3 降级表处理）。
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'format/book_registry.dart';
import 'format/book_source.dart';
import 'platform/app_paths.dart';
import 'settings/settings_store.dart';
import 'ui/reader_page.dart';

Future<void> main() async {
  // path_provider 等插件在访问前需要先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();

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

  // `UI-01` ②：`brightnessResolver: Theme.maybeBrightnessOf` 让玻璃控件跟随
  // **应用 ThemeMode**（light / dark / system），而非仅系统亮度。
  // 包裹位置在 `MReaderApp` **之外**，`app.dart` 里 builder 的透明 Material 地基一字不动。
  runApp(
    LiquidGlassWidgets.wrap(
      child: MReaderApp(settings: settings, home: const HomePage()),
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

/// 首页（验证台）：EPUB / TXT 阅读链路入口。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = false;
  String? _error;

  Future<void> _pickAndOpen() async {
    setState(() => _error = null);
    BookSource? source;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['epub', 'txt'],
        // 统一走 bytes：避免引 dart:io，让核心解析链路保持可纯 Dart 单测。
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return; // 用户取消
      }

      final PlatformFile picked = result.files.single;
      // 刻意不写 `Uint8List?`：flutter/material.dart 并不导出 Uint8List，
      // 让类型由 PlatformFile.bytes 自动推断，省去一个 dart:typed_data 导入。
      final bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _error = '未能读取文件内容（bytes 为空）。');
        return;
      }

      setState(() => _loading = true);
      // 按扩展名 + 魔数分发（`BookRegistry`）；返回的永远是 [BookSource] 抽象，
      // 本页不区分 EPUB / TXT。
      source = await openBook(fileName: picked.name, bytes: bytes);
      // 主动触发一次解析，把格式错误（`RD-05`）暴露在首页——与 M1-T02A 用
      // `parseEpub` 时的口径一致。结果被 source 缓存，阅读页不会重复解析。
      await source.load();
      if (!mounted) return;
      setState(() => _loading = false);

      final BookSource opened = source;
      // 所有权移交给阅读页：它在 `dispose()` 里释放，此处不再持有。
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReaderPage(source: opened)),
      );
    } on MReaderFormatException catch (error) {
      await source?.dispose();
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 面向用户的中文文案（`message` 已中文化，`detail` 不进 UI）。
        _error = error.message;
      });
    } catch (error) {
      await source?.dispose();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '打开失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('阅读M · 可行性验证')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.menu_book_outlined, size: 72),
              const SizedBox(height: 16),
              const Text(
                '打开本地 EPUB / TXT，纵向滚动阅读',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: CircularProgressIndicator(),
                )
              else
                FilledButton.icon(
                  onPressed: _pickAndOpen,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择 EPUB / TXT 文件'),
                ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 20),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
