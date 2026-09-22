// `RD-04`：阅读进度值对象（纯 Dart，**不 import Flutter、不 import dart:io**）。
//
// 进度的**稳定身份是 [chapterHref]**（`Chapter.href`）——章节在书内的稳定定位串；
// [chapterIndex] 只是**加速提示**：恢复时先按 href 匹配章节，匹配不到再退回 index
// 并 clamp。这样即使书源重排 / 目录微调，仍尽量落回同一章，而不是「跳错章」。
//
// **语义字段**（`bookId` / `chapterHref` / `chapterIndex` / `chapterPos` / `updatedAt`）
// 是可**跨设备同步**的（`SYNC-02` 会用），故其中不含任何像素值。
// 另有一个 [localHint]：**设备本地版面快照**，仅用于本机精确恢复；
// **跨设备同步时必须丢弃**（它绑定当前字号 / 行距 / 视口尺寸 / 滚动偏移）。
//
// 本文件是纯数据模型：可在 isolate 与单测中直接使用。落盘经 `ProgressStore`。

/// 设备本地版面快照（**不参与跨设备同步**）。
///
/// 用于「同一设备、同一版面」下零抖动精确恢复：直接照搬 [scrollOffset] 即可，
/// 不必依赖章高测量与迭代校正。
class LocalLayoutHint {
  const LocalLayoutHint({
    required this.scrollOffset,
    required this.fontSize,
    required this.lineHeight,
    required this.viewportWidth,
    required this.viewportHeight,
  });

  /// 保存时「整本连续滚动列表」的绝对像素偏移（`ScrollController.offset`）。
  final double scrollOffset;

  /// 保存时的字号（逻辑像素）。
  final double fontSize;

  /// 保存时的行距倍数。
  final double lineHeight;

  /// 保存时视口宽度（逻辑像素）。
  final double viewportWidth;

  /// 保存时视口高度（逻辑像素）。
  final double viewportHeight;

  /// 序列化为 JSON Map。
  Map<String, Object?> toJson() => <String, Object?>{
        'scrollOffset': scrollOffset,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'viewportWidth': viewportWidth,
        'viewportHeight': viewportHeight,
      };

