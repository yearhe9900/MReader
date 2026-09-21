// 正文内容模型（架构文档 §A.1）。
//
// 纯数据模型：**不依赖 Flutter、不依赖 dart:io**。
// 「段落序列」与「图片页序列」**互斥**：文本格式（EPUB/TXT）只有段落，
// 图片格式（CBZ/PDF 出图）只有图片页，用命名构造器把互斥关系写进类型里。

/// 一章的正文内容。
class ChapterContent {
  const ChapterContent.paragraphs(this.paragraphs) : imagePages = null;
  const ChapterContent.imagePages(this.imagePages) : paragraphs = null;

  /// 段落序列；图片页时为 `null`。
  final List<String>? paragraphs;

  /// 图片页序列（包内路径或已解码位图标识）；段落页时为 `null`。
  final List<String>? imagePages;

  /// 是否为空内容（无段落且无图片页）。
  bool get isEmpty => (paragraphs?.isEmpty ?? true) && (imagePages?.isEmpty ?? true);

  /// 段落安全的读取入口：非段落内容时返回空列表，避免调用方到处判空。
  List<String> get paragraphList => paragraphs ?? const <String>[];

  @override
  String toString() => paragraphs != null
      ? 'ChapterContent.paragraphs(${paragraphs!.length})'
      : 'ChapterContent.imagePages(${imagePages?.length ?? 0})';
}
