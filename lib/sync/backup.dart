// `M4-T04`：全量备份包构建与上传（`SYNC-04`，PRD §10.3 备份包约定）。
//
// 包内布局严格按 §10.3（至少包含且**不含凭据**——`M4-T09` 验收「备份包内
// 搜不到 API Key 与 WebDAV 密码」）：
// ```
// bookshelf.json   书架（library/index.json + shelf_layout + shelf_prefs 三段）
// progress/        全部书籍进度（原字节）
// bookmark.json    书签（{bookId: 内容}）
// note.json        笔记（占位——存储未落地，诚实降级 `NF-C8`）
// settings.json    阅读设置（settings.json + prefs/reading_prefs.json 双段）
// stats/           阅读统计（分片 + stats-config，原字节）
// aiCache/         AI 缓存（可选，默认关）
// meta.json        schemaVersion / exportedAt / deviceName / 包内文件清单
// ```
// 另附本地 `vocab.json`、`tts_settings.json`（§10.3「至少包含」的超集）。
//
// **凭据靠白名单结构性排除**（非黑名单）：`sync_config.json`（连接配置）、
// `credentials.json`（SecureStore 明文壳）、`sync_state.json`、`perf_prefs.json`、
// `ai_providers.json`、书籍副本 / `structure/` / `covers/` 与 `.bak` / `.corrupt`
// / `.tmp` 兄弟文件都不在白名单内，永不可能进包。
//
// 远端命名（§10.3）：`backup-{yyyy-MM-dd}-{device}.zip`，落在远端根目录。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../platform/app_paths.dart';
import 'entry_sync.dart';
import 'sync_config.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

/// 条目文件白名单：`<bookId>.json`（bookmarks / progress 共用；
/// 天然排除 `.bak` / `.corrupt` / `.tmp` 兄弟文件）。
final RegExp _entryJson = RegExp(r'^[A-Za-z0-9_-]+\.json$');

/// 统计分片白名单：`sessions-YYYY-MM.json`。
final RegExp _statShard = RegExp(r'^sessions-\d{4}-\d{2}\.json$');

/// AI 缓存白名单：RAG 索引 `rag_<bookId>.json`。
final RegExp _ragJson = RegExp(r'^rag_[A-Za-z0-9_-]+\.json$');

/// 拼数据目录内的相对路径（`rel` 用 `/`，按平台分隔符落盘）。
String _join(Directory dataDir, String rel) =>
    '${dataDir.path}${Platform.pathSeparator}'
    '${rel.replaceAll('/', Platform.pathSeparator)}';

/// 一次全量备份的结果（`SYNC-07`：失败带可读原因，不静默）。
class BackupOutcome {
  /// 创建结果（成功带 [remotePath]，失败带 [reason]）。
  const BackupOutcome({
    this.remotePath,
    this.fileCount = 0,
    this.zipBytes = 0,
    this.reason,
  });

  /// 远端备份文件路径（相对远端根；失败为 `null`）。
  final String? remotePath;

  /// 包内文件数（含 `meta.json`）。
  final int fileCount;

  /// zip 字节数（失败为 0）。
  final int zipBytes;

  /// 失败时的中文可读原因（成功为 `null`）。
  final String? reason;

  /// 是否成功。
  bool get ok => reason == null;
}

/// 远端备份清单条目（`listBackups` 返回）。
class BackupEntry {
  /// 创建条目。
  const BackupEntry({required this.path, required this.lastModified});

  /// 相对远端根的文件名（如 `backup-2026-10-05-MReader.zip`）。
  final String path;

  /// 远端修改时间（服务器未返回为 `null`）。
  final DateTime? lastModified;
}

