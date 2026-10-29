// `AI-04` ② / `AI-05` ③：摘要缓存持久化与两级缓存键。
//
// 形制照 `vocab_store_test`（临时目录 + 新实例重载验证落盘）。重点钉键的区分度：
// 章级键 = bookId + href + 内容 hash + 模型 + 长度；合并级键 = bookId + 模型 +
// 类型 + 起止章 + inputHash——「缓存键必须能区分生成到第几章」落在起止章上。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/summary_cache.dart';

ChapterSummaryEntry _chapter({
  String bookId = 'b1',
  String href = 'h1',
  String hash = 'aaaa',
  String model = 'm',
  int maxChars = 200,
  String text = '梗概一',
}) =>
    ChapterSummaryEntry(
      bookId: bookId,
      chapterHref: href,
      contentHash: hash,
      model: model,
      maxChars: maxChars,
      text: text,
      updatedAt: 1700000000000,
    );

BookSummaryEntry _book({
  String bookId = 'b1',
  String model = 'm',
  String kind = 'book',
  int from = 0,
  int upto = 9,
  String inputHash = 'ffff',
  String text = '全书摘要',
}) =>
    BookSummaryEntry(
      bookId: bookId,
      model: model,
      kind: kind,
      fromChapter: from,
      uptoChapter: upto,
      inputHash: inputHash,
      text: text,
      updatedAt: 1700000000000,
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mreader_summary_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  SummaryCache newCache() => SummaryCache(dir);

  File cacheFile() =>
      File('${dir.path}${Platform.pathSeparator}summary.json');

  group('summaryContentHash', () {
    test('稳定、区分内容、16 位十六进制', () {
      expect(summaryContentHash('abc'), summaryContentHash('abc'));
      expect(summaryContentHash('abc') == summaryContentHash('abd'), isFalse);
      expect(summaryContentHash('abc'), hasLength(16));
      expect(summaryContentHash('abc'), matches(RegExp(r'^[0-9a-f]{16}$')));
    });
  });

  group('章级缓存', () {
    test('putChapter → 新实例 load：字段保真，落盘为 JSON 对象', () async {
      final SummaryCache cache = newCache();
      await cache.load();
      await cache.putChapter(_chapter(text: '意外之喜'));

      final SummaryCache reloaded = newCache();
      await reloaded.load();
      final ChapterSummaryEntry e =
          reloaded.findChapter(
            bookId: 'b1',
            chapterHref: 'h1',
            contentHash: 'aaaa',
            model: 'm',
            maxChars: 200,
          )!;
      expect(e.text, '意外之喜');
      expect(e.updatedAt, 1700000000000);
      expect(cacheFile().readAsStringSync(), startsWith('{'));
    });

    test('键五维各自区分：任一不同即 miss', () async {
      final SummaryCache cache = newCache();
      await cache.load();
      await cache.putChapter(_chapter());

      ChapterSummaryEntry? probe({
        String bookId = 'b1',
        String href = 'h1',
        String hash = 'aaaa',
        String model = 'm',
        int maxChars = 200,
      }) =>
          cache.findChapter(
            bookId: bookId,
            chapterHref: href,
            contentHash: hash,
            model: model,
            maxChars: maxChars,
          );

      expect(probe(), isNotNull);
      expect(probe(bookId: 'b2'), isNull);
      expect(probe(href: 'h2'), isNull);
      expect(probe(hash: 'bbbb'), isNull);
      expect(probe(model: 'other'), isNull);
      expect(probe(maxChars: 500), isNull); // 长度档不同 = 不同成品
    });

    test('同键 put 覆盖（幂等）；不同键并存', () async {
      final SummaryCache cache = newCache();
      await cache.load();
      await cache.putChapter(_chapter(text: '旧'));
      await cache.putChapter(_chapter(text: '新'));
      expect(cache.chapterEntries, hasLength(1));
      expect(
        cache.findChapter(
          bookId: 'b1',
          chapterHref: 'h1',
          contentHash: 'aaaa',
          model: 'm',
          maxChars: 200,
        )!.text,
        '新',
      );

      await cache.putChapter(_chapter(maxChars: 500, text: '长档'));
      expect(cache.chapterEntries, hasLength(2));
    });
  });

  group('合并级缓存（键含起止章 = 区分生成到第几章）', () {
    test('putBook → 新实例 load：范围与 inputHash 保真', () async {
      final SummaryCache cache = newCache();
      await cache.load();
      await cache.putBook(_book(text: '全书摘要', upto: 29));

      final SummaryCache reloaded = newCache();
      await reloaded.load();
      final BookSummaryEntry? e = reloaded.findBook(
        bookId: 'b1',
        model: 'm',
        kind: 'book',
        fromChapter: 0,
        uptoChapter: 29,
        inputHash: 'ffff',
      );
      expect(e, isNotNull);
      expect(e!.text, '全书摘要');
      expect(e.kind, 'book');
      expect(e.uptoChapter, 29);
    });

    test('键六维区分：起止章 / 类型 / inputHash 任一不同即 miss', () async {
      final SummaryCache cache = newCache();
      await cache.load();
      await cache.putBook(_book()); // book: 0..9

      BookSummaryEntry? probe({
        String model = 'm',
        String kind = 'book',
        int from = 0,
        int upto = 9,
        String inputHash = 'ffff',
      }) =>
          cache.findBook(
            bookId: 'b1',
            model: model,
            kind: kind,
            fromChapter: from,
            uptoChapter: upto,
            inputHash: inputHash,
          );

      expect(probe(), isNotNull);
      expect(probe(kind: 'recap'), isNull); // 回顾与全书是两种成品
      expect(probe(upto: 19), isNull); // 生成到第几章不同 → 不同键
      expect(probe(from: 15), isNull); // 近 N 章窗口移动
      expect(probe(inputHash: 'eeee'), isNull); // 正文变了
      expect(probe(model: 'other'), isNull);

      await cache.putBook(_book(kind: 'recap', from: 5, upto: 9, text: '回顾'));
      expect(cache.bookEntries, hasLength(2)); // 两种成品并存
    });
  });

  group('removeBook（书架删书连带）', () {
    test('删该书章级与合并级，其他书不受影响；不存在则静默', () async {
      final SummaryCache cache = newCache();
      await cache.load();
      await cache.putChapter(_chapter());
      await cache.putChapter(_chapter(bookId: 'b2', href: 'x1', text: '他书'));
      await cache.putBook(_book());
      await cache.putBook(_book(bookId: 'b2'));

      await cache.removeBook('b1');
      expect(cache.chapterEntries.map((ChapterSummaryEntry e) => e.bookId),
          <String>['b2']);
      expect(cache.bookEntries.map((BookSummaryEntry e) => e.bookId),
          <String>['b2']);

      await cache.removeBook('nope'); // 静默，不抛。
      expect(cache.chapterEntries, hasLength(1));

      final SummaryCache reloaded = newCache();
      await reloaded.load();
      expect(reloaded.chapterEntries, hasLength(1));
      expect(reloaded.bookEntries, hasLength(1));
    });
  });

  group('容错与监听', () {
    test('坏条目逐条跳过；损坏文件回退空表', () async {
      cacheFile().writeAsStringSync(
        jsonEncode(<String, Object?>{
          'chapters': <Object?>[
            <String, Object?>{'bookId': 'b1'}, // 缺必填 → 跳过
            _chapter().toJson(),
          ],
          'books': <Object?>['not-a-map', _book().toJson()],
        }),
      );
      final SummaryCache cache = newCache();
      await cache.load();
      expect(cache.chapterEntries, hasLength(1));
      expect(cache.bookEntries, hasLength(1));

      cacheFile().writeAsStringSync('{ 这不是 json');
      final SummaryCache broken = newCache();
      await broken.load();
      expect(broken.chapterEntries, isEmpty);
      expect(broken.bookEntries, isEmpty);
      expect(broken.isLoaded, isTrue);
    });

    test('load 与每次写入都通知监听者', () async {
      final SummaryCache cache = newCache();
      int notified = 0;
      void first() => notified++;
      cache.addListener(first);
      await cache.load();
      expect(notified, 1);
      await cache.putChapter(_chapter());
      expect(notified, 2);
      await cache.putBook(_book());
      expect(notified, 3);
      // 退订后再写入：不再计数（遍历副本不影响退订生效）。
      cache.removeListener(first);
      void second() => notified++;
      cache.addListener(second);
      cache.removeListener(second);
      await cache.putChapter(_chapter(text: '再变'));
      expect(notified, 3);
    });
  });
}
