// M-PAGE `T06`：EPUB 结构缓存（纯层接口 + 信封序列化）。
//
// **纯 Dart 层**：不 import Flutter、不 import `dart:io`（与 `lib/format/**` 同铁律）。
// 磁盘实现在 `lib/storage/structure_cache_store.dart`（走 `AtomicFile` + `DATA-01` 的
// 原子写与损坏隔离），测试可用内存 fake 注入。
//
// 里程碑口径（M-PAGE T06）：`parseEpubStructure` 结果按
// `bookId + 文件 mtime/size` 落盘；判据命中时**跳过 isolate 派发**、直接
// `bindEpubResult` 绑定（闭包仍不跨 isolate，`PERF-01` 契约不变）——文件未变
// 重开**零解析**。章节正文磁盘缓存**不在本期**（§6 ⑤⑵ 后置）。
//
// ## 为什么是紧凑二进制而不是 JSON（2026-10-20 改，§2.107）
//
// 缓存存在的意义是「让开书变快」，但旧实现把结构编码成 **JSON 文本**：
// 真机 1152 章真实样本的缓存文件 100KB+，`jsonDecode` 要在主 isolate 上重建
// **上千个 Map / List / String 对象**——探针实测（桌面，15MB / 471 章真实书）：
// `jsonEncode` 7ms + `jsonDecode` 9ms + 逐字段验型 1ms ≈ **17ms**，而真正有用的
// 工作（`bind` 5ms、`chapters` 1ms）只占零头。缓存自己成了开书的主要成本之一。
//
// 换成 `[magic][schema][varint 长度前缀的字段流]` 后，解码只是「顺序读 + 直接建对象」，
// 不产生任何中间树；同时**删掉了 `entryNames`**（见下）——它是解析 isolate → 绑定
// 之间的一次性传输品，绑定侧 `bindEpubResult` 本来就会重扫 zip 重建同一张表，
// 落盘/读回都是纯冗余（真实样本里占缓存体积的 1/3）。
import 'dart:convert';
import 'dart:typed_data';

import '../epub/epub_parser.dart';
import '../model/chapter.dart';

/// 信封 schema 版本：结构字段 / 信封形状变化时 **+1**（旧版本文件按 miss 处理，
/// 不做迁移——缓存是加速层，miss 只是重解析一次）。
///
/// · v1：JSON 文本信封（含 `entryNames`）。
/// · v2：紧凑二进制信封（不含 `entryNames`，`_parse` 不再产出该字段）。
const int kStructureCacheSchema = 2;

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

// ---------------------------------------------------------------------------
// 信封编解码（紧凑二进制）
// ---------------------------------------------------------------------------

/// 信封魔数（`MRSC` = MReader Structure Cache）。首 4 字节不匹配即按 miss。
const List<int> _kMagic = <int>[0x4D, 0x52, 0x53, 0x43];

/// 把 [key] + [structure] 编成落盘信封（`magic` + `schema` + 判据 + 结构）。
///
/// 判据进信封：读回时逐字段比对，任一不符即 miss——**不做**「文件名即判据」，
/// 因为缓存文件按 bookId 命名，mtime/size 只能在内容里比。
///
/// 字段序（全部小端，整数走无符号 varint，字符串走 `varint 字节长 + UTF-8`）：
/// `bookId, mtimeMs, size | title, author, language, description, fileName
///  | creators[] | sections[] | toc[] | covers[] | flatTitles{}`。
Uint8List encodeStructureEnvelope(
  StructureCacheKey key,
  EpubStructure structure,
) {
  final _BlobWriter w = _BlobWriter()
    ..bytes(_kMagic)
    ..u8(kStructureCacheSchema)
    ..str(key.bookId)
    ..vu(key.mtimeMs)
    ..vu(key.size)
    ..str(structure.title)
    ..str(structure.author)
    ..str(structure.language)
    ..str(structure.description)
    ..str(structure.fileName);
  w
    ..vu(structure.creators.length)
    ..strAll(structure.creators)
    ..vu(structure.sections.length);
  for (final EpubSectionRef s in structure.sections) {
    w
      ..str(s.id)
      ..str(s.href)
      ..u8(s.linear ? 1 : 0);
  }
  w.vu(structure.toc.length);
  for (final Chapter c in structure.toc) {
    w
      ..str(c.href)
      ..str(c.title)
      ..vu(c.level)
      ..str(c.locate);
  }
  w.vu(structure.coverCandidates.length);
  for (final CoverCandidate c in structure.coverCandidates) {
    w
      ..str(c.href)
      ..str(c.source);
  }
  w.vu(structure.flatTitles.length);
  structure.flatTitles.forEach((String k, String v) {
    w
      ..str(k)
      ..str(v);
  });
  return w.take();
}

