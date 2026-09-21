// `META-07`：无封面时的**合成封面**（Flutter 侧，架构 §N.7）。
//
// 按「书名 + 作者 + 主题」运行时绘制（背景取主题色，书名大字居中、作者小字居中于其下），
// **按 cacheKey 缓存**，命中即复用、不重绘；书名 / 作者 / 主题任一变化即失效重建。
//
// 依赖 `dart:ui` + `lib/theme`（`CoverTheme`），属架构 §N.4 表的 Flutter 那半。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/book_meta.dart';
import '../theme/app_theme.dart';

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

/// 默认实现：`dart:ui` 绘制 + 内存缓存（不自建额外字体 / 不引包）。
class CanvasSynthCoverRenderer implements SynthCoverRenderer {
  /// `cacheKey -> 已渲染位图`。
  final Map<String, ui.Image> _cache = <String, ui.Image>{};

  /// 绘制尺寸（逻辑像素；书架上按容器缩放）。
  static const double _width = 600;
  static const double _height = 800;

  @override
  Future<SyntheticCover> render({
    required String title,
    required String author,
    required CoverTheme theme,
  }) async {
    final SyntheticCover ref =
        SyntheticCover(synthCoverCacheKey(title, author, theme));
    if (_cache.containsKey(ref.cacheKey)) {
      return ref; // 命中即复用，不重绘
    }
    final ui.Image image = await _paint(title, author, theme);
    _cache[ref.cacheKey] = image;
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
    for (final ui.Image image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
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
