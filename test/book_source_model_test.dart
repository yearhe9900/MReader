// 书源**模型**测试：把真实书源（`test/fixtures/shenshi.json`）以及若干人造脏数据
// 喂进 `BookSource.fromJson`，验证字段解析、容错与「导入 → 导出」往返。
//
// 夹具说明：`shenshi.json` 是一个真实的 legado **漫画**书源（绅士漫画），
// 它的价值在于「脏」得很有代表性 —— 中文域名、已废弃的 `isPay` 键、
// 未建模的 `ruleContent.title`、空串当「未配置」用。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/source/book_source.dart';

/// 读取真实书源，返回唯一那条 [BookSource]。
BookSource loadShenshi() {
  final String text =
      File('test/fixtures/shenshi.json').readAsStringSync(encoding: utf8);
  final List<dynamic> list = jsonDecode(text) as List<dynamic>;
  return BookSource.fromJson(
    (list.single as Map<dynamic, dynamic>).cast<String, dynamic>(),
  );
}

void main() {
  group('BookSource 基本字段', () {
    test('顶层 25 个字段全部落地，没有落进 extras', () {
      final BookSource source = loadShenshi();

      expect(source.bookSourceUrl, 'https://绅士漫画.luoyacheng.ip-ddns.com');
      expect(source.bookSourceName, '🌈绅士漫画');
      expect(source.bookSourceType, BookSourceType.image);
      expect(source.customOrder, 20);
      expect(source.enabled, isTrue);
      expect(source.enabledExplore, isTrue);
      expect(source.enabledCookieJar, isFalse);
      expect(source.respondTime, 180000);
      expect(source.lastUpdateTime, 1745396736459);
      expect(source.weight, 0);
      expect(source.concurrentRate, '6/1200');
      expect(source.loginUrl, isNotNull);
      expect(source.jsLib, isNotNull);
      expect(source.searchUrl, isNotNull);
      expect(source.exploreUrl, isNotNull);
      expect(source.header, isNotNull);

      // 25 个键全部建模，extras 必须是空的 —— 否则说明模型漏了键。
      expect(source.extras, isEmpty);
    });

    test('displayName 优先用名称，回退主机名', () {
      expect(loadShenshi().displayName, '🌈绅士漫画');

      final BookSource noName =
          BookSource.fromJson(<String, dynamic>{'bookSourceUrl': 'https://a.com'});
      expect(noName.displayName, 'a.com');
      expect(noName.bookSourceName, '');
    });

    test('中文域名（IDN）主机名要 decode 回可读形式', () {
      final BookSource source = loadShenshi();

      // `Uri.parse(...).host` 拿到的是 `%E7%BB%85%E5%A3%AB...`，
      // 直接用会显示成一串乱码，所以模型层做了一次 decode。
      expect(source.host, '绅士漫画.luoyacheng.ip-ddns.com');
      expect(source.host.contains('%'), isFalse);
    });

    test('组名按逗号拆分并去掉空格', () {
      expect(loadShenshi().groups, <String>['🙈', '🎨', '绅士漫画']);

      final BookSource spaced = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.com',
        'bookSourceGroup': ' A , B ,, C ',
      });
      expect(spaced.groups, <String>['A', 'B', 'C']);
    });

    test('concurrentRate 解析成 (并发, 间隔)，非法格式返回 null', () {
      expect(loadShenshi().parsedConcurrentRate, (6, 1200));

      BookSource withRate(String? rate) => BookSource.fromJson(<String, dynamic>{
            'bookSourceUrl': 'https://a.com',
            'concurrentRate': ?rate,
          });

      expect(withRate(null).parsedConcurrentRate, isNull);
      expect(withRate('').parsedConcurrentRate, isNull);
      expect(withRate('6').parsedConcurrentRate, isNull);
      expect(withRate('6/').parsedConcurrentRate, isNull);
      expect(withRate('a/b').parsedConcurrentRate, isNull);
      expect(withRate(' 3 / 500 ').parsedConcurrentRate, (3, 500));
    });
  });

  group('脏数据容错', () {
    test('字符串 "true" 当布尔用', () {
      final BookSource source = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.com',
        'enabled': 'true',
        'enabledExplore': 'false',
        'enabledCookieJar': 0,
      });
      expect(source.enabled, isTrue);
      expect(source.enabledExplore, isFalse);
      expect(source.enabledCookieJar, isFalse);
    });

    test('两个开关的缺省值是 true，只有显式 false 才关', () {
      final BookSource source =
          BookSource.fromJson(<String, dynamic>{'bookSourceUrl': 'https://a.com'});
      expect(source.enabled, isTrue);
      expect(source.enabledExplore, isTrue);
      expect(source.enabledCookieJar, isTrue);
      expect(source.respondTime, 180000);
    });

    test('bookSourceType 支持数字与字符串，未知值退回「文本」', () {
      BookSource withType(Object? type) => BookSource.fromJson(<String, dynamic>{
            'bookSourceUrl': 'https://a.com',
            'bookSourceType': type,
          });

      expect(withType(2).bookSourceType, BookSourceType.image);
      expect(withType('2').bookSourceType, BookSourceType.image);
      expect(withType(99).bookSourceType, BookSourceType.text);
      expect(withType(null).bookSourceType, BookSourceType.text);
      expect(withType('漫画').bookSourceType, BookSourceType.text);
    });

    test('空字符串等同「未配置」，归一化成 null', () {
      final BookSource source = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.com',
        'bookUrlPattern': '',
        'header': '',
        'exploreUrl': '',
      });
      expect(source.bookUrlPattern, isNull);
      expect(source.header, isNull);
      expect(source.exploreUrl, isNull);
      // 导出时不该写出这些空键
      expect(source.toJson().containsKey('header'), isFalse);
      expect(source.toJson().containsKey('exploreUrl'), isFalse);
    });

    test('数值写成字符串 / null 时走 fallback', () {
      final BookSource source = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.com',
        'customOrder': '7',
        'respondTime': null,
        'lastUpdateTime': 'abc',
      });
      expect(source.customOrder, 7);
      expect(source.respondTime, 180000);
      expect(source.lastUpdateTime, 0);
    });

    test('规则组缺失或为空时，对应字段是 null 而不是空对象', () {
      final BookSource source =
          BookSource.fromJson(<String, dynamic>{'bookSourceUrl': 'https://a.com'});
      expect(source.ruleSearch, isNull);
      expect(source.ruleBookInfo, isNull);
      expect(source.ruleToc, isNull);
      expect(source.ruleContent, isNull);
      expect(source.ruleExplore, isNull);
      expect(source.ruleGroups, isEmpty);
    });
  });

  group('legado 新旧键兼容', () {
    test('ruleToc 的 isVip 同时承接旧键 isPay', () {
      final BookSource old = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.com',
        'ruleToc': <String, dynamic>{'chapterList': 'a', 'isPay': 'true'},
      });
      expect(old.ruleToc!.isVip, 'true');

      final BookSource fresh = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.com',
        'ruleToc': <String, dynamic>{'chapterList': 'a', 'isVip': '1'},
      });
      expect(fresh.ruleToc!.isVip, '1');

      // 新键优先
      final BookSource both = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.com',
        'ruleToc': <String, dynamic>{'isVip': 'new', 'isPay': 'old'},
      });
      expect(both.ruleToc!.isVip, 'new');
    });

    test('真实书源里的 isPay 是空串，因此 isVip 为 null', () {
      final BookSource source = loadShenshi();
      expect(source.ruleToc!.isVip, isNull);
      expect(source.ruleToc!.isVolume, isNull);
    });
  });

  group('未建模字段与往返', () {
    test('未知键留在 extras，不会在导入→导出链路里丢', () {
      final BookSource source = loadShenshi();
      expect(source.ruleContent!.extras.keys, <String>['title']);
      expect(source.ruleContent!.toJson().containsKey('title'), isTrue);
    });

    test('toJsonString → fromJson 往返后关键字段一致', () {
      final BookSource source = loadShenshi();
      final List<dynamic> round =
          jsonDecode(source.toJsonString()) as List<dynamic>;
      final BookSource back = BookSource.fromJson(
        (round.single as Map<dynamic, dynamic>).cast<String, dynamic>(),
      );

      expect(back.bookSourceUrl, source.bookSourceUrl);
      expect(back.bookSourceName, source.bookSourceName);
      expect(back.bookSourceType, source.bookSourceType);
      expect(back.concurrentRate, source.concurrentRate);
      expect(back.groups, source.groups);
      expect(back.ruleToc!.isVip, source.ruleToc!.isVip);
      expect(back.ruleContent!.extras, source.ruleContent!.extras);
      expect(back.ruleSearch!.bookList, source.ruleSearch!.bookList);
      expect(back.searchUrl, source.searchUrl);
      expect(back.jsLib, source.jsLib);
      expect(back.extras, isEmpty);
    });
  });

  group('规则组统一视图', () {
    test('已建模的 5 个组按「搜索/详情/目录/正文/发现」顺序出现', () {
      final BookSource source = loadShenshi();
      expect(
        source.ruleGroups.map((SourceRuleGroup g) => g.key),
        <String>['ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent', 'ruleExplore'],
      );
      expect(
        source.ruleGroups.map((SourceRuleGroup g) => g.label),
        <String>['搜索', '详情', '目录', '正文', '发现'],
      );
    });

    test('configuredCount 反映真实配置情况', () {
      final BookSource source = loadShenshi();
      final Map<String, int> configured = <String, int>{
        for (final SourceRuleGroup g in source.ruleGroups) g.key: g.configuredCount,
      };

      // 真实值：搜索 9/10、详情 4/10、目录 6/9、正文 1/7、发现 0/9
      expect(configured['ruleSearch'], 9);
      expect(configured['ruleBookInfo'], 4);
      expect(configured['ruleToc'], 6);
      expect(configured['ruleContent'], 1);
      expect(configured['ruleExplore'], 0);
    });

    test('发现组存在但全空 —— isEmpty 为真', () {
      final BookSource source = loadShenshi();
      final SourceRuleGroup explore = source.ruleGroups
          .firstWhere((SourceRuleGroup g) => g.key == 'ruleExplore');
      expect(explore.isEmpty, isTrue);
      expect(explore.fields.every((SourceRuleField f) => !f.isConfigured), isTrue);
    });
  });
}
