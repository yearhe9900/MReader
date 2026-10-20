// MOBI / AZW3 容器解析 + PalmDOC 解压（**纯 Dart**：不 import Flutter / dart:io）。
//
// ## 能力边界（2026-10-20，诚实降级 `NF-C8`）
//
// | compression | 处理 |
// |---|---|
// | 0 = none | 直接取文本记录 |
// | 1 = PalmDOC | 本文件实现（`decompressPalmDoc`），真样本 `tmp_book/*.azw3` 实证 |
// | 2 = HUFF/CDIC | **抛 [FormatErrorCode.mobiHuffCdicUnsupported]**——HUFF/CDIC 的
//   码表定位与码长推导未获真样本实证，宁可不支持也不产出乱码（用户已同意挂后期：
//   该格式可由 WebView + foliate-js 通道承担，见统一方案 §5 冷格式降级通道） |
//
// 章切分按 `<mbp:pagebreak>`（foliate-js 对 MOBI 的同款做法：MOBI 正文是一整条
// HTML 流，`pagebreak` 是书内既有的分页/分章标记）。
import 'dart:convert';
import 'dart:typed_data';

import '../error_messages.dart';

/// MOBI/PalmDB 容器（解析后的只读视图；不解压、不切分——那是上层的事）。
class MobiContainer {
  MobiContainer._({
    required this.bytes,
    required this.compression,
    required this.textLength,
    required this.textRecordCount,
    required this.recordSize,
    required this.encryptionType,
    required this.textEncoding,
    required this.recordOffsets,
    required this.recordZeroOffset,
    required this.exth,
    required this.coverRecordIndex,
    required this.fullName,
  });

  /// 整本文件字节（构造时持有，与其余 `BookSource` 同一口径）。
  final Uint8List bytes;

  /// PalmDOC 压缩方式：0 无 / 1 PalmDOC / 2 HUFF-Cdic。
  final int compression;

  /// 解压后正文总长。
  final int textLength;

  /// 正文记录条数。
  final int textRecordCount;

  /// 每条记录字节数（末条可能不足）。
  final int recordSize;

  /// 加密类型；非 0 一律拒绝。
  final int encryptionType;

  /// MOBI 头的 `textEncoding`（65001 = UTF-8，1252 = CP1252，其余按 UTF-8 兜底）。
  final int textEncoding;

  /// PDB 记录偏移表（索引 0 = MOBI 头）。
  final List<int> recordOffsets;

  /// 记录 0 的文件偏移。
  final int recordZeroOffset;

  /// EXTH 字段（type → 字符串值；100 作者 / 503 书名 / 201 封面偏移 …）。
  final Map<int, String> exth;

  /// 封面记录索引（EXTH 201 + `firstImageIndex` 合成；无则 -1）。
  final int coverRecordIndex;

  /// 全书名（MOBI 头 `fullNameOffset`；无则 null）。
  final String? fullName;

  /// 记录 [index] 的字节（越界返回 null）。
  Uint8List? record(int index) {
    if (index < 0 || index >= recordOffsets.length) return null;
    final int start = recordOffsets[index];
    final int end = index + 1 < recordOffsets.length
        ? recordOffsets[index + 1]
        : bytes.length;
    if (start < 0 || end > bytes.length || end <= start) return null;
    return Uint8List.sublistView(bytes, start, end);
  }

  /// 解压后的正文（UTF-8 字节流）。compression=2 时抛异常。
  ///
  /// **末尾空白裁剪**：PalmDOC 解压器用「输出末字节是空格」做回溯锚，解出的尾部
  /// 常带一串空格；按 `textLength` 裁剪后再去掉尾部空格/换行，避免污染末段。
  Uint8List textBytes() {
    if (encryptionType != 0) {
      throw const MReaderFormatException(FormatErrorCode.encryptedMobi);
    }
    if (compression == 2) {
      throw const MReaderFormatException(
        FormatErrorCode.mobiHuffCdicUnsupported,
        detail: 'compression=2 (HUFF/CDIC)',
      );
    }

    final Uint8List packed = _packedTextRecords();
    final Uint8List out = _pickText(packed);
    int end = out.length;
    while (end > 0 && _isTrailingBlank(out[end - 1])) {
      end--;
    }
    return end == out.length ? out : Uint8List.sublistView(out, 0, end);
  }

