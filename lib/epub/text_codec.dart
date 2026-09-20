// 纯 Dart 的「字节 -> 字符串」解码工具。
//
// 故意不依赖 Flutter，便于单测与复用。
import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';

/// 把一段字节尽量正确地解码成字符串。
///
/// EPUB 是出了名的脏格式，必须多级兜底，顺序如下：
/// 1. UTF-8 BOM / UTF-16 BOM；
/// 2. XML 声明或 HTML meta 里写的 `encoding` / `charset`（如 GBK）；
/// 3. 严格 UTF-8（成功就直接用，覆盖绝大多数书）；
/// 4. GBK（中文老书常见）—— 允许畸形字节，用替换符兜底；
/// 5. latin1 兜底 —— 保证**一定**返回字符串，绝不抛异常。
///
/// 注意：**本函数承诺对任何输入都返回字符串，绝不抛异常**。
/// 现实里「声明与实际不符」非常常见（声明 utf-8 实为 GBK、声明 gbk 却混入非法字节），
/// 因此声明分支只能当作「优先猜测」：一旦失败必须能安全回落，而不是把异常抛给调用方。
String decodeText(Uint8List bytes) {
  if (bytes.isEmpty) return '';

  if (_hasUtf8Bom(bytes)) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (hasUtf16Bom(bytes)) {
    return utf16.decode(bytes);
  }

  // 声明分支：成功就直接采用；失败（返回 null）则继续往下兜底。
  final String? declared = _detectDeclaredEncoding(bytes);
  if (declared != null) {
    final String? byName = _decodeByEncodingName(declared, bytes);
    if (byName != null) return byName;
  }

  final String? strictUtf8 = _tryStrictUtf8(bytes);
  if (strictUtf8 != null) return strictUtf8;

  return _decodeGbkOrLatin1(bytes);
}

/// 严格 UTF-8 解码；若不是合法 UTF-8 则返回 null，交给上层继续兜底。
String? _tryStrictUtf8(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// GBK -> latin1 兜底。
///
/// GBK 解码**允许畸形字节**（非法序列用 U+FFFD 替换），因此即便有落单/非法字节
/// 也不会抛异常；万一仍然失败，退到 latin1（`allowInvalid: true`，永不失败）。
String _decodeGbkOrLatin1(Uint8List bytes) {
  try {
    return gbk.decode(bytes, allowMalformed: true);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

bool _hasUtf8Bom(Uint8List bytes) =>
    bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;

/// 匹配 `encoding="xxx"` 或 `charset=xxx`，引号可选。
final RegExp _declRegex = RegExp(
  '''(?:encoding|charset)\\s*=\\s*["']?\\s*([A-Za-z0-9_\\-]+)''',
  caseSensitive: false,
);

/// 从文件头部嗅探声明的编码名。
///
/// 声明区一定是 ASCII，所以用 latin1 读取不会有歧义。
String? _detectDeclaredEncoding(Uint8List bytes) {
  final Uint8List head = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
  final String text = latin1.decode(head, allowInvalid: true);
  final RegExpMatch? match = _declRegex.firstMatch(text);
  return match?.group(1)?.toLowerCase();
}

/// 按编码名解码；不认识的编码、或「声明与实际不符」时返回 null，交给上层继续兜底。
///
/// 这里整体包了 try/catch：**任何**底层解码器抛出的异常都会被收敛成 null，
/// 从而保证 [decodeText] 绝不把异常抛给调用方（回归 fixture fx11 即为该契约的探针）。
String? _decodeByEncodingName(String name, Uint8List bytes) {
  try {
    switch (name) {
      case 'utf-8':
      case 'utf8':
        // 声明 utf-8 但字节其实不是合法 UTF-8（如 GBK 伪装）时返回 null，
        // 让 decodeText 回落到「严格 UTF-8 -> GBK」链，而不是静默乱码（fx09）。
        return _tryStrictUtf8(bytes);
      case 'gbk':
      case 'gb2312':
      case 'gb-2312':
      case 'gb18030':
      case 'x-gbk':
        // 允许畸形字节：现实里「声明 gbk 却混入非法字节」很常见，不能因此抛异常（fx11）。
        return gbk.decode(bytes, allowMalformed: true);
      case 'utf-16':
      case 'utf16':
      case 'utf-16le':
      case 'utf-16be':
        return utf16.decode(bytes);
      case 'latin1':
      case 'latin-1':
      case 'iso-8859-1':
      case 'ascii':
      case 'us-ascii':
        return latin1.decode(bytes, allowInvalid: true);
      default:
        return null;
    }
  } catch (_) {
    // 声明不可信（如 utf-16 声明却给了一堆乱字节）：交给上层兜底，绝不向上抛。
    return null;
  }
}
