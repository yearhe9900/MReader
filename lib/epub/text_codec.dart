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
///
/// **重构说明（M1-T02B）**：本函数的「判定」与「解码」已拆开——
/// 判定结果即 [detectEncodingName] 返回的**生效编码名**，本函数等价于
/// 「[detectEncodingName] 取名字 + `_decodeByName` 按名字解码」。
/// 外部行为（输入 -> 输出字符串）逐字节不变，由 `test/epub_fixtures_test.dart`
/// 的 fx04 / fx09 / fx10 / fx11 与 9 本 fixture 基线共同护栏。
String decodeText(Uint8List bytes) =>
    _decodeByName(detectEncodingName(bytes), bytes);

/// 探测编码名（`NF-C4` 六级兜底的**判定结果**）。
///
/// 返回**生效**编码名（不是「声明」的编码名）——即 [decodeText] 最终实际采用的那一档：
/// `'utf-8'` / `'utf-16le'` / `'utf-16be'` / `'gbk'` / `'latin1'`，小写。
/// 例如「声明 utf-8 但字节非法」的输入，本函数返回 `'gbk'`（因为 [decodeText] 会落到 GBK 档）。
///
/// 为什么要这条缝（PRD §15.6.2）：Rust 首版**只做「探测出编码名」**、解码仍留在 Dart，
/// 因此纯 Dart 侧必须能**单独拿到「我判定成了哪种编码」**，否则将来 Rust 无从对齐。
///
/// 空字节输入返回 `'utf-8'`（三者解码结果均为空串，取名不影响 [decodeText] 的行为）。
String detectEncodingName(Uint8List bytes) {
  if (bytes.isEmpty) return 'utf-8';

  // 1. BOM 优先（与 decodeText 的分支顺序严格一致）。
  if (_hasUtf8Bom(bytes)) return 'utf-8';
  if (hasUtf16BeBom(bytes)) return 'utf-16be';
  if (hasUtf16LeBom(bytes)) return 'utf-16le';

  // 2. 声明分支：能成功才采用，否则继续往下兜底。
  final String? declared = _detectDeclaredEncoding(bytes);
  if (declared != null) {
    final String? byDeclaration = _effectiveNameForDeclaration(declared, bytes);
    if (byDeclaration != null) return byDeclaration;
  }

  // 3. 严格 UTF-8。
  if (_tryStrictUtf8(bytes) != null) return 'utf-8';

  // 4~5. GBK，兜底 latin1。
  return _gbkCanDecode(bytes) ? 'gbk' : 'latin1';
}

/// 按**生效编码名**解码；保证绝不抛异常。
///
/// 与旧实现的分支一一对应：
/// - `'utf-8'`：带 UTF-8 BOM 时先剥 3 字节（旧实现如此），否则整体解码；
/// - `'utf-16le'` / `'utf-16be'`：`utf16.decode` 按 BOM 自选端序并剥离 BOM，无 BOM 默认大端；
/// - `'gbk'`：允许畸形字节，失败再退 latin1；
/// - `'latin1'`：永不失败。
String _decodeByName(String name, Uint8List bytes) {
  switch (name) {
    case 'utf-8':
      if (_hasUtf8Bom(bytes)) {
        return utf8.decode(bytes.sublist(3), allowMalformed: true);
      }
      return utf8.decode(bytes, allowMalformed: true);
    case 'utf-16le':
    case 'utf-16be':
      return utf16.decode(bytes);
    case 'gbk':
      return _decodeGbkOrLatin1(bytes);
    case 'latin1':
      return latin1.decode(bytes, allowInvalid: true);
    default:
      // 不应到达：`detectEncodingName` 只会返回上面四种名字之一。
      return utf8.decode(bytes, allowMalformed: true);
  }
}

/// 声明编码名 -> **生效**编码名；声明不可信（解码失败）时返回 null。
///
/// 这是旧实现 `_decodeByEncodingName` 的「判定」投影：返回值非 null 表示
/// [decodeText] 会采用该声明分支，且生效的编码名即此值。
String? _effectiveNameForDeclaration(String name, Uint8List bytes) {
  switch (name) {
    case 'utf-8':
    case 'utf8':
      // 声明 utf-8 但字节非法（如 GBK 伪装）时返回 null，让 decodeText 继续兜底（fx09）。
      return _tryStrictUtf8(bytes) != null ? 'utf-8' : null;
    case 'gbk':
    case 'gb2312':
    case 'gb-2312':
    case 'gb18030':
    case 'x-gbk':
      // 允许畸形字节：现实里「声明 gbk 却混入非法字节」很常见（fx11）。
      return _gbkCanDecode(bytes) ? 'gbk' : null;
    case 'utf-16':
    case 'utf16':
    case 'utf-16le':
    case 'utf-16be':
      if (!_utf16CanDecode(bytes)) return null;
      // 无 BOM 时 utf16.decode 默认大端；有 LE BOM 时为小端。
      return hasUtf16LeBom(bytes) ? 'utf-16le' : 'utf-16be';
    case 'latin1':
    case 'latin-1':
    case 'iso-8859-1':
    case 'ascii':
    case 'us-ascii':
      return 'latin1';
    default:
      return null;
  }
}

/// 严格 UTF-8 解码；若不是合法 UTF-8 则返回 null，交给上层继续兜底。
String? _tryStrictUtf8(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// GBK 能否解码（允许畸形字节）；**只判定，不看结果串**。
bool _gbkCanDecode(Uint8List bytes) {
  try {
    gbk.decode(bytes, allowMalformed: true);
    return true;
  } catch (_) {
    return false;
  }
}

/// utf16 能否解码（畸形输入用替换符兜底，一般不会失败）；**只判定**。
bool _utf16CanDecode(Uint8List bytes) {
  try {
    utf16.decode(bytes);
    return true;
  } catch (_) {
    return false;
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
