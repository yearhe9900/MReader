// `M4-T04`：从备份包恢复（`SYNC-04` ②「全新设备恢复后书架与进度与源设备
// 一致」，PRD §10.3 包内布局的逆向落地）。
//
// 安全闸门（任何写入之前）：
//   ① zip 必须可解（复用 [tryDecodeZip]——archive 4.x 垃圾字节静默返空的
//      EOCD 判废坑与 EPUB 链路同款）；
//   ② `meta.json` 必有且可解析；
//   ③ `schemaVersion <= [maxSchemaVersion]`——版本过新**零写入**直接失败
//      （老应用恢复新包只会得到半懂不懂的残缺数据，宁可拒绝）。
//
// 写入纪律：
//   · **显式白名单分派**——包内条目名不落白名单一律 `skipped++`，路径穿越
//     （`../`、多级段、非法字符）在分派前就被拒，`_join` 永远拿不到危险输入；
//   · 重组段（bookshelf / settings / bookmark）经 [JsonStore] 原子写入；
//     原字节段（progress / stats / aiCache / vocab / tts）经 [AtomicFile]
//     **保真落盘**；
//   · 单条目损坏只 `skipped++`，不中断其余条目（与 `LIB-03` 逐条降级同哲学）。
//
// 诚实降级（`NF-C8`）：`note.json` 是占位（笔记存储未落地）→ 合法忽略不计数。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../epub/zip_paths.dart';
import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'entry_sync.dart';
import 'sync_config.dart';
import 'sync_config_store.dart';
import 'webdav_client.dart';

/// 条目文件白名单（与 `backup.dart` 同口径）：`<bookId>.json`。
final RegExp _entryJson = RegExp(r'^[A-Za-z0-9_-]+\.json$');

/// 纯 key 白名单（bookmark.json 的键 / 书签名）：字母 / 数字 / `_` / `-`。
final RegExp _keyName = RegExp(r'^[A-Za-z0-9_-]+$');

/// 统计分片白名单（与 `backup.dart` 同口径）。
final RegExp _statShard = RegExp(r'^sessions-\d{4}-\d{2}\.json$');

/// RAG 缓存白名单（与 `backup.dart` 同口径）。
final RegExp _ragJson = RegExp(r'^rag_[A-Za-z0-9_-]+\.json$');

/// 拼数据目录内的相对路径（与 `backup.dart` 同口径；`rel` 用 `/`）。
String _join(Directory dataDir, String rel) =>
    '${dataDir.path}${Platform.pathSeparator}'
    '${rel.replaceAll('/', Platform.pathSeparator)}';

/// 一次恢复的结果（`SYNC-07`：失败带可读原因；成功给逐类计数与汇总行）。
class RestoreOutcome {
  /// 创建结果。
  const RestoreOutcome({
    required this.restored,
    required this.skipped,
    required this.summary,
    this.meta,
    this.reason,
  });

  /// 逐类恢复计数（`bookshelf` / `settings` / `bookmark` / `progress` /
  /// `stats` / `aiCache` / `vocab` / `tts`；失败为空表）。
  final Map<String, int> restored;

  /// 跳过条目数（未知条目 / 非法路径 / 单条损坏）。
  final int skipped;

  /// 包内 `meta.json`（成功时带回；失败为 `null`）。
  final Map<String, Object?>? meta;

  /// 失败时的中文可读原因（成功为 `null`）。
  final String? reason;

  /// 中文汇总行（成功 = `恢复 N 项 · 跳过 M 项`；失败 = 同 [reason]）。
  final String summary;

  /// 是否成功。
  bool get ok => reason == null;

  /// 恢复条目总数。
  int get totalRestored =>
      restored.values.fold(0, (int sum, int count) => sum + count);
}

