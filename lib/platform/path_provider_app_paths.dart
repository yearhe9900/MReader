// [AppPaths] 的默认实现（基于 Flutter 官方插件 path_provider），
// 覆盖 Android / iOS / Windows / macOS / Linux 五平台。
//
// 单独成文件的原因见 `app_paths.dart` 头注释：接口保持纯 Dart，
// 依赖 path_provider 的实现隔离在这里，只由启动层（`lib/main.dart`）注入。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_paths.dart';

/// 基于 [path_provider] 的默认实现。
///
/// 基准目录取 `getApplicationSupportDirectory()`：各平台都指向「应用私有、可持久化、
/// 不暴露给用户」的目录（Android: `files/`；iOS: `Library/Application Support`；
/// 桌面: 用户数据目录下的应用子目录），适合放索引 / 进度 / 设置这类内部数据。
class PathProviderAppPaths implements AppPaths {
  PathProviderAppPaths({String? appFolderName})
      : _appFolderName = appFolderName ?? defaultAppFolderName;

  /// 数据根目录下用于隔离本应用数据的子目录名。
  static const String defaultAppFolderName = 'mreader';

  final String _appFolderName;

  /// 已解析的根目录缓存，保证 [dataDir] 幂等。
  Directory? _cachedRoot;

  @override
  Future<Directory> dataDir() async {
    final Directory? cached = _cachedRoot;
    if (cached != null) {
      return cached;
    }
    final Directory base = await getApplicationSupportDirectory();
    final Directory root = Directory(
      '${base.path}${Platform.pathSeparator}$_appFolderName',
    );
    await root.create(recursive: true);
    _cachedRoot = root;
    return root;
  }

  @override
  Future<Directory> subDir(String name) async {
    final Directory root = await dataDir();
    final Directory dir = Directory(
      '${root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}
