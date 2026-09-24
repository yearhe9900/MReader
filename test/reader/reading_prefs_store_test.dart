// `TYP-07~09`：阅读偏好（排版 + 亮度 + 背景色）模型与持久化单测
// （纯 Dart，用 `test()` 而非 `testWidgets()`，理由同 `bookmark_store_test.dart`）。
//
// 预期值人工推演：
//   · 默认值即 [ReaderSettings] 默认 + 不加亮度遮罩 + 白色背景：
//     `fontSize = 18`、`lineHeight = 1.6`、`fontFamily = null`、
//     `themeMode = system`、`pageMargin = normal`、`brightness = 1.0`、
//     `background = white`；
//   · 亮度构造 clamp 到 `[0.2, 1.0]`：传 0.05 → 0.2，传 3.0 → 1.0；
//   · 反序列化**逐项**回退默认（单项坏不连坐全部）：数值越界 clamp、
//     枚举名未知回退默认枚举、类型错回退该项默认。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/reading_prefs.dart';
import 'package:mreader/reader/reading_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/typography/reader_settings.dart';

/// 临时目录实现 [AppPaths]，仅用于测试。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);
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

void main() {
  group('ReadingPrefs（值对象）', () {
    test('默认值：18 / 1.6 / 系统默认字体 / 亮度 1.0 / 白色背景', () {
      final ReadingPrefs prefs = ReadingPrefs();
      expect(prefs.settings.fontSize, 18);
      expect(prefs.settings.lineHeight, 1.6);
      expect(prefs.settings.fontFamily, isNull);
      expect(prefs.settings.themeMode, AppThemeMode.system);
      expect(prefs.settings.pageMargin, PageMargin.normal);
      expect(prefs.brightness, 1.0);
      expect(prefs.background, ReaderBackground.white);
    });

    test('亮度构造 clamp 到 [0.2, 1.0]', () {
      expect(ReadingPrefs(brightness: 0.05).brightness, 0.2);
      expect(ReadingPrefs(brightness: 3.0).brightness, 1.0);
      expect(ReadingPrefs(brightness: 0.5).brightness, 0.5);
    });

    test('toJson 往返保持全部字段', () {
      final ReadingPrefs prefs = ReadingPrefs(
        settings: const ReaderSettings(
          fontSize: 22,
          lineHeight: 2.0,
          fontFamily: 'serif',
          themeMode: AppThemeMode.dark,
          pageMargin: PageMargin.wide,
        ),
        brightness: 0.5,
        background: ReaderBackground.sepia,
      );
      final ReadingPrefs restored = ReadingPrefs.fromJson(prefs.toJson());
      expect(restored, prefs);
    });

    test('fromJson 防御：非 Map 整体默认；字段逐项回退默认', () {
      // 非 Map → 整体默认。
      final ReadingPrefs bad = ReadingPrefs.fromJson('not-a-map');
      expect(bad, ReadingPrefs());

      // 空 Map → 全默认。
      final ReadingPrefs empty = ReadingPrefs.fromJson(<String, Object?>{});
      expect(empty, ReadingPrefs());

      // 单项坏不连坐：坏的回退默认，好的保留。
      final ReadingPrefs partial = ReadingPrefs.fromJson(<String, Object?>{
        'fontSize': 'x', // 类型错 → 18
        'lineHeight': 2.0, // 合法 → 2.0
        'fontFamily': 'serif',
        'themeMode': 'bogus', // 未知 → system
        'pageMargin': 'bogus', // 未知 → normal
        'brightness': 'x', // 类型错 → 1.0
        'background': 'bogus', // 未知 → white
      });
      expect(partial.settings.fontSize, 18);
      expect(partial.settings.lineHeight, 2.0);
      expect(partial.settings.fontFamily, 'serif');
      expect(partial.settings.themeMode, AppThemeMode.system);
      expect(partial.settings.pageMargin, PageMargin.normal);
      expect(partial.brightness, 1.0);
      expect(partial.background, ReaderBackground.white);

      // 数值越界 clamp（亮度 [0.2, 1.0]、字号 [12, 36]、行距 [1.0, 2.6]）。
      final ReadingPrefs clamped = ReadingPrefs.fromJson(<String, Object?>{
        'fontSize': 100,
        'lineHeight': 9.0,
        'brightness': 0.01,
      });
      expect(clamped.settings.fontSize, 36);
      expect(clamped.settings.lineHeight, 2.6);
      expect(clamped.brightness, 0.2);
    });

    test('copyWith：null = 不改；显式值覆盖', () {
      final ReadingPrefs base = ReadingPrefs();
      final ReadingPrefs next = base.copyWith(
        brightness: 0.4,
        background: ReaderBackground.black,
      );
      expect(next.brightness, 0.4);
      expect(next.background, ReaderBackground.black);
      expect(next.settings, base.settings, reason: 'settings 不传则保持');
    });
  });

  group('ReadingPrefsStore', () {
    late Directory tempDir;
    late ReadingPrefsStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_prefs_');
      store = ReadingPrefsStore(_TestAppPaths(tempDir));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('无存档 → null（调用方回落默认值）', () async {
      expect(await store.load(), isNull);
    });

    test('往返：保存后读回全字段一致', () async {
      final ReadingPrefs prefs = ReadingPrefs(
        settings: const ReaderSettings(
          fontSize: 24,
          lineHeight: 1.8,
          fontFamily: 'sans-serif',
          themeMode: AppThemeMode.dark,
          pageMargin: PageMargin.narrow,
        ),
        brightness: 0.5,
        background: ReaderBackground.gray,
      );
      await store.save(prefs);

      // 换一个实例读回（模拟重启）。
      final ReadingPrefsStore fresh =
          ReadingPrefsStore(_TestAppPaths(tempDir));
      final ReadingPrefs? loaded = await fresh.load();
      expect(loaded, prefs);
    });

    test('文件损坏 → null（损坏件隔离为 .corrupt，重启走默认值）', () async {
      await store.save(ReadingPrefs());
      final String path = <String>[
        tempDir.path,
        ReadingPrefsStore.dirName,
        ReadingPrefsStore.fileName,
      ].join(Platform.pathSeparator);
      await File(path).writeAsString('not-json');

      expect(await store.load(), isNull);
      expect(File('$path.corrupt').existsSync(), isTrue);
    });
  });
}
