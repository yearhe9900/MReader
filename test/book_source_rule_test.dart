// 规则解析测试：组合符拆分、JS 切分顺序、元素/索引/提取器、替换链、模板。
//
// 这里覆盖了三个**参考实现会踩、但本实现纠正了**的点，每条都有原始 legado 源码依据：
//   1. JS 切分必须**先于**组合符拆分（`AnalyzeRule.splitSourceRule`）——
//      否则 `if (a && b)` 会被 `&&` 切碎；
//   2. `!` 是**索引块里的排除标记**，不是「整条规则取反」（`AnalyzeJSoup.findIndexSet`）；
//   3. 行首 `-` / `+` 只属于**列表规则**，legado 在进规则引擎前就剥掉了
//      （`BookList.kt:90` / `BookChapterList.kt:75`）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/source/book_source.dart';
import 'package:mreader/source/rule_analyzer.dart';
import 'package:mreader/source/source_rule.dart';

BookSource loadShenshi() {
  final String text =
      File('test/fixtures/shenshi.json').readAsStringSync(encoding: utf8);
  return BookSource.fromJson(
    ((jsonDecode(text) as List<dynamic>).single as Map<dynamic, dynamic>)
        .cast<String, dynamic>(),
  );
}

RuleSegment seg(String rule) => RuleSegment.fromString(rule);

