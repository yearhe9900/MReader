// `LIB-02`：书库索引的**持久化记录**（纯 Dart，无 Flutter / `dart:io`）。
//
// 本类是书库的最小可持久化单元——一本在库书籍的全部元数据快照。
// 序列化 / 反序列化经 [encodeCoverRef] / [decodeCoverRef]（`META-06 ⑤` 唯一出口），
// JSON 中**不含** `PendingCover`（持久化不变式，由调用方在落盘前物化为 [StoredCover]）。
import '../meta/cover_ref_codec.dart';
import '../model/book_meta.dart';

/// 一本在库书籍的持久化记录。
///
/// 纯 Dart（只 import `model` / `meta`）；不 import Flutter / `dart:io`。
class BookRecord {
  const BookRecord({
    required this.bookId,
    required this.fileName,
    required this.filePath,
    required this.title,
    required this.author,
    required this.format,
    required this.cover,
    required this.importedAt,
    this.lastReadAt,
    this.readProgress,
  });

  /// 内容摘要（SHA-256 hex 前 16 位）；`LIB-05` 判重键。
  final String bookId;

  /// 原始文件名（展示用，如 `三体.epub`）。
  final String fileName;

  /// App 私有目录内的副本**文件名**（相对路径，如 `<bookId>.epub`）。
  final String filePath;

  /// 书名（来自 [BookMeta.title]）。
  final String title;

  /// 作者（来自 [BookMeta.author]）。
  final String author;

  /// 格式标识（`'epub'` / `'txt'`）。
  final String format;

  /// 封面引用（`CoverRef` 四态之一；持久化时**不得**为 [PendingCover]）。
  final CoverRef cover;

  /// 导入时间戳（Unix 毫秒）。
  final int importedAt;

  /// 最后阅读时间（Unix 毫秒；M1-T04 填充，当前为 `null`）。
  final int? lastReadAt;

  /// 已读百分比 `0.0 ~ 1.0`（M1-T04 填充，当前为 `null`）。
  final double? readProgress;

  /// 序列化为 JSON Map（持久化到 `index.json`）。
  Map<String, Object?> toJson() => <String, Object?>{
        'bookId': bookId,
        'fileName': fileName,
        'filePath': filePath,
        'title': title,
        'author': author,
        'format': format,
        'cover': encodeCoverRef(cover),
        'importedAt': importedAt,
        if (lastReadAt != null) 'lastReadAt': lastReadAt,
        if (readProgress != null) 'readProgress': readProgress,
      };

  /// 从 JSON Map 反序列化；必填字段缺失或类型错误时抛异常
  /// （由 `BookIndex.load()` 的 try-catch 逐条降级捕获）。
  factory BookRecord.fromJson(Map<String, Object?> json) {
    final Object? bookId = json['bookId'];
    final Object? fileName = json['fileName'];
    final Object? filePath = json['filePath'];
    final Object? title = json['title'];
    final Object? author = json['author'];
    final Object? format = json['format'];
    final Object? importedAt = json['importedAt'];

    if (bookId is! String ||
        fileName is! String ||
        filePath is! String ||
        title is! String ||
        author is! String ||
        format is! String ||
        importedAt is! num) {
      throw const FormatException('BookRecord JSON 缺少必填字段或类型错误');
    }

    return BookRecord(
      bookId: bookId,
      fileName: fileName,
      filePath: filePath,
      title: title,
      author: author,
      format: format,
      cover: decodeCoverRef(json['cover']),
      importedAt: importedAt.toInt(),
      lastReadAt: (json['lastReadAt'] as num?)?.toInt(),
      readProgress: (json['readProgress'] as num?)?.toDouble(),
    );
  }

  /// 生成一份新副本（M2a 的 `META-09` 换封面、M1-T04 进度更新时使用）。
  BookRecord copyWith({
    String? title,
    String? author,
    CoverRef? cover,
    int? lastReadAt,
    double? readProgress,
  }) {
    return BookRecord(
      bookId: bookId,
      fileName: fileName,
      filePath: filePath,
      title: title ?? this.title,
      author: author ?? this.author,
      format: format,
      cover: cover ?? this.cover,
      importedAt: importedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      readProgress: readProgress ?? this.readProgress,
    );
  }

  /// 标识：内容摘要（同 [bookId]），不按文件名判定「同一本书」。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookRecord && runtimeType == other.runtimeType && bookId == other.bookId;

  @override
  int get hashCode => bookId.hashCode;

  @override
  String toString() => 'BookRecord($bookId, $title, $author, $format)';
}
