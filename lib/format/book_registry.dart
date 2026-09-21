// 装配 + 分发点（架构文档 §A.1 的 `book_registry.dart` / §A.2）。
//
// **为什么单独一个文件**（架构文档 §A.1 铁律第 3 条）：
// `BookSource` 各实现（Dart / Rust）**互不感知**，选择发生在 [BookRegistry]，
// 实现类之间没有任何 import。若把 `openBook` 写在 `book_source.dart` 里，
// 抽象层就得 import 具体实现，M3.5 加 Rust 实现时该文件会变成所有实现的汇聚点。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'dart:typed_data';

import 'book_source.dart';
import 'dart_epub_source.dart';
import 'dart_txt_source.dart';

// `MReaderFormatException` / `FormatErrorCode` 经 `book_source.dart` 的
// `export 'error_messages.dart';` 转出，不再单独 import（避免重复导入同一个库）。

/// 格式种类。
enum FormatKind { epub, txt, unsupported }

/// 装配 + 分发点。
///
/// M3.5 接入 Rust 时会加可选构造参数 `HighPerfRegistry? highPerf`
/// （架构 §A.2 的 `BookRegistry({HighPerfRegistry? highPerf, ...})`），
/// 由 `main()` 注入；届时「按探测结果择实现」只改本文件的 [open]。
class BookRegistry {
  const BookRegistry();

  /// 按一级（扩展名）+ 二级（魔数）选择实现。
  ///
  /// - `epub` → [DartEpubSource]；
  /// - `txt`  → [DartTxtSource]（M1-T02B 接入）；
  /// - `unsupported` → 抛 [MReaderFormatException]（`RD-05`）。
  ///
  /// 返回的永远是 [BookSource] 抽象——调用方无法、也无需知道来源。
  Future<BookSource> open({
    required String fileName,
    required Uint8List bytes,
  }) async {
    switch (sniffFormat(fileName: fileName, bytes: bytes)) {
      case FormatKind.epub:
        return DartEpubSource(fileName: fileName, bytes: bytes);
      case FormatKind.txt:
        return DartTxtSource(fileName: fileName, bytes: bytes);
      case FormatKind.unsupported:
        throw const MReaderFormatException(FormatErrorCode.unsupportedFormat);
    }
  }
}

/// 便捷包装：等价于 `const BookRegistry().open(...)`（**签名与 M1-T02A 冻结时一致**）。
///
/// 测试与 `main()` 用这个；M3.5 后 `main()` 改为持有注入过的 [BookRegistry] 实例。
Future<BookSource> openBook({
  required String fileName,
  required Uint8List bytes,
}) =>
    const BookRegistry().open(fileName: fileName, bytes: bytes);

/// 一级（扩展名）+ 二级（魔数）分发（PRD §7.3；`FMT-06` 的完整纠偏在 M2b）。
///
/// 规则：
/// - **EPUB**：扩展名 `.epub`（**以扩展名为主**——`.zip` 改名 `.epub` 也要交给 EPUB 解析器，
///   由它给出「不是有效 EPUB」的可读提示，而不是在这里静默拒绝）；
/// - **TXT**：非 zip 且（扩展名 `.txt` 或字节可判为文本）；
/// - 其余：`unsupported`。
FormatKind sniffFormat({
  required String fileName,
  required Uint8List bytes,
}) {
  final String ext = _extensionOf(fileName);

  if (ext == 'epub') return FormatKind.epub;
  if (_looksLikeZip(bytes)) return FormatKind.unsupported;
  if (ext == 'txt') return FormatKind.txt;
  if (_looksLikeText(bytes)) return FormatKind.txt;
  return FormatKind.unsupported;
}

/// 取小写扩展名（不含点）；无扩展名返回空串。
String _extensionOf(String fileName) {
  final String name = fileName.replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  final String base = slash >= 0 ? name.substring(slash + 1) : name;
  final int dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// 是否是 zip 容器（PK 头的三种形态：本地文件头 / 空档案 / 分卷档案）。
bool _looksLikeZip(Uint8List bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
  return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
      (bytes[2] == 0x05 && bytes[3] == 0x06) ||
      (bytes[2] == 0x07 && bytes[3] == 0x08);
}

/// 字节是否「看起来是文本」（`.txt` 之外的兜底；完整嗅探属 M2b 的 `FMT-06`）。
///
/// 判据（保守，宁可判为不支持也不误开二进制）：
/// 1. 无 `0x00`（含 NUL 的几乎一定是二进制）；
/// 2. 头部 512 字节里没有除 `\t \n \f \r` 之外的 C0 控制符；
/// 3. 非 ASCII 字节视为文本（中文 TXT 必然是高位字节）。
bool _looksLikeText(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  final int head = bytes.length > 512 ? 512 : bytes.length;
  for (int i = 0; i < head; i++) {
    final int b = bytes[i];
    if (b == 0x00) return false;
    if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0C && b != 0x0D) {
      return false;
    }
  }
  return true;
}
