// 装配 + 分发点（架构文档 §A.1 的 `book_registry.dart` / §A.2）。
//
// **为什么单独一个文件**（架构文档 §A.1 铁律第 3 条）：`BookSource` 各实现互不
// import，选择集中在 [BookRegistry]；若把 `openBook` 写在 `book_source.dart` 里，
// 抽象层就得 import 具体实现。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
//
// ══════════════════════════════════════════════════════════════════════════
// 2026-10-26：解析实现唯一化 —— 内核是唯一实现，纯 Dart 源与「回落」一并下线
// ══════════════════════════════════════════════════════════════════════════
// EPUB / TXT / MOBI-AZW3 / CBZ 的解析自本日起**只有内核一条路**
// （[RustKernelSource]，vendored `rrk-*`）。原先的「Rust 失败回落纯 Dart」随
// 四个 Dart 源（`DartEpubSource` / `DartTxtSource` / `MobiSource` / `CbzSource`）
// 整体删除：内核已在这些格式上逐条对齐并通过双实现等价回归，回落的维护成本
// （两份实现 + 双份测试 + 无内核环境可测性）超过它的价值。
// 代价与替代路径已记上游 issue：
//   · 内核错误码 → 宿主映射统一中文（`rust_reader_kernel#11`）；
//   · 内容级解析缓存（原三层 Dart 缓存的接任者，`rust_reader_kernel#12`）。
// **CBR 与 PDF 不在此列**：CBR 内核明确不支持（`FMT-03` 靠 [CbrSource] 给
// 「识别 + 明确提示」），PDF 渲染走 pdfrx 原生引擎（`FMT-01`）。
import 'dart:typed_data';

import '../highperf/high_perf_capability.dart';
import '../highperf/high_perf_registry.dart';
import '../src/rust/api/error.dart' as rk_err;
import 'book_source.dart';
import 'cbr_source.dart';
import 'pdf_source.dart';
import 'rust_kernel_source.dart';
import 'sniffer.dart';

// `MReaderFormatException` / `FormatErrorCode` 经 `book_source.dart` 的
// `export 'error_messages.dart';` 转出，不单独 import（避免重复导入同一个库）。

/// 格式种类。
///
/// [mobi] = MOBI/AZW3（PalmDB `BOOKMOBI` 家族，`FMT-06` ① 识别）。[pdf] = PDF
/// （`FMT-01`）：`%PDF` 魔数 / `.pdf` 后缀识别，渲染内核经 `PdfEngine` 注入
/// （`META-10` ③，见 `lib/platform/pdf_engine.dart`）。
enum FormatKind { epub, txt, cbz, cbr, mobi, pdf, unsupported }

/// 装配 + 分发点。
///
/// ## 加速层注入缝（`RUST-01`）
///
/// [highPerf] 由组合根（`main()`）注入；**缺省取 [HighPerfRegistryProvider.current]**
/// （未注入时它就是纯 Dart 回落实例）。为什么「缺省读 provider」而非「缺省新建」：
/// `main()` 必须在 `runApp` **之前**把 `warmUp()` 的结论写进 provider，而 `openBook()`
/// 被深层纯层调用（`import_service` / `search_session` / `shelf_page`），逐层穿参
/// 会把加速层概念泄进那些调用点（违反 `RUST-01 ④`）。取舍全文见 [HighPerfRegistryProvider]。
///
/// **注**：内核唯一化之后，[highPerf] 不再决定「用哪份实现」，只承担**可观测性**
///（探测结论、成功 / 失败计数 → 体检页与日志回答「这本是内核开的吗」，`RUST-10 ②`）。
class BookRegistry {
  const BookRegistry({HighPerfRegistry? highPerf}) : _injectedHighPerf = highPerf;

  final HighPerfRegistry? _injectedHighPerf;

  /// 本次分发生效的加速能力注册表（构造注入优先，否则取组合根注入点）。
  /// 暴露用途：① 组合根 / 体检页输出 `describe()`（`RUST-10 ②`）；
  /// ② 测试取证探测结论（`identical` 断言，不靠行为反推）。
  HighPerfRegistry get highPerf =>
      _injectedHighPerf ?? HighPerfRegistryProvider.current;

