// M-PAGE `T06`：EPUB 结构缓存（纯层接口 + 信封序列化）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`（与 `lib/format/**` 同铁律）。
// 磁盘实现在 `lib/storage/structure_cache_store.dart`（走 `JsonStore` + `AtomicFile`，
// 复用 `DATA-01` 的原子写与损坏回退），测试可用内存 fake 注入。
//
// 里程碑口径（`docs/里程碑-分页引擎.md` T06）：`parseEpubStructure` 结果按
// `bookId + 文件 mtime/size` 落盘；判据命中时**跳过 isolate 派发**、直接
// `bindEpubResult` 绑定（闭包仍不跨 isolate，`PERF-01` 契约不变）——文件未变
// 重开**零解析**。章节正文磁盘缓存**不在本期**（§6 ⑤⑵ 后置）。
import '../epub/epub_parser.dart';
import '../model/chapter.dart';

/// 信封 schema 版本：结构字段 / 信封形状变化时 **+1**（旧版本文件按 miss 处理，
/// 不做迁移——缓存是加速层，miss 只是重解析一次）。
const int kStructureCacheSchema = 1;

/// 缓存判据：`bookId`（内容摘要，`LIB-05`）+ 副本文件 `mtime` / `size`。
///
/// 三者全等才命中（里程碑原文判据，同 567Reader `BookExtensions.kt`）：
/// 内容变 → bookId 变；同 bookId 下副本被替换 → mtime/size 变。
class StructureCacheKey {
  const StructureCacheKey({
    required this.bookId,
    required this.mtimeMs,
    required this.size,
  });

  /// SHA-256 hex 前 16 位（`ImportService.computeBookId`）——文件名安全字符。
  final String bookId;

  /// 副本文件修改时间（epoch 毫秒）。
  final int mtimeMs;

  /// 副本文件字节数。
  final int size;

  @override
  bool operator ==(Object other) =>
      other is StructureCacheKey &&
      other.bookId == bookId &&
      other.mtimeMs == mtimeMs &&
      other.size == size;

  @override
  int get hashCode => Object.hash(bookId, mtimeMs, size);

  @override
  String toString() =>
      'StructureCacheKey($bookId, mtime=$mtimeMs, size=$size)';
}

/// 结构缓存的存储接口（纯层；实现：`FileStructureCacheStore` 与测试 fake）。
///
/// 三条操作都**不抛是常态**——但接口不强制吞错：读/写失败的兜底在
/// `DartEpubSource`（开书绝不因缓存坏掉而失败），delete 是清理语义、
/// 由实现方 best-effort。
abstract interface class StructureCacheStore {
  /// 判据命中 → 返回结构；miss / 损坏 / 判据不符 → `null`。
  Future<EpubStructure?> read(StructureCacheKey key);

  /// 写入（覆盖同 bookId 旧判据）。
  Future<void> write(StructureCacheKey key, EpubStructure structure);

  /// 删除某本书的全部缓存痕迹（连带 .bak / .corrupt；无文件 = 空操作）。
  Future<void> delete(String bookId);
}

/// 把 [key] + [structure] 编成落盘信封（`schema` + 判据 + 结构）。
///
/// 判据进信封：读回时逐字段比对，任一不符即 miss——**不做**「文件名即判据」，
/// 因为缓存文件按 bookId 命名，mtime/size 只能在内容里比。
Map<String, Object?> encodeStructureEnvelope(
  StructureCacheKey key,
  EpubStructure structure,
) =>
    <String, Object?>{
      'schema': kStructureCacheSchema,
      'bookId': key.bookId,
      'mtimeMs': key.mtimeMs,
      'size': key.size,
      'structure': _encodeStructure(structure),
    };

/// 解信封：schema / 判据不匹配或形状损坏 → `null`（当 miss，绝不抛）。
///
/// 防御式逐字段验型：任何一处类型不符整体判 miss——宁可重解析也不赌。
EpubStructure? decodeStructureEnvelope(
  Object? json, {
  required StructureCacheKey key,
}) {
  if (json is! Map) return null;
  if (json['schema'] != kStructureCacheSchema) return null;
  if (json['bookId'] != key.bookId) return null;
  if (json['mtimeMs'] != key.mtimeMs) return null;
  if (json['size'] != key.size) return null;
  return _decodeStructure(json['structure']);
}

