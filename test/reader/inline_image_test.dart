// 内嵌图片渲染 + 解码缓存测试（`CNT-01`）。
//
// 纯 Dart `test()`（非 `testWidgets`）——图片缓存的逻辑测试不需要 Flutter widget 树。
// `parseContentSpans` 的 WidgetSpan 渲染测试用 `testWidgets`（需要 `tester.pump`）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/image_cache.dart';
import 'package:mreader/typography/typeset.dart';

/// 最小合法 PNG（1×1 透明像素），用于 mock `readResource` 返回。
const List<int> _kTinyPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1×1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // 8-bit RGBA
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, // IDAT chunk
  0x54, 0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02, //
  0x00, 0x01, 0xE5, 0x27, 0xDE, 0xFC, 0x00, 0x00, //
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, // IEND chunk
  0x60, 0x82,
];

final Uint8List _kTinyPng = Uint8List.fromList(_kTinyPngBytes);

void main() {
  group('parseContentSpans', () {
    const TextStyle base = TextStyle(fontSize: 18, height: 1.6);

    Future<Uint8List?> mockResolve(String href) async => _kTinyPng;

    Future<Uint8List?> mockResolveNull(String href) async => null;

    test('无图片标记时走 parseInlineStyles 路径', () {
      final List<InlineSpan> spans =
          parseContentSpans('hello world', base, mockResolve);
      expect(spans.length, 1);
      expect((spans[0] as TextSpan).text, 'hello world');
    });

    test('<img src="cover.jpg"> → 产生含 WidgetSpan 的 spans', () {
      final List<InlineSpan> spans = parseContentSpans(
        '\x00IMG:OEBPS/images/cover.jpg\x00',
        base,
        mockResolve,
      );
      expect(spans.length, 1);
      expect(spans[0], isA<WidgetSpan>());
    });

    test('src 不存在（resolve 返回 null）→ 占位 widget 不崩', () {
      final List<InlineSpan> spans = parseContentSpans(
        '\x00IMG:missing.png\x00',
        base,
        mockResolveNull,
      );
      expect(spans.length, 1);
      expect(spans[0], isA<WidgetSpan>());
    });

    test('<b> + <img> 混合段落 → TextSpan + WidgetSpan 结构正确', () {
      final List<InlineSpan> spans = parseContentSpans(
        'before <b>bold</b> \x00IMG:img.png\x00 after',
        base,
        mockResolve,
      );
      // 期望：TextSpan("before ") + TextSpan("bold", bold) + TextSpan(" ") + WidgetSpan + TextSpan(" after")
      expect(spans.length, greaterThanOrEqualTo(4));
      // 第一个和最后一个是 TextSpan
      expect(spans.first, isA<TextSpan>());
      expect(spans.last, isA<TextSpan>());
      // 中间有 WidgetSpan
      expect(spans.any((s) => s is WidgetSpan), isTrue);
    });

    test('连续图片标记 → 多个 WidgetSpan', () {
      final List<InlineSpan> spans = parseContentSpans(
        '\x00IMG:a.png\x00\x00IMG:b.png\x00',
        base,
        mockResolve,
      );
      expect(spans.length, 2);
      expect(spans[0], isA<WidgetSpan>());
      expect(spans[1], isA<WidgetSpan>());
    });
  });

  group('ImageCacheLRU', () {
    test('基本 get/put', () {
      final ImageCacheLRU cache = ImageCacheLRU(maxBytes: 1024);
      final Uint8List bytes = Uint8List(100);
      cache.put('a.png', bytes);
      expect(cache.get('a.png'), same(bytes));
      expect(cache.length, 1);
    });

    test('get 命中时提升为最近使用', () {
      final ImageCacheLRU cache = ImageCacheLRU(maxBytes: 300);
      cache.put('a.png', Uint8List(100));
      cache.put('b.png', Uint8List(100));
      cache.put('c.png', Uint8List(100));
      // 访问 a 使其成为最近使用
      cache.get('a.png');
      // 再加一个超限 → 淘汰最久未使用的（b）
      cache.put('d.png', Uint8List(100));
      expect(cache.get('b.png'), isNull); // b 被淘汰
      expect(cache.get('a.png'), isNotNull); // a 被提升，未淘汰
    });

    test('超限淘汰：超过 maxBytes 后淘汰旧条目', () {
      final ImageCacheLRU cache = ImageCacheLRU(maxBytes: 250);
      cache.put('a.png', Uint8List(100));
      cache.put('b.png', Uint8List(100));
      // 当前 200 字节，再加 100 → 超限 → 淘汰 a
      cache.put('c.png', Uint8List(100));
      expect(cache.get('a.png'), isNull); // a 被淘汰
      expect(cache.get('b.png'), isNotNull);
      expect(cache.get('c.png'), isNotNull);
    });

    test('put 已存在的 key → 更新值，不重复计数', () {
      final ImageCacheLRU cache = ImageCacheLRU(maxBytes: 1024);
      cache.put('a.png', Uint8List(100));
      cache.put('a.png', Uint8List(200));
      expect(cache.length, 1);
      expect(cache.currentBytes, 200);
    });

    test('dispose 清空所有缓存', () {
      final ImageCacheLRU cache = ImageCacheLRU(maxBytes: 1024);
      cache.put('a.png', Uint8List(100));
      cache.dispose();
      expect(cache.length, 0);
      expect(cache.currentBytes, 0);
    });

    test('maxBytes 上界 = 50MB', () {
      expect(kDefaultImageCacheMaxBytes, 50 * 1024 * 1024);
    });

    test('单条目超大（> maxBytes）→ 仍能存入（淘汰所有旧条目后）', () {
      final ImageCacheLRU cache = ImageCacheLRU(maxBytes: 100);
      cache.put('big.png', Uint8List(200));
      expect(cache.length, 1);
      expect(cache.currentBytes, 200);
    });
  });
}