  /// 拼接文本记录 1..[textRecordCount]（按 recordSize 截齐；末条可不足）。
  Uint8List _packedTextRecords() {
    final List<int> offsets = recordOffsets;
    final int count = textRecordCount < 0 ? 0 : textRecordCount;
    final Uint8List raw = Uint8List(recordSize * count);
    int copied = 0;
    for (int i = 1; i <= count && i < offsets.length; i++) {
      final Uint8List? rec = record(i);
      if (rec == null) break;
      final int take = rec.length < recordSize ? rec.length : recordSize;
      if (copied + take > raw.length) break;
      raw.setRange(copied, copied + take, rec);
      copied += take;
    }
    Uint8List packed = Uint8List.sublistView(raw, 0, copied);
    // textLength 描述的是**解压后**长度；未压缩书两者相等。真压缩书必然
    // packed < textLength，故这里只在 packed 明显更长时按 textLength 裁。
    if (textLength > 0 && textLength < packed.length) {
      packed = Uint8List.sublistView(packed, 0, textLength);
    }
    return packed;
  }

  /// ## 「压缩标志不可信」的实测口径（2026-10-20，真样本）
  ///
  /// | 样本 | compression | 记录拼接长度 vs textLength | 判定 |
  /// |---|---|---|---|
  /// | `tmp_book/*.azw3`（掌阅系中文长篇） | 1 = PalmDOC | **恰好相等** | 实际**未压缩**——按 PalmDOC 解会把中文全打成 ASCII 垃圾（实测 cjk=0） |
  /// | `tmp_book/*.mobi` | 2 = HUFF/CDIC | 11.9MB < 21.6MB | 真压缩（本实现不支持，诚实降级） |
  ///
  /// 口径：**先看长度再决定**——`packed.length < textLength` 才可能是真压缩；
  /// 相等即按未压缩直取。两者都可用时用「UTF-8 合法率」择优（脏书兜底）。
  Uint8List _pickText(Uint8List packed) {
    final bool maybeCompressed = compression == 1 && textLength > packed.length;
    if (!maybeCompressed) return packed;
    final Uint8List inflated = decompressPalmDoc(packed);
    return _utf8Score(inflated) >= _utf8Score(packed) ? inflated : packed;
  }

  /// UTF-8 合法率（0~1）：替换符占比越低越像正常文本。
  static double _utf8Score(Uint8List bytes) {
    if (bytes.isEmpty) return 1;
    try {
      const Utf8Decoder(allowMalformed: false).convert(bytes);
      return 1;
    } catch (_) {
      // 落到容错解码后数替换符（粗判即可，只在两条候选间比较）。
    }
    final String s = const Utf8Decoder(allowMalformed: true).convert(bytes);
    int bad = 0;
    for (int i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) == 0xfffd) bad++;
    }
    return 1 - bad / s.length;
  }

  static bool _isTrailingBlank(int byte) =>
      byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d || byte == 0x00;
}

