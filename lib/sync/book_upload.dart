// `M4-T04`：书籍文件上传 / 下载（`SYNC-05`，PRD §10.1「书籍文件及其封面——
// 可选开关，**默认关闭**」/ §10.3 `books/` 目录约定）。
//
// 三要点（`SYNC-05` 验收）：
//   ① **默认不传**：[BookUploadPrefsStore] 落盘 `book_upload.json`，缺失即
//      `false`——开关判定在任何网络请求**之前**（零请求）；
//   ② 开启后可上传与下载（远端 `books/{文件名}`，单层目录）；
//   ③ 大文件可取消且有进度：透传 [TransferControl] / `onProgress` 给
//      `WebdavClient.uploadStream` / `downloadToFile`。
//
// 文件名净化与远端安全：basename 过 Windows 非法字符净化（口径同
// `progress_sync._safeSegment`），`.` / `..` / 空名拒绝——WebDAV 单层路径
// 由 WebdavClient 逐段 percent-encode，中文书名安全。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'entry_sync.dart';
import 'sync_config.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

/// 书籍上传开关持久化（`book_upload.json`；**默认关**）。
///
/// 形制与 `SettingsStore` 同款：进程内共享实例 + 组合根显式注入；
/// `load()` 由启动流程调用，未加载 / 缺失一律 `false`（fail-closed——
/// 忘记加载只会导致「不上传」，不会误传）。
class BookUploadPrefsStore {
  /// 用数据目录构造（组合根注入，见 `lib/main.dart`）。
  BookUploadPrefsStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}book_upload.json',
          ),
        );

  final JsonStore _store;

  bool _enabled = false;

  /// 是否允许书籍文件同步（默认 `false`，`SYNC-05` ①）。
  bool get enabled => _enabled;

  /// 从磁盘加载；缺失 / 损坏 / 结构不符 → 保持 `false`。
  Future<void> load() async {
    final Object? json = await _store.read();
    _enabled = json is Map && json['enabled'] == true;
  }

  /// 保存开关（原子写入）。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _store.write(<String, Object?>{'enabled': value});
  }
}

/// 书籍传输动作分类（`SYNC-05` 结果可见）。
enum BookTransferAction {
  /// 已上传远端。
  uploaded,

  /// 已下载到本地。
  downloaded,

  /// 开关关闭——未发起任何请求（`SYNC-05` ①）。
  skipped,

  /// 用户主动取消。
  cancelled,

  /// 失败；[BookUploadOutcome.reason] 给出可读原因（`SYNC-07`）。
  failed,
}

/// 单个文件的传输结果。
class BookUploadOutcome {
  /// 创建结果。
  const BookUploadOutcome({
    required this.fileName,
    required this.action,
    this.reason,
  });

  /// 远端文件名（净化后的 basename）。
  final String fileName;

  /// 动作分类。
  final BookTransferAction action;

  /// 失败 / 取消时的中文可读原因（成功为 `null`）。
  final String? reason;

  /// 是否失败。
  bool get failed => action == BookTransferAction.failed;
}

/// 书籍文件传输引擎（进程内共享，显式注入；触发时机由 `M4-T05` 编排）。
class BookUploadEngine {
  /// 创建引擎（依赖由组合根注入，见 `lib/main.dart`）。
  BookUploadEngine({
    required WebdavClient client,
    required BookUploadPrefsStore prefs,
    required SyncConfigStore configStore,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _client = client, // ignore: prefer_initializing_formals
        _prefs = prefs, // ignore: prefer_initializing_formals
        _configStore = configStore; // ignore: prefer_initializing_formals

  /// 远端书籍子目录（PRD §10.3：`{url}/{dir}/books/`）。
  static const String remoteDir = 'books';

  final WebdavClient _client;
  final BookUploadPrefsStore _prefs;
  final SyncConfigStore _configStore;
  final RemoteDirCache _dirs = RemoteDirCache();

  /// 上传一本书（`SYNC-05` ②③：开关关 → skipped 零请求；开启 → 流式
  /// 上传带进度、可取消）。
  ///
  /// 不抛业务异常：配置 / 通道 / 数据问题一律返回
  /// [BookTransferAction.failed] + 可读 reason（`SYNC-07` 不静默）。
  Future<BookUploadOutcome> uploadBook(
    File file, {
    TransferControl? control,
    void Function(int sent, int total)? onProgress,
  }) async {
    final String name = _remoteName(file.path);
    if (!_prefs.enabled) {
      return _of(name, BookTransferAction.skipped);
    }
    if (!_validName(name)) {
      return _failed(name, '非法文件名');
    }
    if (!await file.exists()) {
      return _failed(name, '书籍文件不存在');
    }
    try {
      final ({SyncConfig config, String password}) ctx =
          await requireWebdav(_configStore);
      await _dirs.ensure(_client, ctx.config, ctx.password, remoteDir);
      await _client.uploadStream(
        ctx.config,
        ctx.password,
        '$remoteDir/$name',
        file.openRead(),
        contentLength: await file.length(),
        control: control,
        onProgress: onProgress,
      );
      return _of(name, BookTransferAction.uploaded);
    } on SyncException catch (e) {
      if (e.kind == SyncErrorKind.cancelled) {
        return BookUploadOutcome(
          fileName: name,
          action: BookTransferAction.cancelled,
          reason: e.message,
        );
      }
      return _failed(name, e.message);
    }
  }

  /// 下载一本书到 [target]（原子替换；开关关 → skipped 零请求）。
  ///
  /// 不抛业务异常，失败分类同 [uploadBook]。
  Future<BookUploadOutcome> downloadBook(
    String fileName,
    File target, {
    TransferControl? control,
    void Function(int received, int total)? onProgress,
  }) async {
    final String name = _remoteName(fileName);
    if (!_prefs.enabled) {
      return _of(name, BookTransferAction.skipped);
    }
    if (!_validName(name)) {
      return _failed(name, '非法文件名');
    }
    try {
      final ({SyncConfig config, String password}) ctx =
          await requireWebdav(_configStore);
      await _client.downloadToFile(
        ctx.config,
        ctx.password,
        '$remoteDir/$name',
        target,
        control: control,
        onProgress: onProgress,
      );
      return _of(name, BookTransferAction.downloaded);
    } on SyncException catch (e) {
      if (e.kind == SyncErrorKind.cancelled) {
        return BookUploadOutcome(
          fileName: name,
          action: BookTransferAction.cancelled,
          reason: e.message,
        );
      }
      return _failed(name, e.message);
    }
  }

  /// 路径 → 远端文件名（basename + Windows 非法字符净化；空回退 `未知`）。
  String _remoteName(String path) {
    final String base = path.split(RegExp(r'[/\\]')).last;
    final String cleaned = base
        .trim()
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? '未知' : cleaned;
  }

  /// 文件名合法性：非空且非 `.` / `..`（净化后只剩这两个形态能穿越单层路径）。
  bool _validName(String name) =>
      name.isNotEmpty && name != '.' && name != '..';

  BookUploadOutcome _of(String name, BookTransferAction action) =>
      BookUploadOutcome(fileName: name, action: action);

  BookUploadOutcome _failed(String name, String reason) => BookUploadOutcome(
        fileName: name,
        action: BookTransferAction.failed,
        reason: reason,
      );
}