  /// 该格式对应的**内核能力**；`null` = 该格式不走内核（无内核适配）。
  ///
  /// 这张映射表是 [open] 择实现的**唯一依据**，也是体检 / 日志回答「开这本 EPUB 时
  /// 内核到底生效了没」的入口：`highPerf.has(registry.capabilityFor(FormatKind.epub)!)`。
  ///
  /// 语义：`epub` / `txt` / `mobi` / `cbz` 四档 = **整条解析链走 Rust 内核**
  /// （打开 / 分章 / 正文抽取 / 资源，`rust/vendor/` 的 `rrk-*`），是**唯一实现**；
  /// `cbr` / `pdf` → **无候选**（CBR 内核明确不支持；PDF 渲染走 `pdfrx` 原生引擎，
  /// 内核 PDF 视图未接线）；`unsupported` → 无候选。
  HighPerfCapability? capabilityFor(FormatKind kind) => switch (kind) {
        FormatKind.epub => HighPerfCapability.epubDecompress,
        FormatKind.txt => HighPerfCapability.txtChapterize,
        FormatKind.mobi => HighPerfCapability.mobiDecompress,
        FormatKind.cbz => HighPerfCapability.cbzPages,
        FormatKind.cbr => null,
        FormatKind.pdf => null,
        FormatKind.unsupported => null,
      };

  /// 按一级（扩展名）+ 二级（魔数）选择实现。
  ///
  /// - `epub` / `txt` / `mobi` / `cbz` → [RustKernelSource]（唯一实现）；
  /// - `cbr` → [CbrSource]（`FMT-03`：`Q5` 退化「识别 + 明确提示」，`load()` 抛
  ///   `cbrUnsupported`、导入即拒绝）；
  /// - `pdf` → [PdfSource]（`FMT-01`：伪分章 + 连续翻阅 + 缩放；渲染内核取组合根
  ///   注入的 `PdfEngine`，未注入时抛 `unsupportedFormat`）；
  /// - `unsupported` → 抛 [MReaderFormatException]（`RD-05`）。
  ///
  /// 返回的永远是 [BookSource] 抽象——调用方无法、也无需知道来源。
  ///
  /// **内核失败即失败**（2026-10-26 起无回落）：打开失败统一翻译成
  /// [MReaderFormatException]（文案单一来源 `error_messages.dart`），内核原始消息
  /// 进 `detail` 只做调试；加密 / 损坏等细分口径待内核错误码落地后按码细分
  /// （`rust_reader_kernel#11`）。
  Future<BookSource> open({
    required String fileName,
    required Uint8List bytes,
  }) async {
    switch (sniffFormat(fileName: fileName, bytes: bytes)) {
      case FormatKind.epub:
        return _openKernel(kind: FormatKind.epub, fileName: fileName, bytes: bytes);
      case FormatKind.txt:
        return _openKernel(kind: FormatKind.txt, fileName: fileName, bytes: bytes);
      case FormatKind.cbz:
        return _openKernel(kind: FormatKind.cbz, fileName: fileName, bytes: bytes);
      case FormatKind.mobi:
        return _openKernel(kind: FormatKind.mobi, fileName: fileName, bytes: bytes);
      case FormatKind.cbr:
        return CbrSource(fileName: fileName, bytes: bytes);
      case FormatKind.pdf:
        return PdfSource(fileName: fileName, bytes: bytes);
      case FormatKind.unsupported:
        throw const MReaderFormatException(FormatErrorCode.unsupportedFormat);
    }
  }

