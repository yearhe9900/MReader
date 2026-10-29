// `RD-04`：阅读进度值对象（纯 Dart，**不 import Flutter、不 import dart:io**）。
//
// 进度的**稳定身份是 [chapterHref]**；[chapterIndex] 只是 href 匹配不到时的回退提示
// （书源重排 / 目录微调时仍尽量落回同一章，而不是跳错章）。
//
// **语义字段**（`bookId` / `chapterHref` / `chapterIndex` / `chapterPos` / `updatedAt`）
// 可**跨设备同步**（`SYNC-02` 会用），不含任何像素值；[localHint] 是**设备本地版面
// 快照**，仅用于本机精确恢复，**跨设备同步时必须丢弃**（绑定当前字号 / 行距 / 视口）。
//
// 纯数据模型：可在 isolate 与单测中直接使用。落盘经 `ProgressStore`。

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
  ///
  /// **真值语义 = 字符偏移比例**（§0 定义，选型 §6 拍板②）：`chapterPos =
  /// charOffset / totalChars`。**旧几何比例值宽容读取**：`fromJson` 不做来源标记，
  /// 新旧数值同型同域一律直接采用（首帧估算够接近，随后由分页视图按 charOffset
  /// 采样回归一）；**写回时统一为字符偏移比例**（JSON 格式不变，`SYNC-02` 不动）。
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

/// 一块章块的几何 / 加载态快照（[detectChapterAt] 的输入；纯数据，便于纯 Dart 单测）。
///
/// 「章块」= 连续滚动列表里某一章对应的 item（已加载章是标题 + 正文，
/// 未加载章是估算占位块）。
class ChapterBlockSnapshot {
  const ChapterBlockSnapshot({
    required this.index,
    required this.top,
    required this.height,
    required this.reallyLoaded,
  });

  /// 章索引（与 `chapters()` 同序）。
  final int index;

  /// 章块顶相对**视口顶**的 y（逻辑像素）：`≤ 0` 表示在视口顶之上或齐平。
  final double top;

  /// 章块渲染高度（逻辑像素）。未加载章这里是**估算占位高**。
  final double height;

  /// 该章是否**真实加载**（正文已解析并渲染），而非「已加载章高度中位数」占位块。
  final bool reallyLoaded;

  /// 章块底相对视口顶的 y。
  double get bottom => top + height;
}

/// 判定「视口顶落在哪一章、章内哪个相对位置」（纯计算，不依赖 widget 树）。
///
/// 返回值语义（调用方契约，`RC3` / `RC4`）：
///   · `null` —— 一个章块都没布局，**完全无法确定**；
///   · `chapterPos == null` —— 章可知但**章内位置不可采样**（估算占位高章的分母是
///     估的，采样会把垃圾值写进 `chapterPos`，`RC3`）；
///   · `chapterPos` 为数值 —— 完整采样成功。
///
/// 前两种情况调用方**必须保持 `chapterPos` 原值、且不得写盘**（`RC3`/`RC4`：探不到就
/// 静默沿用旧章并继续保存，正是「多次进出后偏离原章节」的来源）。
///
/// 命中规则：取**真正覆盖视口顶**（`top ≤ 0.5 < bottom`）的那一块（章块互不重叠、覆盖者
/// 唯一）——不用「顶在视口顶之上里最靠下的」，那会在真章落进探测范围之外时误判成窗口
/// 边缘章（`RC4`）。无覆盖（列表顶 / 底内边距）时回落到**离视口顶最近的已真实加载**章块，
/// 章内位置取 `clamp(-top / height, 0, 1)`。
({int chapterIndex, double? chapterPos})? detectChapterAt(
  Iterable<ChapterBlockSnapshot> blocks,
) {
  final List<ChapterBlockSnapshot> all = blocks.toList(growable: false);
  if (all.isEmpty) return null;

  // ① 找真正覆盖视口顶的章块。**不看加载态**：命中占位章时若跳过它、让邻近真实章
  //    顶替，就是章级误判（`RC4`）——宁可报「位置不可采样」。
  ChapterBlockSnapshot? cover;
  for (final ChapterBlockSnapshot block in all) {
    if (block.height <= 0) continue;
    if (block.top <= 0.5 && block.bottom > 0.5) {
      if (cover == null || block.top > cover.top) {
        cover = block;
      }
    }
  }

  final ChapterBlockSnapshot chosen;
  if (cover != null) {
    if (!cover.reallyLoaded) {
      // `RC3`：占位高章**不采样 chapterPos**，等该章真正加载后再采样。
      return (chapterIndex: cover.index, chapterPos: null);
    }
    chosen = cover;
  } else {
    // ② 视口顶在列表顶 / 底内边距：回落到离视口顶最近的**已真实加载**章块。
    ChapterBlockSnapshot? nearest;
    double nearestDistance = double.infinity;
    for (final ChapterBlockSnapshot block in all) {
      if (!block.reallyLoaded || block.height <= 0) continue;
      final double distance = block.top > 0.5
          ? block.top
          : (block.bottom <= 0.5 ? 0.5 - block.bottom : 0.0);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = block;
      }
    }
    if (nearest == null) return null;
    chosen = nearest;
  }

  final double pos = (-chosen.top / chosen.height).clamp(0.0, 1.0).toDouble();
  return (chapterIndex: chosen.index, chapterPos: pos);
}

