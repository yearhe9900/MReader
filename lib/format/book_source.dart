// §7.1 格式解析统一抽象（纯 Dart：**不 import Flutter、不 import dart:io**）。
//
// 这是 `PERF-01`（解析移出主 isolate）的硬前提：本目录下的所有类型都只依赖
// `dart:typed_data` / `dart:convert` 与纯 Dart 包，因此可以直接丢进 `compute()`。
//
// 各格式实现（EPUB / TXT / …）**互不感知**，由 [BookRegistry]（见 `book_registry.dart`）按格式选择；
// Rust 加速层（M3.5）挂在本抽象**之后**，与纯 Dart 实现并存（PRD §15.6.1）。
//
// ⚠️ **本文件只放「纯类型 + export」，不得出现任何具体实现的 import**
// （架构 §A.1 铁律第 3 条：「选择发生在 BookRegistry，实现类之间没有任何 import」）。
// 分发点 `BookRegistry` / `sniffFormat` / `openBook` 都在 `book_registry.dart`——
// 把 `dart_epub_source.dart` / `dart_txt_source.dart` 加进来会破坏该铁律，
// 并让本文件变成所有实现（含未来的 Rust 实现）的汇聚点。**请不要加回去。**
import 'dart:typed_data';

import '../model/book_meta.dart';
import '../model/chapter.dart';
import '../model/chapter_content.dart';

export 'error_messages.dart';
export '../model/book_meta.dart';
export '../model/chapter.dart';
export '../model/chapter_content.dart';

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

  /// 按包内路径读取任意资源字节（图片 / 字体 / CSS）。
  ///
  /// [href] 是**已解析的绝对包内路径**（如 `OEBPS/images/cover.jpg`）。
  /// TXT 源无资源 → 返回 `null`。EPUB 源按需解压（`lazyEntryLoader`，不常驻）。
  Future<Uint8List?> readResource(String href) async => null;

  Future<void> dispose();
}
