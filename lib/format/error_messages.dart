// 面向用户的格式错误文案 —— **全工程唯一来源**。
//
// 为什么必须唯一（对齐 `RD-05` 与 `RUST-04 ②`）：
// Rust 加速层回落后，同一类错误的**中文口径必须与纯 Dart 路径一致**。
// 若各层自行拼字符串，两份实现的提示必然漂移，用户会看到两套说法。
// 因此：格式层**只允许**从这里取文案，抛异常时只传「错误码 + 调试细节」。
//
// 本文件为纯 Dart（不 import Flutter、不 import dart:io），可被 isolate 复用。

/// 格式错误的枚举。**新增枚举值必须同时补 [kFormatErrorMessages]**
/// （由 `test/format/error_messages_test.dart` 兜底检查）。
enum FormatErrorCode {
  notZip,
  missingContainer,
  badContainerXml,
  missingOpf,
  badOpf,
  emptySpine,
  encryptedEpub,
  encryptedMobi,
  unsupportedFormat,
  corruptFile,
  emptyFile,
  txtNoContent,
  cbrUnsupported,
  mobiUnsupported,
  noImagePages,
}

/// 格式层统一异常。
///
/// [code] 决定面向用户的中文（取自 [kFormatErrorMessages]）；
/// [detail] 只用于调试（如包内路径 / 具体原因），**不直接展示给用户**。
class MReaderFormatException implements Exception {
  const MReaderFormatException(this.code, {this.detail});

  final FormatErrorCode code;

  /// 仅调试用（如包内路径），**不直接展示给用户**。
  final String? detail;

  /// 面向用户的中文，取自 [kFormatErrorMessages]。
  String get message => kFormatErrorMessages[code]!;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

/// [FormatErrorCode] -> 面向用户的中文提示（`RD-05` 口径，逐字固定）。
const Map<FormatErrorCode, String> kFormatErrorMessages =
    <FormatErrorCode, String>{
  FormatErrorCode.notZip: '解压失败：该文件不是有效的 EPUB（EPUB 本质是一个 zip 包）。',
  FormatErrorCode.missingContainer: '缺少 META-INF/container.xml，不是合法的 EPUB 结构。',
  FormatErrorCode.badContainerXml: 'META-INF/container.xml 解析失败（XML 格式错误）。',
  FormatErrorCode.missingOpf: 'container.xml 中没有找到 rootfile（OPF 路径缺失）。',
  FormatErrorCode.badOpf: 'OPF 解析失败（XML 格式错误）。',
  FormatErrorCode.emptySpine: 'spine 为空：找不到任何可阅读的章节。',
  FormatErrorCode.encryptedEpub: '这是一本加密的 EPUB，暂不支持打开。',
  FormatErrorCode.encryptedMobi: '这是一本加密的 AZW3/MOBI，暂不支持打开。',
  FormatErrorCode.unsupportedFormat: '暂不支持这种格式（当前支持 EPUB、TXT 与 CBZ）。',
  FormatErrorCode.corruptFile: '文件已损坏或不是有效的电子书文件。',
  FormatErrorCode.emptyFile: '文件是空的。',
  FormatErrorCode.txtNoContent: '这个 TXT 里没有找到可阅读的文本。',
  FormatErrorCode.cbrUnsupported: '这是一本 CBR（RAR 压缩包），暂不支持打开，请转换为 CBZ 后导入。',
  FormatErrorCode.mobiUnsupported: '暂不支持 MOBI/AZW3 格式，请转换为 EPUB 或 TXT 后导入。',
  FormatErrorCode.noImagePages: '压缩包里没有找到任何图片页。',
};
