// §7.1 格式解析统一抽象（纯 Dart：**不 import Flutter、不 import dart:io**）。
//
// 这是 `PERF-01`（解析移出主 isolate）的硬前提：本目录下的所有类型都只依赖
// `dart:typed_data` / `dart:convert` 与纯 Dart 包，因此可以直接丢进 `compute()`。
//
// 各格式实现（EPUB / TXT / …）**互不感知**，由分发点按格式选择实现；
// Rust 加速层（M3.5）挂在本抽象**之后**，与纯 Dart 实现并存（PRD §15.6.1）。
import 'dart:typed_data';

import '../model/chapter.dart';
import '../model/chapter_content.dart';
import 'dart_epub_source.dart';
import 'error_messages.dart';

export 'error_messages.dart';
export '../model/chapter.dart';
export '../model/chapter_content.dart';

/// 书籍元数据（含来源标记，对应 `META-01`）。
class BookMeta {
  const BookMeta({
    required this.title,
    required this.author,
    required this.language,
    required this.coverBytes,
    required this.titleOrigin,
    required this.authorOrigin,
    required this.coverOrigin,
  });

  final String title;
  final String author;
  final String language;

  /// 封面字节；本批（M1-T02A）恒为 `null`，封面链路属 `M1-T05`。
  final Uint8List? coverBytes;

  /// 来源标记（`META-01`）：如 `'opf:dc:title'` / `'exth:100'` / `'filename'` / `'none'`。
  final String titleOrigin;
  final String authorOrigin;
  final String coverOrigin;
}

/// 本格式支持哪些能力。
class SourceCapabilities {
  const SourceCapabilities({
    required this.hasImages,
    required this.hasFootnotes,
    required this.reflowable,
    required this.searchable,
    required this.charCountSupported,
  });

  final bool hasImages;
  final bool hasFootnotes;

  /// 是否可重排（TXT / EPUB 为 true，PDF / CBZ 为 false）。
  final bool reflowable;
  final bool searchable;

  /// `STAT-14` 用：是否能给出全书字符总数。
  final bool charCountSupported;
}

/// 取消令牌（统一后台任务抽象的一部分，见架构文档 §F）。
class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 搜索命中。
class SearchHit {
  const SearchHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.offset,
    required this.context,
  });

  /// 章节索引，与 `chapters()` 返回的列表**同序**。
  final int chapterIndex;
  final String chapterTitle;

  /// 章内字符偏移（按「段落字符数累加」计），供列表展示与跳转定位。
  final int offset;

  /// 命中段落（当前实现为「命中所在的整段」），供列表展示。
  final String context;
}

/// 搜索事件：命中 **或** 进度（二者必居其一）。
class SearchEvent {
  const SearchEvent.hit(SearchHit this.hit) : progress = null;
  const SearchEvent.progress(double this.progress) : hit = null;

  final SearchHit? hit;

  /// `0.0 ~ 1.0`；`null` 表示这不是进度事件。
  final double? progress;
}

/// §7.1 格式解析统一抽象。**各实现互不感知**。
abstract class BookSource {
  /// 实现标识：`'dart-epub'` / `'dart-txt'`（将来 `'rust-epub'` …）。仅日志 / 体检用。
  String get implId;

  Future<BookMeta> load();

  Future<List<Chapter>> chapters();

  Future<ChapterContent> content(int chapterIndex);

  SourceCapabilities capabilities();

  /// 全书搜索（`CNT-06` 的纯 Dart 基线，M2b 才产品化）。
  Stream<SearchEvent> search(String query, {required CancelToken cancel});

  /// 全书字符总数（`STAT-14` 用）。不支持时返回 `null`。
  ///
  /// **这是对架构文档 §A.1 的显式增补**：PRD `STAT-14` 要求「字符数来自
  /// `BookSource.capabilities()` 暴露的全书字符总数」，而 §A.1 只列了
  /// `charCountSupported` 布尔量。这里用带默认实现的具体方法补入，
  /// **不破坏 §A.1 的既有字段与签名**。
  Future<int?> totalCharCount() async => null;

  Future<void> dispose();
}

/// 格式种类。
enum FormatKind { epub, txt, unsupported }

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

/// 打开一本本地书（**纯字节入口**：不碰路径，才能在 isolate 里跑）。
///
/// - `epub` → [DartEpubSource]；
/// - `txt`  → **本批（M1-T02A）尚未接入**，由 M1-T02B 的 `DartTxtSource` 绑定到此处；
/// - `unsupported` → 抛 [MReaderFormatException]（`RD-05`）。
///
/// 这是架构文档 §A.2 的 `BookRegistry` 前身；M3.5 接 Rust 时由 `BookRegistry` 接管，
/// **本函数签名不变**，上层调用点无需改动。
Future<BookSource> openBook({
  required String fileName,
  required Uint8List bytes,
}) async {
  switch (sniffFormat(fileName: fileName, bytes: bytes)) {
    case FormatKind.epub:
      return DartEpubSource(fileName: fileName, bytes: bytes);
    case FormatKind.txt:
      // M1-T02B 会在这里返回 DartTxtSource(fileName: fileName, bytes: bytes)。
      throw const MReaderFormatException(
        FormatErrorCode.unsupportedFormat,
        detail: 'TXT 分支由 M1-T02B 接入',
      );
    case FormatKind.unsupported:
      throw const MReaderFormatException(FormatErrorCode.unsupportedFormat);
  }
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
