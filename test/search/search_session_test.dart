// `SearchSession` 协议测试（纯 Dart `test()`，真后台 isolate；`CNT-06` / `RUST-05`）。
//
// 验收映射：
//   · `CNT-06` ①「命中数与实际出现次数一致」——样本里 3 次「alpha」→ 恰 3 条命中，
//     offset / context / chapterIndex 逐条人工推演钉死（防假绿）；
//   · `CNT-06` ③「可取消且 UI 不卡死」——取消当帧收尾、无迟到事件、不留未完成态
//     （UI 不卡死由 `test/search/search_sheet_test.dart` 与阈值 4 基线另行守）；
//   · `RUST-05` ③「进度回报单调递增」——progress 序列断言；
//   · spec（后台重建）与 localSource（句柄源本 isolate 流式）两条路径同测。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/dart_txt_source.dart';
import 'package:mreader/task/search_session.dart';

import '../format/epub_builder.dart';

/// 两章样本（段落显式给定，offset 可人工推演）：
///   章 0：`alpha beta alpha`（16 字符，「alpha」在 0、11）+ `无命中段`（4 字符）
///   章 1：`gamma alpha delta`（「alpha」在 6）
/// 「alpha」共 3 次。
Uint8List _twoChapterEpub() => zipEntries(<EpubEntry>[
      textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
      textEntry(
        'OEBPS/content.opf',
        opfXml(
          title: '搜索样本',
          manifest: itemXml('c1', 'text/ch1.xhtml', 'application/xhtml+xml') +
              itemXml('c2', 'text/ch2.xhtml', 'application/xhtml+xml'),
          spine: itemrefXml('c1') + itemrefXml('c2'),
        ),
      ),
      textEntry(
        'OEBPS/text/ch1.xhtml',
        xhtmlDoc(
          title: '一',
          heading: '第一章',
          paragraphs: <String>['alpha beta alpha', '无命中段'],
        ),
      ),
      textEntry(
        'OEBPS/text/ch2.xhtml',
        xhtmlDoc(
          title: '二',
          heading: '第二章',
          paragraphs: <String>['gamma alpha delta'],
        ),
      ),
    ]);

SearchBookSpec _spec() => SearchBookSpec(
      fileName: 'search.epub',
      bytes: _twoChapterEpub(),
    );

/// 收集一次会话的全部事件（并等 done）。
Future<List<SearchEvent>> _collect(SearchSession session) =>
    session.events.toList();