/// 恢复引擎（进程内共享，显式注入；`M4-T05` 编排「从云端恢复」入口）。
class RestoreEngine {
  /// 创建引擎（依赖由组合根注入，见 `lib/main.dart`）。
  RestoreEngine({
    required AppPaths paths,
    required WebdavClient client,
    required SyncConfigStore configStore,
  })  : // 私有字段作**命名**初始化形参仅位置参数合法（同 `high_perf_registry.dart`），
        // 字段名 = '_' + 参数名触发 `prefer_initializing_formals` → 显式赋值 + 行尾 ignore。
        _paths = paths, // ignore: prefer_initializing_formals
        _client = client, // ignore: prefer_initializing_formals
        _configStore = configStore; // ignore: prefer_initializing_formals

  /// 本应用可读的最高包版本（`meta.schemaVersion`；更高 → 拒绝零写入）。
  static const int maxSchemaVersion = 1;

  final AppPaths _paths;
  final WebdavClient _client;
  final SyncConfigStore _configStore;

  /// 从远端下载备份包并恢复（通道 / 配置失败 → failed + 可读 reason）。
  Future<RestoreOutcome> restoreFromRemote(String remotePath) async {
    final List<int> bytes;
    try {
      final ({SyncConfig config, String password}) ctx =
          await requireWebdav(_configStore);
      bytes = await _client.download(ctx.config, ctx.password, remotePath);
    } on SyncException catch (e) {
      return _failed(e.message);
    }
    return restoreFromZip(bytes);
  }

