// 装配 + 分发点（架构文档 §A.1 的 `book_registry.dart` / §A.2）。
//
// **为什么单独一个文件**（架构文档 §A.1 铁律第 3 条）：
// `BookSource` 各实现（Dart / Rust）**互不感知**，选择发生在 [BookRegistry]，
// 实现类之间没有任何 import。若把 `openBook` 写在 `book_source.dart` 里，
// 抽象层就得 import 具体实现，M3.5 加 Rust 实现时该文件会变成所有实现的汇聚点。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'dart:typed_data';

import 'book_source.dart';
import 'cbz_source.dart';
import 'cbr_source.dart';
import 'dart_epub_source.dart';
import 'dart_txt_source.dart';
import 'pdf_source.dart';
import 'sniffer.dart';

// `MReaderFormatException` / `FormatErrorCode` 经 `book_source.dart` 的
// `export 'error_messages.dart';` 转出，不再单独 import（避免重复导入同一个库）。

/// 格式种类。
///
/// [mobi] = MOBI/AZW3（PalmDB `BOOKMOBI` 家族，`FMT-06` ① 识别）；解析器
/// `M2b-T05` 接入，接入前 [BookRegistry.open] 抛 `mobiUnsupported`、导入即拒绝。
/// [pdf] = PDF（`FMT-01`，M2b-T01 接入）：`%PDF` 魔数 / `.pdf` 后缀识别，
/// 渲染内核经 `PdfEngine` 注入（`META-10` ③，见 `lib/platform/pdf_engine.dart`）。
enum FormatKind { epub, txt, cbz, cbr, mobi, pdf, unsupported }

/// 装配 + 分发点。
///
/// M3.5 接入 Rust 时会加可选构造参数 `HighPerfRegistry? highPerf`
/// （架构 §A.2 的 `BookRegistry({HighPerfRegistry? highPerf, ...})`），
/// 由 `main()` 注入；届时「按探测结果择实现」只改本文件的 [open]。
class BookRegistry {
  const BookRegistry();

  /// 按一级（扩展名）+ 二级（魔数）选择实现。
  ///
  /// - `epub` → [DartEpubSource]；
  /// - `txt`  → [DartTxtSource]（M1-T02B 接入）；
  /// - `cbz`  → [CbzSource]（M2b-T02 接入，`FMT-02`）；
  /// - `cbr`  → [CbrSource]（M2b-T02 接入，`FMT-03`：`Q5` 退化「识别 + 明确提示」，
  ///   `load()` 抛 `cbrUnsupported`、导入即拒绝）；
  /// - `pdf`  → [PdfSource]（M2b-T01 接入，`FMT-01`：伪分章 + 连续翻阅 + 缩放；
  ///   渲染内核取组合根注入的 `PdfEngine`，未注入时抛 `unsupportedFormat`）；
  /// - `mobi` → `M2b-T05` 接入解析器；接入前抛 `mobiUnsupported`（导入即拒绝，
  ///   口径与 `unsupportedFormat` 区分：用户能知道「这是 MOBI，还没支持」）；
  /// - `unsupported` → 抛 [MReaderFormatException]（`RD-05`）。
  ///
  /// 返回的永远是 [BookSource] 抽象——调用方无法、也无需知道来源。
  Future<BookSource> open({
    required String fileName,
    required Uint8List bytes,
  }) async {
    switch (sniffFormat(fileName: fileName, bytes: bytes)) {
      case FormatKind.epub:
        return DartEpubSource(fileName: fileName, bytes: bytes);
      case FormatKind.txt:
        return DartTxtSource(fileName: fileName, bytes: bytes);
      case FormatKind.cbz:
        return CbzSource(fileName: fileName, bytes: bytes);
      case FormatKind.cbr:
        return CbrSource(fileName: fileName, bytes: bytes);
      case FormatKind.pdf:
        return PdfSource(fileName: fileName, bytes: bytes);
      case FormatKind.mobi:
        throw const MReaderFormatException(FormatErrorCode.mobiUnsupported);
      case FormatKind.unsupported:
        throw const MReaderFormatException(FormatErrorCode.unsupportedFormat);
    }
  }
}