  /// 打开内核源；成败都给注册表记一笔（体检 / 日志用），失败翻译成
  /// [MReaderFormatException]（用户见中文，内核消息进 `detail`）。
  Future<BookSource> _openKernel({
    required FormatKind kind,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final HighPerfCapability? cap = capabilityFor(kind);
    try {
      final RustKernelSource source =
          await RustKernelSource.open(fileName: fileName, bytes: bytes);
      if (cap != null) highPerf.noteSuccess(cap);
      return source;
    } catch (error) {
      if (cap != null) highPerf.noteFailure(cap);
      // 已经是格式层异常（如 CBZ 空页表 `noImagePages`）→ 原样抛，不重复包装。
      if (error is MReaderFormatException) rethrow;
      throw _mapKernelError(kind, error);
    }
  }

  /// 内核错误 → 格式层异常（`RUST-04` 口径：用户见的中文仍只来自
  /// `error_messages.dart`；内核的中文 `messageZh` 进 `detail` 仅调试）。
  ///
  /// [rk_err.HighPerfErrorKind] 是与 Rust 侧逐值对应的**契约类别**，故这里按
  /// 类别映射、不猜文案；细分口径（加密的 EPUB vs MOBI）用格式种类判。
  static MReaderFormatException _mapKernelError(
    FormatKind kind,
    Object error,
  ) {
    if (error is! rk_err.HighPerfError) {
      return MReaderFormatException(
        FormatErrorCode.corruptFile,
        detail: 'kernel open failed: $error',
      );
    }
    final FormatErrorCode code = switch (error.kind) {
      rk_err.HighPerfErrorKind.encrypted =>
        kind == FormatKind.mobi
            ? FormatErrorCode.encryptedMobi
            : FormatErrorCode.encryptedEpub,
      rk_err.HighPerfErrorKind.missingContainer =>
        FormatErrorCode.missingContainer,
      rk_err.HighPerfErrorKind.io => FormatErrorCode.corruptFile,
      rk_err.HighPerfErrorKind.formatInvalid => FormatErrorCode.corruptFile,
      rk_err.HighPerfErrorKind.cancelled => FormatErrorCode.corruptFile,
      rk_err.HighPerfErrorKind.internal => FormatErrorCode.corruptFile,
    };
    return MReaderFormatException(code, detail: error.messageZh);
  }
}

/// 便捷包装：等价于 `BookRegistry(highPerf: registry).open(...)`。
///
/// 三种取值别混用：
///   · 不给 [registry]（或给 `const BookRegistry()`）→ **走组合根注入点**（生产路径：
///     `main()` 已在 `runApp` 前 `warmUp()` 并写入 [HighPerfRegistryProvider.current]）；
///   · 给 `BookRegistry(highPerf: HighPerfRegistry.fallback())` → **显式无加速层**
///     （与组合根无关；`RUST-10` 对照测试与格式层单测常用）；
///   · 给 `BookRegistry(highPerf: 具体实例)` → 显式指定（对照 / 体检）。
Future<BookSource> openBook({
  required String fileName,
  required Uint8List bytes,
  BookRegistry registry = const BookRegistry(),
}) =>
    registry.open(fileName: fileName, bytes: bytes);

/// 一级（扩展名）+ 二级（魔数）分发（PRD §7.3 二级判定；`FMT-06` 魔数纠偏 + PDF）。
///
/// 规则（自上而下，魔数优先于后缀）：
/// 1. **MOBI 系魔数**（[hasMobiMagic]，PalmDB `BOOKMOBI`）压过**一切**后缀——AZW3
///    头 8 字节是可打印 ASCII（PDB name），改名 `.txt` 不得落纯文本判定（`FMT-06` 验收①）；
/// 1b. **PDF 魔数**（[hasPdfMagic]，文件头 `%PDF`）同样压过后缀（`FMT-01`）；
/// 2. **EPUB**：扩展名 `.epub` 为主——`.zip` / 纯文本 / 坏字节改名 `.epub` 都交给
///    内核给「不是有效 EPUB」的可读提示 = `FMT-06` 验收② 的「明确报错」出口；
/// 3. **CBZ / CBR**：扩展名 `.cbz` / `.cbr`（坏包由各自实现给可读提示；
///    `FMT-03`：CBR 由 `CbrSource` 明确提示暂不支持）；
/// 3b. **PDF 后缀**：非 PDF 字节改名 `.pdf` → 交给 PDF 解析器给可读报错（同 `.epub` 口径）；
/// 4. **TXT**：非 zip 且（扩展名 `.txt` 或字节可判为文本）；
/// 5. 其余：`unsupported`。
///
/// 边界声明：① MOBI 与 AZW3 不做家族内区分（同判据同 kind）；② 非 `BOOKMOBI` 的
/// 其他 PalmDB 落 `unsupported`；③ cbz/cbr 的「纯文本内容」不做纠偏（坏包走可读报错）；
/// ④ PDF 判据只看**偏移 0** 的 `%PDF`（不做「头 1024 字节内搜索」的宽松变体——
/// 宁可落 `unsupported` 也不误开）。
FormatKind sniffFormat({
  required String fileName,
  required Uint8List bytes,
}) {
  final String ext = _extensionOf(fileName);

  // 1. MOBI 系魔数（FMT-06 ①）：先于一切后缀与纯文本判定。
  if (hasMobiMagic(bytes)) return FormatKind.mobi;
  // 1b. PDF 魔数（FMT-01）：与 MOBI 同理，魔数压过后缀——PDF 改名 `.txt` 仍识别为 PDF。
  if (hasPdfMagic(bytes)) return FormatKind.pdf;
  // 2. EPUB：扩展名优先。FMT-06 ② 双出口取「明确报错」——纯文本/坏字节改名
  //    `.epub` 仍交给内核给 notZip 可读报错，不静默改判 TXT（诚实报错优先）。
  if (ext == 'epub') return FormatKind.epub;
  if (ext == 'cbz') return FormatKind.cbz;
  if (ext == 'cbr') return FormatKind.cbr;
  // 3b. PDF 后缀（FMT-01）：非 PDF 字节改名 `.pdf` 也交 PDF 解析器给可读报错
  //     （口径同 `.epub`；`looksLikeZip` 之前，故 zip 改名 `.pdf` 也报「不是有效 PDF」）。
  if (ext == 'pdf') return FormatKind.pdf;
  if (looksLikeZip(bytes)) return FormatKind.unsupported;
  if (ext == 'txt') return FormatKind.txt;
  if (looksLikeText(bytes)) return FormatKind.txt;
  return FormatKind.unsupported;
}

/// 取小写扩展名（不含点）；无扩展名返回空串。
String _extensionOf(String fileName) {
  final String name = fileName.replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  final String base = slash >= 0 ? name.substring(slash + 1) : name;
  final int dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}
