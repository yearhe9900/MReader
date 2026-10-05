// `TYP-06~09`：阅读偏好持久化（排版 + 亮度 + 背景色，**全局一份、不分书**）。
//
// 落点：`<dataDir>/prefs/reading_prefs.json`——单文件小偏好，与
// `SettingsStore`（`<dataDir>/settings.json`）同一「小文件」量级；
// 落盘一律经 [JsonStore] → [AtomicFile]（`DATA-01` 原子写入 + 备份回退）。
//
// 为什么全局而不是按书：PRD §10.1 把「阅读设置：字号/行距/边距/主题/字体/亮度」
// 归为**全局设置项**（同步时「取最近修改」），不是逐书数据；`TYP-08` 的
// 「亮度…保留」同理（夜间亮度是环境偏好，不随书变）。
import 'dart:io';

import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'reading_prefs.dart';

/// 阅读偏好持久化服务（进程内共享，显式注入 `ReaderPage`）。
class ReadingPrefsStore {
  ReadingPrefsStore(this._paths);

  final AppPaths _paths;

  /// 偏好子目录名（落在 `<dataDir>/prefs/`）。
  static const String dirName = 'prefs';

  /// 偏好文件名。
  static const String fileName = 'reading_prefs.json';

  /// 加载阅读偏好。
  ///
  /// 文件缺失 / 无法回退 → 返回 `null`（调用方回落默认值）；
  /// 文件存在但个别字段非法 → 由 [ReadingPrefs.fromJson] **逐项**回退默认。
  Future<ReadingPrefs?> load() async {
    final JsonStore store = await _store();
    final Object? json = await store.read();
    if (json == null) {
      return null;
    }
    return ReadingPrefs.fromJson(json);
  }

  /// 保存阅读偏好（原子写入）。
  Future<void> save(ReadingPrefs prefs) async {
    final JsonStore store = await _store();
    await store.write(prefs.toJson());
  }

  /// 偏好文件本身（`SYNC-03` 设置同步取「最近修改」用：比较本地文件 mtime
  /// 与远端 mtime——不给 `ReadingPrefs` 加时间字段，不动数据模型）。
  Future<File> file() async {
    final JsonStore store = await _store();
    return File(store.atomicFile.path);
  }

  /// 偏好文件对应的 [JsonStore]。
  Future<JsonStore> _store() async {
    final Directory dir = await _paths.subDir(dirName);
    return JsonStore(
      AtomicFile('${dir.path}${Platform.pathSeparator}$fileName'),
    );
  }
}
