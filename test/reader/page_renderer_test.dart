// 页内容渲染器（T05-c R2）契约：页框几何、平移量、段落拼装、渲染-测量同源支点。
// 期望值一律硬编码。夹具同 `pagination_measure_test`：fontSize 18 / height 1.6、
// pageWidth 180（10 字/行）、行高 29.0、段间距 8。
// 契约：页框高 = **本页内容自然高**（`PageSlice.height`）。
//
// 原断言页框 = `config.pageHeight`。那与调用方 [PagedScroller] 的
// `Positioned(height: e.height)` 不一致 ⇒ 分页模式下（`pageHeight` = 视口高、
// 末页内容远不足一屏）超出部分被外层裁掉 ⇒ 「文字丢失上一半」。
// 现页框 = `PageSlice.height`（本页实际内容高），内外盒一致、**不裁任何一行**。
//
// 夹具 A（页高 200，两段各 100 字）：22 行 → 4 页 lineCount 6/5/6/5——
// 页 1 贪心后切在 p1 内被断句回拉到 p0 段末（窗口 8 字 ≤ 50），故**无跨段页**。
// 夹具 B（页高 215，p0 100 字 + p1 10 字）：页 1 吃到章末（切点 = 段末不回拉）
// → 恰成跨段页 7/6，用于「两段 + 段间距」拼装断言。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
import 'package:mreader/reader/pagination/page_renderer.dart';
import 'package:mreader/typography/typeset.dart';

import '../test_config.dart';

