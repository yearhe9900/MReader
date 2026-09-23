// `META-08` / `META-09`：元数据**一次性回填**与来源标记的**纯 Dart** 逻辑。
//
// 本文件只做「记录 × 解析结果 → 新记录」的纯函数变换：
// **不 import Flutter、不 import `dart:io`**——解析（`openBook` / `load`）、封面物化
// （`CoverStore`）与落盘（`LibraryRepository.updateRecord`）都由调用方（详情页）完成。
// 这样 `test/meta/detail_test.dart` 可直接单测每条变换，不必起 widget。
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

/// 详情页加载时是否需要**一次性回填**（旧索引条目检测）。
///
/// 判据 = **四来源全为 `none`**——这正是旧索引条目（`BookRecord.fromJson` 补字段前）
/// 的形态：旧条目四个来源键整体缺失 → 一律读成 `none`。
/// 新导入记录的书名 / 作者来源必为 `metadata` / `filename`（`ImportService` 透传解析结果），
/// 不会命中；TXT 的简介 / 封面解析结果**本就**是 `none`（缺失），若按「任一为 none」触发，
/// 会让每本书每次打开详情页都重新解析，违背「之后不再重解析」的有界 IO 要求。
bool needsOriginBackfill(BookRecord record) =>
    record.titleOrigin == MetaOrigin.none &&
    record.authorOrigin == MetaOrigin.none &&
    record.introOrigin == MetaOrigin.none &&
    record.coverOrigin == MetaOrigin.none;

/// 解析时刻的自动值：`meta.auto` 优先；`auto` 为 `null` 时退解析值本身
/// （`book_meta.dart:81-95` 注释：M1 阶段 `auto` 恒非空，`null` 只表示「未解析」）。
BookMetaAuto autoValuesOf(BookMeta meta) =>
    meta.auto ??
    BookMetaAuto(title: meta.title, author: meta.author, intro: meta.intro);

/// 一次性回填（`META-08`）：**只**把 `origin == none` 的字段替换为解析值。
///
/// - `origin == user` 的字段**绝不动**（`META-09 ④`；`user != none` 天然跳过）；
/// - 已标 `metadata` / `filename` 的字段同样不动；
/// - 封面**引用**不由本函数处理（`PendingCover` 物化需 IO，由调用方完成），
///   本函数只回填 `coverOrigin`。
///
/// 无任何字段需要回填时原样返回同一实例。
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
