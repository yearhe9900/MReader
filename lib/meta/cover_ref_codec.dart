// 封面引用的**序列化**（`META-06 ⑤`：全工程搜不到魔法字符串）。
//
// ⚠️ **本文件是全工程唯一允许出现 `'file'` / `'synthetic'` / `'none'` 这类串的地方**，
// 且由 round-trip 测试锁死（§N.5）。业务代码一律用 [CoverRef] 显式类型表达。
//
// 纯 Dart（只 import `dart:convert` 的等价物——此处直接用 `Map`，不依赖任何包）。
import '../model/book_meta.dart';

/// `'file'` / `'synthetic'` / `'none'` 的**唯一定义处**。
class _CoverKind {
  static const String file = 'file';
  static const String synthetic = 'synthetic';
  static const String none = 'none';
}

/// 把 [CoverRef] 编码成可 JSON 化的 `Map`。
///
/// **不变式（§N.5）**：持久化不得含 [PendingCover]——遇到即抛 [StateError]
/// （落盘前必须经 `CoverStore.materialize()` 物化为 [StoredCover]）。
/// ```jsonc
/// { "kind": "file",      "fileName": "ab12…f9.cover.png" }
/// { "kind": "synthetic", "cacheKey": "9d2e…" }
/// { "kind": "none" }
/// ```
Map<String, Object?> encodeCoverRef(CoverRef ref) {
  switch (ref) {
    case NoCover():
      return <String, Object?>{'kind': _CoverKind.none};
    case StoredCover(:final String fileName):
      return <String, Object?>{
        'kind': _CoverKind.file,
        'fileName': fileName,
      };
    case SyntheticCover(:final String cacheKey):
      return <String, Object?>{
        'kind': _CoverKind.synthetic,
        'cacheKey': cacheKey,
      };
    case PendingCover():
      throw StateError(
        'PendingCover 不得持久化：落盘前必须经 CoverStore.materialize() '
        '物化为 StoredCover（架构 §N.5）。',
      );
  }
}

/// 从 [encodeCoverRef] 的产物还原 [CoverRef]。
CoverRef decodeCoverRef(Object? json) {
  if (json is! Map) {
    throw FormatException('封面引用不是对象：$json');
  }
  final Object? kind = json['kind'];
  switch (kind) {
    case _CoverKind.none:
      return const NoCover();
    case _CoverKind.file:
      return StoredCover('${json['fileName']}');
    case _CoverKind.synthetic:
      return SyntheticCover('${json['cacheKey']}');
    default:
      throw FormatException('未知封面引用 kind：$kind');
  }
}
