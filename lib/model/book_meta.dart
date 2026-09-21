// 书籍元数据统一模型（`META-01`，架构文档 §N 接口冻结）。
//
// **全工程唯一定义**：`lib/format/book_source.dart` 与 `lib/meta/book_meta.dart`
// 只做 `export`，**不另立第二份**（§N.1 防复制陷阱——与 `chapter.dart` 同款做法，
// 结构相同的两份类型会导致无意义的字段搬运与「各实现各自挑类型」）。
//
// 纯 Dart **叶子**：除 `dart:typed_data` 外**零 import**。
// 这是 `PERF-01`（解析移出主 isolate）的硬前提——`BookSource.load()` 的产出
// 必须能直接丢进 `compute()`（§N.4 边界表）。
import 'dart:typed_data';

/// 每个字段的**来源标记**（`META-01`）：**闭合四值**。
///
/// ⚠️ **不得扩展成「哪一路内嵌源」**（OPF 的 dc 字段、MOBI 的 EXTH 编号 …）——
/// 那是**另一根轴**（§N.2）：混用会让「来源标记相等」的等价性判定（§B.3 L3）
/// 与「来源标记置 user 不被覆盖」的逻辑（`META-08`）失去可判定性。
/// 若排障需要，只在**解析期结果**上挂一个非契约的 `debugTag`，不进本枚举、不落盘。
enum MetaOrigin {
  /// 来自文件内嵌元数据（EPUB 的 OPF、MOBI 的 EXTH…）。
  metadata,

  /// 由文件名推断。
  filename,

  /// 用户手动编辑。
  user,

  /// 缺失。
  none,
}

/// 封面的**真实**格式——由**魔数嗅探**得出（**非扩展名**，`META-05`，§N.5/§N.6）。
enum CoverFormat { jpeg, png, webp, gif, bmp, unknown }

/// 封面引用（`META-06 ④`）：一律用**显式类型 / 枚举 / 空值**表达，**禁止魔法字符串**。
///
/// 与 `MetaOrigin`（`coverOrigin` 字段）**正交**：本类型答「封面从哪来 / 怎么存」，
/// `MetaOrigin` 答「谁定的（metadata/filename/user/none）」。
sealed class CoverRef {
  const CoverRef();
}

/// 无封面（走占位图）。
final class NoCover extends CoverRef {
  const NoCover();
}

/// 解析期：封面原始字节**尚未落盘**——纯 Dart 的 `BookSource` 只能产出它。
///
/// **不变式**：**持久化**的 `BookMeta` 中**不得**出现 `PendingCover`；
/// 落盘前必须由 `CoverStore.materialize()` 物化为 [StoredCover]（§N.7）。
/// 之所以让 `load()` 返回「原始字节 + 真实格式」而非自己落盘：
/// `lib/format/**` 禁 `dart:io`（`PERF-01`），**不可能**自己写 `covers/`——
/// 职责与层同时对齐。
final class PendingCover extends CoverRef {
  const PendingCover(this.bytes, this.format);

  /// 封面原始字节（**保留源字节，不重编码**）。
  final Uint8List bytes;

  /// 真实格式（魔数嗅探结果）。
  final CoverFormat format;
}

/// 已落盘：`covers/<fileName>`（保留源字节、真实格式，**不重编码**，`META-05`）。
final class StoredCover extends CoverRef {
  const StoredCover(this.fileName);

  /// **仅文件名**（不含目录；目录由 [CoverStore] 解析）。
  final String fileName;
}

/// 运行时合成封面（`META-07`）：`cacheKey = hash(书名 + 作者 + 主题)`。
final class SyntheticCover extends CoverRef {
  const SyntheticCover(this.cacheKey);

  /// 合成封面的缓存键（书名 + 作者 + 主题 的哈希）。
  final String cacheKey;
}

/// 解析时刻的**自动值**（**不含** user 编辑）；`META-08` 的「恢复自动值」依赖它。
///
/// 封面**不在其中**——「恢复自动封面」= 重跑 `epub_meta` 提取
/// （不缓存原始封面字节，省内存，§N.3）。
class BookMetaAuto {
  const BookMetaAuto({
    required this.title,
    required this.author,
    required this.intro,
  });

  final String title;
  final String author;
  final String intro;
}

/// 元数据统一模型（`META-01`）——书架与详情页**只消费它**，不感知格式。
///
/// 位置：`lib/model/book_meta.dart`（唯一）。纯 Dart（只 import `dart:typed_data`）。
class BookMeta {
  const BookMeta({
    required this.title,
    required this.titleOrigin,
    required this.author,
    required this.authorOrigin,
    required this.intro,
    required this.introOrigin,
    required this.cover,
    required this.coverOrigin,
    required this.language,
    this.auto,
  });

  final String title;
  final MetaOrigin titleOrigin;

  /// 作者；缺失时为「未知作者」，**不得留空字符串**（`META-01` 兜底统一）。
  final String author;
  final MetaOrigin authorOrigin;

  /// 简介（`META-01` 四字段之一）。
  final String intro;
  final MetaOrigin introOrigin;

  /// 封面引用（`META-06`，见 [CoverRef]）。
  final CoverRef cover;
  final MetaOrigin coverOrigin;

  final String language;

  /// 解析时刻的**自动值**快照，供 M2a「恢复自动值」（`META-08`）回退；
  /// M1 阶段由解析写入、**恒非空**（依赖注入时为 `null` 只表示「未解析」）。
  final BookMetaAuto? auto;

  @override
  String toString() => 'BookMeta(title: $title, author: $author, '
      'titleOrigin: $titleOrigin, authorOrigin: $authorOrigin, '
      'cover: ${cover.runtimeType}, coverOrigin: $coverOrigin)';
}
