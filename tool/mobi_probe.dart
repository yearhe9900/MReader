// M2b-T05 · MOBI/AZW3 纯 Dart 原型探测基线（FMT-04 / PRD §16 Q25 最小验证）。
//
// **只做原型探测，不做正式解析器接入**。回答四件事：
//   ① PDB 容器头（name/type/creator、record 数）能否在纯 Dart 下读出；
//   ② EXTH 是否存在、关键 record（title/author/boundary/…）能否列出；
//   ③ Huff/CDIC 最小解压能否把压缩文本流解出可读开头（验证算法可行性）；
//   ④ KF8 入口结论（Q25）：KF8 结构到底是「EXTH 129/131 偏移入口」还是
//      「同文件尾部 FDST/SKEL/FRAG（INDX）结构」；入口又走哪条路
//      （mobi.version >= 8 直入 vs EXTH 121 boundary 记录号跳转重读头）。
//
// 同时输出 PRD §15.6.3 阈值 1 对照用的原型耗时：
//   · 打开口径 = 解析（record 0 [+ boundary 重读]） + Huff/CDIC 构建 + 首文本记录解压；
//   · 全书口径 = 解析 + 解压器构建 + **全部**文本记录解压（「单本解压 + 解析」的下界，
//     不含 HTML 清洗/切段——该层 PRD §15.6.4 已定保留 Dart）。
//   两者均为**开发机（Windows x64）**数字，正式判定须在 Android 主力机复测。
//
// 字段偏移与算法**直译**自 567Reader 的 Kotlin 自研实现
// （app/src/main/java/**/lib/mobi/：PDBFile / MobiReader / MobiBook /
//  HuffcdicDecompressor / Lz77Decompressor），属「移植可行性验证」而非按规范自写；
// KF8 头偏移（fdst/skel/frag/guide）以目标记录 magic（FDST/INDX）实测自校验。
//
// 用法：
//   dart run tool/mobi_probe.dart             # 自动扫 tmp_book/ 下 *.mobi *.azw3 *.azw
//   dart run tool/mobi_probe.dart <文件...>   # 指定样本
// 样本缺失时优雅降级：打印说明后正常退出（exit 0）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// 基础读数（大端；u32 按无符号语义，Dart int 足够宽）
// ---------------------------------------------------------------------------

int u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// 越界安全读（头部尾段字段可能不存在于短头），返回 [fallback]。
int u32o(Uint8List b, int o, [int fallback = -1]) =>
    (o + 4 <= b.length) ? u32(b, o) : fallback;

int clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

String asciiTrim(Uint8List b, int o, int len) {
  final List<int> chars = <int>[];
  for (int i = o; i < o + len && i < b.length; i++) {
    final int c = b[i];
    if (c == 0) break;
    chars.add(c >= 0x20 && c < 0x7f ? c : 0x2e /* . */);
  }
  return String.fromCharCodes(chars).trim();
}

String asciiPreview(Uint8List b, int o, int len) {
  final List<int> chars = <int>[];
  for (int i = o; i < o + len && i < b.length; i++) {
    final int c = b[i];
    chars.add(c >= 0x20 && c < 0x7f ? c : 0x2e);
  }
  return String.fromCharCodes(chars);
}

