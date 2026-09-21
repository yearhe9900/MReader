// 应用数据目录解析（平台能力抽象，PRD §15.1）。
//
// 约束：lib/ 内的业务代码**只依赖 [AppPaths] 接口**，具体实现在启动时显式注入
// （见 lib/main.dart）。禁止在业务代码里硬编码路径或直接依赖 path_provider /
// dart:io 的目录 API。
//
// 当前唯一实现 [PathProviderAppPaths] 基于 Flutter 官方插件 path_provider，
// 覆盖 Android / iOS / Windows / macOS / Linux 五平台。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用数据目录解析的抽象接口。
///
/// 所有落盘（设置 / 进度 / 书签 / 笔记 / 书库索引，见 PRD `DATA-01`）
/// 都应以本接口返回的目录为根。
abstract interface class AppPaths {
  /// 应用私有数据根目录；首次调用时若不存在会自动创建。
  ///
  /// 该目录位于各平台的应用沙箱内、随应用卸载一起清除，不暴露给用户文件管理器。
  Future<Directory> dataDir();

  /// 在数据根目录下解析一个子目录，不存在时自动创建。
  ///
  /// 用于把不同用途的落盘文件分门别类，例如 `settings` / `library` / `progress`。
  Future<Directory> subDir(String name);
}

/// 基于 [path_provider] 的默认实现。
///
/// 使用 `getApplicationSupportDirectory()` 作为基准目录：它在各平台都指向
/// 「应用私有、可持久化、不暴露给用户」的目录
/// （Android: `files/`；iOS: `Library/Application Support`；桌面: 用户数据目录下的应用子目录），
/// 适合存放索引 / 进度 / 设置这类内部数据。
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
