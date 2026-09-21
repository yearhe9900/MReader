// 入口：初始化平台能力 → 加载设置 → runApp。
//
// 纯 Flutter 自绘：不使用 WebView / foliate-js。
// 目标平台：Android / iOS / Windows / macOS / Linux（平台能力差异按 PRD §15.3 降级表处理）。
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'epub/epub_parser.dart';
import 'model/epub_book.dart';
import 'platform/app_paths.dart';
import 'settings/settings_store.dart';
import 'ui/reader_page.dart';

Future<void> main() async {
  // path_provider 等插件在访问前需要先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();

  // 平台能力经抽象注入（PRD §15.1）：解析应用数据目录 → 构建设置服务 → 加载。
  final AppPaths appPaths = PathProviderAppPaths();
  final Directory dataDir = await appPaths.dataDir();
  final SettingsStore settings = SettingsStore(dataDir);
  await settings.load();

  runApp(MReaderApp(settings: settings, home: const HomePage()));
}

/// 首页（验证台）：EPUB 阅读链路入口。
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
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['epub'],
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
      final EpubBook book = await parseEpub(bytes, fileName: picked.name);
      if (!mounted) return;
      setState(() => _loading = false);

      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReaderPage(book: book)),
      );
    } on EpubParseException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (error) {
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
                '打开本地 EPUB，纵向滚动阅读',
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
                  label: const Text('选择 EPUB 文件'),
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
