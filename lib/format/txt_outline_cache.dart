// 开书大纲缓存（TXT 版）：`TxtOutline`（编码 + 章表）按判据落盘。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`（与 `lib/format/**` 同铁律）。
// 磁盘实现在 `lib/storage/txt_outline_cache_store.dart`（走 `JsonStore` + `AtomicFile`，
// 复用 `DATA-01` 的原子写与损坏回退），测试可用内存 fake 注入。
//
// ## 为什么 TXT 需要这份缓存（2026-10-09 批次，与 EPUB 侧 T06 同族）
//
// EPUB 有 `StructureCache`（M-PAGE `T06`）：命中零解析。TXT 此前**一步不少**——
// 每次开书都整本解码（GBK 逐字节查表）+ 全文正则分章 + 把整份字符串跨 isolate
// 运回（20MB 书 = 再拷几十 MB）。本缓存把这三段整段跳过：
// 命中 ⇒ `_txtPrepareTask` 不派发，章节表直接由落盘大纲还原。
//
// ## 与 T06 结构缓存的同族口径
//
// · **同一判据** [StructureCacheKey]（`bookId` + 副本 `mtime/size`）；
// · **同一信封形状**（`schema` + 判据 + 载荷），判据逐字段比对、任一不符即 miss；
// · **同一失败语义**：损坏 / schema 不符 / 判据不符 → 按 miss 处理、绝不抛
//   （缓存是加速层，miss 只是重算一次；开书绝不因缓存坏掉而失败）。
//
// 「每本书的 outline」这一概念由两份实现共同承担：EPUB = `EpubStructure`
// （`structure_cache.dart`），TXT = [TxtOutline]（本文件）。判据与信封约定共用，
// 载荷各随格式。
import 'structure_cache.dart';

/// 信封 schema 版本：载荷字段 / 信封形状变化时 **+1**（旧版本文件按 miss 处理，
/// 不做迁移——缓存是加速层，miss 只是重解析一次）。
const int kTxtOutlineCacheSchema = 1;

/// 一章的字符区间与章名（与 `DartTxtSource` 内部分段同口径：`start`/`end` 均为
/// **字符**偏移，正文取 `text.substring(start, end)`；`Chapter.href = 'txt:<start>'`）。
class TxtChapterSpan {
  const TxtChapterSpan({
    required this.start,
    required this.end,
    required this.title,
  });

  /// 章正文起始字符偏移（含标题行之后，与分章结果一致）。
  final int start;

  /// 章正文结束字符偏移（不含）。
  final int end;

  /// 章名（已 trim；与 `Chapter.title` 逐字相同）。
  final String title;

  @override
  bool operator ==(Object other) =>
      other is TxtChapterSpan &&
      other.start == start &&
      other.end == end &&
      other.title == title;

  @override
  int get hashCode => Object.hash(start, end, title);

  @override
  String toString() => 'TxtChapterSpan($start..$end, $title)';
}

/// TXT 大纲：解码结论 + 章表。
///
/// [encoding] = `detectEncodingName` 的**生效**编码名（`'utf-8'` / `'utf-16le'` /
/// `'utf-16be'` / `'gbk'` / `'latin1'`）——落盘它是为了让「将来按字节区间解码」
/// 有据可依（`PRD §15.6.2` 的 Rust 编码探测对齐缝也用同一口径）；当前取正文走
/// 章正文缓存 / 整本解码回落，尚未用它做按章解码。
class TxtOutline {
  const TxtOutline({required this.encoding, required this.chapters});

  /// 生效编码名（小写；见 [TxtOutline] 文档）。
  final String encoding;

  /// 章表（按阅读顺序，连续切分全书）。
  final List<TxtChapterSpan> chapters;
}

/// TXT 大纲缓存的存储接口（纯层；实现：`FileTxtOutlineCacheStore` 与测试 fake）。
///
/// 与 [StructureCacheStore] 同构：read 判据不符 / 损坏 → `null`（当 miss），
/// write 覆盖同 bookId 旧判据，delete 是清理语义（best-effort）。
abstract interface class TxtOutlineCacheStore {
  /// 判据命中 → 返回大纲；miss / 损坏 / 判据不符 → `null`。
  Future<TxtOutline?> read(StructureCacheKey key);

  /// 写入（覆盖同 bookId 旧判据）。
  Future<void> write(StructureCacheKey key, TxtOutline outline);

  /// 删除某本书的全部缓存痕迹（连带 .bak / .corrupt；无文件 = 空操作）。
  Future<void> delete(String bookId);
}

/// 把 [key] + [outline] 编成落盘信封（`schema` + 判据 + 载荷）。
Map<String, Object?> encodeTxtOutlineEnvelope(
  StructureCacheKey key,
  TxtOutline outline,
) =>
    <String, Object?>{
      'schema': kTxtOutlineCacheSchema,
      'bookId': key.bookId,
      'mtimeMs': key.mtimeMs,
      'size': key.size,
      'outline': <String, Object?>{
        'encoding': outline.encoding,
        'chapters': <Map<String, Object?>>[
          for (final TxtChapterSpan c in outline.chapters)
            <String, Object?>{'start': c.start, 'end': c.end, 'title': c.title},
        ],
      },
    };

/// 解信封：schema / 判据不匹配或形状损坏 → `null`（当 miss，绝不抛）。
///
/// 防御式逐字段验型：任何一处类型不符整体判 miss——宁可重解析也不赌。
TxtOutline? decodeTxtOutlineEnvelope(
  Object? json, {
  required StructureCacheKey key,
}) {
  if (json is! Map) return null;
  if (json['schema'] != kTxtOutlineCacheSchema) return null;
  if (json['bookId'] != key.bookId) return null;
  if (json['mtimeMs'] != key.mtimeMs) return null;
  if (json['size'] != key.size) return null;

  final Object? outlineRaw = json['outline'];
  if (outlineRaw is! Map) return null;
  final Object? encoding = outlineRaw['encoding'];
  if (encoding is! String || encoding.isEmpty) return null;

  final Object? chaptersRaw = outlineRaw['chapters'];
  if (chaptersRaw is! List || chaptersRaw.isEmpty) return null;
  final List<TxtChapterSpan> chapters = <TxtChapterSpan>[];
  for (final Object? item in chaptersRaw) {
    if (item is! Map) return null;
    final Object? start = item['start'];
    final Object? end = item['end'];
    final Object? title = item['title'];
    if (start is! int || end is! int || title is! String) return null;
    if (start < 0 || end < start) return null;
    chapters.add(TxtChapterSpan(start: start, end: end, title: title));
  }
  return TxtOutline(encoding: encoding, chapters: chapters);
}
