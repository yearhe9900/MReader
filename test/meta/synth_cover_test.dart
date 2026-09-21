// `lib/meta/synth_cover.dart` 单测：cacheKey 契约 + 命中即复用 + 失效重建。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/meta/synth_cover.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('synthCoverCacheKey（hash(书名 + 作者 + 主题)）', () {
    test('确定性 + 维度变化即变化', () {
      final String a = synthCoverCacheKey('三体', '刘慈欣', CoverTheme.day);
      expect(a, synthCoverCacheKey('三体', '刘慈欣', CoverTheme.day));
      expect(a, isNot(synthCoverCacheKey('三体', '刘慈欣', CoverTheme.night)));
      expect(a, isNot(synthCoverCacheKey('活着', '刘慈欣', CoverTheme.day)));
      expect(a, isNot(synthCoverCacheKey('三体', '余华', CoverTheme.day)));
    });
  });

  group('coverThemeOf', () {
    test('亮 -> day，暗 -> night', () {
      expect(coverThemeOf(Brightness.light), CoverTheme.day);
      expect(coverThemeOf(Brightness.dark), CoverTheme.night);
    });
  });

  group('CanvasSynthCoverRenderer', () {
    test('render 命中缓存不重绘（同一 image 对象）', () async {
      final CanvasSynthCoverRenderer r = CanvasSynthCoverRenderer();
      addTearDown(r.dispose);

      final SyntheticCover first =
          await r.render(title: '三体', author: '刘慈欣', theme: CoverTheme.day);
      final SyntheticCover second =
          await r.render(title: '三体', author: '刘慈欣', theme: CoverTheme.day);

      expect(second.cacheKey, first.cacheKey);
      expect(r.imageOf(first), isNotNull);
      expect(identical(r.imageOf(first), r.imageOf(second)), isTrue,
          reason: '命中 cacheKey 应复用同一张位图');
    });

    test('invalidate 后失效重建', () async {
      final CanvasSynthCoverRenderer r = CanvasSynthCoverRenderer();
      addTearDown(r.dispose);

      final SyntheticCover ref =
          await r.render(title: 'T', author: 'A', theme: CoverTheme.night);
      expect(r.imageOf(ref), isNotNull);
      r.invalidate(ref);
      expect(r.imageOf(ref), isNull, reason: '失效后缓存应移除');

      final SyntheticCover again =
          await r.render(title: 'T', author: 'A', theme: CoverTheme.night);
      expect(again.cacheKey, ref.cacheKey);
      expect(r.imageOf(again), isNotNull);
    });
  });
}
