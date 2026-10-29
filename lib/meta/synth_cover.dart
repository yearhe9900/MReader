// `META-07`：无封面时的**合成封面**（Flutter 侧，架构 §N.7）。
//
// 按「书名 + 作者 + 主题」运行时绘制（背景取主题色，书名大字居中、作者小字居中于其下），
// **按 cacheKey 缓存**，命中即复用、不重绘；书名 / 作者 / 主题任一变化即失效重建。
//
// 缓存**有界**（`META-05`「缓存上限」的另一半）：合成封面是本工程**唯一自建**的位图缓存
// （真实封面只由 `CoverStore` 落盘 / 返回字节，解码去重交给 Flutter 内置 `ImageCache`），
// **必须自带 LRU 上限**（[kSynthCoverCacheMaxEntries]）。两条硬约束缺一即退化成「有界但
// 泄漏」：超限逐出的位图**必须 `ui.Image.dispose()`**；同 key 并发渲染经 in-flight 表
// **共享同一个 future** 只保一张图（失败路径同样从在途表移除，不把失败永久缓存）。
//
// 依赖 `dart:ui` + `lib/theme`（`CoverTheme`），属架构 §N.4 表的 Flutter 那半。
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/book_meta.dart';
import '../theme/app_theme.dart';

/// 合成封面内存缓存的**默认上限**（张）。算术：单张 `600 × 800 px × 4 B/px ≈ 1.92 MB`，
/// `32 × 1.92 MB ≈ 61.4 MB` 最坏常驻——**远高于书架同屏可见的封面数**（手机网格
/// 2~3 列 × 4~6 行 ≈ 6~18 张 + 少量预取），同时给这块**全局唯一自建缓存**设了确定边界。
const int kSynthCoverCacheMaxEntries = 32;

/// `META-07` 的合成封面渲染契约（架构 §N.7，**签名一字不改**）。
abstract interface class SynthCoverRenderer {
  /// 按「书名 + 作者 + 主题」合成；命中 `cacheKey` 则复用，不重复绘制。
  Future<SyntheticCover> render({
    required String title,
    required String author,
    required CoverTheme theme, // 日/夜（由 app_theme 暴露的小枚举）
  });

  /// 主题切换 / 书名作者变更时失效（`META-07`）。
  void invalidate(SyntheticCover ref);
}

/// 合成封面缓存键：`hash(书名 + 作者 + 主题)`（确定性 FNV-1a，跨运行稳定）。
String synthCoverCacheKey(String title, String author, CoverTheme theme) {
  final String raw = '${theme.name}\u0000$title\u0000$author';
  int hash = 0x811C9DC5;
  for (int i = 0; i < raw.length; i++) {
    hash ^= raw.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return 'sc_${hash.toRadixString(16).padLeft(8, '0')}';
}

/// 默认实现：`dart:ui` 绘制 + **有界 LRU** 内存缓存（不自建额外字体 / 不引包）。
class CanvasSynthCoverRenderer implements SynthCoverRenderer {
  /// [maxEntries] 上限可注入（缺省取 [kSynthCoverCacheMaxEntries]），仅作**测试缝**；
  /// 生产路径一律走默认常量。小于 1 归一为 1。
  CanvasSynthCoverRenderer({int maxEntries = kSynthCoverCacheMaxEntries})
      : _maxEntries = maxEntries < 1 ? 1 : maxEntries;

  final int _maxEntries;

  /// `cacheKey -> 已渲染位图`。**保序**：最近使用在尾，最久未用在头（LRU 依据）。
  final LinkedHashMap<String, ui.Image> _cache =
      LinkedHashMap<String, ui.Image>();

  /// `cacheKey -> 在途渲染`。同 key 并发调用共享同一个 future：既不重绘，
  /// 也不产生第二张「后写覆盖、前者永不释放」的悬挂位图。
  final Map<String, Future<ui.Image>> _inFlight = <String, Future<ui.Image>>{};

  bool _disposed = false;

  /// 绘制尺寸（逻辑像素；书架上按容器缩放）。
  static const double _width = 600;
  static const double _height = 800;

  /// 当前缓存张数（供测试观察，不必经 [imageOf] 反推）。
  int get cachedCount => _cache.length;

  @override
  Future<SyntheticCover> render({
    required String title,
    required String author,
    required CoverTheme theme,
  }) async {
    final SyntheticCover ref =
        SyntheticCover(synthCoverCacheKey(title, author, theme));

    // ① 命中缓存：置为最近使用（LRU 尾），不重绘。
    final ui.Image? cached = _cache.remove(ref.cacheKey);
    if (cached != null) {
      _cache[ref.cacheKey] = cached;
      return ref;
    }

    // ② 命中在途：await **同一个** future（不画第二张）。
    Future<ui.Image>? pending = _inFlight[ref.cacheKey];
    if (pending == null) {
      pending = _renderAndCache(ref.cacheKey, title, author, theme);
      _inFlight[ref.cacheKey] = pending;
    }
    await pending;

    // ③ 完成后刷新 LRU 位置——在途命中同样适用，否则「刚渲染完」的项
    //    会因插入点早于其它并发渲染而被当成最久未用。
    final ui.Image? image = _cache.remove(ref.cacheKey);
    if (image != null) _cache[ref.cacheKey] = image;
    return ref;
  }

  /// 取已渲染的位图（供 UI 绘制）；未渲染返回 `null`。
  ui.Image? imageOf(SyntheticCover ref) => _cache[ref.cacheKey];

  @override
  void invalidate(SyntheticCover ref) {
    _cache.remove(ref.cacheKey)?.dispose();
  }

  /// 释放全部缓存位图（页面销毁时调用）。
  void dispose() {
    _disposed = true;
    for (final ui.Image image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
  }

  /// 绘制并写入缓存；**完成（含失败）后从在途表移除**。
  Future<ui.Image> _renderAndCache(
    String key,
    String title,
    String author,
    CoverTheme theme,
  ) async {
    try {
      final ui.Image image = await _paint(title, author, theme);
      _put(key, image);
      return image;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 写入缓存并**逐出到上限**；逐出即 `dispose()`（否则有界却泄漏）。
  void _put(String key, ui.Image image) {
    if (_disposed) {
      image.dispose(); // 渲染期间被 dispose：不留悬挂位图
      return;
    }
    _cache[key] = image;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first)?.dispose();
    }
  }

  Future<ui.Image> _paint(String title, String author, CoverTheme theme) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas =
        Canvas(recorder, const Rect.fromLTWH(0, 0, _width, _height));

    final Color background = theme == CoverTheme.night
        ? const Color(0xFF14142A)
        : AppTheme.seed;
    final Color foreground =
        theme == CoverTheme.night ? const Color(0xFFE8E8F0) : Colors.white;

    canvas.drawRect(
      const Rect.fromLTWH(0, 0, _width, _height),
      Paint()..color = background,
    );
    _paintCentered(canvas, title, foreground, _height * 0.42, 48, FontWeight.bold);
    _paintCentered(canvas, author, foreground.withValues(alpha: 0.85),
        _height * 0.60, 28, FontWeight.normal);

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image =
        await picture.toImage(_width.toInt(), _height.toInt());
    picture.dispose();
    return image;
  }

  /// 单行/多行文本在宽度内居中绘制。
  void _paintCentered(
    Canvas canvas,
    String text,
    Color color,
    double centerY,
    double fontSize,
    FontWeight weight,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 4,
      ellipsis: '…',
    )..layout(maxWidth: _width * 0.8);
    painter.paint(
      canvas,
      Offset((_width - painter.width) / 2, centerY - painter.height / 2),
    );
    painter.dispose();
  }
}
