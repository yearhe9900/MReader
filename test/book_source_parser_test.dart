// 导入解析测试：`BookSourceParser` 的容错边界。
//
// 设计前提：导入是**用户第一次接触书源的入口**，它面对的输入完全不可控 ——
// 从聊天软件里转发过来的 JSON 可能被截断、带 BOM、混着别的书源站的格式。
// 所以这里的要求是「**永不抛异常**」：能救的救（跳过坏记录），救不了的给出可读原因。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/source/book_source.dart';
import 'package:mreader/source/book_source_parser.dart';

String loadShenshiText() =>
    File('test/fixtures/shenshi.json').readAsStringSync(encoding: utf8);

void main() {
  group('真实书源', () {
    test('单条书源完整导入，无跳过无去重', () {
      final BookSourceImportResult result =
          BookSourceParser.parse(loadShenshiText());

      expect(result.sources, hasLength(1));
      expect(result.skipped, isEmpty);
      expect(result.rawCount, 1);
      expect(result.duplicateCount, 0);
      expect(result.isEmpty, isFalse);
      expect(result.summary, '解析 1 条，成功 1 条');

      final BookSource source = result.sources.single;
      expect(source.bookSourceName, '🌈绅士漫画');
      expect(source.bookSourceType, BookSourceType.image);
      expect(source.ruleSearch, isNotNull);
    });
  });

  group('三种根结构', () {
    test('数组（legado 导出的标准形式）', () {
      final BookSourceImportResult result =
          BookSourceParser.parse(loadShenshiText());
      expect(result.sources, hasLength(1));
    });

    test('单个对象', () {
      final BookSourceImportResult result =
          BookSourceParser.parse('{"bookSourceUrl":"https://a.com"}');
      expect(result.sources, hasLength(1));
      expect(result.rawCount, 1);
    });

    test('包一层 bookSources 的对象', () {
      final BookSourceImportResult result = BookSourceParser.parse(
          '{"bookSources":[{"bookSourceUrl":"https://a.com"},'
          '{"bookSourceUrl":"https://b.com"}]}');
      expect(result.sources, hasLength(2));
      expect(result.sources.map((BookSource s) => s.bookSourceUrl),
          <String>['https://a.com', 'https://b.com']);
    });
  });

  group('去重', () {
    test('按 bookSourceUrl 去重，同一地址只留第一条', () {
      final BookSourceImportResult result = BookSourceParser.parse(
          '[{"bookSourceUrl":"https://a.com","bookSourceName":"第一"},'
          '{"bookSourceUrl":"https://a.com","bookSourceName":"第二"}]');

      expect(result.sources, hasLength(1));
      expect(result.sources.single.bookSourceName, '第一');
      expect(result.duplicateCount, 1);
      expect(result.rawCount, 2);
      expect(result.summary, '解析 2 条，成功 1 条，去重 1 条');
    });
  });

  group('脏输入不抛异常', () {
    test('JSON 语法错误 → 0 条成功 + 1 条 skipped', () {
      final BookSourceImportResult result = BookSourceParser.parse('{oops');

      expect(result.sources, isEmpty);
      expect(result.skipped, hasLength(1));
      expect(result.isEmpty, isTrue);
      expect(result.skipped.single.reason, isNotEmpty);
      expect(result.summary.contains('跳过 1 条'), isTrue);
    });

    test('空串 / 只有空白', () {
      expect(BookSourceParser.parse('').sources, isEmpty);
      expect(BookSourceParser.parse('   ').sources, isEmpty);
    });

    test('顶层是数字 / 字符串 / null', () {
      expect(BookSourceParser.parse('123').sources, isEmpty);
      expect(BookSourceParser.parse('"hello"').sources, isEmpty);
      expect(BookSourceParser.parse('null').sources, isEmpty);
    });

    test('数组元素类型不对时跳过该条，不影响其他条', () {
      final BookSourceImportResult result = BookSourceParser.parse(
          '[1,"x",null,{"bookSourceUrl":"https://a.com"}]');

      expect(result.sources, hasLength(1));
      expect(result.skipped, hasLength(3));
      expect(result.rawCount, 4);
    });

    test('缺 bookSourceUrl 的记录被跳过，整批不炸', () {
      final BookSourceImportResult result = BookSourceParser.parse(
          '[{"bookSourceUrl":"https://a.com"},{"bookSourceName":"x"}]');

      expect(result.sources, hasLength(1));
      expect(result.skipped, hasLength(1));
      expect(result.rawCount, 2);
      expect(result.skipped.single.index, 1);
    });

    test('bookSourceUrl 是空白串也算无效', () {
      final BookSourceImportResult result = BookSourceParser.parse(
          '[{"bookSourceUrl":"   "},{"bookSourceUrl":"https://a.com"}]');
      expect(result.sources, hasLength(1));
      expect(result.skipped, hasLength(1));
    });

    test('单条里字段类型全乱也不影响导入', () {
      final BookSourceImportResult result = BookSourceParser.parse(
          '[{"bookSourceUrl":"https://a.com","bookSourceType":"2",'
          '"enabled":"true","customOrder":null,"ruleSearch":"不是对象"}]');

      expect(result.sources, hasLength(1));
      final BookSource source = result.sources.single;
      expect(source.bookSourceType, BookSourceType.image);
      expect(source.enabled, isTrue);
      expect(source.customOrder, 0);
      // 规则组类型不对时按「未配置」处理，不能崩
      expect(source.ruleSearch, isNull);
    });

    test('skipped 记录带下标与片段，便于定位', () {
      final BookSourceImportResult result = BookSourceParser.parse(
          '[{"bookSourceUrl":"https://a.com"},{"bookSourceName":"没有地址"}]');

      final SkippedRecord record = result.skipped.single;
      expect(record.index, 1);
      expect(record.reason, isNotEmpty);
      expect(record.preview, contains('没有地址'));
      expect(record.toString(), contains('第 1 条'));
    });
  });

  group('导出再导入', () {
    test('toJsonString 的输出能被自己解析回来', () {
      final BookSourceImportResult first =
          BookSourceParser.parse(loadShenshiText());
      final String exported = first.sources.single.toJsonString();

      final BookSourceImportResult second = BookSourceParser.parse(exported);
      expect(second.sources, hasLength(1));
      expect(second.skipped, isEmpty);

      final BookSource a = first.sources.single;
      final BookSource b = second.sources.single;
      expect(b.bookSourceUrl, a.bookSourceUrl);
      expect(b.ruleToc!.chapterList, a.ruleToc!.chapterList);
      expect(b.ruleContent!.extras, a.ruleContent!.extras);
    });

    test('导出的文本是合法 JSON 数组', () {
      final BookSourceImportResult result =
          BookSourceParser.parse(loadShenshiText());
      final Object? decoded = jsonDecode(result.sources.single.toJsonString());
      expect(decoded, isA<List<dynamic>>());
      expect((decoded! as List<dynamic>).single, isA<Map<dynamic, dynamic>>());
    });
  });
}