void main() {
  group('RuleAnalyzer 组合符拆分', () {
    test('顶层 && / || / %% 会被切开', () {
      expect(RuleAnalyzer.splitRule('.a@text&&.b@text').parts,
          <String>['.a@text', '.b@text']);
      expect(RuleAnalyzer.splitRule('.a@text&&.b@text').combinator,
          RuleCombinator.and);

      expect(RuleAnalyzer.splitRule('.a@text||.b@text').parts,
          <String>['.a@text', '.b@text']);
      expect(RuleAnalyzer.splitRule('.a@text||.b@text').combinator,
          RuleCombinator.or);

      final RuleSplit interleave = RuleAnalyzer.splitRule('.a@text%%!/.b@text');
      expect(interleave.parts, <String>['.a@text', '!/.b@text']);
      expect(interleave.combinator, RuleCombinator.interleave);
    });

    test('括号 / 引号内部的组合符**不能**切', () {
      const String css = '.a[data-x="p&&q"]@text';
      expect(RuleAnalyzer.splitRule(css).parts, <String>[css]);
      expect(RuleAnalyzer.splitRule(css).combinator, RuleCombinator.none);

      const String jsonPath = r'$.data.list[?(@.id==1 && @.x)]@name';
      expect(RuleAnalyzer.splitRule(jsonPath).parts, <String>[jsonPath]);

      const String xpath = '//div[@class="a||b"]/text()';
      expect(RuleAnalyzer.splitRule(xpath).parts, <String>[xpath]);

      const String quoted = "a[href*='&&']@href";
      expect(RuleAnalyzer.splitRule(quoted).parts, <String>[quoted]);
    });

    test('括号不平衡的脏规则退化成单条，不抛异常', () {
      const String broken = '.a[unclosed&&.b@text';
      expect(() => RuleAnalyzer.splitRule(broken), returnsNormally);
      expect(RuleAnalyzer.splitRule(broken).parts, <String>[broken]);
    });

    test('空串拆出空列表，不抛异常', () {
      expect(RuleAnalyzer.splitRule('').parts, isEmpty);
    });
  });

  group('ParsedSourceRule 阶段切分', () {
    test('JS 优先于组合符：<js> 里的 && / || 不会被切碎', () {
      const String rule = '<js>\nif (a && b || c) { result = x; }\n</js>';
      final ParsedSourceRule parsed = ParsedSourceRule.parse(rule);

      // 若先按组合符拆，这里会变成 3 个普通段 —— 那就是参考实现的 bug。
      expect(parsed.stages.length, 1);
      expect(parsed.stages.single.isJs, isTrue);
      expect(parsed.segments, isEmpty);
      expect(parsed.jsBlocks, hasLength(1));
      expect(parsed.jsBlocks.single.contains('a && b || c'), isTrue);
    });

    test('普通段 + JS 段的两段式：isMixed 为真', () {
      final ParsedSourceRule parsed =
          ParsedSourceRule.parse('a@href@js:baseUrl + result');
      expect(parsed.stages.length, 2);
      expect(parsed.stages.first.isJs, isFalse);
      expect(parsed.stages.last.isJs, isTrue);
      expect(parsed.isMixed, isTrue);
      expect(parsed.usesJs, isTrue);
    });

    test('@webjs: 被标注成需要 WebView', () {
      final ParsedSourceRule parsed =
          ParsedSourceRule.parse('a@href@webjs:return document.body.innerHTML');
      final RuleStage js =
          parsed.stages.firstWhere((RuleStage s) => s.isJs);
      expect(js.isWebJs, isTrue);
      expect(js.notes.any((String n) => n.contains('WebView')), isTrue);
    });

    test('真实书源的 bookList 是单段纯 JS（不是被切碎的 3 段）', () {
      final ParsedSourceRule parsed =
          ParsedSourceRule.parse(loadShenshi().ruleSearch!.bookList!);

      expect(parsed.stages.length, 1);
      expect(parsed.stages.single.isJs, isTrue);
      expect(parsed.segments, isEmpty);
      // 这段 JS 里同时有 `&&` 和 `||`，正好用来验证切分顺序
      expect(parsed.jsBlocks.single.contains('&&'), isTrue);
      expect(parsed.jsBlocks.single.contains('||'), isTrue);
    });
  });

  group('列表规则的 - / + 顺序修饰', () {
    test('- 前缀被剥掉，剩下的才交给规则引擎', () {
      final ParsedSourceRule parsed =
          ParsedSourceRule.parseList('-<js>abc</js>');

      expect(parsed.isListRule, isTrue);
      expect(parsed.listOrder, ListOrderModifier.reverse);
      expect(parsed.raw, '-<js>abc</js>');
      expect(parsed.body, '<js>abc</js>');
      expect(parsed.jsBlocks, <String>['abc']);
      expect(parsed.listOrderNote, isNotNull);
    });

    test('+ 前缀表示显式不反转', () {
      final ParsedSourceRule parsed = ParsedSourceRule.parseList('+a@href');
      expect(parsed.listOrder, ListOrderModifier.explicit);
      expect(parsed.body, 'a@href');
    });

    test('没有前缀也是列表规则，只是顺序为默认', () {
      final ParsedSourceRule parsed = ParsedSourceRule.parseList('a@href');
      expect(parsed.isListRule, isTrue);
      expect(parsed.listOrder, ListOrderModifier.none);
      expect(parsed.listOrderNote, isNull);
    });

    test('非列表规则的 - 不剥（- 只对列表规则生效）', () {
      final ParsedSourceRule parsed = ParsedSourceRule.parse('-a@href');
      expect(parsed.isListRule, isFalse);
      expect(parsed.listOrder, ListOrderModifier.none);
      expect(parsed.body, '-a@href');
    });

    test('真实书源的 chapterList 带 - 前缀', () {
      final ParsedSourceRule parsed =
          ParsedSourceRule.parseList(loadShenshi().ruleToc!.chapterList!);

      expect(parsed.listOrder, ListOrderModifier.reverse);
      expect(parsed.body.startsWith('<js>'), isTrue);
      expect(parsed.jsBlocks, hasLength(1));
      expect(parsed.jsBlocks.single.contains("java.get('sshj')"), isTrue);
      // 剥掉前缀之后不该再有孤零零的选择器段
      expect(parsed.segments, isEmpty);
    });
  });

  group('选择器 / 提取器 / 索引', () {
    test('@xxx 提取器与属性名', () {
      expect(seg('a@text').extractor, RuleExtractor.text);
      expect(seg('a@text').selectorChain, <String>['a']);
      expect(seg('a@href').extractor, RuleExtractor.attribute);
      expect(seg('a@href').attributeName, 'href');
      expect(seg('img@src').extractor, RuleExtractor.attribute);
      expect(seg('img@src').attributeName, 'src');
      expect(seg('div@html').extractor, RuleExtractor.html);
      expect(seg('div@textNodes').extractor, RuleExtractor.textNodes);
      expect(seg('div@ownText').extractor, RuleExtractor.ownText);
      expect(seg('div@all').extractor, RuleExtractor.all);
    });

    test('元素链按 @ 拆开，索引写在链尾', () {
      final RuleSegment s = seg('id.list@tag.dd');
      expect(s.mode, RuleMode.css);
      expect(s.selectorChain, <String>['id.list', 'tag.dd']);

      final RuleSegment indexed = seg('a.0@href');
      expect(indexed.selectorChain, <String>['a']);
      expect(indexed.index, 0);
      expect(indexed.extractor, RuleExtractor.attribute);
      expect(indexed.attributeName, 'href');
      expect(indexed.indexFilter, IndexFilter.select);
      expect(indexed.indexExpression, '0');

      final RuleSegment img = seg('img.0@all');
      expect(img.selectorChain, <String>['img']);
      expect(img.index, 0);
      expect(img.extractor, RuleExtractor.all);
    });

    test('索引集合 / 区间 / 排除（legado 的 [] 写法）', () {
      final RuleSegment set = seg('li[0,2]');
      expect(set.selectorChain, <String>['li']);
      expect(set.indexFilter, IndexFilter.select);
      expect(set.indexExpression, '0,2');
      expect(set.index, isNull); // 不是单个整数
      expect(set.notes.any((String n) => n.contains('索引表达式')), isTrue);

      final RuleSegment exclude = seg('li[!1,3-5]');
      expect(exclude.indexFilter, IndexFilter.exclude);
      expect(exclude.indexExpression, '1,3-5');
      expect(exclude.selectorChain, <String>['li']);
    });

    test('! 是索引排除标记，不是「整条规则取反」', () {
      final RuleSegment s = seg('a!1');
      expect(s.indexFilter, IndexFilter.exclude);
      expect(s.indexExpression, '1');
      expect(s.selectorChain, <String>['a']);
    });

    test('负索引', () {
      final RuleSegment s = seg('a.-1@href');
      expect(s.index, -1);
      expect(s.selectorChain, <String>['a']);
      expect(s.extractor, RuleExtractor.attribute);
    });

    test('索引直接作为根元素时给出 children 提示', () {
      final RuleSegment s = seg('.0');
      expect(s.index, 0);
      expect(s.selectorChain, isEmpty);
      expect(s.notes.any((String n) => n.contains('根元素')), isTrue);
    });

    test('这些不能被误判成索引', () {
      // 标签名里带数字
      expect(seg('h1').index, isNull);
      expect(seg('h1').selectorChain, <String>['h1']);
      expect(seg('h1').mode, RuleMode.css);
      // CSS 类名里的连字符
      expect(seg('.class-2').index, isNull);
      // 伪类里的括号
      expect(seg('li:nth-child(2)').index, isNull);
      expect(seg('li:nth-child(2)').selectorChain, <String>['li:nth-child(2)']);
      // 属性选择器里的数字
      expect(seg('a[data-id="1"]@href').index, isNull);
    });

    test('XPath / JSONPath 的方括号属于表达式自身，legado 不拆索引', () {
      final RuleSegment xpath = seg('//div[1]');
      expect(xpath.mode, RuleMode.xpath);
      expect(xpath.index, isNull);
      expect(xpath.indexExpression, isNull);
      expect(xpath.notes.any((String n) => n.contains('XPath')), isTrue);

      final RuleSegment json = seg(r'$.data.list[0]');
      expect(json.mode, RuleMode.jsonPath);
      expect(json.index, isNull);
      expect(json.notes.any((String n) => n.contains('JSONPath')), isTrue);
    });
  });

  group('裸标识符 vs 标签选择器', () {
    test('HTML 标签名按选择器解析', () {
      for (final String tag in <String>['h1', 'div', 'p', 'a', 'img', 'li']) {
        expect(seg(tag).mode, RuleMode.css, reason: '$tag 应是选择器');
        expect(seg(tag).selectorChain, <String>[tag]);
      }
      expect(RuleSegment.isHtmlTagName('h1'), isTrue);
      expect(RuleSegment.isHtmlTagName('H1'), isTrue);
    });

    test('非标签名的裸标识符标成 identifier 并给出说明', () {
      for (final String name in <String>['kind', 'intro', 'fm', 'jj', 'tags']) {
        expect(seg(name).mode, RuleMode.identifier, reason: name);
        expect(seg(name).notes.any((String n) => n.contains('裸标识符')), isTrue);
      }
      expect(RuleSegment.isHtmlTagName('kind'), isFalse);
    });

    test('真实书源详情页的 kind / intro 是裸标识符，coverUrl 是 URL 规则', () {
      final BookSource source = loadShenshi();
      final ParsedSourceRule kind =
          ParsedSourceRule.parse(source.ruleBookInfo!.kind!);
      expect(kind.segments.single.mode, RuleMode.identifier);

      final ParsedSourceRule intro =
          ParsedSourceRule.parse(source.ruleBookInfo!.intro!);
      expect(intro.segments.single.mode, RuleMode.identifier);
      expect(source.ruleBookInfo!.coverUrl, 'fm');
    });
  });

  group('老式元素写法', () {
    test('class. / tag. / id. 前缀被识别并给出准确含义', () {
      final RuleSegment klass = seg('class.abc');
      expect(klass.mode, RuleMode.css);
      expect(klass.legacyPrefix, 'class.');
      expect(klass.notes.any((String n) => n.contains('getElementsByClass')), isTrue);

      expect(seg('tag.div').legacyPrefix, 'tag.');
      expect(seg('id.main').legacyPrefix, 'id.');
    });

    test('prefix + 索引：tag.div.1', () {
      final RuleSegment s = seg('tag.div.1');
      expect(s.selectorChain, <String>['tag.div']);
      expect(s.index, 1);
      expect(s.legacyPrefix, 'tag.');
    });

    test('text. 不是「取文本」，要显式提示', () {
      final RuleSegment s = seg('text.abc');
      expect(s.legacyPrefix, 'text.');
      expect(s.notes.any((String n) => n.contains('不是「取文本」')), isTrue);
    });

    test('裸 children 也是合法关键字', () {
      final RuleSegment s = seg('children');
      expect(s.mode, RuleMode.css);
      expect(s.legacyPrefix, 'children');
    });
  });

  group('替换链与模板', () {
    test('##match##replace 拆分', () {
      final RuleSegment s = seg('a@href##index##webp');
      expect(s.subject, 'a@href');
      expect(s.replaceRegex, 'index');
      expect(s.replacement, 'webp');
      expect(s.replaceFirst, isFalse);
      expect(s.replaceChain, '##index##webp');
      expect(s.hasReplace, isTrue);
    });

    test('尾部 ### 表示只替换第一处', () {
      final RuleSegment s = seg(r'.info@text##^(\d+)##$1张图###');
      expect(s.replaceRegex, r'^(\d+)');
      expect(s.groupRefs, <int>[1]);
      expect(s.replaceFirst, isTrue);
      expect(s.replaceChain.endsWith('#'), isTrue);
    });

    test('只有一段 ## 时也算替换链（legado 是 size>1 就取）', () {
      final RuleSegment s = seg('a@text##\\s+');
      expect(s.subject, 'a@text');
      expect(s.replaceRegex, r'\s+');
      expect(s.replacement, isNull);
      expect(s.replaceChain, r'##\s+');
    });

    test('真实书源 chapterUrl：a@href##index##webp', () {
      final RuleSegment s = RuleSegment.fromString(loadShenshi().ruleToc!.chapterUrl!);
      expect(s.selectorChain, <String>['a']);
      expect(s.extractor, RuleExtractor.attribute);
      expect(s.attributeName, 'href');
      expect(s.replaceRegex, 'index');
      expect(s.replacement, 'webp');
    });

    test('{{}} 模板按内容分类：变量 / 规则 / JS', () {
      final ParsedSourceRule tpl =
          ParsedSourceRule.parse('https:{{@@img@src}},{headers:{referer:"{{surl()}}/"}}');

      expect(tpl.hasTemplates, isTrue);
      final Map<String, TemplateKind> kinds = <String, TemplateKind>{
        for (final RuleTemplate t in tpl.templates) t.content: t.kind,
      };
      expect(kinds['@@img@src'], TemplateKind.rule);
      expect(kinds['surl()'], TemplateKind.js);
      expect(tpl.usesJs, isTrue);

      expect(RuleTemplate.fromContent('page').kind, TemplateKind.variable);
      expect(RuleTemplate.fromContent('@get:{x}').kind, TemplateKind.rule);
      expect(RuleTemplate.fromContent(r'$.a.b').kind, TemplateKind.rule);
      expect(RuleTemplate.fromContent('java.base64Encode(key)').kind,
          TemplateKind.js);
      expect(RuleTemplate.isRuleContent('//div/a'), isTrue);
      expect(RuleTemplate.isRuleContent('page'), isFalse);
    });

    test('真实书源 updateTime：替换链 + \$2/\$1 分组引用 + 尾部 ###', () {
      final RuleSegment s =
          RuleSegment.fromString(loadShenshi().ruleToc!.updateTime!);

      expect(s.subject, '.info@text');
      expect(s.selectorChain, <String>['.info']);
      expect(s.extractor, RuleExtractor.text);
      expect(s.replaceRegex, r'^(\d+)\D*([\d\-\s\:]{4,})$');
      expect(s.replacement, r'$2　$1张图');
      expect(s.replaceFirst, isTrue);
      // 分组引用出现在**替换文本**里，不是规则主体里
      expect(s.groupRefs, <int>[2, 1]);
    });

    test('@get: / @put: 变量引用', () {
      final RuleSegment s = seg('@get:{sshj}@text');
      expect(s.variableRefs, <String>['sshj']);

      final RuleSegment put = seg('a@text@put:{anm:result}');
      expect(put.putRefs, <String>['anm']);
    });
  });
}