void main() {
  capTestTimeout();

  const TextStyle base = TextStyle(fontSize: 18, height: 1.6);
  const PaginationConfig config = PaginationConfig(
    pageWidth: 180,
    pageHeight: 200,
    textStyle: base,
  );

  String paraA() => '0123456789' * 10;
  String paraB() => 'abcdefghij' * 10;
  List<String> paras() => <String>[paraA(), paraB()];

  Future<Uint8List?> resolve(String _) async => null;

  late List<MeasuredLine> lines;
  late List<PageSlice> pages;

  setUp(() {
    lines = PagePaginator.measureParagraphs(paragraphs: paras(), config: config);
    pages = PageBreaker.paginate(
      lines,
      pageHeight: 200,
      paragraphSpacing: 8,
    );
  });

  Widget host(PageSlice page, {PaginationConfig cfg = config,
      List<String>? paragraphs, List<MeasuredLine>? rowList}) => MaterialApp(
        home: Center(
          child: PageContent(
            paragraphs: paragraphs ?? paras(),
            lines: rowList ?? lines,
            page: page,
            config: cfg,
            resolveImage: resolve,
          ),
        ),
      );

  group('pageContentPreHeight（纯函数）', () {
    test('夹具 A 页表 4 页 6/5/6/5；段首 0、段中 = 前缀行高和', () {
      expect(pages.length, 4);
      expect(pages[0].lineCount, 6);
      expect(pages[1].lineCount, 5);
      expect(pages[2].lineCount, 6);
      expect(pages[3].lineCount, 5);
      expect(pages[1].end, 100); // 回拉到 p0 段末的字面量证据

      expect(pageContentPreHeight(lines, pages[0]), 0.0);
      expect(pageContentPreHeight(lines, pages[1]), 174.0); // 行0..5 × 29
      expect(pageContentPreHeight(lines, pages[2]), 0.0); // 恰为 p1 段首行
      expect(pageContentPreHeight(lines, pages[3]), 174.0); // 行11..16 × 29
      expect(
        pageContentPreHeight(
          lines,
          const PageSlice(
            index: 0, start: 0, end: 0, height: 0, firstLine: 0, lineCount: 0,
          ),
        ),
        0.0,
      );
    });
  });

  testWidgets('页 0：段首页平移 0、单段落、页框 = 本页内容高、正文宽 180',
      (WidgetTester tester) async {
    await tester.pumpWidget(host(pages[0]));

    // 页框高 = pages[0].height（内容自然高），不再是 pageHeight。
    expect(tester.getSize(find.byType(PageContent)),
        Size(180, pages[0].height));
    expect(find.byType(InlineParagraph), findsOneWidget);
    expect(
      tester.widget<InlineParagraph>(find.byType(InlineParagraph)).text,
      withFirstLineIndent(paraA()),
    );
    // 同宽支点：段落实宽 = 测量 maxWidth。
    expect(tester.getSize(find.byType(InlineParagraph)).width, 180.0);
    // 平移 0（Matrix4 平移分量 ty = storage[13]）。
    final Transform transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.transform.storage[13], 0.0);
    // 段落完整渲染（100 字 11 行 = 319 高）→ 高于页框 200，ClipRect 裁切
    // 且不报 RenderFlex overflow（OverflowBox 解耦高度约束）；
    // 319 = 测量行高 × 行数 = 渲染实高 → 测量-渲染同源支点实证。
    expect(tester.getSize(find.byType(Column)).height, 319.0);
  });

  testWidgets('段中页（页 1）：单段落、平移 −174', (WidgetTester tester) async {
    await tester.pumpWidget(host(pages[1]));

    expect(find.byType(InlineParagraph), findsOneWidget);
    expect(
      tester.widget<InlineParagraph>(find.byType(InlineParagraph)).text,
      withFirstLineIndent(paraA()),
    );
    final Transform transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.transform.storage[13], -174.0);
    expect(tester.getSize(find.byType(PageContent)),
        Size(180, pages[1].height));
  });

  testWidgets('跨段页（夹具 B）：段0 + 间距 8 + 段1，平移 −203', (WidgetTester tester) async {
    const PaginationConfig cfgB = PaginationConfig(
      pageWidth: 180,
      pageHeight: 215,
      textStyle: base,
    );
    final List<String> parasB = <String>[paraA(), '0123456789'];
    final List<MeasuredLine> linesB =
        PagePaginator.measureParagraphs(paragraphs: parasB, config: cfgB);
    final List<PageSlice> pagesB = PageBreaker.paginate(
      linesB,
      pageHeight: 215,
      paragraphSpacing: 8,
    );
    // 夹具 B 页表：7/6，页 1 = 跨段且切点即章末（不回拉）。
    expect(pagesB.length, 2);
    expect(pagesB[0].lineCount, 7);
    expect(pagesB[1].lineCount, 6);
    expect(pagesB[1].start, 68);
    expect(pagesB[1].end, 110);

    await tester.pumpWidget(host(
      pagesB[1],
      cfg: cfgB,
      paragraphs: parasB,
      rowList: linesB,
    ));

    final List<InlineParagraph> found =
        tester.widgetList<InlineParagraph>(find.byType(InlineParagraph)).toList();
    expect(found.length, 2);
    expect(found[0].text, withFirstLineIndent(paraA()));
    expect(found[1].text, withFirstLineIndent('0123456789'));
    expect(
      find.byWidgetPredicate((Widget w) => w is SizedBox && w.height == 8),
      findsOneWidget,
      reason: '页内相邻段之间恰一个段间距',
    );
    final Transform transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.transform.storage[13], -203.0); // 行0..6 × 29
    // 页框 = 本页内容自然高（本夹具 182），不再是 pageHeight(215)。
    expect(tester.getSize(find.byType(PageContent)), const Size(180, 182));
  });

  testWidgets('clipHeight 覆盖页框（页 0 标题预留由视图层裁进）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: PageContent(
            paragraphs: paras(),
            lines: lines,
            page: pages[0],
            config: config,
            resolveImage: resolve,
            clipHeight: 152,
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(PageContent)), const Size(180, 152));
  });

  testWidgets('空页（lineCount 0）：空页框，无段落无平移', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const PageSlice(
        index: 0, start: 0, end: 0, height: 0, firstLine: 0, lineCount: 0,
      )),
    );

    // 空页 `height: 0` ⇒ 页框 0（不得回落 `pageHeight`）。
    expect(tester.getSize(find.byType(PageContent)), const Size(180, 0));
    expect(find.byType(InlineParagraph), findsNothing);
    expect(find.byType(Transform), findsNothing);
  });

  testWidgets('同源支点：textScaler = linear(config)、DefaultTextStyle = config.textStyle',
      (WidgetTester tester) async {
    const PaginationConfig cfg15 = PaginationConfig(
      pageWidth: 180,
      pageHeight: 200,
      textStyle: base,
      textScaleFactor: 1.5, // 与 ambient（1.0）区分，证明注入生效
    );
    final List<MeasuredLine> lines15 =
        PagePaginator.measureParagraphs(paragraphs: paras(), config: cfg15);
    final List<PageSlice> pages15 = PageBreaker.paginate(
      lines15,
      pageHeight: 200,
      paragraphSpacing: 8,
    );

    await tester.pumpWidget(host(
      pages15[0],
      cfg: cfg15,
      rowList: lines15,
    ));

    final BuildContext ctx = tester.element(find.byType(InlineParagraph));
    expect(MediaQuery.textScalerOf(ctx).scale(10), 15.0);
    expect(DefaultTextStyle.of(ctx).style.fontSize, 18.0);
  });
}
