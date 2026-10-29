// EPUB 包内路径与 zip 条目的匹配工具（从 `epub_parser.dart` 提出，供 `epub_toc.dart` 复用）。
//
// **行为与 M0 期既有实现逐字一致**：`fx01` / `fx02a` / `fx02b` / `fx03` 四个 fixture
// 覆盖了「大小写不敏感 + 百分号解码 / 编码三试探」，**不得改变既有匹配行为**。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 尝试解 zip；把异常收敛成 `null`，由上层转成可读的中文错误。
///
/// ⚠️ archive 4.x 对**无 EOCD 记录**的垃圾字节会**静默返回空 Archive**（3.x 抛
/// `ArchiveException`），不判废会让上层错误码后移成 `missingContainer` / `noImagePages`，
/// 破坏 `RD-05` 的「同型同码」契约；故解码后显式检查 `filePosition < 0` = 不是 zip
/// （合法 zip 含空 zip 必有 EOCD，误杀面为零）。
Archive? tryDecodeZip(Uint8List bytes) {
  try {
    final ZipDecoder decoder = ZipDecoder();
    final Archive archive = decoder.decodeBytes(bytes);
    if (decoder.directory.filePosition < 0) return null;
    return archive;
  } catch (_) {
    return null;
  }
}

/// 取 [ArchiveFile] 的字节内容（**按需解压且缓存在条目上**；限一次性读取路径）。
Uint8List contentOfArchiveFile(ArchiveFile file) => file.readBytes() ?? Uint8List(0);

/// 为一个**尚未解压**的归档条目构造「按需、**非驻留**」解压器（`PERF-02` ①）。
///
/// 返回的闭包**不保留解压结果**（每次从压缩态字节重新解压），长期持有不会让读过的章驻留。
/// 不能用 `file.readBytes()`：它**一次解压即永久缓存** `_content` 在条目上，遍历全书后
/// 稳态内存又回到「全书大小」，正是 `PERF-02` ① 要消除的。`file.decompress(out)` 带输出
/// 即不落缓存（库原生保证非驻留，全压缩法同路径）；坏条目解压失败优雅返回空字节，
/// 不向渲染层抛。
Uint8List Function() lazyEntryLoader(ArchiveFile file) {
  return () {
    try {
      final OutputMemoryStream out = OutputMemoryStream();
      file.decompress(out);
      return out.getBytes();
    } catch (_) {
      return Uint8List(0);
    }
  };
}

/// 归一化包内路径：统一分隔符、去掉 `'./'` 与开头的 `'/'`、压掉重复斜杠。
String normalizeZipPath(String raw) {
  var s = raw.replaceAll('\\', '/');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  s = s.replaceAll(RegExp(r'/+'), '/');
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
}

/// 解码路径里的百分号转义（如 `%20` -> 空格，`%E7%AC%AC` -> 中文字符）。
///
/// 用 `Uri.decodeComponent`：它按 UTF-8 解码且**不会**把 `'+'` 当成空格。
/// 遇到畸形转义就原样返回，不抛异常。
String decodePercentPath(String value) {
  if (!value.contains('%')) return value;
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

/// 把路径里的非 ASCII 字符做百分号编码（保留 `'/'` 等保留字符，不做多余转义）。
///
/// 用于匹配「zip 条目名本身就是百分号编码」的畸形 EPUB（回归 fixture `fx02b`）：
/// 这类书的 href 与条目名**解码后**一致，需要用「编码后」的形态去命中真实条目名。
String encodePercentPath(String value) {
  if (_isAllAscii(value)) return value;
  try {
    return Uri.encodeFull(value);
  } catch (_) {
    return value;
  }
}

/// 是否全部为 ASCII。
bool _isAllAscii(String value) {
  for (int i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) > 0x7F) return false;
  }
  return true;
}

/// 把相对 href 解析成相对于 [baseDir] 的规范化包内路径。
///
/// 会去掉 fragment 与 query（章节文件本身不含它们），并做百分号解码。
String resolveHref(String baseDir, String href) {
  var h = href.trim();

  // 去掉 fragment 与 query（spine 指向的是文件本身）。
  final int hash = h.indexOf('#');
  if (hash >= 0) h = h.substring(0, hash);
  final int question = h.indexOf('?');
  if (question >= 0) h = h.substring(0, question);

  h = decodePercentPath(h).replaceAll('\\', '/');
  if (h.isEmpty) return '';

  final String joined =
      (baseDir.isEmpty || baseDir == '.') ? h : p.posix.join(baseDir, h);
  return p.posix.normalize(joined);
}

