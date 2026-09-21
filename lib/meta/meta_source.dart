// 元数据装配的**纯 Dart**公共部件（架构 §N.4：可进 `compute()`）。
//
// 职责：
//   · 来源标记装配所需的**统一兜底**（「未知作者」/「未命名书籍」，`META-01`）；
//   · 封面**魔数嗅探** `sniffCoverFormat`（只看前几字节、**不解码**，`META-05`）；
//   · 文件名去目录 / 去扩展名 `fileStem`（EPUB / TXT 共用）。
//
// ⚠️ 本文件**零 Flutter、零 `dart:io`**（`PERF-01` 硬前提），且**永不 import `lib/format/**`**（§N.0 无环）。
import 'dart:typed_data';

import '../model/book_meta.dart';

/// 作者缺失时的**统一兜底文案**（`META-01`：作者不得留空字符串）。
const String kUnknownAuthor = '未知作者';

/// 书名缺失时的**统一兜底文案**（`META-01`）。
const String kUntitledBook = '未命名书籍';

/// 魔数嗅探封面格式（**不看扩展名**，`META-05` / §N.6）。
///
/// 只看前几个字节，**不解码**——这是让「嗅探（纯 Dart、可进 isolate）」与
/// 「解码（`dart:ui`、须 Flutter）」拆开的关键。
/// - JPEG：`FF D8 FF`
/// - PNG：`89 50 4E 47 0D 0A 1A 0A`
/// - WebP：`RIFF`????`WEBP`
/// - GIF：`GIF8`
/// - BMP：`BM`
/// - 都不匹配 → [CoverFormat.unknown]
CoverFormat sniffCoverFormat(Uint8List bytes) {
  final int n = bytes.length;

  if (n >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return CoverFormat.jpeg;
  }
  if (n >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return CoverFormat.png;
  }
  if (n >= 12 &&
      bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x45 && // E
      bytes[10] == 0x42 && // B
      bytes[11] == 0x50) {
    // P
    return CoverFormat.webp;
  }
  if (n >= 4 &&
      bytes[0] == 0x47 && // G
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x38) {
    // 8
    return CoverFormat.gif;
  }
  if (n >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    // BM
    return CoverFormat.bmp;
  }
  return CoverFormat.unknown;
}

/// 作者兜底：空 / 纯空白 -> [kUnknownAuthor]（`META-01`）。
String fallbackAuthor(String raw) {
  final String value = raw.trim();
  return value.isEmpty ? kUnknownAuthor : value;
}

/// 书名兜底：`raw` 非空用 `raw`；否则用 `fallback`；再空则 [kUntitledBook]（`META-01`）。
String fallbackTitle(String raw, String fallback) {
  final String value = raw.trim();
  if (value.isNotEmpty) return value;
  final String alt = fallback.trim();
  return alt.isNotEmpty ? alt : kUntitledBook;
}

/// 文件名去目录、去扩展名（不含 `dart:io`；兼容 Windows 的 `\`）。
///
/// 口径：`红楼梦.txt` → `红楼梦`；`noext` → `noext`；`.txt`（只有扩展名、无书名）→ 空串；
/// `a.b.txt` → `a.b`（只去最后一段）。与 M1-T02B 的既有口径一致。
String fileStem(String fileName) {
  final String name = fileName.replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  final String base = slash >= 0 ? name.substring(slash + 1) : name;
  final int dot = base.lastIndexOf('.');
  final String stem;
  if (dot < 0) {
    stem = base; // 无扩展名
  } else if (dot == 0) {
    stem = ''; // 形如 `.txt`：点前没有书名
  } else {
    stem = base.substring(0, dot);
  }
  return stem.trim();
}