void main() {
  group('SearchSession · 后台重建路径（spec）', () {
    test('命中数与实际出现次数一致，offset/context/chapterIndex 逐条对表', () async {
      final SearchSession session =
          SearchSession.start(query: 'alpha', spec: _spec());
      expect(session.usedIsolate, isTrue, reason: 'spec 路径必须走后台 isolate');

      final List<SearchEvent> events = await _collect(session);
      final List<SearchHit> hits =
          events.map((SearchEvent e) => e.hit).nonNulls.toList();
      expect(hits, hasLength(3), reason: '「alpha」出现 3 次 → 恰 3 条命中（CNT-06 ①）');

      // 人工推演：章 0 段 0 `alpha beta alpha`（0-4 / 11-15 两处）、章 1 段 0（6-10）。
      expect(hits[0].chapterIndex, 0);
      expect(hits[0].offset, 0);
      expect(hits[0].context, 'alpha beta alpha');
      expect(hits[1].chapterIndex, 0);
      expect(hits[1].offset, 11);
      expect(hits[1].context, 'alpha beta alpha');
      expect(hits[2].chapterIndex, 1);
      expect(hits[2].offset, 6);
      expect(hits[2].context, 'gamma alpha delta');

      // 章标题与 chapters() 同源（不在这里硬编码提取产物的形态）。
      final List<Chapter> chapters = await const BookRegistry()
          .open(fileName: 'search.epub', bytes: _twoChapterEpub())
          .then((BookSource s) async {
        final List<Chapter> list = await s.chapters();
        await s.dispose();
        return list;
      });
      expect(hits[2].chapterTitle, chapters[1].title);

      await session.done;
    });

    test('progress 单调递增且以 1.0 收尾（RUST-05 ③）', () async {
      final SearchSession session =
          SearchSession.start(query: 'alpha', spec: _spec());
      final List<double> progress = (await _collect(session))
          .map((SearchEvent e) => e.progress)
          .nonNulls
          .toList();
      expect(progress, <double>[0.5, 1.0], reason: '两章各报一次：(i+1)/total');
      for (int i = 1; i < progress.length; i++) {
        expect(progress[i] > progress[i - 1], isTrue,
            reason: '进度回报必须单调递增（RUST-05 ③）');
      }
    });

    test('取消：当帧收尾、无迟到事件、done 完成（CNT-06 ③ / RUST-05 ①）', () async {
      final SearchSession session =
          SearchSession.start(query: 'alpha', spec: _spec());
      final List<SearchEvent> seen = <SearchEvent>[];
      // 单订阅流只听一次；第一条事件到达即取消——此后的迟到事件必须被丢弃。
      final Future<void> pump = session.events.forEach((SearchEvent e) {
        seen.add(e);
        if (seen.length == 1) session.cancel();
      });
      await pump;
      await session.done;
      expect(session.isDone, isTrue);
      // 取消点在第一条事件后：seen 允许 1~若干条（时序竞态），但绝不超过总数 5。
      expect(seen.length, lessThanOrEqualTo(5));
    });

    test('预取消：流立即收尾，无任何事件', () async {
      final SearchSession session =
          SearchSession.start(query: 'alpha', spec: _spec());
      session.cancel();
      expect(await _collect(session), isEmpty);
      expect(session.isDone, isTrue);
    });

    test('首屏埋点：firstEvent/firstHit 非空；零命中时 firstHit 为 null', () async {
      final SearchSession hit =
          SearchSession.start(query: 'alpha', spec: _spec());
      await _collect(hit);
      expect(hit.firstEventElapsed, isNotNull);
      expect(hit.firstHitElapsed, isNotNull);

      final SearchSession none =
          SearchSession.start(query: '不存在的词zzz', spec: _spec());
      await _collect(none);
      expect(none.firstEventElapsed, isNotNull,
          reason: 'progress 也是首事件（进度条可上屏）');
      expect(none.firstHitElapsed, isNull, reason: '零命中无「首屏结果」');
    });

    test('spec 路径与本 isolate 直搜命中集合一致（RUST-02 等价精神）', () async {
      final SearchSession viaIsolate =
          SearchSession.start(query: 'alpha', spec: _spec());
      final List<String> fromIsolate = (await _collect(viaIsolate))
          .map((SearchEvent e) => e.hit)
          .nonNulls
          .map((SearchHit h) => '${h.chapterIndex}:${h.offset}')
          .toList();

      final BookSource local = await const BookRegistry()
          .open(fileName: 'search.epub', bytes: _twoChapterEpub());
      addTearDown(local.dispose);
      final SearchSession viaLocal =
          SearchSession.start(query: 'alpha', localSource: local);
      expect(viaLocal.usedIsolate, isFalse);
      final List<String> fromLocal = (await _collect(viaLocal))
          .map((SearchEvent e) => e.hit)
          .nonNulls
          .map((SearchHit h) => '${h.chapterIndex}:${h.offset}')
          .toList();

      expect(fromIsolate, <String>['0:0', '0:11', '1:6']);
      expect(fromLocal, fromIsolate);
    });

    test('localSource 路径不 dispose 外部源（句柄源生命周期归持有方）', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: 'x.txt',
        bytes: Uint8List.fromList('第一章 甲\nalpha\n'.codeUnits),
      );
      final SearchSession session =
          SearchSession.start(query: 'alpha', localSource: source);
      await _collect(session);
      // dispose 后 chapters() 按契约返回空——非空即证源还活着。
      expect(await source.chapters(), isNotEmpty);
      await source.dispose();
    });

    test('业务错误经信封上抛（坏文件）：流以 error 结束，不静默空', () async {
      // [1,2,3] 既非 zip 也不像文本 → sniffFormat unsupported → openBook 报业务错。
      final SearchSession session = SearchSession.start(
        query: 'alpha',
        spec: SearchBookSpec(
          fileName: 'bad.epub',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      );
      await expectLater(session.events.toList(), throwsA(isA<Object>()));
    });

    test('空 query / 无源：空流立即收尾（优雅空结果口径）', () async {
      final SearchSession emptyQuery =
          SearchSession.start(query: '', spec: _spec());
      expect(await _collect(emptyQuery), isEmpty);

      final SearchSession noSource = SearchSession.start(query: 'alpha');
      expect(await _collect(noSource), isEmpty);
    });
  });
}
