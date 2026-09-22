// parseInlineStyles + withFirstLineIndent 单测（`TYP-04`）。
//
// 纯 Dart `test()`（非 `testWidgets`）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/typography/typeset.dart';

void main() {
  const TextStyle base = TextStyle(fontSize: 18, height: 1.6);

  group('withFirstLineIndent', () {
    test('加两个全角空格', () {
      expect(withFirstLineIndent('hello'), '\u3000\u3000hello');
    });

    test('空字符串也加', () {
      expect(withFirstLineIndent(''), '\u3000\u3000');
    });
  });

  group('parseInlineStyles 白名单', () {
    test('纯文本（无标签）', () {
      final List<InlineSpan> spans = parseInlineStyles('hello', base);
      expect(spans.length, 1);
      expect((spans[0] as TextSpan).text, 'hello');
      expect((spans[0] as TextSpan).style, base);
    });

    test('<b> → bold', () {
      final List<InlineSpan> spans =
          parseInlineStyles('a <b>b</b> c', base);
      expect(spans.length, 3);
      expect((spans[0] as TextSpan).text, 'a ');
      expect((spans[0] as TextSpan).style, base);
      expect((spans[1] as TextSpan).text, 'b');
      expect((spans[1] as TextSpan).style?.fontWeight, FontWeight.bold);
      expect((spans[2] as TextSpan).text, ' c');
      expect((spans[2] as TextSpan).style, base);
    });

    test('<i> → italic', () {
      final List<InlineSpan> spans =
          parseInlineStyles('a <i>b</i> c', base);
      expect(spans.length, 3);
      expect((spans[1] as TextSpan).text, 'b');
      expect((spans[1] as TextSpan).style?.fontStyle, FontStyle.italic);
    });

    test('<b><i> 嵌套', () {
      final List<InlineSpan> spans =
          parseInlineStyles('<b><i>bi</i></b>', base);
      expect(spans.length, 1);
      final TextSpan span = spans[0] as TextSpan;
      expect(span.text, 'bi');
      expect(span.style?.fontWeight, FontWeight.bold);
      expect(span.style?.fontStyle, FontStyle.italic);
    });

    test('未知标签原样显示文本（不吞内容）', () {
      final List<InlineSpan> spans =
          parseInlineStyles('a <unknown>x</unknown> b', base);
      // <unknown> 不是 <b>/<i>，不应被识别为标签——它会作为纯文本保留。
      // _inlineTagPattern 只匹配 <b> 和 <i>，所以 <unknown> 不会被解析。
      // 它会原样出现在文本中。
      expect(spans.length, 1);
      expect((spans[0] as TextSpan).text,
          'a <unknown>x</unknown> b');
    });

    test('空文本', () {
      final List<InlineSpan> spans = parseInlineStyles('', base);
      expect(spans.length, 1);
      expect((spans[0] as TextSpan).text, '');
    });

    test('连续标签', () {
      final List<InlineSpan> spans =
          parseInlineStyles('<b>a</b><i>b</i>', base);
      expect(spans.length, 2);
      expect((spans[0] as TextSpan).text, 'a');
      expect((spans[0] as TextSpan).style?.fontWeight, FontWeight.bold);
      expect((spans[1] as TextSpan).text, 'b');
      expect((spans[1] as TextSpan).style?.fontStyle, FontStyle.italic);
    });
  });

  group('TYP-04 脏书不崩溃', () {
    // 14 本脏书 fixture 的文本片段（不依赖文件 IO，直接喂文本）。
    const List<String> dirtyTexts = <String>[
      '', // 空段落
      '<b>', // 未闭合
      '</b>', // 多余闭合
      '<b><b>nested</b></b>', // 嵌套同标签
      '<i><b>ib</i></b>', // 交叉嵌套
      '<B>大写标签</B>', // 大写标签（不应匹配 _inlineTagPattern）
      '<b></b>', // 空标签
      '<<b>>double<<//b>>', // 双重尖括号
      'plain text without any tags',
      '<b>中文粗体</b>',
      '<i>日文斜体</i>',
      '<b><i>混合</i>粗体</b>',
      'abc <b>def <i>ghi</i> jkl</b> mno',
      '<script>alert("xss")</script><b>safe</b>',
    ];

    for (int i = 0; i < dirtyTexts.length; i++) {
      test('脏书 #${i + 1} 不崩溃', () {
        // 关键断言：不抛异常。
        final List<InlineSpan> spans =
            parseInlineStyles(dirtyTexts[i], base);
        expect(spans, isNotEmpty);
      });
    }
  });
}
