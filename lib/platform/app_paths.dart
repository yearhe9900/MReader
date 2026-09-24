// 应用数据目录解析（平台能力抽象，PRD §15.1）。
//
// 约束：lib/ 内的业务代码**只依赖 [AppPaths] 接口**，具体实现在启动时显式注入
// （见 lib/main.dart）。禁止在业务代码里硬编码路径或直接依赖 path_provider /
// dart:io 的目录 API。
//
// 本文件**只含纯 Dart 接口**（不 import 任何插件）：具体实现
// [PathProviderAppPaths] 在 `path_provider_app_paths.dart`。这样纯 Dart 模块
// （如 `lib/stats/`，`STAT-02` ⑤ 要求零平台插件）与命令行工具
// （`tool/stats_bench.dart`）依赖接口时不被 path_provider 拖进 Flutter 运行时。
import 'dart:io';

/// 应用数据目录解析的抽象接口。
///
/// 所有落盘（设置 / 进度 / 书签 / 笔记 / 书库索引 / 统计分片，见 PRD `DATA-01`）
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