/// 全量备份引擎（进程内共享，显式注入；触发时机由 `M4-T05` 编排）。
class BackupEngine {
  /// 创建引擎（依赖由组合根注入，见 `lib/main.dart`）；[clock] 仅测试拨时。
  BackupEngine({
    required AppPaths paths,
    required WebdavClient client,
    required SyncConfigStore configStore,
    DateTime Function()? clock,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _paths = paths, // ignore: prefer_initializing_formals
        _client = client, // ignore: prefer_initializing_formals
        _configStore = configStore, // ignore: prefer_initializing_formals
        _now = clock ?? DateTime.now;

  final AppPaths _paths;
  final WebdavClient _client;
  final SyncConfigStore _configStore;
  final DateTime Function() _now;
  final RemoteDirCache _dirs = RemoteDirCache();

  /// 构建备份包（`SYNC-04` ①：白名单收集 → zip 字节）。
  ///
  /// [includeAiCache] 默认 `false`（§10.1：AI 缓存体积大、可选）。
  /// 本地缺失 / 损坏的段**不进包**（不传播损坏，恢复端也不覆盖该段）。
  Future<({Uint8List zip, int fileCount})> buildZip({
    bool includeAiCache = false,
  }) async {
    final Directory dataDir = await _paths.dataDir();
    final Archive archive = Archive();
    final List<String> names = <String>[];

    void addBytes(String name, List<int> bytes) {
      archive.addFile(ArchiveFile.bytes(name, bytes));
      names.add(name);
    }

    void addJson(String name, Object? value) =>
        addBytes(name, utf8.encode(jsonEncode(value)));

    // ① 书架三段 → bookshelf.json。
    final Map<String, Object?> shelf = <String, Object?>{};
    final Object? index = await _readJson(dataDir, 'library/index.json');
    if (index != null) {
      shelf['index'] = index;
    }
    final Object? layout = await _readJson(dataDir, 'shelf_layout.json');
    if (layout != null) {
      shelf['shelfLayout'] = layout;
    }
    final Object? shelfPrefs = await _readJson(dataDir, 'shelf_prefs.json');
    if (shelfPrefs != null) {
      shelf['shelfPrefs'] = shelfPrefs;
    }
    if (shelf.isNotEmpty) {
      addJson('bookshelf.json', shelf);
    }

    // ② 设置双段 → settings.json（app = 主题/字号，reading = 阅读偏好）。
    final Map<String, Object?> settings = <String, Object?>{};
    final Object? app = await _readJson(dataDir, 'settings.json');
    if (app != null) {
      settings['app'] = app;
    }
    final Object? reading =
        await _readJson(dataDir, 'prefs/reading_prefs.json');
    if (reading != null) {
      settings['reading'] = reading;
    }
    if (settings.isNotEmpty) {
      addJson('settings.json', settings);
    }

    // ③ 书签 → bookmark.json（{bookId: 文件内容}）。
    final Map<String, Object?> bookmarks = <String, Object?>{};
    for (final String name
        in await _whitelisted(dataDir, 'bookmarks', (String n) => _entryJson.hasMatch(n))) {
      final Object? content = await _readJson(dataDir, 'bookmarks/$name');
      if (content != null) {
        bookmarks[name.substring(0, name.length - '.json'.length)] = content;
      }
    }
    if (bookmarks.isNotEmpty) {
      addJson('bookmark.json', bookmarks);
    }

    // ④ 进度 / 统计 → 原字节逐文件进包（保真）。
    await _addDirBytes(
      dataDir,
      archive,
      names,
      'progress',
      (String n) => _entryJson.hasMatch(n),
    );
    await _addDirBytes(
      dataDir,
      archive,
      names,
      'stats',
      (String n) => _statShard.hasMatch(n) || n == 'stats-config.json',
    );

    // ⑤ AI 缓存（可选，默认关）。
    if (includeAiCache) {
      await _addDirBytes(
        dataDir,
        archive,
        names,
        'aiCache',
        (String n) => n == 'summary.json' || _ragJson.hasMatch(n),
      );
    }

    // ⑥ 词库 / TTS 设置（§10.3「至少包含」的超集，白名单单文件）。
    await _addFileBytes(dataDir, addBytes, 'vocab.json');
    await _addFileBytes(dataDir, addBytes, 'tts_settings.json');

    // ⑦ 笔记占位（存储未落地，`NF-C8` 诚实降级——包结构先对齐 §10.3）。
    addBytes('note.json', utf8.encode('{"notes":[]}'));

    // ⑧ meta.json：版本号 / 导出时间 / 设备名 / 包内文件清单（不含自身）。
    final Map<String, Object?> meta = <String, Object?>{
      'schemaVersion': 1,
      'exportedAt': _now().toIso8601String(),
      'deviceName': _safeSegment(_deviceName()),
      'files': <String>[...names]..sort(),
    };
    addJson('meta.json', meta);

    return (
      zip: ZipEncoder().encodeBytes(archive),
      fileCount: names.length,
    );
  }

  /// 立即全量备份（构建 zip → 上传远端根 `backup-{日期}-{设备}.zip`）。
  ///
  /// 不抛业务异常：配置 / 通道 / 本地数据问题一律返回 failed + 可读 reason
  /// （`SYNC-07` 不静默）。
  Future<BackupOutcome> backupNow({bool includeAiCache = false}) async {
    try {
      final ({SyncConfig config, String password}) ctx =
          await requireWebdav(_configStore);
      final ({Uint8List zip, int fileCount}) built =
          await buildZip(includeAiCache: includeAiCache);
      final String name = 'backup-${_dateKey(_now())}-'
          '${_safeSegment(ctx.config.deviceName)}.zip';
      await _dirs.ensure(_client, ctx.config, ctx.password, '');
      await _client.upload(ctx.config, ctx.password, name, built.zip);
      return BackupOutcome(
        remotePath: name,
        fileCount: built.fileCount,
        zipBytes: built.zip.length,
      );
    } on SyncException catch (e) {
      return BackupOutcome(reason: e.message);
    } catch (e) {
      return BackupOutcome(reason: '备份失败：$e');
    }
  }

  /// 列出远端备份包（根目录 `backup-*.zip`，按 mtime 新→旧；404 → 空表）。
  ///
  /// 未配置 / 通道错误**原样抛** [SyncException]（可读原因）——列表失败
  /// 若静默成空表会让用户误以为「从未备份过」（`SYNC-07`）。
  Future<List<BackupEntry>> listBackups() async {
    final ({SyncConfig config, String password}) ctx =
        await requireWebdav(_configStore);
    final List<WebdavEntry> entries;
    try {
      entries = await _client.list(ctx.config, ctx.password, '');
    } on SyncException catch (e) {
      if (e.kind == SyncErrorKind.notFound) {
        return const <BackupEntry>[]; // 远端根还不存在 = 从未备份。
      }
      rethrow;
    }
    final List<BackupEntry> out = <BackupEntry>[];
    for (final WebdavEntry entry in entries) {
      final String path = entry.path;
      if (entry.isCollection ||
          path.isEmpty ||
          path.contains('/') ||
          !path.startsWith('backup-') ||
          !path.endsWith('.zip')) {
        continue;
      }
      out.add(BackupEntry(path: path, lastModified: entry.lastModified));
    }
    out.sort((BackupEntry a, BackupEntry b) {
      final DateTime? am = a.lastModified;
      final DateTime? bm = b.lastModified;
      if (am == null && bm == null) {
        return a.path.compareTo(b.path);
      }
      if (am == null) {
        return 1; // 无时间戳排后（同名兜底靠 path，序稳定）。
      }
      if (bm == null) {
        return -1;
      }
      final int byTime = bm.compareTo(am); // 新 → 旧。
      return byTime != 0 ? byTime : a.path.compareTo(b.path);
    });
    return out;
  }

  /// 当前设备名（未配置连接时回退默认——`buildZip` 可离线用）。
  String _deviceName() =>
      _configStore.config?.deviceName ?? SyncConfig.defaultDeviceName;

  /// 某目录下过白名单的文件名（basename，升序——包内顺序稳定可断言）。
  Future<List<String>> _whitelisted(
    Directory dataDir,
    String rel,
    bool Function(String name) keep,
  ) async {
    final Directory dir = Directory(_join(dataDir, rel));
    if (!await dir.exists()) {
      return const <String>[];
    }
    final List<String> out = <String>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (keep(name)) {
        out.add(name);
      }
    }
    out.sort();
    return out;
  }

  /// 把目录下过白名单的 JSON 文件按**原字节**加进包（`{rel}/{name}` 命名）。
  Future<void> _addDirBytes(
    Directory dataDir,
    Archive archive,
    List<String> names,
    String rel,
    bool Function(String name) keep,
  ) async {
    for (final String name in await _whitelisted(dataDir, rel, keep)) {
      final List<int>? bytes = await _readBytes(dataDir, '$rel/$name');
      if (bytes == null) {
        continue;
      }
      archive.addFile(ArchiveFile.bytes('$rel/$name', bytes));
      names.add('$rel/$name');
    }
  }

  /// 单文件原字节进包（缺失 / 读失败跳过）。
  Future<void> _addFileBytes(
    Directory dataDir,
    void Function(String name, List<int> bytes) add,
    String rel,
  ) async {
    final List<int>? bytes = await _readBytes(dataDir, rel);
    if (bytes != null) {
      add(rel, bytes);
    }
  }

  /// 读文件字节；不存在返 `null`。
  Future<List<int>?> _readBytes(Directory dataDir, String rel) async {
    final File file = File(_join(dataDir, rel));
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  /// 读 JSON；缺失 / 损坏 / 非法 JSON → `null`（损坏段不进包）。
  Future<Object?> _readJson(Directory dataDir, String rel) async {
    final List<int>? bytes = await _readBytes(dataDir, rel);
    if (bytes == null) {
      return null;
    }
    try {
      return jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  /// 文件名段净化（口径同 `progress_sync._safeSegment`：路径分隔符与
  /// Windows 非法字符替换为 `_`，空白折叠；空回退 `未知`——设备名进包名）。
  String _safeSegment(String raw) {
    final String cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? '未知' : cleaned;
  }

  /// `yyyy-MM-dd`（本地日期，文件名用）。
  String _dateKey(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-'
      '${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}
