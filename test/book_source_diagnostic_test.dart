// 书源体检测试：把「这条源能不能跑」的判断显式化。
//
// 体检是纯静态分析（不联网、不执行 JS），所以它是**可测的**。
// 这里锁住两件最容易退化的东西：
//   1. 字段**类型**判定 —— 它取决于字段名，与是否已配置无关；
//   2. 结论条数与等级 —— 12 条结论里恰好 2 条 blocker，是当前实现程度下的真话。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/source/book_source.dart';
import 'package:mreader/source/source_diagnostic.dart';

BookSource loadShenshi() {
  final String text =
      File('test/fixtures/shenshi.json').readAsStringSync(encoding: utf8);
  return BookSource.fromJson(
    ((jsonDecode(text) as List<dynamic>).single as Map<dynamic, dynamic>)
        .cast<String, dynamic>(),
  );
}

ParsedField fieldOf(SourceDiagnostic d, String key) =>
    d.fields.firstWhere((ParsedField f) => '${f.groupKey}/${f.fieldName}' == key);

void main() {
  group('整体体检结论', () {
    test('真实漫画源：12 条结论，最高等级是「阻塞」', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(d.fields, hasLength(52));
      expect(d.configuredFieldCount, 25);
      expect(d.jsFieldCount, 10);
      expect(d.jsFreeFields, hasLength(15));
      expect(d.findings, hasLength(12));
      expect(d.worstLevel, DiagnosticLevel.blocker);
      expect(d.findingsOf(DiagnosticLevel.blocker), hasLength(2));
      expect(d.legadoApis, hasLength(28));
    });

    test('两条 blocker：漫画类型 + 缺 JS 引擎', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());
      final List<String> titles = d
          .findingsOf(DiagnosticLevel.blocker)
          .map((DiagnosticFinding f) => f.title)
          .toList();

      expect(titles.any((String t) => t.contains('漫画')), isTrue);
      expect(titles.any((String t) => t.contains('依赖 JS 引擎')), isTrue);
      // 数量对不上说明它俩是当前 demo 的真实能力边界，不该被静默吞掉
      for (final DiagnosticFinding f in d.findings) {
        expect(f.title, isNotEmpty);
        expect(f.detail, isNotEmpty);
      }
    });

    test('能力清单锁定（11 项）', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      for (final SourceCapability c in <SourceCapability>[
        SourceCapability.network,
        SourceCapability.js,
        SourceCapability.webView,
        SourceCapability.login,
        SourceCapability.base64,
        SourceCapability.hex,
        SourceCapability.charset,
        SourceCapability.css,
        SourceCapability.regex,
        SourceCapability.template,
        SourceCapability.replaceChain,
        SourceCapability.concurrencyRate,
      ]) {
        if (c == SourceCapability.charset) continue; // 该源没声明字符集
        expect(d.capabilities.contains(c), isTrue, reason: c.label);
      }
      // enabledCookieJar=false，不该报 Cookie 能力
      expect(d.capabilities.contains(SourceCapability.cookieJar), isFalse);
      expect(d.capabilities.contains(SourceCapability.charset), isFalse);
      expect(d.capabilities, hasLength(11));
    });

    test('私有 API 逐个列出且去重排序', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(d.legadoApis, contains('java.ajax'));
      expect(d.legadoApis, contains('java.base64Encode'));
      expect(d.legadoApis, contains('org.jsoup.Jsoup.parse'));
      expect(d.legadoApis, contains('source.putLoginInfo'));
      // 去重
      expect(d.legadoApis.toSet(), hasLength(d.legadoApis.length));
    });

    test('几条关键结论都在（IDN / 列表顺序修饰 / 裸标识符 / 未建模字段）', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());
      final List<String> titles =
          d.findings.map((DiagnosticFinding f) => f.title).toList();

      expect(titles.any((String t) => t.contains('IDN')), isTrue);
      expect(titles.any((String t) => t.contains('列表规则带顺序修饰')), isTrue);
      expect(titles.any((String t) => t.contains('裸标识符')), isTrue);
      expect(titles.any((String t) => t.contains('未建模的键')), isTrue);
      expect(titles.any((String t) => t.contains('登录/域名切换')), isTrue);
      expect(titles.any((String t) => t.contains('并发限速')), isTrue);
      expect(titles.any((String t) => t.contains('WebView')), isTrue);
      // 该源的「发现」组全空
      expect(titles.any((String t) => t.contains('发现') && t.contains('未配置')), isTrue);
    });

    test('空源也能体检，不抛异常', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(
        BookSource.fromJson(<String, dynamic>{'bookSourceUrl': 'https://a.com'}),
      );

      expect(d.fields, isNotEmpty);
      expect(d.jsFieldCount, 0);
      expect(d.jsFreeFields.length + d.jsFieldCount, 0);
      // 只有「声明启用了发现但没有发现规则」这一条
      expect(d.findings, hasLength(1));
      expect(d.findings.single.level, DiagnosticLevel.warn);
      expect(d.worstLevel, DiagnosticLevel.warn);
    });
  });

  group('字段类型取决于字段名，与是否配置无关', () {
    test('真实源的字段分类', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(fieldOf(d, '/searchUrl').kind, SourceFieldKind.url);
      expect(fieldOf(d, '/exploreUrl').kind, SourceFieldKind.url);
      expect(fieldOf(d, '/bookUrlPattern').kind, SourceFieldKind.url);
      expect(fieldOf(d, '/jsLib').kind, SourceFieldKind.js);
      expect(fieldOf(d, '/loginUrl').kind, SourceFieldKind.js);
      expect(fieldOf(d, '/coverDecodeJs').kind, SourceFieldKind.js);
      expect(fieldOf(d, 'ruleSearch/checkKeyWord').kind, SourceFieldKind.text);
      expect(fieldOf(d, 'ruleSearch/coverUrl').kind, SourceFieldKind.urlResult);
      expect(fieldOf(d, 'ruleSearch/bookUrl').kind, SourceFieldKind.urlResult);
      expect(fieldOf(d, 'ruleSearch/bookList').kind, SourceFieldKind.rule);
      expect(fieldOf(d, 'ruleToc/nextTocUrl').kind, SourceFieldKind.urlResult);
      expect(fieldOf(d, 'ruleBookInfo/init').kind, SourceFieldKind.js);
      expect(fieldOf(d, 'ruleToc/formatJs').kind, SourceFieldKind.js);
      expect(fieldOf(d, 'ruleContent/webJs').kind, SourceFieldKind.js);
    });

    test('未配置的字段仍然保留它该有的类型', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      // coverDecodeJs / formatJs 都是空的，但它们依然是「JS 代码」而不是「规则」
      final ParsedField coverDecode = fieldOf(d, '/coverDecodeJs');
      expect(coverDecode.isConfigured, isFalse);
      expect(coverDecode.kind, SourceFieldKind.js);

      final ParsedField formatJs = fieldOf(d, 'ruleToc/formatJs');
      expect(formatJs.isConfigured, isFalse);
      expect(formatJs.kind, SourceFieldKind.js);

      // 没配规则类字段时不该生成 rule 对象
      expect(fieldOf(d, 'ruleSearch/lastChapter').rule, isNull);
      expect(fieldOf(d, 'ruleExplore/bookList').rule, isNull);
    });

    test('JS 类字段即使没配也不会被当成规则解析', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());
      for (final ParsedField f in d.fields) {
        if (f.kind == SourceFieldKind.js && !f.isConfigured) {
          expect(f.rule, isNull, reason: '${f.fieldName} 不该被解析成规则');
          expect(f.usesJs, isFalse);
        }
      }
    });
  });

  group('字段摘要', () {
    test('未配置 / 纯文本 / 列表规则的特殊摘要', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(fieldOf(d, 'ruleSearch/lastChapter').summary, '未配置');
      expect(fieldOf(d, 'ruleSearch/checkKeyWord').summary, '纯文本');
      expect(fieldOf(d, 'ruleSearch/bookList').summary.contains('列表规则'), isTrue);
      expect(fieldOf(d, 'ruleToc/chapterList').summary.contains('列表规则 · -'), isTrue);
      // URL 类字段优先给 URL 结构摘要
      expect(fieldOf(d, '/searchUrl').summary.contains('模板'), isTrue);
      expect(fieldOf(d, '/exploreUrl').summary, 'JS 生成');
      expect(fieldOf(d, 'ruleBookInfo/coverUrl').summary.contains('相对地址'), isTrue);
    });

    test('列表规则标记只打在真正配置了的列表字段上', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(fieldOf(d, 'ruleSearch/bookList').isListRule, isTrue);
      expect(fieldOf(d, 'ruleToc/chapterList').isListRule, isTrue);
      // 该源的「发现」组全空 —— 没配就没有解析产物，也就没有标记
      expect(fieldOf(d, 'ruleExplore/bookList').isListRule, isFalse);
      // 同一个组里的普通字段不该被标
      expect(fieldOf(d, 'ruleToc/chapterName').isListRule, isFalse);
      expect(fieldOf(d, 'ruleSearch/name').isListRule, isFalse);
    });

    test('usesJs 只对真正含 JS 的字段为真', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());

      expect(fieldOf(d, 'ruleSearch/bookList').usesJs, isTrue);
      expect(fieldOf(d, 'ruleToc/chapterName').usesJs, isFalse);
      expect(fieldOf(d, 'ruleSearch/author').usesJs, isFalse);
      expect(fieldOf(d, '/searchUrl').usesJs, isFalse);
      expect(fieldOf(d, '/exploreUrl').usesJs, isTrue);
    });
  });

  group('排序与查询', () {
    test('结论按等级从重到轻排序', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());
      final List<int> levels =
          d.findings.map((DiagnosticFinding f) => f.level.index).toList();
      final List<int> descending = List<int>.of(levels)
        ..sort((int a, int b) => b.compareTo(a));
      expect(levels, descending, reason: 'blocker 应该排在最前面');
    });

    test('findingsOf 过滤正确', () {
      final SourceDiagnostic d = SourceDiagnostic.inspect(loadShenshi());
      final int total = d.findingsOf(DiagnosticLevel.blocker).length +
          d.findingsOf(DiagnosticLevel.warn).length +
          d.findingsOf(DiagnosticLevel.info).length;
      expect(total, d.findings.length);
    });
  });
}
