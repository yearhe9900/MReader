// PDF 测试夹具：可编排的假渲染引擎（`FMT-01` 相关测试共享）。
//
// 为什么用假引擎：`PdfSource` 的全部契约（伪分章 / 分页资源键 / 封面 / 错误码映射 /
// dispose）都与「渲染内核」解耦——这正是 `META-10` ③ 注入缝的意义。
// 假引擎让这些契约能**离线、确定性**验证，不需要真 PDF 与原生库
// （真样本冒烟在 `M2b-T09` 用 `tmp_book/小狗钱钱.pdf` 走手工/端到端路径）。
import 'dart:typed_data';

import 'package:mreader/platform/bgra_png.dart';
import 'package:mreader/platform/pdf_engine.dart';

/// 最小「PDF」字节：只需通过 `sniffFormat` 的 `%PDF` 魔数判定。
///
/// 逐字节常量而非字符串编码，避免编码歧义（与 `sniffer.dart` 同写法）。
Uint8List minimalPdfBytes() => Uint8List.fromList(<int>[
      0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, // "%PDF-1.4\n"
      0x25, 0x25, 0x45, 0x4F, 0x46, 0x0A, // "%%EOF\n"
    ]);

/// 可编排的假引擎：记录每次渲染，可注入打开失败 / 渲染失败 / 页文本。
class FakePdfEngine implements PdfEngine {
  FakePdfEngine({
    this.pageCount = 25,
    this.openFailure,
    this.available = true,
    this.renderFailedPages = const <int>{},
    this.texts = const <int, String>{},
    this.pageWidth = 612, // 美制 Letter 的 72dpi 尺寸
    this.pageHeight = 792,
  });

  final int pageCount;

  /// 非空时 `open()` 抛 [PdfEngineOpenException]（模拟加密 / 损坏）。
  final PdfOpenFailure? openFailure;

  final bool available;

  /// 这些页渲染返回 `null`（模拟坏页）。
  final Set<int> renderFailedPages;

  /// 页文本层（`pageText`）。
  final Map<int, String> texts;

  final double pageWidth;
  final double pageHeight;

  /// 观察点。
  int openCount = 0;
  int lastOpenedByteLength = -1;
  int disposeCount = 0;
  final List<int> renderedPages = <int>[];
  final List<int> renderedWidths = <int>[];

  @override
  bool get isAvailable => available;

  @override
  Future<PdfEngineDocument> open(Uint8List bytes) async {
    openCount++;
    lastOpenedByteLength = bytes.length;
    final PdfOpenFailure? failure = openFailure;
    if (failure != null) {
      throw PdfEngineOpenException(failure, detail: 'FakePdfEngine 编排的失败');
    }
    return FakePdfDocument(this);
  }
}

class FakePdfDocument implements PdfEngineDocument {
  FakePdfDocument(this.engine);

  final FakePdfEngine engine;

  @override
  int get pageCount => engine.pageCount;

  @override
  Future<Uint8List?> renderPagePng(int pageIndex, {required int widthPx}) async {
    engine.renderedPages.add(pageIndex);
    engine.renderedWidths.add(widthPx);
    if (pageIndex < 0 || pageIndex >= engine.pageCount) return null;
    if (engine.renderFailedPages.contains(pageIndex)) return null;
    // 用**真实编码器**产出合法 PNG（2×1 纯色）：封面嗅探 / 解码链路验的是真字节，
    // 不是「号称是 PNG」的假头（`kTinyPng` 教训：夹具必须真有效）。
    return encodeBgraToPng(
      solidBgra(width: 2, height: 1, seed: pageIndex),
      width: 2,
      height: 1,
    );
  }

  @override
  Future<String?> pageText(int pageIndex) async => engine.texts[pageIndex];

  @override
  Future<void> dispose() async => engine.disposeCount++;
}

/// 生成纯色 BGRA 位图（测试用；[seed] 决定颜色，便于区分页）。
Uint8List solidBgra({required int width, required int height, int seed = 0}) {
  final Uint8List pixels = Uint8List(width * height * 4);
  final int r = (seed * 37) & 0xFF;
  final int g = (seed * 71 + 20) & 0xFF;
  final int b = (seed * 113 + 40) & 0xFF;
  for (int i = 0; i < pixels.length; i += 4) {
    pixels[i] = b; // B
    pixels[i + 1] = g; // G
    pixels[i + 2] = r; // R
    pixels[i + 3] = 0xFF; // A
  }
  return pixels;
}
