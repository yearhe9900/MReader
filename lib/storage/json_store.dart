// 基于 [AtomicFile] 的 JSON 读写（PRD `DATA-01`）。
//
// 回退语义（对齐 `DATA-01` ②「每次读取失败都能回退到上一份有效副本」）：
//   · 目标存在且可解析          → 返回目标内容；
//   · 目标不存在但存在 `.bak`   → 视为「替换在轮转后、改名到目标前被中断」，
//                                 回退 `.bak` 并自愈目标；
//   · 目标不存在且无 `.bak`     → 视为「从未写入」，返回 null；
//   · 目标存在但解析失败/为空   → 视为「损坏」：先把损坏文件另存为 `.corrupt`
//                                 （**不静默丢弃**，便于排障），再回退 `.bak`。
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

/// 单个文件的 JSON 读写封装。
class JsonStore {
  JsonStore(this.atomicFile);

  /// 底层原子文件通道。
  final AtomicFile atomicFile;

  /// 写入任意可 JSON 序列化的值（通常是 `Map` / `List`）；经 [AtomicFile] 满足
  /// `DATA-01` 原子性与备份轮转。
  Future<void> write(Object? value) async {
    final String encoded = jsonEncode(value);
    await atomicFile.writeString(encoded);
  }

  /// 读取 JSON 值；无数据或无法回退时返回 `null`。
  Future<Object?> read() async {
    final _Probe primary = await _probe(atomicFile.path);
    switch (primary.status) {
      case _FileStatus.ok:
        return primary.value;
      case _FileStatus.missing:
        if (await atomicFile.hasBackup()) {
          return _fallbackToBackup();
        }
        return null;
      case _FileStatus.corrupt:
        await _quarantine();
        return _fallbackToBackup();
    }
  }

  /// 回退到 `.bak`；成功读取后把备份复制回目标以「自愈」。
  Future<Object?> _fallbackToBackup() async {
    final _Probe backup = await _probe(atomicFile.backupPath);
    if (backup.status != _FileStatus.ok) {
      return null;
    }
    // 自愈：把备份复制回目标，让后续读取回到健康状态（保留 .bak 不删除）。
    await atomicFile.restoreFromBackup();
    return backup.value;
  }

  /// 把损坏的目标文件另存为 `.corrupt`（覆盖上一份隔离文件）。
  Future<void> _quarantine() async {
    final File source = File(atomicFile.path);
    if (!await source.exists()) {
      return;
    }
    final File quarantine = File(atomicFile.corruptPath);
    if (await quarantine.exists()) {
      await quarantine.delete();
    }
    try {
      await source.rename(atomicFile.corruptPath);
    } catch (_) {
      // 隔离失败不应影响主流程；损坏文件保持原位。
    }
  }

  /// 探测某个文件：不存在 / 可解析 / 损坏。
  Future<_Probe> _probe(String filePath) async {
    final File file = File(filePath);
    if (!await file.exists()) {
      return const _Probe.missing();
    }
    try {
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        // 空文件无法解析，视为损坏（`DATA-01` ① 要求重启后文件仍可解析）。
        return const _Probe.corrupt();
      }
      return _Probe.ok(jsonDecode(raw));
    } on FormatException {
      return const _Probe.corrupt();
    } catch (_) {
      // 其它 IO / 解码错误同样按损坏处理。
      return const _Probe.corrupt();
    }
  }
}

enum _FileStatus { ok, missing, corrupt }

class _Probe {
  const _Probe.ok(Object? initial)
      : status = _FileStatus.ok,
        value = initial;

  const _Probe.missing()
      : status = _FileStatus.missing,
        value = null;

  const _Probe.corrupt()
      : status = _FileStatus.corrupt,
        value = null;

  final _FileStatus status;
  final Object? value;
}