/// 信封解码结果的性质（供磁盘层决定「要不要把文件隔离成 `.corrupt`」）。
///
/// **为什么需要区分**：判据失效（副本被替换 / 缓存版本升级）是**正常**的，
/// 每次都把文件轮转成 `.corrupt` 只会在磁盘上堆垃圾；而「magic / schema 都对、
/// 字节流却读不下去」才是真损坏，按 `DATA-01` ② 必须隔离留证。
enum StructureDecodeStatus {
  /// 命中：判据全等且结构完整。
  hit,

  /// 判据不符（`bookId` / `mtime` / `size` 任一不同）——正常失效，不是损坏。
  keyMismatch,

  /// 字节流损坏（magic / schema 不符、越界、非法 UTF-8、尾部污染）。
  corrupted,
}

/// 带状态的信封解码结果。
class StructureDecodeResult {
  const StructureDecodeResult(this.status, [this.structure]);

  final StructureDecodeStatus status;
  final EpubStructure? structure;

  bool get isHit => status == StructureDecodeStatus.hit && structure != null;
}

/// 解信封：返回「结构 + 状态」（磁盘层据此决定是否隔离损坏文件）。
///
/// 防御式读取：任何越界、UTF-8 非法、尾部多余字节都判 corrupted——宁可重解析也不赌。
/// **先解析完再比判据**：这样「判据不符」与「字节损坏」可以区分（见
/// [StructureDecodeStatus]），而判据不符的正常失效不会污染磁盘。
StructureDecodeResult decodeStructureEnvelopeDetailed(
  Uint8List? blob, {
  required StructureCacheKey key,
}) {
  if (blob == null || blob.length < _kMagic.length + 1) {
    return const StructureDecodeResult(StructureDecodeStatus.corrupted);
  }
  for (int i = 0; i < _kMagic.length; i++) {
    if (blob[i] != _kMagic[i]) {
      return const StructureDecodeResult(StructureDecodeStatus.corrupted);
    }
  }
  try {
    final _BlobReader r = _BlobReader(blob, _kMagic.length);
    if (r.u8() != kStructureCacheSchema) {
      // schema 升级：旧文件按 miss 处理（不迁移、不算损坏——由调用方删旧文件）。
      return const StructureDecodeResult(StructureDecodeStatus.keyMismatch);
    }
    final String bookId = r.str();
    final int mtimeMs = r.vu();
    final int size = r.vu();

    final String title = r.str();
    final String author = r.str();
    final String language = r.str();
    final String description = r.str();
    final String fileName = r.str();

    final int creatorCount = r.count();
    final List<String> creators = <String>[
      for (int i = 0; i < creatorCount; i++) r.str(),
    ];

    final int sectionCount = r.count();
    final List<EpubSectionRef> sections = <EpubSectionRef>[
      for (int i = 0; i < sectionCount; i++)
        EpubSectionRef(id: r.str(), href: r.str(), linear: r.u8() != 0),
    ];

    final int tocCount = r.count();
    final List<Chapter> toc = <Chapter>[
      for (int i = 0; i < tocCount; i++)
        Chapter(
          href: r.str(),
          title: r.str(),
          level: r.vu(),
          locate: r.str(),
        ),
    ];

    final int coverCount = r.count();
    final List<CoverCandidate> covers = <CoverCandidate>[
      for (int i = 0; i < coverCount; i++)
        CoverCandidate(href: r.str(), source: r.str()),
    ];

    final int flatCount = r.count();
    final Map<String, String> flatTitles = <String, String>{};
    for (int i = 0; i < flatCount; i++) {
      flatTitles[r.str()] = r.str();
    }
    // 结构完整性：读完必须正好到底（截断 / 尾部污染都算损坏）。
    if (!r.atEnd) {
      return const StructureDecodeResult(StructureDecodeStatus.corrupted);
    }
    // 判据比对放在解析之后：此时才能确定「文件是完好的，只是不再适用」。
    if (bookId != key.bookId || mtimeMs != key.mtimeMs || size != key.size) {
      return const StructureDecodeResult(StructureDecodeStatus.keyMismatch);
    }

    return StructureDecodeResult(
      StructureDecodeStatus.hit,
      EpubStructure(
        title: title,
        author: author,
        language: language,
        description: description,
        creators: creators,
        fileName: fileName,
        sections: sections,
        toc: toc,
        coverCandidates: covers,
        flatTitles: flatTitles,
      ),
    );
  } catch (_) {
    // 越界 / 非法 UTF-8 / 长度爆炸：一律当损坏。
    return const StructureDecodeResult(StructureDecodeStatus.corrupted);
  }
}

