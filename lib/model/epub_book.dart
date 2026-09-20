// 书籍与章节的纯数据模型。
//
// 本文件**不依赖 Flutter**，只是数据结构，便于单测与后续在正式工程里复用。
import 'dart:typed_data';

/// 一本书的结构 + 元数据。
///
/// 关键设计：这里**不保存**解析后的正文文本，只保存每章 XHTML 的原始字节。
/// 正文由 UI 在滚动到附近时按需解析（见 `epub/section_extractor.dart`），
/// 避免一次性把整本书的排版结果铺进内存。
class EpubBook {
  const EpubBook({
    required this.title,
    required this.author,
    required this.language,
    required this.fileName,
    required this.sections,
  });

  /// 书名，来自 OPF 的 dc:title；可能为空字符串。
  final String title;

  /// 作者，来自 OPF 的 dc:creator；可能为空字符串。
  final String author;

  /// 语言，来自 OPF 的 dc:language；可能为空字符串。
  final String language;

  /// 原始文件名。书名缺失时作为兜底显示。
  final String fileName;

  /// 按 spine 顺序排列的章节（已跳过 `linear="no"` 的项）。
  final List<EpubSection> sections;

  /// 给 UI 用的显示名：书名 -> 文件名 -> 占位。
  String get displayTitle {
    if (title.isNotEmpty) return title;
    if (fileName.isNotEmpty) return fileName;
    return '未命名书籍';
  }

  /// 作者 + 语言的一行摘要，供 AppBar 副标题使用。
  String get subtitle {
    final parts = <String>[
      if (author.isNotEmpty) author,
      if (language.isNotEmpty) language,
    ];
    return parts.join(' · ');
  }
}

/// 一个 spine 项（一章）。
class EpubSection {
  const EpubSection({
    required this.id,
    required this.href,
    required this.rawBytes,
  });

  /// OPF manifest 中的 id，便于调试与定位。
  final String id;

  /// 归一化后的包内路径，例如 `OEBPS/text/ch1.xhtml`。
  final String href;

  /// 该章 XHTML 的原始字节（尚未解码）。按需解码是「不一次性解析整本书」的关键。
  final Uint8List rawBytes;
}
