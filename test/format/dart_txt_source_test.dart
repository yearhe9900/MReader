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
      expect(meta.author, '');
      expect(meta.authorOrigin, MetaOrigin.none);
      expect(meta.cover, isA<NoCover>());
      expect(meta.coverOrigin, MetaOrigin.none);
      await source.dispose();
    });

    test('文件名无有效书名时 title 为「未命名」而非空串', () async {
      final DartTxtSource source =
          DartTxtSource(fileName: '.txt', bytes: _utf8(_twoChaptersText()));
      expect((await source.load()).title, '未命名');
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
      expect(meta.titleOrigin, 'none');
      expect(meta.authorOrigin, 'none');
      expect(meta.coverOrigin, 'none');
      expect(await source.chapters(), isEmpty);
      expect((await source.content(0)).isEmpty, isTrue);
      expect(await source.totalCharCount(), isNull);
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
}