Map<String, Object?> _encodeStructure(EpubStructure s) => <String, Object?>{
      'title': s.title,
      'author': s.author,
      'language': s.language,
      'description': s.description,
      'creators': s.creators,
      'fileName': s.fileName,
      'sections': <Map<String, Object?>>[
        for (final EpubSectionRef r in s.sections)
          <String, Object?>{'id': r.id, 'href': r.href, 'linear': r.linear},
      ],
      'toc': <Map<String, Object?>>[
        for (final Chapter c in s.toc)
          <String, Object?>{
            'href': c.href,
            'title': c.title,
            'level': c.level,
            'locate': c.locate,
          },
      ],
      'covers': <Map<String, Object?>>[
        for (final CoverCandidate c in s.coverCandidates)
          <String, Object?>{'href': c.href, 'source': c.source},
      ],
      'entryNames': s.entryNames,
      'flatTitles': s.flatTitles,
    };

EpubStructure? _decodeStructure(Object? raw) {
  if (raw is! Map) return null;

  final Object? title = raw['title'];
  final Object? author = raw['author'];
  final Object? language = raw['language'];
  final Object? description = raw['description'];
  final Object? fileName = raw['fileName'];
  if (title is! String ||
      author is! String ||
      language is! String ||
      description is! String ||
      fileName is! String) {
    return null;
  }

  final Object? creators = raw['creators'];
  if (creators is! List || creators.any((Object? e) => e is! String)) {
    return null;
  }

  final Object? sectionsRaw = raw['sections'];
  if (sectionsRaw is! List) return null;
  final List<EpubSectionRef> sections = <EpubSectionRef>[];
  for (final Object? item in sectionsRaw) {
    if (item is! Map) return null;
    final Object? id = item['id'];
    final Object? href = item['href'];
    final Object? linear = item['linear'];
    if (id is! String || href is! String || linear is! bool) return null;
    sections.add(EpubSectionRef(id: id, href: href, linear: linear));
  }

  final Object? tocRaw = raw['toc'];
  if (tocRaw is! List) return null;
  final List<Chapter> toc = <Chapter>[];
  for (final Object? item in tocRaw) {
    if (item is! Map) return null;
    final Object? href = item['href'];
    final Object? t = item['title'];
    final Object? level = item['level'];
    final Object? locate = item['locate'];
    if (href is! String ||
        t is! String ||
        level is! int ||
        locate is! String) {
      return null;
    }
    toc.add(Chapter(href: href, title: t, level: level, locate: locate));
  }

  final Object? coversRaw = raw['covers'];
  if (coversRaw is! List) return null;
  final List<CoverCandidate> covers = <CoverCandidate>[];
  for (final Object? item in coversRaw) {
    if (item is! Map) return null;
    final Object? href = item['href'];
    final Object? source = item['source'];
    if (href is! String || source is! String) return null;
    covers.add(CoverCandidate(href: href, source: source));
  }

  final Object? entryNames = raw['entryNames'];
  if (!_isStringMap(entryNames)) return null;
  final Object? flatTitles = raw['flatTitles'];
  if (!_isStringMap(flatTitles)) return null;

  return EpubStructure(
    title: title,
    author: author,
    language: language,
    description: description,
    creators: List<String>.from(creators),
    fileName: fileName,
    sections: sections,
    toc: toc,
    coverCandidates: covers,
    entryNames: Map<String, String>.from(entryNames! as Map),
    flatTitles: Map<String, String>.from(flatTitles! as Map),
  );
}

bool _isStringMap(Object? value) {
  if (value is! Map) return false;
  for (final MapEntry<Object?, Object?> e in value.entries) {
    if (e.key is! String || e.value is! String) return false;
  }
  return true;
}
