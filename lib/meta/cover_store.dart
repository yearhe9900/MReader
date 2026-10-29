// 封面落盘与生命周期（`META-05` / `META-06`，架构 §N.6 / §N.7）——**Flutter 侧**。
//
// 本文件依赖 `dart:ui`（解码 / 降采样）与 `lib/platform`（`AppPaths`）、`lib/storage`
// （`AtomicFile`，`DATA-01`），属架构 §N.4 表中的「Flutter 那半」，**不进 `compute()`**。
// 魔数嗅探（纯 Dart）在 `meta_source.dart`——「嗅探」与「解码」拆开，是让 `META-05`
// 上半截仍可进 isolate 的关键。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../model/book_meta.dart';
import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import 'meta_source.dart';

/// 解码**像素上限**（`META-05` / `NF-M5`）：超限**先降采样再解码**，
/// 避免「导入大封面 → 逐本解码原图 → 内存尖峰」。取 2048×2048。
const int kCoverDecodeMaxPixels = 4 * 1024 * 1024; // 4,194,304

/// 书架缩略图**最长边**（`META-05`：书架**不**逐本缩放原图）。
const int kCoverThumbMaxEdge = 320; // px

/// `META-05/06` 的封面存储契约（架构 §N.7，**签名一字不改**）。
abstract interface class CoverStore {
  /// 解析期封面落盘：`PendingCover` → `StoredCover`（保留源字节 + 真实格式），并生成缩略图。
  ///
  /// **幂等**：同一 `bookId` 重复 `materialize` 覆盖旧文件（先清同 `bookId` 旧文件，不产生孤儿）。
  Future<StoredCover> materialize({
    required String bookId,
    required PendingCover pending,
  });

  /// 用户换封面（`META-09`）：写入用户图，**并删除** [previous] 指向的旧文件（`META-06 ①`）。
  Future<StoredCover> replaceWithUserPick({
    required String bookId,
    required Uint8List bytes,
    required CoverRef? previous,
  });

  /// 详情页看大图。
  Future<Uint8List?> readFull(CoverRef ref);

  /// 书架列表（只解码缩略图）。
  Future<Uint8List?> readThumb(CoverRef ref);

  /// 删书（`LIB-06`）/ 换封面后清理被替换文件（`META-06 ①②`）。
  /// `NoCover` / `SyntheticCover` 为**空操作**（合成封面不是文件）。
  Future<void> delete(CoverRef ref);

  /// 「清空缓存」：删除 `covers/` 下**不被任何书籍引用**的孤儿（`META-06 ③`）。
  /// [referencedFileNames] 由书库汇总所有在库书籍的 `StoredCover.fileName`。
  /// **安全规则（写死，§N.7）**：只删 `covers/` 内、且**不在** [referencedFileNames]
  /// 中的文件；返回删除数；**幂等**；`covers/` 之外的任何路径**永不触碰**。
  /// `AtomicFile` 的 `.tmp` / `.bak` / `.corrupt` **兄弟文件必须随基文件处置**（基文件
  /// 被引用 → 兄弟保留；基文件是孤儿 → 兄弟一起删），否则会删掉主文件损坏时唯一可回退
  /// 的 `.bak`、破坏降级路径；**缩略图**同理随其基封面处置。
  Future<int> purgeOrphans({required Set<String> referencedFileNames});
}

/// 基于 [AppPaths] + [AtomicFile] 的默认实现。落盘目录：`AppPaths.subDir('covers')`
/// （**不**硬编码路径、**不**直接 import `path_provider`）。
class FileCoverStore implements CoverStore {
  FileCoverStore(this._paths);

  final AppPaths _paths;

  /// `covers/` 子目录名。
  static const String coverDirName = 'covers';

  /// 备份 / 临时 / 隔离文件后缀（与 [AtomicFile] 一致）。
  static const List<String> _siblingSuffixes = <String>[
    '.tmp',
    '.bak',
    '.corrupt',
  ];

  Future<Directory> _dir() => _paths.subDir(coverDirName);

  /// 真实格式 -> 落盘扩展名（**不看原扩展名**，`META-05`）。
  static String extensionOf(CoverFormat format) {
    switch (format) {
      case CoverFormat.jpeg:
        return 'jpg';
      case CoverFormat.png:
        return 'png';
      case CoverFormat.webp:
        return 'webp';
      case CoverFormat.gif:
        return 'gif';
      case CoverFormat.bmp:
        return 'bmp';
      case CoverFormat.unknown:
        // 嗅探不出格式：仍保留源字节，用中性扩展名（不谎报为已知格式）。
        return 'img';
    }
  }

  @override
  Future<StoredCover> materialize({
    required String bookId,
    required PendingCover pending,
  }) async {
    final Directory dir = await _dir();
    // 幂等：先清同 bookId 的旧封面 / 缩略图（含不同扩展名与兄弟文件），避免孤儿。
    await _deleteByBookId(dir, bookId);

    final String coverName = '$bookId.cover.${extensionOf(pending.format)}';
    await AtomicFile(_join(dir, coverName)).writeBytes(pending.bytes);

    // 缩略图：独立文件，书架只解码它。命名用 `png` 而非源格式——`dart:ui` 只能编码
    // PNG，用源扩展名会「后缀名与内容不符」（`META-05` 明令禁止）。
    final Uint8List? thumb = await _renderThumbPng(pending.bytes);
    if (thumb != null) {
      await AtomicFile(_join(dir, '$bookId.thumb.png')).writeBytes(thumb);
    }

    return StoredCover(coverName);
  }

