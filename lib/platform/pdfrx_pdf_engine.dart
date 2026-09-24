// pdfrx 2.6.5 适配器 —— **全仓唯一**直接 `import 'package:pdfrx/...'` 的文件
// （`Q4 ①` 验收①：渲染能力经注入式接口接入，`META-10` ③）。
//
// ## 职责（只做三件事）
//
//   1. 惰性初始化 pdfrx（`pdfrxFlutterInitialize`）；
//   2. 把 pdfrx 的异常**收敛**成 [PdfEngineOpenException]（加密 / 不可读两类），
//      不让第三方异常类型泄漏到格式层（格式层再映射成 `FormatErrorCode`，`RD-05`）；
//   3. 把 `PdfImage`（BGRA8888）编成 PNG 字节并**当场 dispose**（`PERF-02` 非驻留）。
//
// ## 与 pdfrx 交互的关键事实（均读自 pdfrx 2.6.5 / pdfrx_engine 0.6.1 真实源码）
//
//   · `PdfDocument.openData(bytes, …)`：**不传** `passwordProvider` 时，需要密码的
//     PDF 抛 `PdfPasswordException`（`pdfrx_pdfium.dart:849` 实证）——正是 `Q4 ④`
//     「不走输密码链路」的落点；
//   · `PdfPage.render({fullWidth, fullHeight, …})`：**两个必须成对传**。只传
//     `fullWidth` 时 `fullHeight` 会回落到页面 72dpi 高度（源码
//     `fullHeight ??= this.height`），渲染出的位图长宽比是错的；
//   · `PdfImage.pixels` 是 BGRA8888（`pdf_image.dart` 里 `createFromBgraData` 的
//     同一格式），`width/height` 是实际像素尺寸，`dispose()` 必须调；
//   · `PdfPageRawText.fullText` 是整页纯文本（`pdf_text.dart:14`），无文本层时为 null。
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'bgra_png.dart';
import 'pdf_engine.dart';

/// 用 pdfrx 实现 [PdfEngine]（`Q4 ①` 拍板版本 2.6.5）。
class PdfrxPdfEngine implements PdfEngine {
  PdfrxPdfEngine();

  /// 初始化只做一次：`pdfrxFlutterInitialize` 内部虽有 `_isInitialized` 门，
  /// 这里再串一次 Future，防并发首开同时进入（它要做插件绑定与原生库准备）。
  static Future<void>? _initializing;

  static Future<void> _ensureInitialized() =>
      _initializing ??= pdfrx.pdfrxFlutterInitialize();

  @override
  bool get isAvailable => true;

  @override
  Future<PdfEngineDocument> open(Uint8List bytes) async {
    await _ensureInitialized();
    final pdfrx.PdfDocument document;
    try {
      document = await pdfrx.PdfDocument.openData(
        bytes,
        sourceName: 'mreader-pdf',
        // Q4 ④：不接 passwordProvider——需要密码就报错，不做输密码链路。
        firstAttemptByEmptyPassword: true,
      );
    } on pdfrx.PdfPasswordException catch (e) {
      // 需要密码才能打开：明确拒绝（文案在格式层，RD-05）。
      throw PdfEngineOpenException(PdfOpenFailure.encrypted, detail: e.message);
    } on pdfrx.PdfException catch (e) {
      throw PdfEngineOpenException(PdfOpenFailure.unreadable, detail: e.message);
    } catch (e) {
      // 非 pdfrx 自身异常（如原生库加载失败）：按「不可读」收敛，
      // 不把原始栈抛给 UI 层。
      throw PdfEngineOpenException(PdfOpenFailure.unreadable, detail: '$e');
    }

    // 空密码即可打开的「所有者加密」PDF（只限制打印 / 复制）也算加密文档：
    // 按 `Q4 ④`「加密 PDF 明确拒绝」的保守口径一并拒绝。
    //
    // 边界声明：若将来负责人要求放开这类「能直接打开、只带权限限制」的 PDF，
    // 删掉本段即可——格式层与 UI 零改动（这就是注入缝的意义）。
    if (document.isEncrypted) {
      await document.dispose();
      throw const PdfEngineOpenException(
        PdfOpenFailure.encrypted,
        detail: '文档带加密安全处理器（isEncrypted）',
      );
    }
    return _PdfrxDocument(document);
  }
}

class _PdfrxDocument implements PdfEngineDocument {
  _PdfrxDocument(this._document);

  final pdfrx.PdfDocument _document;
  bool _disposed = false;

  @override
  int get pageCount => _document.pages.length;

  @override
  Future<Uint8List?> renderPagePng(int pageIndex, {required int widthPx}) async {
    if (_disposed || widthPx <= 0) return null;
    final List<pdfrx.PdfPage> pages = _document.pages;
    if (pageIndex < 0 || pageIndex >= pages.length) return null;
    final pdfrx.PdfPage page = pages[pageIndex];
    final double pageWidth = page.width;
    if (pageWidth <= 0) return null; // 页面尺寸异常（损坏页）：当缺图处理

    // 高度按页宽高比推导，**与 fullWidth 成对传入**（只传一个会按 72dpi 兜底 → 比例错）。
    final double fullHeight = widthPx * (page.height / pageWidth);
    pdfrx.PdfImage? image;
    try {
      image = await page.render(
        fullWidth: widthPx.toDouble(),
        fullHeight: fullHeight,
      );
    } catch (_) {
      return null; // 渲染失败 = 该页缺图（阅读页图片分支已有缺图兜底），不向上抛
    }
    if (image == null) return null;
    try {
      return encodeBgraToPng(
        image.pixels,
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose(); // PERF-02 ①：渲染位图不驻留（含异常路径）
    }
  }

  @override
  Future<String?> pageText(int pageIndex) async {
    if (_disposed) return null;
    final List<pdfrx.PdfPage> pages = _document.pages;
    if (pageIndex < 0 || pageIndex >= pages.length) return null;
    try {
      final pdfrx.PdfPageRawText? text = await pages[pageIndex].loadText();
      return text?.fullText;
    } catch (_) {
      return null; // 扫描件 / 抽取失败：返回 null（T04 搜索据此跳过该页）
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _document.dispose();
  }
}
