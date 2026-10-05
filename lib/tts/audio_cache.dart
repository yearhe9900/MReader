// 在线 TTS 音频本地缓存（`TTS-07` ②「同一段文本二次朗读命中音频缓存」）。
//
// 形制：
//   · 目录 = `<dataDir>/tts_audio/`，一条音频一个文件；
//     文件名 = 请求指纹的 sha256 hex（指纹算法在 `online_tts.dart`
//     [OnlineTts.buildCacheKey]）——命中判定 = 文件存在；
//   · 写入走「临时文件 + rename」：半截下载绝不覆盖既有条目（部分写免疫）；
//     Windows 上 rename 到已存在文件会失败 → 先删目标再 rename
//     （同 `AtomicFile` 轮转口径）；
//   · 不设容量上限（段落音频以 KB 计），[clear] 留给设置页手动清理。
import 'dart:io';
import 'dart:typed_data';

/// 按段落缓存的音频文件仓（目录惰性创建）。
class TtsAudioCache {
  /// 用缓存目录构造（通常 `<dataDir>/tts_audio`）。
  TtsAudioCache(this.directory);

  /// 缓存目录。
  final Directory directory;

  /// 查缓存；命中返回文件，未命中返回 `null`。
  Future<File?> find(String key) async {
    final File file = _fileOf(key);
    try {
      return await file.exists() ? file : null;
    } catch (_) {
      return null; // 目录不可读等异常按未命中处理，走网络重取
    }
  }

  /// 落缓存（临时文件 + rename，覆盖旧条目）。
  Future<void> store(String key, Uint8List bytes) async {
    final File file = _fileOf(key);
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    } catch (_) {
      // 提交失败（磁盘满等）：缓存非关键路径，丢弃临时文件即可。
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 清空缓存（设置页「清理音频缓存」）。
  Future<void> clear() async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 当前条目数（设置页展示用；目录不存在 = 0）。
  Future<int> count() async {
    try {
      if (!await directory.exists()) return 0;
      int n = 0;
      await for (final FileSystemEntity e in directory.list()) {
        if (e is File && e.path.endsWith('.audio')) n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  File _fileOf(String key) =>
      File('${directory.path}${Platform.pathSeparator}$key.audio');
}
