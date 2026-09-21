// `META-02/03`：EPUB 元数据提取（纯 Dart，架构 §N.4 可进 `compute()`）。
//
// 输入是**已解析好的 OPF 视图** [OpfView]（由 `lib/epub/epub_parser.dart` 与 `EpubBook`
// 同一次解压产出）——**本文件不重复解压**（§N.4 跨任务缝）。
//
// ⚠️ 零 Flutter、零 `dart:io`；**永不 import `lib/format/**`**（§N.0 无环）。
import 'dart:typed_data';

import '../epub/epub_parser.dart';
import '../model/book_meta.dart';
import 'meta_source.dart';
import 'txt_meta.dart';

/// 由 OPF 视图产出 EPUB 的 [BookMeta]。
///
/// - `META-03` 书名：`dc:title`；缺失 -> 文件名规则链 / 文件名主干 -> 「未命名书籍」。
/// - `META-03` 作者：`dc:creator` **多值稳定顺序整体保留**（`Q17`）；缺失 -> 文件名解析 -> 「未知作者」。
/// - `META-01` 简介：`dc:description`；缺失 -> 空串（来源 `none`）。
/// - `META-02` 封面：[OpfView.coverCandidates] **已按优先级排序**，**命中即停**——首个
///   「字节非空 + 魔数嗅探为已知图片格式」的候选 -> [PendingCover]；否则 [NoCover]。
BookMeta buildEpubMeta({required OpfView opfView, required String fileName}) {
  final String stem = fileStem(fileName);
  final FileNameMeta fromName = parseFileNameStem(stem);

  // ---- META-03 书名 ----
  final String metaTitle = (opfView.title ?? '').trim();
  final String title;
  final MetaOrigin titleOrigin;
  if (metaTitle.isNotEmpty) {
    title = metaTitle;
    titleOrigin = MetaOrigin.metadata;
  } else if (fromName.title.trim().isNotEmpty) {
    title = fromName.title.trim();
    titleOrigin = MetaOrigin.filename;
  } else if (stem.isNotEmpty) {
    title = stem;
    titleOrigin = MetaOrigin.filename;
  } else {
    title = kUntitledBook;
    titleOrigin = MetaOrigin.none;
  }

  // ---- META-03 作者：多作者稳定顺序整体保留（不切分） ----
  final List<String> creators = opfView.creators
      .map((String c) => c.trim())
      .where((String c) => c.isNotEmpty)
      .toList(growable: false);
  final String joined = creators.join('；');
  final String author;
  final MetaOrigin authorOrigin;
  if (joined.isNotEmpty) {
    author = joined;
    authorOrigin = MetaOrigin.metadata;
  } else if (fromName.author.trim().isNotEmpty) {
    author = fromName.author.trim();
    authorOrigin = MetaOrigin.filename;
  } else {
    author = kUnknownAuthor;
    authorOrigin = MetaOrigin.none;
  }

  // ---- META-01 简介 ----
  final String metaIntro = (opfView.description ?? '').trim();
  final MetaOrigin introOrigin =
      metaIntro.isNotEmpty ? MetaOrigin.metadata : MetaOrigin.none;

  // ---- META-02 封面：四来源有序，命中即停 ----
  CoverRef cover = const NoCover();
  MetaOrigin coverOrigin = MetaOrigin.none;
  for (final CoverCandidate candidate in opfView.coverCandidates) {
    final Uint8List? bytes = opfView.readEntry?.call(candidate.href);
    if (bytes == null || bytes.isEmpty) continue;
    final CoverFormat format = sniffCoverFormat(bytes);
    if (format == CoverFormat.unknown) continue; // 非图片（如 guide 指向 XHTML 封面页）跳过
    cover = PendingCover(bytes, format);
    coverOrigin = MetaOrigin.metadata;
    break;
  }

  return BookMeta(
    title: title,
    titleOrigin: titleOrigin,
    author: author,
    authorOrigin: authorOrigin,
    intro: metaIntro,
    introOrigin: introOrigin,
    cover: cover,
    coverOrigin: coverOrigin,
    language: (opfView.language ?? '').trim(),
    // M1 阶段 auto 恒非空：即解析结果（此时尚无 user 编辑）。
    auto: BookMetaAuto(title: title, author: author, intro: metaIntro),
  );
}