/// 便捷包装：等价于 `const BookRegistry().open(...)`（**签名与 M1-T02A 冻结时一致**）。
///
/// 测试与 `main()` 用这个；M3.5 后 `main()` 改为持有注入过的 [BookRegistry] 实例。
Future<BookSource> openBook({
  required String fileName,
  required Uint8List bytes,
}) =>
    const BookRegistry().open(fileName: fileName, bytes: bytes);

/// 一级（扩展名）+ 二级（魔数）分发（PRD §7.3 二级判定；`FMT-06` 魔数纠偏，
/// M2b-T03 落地；M2b-T01 追加 PDF）。
///
/// 规则（自上而下，魔数优先于后缀）：
/// 1. **MOBI 系魔数**（[hasMobiMagic]，PalmDB `BOOKMOBI`）压过**一切**后缀
///    ——AZW3 头 8 字节是可打印 ASCII（PDB name），改名 `.txt` 不得落纯文本
///    判定（`FMT-06` 验收①）；
/// 1b. **PDF 魔数**（[hasPdfMagic]，文件头 `%PDF`）同样压过后缀（`FMT-01`）：
///    PDF 改名 `.txt` 不会被纯文本启发式误判（与上一条同口径）；
/// 2. **EPUB**：扩展名 `.epub` 为主——`.zip` / 纯文本 / 坏字节改名 `.epub` 都
///    交给 EPUB 解析器，由它给出「不是有效 EPUB」的可读提示 = `FMT-06` 验收②
///    的「明确报错」出口（「识别为 TXT」出口未取，取舍见函数体注释）；
/// 3. **CBZ / CBR**：扩展名 `.cbz` / `.cbr`（坏包由各自解析器给可读提示；
///    `FMT-03`：CBR 由 `CbrSource` 明确提示暂不支持）；
/// 3b. **PDF 后缀**：非 PDF 字节改名 `.pdf` → 交给 PDF 解析器给可读报错
///    （与 `.epub` 的「明确报错」出口同口径，不落 `unsupported`）；
/// 4. **TXT**：非 zip 且（扩展名 `.txt` 或字节可判为文本）；
/// 5. 其余：`unsupported`。
///
/// 边界声明（M2b-T03 / M2b-T01）：① MOBI 与 AZW3 不做家族内区分（同判据同 kind）；
/// ② 非 `BOOKMOBI` 的其他 PalmDB 落 `unsupported`；③ cbz/cbr 的「纯文本内容」
/// 不做纠偏（不在 `FMT-06` 验收面，坏包走解析器可读报错）；④ PDF 判据只看
/// **偏移 0** 的 `%PDF`（规范要求 header 位于文件起始；不做「头 1024 字节内搜索」
/// 的宽松变体——宁可落 `unsupported` 也不误开）。
FormatKind sniffFormat({
  required String fileName,
  required Uint8List bytes,
}) {
  final String ext = _extensionOf(fileName);

  // 1. MOBI 系魔数（FMT-06 ①）：先于一切后缀与纯文本判定。
  if (hasMobiMagic(bytes)) return FormatKind.mobi;
  // 1b. PDF 魔数（FMT-01，M2b-T01）：与 MOBI 同理，魔数压过后缀——
  //     PDF 改名 `.txt` 仍识别为 PDF（真样本 tmp_book/小狗钱钱.pdf 实证 `%PDF`）。
  if (hasPdfMagic(bytes)) return FormatKind.pdf;
  // 2. EPUB：扩展名优先。FMT-06 ② 双出口取「明确报错」——纯文本/坏字节改名
  //    `.epub` 仍交给 EPUB 解析器给 notZip 可读报错，不静默改判 TXT（诚实报错
  //    优先）；既有锁 dart_epub_source_test「非 zip 字节 + .epub → notZip 文案」
  //    保持不动。若改走「识别为 TXT」出口，须同步推翻该测试并更新此处注释。
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
