// 章节定位模型（架构文档 §A.1）。
//
// 纯数据模型：**不依赖 Flutter、不依赖 dart:io**，可直接在 isolate 与单测中使用。

/// 章节定位信息。**这是全项目唯一的「章节」类型**：`lib/epub/**`（目录解析）、
/// `lib/format/**`（各格式实现）与 UI 共用，**不得再复制第二份**（结构相同会导致
/// 无意义的字段搬运、各实现各自挑类型）；本文件是**叶子**：不 import 任何东西。
/// [href] 是章节的**稳定身份**：`RD-04`（阅读进度）与 `SYNC-02`（同步）都以它对齐，
/// 实现方必须保证「同一章在同一本书里 href 恒定」。
class Chapter {
  const Chapter({
    required this.href,
    required this.title,
    required this.level,
    required this.locate,
  });

  /// 定位串：EPUB = 包内路径（如 `OEBPS/text/ch1.xhtml`）；TXT = `txt:<起始字符偏移>`
  /// （形如 `txt:0`，**字符**偏移而非字节）。
  final String href;

  /// 目录标题（已折叠空白）。
  final String title;

  /// 层级深度，0 = 顶层。目录按此缩进。
  final int level;

  /// 章内定位（EPUB 的 fragment id，不含 `'#'`）；无则空串。
  final String locate;

  @override
  String toString() =>
      'Chapter(href: $href, title: $title, level: $level, locate: $locate)';
}