/// 解析 [path] 到**真实条目名**（大小写不敏感 + 百分号三试探）；找不到返回 `null`。
///
/// 「惰性读取」的关键一步（`PERF-02` ①）：只建**条目名索引**（廉价、不解压），字节读取
/// 交调用方**按需**进行——避免为建索引把整本（含图片 / 字体 / CSS）解压常驻。候选依次
/// （一律**大小写不敏感**）：1. 归一化后的原路径；2. 百分号**解码**后的路径（`fx02a`）；
/// 3. 百分号**编码**后的路径（条目名本身即编码的畸形书，`fx02b`）。
String? resolveEntryName(Map<String, String> lowerIndex, String path) {
  final Set<String> candidates = <String>{
    normalizeZipPath(path),
    normalizeZipPath(decodePercentPath(path)),
    normalizeZipPath(encodePercentPath(path)),
  };
  for (final String candidate in candidates) {
    if (candidate.isEmpty) continue;
    final String? byLower = lowerIndex[candidate.toLowerCase()];
    if (byLower != null) return byLower;
  }
  return null;
}

/// 在「已持有全部条目字节」的映射里查找资源（保留旧签名，行为逐字一致）。
/// **新代码优先用 [resolveEntryName] + 按需读取**（见 `epub_parser.dart` 的惰性 `lookup`），
/// 以免把整本解压结果钉在内存里。
Uint8List? lookupInFiles(
  Map<String, Uint8List> files,
  Map<String, String> lowerIndex,
  String path,
) {
  final String? name = resolveEntryName(lowerIndex, path);
  if (name == null) return null;
  return files[name];
}

/// media-type 缺失时的兜底：需要排除出 spine 的**非文本**资源扩展名。
const Set<String> _binaryExtensions = <String>{
  'png', 'jpg', 'jpeg', 'jpe', 'gif', 'bmp', 'webp', 'tif', 'tiff',
  'ico', 'svg', 'avif', 'heic', 'apng',
  'mp3', 'mp4', 'm4a', 'ogg', 'oga', 'wav', 'aac', 'flac', 'webm', 'avi', 'mov',
  'ttf', 'otf', 'woff', 'woff2', 'eot',
  'css', 'js', 'mjs',
};

/// 该 spine 项是否可能是「文本内容」。
///
/// 判定顺序：1. 有明确 media-type：`image/` `audio/` `video/` 或含 css/font/javascript
/// 的一律排除；2. media-type 缺失：先按扩展名，再用字节魔数（PNG/JPEG/GIF/BMP/WEBP）
/// 兜底——封面图常被塞进 spine 且漏写 media-type（`fx07b`），只看声明会当正文输出。
bool looksTextual(String? mediaType, String href, Uint8List bytes) {
  final bool? verdict = textualVerdict(mediaType, href);
  if (verdict != null) return verdict;
  return !_looksBinaryByMagic(bytes);
}

/// **无需字节**的文本性判定（`PERF-02` ①：正文/资源分离）：解析器据此在**不解压**
/// 条目的前提下决定是否收进骨架。返回 `true` = 仅凭声明即文本（应构造**惰性**
/// `EpubSection`，解压推迟到 `content(i)`）；`false` = 明确非文本；`null` = 声明不足，
/// **必须**再看字节魔数（由 [looksTextual] 兜底，会解压该**单个**条目，属罕见脏书写法）。
bool? textualVerdict(String? mediaType, String href) {
  if (mediaType != null && mediaType.isNotEmpty) {
    final String m = mediaType.toLowerCase();
    if (m.startsWith('image/')) return false;
    if (m.startsWith('audio/')) return false;
    if (m.startsWith('video/')) return false;
    if (m.contains('css')) return false;
    if (m.contains('font')) return false;
    if (m.contains('javascript')) return false;
    return true;
  }
  if (_looksBinaryByExtension(href)) return false;
  return null; // 扩展名不暴露二进制 -> 无法仅凭名字判定
}

/// 扩展名兜底：href 以已知二进制扩展名结尾 -> 不是文本。
bool _looksBinaryByExtension(String href) {
  final String path = normalizeZipPath(decodePercentPath(href)).toLowerCase();
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  final String ext = path.substring(dot + 1);
  return _binaryExtensions.contains(ext);
}

/// 字节魔数兜底：文件头就能看出是图片等二进制 -> 不是文本。
bool _looksBinaryByMagic(Uint8List bytes) {
  final int n = bytes.length;
  if (n >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) return true; // BMP "BM"
  if (n >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return true; // JPEG
  }
  if (n >= 4) {
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return true; // PNG
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return true; // GIF8
    }
    if (n >= 12 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return true; // WEBP (RIFF....WEBP)
    }
  }
  return false;
}
