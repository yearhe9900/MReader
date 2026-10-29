// 分页测量层单测（T01）：投影契约 + 行偏移映射 + 端到端切页。
// 期望值一律硬编码字面量。夹具（flutter test 等宽字体）：fontSize 18
// → 字宽 18（pageWidth 180 = 10 字/行）、行高 **29.0**、图片占位混排行高 **51.0**
//（占位 48 + 缩进文本同行，bottom 对齐——与渲染 `typeset.dart` WidgetSpan 默认一致）。
// 投影恒加 2 字符首行缩进前缀（`kFirstLineIndentPrefix`）：可见偏移 ≈ 原文 + 2。
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

      expect(projection.visible, '$kFirstLineIndentPrefix加粗斜体正文');
      expect(projection.rawOfVisible, <int>[0, 0, 3, 4, 12, 13, 18, 19]);
      expect(projection.rawLength, 20);
      expect(projection.placeholderCount, 0);
      expect(
        triples(projection.spans),
        triples(parseInlineStyles(withFirstLineIndent(raw), base)),
      );
    });

    test('标记：与 parseContentSpans 对拍 + 偏移映射', () {
      const String raw = 'a\x00IMG:x.png\x00b\x00A:h\x00c\x00A\x00\x00ID:z\x00d';

      final VisibleProjection projection = PagePaginator.project(raw, base);

      // 缩进 + a ␀IMG:x.png␀ b ␀A:h␀ c ␀A␀ ␀ID:z␀ d（下标：0/0 / 0 / 1 / 12 / 18 / 28）
      expect(projection.visible, '${kFirstLineIndentPrefix}a\uFFFCbcd');
      expect(projection.placeholderCount, 1);
      expect(projection.placeholderSrcs, <String>['x.png']); // T05-b 记 src
      expect(projection.rawOfVisible, <int>[0, 0, 0, 1, 12, 18, 28]);
      expect(projection.rawLength, 29);

      final List<InlineSpan> reference =
          parseContentSpans(withFirstLineIndent(raw), base, (String _) async => null);
      expect(
        projection.visible,
        reference.map((InlineSpan s) => s is TextSpan ? (s.text ?? '') : '\uFFFC').join(),
      );
      expect(reference.whereType<WidgetSpan>().length, 1);
    });

    test('脏数据不抛：未闭合标记、未知标记、未闭合链接', () {
      expect(PagePaginator.project('ab\x00IMG', base).visible, '${kFirstLineIndentPrefix}ab');
      expect(PagePaginator.project('a\x00ZZZ\x00b', base).visible, '${kFirstLineIndentPrefix}ab');
      expect(
        PagePaginator.project('\x00A:h\x00link', base).visible,
        '${kFirstLineIndentPrefix}link',
      );
      expect(PagePaginator.project('', base).visible, kFirstLineIndentPrefix);
    });
  });

  group('行测量与偏移映射', () {
    test('每行 10 字、行高 29，区间首尾相接且覆盖整段（缩进占行首 2 字）', () {
      final List<MeasuredLine> lines = PagePaginator.measureParagraphs(
        paragraphs: <String>['0123456789' * 12],
        config: config,
      );

      expect(lines.length, 13); // 120 + 2 缩进 = 122 可见 → 13 行
      expect(lines.first.start, 0);
      expect(lines.first.end, 8); // 首行 = 2 缩进 + 8 原文
      expect(lines.first.height, 29.0);
      expect(lines.first.quality, LineBreakQuality.none);
      expect(lines[1].start, 8);
      expect(lines.last.start, 118);
      expect(lines.last.end, 120);
      expect(lines.last.quality, LineBreakQuality.paragraphEnd);
      for (int i = 1; i < lines.length; i++) {
        expect(lines[i].start, lines[i - 1].end);
      }
    });

    test('图片标记：占 1 个可见槽位，行高取占位（48 底 + 缩进文本 → 51，非文本行高 29）', () {
      final List<MeasuredLine> lines = PagePaginator.measureParagraphs(
        paragraphs: <String>['\x00IMG:a.png\x00'],
        config: config,
      );

      expect(lines.length, 1);
      expect(lines.single.start, 0);
      expect(lines.single.end, 11); // ␀IMG:a.png␀ = 11 个原文码元
      expect(lines.single.height, 51.0);
      expect(lines.single.quality, LineBreakQuality.paragraphEnd);
    });

    test('图片真尺寸（T05-b）：命中查表按页宽 fit，未命中回退 48', () {
      final Map<String, Size> imageSizes = <String, Size>{
        'wide.png': const Size(300, 150), // > 页宽 180 → fit 180×90
        'small.png': const Size(60, 30), // 不超页宽 → 原样 60×30
      };

      final List<MeasuredLine> wide = PagePaginator.measureParagraphs(
        paragraphs: <String>['\x00IMG:wide.png\x00'],
        config: config,
        imageSizes: imageSizes,
      );
      // fit 后 180 宽：段首 2 缩进（36px）+ 180 > 页宽 → 图片换行成 2 行
      //（缩进行 29.0 + 图行 90.0，与渲染侧行断一致）。
      expect(wide.length, 2);
      expect(wide[0].height, 29.0);
      expect(wide[1].height, 90.0);

      final List<MeasuredLine> small = PagePaginator.measureParagraphs(
        paragraphs: <String>['\x00IMG:small.png\x00'],
        config: config,
        imageSizes: imageSizes,
      );
      // 60×30 原样进占位（fit 不动）：行高 33.0——flutter test 字体下
      // 「30 高占位 + 缩进文本同行」的 bottom 对齐行盒值，与回退的 51.0 可区分。
      expect(small.single.height, 33.0);

      // 未命中（不传 / 表里没有）→ 48×48 加载态回退。
      final List<MeasuredLine> miss = PagePaginator.measureParagraphs(
        paragraphs: <String>['\x00IMG:none.png\x00'],
        config: config,
        imageSizes: imageSizes,
      );
      expect(miss.single.height, 51.0);

      final List<MeasuredLine> noTable = PagePaginator.measureParagraphs(
        paragraphs: <String>['\x00IMG:wide.png\x00'],
        config: config,
      );
      expect(noTable.single.height, 51.0);
    });

    test('标签不进字符区间：偏移保持原文口径', () {
      final List<MeasuredLine> lines = PagePaginator.measureParagraphs(
        paragraphs: <String>['<b>正文</b>'],
        config: config,
      );

      expect(lines.length, 1);
      expect(lines.single.start, 0); // 缩进映射原文段首（含 `<b>` 标签起点）
      expect(lines.single.end, 9); // `</b>` 归入本行（原文长 9）
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
    test('页高 200 / 行高 29 → 每页 6 行；120 字 = 3 页', () {
      final List<PageSlice> pages = PagePaginator.paginate(
        paragraphs: <String>['0123456789' * 12],
        config: config,
      );

      expect(pages.length, 3);
      expect(pages[0].start, 0);
      expect(pages[0].end, 58); // 2 缩进 + 58 原文 = 6 行可见
      expect(pages[0].lineCount, 6);
      expect(pages[0].height, 174.0);
      expect(pages[1].start, 58);
      expect(pages[1].end, 118);
      expect(pages[1].lineCount, 6);
      expect(pages[1].height, 174.0);
      expect(pages[2].start, 118);
      expect(pages[2].end, 120);
      expect(pages[2].lineCount, 1);
      expect(pages[2].height, 29.0);

      for (int i = 1; i < pages.length; i++) {
        expect(pages[i].start, pages[i - 1].end);
      }
    });

    test('段间距：页内跨段加、跨页不加', () {
      const PaginationConfig tight = PaginationConfig(
        pageWidth: 180,
        pageHeight: 160,
        textStyle: base,
      );

      final List<PageSlice> pages = PagePaginator.paginate(
        paragraphs: <String>['0123456789', 'abcdefghij', 'ABCDEFGHIJ', 'qrstuvwxyz'],
        config: tight,
      );

      // 缩进后每段 12 可见 = 2 行；页 0 收 4 行（29×4）+ 1 个页内段间距（8）
      // = 124 ≤ 160，再收跨段行 = 161 > 160；页 1 同构（跨页段间距不加 → 124）。
      expect(pages.length, 2);
      expect(pages[0].start, 0);
      expect(pages[0].end, 20);
      expect(pages[0].lineCount, 4);
      expect(pages[0].height, 124.0);
      expect(pages[1].start, 20);
      expect(pages[1].end, 40);
      expect(pages[1].lineCount, 4);
      expect(pages[1].height, 124.0);
    });

    test('断句回拉：窗口内（≤50 字）的句读处收页', () {
      const PaginationConfig tall = PaginationConfig(
        pageWidth: 180,
        pageHeight: 300,
        textStyle: base,
      );
      // 缩进 +2 后「。」放 raw[7]/raw[67] → 可见 9/69 = 行 0/行 6 行尾。
      // 13 行；页高 300 容 10 行 → 贪心切在行 9（段中间），回拉到行 6。
      final String text = '0123456。${'0123456789' * 5}012345678。${'0123456789' * 5}01';

      final List<PageSlice> pages = PagePaginator.paginate(paragraphs: <String>[text], config: tall);

      // 行 6 尾 = 可见 70 → 原文 68（距贪心切点 3 行 = 30 字 ≤ 50 窗口）。
      expect(pages.length, 2);
      expect(pages[0].end, 68);
      expect(pages[0].lineCount, 7);
      expect(pages[1].start, 68);
      expect(pages[1].end, 120);
      expect(pages[1].lineCount, 6);
    });

    test('空章节 → 一个空页 [0, 0)', () {
      expect(PagePaginator.paginate(paragraphs: const <String>[], config: config).single.end, 0);
      // 空段渲染为缩进空行（与 `withFirstLineIndent('')` 一致）→ 1 行 [0, 0)。
      expect(
        PagePaginator.paginate(paragraphs: const <String>[''], config: config).single.lineCount,
        1,
      );
      expect(PagePaginator.charCountOf(const <String>[]), 0);
    });

    test('页表 ↔ 字符偏移互查', () {
      final List<PageSlice> pages = PagePaginator.paginate(
        paragraphs: <String>['0123456789' * 12],
        config: config,
      );

      expect(PageBreaker.findPageByCharOffset(pages, 0), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 57), 0);
      expect(PageBreaker.findPageByCharOffset(pages, 58), 1);
      expect(PageBreaker.findPageByCharOffset(pages, 117), 1);
      expect(PageBreaker.findPageByCharOffset(pages, 118), 2);
      expect(PageBreaker.findPageByCharOffset(pages, 119), 2);
      expect(PageBreaker.findPageByCharOffset(pages, 120), 2); // 章末 → 末页
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
