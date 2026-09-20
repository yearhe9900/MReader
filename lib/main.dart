// 入口：选择本地 EPUB -> 解析 -> 纵向滚动阅读。
//
// 纯 Flutter 自绘：不使用 WebView / foliate-js，也不使用任何平台特定 API，
// 因此同一份代码可以跑在 Android / iOS / Windows / macOS / Linux / Web 上。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'epub/epub_parser.dart';
import 'model/epub_book.dart';
import 'ui/reader_page.dart';

void main() {
  runApp(const MReaderApp());
}

/// 应用根。刻意保持最简：不需要任何状态管理库。
class MReaderApp extends StatelessWidget {
  const MReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MReader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// 首页：一个「选择 EPUB」按钮 + 加载指示 + 可读的错误提示。
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
        // Web 没有真实文件路径，必须让插件把内容读进 bytes；
        // 桌面/移动端也统一走 bytes，省得再引 dart:io（会导致 Web 编译失败）。
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
      appBar: AppBar(title: const Text('阅读M · EPUB 可行性验证')),
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
            ],
          ),
        ),
      ),
    );
  }
}
