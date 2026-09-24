// `TYP-06`：书签值对象（纯 Dart，**不 import Flutter、不 import dart:io**）。
//
// 书签 = 「书内一个可回跳的语义位置」，定位三元组与 [ReadingProgress] 同构：
//   · [chapterHref]（`Chapter.href`）是**稳定身份**——跳转先按 href 匹配章；
//   · [chapterIndex] 只是**加速提示**（href 匹配不到时回退并 clamp）；
//   · [chapterPos] 是章内相对位置 `0.0 ~ 1.0`（语义坐标，不含像素值，可同步）。
//
// [chapterTitle] 是添加时的目录标题快照，**仅用于列表展示**（书源重排后标题
// 可能过期，但不影响跳转——跳转只认 href / index / pos）。
// [createdAt]（Unix 毫秒）兼作条目身份（同一毫秒同一位置的重复添加视为同一条）。
//
// 按书持久化（`TYP-06`），落盘经 `BookmarkStore`。
class Bookmark {
  Bookmark({
    required this.bookId,
    required this.chapterHref,
    required this.chapterIndex,
    required double chapterPos,
    required this.chapterTitle,
    required this.createdAt,
  }) : chapterPos = chapterPos.clamp(0.0, 1.0).toDouble();

  /// 归属书籍（`BookRecord.bookId`）——也是书签文件的文件名。
  final String bookId;

  /// 章的稳定身份（`Chapter.href`）——跳转定位的首选键。
  final String chapterHref;

  /// 章节索引（与 `chapters()` 同序）；仅作 href 匹配不到时的回退提示。
  final int chapterIndex;

  /// 章内进度 `0.0 ~ 1.0`（构造时自动 clamp）。
  final double chapterPos;

  /// 添加时的目录标题快照（仅展示用；可为空串）。
  final String chapterTitle;

  /// 创建时间戳（Unix 毫秒），兼作条目身份。
  final int createdAt;

  /// 序列化为 JSON Map。
  Map<String, Object?> toJson() => <String, Object?>{
        'bookId': bookId,
        'chapterHref': chapterHref,
        'chapterIndex': chapterIndex,
        'chapterPos': chapterPos,
        'chapterTitle': chapterTitle,
        'createdAt': createdAt,
      };

  /// 防御式反序列化。
  ///
  /// 非 `Map`、必填字段缺失或类型错误 → 返回 `null`（单条损坏**静默丢弃**，
  /// 不拖垮同文件里的其它书签）。[chapterPos] 越界自动 clamp。
  static Bookmark? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? bookId = json['bookId'];
    final Object? chapterHref = json['chapterHref'];
    final Object? chapterIndex = json['chapterIndex'];
    final Object? chapterPos = json['chapterPos'];
    final Object? chapterTitle = json['chapterTitle'];
    final Object? createdAt = json['createdAt'];
    if (bookId is! String ||
        chapterHref is! String ||
        chapterIndex is! num ||
        chapterPos is! num ||
        chapterTitle is! String ||
        createdAt is! num) {
      return null;
    }
    return Bookmark(
      bookId: bookId,
      chapterHref: chapterHref,
      chapterIndex: chapterIndex.toInt(),
      chapterPos: chapterPos.toDouble(),
      chapterTitle: chapterTitle,
      createdAt: createdAt.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Bookmark &&
          runtimeType == other.runtimeType &&
          bookId == other.bookId &&
          chapterHref == other.chapterHref &&
          chapterIndex == other.chapterIndex &&
          chapterPos == other.chapterPos &&
          chapterTitle == other.chapterTitle &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
        bookId,
        chapterHref,
        chapterIndex,
        chapterPos,
        chapterTitle,
        createdAt,
      );

  @override
  String toString() => 'Bookmark($bookId, href: $chapterHref, '
      'idx: $chapterIndex, pos: ${chapterPos.toStringAsFixed(3)}, '
      'at: $createdAt)';
}
