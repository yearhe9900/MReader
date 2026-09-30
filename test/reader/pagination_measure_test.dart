// 分页测量层单测（T01）：投影契约 + 行偏移映射 + 端到端切页。
// 期望值一律硬编码字面量。夹具（flutter test 等宽字体实测）：fontSize 18
// → 字宽 18（pageWidth 180 = 10 字/行）、行高 **29.0**、图片占位行高 **48.0**。
// 投影契约对拍 `typeset.dart` 的 `parseInlineStyles` / `parseContentSpans`
// ——两条独立路径产出必须同语义（测量与渲染行断一致性的前提）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/pagination/page_breaker.dart';
import 'package:mreader/reader/pagination/page_paginator.dart';
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

  /// 取 (文本, 字重, 字形) 三元组，用于与 `typeset.dart` 的 span 产物对拍。
  List<(String, FontWeight?, FontStyle?)> triples(List<InlineSpan> spans) {
    return <(String, FontWeight?, FontStyle?)>[
      for (final InlineSpan span in spans)
        if (span is TextSpan)
          ((span.text ?? ''), span.style?.fontWeight, span.style?.fontStyle),
    ];
  }

  group('project 投影契约', () {
    test('无标记 + <b>/<i>：与 parseInlineStyles 逐段对拍', () {
      const String raw = '<b>加粗</b><i>斜体</i>正文';

      final VisibleProjection projection = PagePaginator.project(raw, base);

      expect(projection.visible, '加粗斜体正文');
      expect(projection.rawOfVisible, <int>[3, 4, 12, 13, 18, 19]);
      expect(projection.rawLength, 20);
      expect(projection.placeholderCount, 0);
      expect(triples(projection.spans), triples(parseInlineStyles(raw, base)));
    });

    test('标记：与 parseContentSpans 对拍 + 偏移映射', () {
      const String raw = 'a\x00IMG:x.png\x00b\x00A:h\x00c\x00A\x00\x00ID:z\x00d';

      final VisibleProjection projection = PagePaginator.project(raw, base);

      // a ␀IMG:x.png␀ b ␀A:h␀ c ␀A␀ ␀ID:z␀ d（下标：0 / 1 / 12 / 18 / 28，长 29）
      expect(projection.visible, 'a\uFFFCbcd');
      expect(projection.placeholderCount, 1);
      expect(projection.rawOfVisible, <int>[0, 1, 12, 18, 28]);
      expect(projection.rawLength, 29);

      final List<InlineSpan> reference = parseContentSpans(raw, base, (String _) async => null);
      expect(
        projection.visible,
        reference.map((InlineSpan s) => s is TextSpan ? (s.text ?? '') : '\uFFFC').join(),
      );
      expect(reference.whereType<WidgetSpan>().length, 1);
    });

    test('脏数据不抛：未闭合标记、未知标记、未闭合链接', () {
      expect(PagePaginator.project('ab\x00IMG', base).visible, 'ab');
      expect(PagePaginator.project('a\x00ZZZ\x00b', base).visible, 'ab');
      expect(PagePaginator.project('\x00A:h\x00link', base).visible, 'link');
      expect(PagePaginator.project('', base).visible, '');
    });
  });

  group('行测量与偏移映射', () {
    test('每行 10 字、行高 29，区间首尾相接且覆盖整段', () {
      final List<MeasuredLine> lines = PagePaginator.measureParagraphs(
        paragraphs: <String>['0123456789' * 12],
        config: config,
      );

      expect(lines.length, 12);
      expect(lines.first.start, 0);
      expect(lines.first.end, 10);
      expect(lines.first.height, 29.0);
      expect(lines.first.quality, LineBreakQuality.none);
      expect(lines[1].start, 10);
      expect(lines.last.start, 110);
      expect(lines.last.end, 120);
      expect(lines.last.quality, LineBreakQuality.paragraphEnd);
      for (int i = 1; i < lines.length; i++) {
        expect(lines[i].start, lines[i - 1].end);
      }
    });

    test('图片标记：占 1 个可见槽位，行高取占位 48（不是文本行高 29）', () {
      final List<MeasuredLine> lines = PagePaginator.measureParagraphs(
        paragraphs: <String>['\x00IMG:a.png\x00'],
        config: config,
      );

      expect(lines.length, 1);
      expect(lines.single.start, 0);
      expect(lines.single.end, 11); // ␀IMG:a.png␀ = 11 个原文码元
      expect(lines.single.height, 48.0);
      expect(lines.single.quality, LineBreakQuality.paragraphEnd);
    });

    test('标签不进字符区间：偏移保持原文口径', () {
      final List<MeasuredLine> lines = PagePaginator.measureParagraphs(
        paragraphs: <String>['<b>正文</b>'],
        config: config,
      );

      expect(lines.length, 1);
      expect(lines.single.start, 3); // `<b>` 之后
      expect(lines.single.end, 9); // `</b>` 归入本页（原文长 9）
    });

    test('多段：第二段基址 = Σ 前段长度（无分隔符）', () {
      final List<MeasuredLine> lines = PagePaginator.measureParagraphs(
        paragraphs: <String>['0123456789' * 12, 'b'],
        config: config,
      );

      expect(lines.last.paragraphIndex, 1);
      expect(lines.last.start, 120);
      expect(lines.last.end, 121);
      expect(PagePaginator.charCountOf(<String>['0123456789' * 12, 'b']), 121);
    });
  });

  group('端到端 paginate', () {
    test('页高 200 / 行高 29 → 每页 6 行；120 字 = 2 页', () {
      final List<PageSlice> pages = PagePaginator.paginate(
        paragraphs: <String>['0123456789' * 12],
        config: config,
      );

      expect(pages.length, 2);
      expect(pages[0].start, 0);
      expect(pages[0].end, 60);
      expect(pages[0].lineCount, 6);
      expect(pages[0].height, 174.0);
      expect(pages[1].start, 60);
      expect(pages[1].end, 120);
      expect(pages[1].lineCount, 6);

      for (int i = 1; i < pages.length; i++) {
        expect(pages[i].start, pages[i - 1].end);
      }
    });

    test('段间距：页内跨段加、跨页不加', () {
      const PaginationConfig tight = PaginationConfig(
        pageWidth: 180,
        pageHeight: 120,
        textStyle: base,
      );

      final List<PageSlice> pages = PagePaginator.paginate(
        paragraphs: <String>['0123456789', 'abcdefghij', 'ABCDEFGHIJ', 'qrstuvwxyz'],
        config: tight,
      );

      // 3 行（29×3）+ 2 个段间距（8×2）= 103 ≤ 120；第 4 段需 103+8+29 = 140 > 120。
      expect(pages.length, 2);
      expect(pages[0].lineCount, 3);
      expect(pages[0].height, 103.0);
      expect(pages[1].lineCount, 1);
      expect(pages[1].height, 29.0);
    });

    test('断句回拉：窗口内（≤50 字）的句读处收页', () {
      const PaginationConfig tall = PaginationConfig(
        pageWidth: 180,
        pageHeight: 300,
        textStyle: base,
      );
      // 12 行：L0 与 L6 以「。」结尾，其余数字；页高 300 容 10 行 → 切在 L9（段中间）。
      final String text = '012345678。${'0123456789' * 5}012345678。${'0123456789' * 5}';

      final List<PageSlice> pages = PagePaginator.paginate(paragraphs: <String>[text], config: tall);

      // 回拉到 L6（页尾行 L9 与其相距 3 行 = 30 字 ≤ 50 窗口）。
      expect(pages.length, 2);
      expect(pages[0].end, 70);
      expect(pages[0].lineCount, 7);
      expect(pages[1].start, 70);
      expect(pages[1].end, 120);
      expect(pages[1].lineCount, 5);
    });

    test('空章节 → 一个空页 [0, 0)', () {
      expect(PagePaginator.paginate(paragraphs: const <String>[], config: config).single.end, 0);
      expect(
        PagePaginator.paginate(paragraphs: const <String>[''], config: config).single.lineCount,
        0,
      );
      expect(PagePaginator.charCountOf(const <String>[]), 0);
    });

    test('页表 ↔ 字符偏移互查', () {
      final List<PageSlice> pages = PagePaginator.paginate(
        paragraphs: <String>['0123456789' * 12],
        config: config,
      );

      expect(PageBreaker.findPageByCharOffset(pages, 0), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 59), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 60), 1);
      expect(PageBreaker.findPageByCharOffset(pages, 119), 1);
      expect(PageBreaker.findPageByCharOffset(pages, 120), 1); // 章末 → 末页
    });
  });

  group('PaginationConfig', () {
    test('值相等性（T02 分页缓存键的基础）', () {
      const PaginationConfig a = PaginationConfig(pageWidth: 180, pageHeight: 200, textStyle: base);
      const PaginationConfig b = PaginationConfig(pageWidth: 180, pageHeight: 200, textStyle: base);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a == const PaginationConfig(pageWidth: 180, pageHeight: 200, textStyle: base, paragraphSpacing: 9),
        isFalse,
      );
      expect(
        a == const PaginationConfig(pageWidth: 181, pageHeight: 200, textStyle: base),
        isFalse,
      );
    });
  });
}