  /// 防御式反序列化：非 `Map` / 任一字段缺失或类型不对 → 返回 `null`（不报错）。
  static LocalLayoutHint? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? scrollOffset = json['scrollOffset'];
    final Object? fontSize = json['fontSize'];
    final Object? lineHeight = json['lineHeight'];
    final Object? viewportWidth = json['viewportWidth'];
    final Object? viewportHeight = json['viewportHeight'];
    if (scrollOffset is! num ||
        fontSize is! num ||
        lineHeight is! num ||
        viewportWidth is! num ||
        viewportHeight is! num) {
      return null;
    }
    return LocalLayoutHint(
      scrollOffset: scrollOffset.toDouble(),
      fontSize: fontSize.toDouble(),
      lineHeight: lineHeight.toDouble(),
      viewportWidth: viewportWidth.toDouble(),
      viewportHeight: viewportHeight.toDouble(),
    );
  }

  /// 是否与给定版面「同签名」（字号 / 行距 / 视口尺寸全部一致，容差 0.5 逻辑像素）。
  ///
  /// 同签名 → 可直接照搬 [scrollOffset] 精确恢复；否则需按比例估算 + 校正。
  bool matches({
    required double fontSize,
    required double lineHeight,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    bool near(double a, double b) => (a - b).abs() <= 0.5;
    return near(this.fontSize, fontSize) &&
        near(this.lineHeight, lineHeight) &&
        near(this.viewportWidth, viewportWidth) &&
        near(this.viewportHeight, viewportHeight);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalLayoutHint &&
          runtimeType == other.runtimeType &&
          scrollOffset == other.scrollOffset &&
          fontSize == other.fontSize &&
          lineHeight == other.lineHeight &&
          viewportWidth == other.viewportWidth &&
          viewportHeight == other.viewportHeight;

  @override
  int get hashCode => Object.hash(
        scrollOffset,
        fontSize,
        lineHeight,
        viewportWidth,
        viewportHeight,
      );

  @override
  String toString() =>
      'LocalLayoutHint(offset: ${scrollOffset.toStringAsFixed(1)}, '
      'font: $fontSize, line: $lineHeight, '
      'viewport: ${viewportWidth.toStringAsFixed(1)}x'
      '${viewportHeight.toStringAsFixed(1)})';
}

/// 一本书的阅读进度快照（不可变）。
class ReadingProgress {
  ReadingProgress({
    required this.bookId,
    required this.chapterHref,
    required this.chapterIndex,
    required double chapterPos,
    required this.updatedAt,
    this.localHint,
  }) : chapterPos = chapterPos.clamp(0.0, 1.0).toDouble();

  /// 归属书籍（`BookRecord.bookId`）——也是进度文件的文件名。
  final String bookId;

  /// 章内**稳定身份**（`Chapter.href`）——恢复定位的首选键。
  final String chapterHref;

  /// 章节索引（与 `chapters()` 同序）；仅作 href 匹配不到时的回退提示。
  final int chapterIndex;

  /// 章内进度 `0.0 ~ 1.0`（构造时自动 clamp）。
  final double chapterPos;

  /// 更新时间戳（Unix 毫秒）。
  final int updatedAt;

  /// 设备本地版面快照（**不参与跨设备同步**；缺失时为 `null`）。
  final LocalLayoutHint? localHint;

  /// 序列化为 JSON Map。`localHint` 缺失时不写入该键。
  Map<String, Object?> toJson() => <String, Object?>{
        'bookId': bookId,
        'chapterHref': chapterHref,
        'chapterIndex': chapterIndex,
        'chapterPos': chapterPos,
        'updatedAt': updatedAt,
        if (localHint != null) 'localHint': localHint!.toJson(),
      };

  /// 防御式反序列化。
  ///
  /// 非 `Map`、必填字段缺失或类型错误 → 返回 `null`（进度文件损坏时**静默丢弃**）。
  /// 数值字段用 `num` 兜底；[chapterPos] 越界自动 clamp；[localHint] 非法则置 `null`。
  static ReadingProgress? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? bookId = json['bookId'];
    final Object? chapterHref = json['chapterHref'];
    final Object? chapterIndex = json['chapterIndex'];
    final Object? chapterPos = json['chapterPos'];
    final Object? updatedAt = json['updatedAt'];

    if (bookId is! String ||
        chapterHref is! String ||
        chapterIndex is! num ||
        chapterPos is! num ||
        updatedAt is! num) {
      return null;
    }

    return ReadingProgress(
      bookId: bookId,
      chapterHref: chapterHref,
      chapterIndex: chapterIndex.toInt(),
      chapterPos: chapterPos.toDouble(),
      updatedAt: updatedAt.toInt(),
      localHint: LocalLayoutHint.fromJson(json['localHint']),
    );
  }

  /// 生成一份新副本。
  ///
  /// 语义字段与 [localHint] 各取「传入值 ?? 原值」（`null` 表示不改该字段）。
  ReadingProgress copyWith({
    String? chapterHref,
    int? chapterIndex,
    double? chapterPos,
    int? updatedAt,
    LocalLayoutHint? localHint,
  }) {
    return ReadingProgress(
      bookId: bookId,
      chapterHref: chapterHref ?? this.chapterHref,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterPos: chapterPos ?? this.chapterPos,
      updatedAt: updatedAt ?? this.updatedAt,
      localHint: localHint ?? this.localHint,
    );
  }

  /// **仅语义字段**是否等价（忽略 [localHint]）——`SYNC-02` 跨设备比对用。
  bool hasSameSemantics(ReadingProgress other) =>
      bookId == other.bookId &&
      chapterHref == other.chapterHref &&
      chapterIndex == other.chapterIndex &&
      (chapterPos - other.chapterPos).abs() <= 1e-6;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReadingProgress &&
          runtimeType == other.runtimeType &&
          bookId == other.bookId &&
          chapterHref == other.chapterHref &&
          chapterIndex == other.chapterIndex &&
          chapterPos == other.chapterPos &&
          updatedAt == other.updatedAt &&
          localHint == other.localHint;

  @override
  int get hashCode => Object.hash(
        bookId,
        chapterHref,
        chapterIndex,
        chapterPos,
        updatedAt,
        localHint,
      );

  @override
  String toString() => 'ReadingProgress($bookId, href: $chapterHref, '
      'idx: $chapterIndex, pos: ${chapterPos.toStringAsFixed(3)}, '
      'hint: ${localHint ?? 'none'})';
}