  @override
  Future<StoredCover> replaceWithUserPick({
    required String bookId,
    required Uint8List bytes,
    required CoverRef? previous,
  }) async {
    final CoverFormat format = sniffCoverFormat(bytes);
    final StoredCover stored = await materialize(
      bookId: bookId,
      pending: PendingCover(bytes, format),
    );
    // 删除被替换的旧文件（`META-06 ①`）。
    if (previous != null && previous is StoredCover) {
      if (previous.fileName != stored.fileName) {
        await delete(previous);
      }
    }
    return stored;
  }

  @override
  Future<Uint8List?> readFull(CoverRef ref) async {
    if (ref is! StoredCover) return null;
    final Directory dir = await _dir();
    final File file = File(_join(dir, ref.fileName));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<Uint8List?> readThumb(CoverRef ref) async {
    if (ref is! StoredCover) return null;
    final String? thumb = _thumbNameFor(ref.fileName);
    if (thumb == null) return null;
    final Directory dir = await _dir();
    final File file = File(_join(dir, thumb));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> delete(CoverRef ref) async {
    if (ref is! StoredCover) return; // NoCover / SyntheticCover：空操作
    final Directory dir = await _dir();
    await _deleteFileAndSiblings(dir, ref.fileName);
    final String? thumb = _thumbNameFor(ref.fileName);
    if (thumb != null) {
      await _deleteFileAndSiblings(dir, thumb);
    }
  }

  @override
  Future<int> purgeOrphans({required Set<String> referencedFileNames}) async {
    final Directory dir = await _dir();
    if (!await dir.exists()) return 0;

    // 被引用的「基名」（把可能带 .tmp/.bak/.corrupt 的引用一并归一），以及其 bookId。
    final Set<String> keepBase = <String>{};
    final Set<String> keepBookIds = <String>{};
    for (final String name in referencedFileNames) {
      final String base = _baseName(name);
      keepBase.add(base);
      final String? id = _bookIdOf(base);
      if (id != null) keepBookIds.add(id);
    }

    int removed = 0;
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final String name = _lastSegment(entity.path);
      final String base = _baseName(name);
      if (keepBase.contains(base)) continue; // 基文件被引用（或引用名本身带后缀）
      final String? id = _bookIdOf(base);
      if (id != null && keepBookIds.contains(id)) continue; // 兄弟 / 缩略图随基封面保留
      await entity.delete();
      removed++;
    }
    return removed;
  }

  // -------------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------------

  /// 缩略图最长边降采样 + PNG 编码；解码失败返回 `null`（不阻塞封面落盘）。
  Future<Uint8List?> _renderThumbPng(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      int tw = descriptor.width;
      int th = descriptor.height;
      final int pixels = tw * th;

      // ① 像素上限：超限先等比降到上限内（先量后算再解码，`META-05` / §N.6）。
      if (pixels > kCoverDecodeMaxPixels && pixels > 0) {
        final double s = math.sqrt(kCoverDecodeMaxPixels / pixels);
        tw = math.max(1, (tw * s).floor());
        th = math.max(1, (th * s).floor());
      }
      // ② 再降到缩略图最长边（书架只解码它）。
      final int longest = math.max(tw, th);
      if (longest > kCoverThumbMaxEdge) {
        final double s = kCoverThumbMaxEdge / longest;
        tw = math.max(1, (tw * s).floor());
        th = math.max(1, (th * s).floor());
      }

      codec = await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } catch (_) {
      return null; // 脏图 / 不支持的编码：原图仍落盘，缩略图缺省。
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// 由封面文件名推缩略图文件名：`<bookId>.cover.<ext>` -> `<bookId>.thumb.png`。
  static String? _thumbNameFor(String coverFileName) {
    final int idx = coverFileName.lastIndexOf('.cover.');
    if (idx <= 0) return null;
    return '${coverFileName.substring(0, idx)}.thumb.png';
  }

  /// 去掉 `.tmp` / `.bak` / `.corrupt` 后缀，得到「基名」。
  static String _baseName(String fileName) {
    for (final String suffix in _siblingSuffixes) {
      if (fileName.endsWith(suffix)) {
        return fileName.substring(0, fileName.length - suffix.length);
      }
    }
    return fileName;
  }

  static final RegExp _coverNameRe = RegExp(r'^(.+)\.cover\.[A-Za-z0-9]+$');
  static final RegExp _thumbNameRe = RegExp(r'^(.+)\.thumb\.[A-Za-z0-9]+$');

  /// 由「基名」提取 `bookId`（封面 / 缩略图命名都含 bookId）；无法识别返回 `null`。
  static String? _bookIdOf(String base) {
    final RegExpMatch? m =
        _coverNameRe.firstMatch(base) ?? _thumbNameRe.firstMatch(base);
    return m?.group(1);
  }

  Future<void> _deleteByBookId(Directory dir, String bookId) async {
    if (!await dir.exists()) return;
    final String coverPrefix = '$bookId.cover.';
    final String thumbPrefix = '$bookId.thumb.';
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final String name = _lastSegment(entity.path);
      if (name.startsWith(coverPrefix) || name.startsWith(thumbPrefix)) {
        await entity.delete();
      }
    }
  }

  Future<void> _deleteFileAndSiblings(Directory dir, String fileName) async {
    if (!await dir.exists()) return;
    for (final String candidate in <String>[
      fileName,
      for (final String suffix in _siblingSuffixes) '$fileName$suffix',
    ]) {
      final File file = File(_join(dir, candidate));
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static String _join(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  static String _lastSegment(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }
}
