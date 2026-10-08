// 每章**权重估算**契约（2026-10-08 真机「EPUB 章节加载特别慢」定案）。
//
// 背景：阅读页的进度百分比原先走 `chapterCharCounts()`——**逐章解压 + 解析
// XHTML** 统计精确字数。真机 1152 章的书实测：整本书扫一遍把主 isolate
// **独占秒级**（探针：300 章 247ms / 停顿 217ms；800 章 679ms / 停顿 649ms），
// 且正好落在开书后用户开始滚动的那一刻 ⇒「章节要等很久才出来 / 快滑过去好几章
// 还是空的」。现改走 `chapterWeightEstimates()`：**只读 zip 中央目录里的
// `uncompressedSize`**（`ArchiveFile.size`，`zip-decoder` 写自解压前即可得的
// 中央目录），零解压、零 HTML 解析（同一探针：恒 32ms / 停顿 5ms，且不随章数增长）。
//
// 本文件钉三条：
//   ① **实现口径**：值必须就是该章 zip 条目的解压后字节长度（纯元数据读数）；
//   ② **精度够用**：换算成「全书进度百分比」的偏差须远小于等权退化；
//   ③ dispose 契约：释放后返回 null。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/dart_epub_source.dart';
import 'package:mreader/model/chapter.dart';

import 'epub_builder.dart';

/// 造一本**各章长度悬殊**的 EPUB（权重估算的判别力全在「不等长」上：
/// 各章等长时等权就是精确解，任何权重都测不出差别）。
Uint8List buildUnevenEpub(List<List<String>> chapters) {
  final StringBuffer manifest = StringBuffer();
  final StringBuffer spine = StringBuffer();
  final List<EpubEntry> entries = <EpubEntry>[
    textEntry('META-INF/container.xml', containerXml('OEBPS/content.opf')),
  ];
  for (int i = 0; i < chapters.length; i++) {
    manifest.write(itemXml('c$i', 'text/ch$i.xhtml', 'application/xhtml+xml'));
    spine.write(itemrefXml('c$i'));
    entries.add(textEntry(
      'OEBPS/text/ch$i.xhtml',
      xhtmlDoc(
        title: '第$i章',
        heading: '第$i章',
        paragraphs: chapters[i],
      ),
    ));
  }
  entries.add(textEntry(
    'OEBPS/content.opf',
    opfXml(
      title: '权重样本',
      manifest: manifest.toString(),
      spine: spine.toString(),
    ),
  ));
  return zipEntries(entries);
}

/// 把一组「每章权重」换算成「读到每章开头时的全书进度百分比」，返回序列。
List<double> progressSequence(List<int> weights) {
  final int total = weights.fold<int>(0, (int a, int b) => a + b);
  final List<double> out = <double>[];
  int before = 0;
  for (final int w in weights) {
    out.add(total == 0 ? 0 : before / total * 100);
    before += w;
  }
  return out;
}

/// 两组权重算出的进度百分比序列的**最大偏差（百分点）**。
double maxProgressDeviation(List<int> a, List<int> b) {
  final List<double> pa = progressSequence(a);
  final List<double> pb = progressSequence(b);
  double worst = 0;
  for (int i = 0; i < pa.length; i++) {
    final double d = (pa[i] - pb[i]).abs();
    if (d > worst) worst = d;
  }
  return worst;
}

void main() {
  const String filler = '正文内容用于撑出足够长的单章体量，避免标签占比过大。';
  final List<List<String>> chapterSpec = <List<String>>[
    List<String>.generate(50, (int i) => '第1章第$i段$filler'),
    List<String>.generate(100, (int i) => '第2章第$i段$filler'),
    List<String>.generate(200, (int i) => '第3章第$i段$filler'),
  ];

  test('权重估算 = 该章 zip 条目的解压后字节长度（零解压纯元数据口径）', () async {
    final Uint8List bytes = buildUnevenEpub(chapterSpec);
    final DartEpubSource source =
        DartEpubSource(fileName: 'uneven.epub', bytes: bytes);
    addTearDown(source.dispose);

    final List<Chapter> chapters = await source.chapters();
    expect(chapters.length, 3);

    final List<int>? est = await source.chapterWeightEstimates();
    expect(est, isNotNull);
    expect(est!.length, chapters.length, reason: '长度须与 chapters() 一致');
    expect(est.every((int v) => v > 0), isTrue,
        reason: '每章都应有正权重（全 0 会静默退化成等权，把缺陷藏起来）');

    // ① 独立从 zip 中央目录核对：值 == 该条目的 uncompressedSize。
    //    这条钉死实现口径——若有人把它改回「解压 + 数字数」（或被 UTF-16/字节
    //    混淆），数值立刻不等而判红。
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    for (int i = 0; i < chapters.length; i++) {
      final ArchiveFile file =
          archive.files.firstWhere((ArchiveFile f) => f.name == 'OEBPS/text/ch$i.xhtml');
      expect(est[i], file.size,
          reason: '第 $i 章权重应等于其 zip 条目的解压后字节长度');
    }

    // 单调性：章内文本越多 ⇒ 权重越大（夹具是 50/100/200 段）。
    expect(est[0], lessThan(est[1]));
    expect(est[1], lessThan(est[2]));
  });

  test('权重估算换算成进度百分比的偏差，远小于等权退化', () async {
    final Uint8List bytes = buildUnevenEpub(chapterSpec);
    final DartEpubSource source =
        DartEpubSource(fileName: 'uneven.epub', bytes: bytes);
    addTearDown(source.dispose);

    final List<int> exact = (await source.chapterCharCounts())!;
    final List<int> est = (await source.chapterWeightEstimates())!;

    // ② 真正被消费的量是「全书进度百分比」（一位小数）。
    //    实测：估算 **0.52** 个百分点，等权 24.24 个百分点 —— **好 47 倍**。
    //    阈值取 5.0：留足余量（真实书的章长差异比本夹具的等比例序列更大），
    //    但足以把「权重退化成等权 / 常数」一把抓住。
    //    变异实测（把估算改成 `out[i] = 1`）→ 本断言判红：
    //      `Expected: a value less than <5.0>  Actual: <24.2398164084911>`。
    final double estDev = maxProgressDeviation(est, exact);
    expect(estDev, lessThan(5.0),
        reason: '权重估算换算出的进度百分比与精确口径的偏差必须很小'
            '（本夹具实测 ${estDev.toStringAsFixed(2)} 个百分点）');

    // 夹具判别力自检：各章等长时等权 = 精确解，本夹具故意不等长——
    // 等权在这种书上的偏差极大，证明「权重可忽略」的回归一定会被抓到。
    final List<int> equal = List<int>.filled(exact.length, 1);
    final double equalDev = maxProgressDeviation(equal, exact);
    expect(equalDev, greaterThan(20.0),
        reason: '夹具必须能区分「有权重」与「等权」'
            '（等权在本夹具的偏差实测 ${equalDev.toStringAsFixed(2)} 个百分点）');
    expect(estDev, lessThan(equalDev / 10),
        reason: '权重估算的精度须比等权退化高一个数量级');
  });

  test('dispose 之后 chapterWeightEstimates 返回 null（优雅空结果）', () async {
    final Uint8List bytes = buildUnevenEpub(chapterSpec);
    final DartEpubSource source =
        DartEpubSource(fileName: 'uneven.epub', bytes: bytes);
    await source.chapters(); // 先让结构就绪，再 dispose，避免测成「没解析过」
    await source.dispose();
    expect(await source.chapterWeightEstimates(), isNull);
  });
}
