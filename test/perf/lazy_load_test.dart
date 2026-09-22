// `PERF-02`（懒加载内存收敛）/ `PERF-03`（逐段渲染）的**纯 Dart** 验收。
//
// ⚠️ 一律用 `test()` 而非 `testWidgets`：本项目已两次实证 `testWidgets` 测试体内
// `await` 真异步 IO 会挂死（FakeAsync 不排空微任务队列），详见 `68578e4` /
// `docs/tech-usage.md`。故「有界缓存 + 增量加载」逻辑抽到 `lib/reader/chapter_cache.dart`
// （纯 Dart），在此直接对**真实 source** 驱动并断言。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/model/chapter.dart';
import 'package:mreader/model/chapter_content.dart';
import 'package:mreader/reader/chapter_cache.dart';

import '../../tool/perf_fixtures.dart';

void main() {
  group('PERF-02 懒加载（内存收敛）', () {
    test('打开 300+ 章 EPUB：已加载章数 ≤ 上界常量，且远小于总章数', () async {
      final Uint8List bytes = buildEpub(chapters: 320);
      final DartEpubSource source =
          DartEpubSource(fileName: 'big.epub', bytes: bytes);
      addTearDown(source.dispose);

      final List<Chapter> chapters = await source.chapters();
      expect(chapters.length, greaterThanOrEqualTo(300));

      final ChapterAutoLoader loader = ChapterAutoLoader(
        chapterCount: chapters.length,
        loadContent: source.content,
      );

      // 首帧批次：只等「目标章 ±1」。
      await loader.loadFirstBatch(0);
      expect(loader.cache.count, lessThanOrEqualTo(3));

      // 后台补齐「当前窗口」（半径内、近的先载），直到窗口内全部驻留。
      int batches = 0;
      while (await loader.fillOnce(0)) {
        batches++;
        expect(batches, lessThan(1000), reason: '补齐循环应能在有限批内停下');
      }

      // 关键断言（`PERF-02`）：驻留章数受上界约束，**不是**全书。
      expect(loader.cache.count, lessThanOrEqualTo(kMaxLoadedChapters));
      expect(loader.cache.count, lessThan(chapters.length));
    });

    test('非章节资源（图片）不常驻：window 中心处的驻留仍 ≤ 上界', () async {
      final Uint8List bytes = buildEpub(
        chapters: 300,
        imageCount: 6,
        imageBytesEach: 2 * 1024 * 1024,
      );
      final DartEpubSource source =
          DartEpubSource(fileName: 'img.epub', bytes: bytes);
      addTearDown(source.dispose);

      final List<Chapter> chapters = await source.chapters();
      final ChapterAutoLoader loader = ChapterAutoLoader(
        chapterCount: chapters.length,
        loadContent: source.content,
      );

      const int center = 150;
      await loader.loadFirstBatch(center);
      while (await loader.fillOnce(center)) {}

      expect(loader.cache.count, lessThanOrEqualTo(kMaxLoadedChapters));
      // 窗口内应能直接读到正文（不是空）。
      expect(loader.cache.contains(center), isTrue);
      final ChapterContent? c = loader.cache.peek(center);
      expect(c, isNotNull);
      expect(c!.paragraphList, isNotEmpty);
    });

    test('LRU：小上界下连续放入会被淘汰，驻留数不超过上界', () {
      final ChapterCache cache = ChapterCache(maxLoaded: 5);
      for (int i = 0; i < 50; i++) {
        cache.put(i, ChapterContent.paragraphs(<String>['p$i']));
      }
      expect(cache.count, 5);
      // 最近的 5 个（45..49）应留下，最早的被淘汰。
      expect(cache.contains(49), isTrue);
      expect(cache.contains(0), isFalse);
    });
  });

  group('PERF-03 逐段渲染', () {
    test('10 万+ 字符单章：能取到段落，且是逐段结构（多段），非一条巨型文本', () async {
      final Uint8List bytes =
          buildLongChapterEpub(paragraphs: 1200, charsPerParagraph: 100);
      final DartEpubSource source =
          DartEpubSource(fileName: 'long.epub', bytes: bytes);
      addTearDown(source.dispose);

      final List<Chapter> chapters = await source.chapters();
      expect(chapters.length, 1);

      final ChapterContent content = await source.content(0);
      final List<String> paragraphs = content.paragraphList;

      // 逐段：段数很多（≥ 1000），且总字符数 ≥ 10 万。
      expect(paragraphs.length, greaterThan(1000));
      final int total =
          paragraphs.fold<int>(0, (int a, String p) => a + p.length);
      expect(total, greaterThan(100000));
      // 没有任何一段等于整章（即不是「一条巨型文本」）。
      expect(paragraphs.any((String p) => p.length == total), isFalse);
    });
  });
}