  /// 从 zip 字节恢复（`SYNC-04` ②）；不抛——坏包 / 版本过新 / 单条损坏
  /// 一律收敛为 failed 或 `skipped++`。
  Future<RestoreOutcome> restoreFromZip(List<int> zipBytes) async {
    try {
      final Archive? archive = tryDecodeZip(Uint8List.fromList(zipBytes));
      if (archive == null) {
        return _failed('备份包不是有效的 zip 文件');
      }

      // 归一化条目索引（重名取首个；空名 / 目录残留忽略）。
      final Map<String, ArchiveFile> entries = <String, ArchiveFile>{};
      for (final ArchiveFile file in archive) {
        final String name = normalizeZipPath(file.name);
        if (name.isEmpty) {
          continue;
        }
        entries.putIfAbsent(name, () => file);
      }

      // ── 闸门：meta 必有 + 版本可读——全部在任何写入之前 ──
      final ArchiveFile? metaFile = entries['meta.json'];
      if (metaFile == null) {
        return _failed('备份包缺少 meta.json');
      }
      final Object? metaRaw = _decode(contentOfArchiveFile(metaFile));
      if (metaRaw is! Map) {
        return _failed('备份包 meta.json 损坏');
      }
      final Map<String, Object?> meta = Map<String, Object?>.from(metaRaw);
      final Object? version = meta['schemaVersion'];
      if (version is! num) {
        return _failed('备份包缺少版本号（schemaVersion）');
      }
      if (version > maxSchemaVersion) {
        return _failed(
          '备份包版本 $version 过新，当前应用仅支持版本 $maxSchemaVersion',
        );
      }

      // ── 白名单分派写入 ──
      final Directory dataDir = await _paths.dataDir();
      final Map<String, int> restored = <String, int>{};
      int skipped = 0;

      void bump(String key) => restored[key] = (restored[key] ?? 0) + 1;

      for (final MapEntry<String, ArchiveFile> entry in entries.entries) {
        final String name = entry.key;
        if (name == 'meta.json' || name == 'note.json') {
          continue; // meta 已作闸门；note 是占位（无存储，合法忽略）。
        }
        final List<int> bytes = contentOfArchiveFile(entry.value);

        if (name == 'bookshelf.json') {
          final Object? value = _decode(bytes);
          if (value is! Map) {
            skipped += 1;
            continue;
          }
          const Map<String, String> segments = <String, String>{
            'index': 'library/index.json',
            'shelfLayout': 'shelf_layout.json',
            'shelfPrefs': 'shelf_prefs.json',
          };
          for (final MapEntry<String, String> segment in segments.entries) {
            final Object? part = value[segment.key];
            if (part == null) {
              continue;
            }
            await _writeJson(dataDir, segment.value, part);
            bump('bookshelf');
          }
          continue;
        }

        if (name == 'settings.json') {
          final Object? value = _decode(bytes);
          if (value is! Map) {
            skipped += 1;
            continue;
          }
          const Map<String, String> segments = <String, String>{
            'app': 'settings.json',
            'reading': 'prefs/reading_prefs.json',
          };
          for (final MapEntry<String, String> segment in segments.entries) {
            final Object? part = value[segment.key];
            if (part == null) {
              continue;
            }
            await _writeJson(dataDir, segment.value, part);
            bump('settings');
          }
          continue;
        }

        if (name == 'bookmark.json') {
          final Object? value = _decode(bytes);
          if (value is! Map) {
            skipped += 1;
            continue;
          }
          for (final MapEntry<Object?, Object?> item in value.entries) {
            final Object? key = item.key;
            final Object? content = item.value;
            // 键过白名单（防路径穿越）+ 防串档哨兵（bookId 必须自洽）。
            if (key is! String ||
                !_keyName.hasMatch(key) ||
                content is! Map ||
                content['bookId'] != key) {
              skipped += 1;
              continue;
            }
            await _writeJson(dataDir, 'bookmarks/$key.json', content);
            bump('bookmark');
          }
          continue;
        }

        if (name.startsWith('progress/')) {
          final String rest = name.substring('progress/'.length);
          if (rest.contains('/') ||
              !_entryJson.hasMatch(rest) ||
              !_isJson(bytes)) {
            skipped += 1;
            continue;
          }
          await _writeBytes(dataDir, name, bytes);
          bump('progress');
          continue;
        }

        if (name.startsWith('stats/')) {
          final String rest = name.substring('stats/'.length);
          if (rest.contains('/') ||
              !(_statShard.hasMatch(rest) || rest == 'stats-config.json') ||
              !_isJson(bytes)) {
            skipped += 1;
            continue;
          }
          await _writeBytes(dataDir, name, bytes);
          bump('stats');
          continue;
        }

        if (name.startsWith('aiCache/')) {
          final String rest = name.substring('aiCache/'.length);
          if (rest.contains('/') ||
              !(rest == 'summary.json' || _ragJson.hasMatch(rest)) ||
              !_isJson(bytes)) {
            skipped += 1;
            continue;
          }
          await _writeBytes(dataDir, name, bytes);
          bump('aiCache');
          continue;
        }

        if (name == 'vocab.json' || name == 'tts_settings.json') {
          if (!_isJson(bytes)) {
            skipped += 1;
            continue;
          }
          await _writeBytes(dataDir, name, bytes);
          bump(name == 'vocab.json' ? 'vocab' : 'tts');
          continue;
        }

        skipped += 1; // 未知条目（含 `../` 路径穿越形态）——不写、只计数。
      }

      final int total =
          restored.values.fold(0, (int sum, int count) => sum + count);
      return RestoreOutcome(
        restored: restored,
        skipped: skipped,
        meta: meta,
        summary: '恢复 $total 项 · 跳过 $skipped 项',
      );
    } catch (e) {
      return _failed('恢复失败：$e');
    }
  }

  /// 失败结果（summary 同 reason，UI 直接回显）。
  RestoreOutcome _failed(String reason) => RestoreOutcome(
        restored: const <String, int>{},
        skipped: 0,
        summary: reason,
        reason: reason,
      );

  /// 重组段原子写入（[JsonStore] → [AtomicFile]，`DATA-01`）。
  Future<void> _writeJson(Directory dataDir, String rel, Object? value) =>
      JsonStore(AtomicFile(_join(dataDir, rel))).write(value);

  /// 原字节保真写入（[AtomicFile]，`DATA-01`）。
  Future<void> _writeBytes(Directory dataDir, String rel, List<int> bytes) =>
      AtomicFile(_join(dataDir, rel)).writeBytes(bytes);

  /// 解析 JSON；非法 / 畸形 UTF-8 → `null`。
  Object? _decode(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  /// 字节是否为合法 JSON（原字节段的入库前校验）。
  bool _isJson(List<int> bytes) {
    try {
      jsonDecode(utf8.decode(bytes));
      return true;
    } catch (_) {
      return false;
    }
  }
}
