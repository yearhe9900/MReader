// 「现渲染」书源的**原始光栅**出口（PDF 专用能力缝）。
//
// 为什么单独一个接口而不是加进 `BookSource`：`BookSource` 的 `readResource` 语义是
// 「包内条目字节」（CBZ / EPUB 图片都是现成压缩字节，`Image.memory` 正好）；PDF 没有
// 现成字节，只能现渲染。若把 PDF 塞进同一条字节管线，就得为了「形状一致」付一次
// 手写 PNG 编码（整页 1600×2263 上是数百毫秒的纯 CPU：B/R 换位 + deflate + CRC），
// 再让 Flutter 解码回像素——纯属把已经有的像素绕一圈。
//
// 因此做成**可选能力**：实现了本接口的源，阅读页优先取原始像素直通解码；未实现的源
// （CBZ / CBR / EPUB 内嵌图）零改动走原字节路径。阅读页只做 `source is PageRasterSource`
// 判断，不给 `BookSource` 加成员（避免逼所有 fake 跟着改）。
//
// 纯 Dart 纪律：本文件不 import Flutter、不 import `dart:io`——只搬字节。
import '../platform/pdf_engine.dart';

abstract interface class PageRasterSource {
  /// 取 [href] 对应页的原始像素（[widthPx] 为目标像素宽，高度按页宽高比推导）。
  ///
  /// 失败 / 越界 / 已释放一律返回 `null`（阅读页按缺图兜底）；**不抛异常**。
  Future<PdfRasterPage?> renderPageRaster(String href, {required int widthPx});
}
