// `AI-06` 检索层 / `Q6` 关键词口径 / §8.3：BM25 索引单测。
//
// 覆盖：分词口径（ASCII 小写化 + CJK 按字与二元组、标点为分隔符，检索可解释的
// 前提）、章级 BM25（命中章进榜、无命中词返回空、通用词全书命中）、序列化往返
// 不改变检索结果（§8.3 索引本地持久化）、[RagIndex.approxBytes] 估算口径 > 0。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/bm25.dart';

import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。

  group('tokenize 分词口径', () {
    test('ASCII 词元小写化，按非字母数字切分', () {
      expect(tokenize('Hello World 2024'), <String>['hello', 'world', '2024']);
      expect(tokenize('Ab12 cd'), <String>['ab12', 'cd']);
    });

    test('CJK 连续段 = 按字 + 二元组，标点为分隔符', () {
      expect(tokenize('中文'), <String>['中', '中文', '文']);
      expect(tokenize('中文，文！'), <String>['中', '中文', '文', '文']);
      expect(tokenize('Ab中文'), <String>['ab', '中', '中文', '文']);
    });

    test('标点 / 空白不产词元', () {
      expect(tokenize('，。！？ \t\n'), isEmpty);
      expect(tokenize(''), isEmpty);
    });
  });

  group('章级 BM25 打分', () {
    late RagIndexBuilder builder;

    setUp(() {
      builder = RagIndexBuilder()
        ..addChapter('第一章', '猫坐在垫子上。')
        ..addChapter('第二章', '狗在院子里跑。')
        ..addChapter('第三章', '猫在窗台上晒太阳。');
    });

    test('构建统计：章数 / token 总数 / 标题入索引', () {
      final RagIndex index = builder.finish();
      expect(index.docLengths.length, 3);
      expect(index.titles, <String>['第一章', '第二章', '第三章']);
      expect(index.totalTokens, greaterThan(0));
      expect(builder.chapterCount, 3);
      expect(builder.totalTokens, index.totalTokens);
    });

    test('命中「猫」的两章进榜，未命中章不进榜', () {
      final RagIndex index = builder.finish();
      final List<({int chapterIndex, double score})> ranked =
          index.topChapters('猫', 5);
      expect(
        ranked.map((({int chapterIndex, double score}) r) => r.chapterIndex).toSet(),
        <int>{0, 2},
      );
      expect(ranked.first.score, greaterThan(ranked.last.score));
    });

    test('通用词（各章都有）全书进榜', () {
      final RagIndex index = builder.finish();
      final List<({int chapterIndex, double score})> ranked =
          index.topChapters('在', 5);
      expect(
        ranked.map((({int chapterIndex, double score}) r) => r.chapterIndex).toSet(),
        <int>{0, 1, 2},
      );
    });

    test('书内不存在的词 → 空榜（「书中未提及」链路上游）', () {
      final RagIndex index = builder.finish();
      expect(index.topChapters('青蛙', 5), isEmpty);
      expect(index.topChapters('zzz', 5), isEmpty);
      expect(index.topChapters('', 5), isEmpty);
    });

    test('limit 截断 + 同分按下标升序', () {
      final RagIndex index = builder.finish();
      final List<({int chapterIndex, double score})> ranked =
          index.topChapters('猫', 1);
      expect(ranked.length, 1);
      expect(ranked.first.chapterIndex, 0);
    });

    test('空索引退化：恒空榜', () {
      final RagIndex empty = RagIndex.empty();
      expect(empty.topChapters('猫', 5), isEmpty);
      expect(empty.approxBytes, greaterThan(0));
    });
  });

  group('序列化（索引本地持久化形态）', () {
    test('toJson → fromJson 往返不改变检索结果', () {
      final RagIndex index = (RagIndexBuilder()
            ..addChapter('第一章', '猫坐在垫子上。')
            ..addChapter('第二章', '天空很蓝。'))
          .finish();
      final RagIndex? back = RagIndex.fromJson(index.toJson());
      expect(back, isNotNull);
      final RagIndex restored = RagIndex.fromJson(index.toJson())!;
      expect(restored.titles, index.titles);
      expect(restored.docLengths, index.docLengths);
      expect(restored.totalTokens, index.totalTokens);
      expect(
        restored
            .topChapters('猫', 5)
            .map((({int chapterIndex, double score}) r) => r.chapterIndex)
            .toList(),
        index
            .topChapters('猫', 5)
            .map((({int chapterIndex, double score}) r) => r.chapterIndex)
            .toList(),
      );
      expect(restored.approxBytes, greaterThan(0));
    });

    test('结构异常 / 版本不符 → null（调用方回退重建）', () {
      expect(RagIndex.fromJson(null), isNull);
      expect(RagIndex.fromJson(<String, Object?>{'v': 99}), isNull);
      expect(
        RagIndex.fromJson(<String, Object?>{
          'v': 1,
          'titles': <Object?>['x'],
          'lengths': <Object?>['不是数字'],
          'total': 1,
          'postings': <String, Object?>{},
        }),
        isNull,
      );
      expect(
        RagIndex.fromJson(<String, Object?>{
          'v': 1,
          'titles': <Object?>['x'],
          'lengths': <Object?>[1],
          'total': 1,
          'postings': <String, Object?>{'猫': <Object?>[0]}, // 奇数长度
        }),
        isNull,
      );
    });
  });
}
