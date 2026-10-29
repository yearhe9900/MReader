// CBR（RAR 归档）解压能力接口（`FMT-03`，`Q5` 退化拍板的**预留升级缝**）。
//
// 为什么只是接口：`Q5`（PRD §14）「CBR 若找不到 rar 解决方案怎么办？退化为『识别 +
// 明确提示』，与加密文件的处理一致，不做半成品」——Dart 生态无 rar 解压（`archive`
// 只到 zip/tar/7z…），故当前**没有任何生产实现**，恒为 [UnavailableRarExtractor]，
// CBR 走 `CbrSource.load()` 抛 `cbrUnsupported` 的「导入即拒绝」路径。将来若接平台
// 通道 / FFI（unarr、libarchive、p7zip 等）实现本接口，注入 `CbrSource(extractor: …)`
// 即可升级为与 CBZ 一致的行为（`FMT-03` ②），调用方与 UI **零改动**。
//
// 纯 Dart：不 import Flutter、不 import `dart:io`。
import 'dart:typed_data';

/// RAR 解压能力。
abstract interface class RarExtractor {
  /// 是否可用（`false` = 本平台/本版本无解压能力，CBR 退化为「识别 + 提示」）。
  bool get isAvailable;

  /// 列出归档内图片条目名（顺序不保证；自然序由调用方负责）。
  Future<List<String>> listImageEntries(Uint8List archiveBytes);

  /// 读取条目原始字节；条目不存在返回 `null`。
  Future<Uint8List?> readEntry(Uint8List archiveBytes, String entryName);
}

/// 默认实现：能力不可用（`Q5` 退化口径的现值）。
class UnavailableRarExtractor implements RarExtractor {
  const UnavailableRarExtractor();

  @override
  bool get isAvailable => false;

  @override
  Future<List<String>> listImageEntries(Uint8List archiveBytes) async =>
      const <String>[];

  @override
  Future<Uint8List?> readEntry(Uint8List archiveBytes, String entryName) async =>
      null;
}
