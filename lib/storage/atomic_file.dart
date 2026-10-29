// 原子写入通道（PRD `DATA-01`）——本工程所有落盘链路的**唯一入口**。
//
// 语义（对齐 `DATA-01`）：① 写入 = 写到**同目录**临时文件 → flush 落盘 → 原子替换
// 目标文件，任何时刻断电都不会留下半截文件；② 替换采用**轮转式**——先把现有目标
// 轮转为 `.bak` 备份，再把临时文件 rename 成目标，每次读取失败都能回退到上一份有效副本。
//
// 平台差异（Windows 关键坑）：Dart 的 `File.rename` 在 Windows 上**无法覆盖已存在的
// 目标文件**（POSIX 可以），故**不假设 rename 能覆盖**——先删旧 `.bak`，再把 `target`
// rename 成 `.bak` 腾空目标，最后把 `tmp` rename 成 `target`，两步的目标位置都不存在。
//
// 并发：同一进程内对**同一路径**的写入串行化（[_tails] 链式等待），避免交错产生半截
// 文件，**不引入任何锁库**；跨进程并发不在本层保证范围（单进程应用足够）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单个文件的原子写入 / 读取封装。
class AtomicFile {
  AtomicFile(this.path);

  /// 目标文件的绝对或相对路径。
  final String path;

  /// 临时文件路径（**与目标同目录**，避免跨设备 rename 失败）。
  String get tempPath => '$path.tmp';

  /// 备份文件路径（上一份有效副本，供读取失败时回退）。
  String get backupPath => '$path.bak';

  /// 损坏隔离文件路径（由 `JsonStore` 在解析失败时使用，便于排障）。
  String get corruptPath => '$path.corrupt';

  /// 进程内按路径串行化的「队尾」future。
  static final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// 便捷方法：以 UTF-8 原子写入文本。
  Future<void> writeString(String contents) => writeBytes(utf8.encode(contents));

  /// 原子写入字节内容：目录不存在时自动创建；同一路径的写入在本进程内串行执行。
  Future<void> writeBytes(List<int> bytes) {
    return _synchronized(() async {
      final File target = File(path);
      final Directory parent = target.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }

      final File temp = File(tempPath);
      // flush: true → 数据真正落盘后再返回，保证随后 rename 的可见性。
      await temp.writeAsBytes(bytes, flush: true);

      await _commit(target: target, temp: temp);
    });
  }

  /// 读取目标文件内容；不存在返回 `null`。本方法**不做备份回退**——回退语义在解析层
  /// （`JsonStore`）实现，以便区分「文件不存在」（无数据）与「文件损坏 / 替换被中断」（需回退）。
  Future<List<int>?> readBytes() async {
    final File file = File(path);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  /// 读取目标文件 UTF-8 文本；不存在返回 `null`。
  Future<String?> readString() async {
    final List<int>? bytes = await readBytes();
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// 备份文件是否存在。
  Future<bool> hasBackup() => File(backupPath).exists();

  /// 把备份文件复制回目标位置（读取层回退后可调用以「自愈」）。采用「读取备份 →
  /// 写回目标」而非直接 rename，避免破坏 [backupPath] 之外的状态；写入同样经串行化。
  Future<void> restoreFromBackup() {
    return _synchronized(() async {
      final File backup = File(backupPath);
      if (!await backup.exists()) {
        return;
      }
      final List<int> bytes = await backup.readAsBytes();
      final File target = File(path);
      if (!await target.parent.exists()) {
        await target.parent.create(recursive: true);
      }
      await target.writeAsBytes(bytes, flush: true);
    });
  }

  /// 提交：轮转式替换，保证目标位置始终指向一份完整文件。
  Future<void> _commit({required File target, required File temp}) async {
    final File backup = File(backupPath);
    final bool hadTarget = await target.exists();
    bool rotated = false;

    if (hadTarget) {
      // Windows 上 rename 到已存在文件会失败 → 先删掉旧备份再轮转。
      if (await backup.exists()) {
        await backup.delete();
      }
      await target.rename(backupPath);
      rotated = true;
    }

    try {
      await temp.rename(path);
    } catch (error) {
      // 替换失败：把旧文件从备份还原回目标，绝不丢失上一份有效数据。
      if (rotated) {
        try {
          final File current = File(path);
          if (await current.exists()) {
            await current.delete();
          }
          await backup.rename(path);
        } catch (_) {
          // 还原也失败时保持备份文件不动，交由读取层回退。
        }
      }
      rethrow;
    }
  }

  /// 按路径串行执行 [action]，保证同一文件不被并发写入交错。
  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final String key = File(path).absolute.path;
    final Future<void> previous = _tails[key] ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _tails[key] = gate.future;
    try {
      await previous;
      return await action();
    } finally {
      if (identical(_tails[key], gate.future)) {
        _tails.remove(key);
      }
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }
}