/// 解信封（简化口径）：只要结构，不区分「判据不符」与「损坏」。
EpubStructure? decodeStructureEnvelope(
  Uint8List? blob, {
  required StructureCacheKey key,
}) =>
    decodeStructureEnvelopeDetailed(blob, key: key).structure;


// ---------------------------------------------------------------------------
// 字节流读写器
// ---------------------------------------------------------------------------

/// 无符号 varint（LEB128）上限：8 组 × 7 bit = 56 bit，足够 `mtimeMs`（epoch 毫秒
/// 约 2^41）与文件字节数；超了就是脏数据（外层按损坏处理）。
///
/// ⚠️ 这里**必须是 8 而不是 5**：5 组只有 35 bit，装不下 2026 年的 epoch 毫秒
/// （1759300000000 ≈ 2^40.7），会把每一份合法缓存都判成损坏。
const int _kMaxVarintBytes = 8;

/// 单个字符串上限（字节）：超过视为脏数据，直接抛（外层按 miss 处理）。
const int _kMaxStringBytes = 8 * 1024 * 1024;

/// 单个集合上限：结构缓存的列表绝不会到十万级，超了就是脏数据。
const int _kMaxCount = 1000000;

class _BlobWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void u8(int v) => _out.addByte(v & 0xFF);

  void bytes(List<int> v) => _out.add(v);

  void vu(int value) {
    int v = value;
    while (v >= 0x80) {
      _out.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _out.addByte(v);
  }

  void str(String s) {
    final List<int> encoded = utf8.encode(s);
    vu(encoded.length);
    _out.add(encoded);
  }

  void strAll(List<String> list) {
    for (final String s in list) {
      str(s);
    }
  }

  Uint8List take() => _out.takeBytes();
}

class _BlobReader {
  _BlobReader(this.bytes, this.pos);

  final Uint8List bytes;
  int pos;

  bool get atEnd => pos == bytes.length;

  int u8() => bytes[pos++];

  int vu() {
    int result = 0;
    int shift = 0;
    for (int i = 0; i < _kMaxVarintBytes; i++) {
      final int b = bytes[pos++];
      result |= (b & 0x7F) << shift;
      if (b < 0x80) return result;
      shift += 7;
    }
    throw const FormatException('varint 过长');
  }

  /// 集合长度：带合法性上界，挡住「长度字段被篡改成十亿」这类恶意/损坏输入。
  int count() {
    final int n = vu();
    if (n < 0 || n > _kMaxCount) {
      throw const FormatException('集合长度非法');
    }
    return n;
  }

  String str() {
    final int len = vu();
    if (len < 0 || len > _kMaxStringBytes) {
      throw const FormatException('字符串长度非法');
    }
    final int end = pos + len;
    if (end > bytes.length) {
      throw const FormatException('字符串越界');
    }
    final String s = utf8.decode(
      Uint8List.sublistView(bytes, pos, end),
      allowMalformed: false,
    );
    pos = end;
    return s;
  }
}