String hexPreview(Uint8List b, int o, int len) {
  final StringBuffer sb = StringBuffer();
  for (int i = o; i < o + len && i < b.length; i++) {
    if (i > o) sb.write(' ');
    sb.write(b[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// UTF-8 可读预览（控制字符替换为 '.'，超长截断且不截断代理对）。
String utf8Preview(Uint8List b, int o, int len) {
  final String s =
      const Utf8Codec(allowMalformed: true).decode(b.sublist(o, o + len));
  final String cleaned =
      s.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '.');
  if (cleaned.length <= 64) return cleaned;
  int cut = 64;
  final int cu = cleaned.codeUnitAt(cut - 1);
  if (cu >= 0xd800 && cu <= 0xdbff) cut = cut - 1; // 避免截断代理对
  return '${cleaned.substring(0, cut)}…';
}

String decodeText(Uint8List b, int o, int len, int encoding) {
  final Uint8List slice = b.sublist(o, o + len);
  // 65001 = UTF-8；1252 = windows-1252（此处用 latin1 近似，探测用途足够）。
  return encoding == 1252
      ? String.fromCharCodes(slice)
      : const Utf8Codec(allowMalformed: true).decode(slice);
}

String compressionName(int c) {
  switch (c) {
    case 1:
      return 'none';
    case 2:
      return 'PalmDOC-LZ77';
    case 17480:
      return 'HUFF/CDIC';
    default:
      return 'unknown';
  }
}

// ---------------------------------------------------------------------------
// 1) PDB 容器（直译 PDBFile.kt）
// ---------------------------------------------------------------------------

class PdbContainer {
  PdbContainer(this.bytes) {
    if (bytes.length < 78) {
      throw FormatException('PDB too short: ${bytes.length} bytes');
    }
    name = asciiTrim(bytes, 0, 32);
    type = asciiTrim(bytes, 60, 4);
    creator = asciiTrim(bytes, 64, 4);
    recordCount = u16(bytes, 76);
    offsets = List<int>.generate(recordCount, (int i) => u32(bytes, 78 + i * 8));
  }

  final Uint8List bytes;
  late final String name;
  late final String type;
  late final String creator;
  late final int recordCount;
  late final List<int> offsets;

  /// 记录 i 的字节切片（长度取下一条偏移之差，末条到文件尾；越界则抛出）。
  Uint8List record(int i) {
    if (i < 0 || i >= recordCount) {
      throw RangeError('record $i out of 0..${recordCount - 1}');
    }
    final int start = offsets[i];
    final int end = (i + 1 < recordCount) ? offsets[i + 1] : bytes.length;
    if (start < 0 || end > bytes.length || end < start) {
      throw FormatException('record $i bad range [$start,$end)');
    }
    return bytes.sublist(start, end);
  }

  int recordLength(int i) => record(i).length;
}

// ---------------------------------------------------------------------------
// 2) 入口头（直译 MobiReader.readMobiEntryHeaders：PalmDOC + MOBI + EXTH + KF8）
//    偏移均为「入口记录内绝对偏移」（含 16 字节 PalmDOC 头）。
// ---------------------------------------------------------------------------

class ExthEntry {
  ExthEntry(this.type, this.totalLength, this.data);
  final int type;
  final int totalLength; // 含 8 字节头
  final Uint8List data;
}

class EntryHeaders {
  EntryHeaders(Uint8List rec) {
    if (rec.length < 140) {
      throw FormatException('entry record too short: ${rec.length}');
    }
    // PalmDOC（0..15）
    compression = u16(rec, 0);
    numTextRecords = u16(rec, 8);
    textRecordSize = u16(rec, 10);
    encryption = u16(rec, 12);

    // MOBI 头（"MOBI" 魔数位于 16）
    identifier = asciiTrim(rec, 16, 4);
    if (identifier != 'MOBI') {
      throw FormatException('missing MOBI header (got "$identifier")');
    }
    mobiHeaderLength = u32(rec, 20);
    mobiType = u32(rec, 24);
    encoding = u32(rec, 28);
    uid = u32(rec, 32);
    version = u32(rec, 36);
    titleOffset = u32(rec, 84);
    titleLength = u32(rec, 88);
    resourceStart = u32o(rec, 108);
    huffcdic = u32o(rec, 112);
    numHuffcdic = u32o(rec, 116);
    exthFlag = u32o(rec, 128, 0);
    trailingFlags = u32o(rec, 240, 0);
    indx = u32o(rec, 244);

    // KF8 头扩展（仅 version >= 8 时有意义，与 Kotlin readKF8Header 的条件一致；
    // 短头时越界安全读出 -1）。
    fdst = u32o(rec, 192);
    numFdst = u32o(rec, 196);
    frag = u32o(rec, 248);
    skel = u32o(rec, 252);
    guide = u32o(rec, 260);

    if (titleLength > 0 &&
        titleLength < 0x1000 &&
        titleOffset >= 0 &&
        titleOffset + titleLength <= rec.length) {
      title = decodeText(rec, titleOffset, titleLength, encoding);
    }

    // EXTH（exthFlag bit6 置位时存在，紧跟 MOBI 头）
    exthPresent = (exthFlag & 0x40) != 0;
    if (exthPresent) {
      final int off = 16 + mobiHeaderLength;
      if (off + 12 <= rec.length && asciiTrim(rec, off, 4) == 'EXTH') {
        exthCount = u32(rec, off + 8);
        int p = off + 12;
        for (int i = 0; i < exthCount && p + 8 <= rec.length; i++) {
          final int t = u32(rec, p);
          final int len = u32(rec, p + 4);
          if (len < 8 || p + len > rec.length) break;
          exth.add(ExthEntry(t, len, rec.sublist(p + 8, p + len)));
          p += len;
        }
      } else {
        exthMagicBad = true;
      }
    }
  }

  late final int compression;
  late final int numTextRecords;
  late final int textRecordSize;
  late final int encryption;
  late final String identifier;
  late final int mobiHeaderLength;
  late final int mobiType;
  late final int encoding;
  late final int uid;
  late final int version;
  late final int titleOffset;
  late final int titleLength;
  String title = '';
  late final int resourceStart;
  late final int huffcdic;
  late final int numHuffcdic;
  late final int exthFlag;
  late final int trailingFlags;
  late final int indx;
  late final int fdst;
  late final int numFdst;
  late final int frag;
  late final int skel;
  late final int guide;
  late final bool exthPresent;
  bool exthMagicBad = false;
  int exthCount = 0;
  final List<ExthEntry> exth = <ExthEntry>[];

  ExthEntry? exthOf(int type) {
    for (final ExthEntry e in exth) {
      if (e.type == type) return e;
    }
    return null;
  }
}

/// EXTH type -> 名称（取自 ExthRecordType.kt 映射 + 常见补充）。
const Map<int, String> kExthNames = <int, String>{
  100: 'author/creator',
  101: 'publisher',
  103: 'description',
  104: 'isbn',
  105: 'subject',
  106: 'published-date',
  108: 'contributor',
  109: 'rights',
  112: 'source',
  113: 'asin',
  121: 'kf8-boundary',
  122: 'fixed-layout',
  125: 'num-resources',
  126: 'original-resolution',
  127: 'zero-gutter',
  128: 'zero-margin',
  129: 'coverURI(per Kotlin map)',
  131: 'unknown-131',
  132: 'region-magnification',
  201: 'cover-offset',
  202: 'thumbnail-offset',
  204: 'creator-software',
  503: 'updated-title',
  524: 'language',
  527: 'page-progression',
};

// ---------------------------------------------------------------------------
// 3) 解压器（直译 PlainDecompressor / Lz77Decompressor / HuffcdicDecompressor）
// ---------------------------------------------------------------------------

/// 去掉文本记录尾部附加项（直译 MobiBook.removeTrailingEntries；异常输入时返回空）。
Uint8List stripTrailing(Uint8List b, int trailingFlags) {
  if (trailingFlags == 0 || b.isEmpty) return b;
  final bool multibyte = (trailingFlags & 1) != 0;
  int numTrailingEntries = 0;
  for (int t = trailingFlags >> 1; t != 0; t >>= 1) {
    if ((t & 1) != 0) numTrailingEntries++;
  }
  final int lastIndex = b.length - 1;
  int extraSize = 0;
  for (int i = 0; i < numTrailingEntries; i++) {
    int value = 0;
    final int start = clampInt(lastIndex - 4 - extraSize, 0, lastIndex);
    final int end = clampInt(lastIndex - extraSize, 0, lastIndex);
    for (int j = start; j <= end; j++) {
      final int byte = b[j];
      if ((byte & 0x80) != 0) value = 0;
      value = (value << 7) | (byte & 0x7f);
    }
    extraSize += value;
    if (extraSize >= b.length) return Uint8List(0); // 异常输入保护
  }
  if (multibyte) {
    final int idx = lastIndex - extraSize;
    if (idx < 0) return Uint8List(0);
    extraSize += (b[idx] & 3) + 1;
  }
  if (extraSize >= b.length) return Uint8List(0);
  return b.sublist(0, b.length - extraSize);
}

/// PalmDOC LZ77（直译 Lz77Decompressor.decompress，缓冲改可增长列表；
/// 重叠拷贝 `out[o++] = out[o - location]` 语义逐字节保持）。
Uint8List lz77Decompress(Uint8List data) {
  final List<int> out = <int>[];
  int i = 0;
  while (i < data.length) {
    int c = data[i++];
    if (c >= 0x01 && c <= 0x08) {
      int j = 0;
      while (j < c && i + j < data.length) {
        out.add(data[i + j]);
        j++;
      }
      i += c;
    } else if (c <= 0x7f) {
      out.add(c);
    } else if (c >= 0xc0) {
      out.add(0x20);
      out.add(c ^ 0x80);
    } else if (i < data.length) {
      c = (c << 8) | data[i++];
      final int length = (c & 0x0007) + 3;
      final int location = (c >> 3) & 0x7ff;
      if (location >= 1 && location <= out.length) {
        for (int k = 0; k < length; k++) {
          out.add(out[out.length - location]);
        }
      }
    }
  }
  return Uint8List.fromList(out);
}

class CdicEntry {
  CdicEntry(this.data, this.decompressed);
  Uint8List data;
  bool decompressed;
}

/// Huff/CDIC（直译 HuffcdicDecompressor：HUFF 码表 + CDIC 词典 + 位级解压）。
class HuffCdic {
  HuffCdic(List<Uint8List> records) {
    if (records.isEmpty) throw FormatException('no HUFF/CDIC records');
    final Uint8List huff = records.first;
    if (huff.length < 16 || asciiTrim(huff, 0, 4) != 'HUFF') {
      throw FormatException('invalid HUFF record');
    }
    offset1 = u32(huff, 8);
    offset2 = u32(huff, 12);
    table1 = List<int>.generate(256, (int i) {
      final int o = offset1 + i * 4;
      return (o + 4 <= huff.length) ? u32(huff, o) : 0;
    });
    for (int i = 1; i <= 32; i++) {
      final int o = offset2 + (i - 1) * 8;
      final int mincode = (o + 8 <= huff.length) ? u32(huff, o) : 0;
      final int maxcode = (o + 8 <= huff.length) ? u32(huff, o + 4) : 0;
      mincodeTable[i] = mincode << (32 - i);
      maxcodeTable[i] = ((maxcode + 1) << (32 - i)) - 1;
    }
    // CDIC 记录（列表第 2..N 条）
    for (int r = 1; r < records.length; r++) {
      final Uint8List rec = records[r];
      if (rec.length < 16 || asciiTrim(rec, 0, 4) != 'CDIC') {
        throw FormatException('invalid CDIC record #$r');
      }
      final int length = u32(rec, 4);
      final int numEntries = u32(rec, 8);
      final int codeLength = u32(rec, 12);
      int n = 1 << codeLength;
      final int remain = numEntries - dictionary.length;
      if (n > remain) n = remain;
      if (n < 0) n = 0;
      if (length < 0 || length + n * 2 > rec.length) {
        n = clampInt((rec.length - length) ~/ 2, 0, n);
      }
      for (int j = 0; j < n; j++) {
        final int off = u16(rec, length + j * 2);
        if (off < 0 || length + off + 2 > rec.length) break;
        final int x = u16(rec, length + off);
        final int len = x & 0x7fff;
        final bool done = (x & 0x8000) != 0;
        if (length + off + 2 + len > rec.length) break;
        dictionary.add(
            CdicEntry(rec.sublist(length + off + 2, length + off + 2 + len), done));
      }
    }
    dictCount = dictionary.length;
  }

  late final int offset1;
  late final int offset2;
  late final List<int> table1;
  final List<int> mincodeTable = List<int>.filled(33, 0);
  final List<int> maxcodeTable = List<int>.filled(33, 0);
  final List<CdicEntry> dictionary = <CdicEntry>[];
  late final int dictCount;

  /// 直译 readUIntX：最多 maxlen 字节大端拼整数，不足时高位对齐。
  static int _readUIntX(Uint8List b, int pos, int maxlen) {
    int value = 0;
    int shift = (maxlen - 1) * 8;
    int i = maxlen;
    int bytesLeft = b.length - pos;
    while (i-- > 0 && bytesLeft-- > 0) {
      value |= b[pos++] << shift;
      shift -= 8;
    }
    return value;
  }

  /// 位级解压一段压缩文本（直译 HuffcdicDecompressor.decompress）。
  Uint8List decompress(Uint8List data) {
    final List<int> bos = <int>[];
    int bitsleft = data.length * 8;
    int pos = 0;
    int x = _readUIntX(data, pos, 8);
    int bitcount = 32;
    int guard = 0;
    final int guardMax = data.length * 8 + 64;
    while (true) {
      if (++guard > guardMax) break; // 异常输入保护
      if (bitcount <= 0) {
        pos += 4;
        x = _readUIntX(data, pos, 8);
        bitcount += 32;
      }
      final int code = (x >> bitcount) & 0xffffffff;
      final int t1 = table1[code >> 24];
      int codelen = t1 & 0x1f;
      int maxcode = (((t1 >> 8) + 1) << (32 - codelen)) - 1;
      if ((t1 & 0x80) == 0) {
        while (codelen < 32 && code < mincodeTable[codelen]) {
          codelen++;
        }
        if (codelen >= 32) break; // 异常输入保护（Kotlin 版此处会越界）
        maxcode = maxcodeTable[codelen];
      }
      bitcount -= codelen;
      bitsleft -= codelen;
      if (bitsleft < 0) break;
      final int index = (maxcode - code) >> (32 - codelen);
      if (index < 0 || index >= dictionary.length) break; // 异常输入保护
      final CdicEntry entry = dictionary[index];
      if (!entry.decompressed) {
        entry.data = decompress(entry.data);
        entry.decompressed = true;
      }
      bos.addAll(entry.data);
    }
    return Uint8List.fromList(bos);
  }
}

// ---------------------------------------------------------------------------
// 4) 探测主流程
// ---------------------------------------------------------------------------

String ms(num v) => '${v.toStringAsFixed(1)} ms';

void probeFile(File file) {
  final String path = file.path;
  final int size = file.lengthSync();
  stdout.writeln('');
  stdout.writeln('======== $path ($size bytes) ========');

  // -- 读文件 --
  final Stopwatch sw = Stopwatch()..start();
  final Uint8List bytes = file.readAsBytesSync();
  sw.stop();
  final double tRead = sw.elapsedMicroseconds / 1000.0;
  stdout.writeln('[read] file -> memory: ${ms(tRead)}');

  // -- PDB 容器 --
  final PdbContainer pdb = PdbContainer(bytes);
  stdout.writeln('-- PDB container --');
  stdout.writeln('name      : "${pdb.name}"');
  stdout.writeln('type      : "${pdb.type}"  creator: "${pdb.creator}"');
  stdout.writeln('records   : ${pdb.recordCount}');
  for (int i = 0; i < pdb.recordCount && i < 3; i++) {
    stdout.writeln('record[$i]  : off=${pdb.offsets[i]} len=${pdb.recordLength(i)}');
  }
  stdout.writeln('record[last=${pdb.recordCount - 1}]: '
      'off=${pdb.offsets[pdb.recordCount - 1]} '
      'len=${pdb.recordLength(pdb.recordCount - 1)}');

  // -- 入口头（record 0）--
  final EntryHeaders e0 = EntryHeaders(pdb.record(0));
  void dumpEntry(String tag, EntryHeaders h) {
    stdout.writeln('-- entry headers ($tag) --');
    stdout.writeln('palmdoc   : compression=${h.compression}'
        ' (${compressionName(h.compression)})'
        ' numTextRecords=${h.numTextRecords}'
        ' recordSize=${h.textRecordSize}'
        ' encryption=${h.encryption}');
    stdout.writeln('mobi      : version=${h.version} type=${h.mobiType}'
        ' encoding=${h.encoding} uid=${h.uid}'
        ' headerLen=${h.mobiHeaderLength}');
    stdout.writeln('title     : "${h.title}"'
        ' (titleOffset=${h.titleOffset} titleLength=${h.titleLength})');
    stdout.writeln('structure : resourceStart(first-image,abs)=${h.resourceStart}'
        ' huffcdic(rel)=${h.huffcdic} numHuffcdic=${h.numHuffcdic}'
        ' indx(rel)=${h.indx}');
    if (h.version >= 8) {
      stdout.writeln('kf8 fields: fdst=${h.fdst} (numFdst=${h.numFdst})'
          ' frag=${h.frag} skel=${h.skel} guide=${h.guide}'
          '  [record 相对索引，基准=boundary]');
    } else {
      stdout.writeln('kf8 fields: n/a (version<8，该区扩展字段不适用)');
    }
    stdout.writeln('flags     : exthFlag=0x${h.exthFlag.toRadixString(16)}'
        ' (exth=${h.exthPresent ? "yes" : "no"})'
        ' trailingFlags=0x${h.trailingFlags.toRadixString(16)}');
    if (h.exthMagicBad) {
      stdout.writeln('exth      : FLAG SET BUT MAGIC MISMATCH');
    }
  }

  dumpEntry('record 0', e0);

  // -- EXTH 明细 --
  stdout.writeln('-- EXTH (${e0.exthPresent ? "${e0.exthCount} records" : "absent"}) --');
  for (final ExthEntry e in e0.exth) {
    final String name = kExthNames[e.type] ?? 'unknown';
    final Uint8List d = e.data;
    final String val;
    if (d.isEmpty) {
      val = '(empty)';
    } else if (d.length == 4) {
      val = 'u32=${u32(d, 0)} raw=[${hexPreview(d, 0, 4)}]';
    } else if (d.length == 8) {
      val = 'u32=(${u32(d, 0)}, ${u32(d, 4)}) raw=[${hexPreview(d, 0, 8)}]';
    } else {
      val = 'str="${asciiPreview(d, 0, clampInt(d.length, 0, 48))}"'
          ' len=${d.length}'
          ' hex=[${hexPreview(d, 0, clampInt(d.length, 0, 16))}]';
    }
    stdout.writeln('[${e.type.toString().padLeft(3)}] $name : $val');
  }
  final ExthEntry? exTitle = e0.exthOf(503);
  final ExthEntry? exAuthor = e0.exthOf(100);
  stdout.writeln('key: title(503)='
      '"${exTitle == null ? "(none)" : asciiPreview(exTitle.data, 0, clampInt(exTitle.data.length, 0, 64))}"'
      ' author(100)='
      '"${exAuthor == null ? "(none)" : asciiPreview(exAuthor.data, 0, clampInt(exAuthor.data.length, 0, 64))}"');

  // -- KF8 入口探测（Q25）--
  stdout.writeln('-- KF8 entry probe (Q25) --');
  stdout.writeln('entry A (version>=8 direct): version=${e0.version}'
      ' -> ${e0.version >= 8 ? "HIT" : "miss"}');
  EntryHeaders active = e0;
  int base = 0; // 记录基准（boundary 或 0），直译 kf8BoundaryOffset
  final ExthEntry? exBoundary = e0.exthOf(121);
  final int boundary =
      (exBoundary != null && exBoundary.data.length == 4) ? u32(exBoundary.data, 0) : -1;
  stdout.writeln('entry B (EXTH 121 boundary): boundary=$boundary');
  if (e0.version < 8 && boundary > 0 && boundary < pdb.recordCount) {
    // 与 Kotlin MobiReader 一致：仅 version < 8 时才走 boundary 跳转。
    try {
      final EntryHeaders e1 = EntryHeaders(pdb.record(boundary));
      stdout.writeln('  re-read record $boundary: version=${e1.version}'
          ' fdst=${e1.fdst} frag=${e1.frag} skel=${e1.skel}'
          ' -> ${e1.version >= 8 ? "KF8 head OK" : "head read OK (version<8)"}');
      if (e1.version >= 8) {
        base = boundary;
        active = e1;
        stdout.writeln('  -> combo file: KF6 head at record 0 + KF8 head at boundary $boundary');
      }
    } catch (err) {
      stdout.writeln('  re-read FAILED: $err (-> fall back KF6)');
    }
  } else if (e0.version >= 8 && boundary > 0) {
    stdout.writeln('  (skipped: version>=8 already direct; boundary=$boundary unused)');
  } else if (boundary == -1) {
    stdout.writeln('  (EXTH 121 absent or -1 -> not a combo file)');
  } else {
    stdout.writeln('  (boundary=$boundary out of range 0..${pdb.recordCount - 1})');
  }
  stdout.writeln('active entry: ${identical(active, e0) ? "record 0" : "record $base (boundary)"}'
      ' version=${active.version}');

  void probeIndexRecord(String label, int relIndex) {
    if (relIndex < 0) {
      stdout.writeln('$label: (absent)');
      return;
    }
    final int abs = base + relIndex;
    if (abs >= pdb.recordCount) {
      stdout.writeln('$label: index=$relIndex (abs=$abs) OUT OF RANGE'
          ' (recordCount=${pdb.recordCount})');
      return;
    }
    final Uint8List rec = pdb.record(abs);
    final String magic = rec.length >= 4 ? asciiTrim(rec, 0, 4) : '?';
    final String tail = abs >= pdb.recordCount - 200 ? ' [file tail]' : '';
    if (magic == 'FDST') {
      final int numEntries = rec.length >= 12 ? u32(rec, 8) : 0;
      stdout.writeln('$label: index=$relIndex (abs=$abs)$tail magic=FDST'
          ' numEntries=$numEntries');
      for (int i = 0; i < numEntries && i < 3; i++) {
        final int o = 12 + i * 8;
        if (o + 8 > rec.length) break;
        stdout.writeln('  fdst[$i]: start=${u32(rec, o)} end=${u32(rec, o + 4)}');
      }
      if (numEntries > 3 && 12 + (numEntries - 1) * 8 + 8 <= rec.length) {
        final int o = 12 + (numEntries - 1) * 8;
        stdout.writeln('  fdst[last]: start=${u32(rec, o)} end=${u32(rec, o + 4)}');
      }
    } else if (magic == 'INDX') {
      final int hdrLen = rec.length >= 8 ? u32(rec, 4) : 0;
      final int idxt = rec.length >= 24 ? u32(rec, 20) : 0;
      final int numRecords = rec.length >= 28 ? u32(rec, 24) : 0;
      final int total = rec.length >= 40 ? u32(rec, 36) : 0;
      final String tagx =
          (hdrLen + 4 <= rec.length && hdrLen >= 0) ? asciiTrim(rec, hdrLen, 4) : '?';
      final String idxtMagic =
          (idxt + 4 <= rec.length && idxt >= 0) ? asciiTrim(rec, idxt, 4) : '?';
      stdout.writeln('$label: index=$relIndex (abs=$abs)$tail magic=INDX'
          ' hdrLen=$hdrLen type=${rec.length >= 12 ? u32(rec, 8) : 0}'
          ' numRecordsField=$numRecords totalEntries=$total');
      stdout.writeln('  tagx="$tagx" idxt="$idxtMagic"');
    } else {
      stdout.writeln('$label: index=$relIndex (abs=$abs)$tail magic="$magic"'
          ' head=[${hexPreview(rec, 0, clampInt(rec.length, 0, 12))}]');
    }
  }

  if (active.version >= 8) {
    probeIndexRecord('FDST', active.fdst);
    probeIndexRecord('SKEL', active.skel);
    probeIndexRecord('FRAG', active.frag);
    probeIndexRecord('GUIDE', active.guide);
  } else {
    stdout.writeln('FDST/SKEL/FRAG/GUIDE: n/a (KF6 head 无此扩展)');
  }
  stdout.writeln('resources : first-image-index(abs)=${active.resourceStart}'
      ' -> 资源记录区间约 [${active.resourceStart}, ${pdb.recordCount})'
      '（同文件尾部 PDB records）');

  // EXTH 129/131「偏移入口说」实测
  for (final int t in const <int>[129, 131]) {
    final ExthEntry? e = active.exthOf(t) ?? e0.exthOf(t);
    if (e == null) {
      stdout.writeln('EXTH $t   : ABSENT -> 「偏移入口」不成立（无此 record）');
      continue;
    }
    final Uint8List d = e.data;
    stdout.writeln('EXTH $t   : len=${d.length}'
        ' hex=[${hexPreview(d, 0, clampInt(d.length, 0, 32))}]'
        ' ascii="${asciiPreview(d, 0, clampInt(d.length, 0, 48))}"');
    if (d.length == 4) {
      final int v = u32(d, 0);
      stdout.writeln('  as u32=$v (recordCount=${pdb.recordCount},'
          ' textRecords=${active.numTextRecords})');
      final int abs = base + v;
      if (abs >= 0 && abs < pdb.recordCount) {
        final Uint8List rec = pdb.record(abs);
        stdout.writeln('  as record index (base+$v=abs $abs): '
            'head=[${hexPreview(rec, 0, clampInt(rec.length, 0, 12))}] '
            'magic="${rec.length >= 4 ? asciiTrim(rec, 0, 4) : '?'}"');
      } else {
        stdout.writeln('  as record index: OUT OF RANGE');
      }
      stdout.writeln('  verdict: 单个 u32；'
          '${abs >= 0 && abs < pdb.recordCount ? "可当 record 索引但无 FDST/SKEL/FRAG 魔数佐证" : "连 record 索引都对不上"}');
    } else if (d.isNotEmpty && d.first == 0x6b /* 'k' */) {
      stdout.writeln('  verdict: 字符串（kindle:… URI），非偏移入口');
    } else {
      stdout.writeln('  verdict: ${d.isEmpty ? "空" : "非 4 字节值，"}非记录偏移入口形态');
    }
  }

  // 结论行（供基线文档直接引用）
  bool structureOk = false;
  if (active.version >= 8 && base + active.fdst >= 0 && base + active.fdst < pdb.recordCount) {
    final Uint8List rec = pdb.record(base + active.fdst);
    structureOk = rec.length >= 4 && asciiTrim(rec, 0, 4) == 'FDST';
  }
  final String entryVerdict = base > 0
      ? 'EXTH 121 boundary @$base (re-read head)'
      : (e0.version >= 8 ? 'version>=8 direct' : 'KF6 only (no KF8)');
  stdout.writeln('VERDICT   : KF8 structure = '
      '${structureOk ? "same-file trailing FDST/SKEL/FRAG (INDX) records" : "NOT CONFIRMED (KF6 或未检出)"}; '
      'entry = $entryVerdict; '
      'EXTH 129/131 offset-entry hypothesis = NOT SUPPORTED');

  // -- 解压器构建 + 试解（Huff/CDIC 最小解压）--
  stdout.writeln('-- decompression trial --');
  HuffCdic? huff;
  final Stopwatch swBuild = Stopwatch()..start();
  if (active.compression == 17480) {
    final List<Uint8List> recs = <Uint8List>[];
    for (int i = 0; i < active.numHuffcdic; i++) {
      recs.add(pdb.record(base + active.huffcdic + i));
    }
    huff = HuffCdic(recs);
  }
  swBuild.stop();
  final double tBuild = swBuild.elapsedMicroseconds / 1000.0;
  if (huff != null) {
    stdout.writeln('huff build: ${ms(tBuild)} (HUFF offset1=${huff.offset1}'
        ' offset2=${huff.offset2} dictEntries=${huff.dictCount}'
        ' cdicRecords=${active.numHuffcdic})');
  } else {
    stdout.writeln('huff build: skipped (compression=${active.compression}'
        ' ${compressionName(active.compression)})');
  }

  Uint8List decompressTextRecord(int i) {
    final Uint8List raw = pdb.record(base + 1 + i);
    final Uint8List trimmed = stripTrailing(raw, active.trailingFlags);
    switch (active.compression) {
      case 1:
        return trimmed;
      case 2:
        return lz77Decompress(trimmed);
      case 17480:
        return huff!.decompress(trimmed);
      default:
        throw FormatException('unknown compression ${active.compression}');
    }
  }

  // 首个文本记录试解（算法可行性证据）
  if (active.numTextRecords > 0) {
    final Stopwatch swTrial = Stopwatch()..start();
    final Uint8List first = decompressTextRecord(0);
    swTrial.stop();
    stdout.writeln('trial     : textRecord[0] '
        '${pdb.recordLength(base + 1)}B -> ${first.length}B'
        ' in ${ms(swTrial.elapsedMicroseconds / 1000.0)}');
    stdout.writeln('head      : "${asciiPreview(first, 0, clampInt(first.length, 0, 200))}"');
  } else {
    stdout.writeln('trial     : no text records');
  }

  // -- 耗时（PRD §15.6.3 阈值 1 对照口径，3 轮取 min/median/max）--
  stdout.writeln('-- timing x3 (threshold-1 baseline) --');
  final List<double> openTimes = <double>[];
  final List<double> fullTimes = <double>[];
  int decompressedTotal = 0;
  for (int iter = 0; iter < 3; iter++) {
    // 打开口径：record 0 解析（+ combo boundary 重读）+ 解压器构建 + 首文本记录解压。
    Stopwatch sw2 = Stopwatch()..start();
    EntryHeaders h = EntryHeaders(pdb.record(0));
    if (base > 0) {
      h = EntryHeaders(pdb.record(base)); // boundary 重读头
    }
    HuffCdic? hh;
    if (h.compression == 17480) {
      final List<Uint8List> recs = <Uint8List>[];
      for (int i = 0; i < h.numHuffcdic; i++) {
        recs.add(pdb.record(base + h.huffcdic + i));
      }
      hh = HuffCdic(recs);
    }
    if (h.numTextRecords > 0) {
      final Uint8List raw = stripTrailing(pdb.record(base + 1), h.trailingFlags);
      if (h.compression == 17480) {
        hh!.decompress(raw);
      } else if (h.compression == 2) {
        lz77Decompress(raw);
      }
    }
    sw2.stop();
    openTimes.add(sw2.elapsedMicroseconds / 1000.0);

    // 全书口径：全部文本记录解压（不含 HTML 清洗/切段）。
    sw2 = Stopwatch()..start();
    int total = 0;
    for (int i = 0; i < active.numTextRecords; i++) {
      total += decompressTextRecord(i).length;
    }
    sw2.stop();
    fullTimes.add(sw2.elapsedMicroseconds / 1000.0);
    decompressedTotal = total;
  }
  openTimes.sort();
  fullTimes.sort();
  final double tOpen = openTimes[1]; // median
  final double tFull = fullTimes[1];
  stdout.writeln('open      : parse+build+firstRecord'
      ' min=${ms(openTimes.first)} median=${ms(tOpen)} max=${ms(openTimes.last)}');
  stdout.writeln('open(w/ read): ${ms(tRead + tOpen)}'
      '  <- 对照「打开 20MB AZW3 > 3s」（下界：不含 HTML 解析/排版）');
  stdout.writeln('full      : parse+build+allRecords(${active.numTextRecords})'
      ' -> ${decompressedTotal}B decompressed'
      ' min=${ms(fullTimes.first)} median=${ms(tFull)} max=${ms(fullTimes.last)}');
  stdout.writeln('full(w/ read): ${ms(tRead + tFull)}'
      '  <- 对照「单本解压 + 解析 > 2s」（下界：不含 HTML 清洗/切段）');
}

void main(List<String> args) {
  stdout.encoding = utf8;
  final List<File> files = <File>[];
  if (args.isNotEmpty) {
    for (final String a in args) {
      final File f = File(a);
      if (f.existsSync()) {
        files.add(f);
      } else {
        stdout.writeln('skip: not found: $a');
      }
    }
  } else {
    final Directory dir = Directory('tmp_book');
    if (dir.existsSync()) {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final String lower = e.path.toLowerCase();
        if (lower.endsWith('.mobi') ||
            lower.endsWith('.azw3') ||
            lower.endsWith('.azw')) {
          files.add(e);
        }
      }
      files.sort((File a, File b) => a.path.compareTo(b.path));
    }
  }

  stdout.writeln('== MReader MOBI/AZW3 probe (M2b-T05 prototype baseline) ==');
  if (files.isEmpty) {
    // 优雅降级：样本缺失不是错误，但要明确说明。
    stdout.writeln('NO SAMPLES: expected tmp_book/*.mobi|*.azw3|*.azw'
        '（或以文件路径作参数）。');
    stdout.writeln('probe skipped gracefully —— 无样本不构成失败，基线数字待补测。');
    return;
  }
  stdout.writeln('samples: ${files.length}');

  for (final File f in files) {
    try {
      probeFile(f);
    } catch (err) {
      stdout.writeln('');
      stdout.writeln('======== ${f.path} ========');
      stdout.writeln('PROBE FAILED: $err');
    }
  }
}
