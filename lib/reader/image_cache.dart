// 内嵌图片的有界字节缓存（`CNT-01`）。
//
// LRU 淘汰：key = 包内路径（href），value = 原始字节（未解码）。
// 上界按字节估算（默认 50 MB），超限淘汰最久未使用的条目。
//
// ⚠️ 不缓存 `dart:ui` 的 `ui.Image`（#4 已知问题：纯 `test()` 环境构造失败）。
//    图片解码由 Flutter 的 `Image.memory` 内部缓存处理。
import 'dart:collection';
import 'dart:typed_data';

/// 默认最大缓存字节数（50 MB）。
const int kDefaultImageCacheMaxBytes = 50 * 1024 * 1024;

/// 有界 LRU 字节缓存（`CNT-01`）。
///
/// 用法：
///   1. `ImageCache` 由 `ReaderPage` 持有（构造时创建，dispose 时释放）；
///   2. `readResource(href)` 的结果经本缓存后返回——命中即复用，未命中即加载并入库；
///   3. 超限自动淘汰最久未使用的条目。
class ImageCacheLRU {
  ImageCacheLRU({int maxBytes = kDefaultImageCacheMaxBytes})
      // ignore: prefer_initializing_formals
      : _maxBytes = maxBytes;

  final int _maxBytes;

  /// 插入序 = LRU 序（尾 = 最新）。
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap<String, Uint8List>();

  /// 当前缓存总字节数。
  int _currentBytes = 0;

  /// 当前缓存条目数。
  int get length => _cache.length;

  /// 当前缓存字节数（测试用）。
  int get currentBytes => _currentBytes;

  /// 最大缓存字节数（测试用）。
  int get maxBytes => _maxBytes;

  /// 读取缓存；命中时**提升为最近使用**。
  Uint8List? get(String href) {
    final Uint8List? bytes = _cache.remove(href);
    if (bytes != null) {
      _cache[href] = bytes; // 移到尾部（最近使用）
    }
    return bytes;
  }

  /// 写入缓存；已存在时先移除旧条目再重新插入。
  ///
  /// 超限时从头部（最久未使用）开始淘汰，直到腾出足够空间。
  void put(String href, Uint8List bytes) {
    // 移除旧条目（如有）
    if (_cache.containsKey(href)) {
      final Uint8List old = _cache.remove(href)!;
      _currentBytes -= old.length;
    }
    // 淘汰直到腾出空间
    while (_currentBytes + bytes.length > _maxBytes && _cache.isNotEmpty) {
      final String oldest = _cache.keys.first;
      final Uint8List removed = _cache.remove(oldest)!;
      _currentBytes -= removed.length;
    }
    // 插入新条目
    _cache[href] = bytes;
    _currentBytes += bytes.length;
  }

  /// 释放所有缓存。
  void dispose() {
    _cache.clear();
    _currentBytes = 0;
  }
}
