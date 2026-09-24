// `PdfSource.search` 测试（纯 Dart `test()` + 假引擎离线跑；`CNT-06` / `Q4` ②）。
//
// 验收映射：
//   · `CNT-06` ①「命中数与实际出现次数一致」——页文本里 N 次出现 → 恰 N 条命中；
//   · 上下文片段 = 命中所在行；`chapterIndex` 按伪分章（10 页/章）折算；
//   · 扫描件（无文本层页）自动跳过、进度照常推进（`RUST-05` ③ 单调递增）；
//   · 可取消（预取消 / 中途取消）、dispose 竞态优雅空。
//
// PDF 是**句柄源**（引擎文档不可序列化）：`searchSpec` 恒为 null——这是搜索驱动层
// 「改走本 isolate 流式」的分流依据（`lib/task/search_session.dart` 文件头）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/pdf_source.dart';

import '../format/pdf_fakes.dart';

PdfSource _source({
  int pageCount = 25,
  Map<int, String> texts = const <int, String>{},
}) =>
    PdfSource(
      fileName: 'x.pdf',
      bytes: minimalPdfBytes(),
      engine: FakePdfEngine(pageCount: pageCount, texts: texts),
    );

List<SearchHit> _hitsOf(List<SearchEvent> events) =>
    events.map((SearchEvent e) => e.hit).nonNulls.toList();

void main() {
  group('PdfSource.search（文本层）', () {
    test('命中数与实际出现次数一致（CNT-06 ①）', () async {
      final PdfSource source = _source(
        pageCount: 3,
        texts: <int, String>{
          0: 'alpha beta alpha',
          2: 'gamma alpha delta',
        },
      );
      addTearDown(source.dispose);
      final List<SearchHit> hits = _hitsOf(await source
          .search('alpha', cancel: CancelToken())
          .toList());
      expect(hits, hasLength(3), reason: '页 0 两次 + 页 2 一次 = 3（页 1 无文本跳过）');
    });

    test('上下文 = 命中所在行；offset 为章内页文本累加偏移', () async {
      final PdfSource source = _source(
        pageCount: 2,
        texts: <int, String>{
          0: '第一行无\n第二行有 alpha 在\n第三行无',
          1: 'delta alpha',
        },
      );
      addTearDown(source.dispose);
      final List<SearchHit> hits = _hitsOf(await source
          .search('alpha', cancel: CancelToken())
          .toList());
      expect(hits, hasLength(2));

      // 页 0 文本「第一行无\n第二行有 alpha 在\n第三行无」逐字符：
      // 「第一行无」4 + \n 1 + 「第二行有 alpha 在」12 + \n 1 + 「第三行无」4 = 22；
      // 「alpha」at = 4+1+4+1 = 10（「第二行有 」5 字后），所在行 = 「第二行有 alpha 在」；
      // offset = 0 + 10 = 10。
      expect(hits[0].context, '第二行有 alpha 在');
      expect(hits[0].offset, 10);

      // 页 1 与页 0 同章（0~/10=0）：offset = 页 0 文本长 22 + at 6（「delta 」6 字）= 28。
      expect(hits[1].context, 'delta alpha');
      expect(hits[1].offset, 28);
    });

    test('chapterIndex 按伪分章折算，标题与 chapters() 同源', () async {
      final PdfSource source = _source(
        pageCount: 12,
        texts: <int, String>{11: 'alpha'},
      );
      addTearDown(source.dispose);
      final List<SearchHit> hits = _hitsOf(await source
          .search('alpha', cancel: CancelToken())
          .toList());
      expect(hits, hasLength(1));
      expect(hits[0].chapterIndex, 1, reason: '页 11 → 11~/10 = 章 1');
      final List<Chapter> chapters = await source.chapters();
      expect(chapters, hasLength(2), reason: '12 页 → 伪分章 2 章（N=10）');
      expect(hits[0].chapterTitle, chapters[1].title);
    });

    test('progress 按页单调递增且以 1.0 收尾（RUST-05 ③）', () async {
      final PdfSource source = _source(
        pageCount: 4,
        texts: <int, String>{0: 'alpha'},
      );
      addTearDown(source.dispose);
      final List<double> progress = (await source
              .search('alpha', cancel: CancelToken())
              .toList())
          .map((SearchEvent e) => e.progress)
          .nonNulls
          .toList();
      expect(progress, <double>[0.25, 0.5, 0.75, 1.0]);
      for (int i = 1; i < progress.length; i++) {
        expect(progress[i] > progress[i - 1], isTrue);
      }
    });

    test('取消：预取消空流、中途取消立即止步', () async {
      final PdfSource source = _source(
        pageCount: 4,
        texts: <int, String>{
          for (int p = 0; p < 4; p++) p: 'alpha alpha alpha',
        },
      );
      addTearDown(source.dispose);

      final CancelToken pre = CancelToken()..cancel();
      expect(await source.search('alpha', cancel: pre).toList(), isEmpty);

      // 中途取消：首条事件后 cancel，剩余页的命中与进度都不再产出。
      final CancelToken mid = CancelToken();
      final List<SearchEvent> seen = <SearchEvent>[];
      await source.search('alpha', cancel: mid).forEach((SearchEvent e) {
        seen.add(e);
        if (seen.length == 1) mid.cancel();
      });
      expect(seen.length, lessThanOrEqualTo(2),
          reason: '首条后即止步（页 0 三条命中先于进度，允许竞态 1~2 条）');
    });

    test('空 query 空流；无文本层页（扫描件）零命中但进度照常', () async {
      final PdfSource source = _source(pageCount: 3); // texts 全空 = 全书扫描件
      addTearDown(source.dispose);
      expect(await source.search('', cancel: CancelToken()).toList(), isEmpty);

      final List<SearchEvent> events =
          await source.search('alpha', cancel: CancelToken()).toList();
      expect(_hitsOf(events), isEmpty);
      expect(events.map((SearchEvent e) => e.progress).nonNulls.toList(),
          <double>[1 / 3, 2 / 3, 1.0]);
    });

    test('searchable=true 且 searchSpec=null（句柄源分流依据）', () async {
      final PdfSource source = _source();
      addTearDown(source.dispose);
      expect(source.capabilities().searchable, isTrue,
          reason: '文本层搜索已接入（Q4 ②）→ 契约「声明可搜就必须搜得到」生效');
      expect(source.searchSpec, isNull,
          reason: '引擎句柄不可序列化 → 驱动层走本 isolate 流式');
    });

    test('dispose 后 search 立即结束（dispose 契约）', () async {
      final PdfSource source = _source(
        pageCount: 2,
        texts: <int, String>{0: 'alpha'},
      );
      await source.dispose();
      expect(await source.search('alpha', cancel: CancelToken()).toList(),
          isEmpty);
    });
  });
}
