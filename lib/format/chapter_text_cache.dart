// 章正文磁盘缓存（EPUB + TXT 共用）：已抽取好的**段落列表**按章落盘。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`（与 `lib/format/**` 同铁律）。
// 磁盘实现在 `lib/storage/chapter_text_cache_store.dart`（追加式 blob + 索引信封），
// 测试可用内存 fake 注入。
//
// ## 消掉的是哪一段（2026-10-09 批次）
//
// · EPUB：`content(i)` 的「inflate 包内条目 + `extractSection` HTML 解析」；
// · TXT：`content(i)` 的「整本解码后的 `substring` + 切段 + 标题剥除」。
//
// 缓存的是**最终段落**（含 EPUB 的 NUL 包裹锚点标记、TXT 已剥重复标题），
// 读路径与现场计算逐字相同——`content()` 返回什么，缓存里就是什么。
//
// ## 与 `StructureCache` / `TxtOutlineCache` 的同族口径
//
// 同一判据 [StructureCacheKey]（bookId + 副本 mtime/size）、同一失败语义
// （损坏 / 判据不符 → 按 miss，绝不抛）。索引信封在本文件编解码（结构语义），
// 落盘 IO 在实现层——与 `structure_cache.dart` / `txt_outline_cache.dart` 同分工。
//
// ## 空段落表也缓存
//
// 「该章就是没正文」是稳定事实（内容决定，判据已钉死文件身份）⇒ 空表照写照读；
// 但**竞态 / 已释放**产生的空结果绝不可写回（消费方各自把关，见两源 `content()`）。
import 'dart:convert';

import 'structure_cache.dart';

/// 信封 schema 版本：负载形状变化时 **+1**（旧版本按 miss 处理，不迁移）。
const int kChapterTextCacheSchema = 1;

/// 一章在 blob 里的字节区间（`[start, end)`，blob = 各章负载的顺序拼接）。
class ChapterTextSpan {
  const ChapterTextSpan({
    required this.chapterIndex,
    required this.start,
    required this.end,
  });

  /// 章序号（`BookSource.content(i)` 的 `i`；书内稳定，由判据钉死文件身份）。
  final int chapterIndex;

  /// 负载起始字节偏移（含）。
  final int start;

  /// 负载结束字节偏移（不含）。
  final int end;

  @override
  bool operator ==(Object other) =>
      other is ChapterTextSpan &&
      other.chapterIndex == chapterIndex &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(chapterIndex, start, end);

  @override
  String toString() => 'ChapterTextSpan(#$chapterIndex $start..$end)';
}

/// 章正文缓存的存储接口（纯层；实现：`FileChapterTextCacheStore` 与测试 fake）。
///
/// 三条操作都不抛是常态——但接口不强制吞错：读写失败的兜底在两个源的
/// `content()`（写回 best-effort、读失败当 miss），delete 是清理语义。
abstract interface class ChapterTextCacheStore {
  /// 判据命中且该章已缓存 → 段落列表；miss / 损坏 / 判据不符 → `null`。
  Future<List<String>?> read(StructureCacheKey key, int chapterIndex);

  /// 写入一章（覆盖同章旧条目）。
  Future<void> write(
    StructureCacheKey key,
    int chapterIndex,
    List<String> paragraphs,
  );

  /// 删除某本书的全部缓存痕迹（blob + 索引 + 轮转残留；无文件 = 空操作）。
  Future<void> delete(String bookId);
}

/// 把 [key] + 章区间表编成索引信封（`schema` + 判据 + `spans`）。
Map<String, Object?> encodeChapterTextIndex(
  StructureCacheKey key,
  List<ChapterTextSpan> spans,
) =>
    <String, Object?>{
      'schema': kChapterTextCacheSchema,
      'bookId': key.bookId,
      'mtimeMs': key.mtimeMs,
      'size': key.size,
      'spans': <Map<String, Object?>>[
        for (final ChapterTextSpan s in spans)
          <String, Object?>{
            'i': s.chapterIndex,
            'start': s.start,
            'end': s.end,
          },
      ],
    };

/// 解索引信封：schema / 判据不匹配或形状损坏 → `null`（当 miss，绝不抛）。
List<ChapterTextSpan>? decodeChapterTextIndex(
  Object? json, {
  required StructureCacheKey key,
}) {
  if (json is! Map) return null;
  if (json['schema'] != kChapterTextCacheSchema) return null;
  if (json['bookId'] != key.bookId) return null;
  if (json['mtimeMs'] != key.mtimeMs) return null;
  if (json['size'] != key.size) return null;

  final Object? spansRaw = json['spans'];
  if (spansRaw is! List) return null;
  final List<ChapterTextSpan> spans = <ChapterTextSpan>[];
  for (final Object? item in spansRaw) {
    if (item is! Map) return null;
    final Object? i = item['i'];
    final Object? start = item['start'];
    final Object? end = item['end'];
    if (i is! int || start is! int || end is! int) return null;
    if (i < 0 || start < 0 || end < start) return null;
    spans.add(ChapterTextSpan(chapterIndex: i, start: start, end: end));
  }
  return spans;
}

/// 章负载编解码：段落表 ⇄ UTF-8 JSON 数组。
///
/// 选 JSON 而非自定义分隔符：段落里可能含任意 Unicode（含换行、NUL 包裹锚点
/// 标记），JSON 无转义歧义，且单章体量小（最大章 ~100K 字 ⇒ ~200KB），解析可忽略。
List<int> encodeChapterTextPayload(List<String> paragraphs) =>
    utf8.encode(jsonEncode(paragraphs));

/// 解章负载；形状不符（非 JSON 数组 / 元素非字符串）→ `null`（当 miss）。
List<String>? decodeChapterTextPayload(List<int> bytes) {
  final Object? raw;
  try {
    raw = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return null;
  }
  if (raw is! List) return null;
  final List<String> out = <String>[];
  for (final Object? item in raw) {
    if (item is! String) return null;
    out.add(item);
  }
  return out;
}
