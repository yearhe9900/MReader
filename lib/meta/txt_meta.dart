// `META-04`：TXT 书名 / 作者的**文件名规则链**（纯 Dart，架构 §N.4 可进 `compute()`）。
//
// ⚠️ 零 Flutter、零 `dart:io`；**永不 import `lib/format/**`**（§N.0 无环）。
import '../model/book_meta.dart';
import 'meta_source.dart';

/// 从文件名主干解析出的书名 / 作者候选（可能为空串）。
class FileNameMeta {
  const FileNameMeta({required this.title, required this.author});

  final String title;
  final String author;

  @override
  String toString() => 'FileNameMeta(title: $title, author: $author)';
}

/// `META-04`：对**文件名主干**依序应用规则、**命中即停**，再清洗 + 兜底。
///
/// 内置规则集**至少覆盖四类**（顺序即优先级）：
///   ① `《书名》…作者：X`
///   ② `《书名》…`（括号书名；作者另从尾部抽）
///   ③ `书名 作者：X`
///   ④ `书名 by X`
/// 全部未命中 → 清洗兜底（剥 `作者xxx` / `xxx 著` 尾巴）。
/// 命中即停：[title] / [author] 为空串表示该字段未解析到，由调用方兜底。
FileNameMeta parseFileNameStem(String stem) {
  final String s = stem.trim();
  if (s.isEmpty) return const FileNameMeta(title: '', author: '');

  // ① / ② 括号书名（`《》` `【】` `［］` 都算），作者另从尾部抽。
  final RegExpMatch? bracket =
      RegExp(r'[《【［]([^》】］]+)[》】］]').firstMatch(s);
  if (bracket != null) {
    final String title = cleanName(bracket.group(1)!);
    if (title.isNotEmpty) {
      return FileNameMeta(title: title, author: _authorFromTail(s));
    }
  }

  // ③ `书名 作者：X`
  final RegExpMatch? byAuthor =
      RegExp(r'^(.*?)[\s\-_]*作者\s*[:：]\s*(.+)$').firstMatch(s);
  if (byAuthor != null) {
    final String title = cleanName(byAuthor.group(1)!);
    final String author = _cleanAuthor(byAuthor.group(2)!);
    if (title.isNotEmpty && author.isNotEmpty) {
      return FileNameMeta(title: title, author: author);
    }
  }

  // ④ `书名 by X`
  final RegExpMatch? byEn =
      RegExp(r'^(.*?)\s+by\s+(.+)$', caseSensitive: false).firstMatch(s);
  if (byEn != null) {
    final String title = cleanName(byEn.group(1)!);
    final String author = _cleanAuthor(byEn.group(2)!);
    if (title.isNotEmpty && author.isNotEmpty) {
      return FileNameMeta(title: title, author: author);
    }
  }

  // ⑤ 清洗兜底：剥 `作者xxx` / `xxx 著` 尾巴后作为书名，作者不成。
  return FileNameMeta(title: cleanName(s), author: '');
}

/// 从字符串**尾部**抽作者（用于括号书名之后仍有 `作者：X` / `by X` 的情形）。
String _authorFromTail(String s) {
  final RegExpMatch? byAuthor = RegExp(r'作者\s*[:：]\s*(.+)$').firstMatch(s);
  if (byAuthor != null) {
    final String a = _cleanAuthor(byAuthor.group(1)!);
    if (a.isNotEmpty) return a;
  }
  final RegExpMatch? byEn =
      RegExp(r'\s+by\s+(.+)$', caseSensitive: false).firstMatch(s);
  if (byEn != null) {
    final String a = _cleanAuthor(byEn.group(1)!);
    if (a.isNotEmpty) return a;
  }
  return '';
}

/// 文件名清洗（`META-04`）：去除 `作者xxx` / `xxx 著` 尾巴并收拢多余空白。
///
/// **精确化兜底**：调用方只在「移除书名占位后另有非空作者候选」时保留作者，
/// **不得**用「长度是否相同」这类粗糙判据（本函数不做长度比较）。
String cleanName(String raw) {
  var s = raw;
  // 去「作者…」尾巴（`作者：X` / `作者X` 均抹去）。
  s = s.replaceAll(RegExp(r'\s*作者\s*[:：]?\s*.*$', dotAll: true), '');
  // 去「… 著」尾巴（只剥「著」字与其前空白，保留作者名）。
  s = s.replaceAll(RegExp(r'\s*著\s*$'), '');
  // 去首尾分隔符与空白。
  s = s.replaceAll(RegExp(r'^[\s\-_、,，]+'), '');
  s = s.replaceAll(RegExp(r'[\s\-_、,，]+$'), '');
  // 收拢多余空白。
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 作者串清洗：去 `作者：` 前缀与 `… 著` 尾巴并收拢空白。
String _cleanAuthor(String raw) {
  var s = raw;
  s = s.replaceFirst(RegExp(r'^\s*作者\s*[:：]?\s*'), '');
  s = s.replaceAll(RegExp(r'\s*著\s*$'), '');
  s = s.replaceAll(RegExp(r'^[\s\-_、,，]+'), '');
  s = s.replaceAll(RegExp(r'[\s\-_、,，]+$'), '');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// `META-04` + `META-01`：由文件名产出 TXT 的 [BookMeta]。
///
/// 来源标记：书名 / 作者来自文件名 -> `filename`；缺失 -> `none`
/// （作者字段缺失时**仍**以「未知作者」兜底，但来源标记为 `none`，符合 `META-01`）。
BookMeta buildTxtMeta({required String fileName}) {
  final String stem = fileStem(fileName);
  final FileNameMeta parsed = parseFileNameStem(stem);

  final String metaTitle = parsed.title.trim();
  final String title = fallbackTitle(metaTitle, stem);
  final MetaOrigin titleOrigin = metaTitle.isNotEmpty
      ? MetaOrigin.filename
      : (stem.isNotEmpty ? MetaOrigin.filename : MetaOrigin.none);

  final String metaAuthor = parsed.author.trim();
  final String author = fallbackAuthor(metaAuthor);
  final MetaOrigin authorOrigin =
      metaAuthor.isNotEmpty ? MetaOrigin.filename : MetaOrigin.none;

  return BookMeta(
    title: title,
    titleOrigin: titleOrigin,
    author: author,
    authorOrigin: authorOrigin,
    intro: '',
    introOrigin: MetaOrigin.none,
    cover: const NoCover(),
    coverOrigin: MetaOrigin.none,
    language: '',
    auto: BookMetaAuto(title: title, author: author, intro: ''),
  );
}
