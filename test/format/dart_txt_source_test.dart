// DartTxtSource 单测（PRD `RD-02` / §7.1；`CNT-06` 纯 Dart 基线）。
//
// 期望值全部来自 `.scratch/` 探针**实测**（先探针、后断言），非凭记忆硬编码。
// 分章算法照译参考实现 `TextFile.kt`（含其 `csNum / numE / maxNum` 择优语义），
// 因此本文件也是「忠实度护栏」——若有人改动择优阈值，这里会红。
import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/format/dart_txt_source.dart';
import 'package:mreader/meta/meta_source.dart' show kUnknownAuthor;
import 'package:mreader/task/isolate_runner.dart';

/// 记录派发的 spy runner（真实派发照走，仅旁路记录调用）。
class _RecordingRunner extends IsolateRunner {
  final List<(Object?, Object?, String?)> calls = <(Object?, Object?, String?)>[];

  @override
  Future<R> run<M, R>(IsolateTask<M, R> task, M message, {String? debugLabel}) {
    calls.add((task, message, debugLabel));
    return super.run<M, R>(task, message, debugLabel: debugLabel);
  }
}

/// 派发必失败的 runner（模拟 spawn 失败 / 派发层故障，验回落路径）。
class _FailingRunner extends IsolateRunner {
  @override
  Future<R> run<M, R>(IsolateTask<M, R> task, M message, {String? debugLabel}) =>
      throw StateError('isolate 派发失败（模拟）');
}

/// 一行正文（21 个非空白字 + 换行），用来把「章正文」撑过择优阈值。
const String _line = '这是本章的正文内容，重复若干次以超过阈值。';

/// 无任何章节特征的普通行（27 字 + 换行 = 28 字/行）。
const String _plain = '这是一段没有任何章节标记的普通文本，用来验证按块切分。';

/// 造一段约 [n] 字的正文（带换行），模拟真实章节体量。
String _body(int n) {
  final StringBuffer sb = StringBuffer();
  while (sb.length < n) {
    sb.write('$_line\n');
  }
  return sb.toString();
}

/// 「第X章」两章 + 长正文（现实形态；实测走规则「目录」→ 2 章）。
String _twoChaptersText() => '第一章 起\n${_body(1500)}第二章 承\n${_body(1500)}';

