// 书籍与章节的纯数据模型。
//
// 本文件**不依赖 Flutter**，只是数据结构，便于单测与后续在正式工程里复用。
import 'dart:typed_data';

import 'chapter.dart';

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
    this.toc = const <Chapter>[],
  });

  /// 书名，来自 OPF 的 dc:title；可能为空字符串。
  final String title;

  /// 作者，来自 OPF 的 dc:creator；可能为空字符串。
  final String author;

  /// 语言，来自 OPF 的 dc:language；可能为空字符串。
  final String language;

  /// 原始文件名。书名缺失时作为兜底显示。
  final String fileName;

  /// 按 spine 顺序排列的章节（非文本资源已剔除）。
  ///
  /// `CNT-05`：`linear="no"` 的非主线章节**保留**在此（不再跳过），
  /// 以 [EpubSection.linear] 标记区分，由章节表标注「（非主线）」展示。
  final List<EpubSection> sections;

  /// 目录（`RD-01`）：EPUB3 `nav.xhtml` 或 EPUB2 `toc.ncx` 的解析结果。
  ///
  /// **空列表表示这本书没有可用目录**，此时调用方应降级为「按 spine 生成平坦目录」。
  /// 默认空列表，保持对既有调用方的向后兼容。
  final List<Chapter> toc;

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
///
/// 提供两种构造：
/// * [EpubSection] —— **急切实体**：构造即持有该章 XHTML 的原始字节；
/// * [EpubSection.lazy] —— **惰性实体**（`PERF-02`）：构造**不**取字节，首次访问
///   [rawBytes] 时才由 `loadBytes` 回调解码。
///
/// 对**消费方而言两者无差别**：一律通过 [rawBytes] getter 读取（类型仍为 [Uint8List]），
/// 故 `dart_epub_source.dart` / 既有测试**无需改动**。对解析器而言，惰性实体让「正文
/// 字节只在 `content(i)` 时才读取」成立——结构解析阶段只建章节骨架、不驻留解压结果。
class EpubSection {
  /// 急切实体：直接持有原始字节（构造即解码）。
  EpubSection({
    required this.id,
    required this.href,
    required Uint8List rawBytes,
    this.linear = true,
  })  : _eagerBytes = rawBytes,
        _loader = null;

  /// 惰性实体（`PERF-02`）：构造**不**取字节，首次访问 [rawBytes] 时才调用 [loadBytes]。
  ///
  /// [loadBytes] 通常闭包捕获包内的 `ArchiveFile`——构造后**不驻留解压结果**
  /// （archive 3.x 的 `ArchiveFile.content` 本身按需解压），非章节资源据此保持压缩态。
  EpubSection.lazy({
    required this.id,
    required this.href,
    required Uint8List Function() loadBytes,
    this.linear = true,
  })  : _eagerBytes = null,
        _loader = loadBytes;

  /// OPF manifest 中的 id，便于调试与定位。
  final String id;

  /// 归一化后的包内路径，例如 `OEBPS/text/ch1.xhtml`。
  final String href;

  /// spine 的 `linear` 属性：`linear="no"` 的非主线章节为 `false`（`CNT-05`）。
  ///
  /// 与解析层的 `EpubSectionRef.linear` 同义；属性缺省即 `true`（主线阅读内容）。
  /// 非主线章节保留可读，由章节表标注「（非主线）」。
  final bool linear;

  final Uint8List? _eagerBytes;
  final Uint8List Function()? _loader;

  /// 该章 XHTML 的原始字节（尚未解码）。
  ///
  /// **不缓存**（`PERF-02` ①：稳态内存不得随「读过的章数」线性增长）：惰性实体**每次访问
  /// 都重新按需解码**——`totalCharCount()` / `search()` 遍历全书后，已读章节的字节会被 GC
  /// 回收，而非永久驻留。急切实体直接返回构造时持有的字节。
  Uint8List get rawBytes => _eagerBytes ?? _loader!();
}
