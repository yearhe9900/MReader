// parseInlineStyles + withFirstLineIndent 单测（`TYP-04`）。
// parseContentSpans 链接/锚点标记（`CNT-04b`）。
//
// 纯 Dart `test()`（非 `testWidgets`）；widget 组除外。
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  group('CNT-04b 链接标记解析', () {
    Future<Uint8List?> noImage(String href) async => null;

    test('A 标记 → 链接 TextSpan（下划线 + recognizer），文字保留', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      final List<InlineSpan> spans = parseContentSpans(
        '前文 \x00A:#fn1\x00[1]\x00A\x00 后文',
        base,
        noImage,
        onLinkTap: (String href) {},
        recognizerSink: sink,
      );
      expect(spans.length, 3);
      expect((spans[0] as TextSpan).text, '前文 ');
      final TextSpan link = spans[1] as TextSpan;
      expect(link.text, '[1]');
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.recognizer, isA<TapGestureRecognizer>());
      expect((spans[2] as TextSpan).text, ' 后文');
      expect(sink.length, 1);
    });

    test('onTap 回调传出归一化 href', () {
      String? tapped;
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      parseContentSpans(
        '\x00A:OEBPS/text/ch2.xhtml#s\x00跳转\x00A\x00',
        base,
        noImage,
        onLinkTap: (String href) => tapped = href,
        recognizerSink: sink,
      );
      expect(sink.length, 1);
      sink[0].onTap!(); // 直接触发回调
      expect(tapped, 'OEBPS/text/ch2.xhtml#s');
    });

    test('ID 标记渲染吞掉不上屏', () {
      final List<InlineSpan> spans = parseContentSpans(
        '\x00ID:fn1\x00注释正文',
        base,
        noImage,
      );
      expect(spans.length, 1);
      expect((spans[0] as TextSpan).text, '注释正文');
    });

    test('ID + A 共存（脚注含返回链接）', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      final List<InlineSpan> spans = parseContentSpans(
        '\x00ID:fn1\x00脚注内容 \x00A:#ref1\x00\u21a9\x00A\x00',
        base,
        noImage,
        onLinkTap: (String href) {},
        recognizerSink: sink,
      );
      // ID 标记吞掉；链接文字带下划线。
      expect(spans.length, 2);
      expect((spans[0] as TextSpan).text, '脚注内容 ');
      expect((spans[1] as TextSpan).text, '\u21a9');
      expect((spans[1] as TextSpan).style?.decoration, TextDecoration.underline);
    });

    test('链接文字内 <b>/<i> 叠加下划线', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      final List<InlineSpan> spans = parseContentSpans(
        '\x00A:#x\x00<b>粗</b>体\x00A\x00',
        base,
        noImage,
        onLinkTap: (String href) {},
        recognizerSink: sink,
      );
      expect(spans.length, 2);
      final TextSpan boldLink = spans[0] as TextSpan;
      expect(boldLink.text, '粗');
      expect(boldLink.style?.fontWeight, FontWeight.bold);
      expect(boldLink.style?.decoration, TextDecoration.underline);
      final TextSpan plainLink = spans[1] as TextSpan;
      expect(plainLink.text, '体');
      expect(plainLink.style?.decoration, TextDecoration.underline);
      // 两段共享同一 recognizer（同一链接）。
      expect(identical(boldLink.recognizer, plainLink.recognizer), isTrue);
    });

    test('多链接各自 recognizer，sink 收集齐', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      final List<String> tapped = <String>[];
      parseContentSpans(
        '\x00A:#a\x00甲\x00A\x00-\x00A:OEBPS/ch2.xhtml\x00乙\x00A\x00',
        base,
        noImage,
        onLinkTap: tapped.add,
        recognizerSink: sink,
      );
      expect(sink.length, 2);
      sink[0].onTap!();
      sink[1].onTap!();
      expect(tapped, <String>['#a', 'OEBPS/ch2.xhtml']);
    });

    test('onLinkTap 为 null：下划线展示但无 recognizer（不可点）', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      final List<InlineSpan> spans = parseContentSpans(
        '\x00A:#x\x00文字\x00A\x00',
        base,
        noImage,
        recognizerSink: sink,
      );
      expect(spans.length, 1);
      expect((spans[0] as TextSpan).style?.decoration, TextDecoration.underline);
      expect((spans[0] as TextSpan).recognizer, isNull);
      expect(sink, isEmpty);
    });

    test('混合 IMG + A + ID 段落不崩', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      final List<InlineSpan> spans = parseContentSpans(
        '\x00ID:p1\x00\x00IMG:p.png\x00图 \x00A:#x\x00链\x00A\x00尾',
        base,
        noImage,
        onLinkTap: (String href) {},
        recognizerSink: sink,
      );
      expect(spans.whereType<WidgetSpan>().length, 1);
      expect(sink.length, 1);
    });

    test('脏数据：未闭合 A / 孤立闭合 / 未知标记体 不崩', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      // 未闭合 A：后续文字保持链接样式延伸到段末。
      final List<InlineSpan> unclosed = parseContentSpans(
        '前 \x00A:#x\x00后',
        base,
        noImage,
        onLinkTap: (String href) {},
        recognizerSink: sink,
      );
      expect(unclosed.length, 2);
      expect((unclosed[1] as TextSpan).style?.decoration,
          TextDecoration.underline);
      // 孤立 \x00A\x00 闭标记吞掉；未知标记体吞掉。
      final List<InlineSpan> orphan = parseContentSpans(
        '甲\x00A\x00乙\x00ZZZ:oops\x00丙',
        base,
        noImage,
        onLinkTap: (String href) {},
        recognizerSink: sink,
      );
      final String flat = orphan
          .map((InlineSpan s) => (s as TextSpan).text ?? '')
          .join();
      expect(flat, '甲乙丙');
    });

    test('空 href 的 A 标记只留文字', () {
      final List<TapGestureRecognizer> sink = <TapGestureRecognizer>[];
      final List<InlineSpan> spans = parseContentSpans(
        '\x00A:\x00文字\x00A\x00',
        base,
        noImage,
        onLinkTap: (String href) {},
        recognizerSink: sink,
      );
      // 空 href 不开链接：文字为普通文本段（但脏数据闭标记吞掉）。
      expect(sink, isEmpty);
      final String flat = spans
          .map((InlineSpan s) => (s as TextSpan).text ?? '')
          .join();
      expect(flat, '文字');
    });
  });

  group('CNT-04b InlineParagraph 生命周期', () {
    testWidgets('渲染吞标记，链接可点传出 href', (WidgetTester tester) async {
      String? tapped;
      await tester.pumpWidget(MaterialApp(
        home: InlineParagraph(
          text: '注 \x00ID:x\x00\x00A:#fn1\x00[1]\x00A\x00',
          style: const TextStyle(fontSize: 18),
          resolveImage: (String href) async => null,
          onLinkTap: (String href) => tapped = href,
        ),
      ));

      // 标记不上屏：RichText 可见文本只有文字部分。
      final RichText rich = tester.widget<RichText>(find.byType(RichText));
      expect(rich.text.toPlainText(), '注 [1]');

      // 精确取链接字形盒（可见文本 '注 [1]' 中 [2,5) = '[1]'）再点击，
      // 避免点到行内空白导致命中失败。
      final RenderParagraph para =
          tester.renderObject<RenderParagraph>(find.byType(RichText));
      final List<TextBox> boxes = para.getBoxesForSelection(
        const TextSelection(baseOffset: 2, extentOffset: 5),
      );
      expect(boxes, isNotEmpty);
      final Offset linkCenter =
          para.localToGlobal(boxes.first.toRect().center);
      await tester.tapAt(linkCenter);
      await tester.pump();
      expect(tapped, '#fn1');
    });

    testWidgets('文本变化重建 + dispose 不崩（recognizer 释放路径）',
        (WidgetTester tester) async {
      Future<Uint8List?> noImage(String href) async => null;
      await tester.pumpWidget(MaterialApp(
        home: InlineParagraph(
          text: '\x00A:#a\x00甲\x00A\x00',
          style: const TextStyle(fontSize: 18),
          resolveImage: noImage,
          onLinkTap: (String href) {},
        ),
      ));
      // 输入变化 → 旧 recognizer 延后释放（postFrame），新 recognizer 生效。
      await tester.pumpWidget(MaterialApp(
        home: InlineParagraph(
          text: '\x00A:#b\x00乙\x00A\x00',
          style: const TextStyle(fontSize: 18),
          resolveImage: noImage,
          onLinkTap: (String href) {},
        ),
      ));
      await tester.pump(); // 执行 postFrameCallback 释放旧批
      // 卸载 → dispose 当前批，不崩。
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 onLinkTap 时纯展示，点击无副作用不崩',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: InlineParagraph(
          text: '\x00A:#x\x00文字\x00A\x00',
          style: const TextStyle(fontSize: 18),
          resolveImage: (String href) async => null,
        ),
      ));
      await tester.tap(find.byType(RichText));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
