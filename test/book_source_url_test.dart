// URL 规则测试：`searchUrl` / `exploreUrl` / 各种 `*Url` 字段的结构解析。
//
// 覆盖三个真实坑：
//   1. `{{`…,{'type':''}`}}` 里的 `,{` 是 **JS 字符串内容**，不是请求选项块；
//   2. 选项是「JS 对象字面量」写法（单引号、键名不加引号），标准 JSON 解析会失败；
//   3. `key` / `page` 常常是**裸变量**（写在 JS 里），不是 `{{key}}` 字样。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/source/book_source.dart';
import 'package:mreader/source/url_rule.dart';

BookSource loadShenshi() {
  final String text =
      File('test/fixtures/shenshi.json').readAsStringSync(encoding: utf8);
  return BookSource.fromJson(
    ((jsonDecode(text) as List<dynamic>).single as Map<dynamic, dynamic>)
        .cast<String, dynamic>(),
  );
}

List<String> tokensOf(ParsedUrlRule rule) =>
    rule.placeholders.map((UrlPlaceholder p) => p.token).toList();

void main() {
  group('真实书源的 URL 规则', () {
    test('searchUrl：整条是 {{}} 模板，里面是 base64 自定义协议', () {
      final ParsedUrlRule rule = ParsedUrlRule.parse(loadShenshi().searchUrl!);

      expect(rule.kind, UrlRuleKind.template);
      // 里面的 `,{'type':''}` 属于 JS 字符串内容 —— 不能当请求选项切走
      expect(rule.options, isNull);
      expect(rule.dataUriBase64, isNull);
      expect(rule.notes.any((String n) => n.contains('静态阶段不当作请求选项')), isTrue);
      // key / page 是裸变量
      expect(tokensOf(rule), <String>['key', 'page']);
    });

    test('exploreUrl：整条由 JS 生成', () {
      final ParsedUrlRule rule = ParsedUrlRule.parse(loadShenshi().exploreUrl!);
      expect(rule.kind, UrlRuleKind.js);
      expect(rule.usesJs, isTrue);
      expect(rule.jsCode, isNotNull);
      expect(rule.jsCode!.contains('Object.entries(flfl)'), isTrue);
      expect(rule.notes.any((String n) => n.contains('JS')), isTrue);
    });

    test('ruleSearch.coverUrl：模板 + 单引号选项', () {
      final ParsedUrlRule rule =
          ParsedUrlRule.parse(loadShenshi().ruleSearch!.coverUrl!);

      expect(rule.kind, UrlRuleKind.template);
      expect(rule.template, 'https:{{@@img@src}}');
      // 宽松解析要认得 `{headers:{referer:'…'}}` 这种 JS 对象字面量
      expect(rule.options, isNotNull);
      expect(rule.options!.parsed, isTrue);
      expect(rule.options!.headers, isNotNull);
      expect(rule.options!.headers!.keys, <String>['referer']);
    });

    test('ruleBookInfo.coverUrl 是相对地址', () {
      final ParsedUrlRule rule =
          ParsedUrlRule.parse(loadShenshi().ruleBookInfo!.coverUrl!);
      expect(rule.kind, UrlRuleKind.relative);
      expect(rule.template, 'fm');
      expect(rule.notes.any((String n) => n.contains('相对地址')), isTrue);
    });

    test('ruleSearch.bookUrl / ruleToc.nextTocUrl 都是 JS', () {
      expect(ParsedUrlRule.parse(loadShenshi().ruleSearch!.bookUrl!).kind,
          UrlRuleKind.js);
      expect(ParsedUrlRule.parse(loadShenshi().ruleToc!.nextTocUrl!).kind,
          UrlRuleKind.js);
    });
  });

  group('请求选项 `,{...}`', () {
    test('标准 JSON 选项', () {
      const String rule = 'https://a.com/s,{"method":"POST","charset":"gbk",'
          '"headers":{"Referer":"https://a.com"}}';
      final ParsedUrlRule parsed = ParsedUrlRule.parse(rule);

      expect(parsed.template, 'https://a.com/s');
      expect(parsed.kind, UrlRuleKind.staticUrl);
      expect(parsed.options!.parsed, isTrue);
      expect(parsed.options!.method, 'POST');
      expect(parsed.options!.charset, 'gbk');
      expect(parsed.options!.headers,
          <String, dynamic>{'Referer': 'https://a.com'});
    });

    test('JS 对象字面量写法也能解析（单引号 + 无引号键 + 尾逗号）', () {
      const String rule =
          "https://a.com/s,{headers:{referer:'https://a.com/'},type:'x',}";
      final ParsedUrlRule parsed = ParsedUrlRule.parse(rule);

      expect(parsed.options!.parsed, isTrue);
      expect(parsed.options!.headers, <String, dynamic>{'referer': 'https://a.com/'});
      expect(parsed.options!.type, 'x');
    });

    test('实在解析不了时保留原文并提示，不抛异常', () {
      final ParsedUrlRule parsed =
          ParsedUrlRule.parse('https://a.com/s,{not json at all');
      expect(parsed.options, isNotNull);
      expect(parsed.options!.parsed, isFalse);
      expect(parsed.options!.raw, isNotNull);
      expect(parsed.notes.any((String n) => n.contains('不是合法 JSON')), isTrue);
    });

    test('模板内部的 ,{ 不当选项 —— 否则会把模板撕成两半', () {
      final ParsedUrlRule parsed = ParsedUrlRule.parse('{{`x,{1}`}}');
      expect(parsed.options, isNull);
      expect(parsed.template, '{{`x,{1}`}}');
      expect(parsed.notes.any((String n) => n.contains('静态阶段不当作请求选项')), isTrue);
    });
  });

  group('页码模板 <page,1,2,3>', () {
    test('解析出候选值列表', () {
      final ParsedUrlRule parsed =
          ParsedUrlRule.parse('https://a.com/list_<1,2,3,4>.html');
      expect(parsed.pageValues, <String>['1', '2', '3', '4']);
      expect(parsed.kind, UrlRuleKind.staticUrl);
    });

    test('只有一项时给出「翻页永远同一个值」的提示', () {
      final ParsedUrlRule parsed =
          ParsedUrlRule.parse('https://a.com/list_<1>.html');
      expect(parsed.pageValues, <String>['1']);
      expect(parsed.notes.any((String n) => n.contains('只有一项')), isTrue);
    });
  });

  group('占位符与类型判定', () {
    test('已知占位符写法（{{key}} / \$page 等）', () {
      final ParsedUrlRule parsed =
          ParsedUrlRule.parse('https://a.com/s?q={{key}}&p={{page}}');
      expect(tokensOf(parsed), <String>['{{key}}', '{{page}}']);
      expect(parsed.kind, UrlRuleKind.template);
    });

    test('裸 key / page 变量也能识别，且不与已知写法重复', () {
      final ParsedUrlRule bare =
          ParsedUrlRule.parse(r'@js:base + key + page');
      expect(tokensOf(bare), <String>['key', 'page']);

      final ParsedUrlRule mixed =
          ParsedUrlRule.parse('https://a.com/s?q={{key}}');
      // `{{key}}` 已经认出来了，不该再加一个裸 `key`
      expect(tokensOf(mixed), <String>['{{key}}']);
    });

    test('相对地址', () {
      final ParsedUrlRule parsed = ParsedUrlRule.parse('/search?q=abc');
      expect(parsed.kind, UrlRuleKind.relative);
      expect(parsed.notes.any((String n) => n.contains('相对地址')), isTrue);
    });

    test('data: 自定义协议 —— base64 直接当响应体，不发请求', () {
      final ParsedUrlRule parsed =
          ParsedUrlRule.parse('data:;base64,YWJj,{"type":"ss"}');
      expect(parsed.kind, UrlRuleKind.dataUri);
      expect(parsed.dataUriBase64, 'YWJj');
      expect(parsed.options!.type, 'ss');
      expect(parsed.notes.any((String n) => n.contains('自定义协议')), isTrue);
    });

    test('空规则', () {
      final ParsedUrlRule parsed = ParsedUrlRule.parse('');
      expect(parsed.kind, UrlRuleKind.empty);
      expect(parsed.options, isNull);
      expect(parsed.placeholders, isEmpty);
      expect(parsed.usesJs, isFalse);
    });
  });
}
