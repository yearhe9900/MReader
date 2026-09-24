// 字节级格式判据 —— **中立共享层**（与 `image_pages.dart` 同一存在理由）。
//
// `FMT-06`（M2b-T03）魔数纠偏的判据实现住这里：不进各 `BookSource` 实现类
// （架构 §A.1 铁律：实现类互不感知），也不混进 `book_registry.dart` 的分发
// 逻辑（判据可独立于 `FormatKind` 单测）。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'dart:typed_data';

/// 是否是 zip 容器（PK 头的三种形态：本地文件头 / 空档案 / 分卷档案）。
bool looksLikeZip(Uint8List bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
  return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
      (bytes[2] == 0x05 && bytes[3] == 0x06) ||
      (bytes[2] == 0x07 && bytes[3] == 0x08);
}

/// 字节是否「看起来是文本」（`.txt` 之外的兜底）。
///
/// 判据（保守，宁可判为不支持也不误开二进制）：
/// 1. 无 `0x00`（含 NUL 的几乎一定是二进制）；
/// 2. 头部 512 字节里没有除 `\t \n \f \r` 之外的 C0 控制符；
/// 3. 非 ASCII 字节视为文本（中文 TXT 必然是高位字节）。
bool looksLikeText(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  final int head = bytes.length > 512 ? 512 : bytes.length;
  for (int i = 0; i < head; i++) {
    final int b = bytes[i];
    if (b == 0x00) return false;
    if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0C && b != 0x0D) {
      return false;
    }
  }
  return true;
}

/// 是否是 MOBI 系容器（MOBI / AZW3，`FMT-06` ①）。
///
/// 判据 = PalmDB 头的 type + creator 字段（偏移 60..68 == ASCII `BOOKMOBI`，
/// 即 type "BOOK" + creator "MOBI"）——tmp_book 真实《牧神记》.mobi 与 .azw3
/// **双样本实测互证**：两文件偏移 60..68 均为 `42 4f 4f 4b 4d 4f 42 49`。
///
/// 为什么不能用「头可打印性」判：AZW3 头 8 字节是 PDB name 字段（可打印
/// ASCII，实测 `epubor.c`），改名 `.txt` 时纯文本启发式会误判——所以
/// `sniffFormat` 把本判据放在纯文本判定**之前**（`FMT-06` 验收①）。
///
/// 边界声明（M2b-T03）：
/// ① 不做 MOBI 与 AZW3 的家族内区分（同判据同信号；DRM/加密另由
///    `encryptedMobi` 错误码在解析层处理）；
/// ② 非 `BOOKMOBI` 的其他 PalmDB（PalmDOC 等）不命中，仍落 `unsupported`；
/// ③ 纯文本恰好在偏移 60..68 处含 ASCII `BOOKMOBI` 会误判——8 字节
///    精确定位碰撞概率可忽略，且 type+creator 是 PalmDB 的业界判据。
bool hasMobiMagic(Uint8List bytes) {
  // "BOOKMOBI"，逐字节常量（避免 String 编码歧义）。
  const List<int> kBookMobi = <int>[
    0x42, 0x4F, 0x4F, 0x4B, 0x4D, 0x4F, 0x42, 0x49,
  ];
  if (bytes.length < 68) return false;
  for (int i = 0; i < 8; i++) {
    if (bytes[60 + i] != kBookMobi[i]) return false;
  }
  return true;
}
