// `lib/meta/synth_cover.dart` 单测：cacheKey 契约 + 命中即复用 + 失效重建
// + 缓存有界（LRU 逐出 + dispose）+ 并发同 key 去重。
import 'dart:ui' as ui;

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

    test('默认上限即 kSynthCoverCacheMaxEntries，超出逐出最早的', () async {
      final CanvasSynthCoverRenderer r = CanvasSynthCoverRenderer();
      addTearDown(r.dispose);

      final List<SyntheticCover> refs = <SyntheticCover>[];
      for (int i = 0; i <= kSynthCoverCacheMaxEntries; i++) {
        refs.add(
            await r.render(title: 'book$i', author: 'a$i', theme: CoverTheme.day));
      }

      expect(kSynthCoverCacheMaxEntries, 32, reason: '上限算术依据：32 × 1.92 MB ≈ 61.4 MB');
      expect(r.cachedCount, kSynthCoverCacheMaxEntries,
          reason: '恰好渲染上限 +1 张后，缓存应被夹在上限');
      expect(r.imageOf(refs.first), isNull, reason: '最早的 ref 应被逐出');
      expect(r.imageOf(refs.last), isNotNull);
    });

    test('逐出时位图已 dispose（LRU 有界且不泄漏）', () async {
      const int max = 3;
      final CanvasSynthCoverRenderer r = CanvasSynthCoverRenderer(maxEntries: max);
      addTearDown(r.dispose);

      final List<SyntheticCover> refs = <SyntheticCover>[];
      ui.Image? firstImage;
      for (int i = 0; i <= max; i++) {
        final SyntheticCover ref =
            await r.render(title: 'b$i', author: 'a', theme: CoverTheme.day);
        refs.add(ref);
        if (i == 0) firstImage = r.imageOf(ref);
      }

      expect(r.cachedCount, max);
      expect(r.imageOf(refs.first), isNull);
      expect(firstImage, isNotNull);
      expect(firstImage!.debugDisposed, isTrue,
          reason: '被逐出的位图必须 dispose，否则只是「有界但泄漏」');
    });

    test('命中刷新 LRU：最近使用的不被优先逐出', () async {
      const int max = 3;
      final CanvasSynthCoverRenderer r = CanvasSynthCoverRenderer(maxEntries: max);
      addTearDown(r.dispose);

      final SyntheticCover a =
          await r.render(title: 'A', author: 'x', theme: CoverTheme.day);
      final SyntheticCover b =
          await r.render(title: 'B', author: 'x', theme: CoverTheme.day);
      final SyntheticCover c =
          await r.render(title: 'C', author: 'x', theme: CoverTheme.day);
      // 命中 A：A 升为最近使用，此时 B 最久未用。
      await r.render(title: 'A', author: 'x', theme: CoverTheme.day);

      final SyntheticCover d =
          await r.render(title: 'D', author: 'x', theme: CoverTheme.day);
      expect(r.imageOf(b), isNull, reason: 'B 最久未用，应被逐出');
      expect(r.imageOf(a), isNotNull, reason: 'A 刚被命中，应保留');
      expect(r.imageOf(c), isNotNull);
      expect(r.imageOf(d), isNotNull);
    });

    test('同 key 并发渲染只画一张（in-flight 去重）', () async {
      final CanvasSynthCoverRenderer r = CanvasSynthCoverRenderer();
      addTearDown(r.dispose);

      final List<SyntheticCover> results = await Future.wait(<Future<SyntheticCover>>[
        r.render(title: 'T', author: 'A', theme: CoverTheme.day),
        r.render(title: 'T', author: 'A', theme: CoverTheme.day),
      ]);

      expect(results[0].cacheKey, results[1].cacheKey);
      expect(identical(r.imageOf(results[0]), r.imageOf(results[1])), isTrue,
          reason: '并发同 key 应共享同一张位图，而非各画一张后丢弃其一');
      expect(r.cachedCount, 1);
    });
  });
}
