// PDF 渲染能力接口（`FMT-01` / `META-10` ③，`Q4 ①` 拍板的**注入缝**）。
//
// 为什么是接口（与 `rar_extractor.dart` 同一存在理由）：PRD `META-10` ③「`lib/` 内
// 不直接依赖平台渲染 API（经接口注入）」——格式层（`lib/format/pdf_source.dart`）只认
// 本文件的抽象，换渲染内核只改适配器（`RarExtractor` 的同款升级缝）；测试用假实现
// （`test/format/pdf_fakes.dart`）即可覆盖伪分章 / 进度 / 错误码映射全链；全仓**唯一**
// 直接 `import 'package:pdfrx/...'` 的文件是 `lib/platform/pdfrx_pdf_engine.dart`
// （`Q4 ①` 验收①）。
//
// 纯 Dart 纪律：本文件不 import Flutter、不 import `dart:io`、不 import pdfrx——
// 只描述能力（字节 / 原始像素进，编码图片字节出），格式层继续满足「纯 Dart、可进
// isolate」约束；把原始像素变成可显示位图（`decodeImageFromPixels`）是**阅读页**的事。
import 'dart:typed_data';

/// 打开失败的原因。第三方引擎的异常类型**不向上泄漏**：适配器把 pdfrx 的
/// `PdfPasswordException` / `PdfException` 收敛成本枚举，再由格式层映射成
/// `FormatErrorCode`（`RD-05` 文案唯一来源在 `lib/format/error_messages.dart`）。
enum PdfOpenFailure {
  /// 需要密码才能打开，或文档带加密安全处理器（`Q4 ④`：明确拒绝，不走输密码链路）。
  encrypted,

  /// 非 PDF / 结构损坏 / 引擎无法解析。
  unreadable,
}

/// 引擎侧打开失败（纯类型）。
class PdfEngineOpenException implements Exception {
  const PdfEngineOpenException(this.reason, {this.detail});

  final PdfOpenFailure reason;

  /// 仅调试用（引擎原始报错），**不直接展示给用户**。
  final String? detail;

  @override
  String toString() => 'PdfEngineOpenException(${reason.name})'
      '${detail == null ? '' : '：$detail'}';
}

/// PDF 渲染能力。
abstract interface class PdfEngine {
  /// 是否可用（`false` = 本平台 / 本构建无渲染内核，PDF 退化为「明确提示」）。
  bool get isAvailable;

  /// 打开文档。失败抛 [PdfEngineOpenException]。
  Future<PdfEngineDocument> open(Uint8List bytes);
}

/// 一页的**原始光栅**（未编码像素）。
///
/// 存在的理由：手写 PNG 编码（B/R 换位 + deflate + CRC）在整页 1600×2263 上是
/// 数百毫秒级的纯 CPU 工作，而 Flutter 侧 `decodeImageFromPixels` 能吃原始像素直通
/// 解码——阅读页因此跳过「编码 → 传输 → 解码」三跳，只付一次原生解码。
///
/// [bgra] 是**堆上**的独立副本（不是原生缓冲区视图）：调用方可在任意时刻读，
/// 与文档句柄生命周期无关。
class PdfRasterPage {
  const PdfRasterPage({
    required this.bgra,
    required this.width,
    required this.height,
  });

  /// BGRA8888 像素，行序自上而下、无行填充，长度 = `width * height * 4`。
  final Uint8List bgra;

  final int width;
  final int height;
}

/// 已打开的 PDF 文档句柄。
///
/// **必须 [dispose]**（`PERF-02` 非驻留纪律：打开态持有原生资源，不能随 source 泄漏）。
abstract interface class PdfEngineDocument {
  /// 总页数（`FMT-01` 伪分章的唯一输入）。
  int get pageCount;

  /// 把第 [pageIndex] 页渲染为**原始像素**（阅读页 `decodeImageFromPixels` 直通）。
  ///
  /// [widthPx] 是目标像素宽，高度按页宽高比推导；越界 / 渲染失败返回 `null`
  /// （**不抛异常**——渲染层尽力而为，坏页不炸阅读）；实现内部的原生位图必须当场
  /// 释放，只把堆上副本交出去（`PERF-02` 非驻留）。
  Future<PdfRasterPage?> renderPageRaster(int pageIndex, {required int widthPx});

  /// 把第 [pageIndex] 页渲染为**编码后的图片字节**（PNG）。契约：返回值可直接交
  /// `Image.memory`（与 CBZ 图片页管线同构）；参数与失败口径同 [renderPageRaster]。
  ///
  /// 阅读页已改走 [renderPageRaster]（跳编码）；本方法留给**需要字节**的场合
  /// （搜索 / 导出 / 测试取证）。
  Future<Uint8List?> renderPagePng(int pageIndex, {required int widthPx});

  /// 第 [pageIndex] 页的文本层（`Q4 ②` 拍板：PDF 纳入 `CNT-06` 全书搜索）。
  /// 扫描件等无文本层的情况、以及失败，一律返回 `null`。
  Future<String?> pageText(int pageIndex);

  Future<void> dispose();
}

/// 默认实现：能力不可用（未注入适配器时的兜底）。
class UnavailablePdfEngine implements PdfEngine {
  const UnavailablePdfEngine();

  @override
  bool get isAvailable => false;

  @override
  Future<PdfEngineDocument> open(Uint8List bytes) async =>
      throw const PdfEngineOpenException(
        PdfOpenFailure.unreadable,
        detail: 'PDF 渲染内核未注入（main() 需设置 PdfEngineProvider.current）',
      );
}

/// 组合根注入点（与 pdfrx 自己的 `PdfrxEntryFunctions.instance` 同款模式）：
/// `main()` 一行 `PdfEngineProvider.current = PdfrxPdfEngine();` 完成注入。未注入时
/// PDF 走「暂不支持这种格式」的可读提示（诚实降级），**绝不静默产出空白页**。
/// 测试可用它注入假引擎，或按实例传参给 `PdfSource`（后者优先，不污染全局）。
class PdfEngineProvider {
  PdfEngineProvider._();

  static PdfEngine current = const UnavailablePdfEngine();
}