/// 解析 PalmDB / MOBI 头。魔数已由 `hasMobiMagic` 把关，这里只做结构校验。
///
/// 抛 [FormatErrorCode.corruptFile] 表示结构不可信（截断、记录表越界等）。
MobiContainer parseMobi(Uint8List bytes) {
  if (bytes.length < 100) {
    throw const MReaderFormatException(FormatErrorCode.emptyFile);
  }
  final ByteData data = ByteData.sublistView(bytes);

  final int recordCount = data.getUint16(76, Endian.big);
  if (recordCount <= 0 || 78 + recordCount * 8 > bytes.length) {
    throw const MReaderFormatException(
      FormatErrorCode.corruptFile,
      detail: 'PDB record table out of range',
    );
  }
  final List<int> offsets = <int>[
    for (int i = 0; i < recordCount; i++)
      data.getUint32(78 + i * 8, Endian.big),
  ];

  final int r0 = offsets.first;
  if (r0 < 0 || r0 + 24 > bytes.length) {
    throw const MReaderFormatException(
      FormatErrorCode.corruptFile,
      detail: 'record 0 out of range',
    );
  }

  final int compression = data.getUint16(r0, Endian.big);
  final int textLength = data.getUint32(r0 + 4, Endian.big);
  final int textRecordCount = data.getUint16(r0 + 8, Endian.big);
  final int recordSize = data.getUint16(r0 + 10, Endian.big);
  final int encryptionType = data.getUint16(r0 + 12, Endian.big);

  // MOBI 头（记录 0 + 16）；旧式纯 PalmDOC（无 'MOBI' 魔数）按 CP1252 处理。
  final int mobiStart = r0 + 16;
  final bool hasMobiHeader = mobiStart + 4 <= bytes.length &&
      bytes[mobiStart] == 0x4d &&
      bytes[mobiStart + 1] == 0x4f &&
      bytes[mobiStart + 2] == 0x42 &&
      bytes[mobiStart + 3] == 0x49;
  int textEncoding = 1252;
  int firstImageIndex = -1;
  int fullNameOffset = -1;
  int fullNameLength = 0;
  int headerLength = 0;
  Map<int, String> exth = const <int, String>{};
  if (hasMobiHeader) {
    headerLength = data.getUint32(mobiStart + 4, Endian.big);
    textEncoding = data.getUint32(mobiStart + 12, Endian.big);
    firstImageIndex = data.getUint32(mobiStart + 0x44, Endian.big);
    fullNameOffset = data.getUint32(mobiStart + 0x2c, Endian.big);
    fullNameLength = data.getUint32(mobiStart + 0x30, Endian.big);
    final int exthFlags = data.getUint32(mobiStart + 0x58, Endian.big);
    if ((exthFlags & 0x40) != 0) {
      exth = _readExth(data, mobiStart + headerLength, bytes);
    }
  }

  String? fullName;
  if (fullNameOffset > 0 && fullNameLength > 0) {
    final int start = r0 + fullNameOffset;
    if (start >= 0 && start + fullNameLength <= bytes.length) {
      fullName = _decode(
        Uint8List.sublistView(bytes, start, start + fullNameLength),
        textEncoding,
      );
    }
  }

  var coverRecordIndex = -1;
  final String? coverOffsetText = exth[201];
  if (coverOffsetText != null && firstImageIndex >= 0 && firstImageIndex != -1) {
    final int? delta = int.tryParse(coverOffsetText.trim(), radix: 10);
    if (delta != null) coverRecordIndex = firstImageIndex + delta;
  }

  return MobiContainer._(
    bytes: bytes,
    compression: compression,
    textLength: textLength,
    textRecordCount: textRecordCount,
    recordSize: recordSize <= 0 ? 4096 : recordSize,
    encryptionType: encryptionType,
    textEncoding: textEncoding,
    recordOffsets: offsets,
    recordZeroOffset: r0,
    exth: exth,
    coverRecordIndex: coverRecordIndex,
    fullName: fullName,
  );
}