Uint8List _gbk(String s) => Uint8List.fromList(gbk.encode(s));
Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('RD-02 ① GBK + 「第X章」', () {
    test('GBK 字节正确解码并按章切分、章名正确', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: '三国演义.txt',
        bytes: _gbk(_twoChaptersText()),
      );

      final List<Chapter> chapters = await source.chapters();
      expect(chapters.length, 2);
      expect(
        chapters.map((Chapter c) => c.title).toList(),
        <String>['第一章 起', '第二章 承'],
      );
      // href = `txt:<起始字符偏移>`（字符，非字节）。
      expect(chapters[0].href, 'txt:5');
      expect(chapters[1].href, 'txt:1529');

      final ChapterContent first = await source.content(0);
      expect(first.paragraphList, hasLength(69));
      expect(first.paragraphList.first, _line);
      await source.dispose();
    });

    test('load() 用文件名作书名（去目录/扩展名），作者等来源为空', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: r'D:\books\红楼梦.txt',
        bytes: _utf8(_twoChaptersText()),
      );
      final BookMeta meta = await source.load();
      expect(meta.title, '红楼梦');
      expect(meta.titleOrigin, MetaOrigin.filename);
      expect(meta.author, kUnknownAuthor);
      expect(meta.authorOrigin, MetaOrigin.none);
      expect(meta.cover, isA<NoCover>());
      expect(meta.coverOrigin, MetaOrigin.none);
      await source.dispose();
    });

    test('文件名无有效书名时 title 为「未命名书籍」而非空串', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: '.txt', bytes: _utf8(_twoChaptersText()));
      final BookMeta meta = await source.load();
      expect(meta.title, '未命名书籍');
      expect(meta.titleOrigin, MetaOrigin.none);
      await source.dispose();
    });
  });

  group('RD-02 ② 无章节标记 → 按块切分', () {
    test('按 10KB 块切分（非整本一章）且块有自动命名', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: '无标记.txt', bytes: _utf8('$_plain\n' * 600));
      final List<Chapter> chapters = await source.chapters();

      expect(chapters, hasLength(2), reason: '不能整本一章');
      expect(chapters[0].title, '第1章(1)');
      expect(chapters[1].title, '第1章(2)');
      // 块边界落在 10KB 之后的首个换行处。
      expect(chapters[1].href, 'txt:10247');
      await source.dispose();
    });
  });

  group('RD-02 卷误判过滤（csNum >= numE * 3）', () {
    test('连续「第N卷」不被当作正式章节（该规则被拒 → 走分块兜底）', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: '卷.txt',
        bytes: _utf8('第1卷\n第2卷\n第3卷\n第4卷\n'
            '第一章 开始\n${_body(1500)}第二章 继续\n${_body(1500)}'),
      );
      final List<Chapter> chapters = await source.chapters();

      // 实测：连续卷标题造成大量 <100 字短间隔（numE），使「第X章/卷」规则不满足
      // `csNum >= numE*3` 而被拒 → 无规则命中 → 10KB 分块兜底。
      expect(chapters, hasLength(1));
      expect(chapters.single.title, '第1章(1)');
      expect(
        chapters.any((Chapter c) => RegExp(r'^第\d+卷').hasMatch(c.title)),
        isFalse,
        reason: '「卷」不得成为正式章节',
      );
      await source.dispose();
    });
  });

  group('RD-02 超长章（> 100KB）二次拆分', () {
    test('单章超阈值被拆成「章名(N)」，原章不留空壳', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: '长.txt',
        bytes: _utf8('第一章 长\n${_body(150000)}第二章 尾\n短。\n'),
      );
      final List<Chapter> chapters = await source.chapters();

      expect(chapters, hasLength(16));
      expect(
        chapters.take(4).map((Chapter c) => c.title).toList(),
        <String>['第一章 长(1)', '第一章 长(2)', '第一章 长(3)', '第一章 长(4)'],
      );
      expect(chapters.last.title, '第二章 尾');
      await source.dispose();
    });
  });

  group('RD-02 ③ 大文件', () {
    test('约 2MB 文本能分完且章数合理（现场生成，不入库）', () async {
      final StringBuffer sb = StringBuffer();
      int n = 0;
      while (sb.length < 720000) {
        n++;
        sb.write('第$n章 标题$n\n${_body(1200)}');
      }
      final DartTxtSource source =
          DartTxtSource(fileName: 'big.txt', bytes: _utf8(sb.toString()));

      final List<Chapter> chapters = await source.chapters();
      expect(chapters.length, greaterThan(100));
      expect(chapters.length, lessThan(2000));
      expect((await source.content(1)).paragraphList, isNotEmpty);
      await source.dispose();
    });
  });

  group('content(i) 段落口径', () {
    test('按 \\r\\n|\\r|\\n 切段、逐行 trim、丢空行', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: 'p.txt',
        bytes: _utf8(
            '第一章 甲\n${_body(1500)}第二章 乙\n  第一段  \r\n\r\n\t第二段\t\n\n第三段\n'),
      );
      final ChapterContent content = await source.content(1);
      expect(content.paragraphList, <String>['第一段', '第二段', '第三段']);
      await source.dispose();
    });

    test('首行与章名重复时被剥离（前言章）', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: 'q.txt',
        bytes: _utf8(
            '前言\n${_body(1500)}第一章 甲\n${_body(1500)}第二章 乙\n${_body(1500)}'),
      );
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.first.title, '前言');
      final ChapterContent content = await source.content(0);
      expect(content.paragraphList.first, isNot('前言'), reason: '重复的章名要剥掉');
      expect(content.paragraphList.first, _line);
      await source.dispose();
    });

    test('越界索引返回空段落、不抛异常', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 'o.txt', bytes: _utf8(_twoChaptersText()));
      final int count = (await source.chapters()).length;
      expect((await source.content(count)).isEmpty, isTrue);
      expect((await source.content(-1)).isEmpty, isTrue);
      await source.dispose();
    });

    test('行首 \\uFEFF（BOM 残留）被清掉', () async {
      final DartTxtSource source = DartTxtSource(
        fileName: 'bom.txt',
        bytes: _utf8('\uFEFF${_twoChaptersText()}'),
      );
      final List<Chapter> chapters = await source.chapters();
      expect(chapters.first.title, '第一章 起');
      final ChapterContent content = await source.content(0);
      expect(content.paragraphList.first.contains('\uFEFF'), isFalse);
      await source.dispose();
    });
  });

  group('能力与分发', () {
    test('capabilities 与 totalCharCount', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 'c.txt', bytes: _utf8(_twoChaptersText()));
      final SourceCapabilities caps = source.capabilities();
      expect(caps.hasImages, isFalse);
      expect(caps.hasFootnotes, isFalse);
      expect(caps.reflowable, isTrue);
      expect(caps.searchable, isTrue);
      expect(caps.charCountSupported, isTrue);

      final int? count = await source.totalCharCount();
      expect(count, isNotNull);
      expect(count!, greaterThan(2000));
      await source.dispose();
    });

    test('chapterCharCounts：按章非空白计数（T03 字数加权原料）', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 'c2.txt', bytes: _utf8(_twoChaptersText()));

      final List<Chapter> chapters = await source.chapters();
      expect(chapters, hasLength(2));

      // 夹具字面量：每章正文 = _body(1500) = 69 行 × 21 非空白字 = 1449
      // （段起点在标题匹配之后，标题行不计入）。
      final List<int>? counts = await source.chapterCharCounts();
      expect(counts, <int>[1449, 1449]);
      expect(counts, hasLength(chapters.length),
          reason: '长度与 chapters() 一致（接口契约）');

      // Σ ≤ totalCharCount：差值 = 标题行的非空白字（各 4 字）+ 空行不计——
      // 分段不含标题匹配文本，不承诺精确覆盖全书（接口文档口径）。
      final int total = (await source.totalCharCount())!;
      final int sum = counts!.fold<int>(0, (int a, int b) => a + b);
      expect(sum, 2898);
      expect(sum, lessThan(total));

      // 缓存：二次调用同一实例。
      expect(identical(counts, await source.chapterCharCounts()), isTrue);

      await source.dispose();
    });

    test('chapterWeightEstimates：分段长度（零扫描口径），供阅读页进度用', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 'c3.txt', bytes: _utf8(_twoChaptersText()));

      final List<Chapter> chapters = await source.chapters();
      final List<int>? est = await source.chapterWeightEstimates();
      expect(est, isNotNull);
      expect(est!.length, chapters.length, reason: '长度与 chapters() 一致（接口契约）');
      expect(est.every((int v) => v > 0), isTrue,
          reason: '每章都应有正权重（全 0 会静默退化成等权）');

      // 夹具字面量：分段 = 章标题之后到下一章标题之前，含各行的换行符。
      // `_body(1500)` = 69 行 × (21 字 + '\n') = 1518，另含标题行尾那一个 '\n'
      // ⇒ 1519。**不含**章标题文字本身（`_splitByRule` 的 segStart = m.end）——
      // 这正是「Σ 权重 ≠ 全书字数」的来源，接口文档已声明不承诺二者相等。
      expect(est, <int>[1519, 1519]);

      // 口径关系：估算含空白 ⇒ 恒 ≥ 精确口径（精确口径剔除空白）。
      final List<int> exact = (await source.chapterCharCounts())!;
      for (int i = 0; i < exact.length; i++) {
        expect(est[i], greaterThanOrEqualTo(exact[i]),
            reason: '估算 = 分段原始长度（含换行），必须 ≥ 非空白字数');
      }

      await source.dispose();
    });

    test('sniffFormat：.txt 与「无扩展名但内容是文本」都判 txt', () {
      expect(sniffFormat(fileName: 'a.txt', bytes: _utf8('hello')), FormatKind.txt);
      expect(
        sniffFormat(fileName: 'noext', bytes: _utf8('第一章 x\n正文')),
        FormatKind.txt,
      );
    });

    test('openBook(.txt) 返回 dart-txt', () async {
      final BookSource source =
          await openBook(fileName: 'a.txt', bytes: _utf8(_twoChaptersText()));
      expect(source.implId, 'dart-txt');
      expect(await source.chapters(), isNotEmpty);
      await source.dispose();
    });
  });

  group('搜索（CNT-06 纯 Dart 基线）', () {
    test('命中 / 进度 / 取消 / dispose 幂等', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 's.txt', bytes: _utf8(_twoChaptersText()));

      final List<SearchEvent> events =
          await source.search('正文', cancel: CancelToken()).toList();
      final List<SearchEvent> hits =
          events.where((SearchEvent e) => e.hit != null).toList();
      expect(hits, hasLength(138));
      expect(hits.first.hit!.chapterIndex, 0);
      expect(hits.any((SearchEvent e) => e.hit!.chapterIndex == 1), isTrue);
      // 每章末回报一次进度（2 章 → 2 次）。
      expect(events.where((SearchEvent e) => e.progress != null), hasLength(2));

      final CancelToken cancelled = CancelToken()..cancel();
      expect(await source.search('正文', cancel: cancelled).toList(), isEmpty);

      await source.dispose();
      await source.dispose(); // 幂等
    });
  });

  group('dispose 契约（RUST-01：上层无感，绝不抛）', () {
    test('dispose 之后：各方法返回优雅空结果、不抛异常', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 'd.txt', bytes: _utf8(_twoChaptersText()));
      await source.dispose();

      final BookMeta meta = await source.load();
      expect(meta.title, '未命名');
      expect(meta.titleOrigin, MetaOrigin.none);
      expect(meta.authorOrigin, MetaOrigin.none);
      expect(meta.coverOrigin, MetaOrigin.none);
      expect(meta.cover, isA<NoCover>());
      // 释放后 load() 的返回须满足 BookMeta 自身的不变式（META-01）：
      // author 不得留空（统一兜底「未知作者」），且三个 origin 均为合法 MetaOrigin。
      expect(meta.author.isNotEmpty, isTrue);
      expect(
        <MetaOrigin>[meta.titleOrigin, meta.authorOrigin, meta.introOrigin],
        everyElement(isIn(MetaOrigin.values)),
      );
      expect(await source.chapters(), isEmpty);
      expect((await source.content(0)).isEmpty, isTrue);
      expect(await source.totalCharCount(), isNull);
      expect(await source.chapterCharCounts(), isNull);
      expect(
        await source.search('正文', cancel: CancelToken()).toList(),
        isEmpty,
      );
    });

    test('dispose 竞态：content 已挂起后再 dispose，不抛（返回空）', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 'r.txt', bytes: _utf8(_twoChaptersText()));
      // 先完成准备，让 content 的 await 一定走「已就绪」分支（最易踩中 _text! / _segments!）。
      await source.chapters();
      final Future<ChapterContent> pending = source.content(0);
      await source.dispose();
      // 修复前：`_text!`（dart_txt_source.dart:132）null check 崩溃。
      final ChapterContent content = await pending;
      expect(content.isEmpty, isTrue);
    });

    test('dispose 竞态：尚未准备的 content 与 dispose 并发，不抛', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: 'r2.txt', bytes: _utf8(_twoChaptersText()));
      final Future<ChapterContent> pending = source.content(0);
      await source.dispose();
      expect((await pending).isEmpty, isTrue);
    });
  });

  // =====================================================================
  // PERF-01 接线（M2a-T06）：解码 + 分章经后台 isolate 任务 + 派发失败回落
  // =====================================================================
  group('PERF-01 接线（M2a-T06）', () {
    test('准备派发给后台 isolate 任务且 Future 去重', () async {
      final _RecordingRunner runner = _RecordingRunner();
      final Uint8List bytes = _utf8(_twoChaptersText());
      final DartTxtSource source = DartTxtSource(
        fileName: 'a.txt',
        bytes: bytes,
        runner: runner,
      );
      final List<Chapter> chapters = await source.chapters();
      expect(chapters, hasLength(2), reason: '文本 + 分段经信封回传后分章语义不变');
      expect(runner.calls, hasLength(1), reason: '准备任务只派发一次（Future 去重）');
      expect(identical(runner.calls.single.$2, bytes), isTrue,
          reason: 'message 就是原始字节（可序列化纯数据）');
      expect(runner.calls.single.$3, isNotEmpty);

      await source.content(0);
      await source.totalCharCount();
      expect(runner.calls, hasLength(1), reason: '文本/分段已缓存，后续调用不再派发');
      await source.dispose();
    });

    test('派发失败回落主 isolate：结果与业务错误语义均不变', () async {
      final _FailingRunner runner = _FailingRunner();
      final DartTxtSource source = DartTxtSource(
        fileName: 'a.txt',
        bytes: _utf8(_twoChaptersText()),
        runner: runner,
      );
      expect((await source.chapters()).length, 2, reason: '回落路径分章结果不变');
      expect((await source.content(0)).paragraphList, isNotEmpty);
      await source.dispose();

      final DartTxtSource empty = DartTxtSource(
        fileName: 'e.txt',
        bytes: _utf8('  \n  '),
        runner: runner,
      );
      await expectLater(
        empty.chapters(),
        throwsA(isA<MReaderFormatException>().having(
          (MReaderFormatException e) => e.code,
          'code',
          FormatErrorCode.txtNoContent,
        )),
        reason: '空文本业务错误（信封）原样抛出，与未接 isolate 前同型同码',
      );
      await empty.dispose();
    });
  });
}