// ---------------------------------------------------------------------------
// 字符偏移比例换算 + 全书进度加权（纯函数，§0 / §6 拍板②）
// ---------------------------------------------------------------------------

/// 章内字符偏移 → `chapterPos` 比例（§0：`charOffset / totalChars`，clamp 0..1）。
///
/// [totalChars] ≤ 0（空章）时返回 `0.0`——不抛异常，空章没有可言的章内位置。
double chapterPosOfCharOffset(int charOffset, int totalChars) {
  if (totalChars <= 0) return 0.0;
  return (charOffset / totalChars).clamp(0.0, 1.0).toDouble();
}

/// `chapterPos` 比例 → 章内字符偏移（重排恢复用：记 charOffset → 重分页 →
/// 二分落位，选型 §6 保证②）。
///
/// [totalChars] ≤ 0 时返回 `0`；结果 clamp 到 `[0, totalChars]`。
int charOffsetOfChapterPos(double chapterPos, int totalChars) {
  if (totalChars <= 0) return 0;
  final int offset = (chapterPos.clamp(0.0, 1.0) * totalChars).round();
  return offset.clamp(0, totalChars);
}

/// 全书阅读进度（`0.0 ~ 1.0`）：**字数加权**（选型 §6 拍板②；不传 [chapterWeights]
/// 时退化为页数等权）。
///
/// - [chapterWeights] 有效（长度 == [chapterCount] 且 `Σ > 0`）→
///   `(Σ 前章字数 + chapterPos × 本章字数) / Σ 全书字数`；
/// - 否则（PDF 等不支持字数统计的源）→ 章节等权 `(chapterIndex + chapterPos) /
///   chapterCount`——与迁移前公式逐位一致，保证旧进度数值不突变。
///
/// 参数越界一律 clamp；`chapterCount ≤ 0` 返回 `0.0`。
double overallReadingProgress({
  required int chapterIndex,
  required double chapterPos,
  required int chapterCount,
  List<int>? chapterWeights,
}) {
  if (chapterCount <= 0) return 0.0;
  final double pos = chapterPos.clamp(0.0, 1.0).toDouble();
  final int index = chapterIndex.clamp(0, chapterCount - 1);

  if (chapterWeights != null && chapterWeights.length == chapterCount) {
    int total = 0;
    for (final int w in chapterWeights) {
      if (w > 0) total += w;
    }
    if (total > 0) {
      int before = 0;
      for (int i = 0; i < index; i++) {
        final int w = chapterWeights[i];
        if (w > 0) before += w;
      }
      final int cur = chapterWeights[index] > 0 ? chapterWeights[index] : 0;
      return ((before + pos * cur) / total).clamp(0.0, 1.0).toDouble();
    }
    // 全 0 权重（如 PDF 空文本伪章）→ 落到等权退化。
  }
  return ((index + pos) / chapterCount).clamp(0.0, 1.0).toDouble();
}