/// 读 EXTH 记录块（type → 字符串值；二进制值按 latin1 存，供 201 这类偏移用）。
Map<int, String> _readExth(ByteData data, int start, Uint8List bytes) {
  if (start < 0 || start + 12 > bytes.length) return const <int, String>{};
  if (bytes[start] != 0x45 || // E
      bytes[start + 1] != 0x58 || // X
      bytes[start + 2] != 0x54 || // T
      bytes[start + 3] != 0x48) { // H
    return const <int, String>{};
  }
  final int count = data.getUint32(start + 8, Endian.big);
  final Map<int, String> out = <int, String>{};
  int p = start + 12;
  for (int i = 0; i < count; i++) {
    if (p + 8 > bytes.length) break;
    final int type = data.getUint32(p, Endian.big);
    final int length = data.getUint32(p + 4, Endian.big);
    if (length < 8 || p + length > bytes.length) break;
    final Uint8List value =
        Uint8List.sublistView(bytes, p + 8, p + length);
    // EXTH 文本随书编码（中文书多为 UTF-8）：先按 UTF-8 解，失败退 latin1，
    // 保证 201 这类纯数字偏移在任何编码下都不失真。
    String text;
    try {
      text = const Utf8Decoder(allowMalformed: false).convert(value);
    } catch (_) {
      text = String.fromCharCodes(value);
    }
    out[type] = text;
    p += length;
  }
  return out;
}

/// 按 MOBI 头 `textEncoding` 解码；未知值按 UTF-8 兜底（失败退 latin1，绝不抛）。
String _decode(Uint8List bytes, int encoding) {
  if (encoding == 65001) {
    try {
      return const Utf8Decoder().convert(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }
  if (encoding == 1252 || encoding == 0) {
    return String.fromCharCodes(bytes); // latin1 近似（MOBI 欧美书主流）
  }
  return String.fromCharCodes(bytes);
}

/// PalmDOC 解压（compression = 1）。
///
/// 算法（Diethorn《MOBI 格式》标准 LZ77 变体）：
/// · `0x00` → 输出 0x00；
/// · `0x01..0x7F` → 字面量；
/// · `0x80..0xBF` → 1 字节长度（`c & 0x7F` + 3）+ 2 字节距离（**15 位有效**）；
/// · `0xC0..0xFF` → 2 字节组合：高 11 位距离、低 3 位长度（+3）。
///
/// 距离一律「从当前输出末尾往回数」（1 = 上一字节）。非法回溯（距离超出已输出）
/// 按「截到可用长度」容错，绝不抛异常——脏书不该让整个导入失败。
Uint8List decompressPalmDoc(Uint8List src) {
  final BytesBuilder out = BytesBuilder(copy: false);
  final List<int> buffer = <int>[];
  int i = 0;
  final int n = src.length;

  void copyBack(int distance, int length) {
    if (distance <= 0 || distance > buffer.length) {
      // 距离非法：能复制多少复制多少（容错，不抛）。
      final int safe = distance <= 0 ? 0 : buffer.length;
      if (safe == 0) return;
      for (int k = 0; k < length; k++) {
        buffer.add(buffer[buffer.length - safe]);
      }
      return;
    }
    for (int k = 0; k < length; k++) {
      buffer.add(buffer[buffer.length - distance]);
    }
  }

  while (i < n) {
    final int c = src[i++];
    if (c == 0) {
      buffer.add(0);
    } else if (c <= 0x7f) {
      buffer.add(c);
    } else if (c >= 0xc0) {
      if (i >= n) break;
      // 组合对：`(c & 0x3F) << 8 | next` —— 高 11 位距离、低 3 位长度。
      final int pair = ((c & 0x3f) << 8) | src[i];
      i++;
      final int rawDistance = pair >> 3; // 0..2047（回溯距离 = rawDistance + 1）
      var length = (pair & 0x7) + 3;
      // Diethorn 规范：距离 > 0xD00 时长度 +1（远距离回溯多复制一字节）。
      if (rawDistance > 0xd00) length += 1;
      copyBack(rawDistance + 1, length);
    } else {
      // 0x80..0xBF：1 字节长度（`c & 0x7F` + 3）+ 2 字节距离（15 位有效）。
      if (i + 1 >= n) break;
      final int length = (c & 0x7f) + 3;
      final int word = ((src[i] << 8) | src[i + 1]) & 0xffff;
      i += 2;
      final int distance = (word >> 1) & 0x7fff;
      copyBack(distance <= 0 ? 1 : distance, length);
    }
  }
  out.add(buffer);
  return out.takeBytes();
}
