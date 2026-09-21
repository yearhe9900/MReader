// EPUB 包内路径与 zip 条目的匹配工具（从 `epub_parser.dart` 提出，供 `epub_toc.dart` 复用）。
//
// **行为与 M0 期既有实现逐字一致**：`fx01` / `fx02a` / `fx02b` / `fx03` 四个 fixture
// 覆盖了「大小写不敏感 + 百分号解码 / 编码三试探」，本文件不得改变既有匹配行为。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 尝试解 zip；把异常收敛成 `null`，由上层转成可读的中文错误。
Archive? tryDecodeZip(Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return null;
  }
}

/// 取 [ArchiveFile] 的字节内容。
///
/// 用 `dynamic` + 类型判断，兼容 archive 3.x 里 `content` 可能是
/// `Uint8List` 或 `List<int>` 的不同实现细节。
Uint8List contentOfArchiveFile(ArchiveFile file) {
  final dynamic content = file.content;
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  return Uint8List(0);
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

/// 在包内查找资源。依次尝试下列候选（一律**大小写不敏感**）：
/// 1. 归一化后的原路径；
/// 2. 百分号**解码**后的路径（`%E7%AC%AC` -> 中文，匹配 zip 内是真实中文名的书，`fx02a`）；
/// 3. 百分号**编码**后的路径（中文 -> `%E7%AC%AC`，匹配 zip 条目名本身即编码的畸形书，`fx02b`）。
Uint8List? lookupInFiles(
  Map<String, Uint8List> files,
  Map<String, String> lowerIndex,
  String path,
) {
  final Set<String> candidates = <String>{
    normalizeZipPath(path),
    normalizeZipPath(decodePercentPath(path)),
    normalizeZipPath(encodePercentPath(path)),
  };
  for (final String candidate in candidates) {
    if (candidate.isEmpty) continue;
    final Uint8List? direct = files[candidate];
    if (direct != null) return direct;
    final String? byLower = lowerIndex[candidate.toLowerCase()];
    if (byLower != null) return files[byLower];
  }
  return null;
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
/// 判定顺序：
/// 1. 有明确 media-type：`image/` `audio/` `video/` 或含 css/font/javascript 的一律排除；
/// 2. media-type 缺失：先按扩展名判断，再用字节魔数（PNG/JPEG/GIF/BMP/WEBP）兜底嗅探。
///
/// 现实里（回归 fixture `fx07b`）封面图常被塞进 spine 且漏写 media-type，
/// 只看 media-type 会把它当正文段落输出。
bool looksTextual(String? mediaType, String href, Uint8List bytes) {
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
  return !_looksBinaryByExtension(href) && !_looksBinaryByMagic(bytes);
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
