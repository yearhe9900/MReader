// `META-08` / `META-09`：元数据**一次性回填**与来源标记的**纯 Dart** 逻辑。
//
// 只做「记录 × 解析结果 → 新记录」的纯函数变换：**不 import Flutter、不 import
// `dart:io`**——解析（`openBook` / `load`）、封面物化（`CoverStore`）与落盘
// （`LibraryRepository.updateRecord`）都由调用方（详情页）完成，故可直接单测、不必起 widget。
import '../library/book_record.dart';
import '../model/book_meta.dart';

/// 来源标记 → 展示文案（`META-08 ②`：`MetaOrigin` 闭合四值；`none` 显「未知」）。
String originLabel(MetaOrigin origin) {
  switch (origin) {
    case MetaOrigin.metadata:
      return '元数据';
    case MetaOrigin.filename:
      return '文件名推断';
    case MetaOrigin.user:
      return '用户自定义';
    case MetaOrigin.none:
      return '未知';
  }
}

/// 详情页加载时是否需要**一次性回填**（旧索引条目检测）。判据 = **四来源全为 `none`**
/// ——这正是旧索引条目（`BookRecord.fromJson` 补字段前）的形态；新导入记录的书名 / 作者
/// 来源必为 `metadata` / `filename`（`ImportService` 透传解析结果）不会命中，而 TXT 的
/// 简介 / 封面解析结果**本就**是 `none`，若按「任一为 none」触发会让每本书每次打开
/// 详情页都重解析，违背「之后不再重解析」的有界 IO 要求。
bool needsOriginBackfill(BookRecord record) =>
    record.titleOrigin == MetaOrigin.none &&
    record.authorOrigin == MetaOrigin.none &&
    record.introOrigin == MetaOrigin.none &&
    record.coverOrigin == MetaOrigin.none;

/// 解析时刻的自动值：`meta.auto` 优先；`auto` 为 `null` 时退解析值本身
/// （`auto` 恒非空时 `null` 只表示「未解析」）。
BookMetaAuto autoValuesOf(BookMeta meta) =>
    meta.auto ??
    BookMetaAuto(title: meta.title, author: meta.author, intro: meta.intro);

/// 一次性回填（`META-08`）：**只**把 `origin == none` 的字段替换为解析值：`origin == user`
/// 的字段**绝不动**（`META-09 ④`；`user != none` 天然跳过），已标 `metadata` / `filename`
/// 的同样不动；封面**引用**不由本函数处理（`PendingCover` 物化需 IO，由调用方完成），
/// 只回填 `coverOrigin`。无任何字段需要回填时原样返回同一实例。
BookRecord backfillFromMeta(BookRecord current, BookMeta meta) {
  final BookMetaAuto auto = autoValuesOf(meta);
  final bool fillTitle = current.titleOrigin == MetaOrigin.none;
  final bool fillAuthor = current.authorOrigin == MetaOrigin.none;
  final bool fillIntro = current.introOrigin == MetaOrigin.none;
  final bool fillCover = current.coverOrigin == MetaOrigin.none;
  if (!fillTitle && !fillAuthor && !fillIntro && !fillCover) {
    return current;
  }
  return current.copyWith(
    title: fillTitle ? auto.title : null,
    author: fillAuthor ? auto.author : null,
    intro: fillIntro ? auto.intro : null,
    titleOrigin: fillTitle ? meta.titleOrigin : null,
    authorOrigin: fillAuthor ? meta.authorOrigin : null,
    introOrigin: fillIntro ? meta.introOrigin : null,
    coverOrigin: fillCover ? meta.coverOrigin : null,
  );
}

/// 编辑校验（`META-09` 保存前置；`META-01` 作者兜底「未知作者」，**不留空串**）：
/// 返回 `null` = 可保存，否则为就地错误文案（保存按钮据此禁用）。
String? validateEdits({required String title, required String author}) {
  if (title.trim().isEmpty) return '书名不能为空';
  if (author.trim().isEmpty) return '作者不能为空（缺失时填「未知作者」）';
  return null;
}

/// 保存编辑（`META-09`）：**只有值实际发生变化的字段** `origin` 置 `user`，未改字段的
/// 来源原样保留（否则「恢复自动值」的原值无从还原，`META-09 ③`）。输入先 `trim`
/// （与展示口径一致）；全部字段都没变时返回同一实例。
BookRecord applyEdits(
  BookRecord current, {
  required String title,
  required String author,
  required String intro,
}) {
  final String t = title.trim();
  final String a = author.trim();
  final String i = intro.trim();
  final bool changedTitle = t != current.title;
  final bool changedAuthor = a != current.author;
  final bool changedIntro = i != current.intro;
  if (!changedTitle && !changedAuthor && !changedIntro) return current;
  return current.copyWith(
    title: changedTitle ? t : null,
    author: changedAuthor ? a : null,
    intro: changedIntro ? i : null,
    titleOrigin: changedTitle ? MetaOrigin.user : null,
    authorOrigin: changedAuthor ? MetaOrigin.user : null,
    introOrigin: changedIntro ? MetaOrigin.user : null,
  );
}

/// 「恢复自动值」（`META-09 ③`）：书名 / 作者 / 简介回到自动值（`meta.auto`，
/// null 时退解析值本身），四来源改回**解析值**（`metadata` / `filename` / `none`）。
///
/// 封面**引用**不由本函数处理（`PendingCover` 物化 / 旧文件清理需 IO），
/// 由调用方完成后 `copyWith(cover:)`；本函数只回填 `coverOrigin`。
BookRecord restoreFromMeta(BookRecord current, BookMeta meta) {
  final BookMetaAuto auto = autoValuesOf(meta);
  return current.copyWith(
    title: auto.title,
    author: auto.author,
    intro: auto.intro,
    titleOrigin: meta.titleOrigin,
    authorOrigin: meta.authorOrigin,
    introOrigin: meta.introOrigin,
    coverOrigin: meta.coverOrigin,
  );
}
