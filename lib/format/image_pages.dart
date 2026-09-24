// 图片页识别判据（CBZ / CBR 共享，M2b-T02）。
//
// 独立于 `CbzSource` / `CbrSource` 两个实现类之外的中立小模块：
// 实现类之间保持**零 import**（格式选择只发生在 `book_registry.dart`），
// 共享判据落本文件，两个实现各自 import。
//
// 白名单与 `epub/zip_paths.dart` 的二进制魔数表对齐但只取图片子集；
// 压缩包里混入的 `ComicInfo.xml` / 目录 / `__MACOSX` 元数据一律排除出页表。

/// 视为「图片页」的扩展名白名单（小写、不含点）。
const Set<String> kImagePageExtensions = <String>{
  'png', 'jpg', 'jpeg', 'jpe', 'gif', 'bmp', 'webp', 'apng',
  'tif', 'tiff', 'avif', 'heic',
};

/// 条目名（小写）是否是图片页（扩展名白名单判据）。
bool isImagePageName(String lowerName) {
  final int dot = lowerName.lastIndexOf('.');
  if (dot < 0 || dot == lowerName.length - 1) return false;
  return kImagePageExtensions.contains(lowerName.substring(dot + 1));
}
