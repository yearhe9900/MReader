// 开发者实验开关：进程内静态、不落盘（同 `HighPerfRegistry.debugForcePureDart` 口径）。

// 格式层（`book_registry.dart`）直接读这里，避免把 UI 概念层层穿进 `openBook()`；
// 纯 Dart、不 import Flutter / `dart:io`。

/// 开发者实验开关集合。
abstract final class DeveloperOptions {
  /// PDF 是否改用 `rrk-pdf` 内核（L1 文字版重排）。
  ///
  /// 默认 `false` = 保持 pdfrx 固版式图片页。只影响**之后打开**的 PDF：已在
  /// 阅读页里的源不换；书架侧按 `implId` 丢弃旧模式的池驻留源。
  /// ⚠️ 内核章身份是 `pdf:{i}`，与固版式的 `p{n}` 不兼容，切换后该书进度会重新定位。
  static bool pdfUseRustKernel = false;
}
