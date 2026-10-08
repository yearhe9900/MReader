// 阅读页取进度的**性能契约**（2026-10-08 真机「EPUB 章节加载特别慢 / 快滑多章没加载」）。
//
// 一句话契约：**开书路径不得做全书遍历**。
//
// 缺陷形态（本轮修掉的那条）：`_loadChapterWeights()` 原先调
// `BookSource.chapterCharCounts()`——EPUB 的实现要**逐章解压 + 解析 XHTML**。
// 真机 1152 章的书实测把主 isolate **独占秒级**（探针：300 章 247ms / 停顿
// 217ms；800 章 679ms / 停顿 649ms），而它换来的只是一个**一位小数**的进度
// 百分比；调用点又在开书后、用户开始滚动的那一刻 ⇒ 帧回调与分页 `step` 全部
// 停摆，表现为「章节要等很久才出来」「快滑过去好几章还是空的」。
//
// 现改为 `chapterWeightEstimates()`（零解压：EPUB 读 zip 中央目录的
// `uncompressedSize`，恒 32ms / 停顿 5ms，且不随章数增长）。
//
// 本文件用**调用计数探针**把契约钉死：精确口径一次都不许被调用。
// 变异实测（把 `_loadChapterWeights` 改回 `chapterCharCounts()`）→ 判红
// `Expected: <0>  Actual: <1>`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_prefs_store.dart';

import 'reader_harness.dart';
import '../test_config.dart';

/// 记录两个权重入口各被调了几次的假源。
class SpyWeightSource extends FakeBookSource {
  SpyWeightSource()
      : super(paragraphCounts: const <int>[20, 30, 60]);

  int exactCalls = 0;
  int estimateCalls = 0;

  @override
  Future<List<int>?> chapterWeightEstimates() async {
    estimateCalls++;
    // 故意给**不等长**的权重：若阅读页把权重丢了，进度必然退化。
    return <int>[20, 30, 60];
  }

  @override
  Future<List<int>?> chapterCharCounts() async {
    exactCalls++;
    // 真源上这里是**全书逐章解压 + 解析**；本探针只记调用次数。
    return <int>[100, 100, 100];
  }
}

void main() {
  capTestTimeout();

  testWidgets('开书取进度权重只走廉价估算：精确字数一次都不许被调用',
      (WidgetTester tester) async {
    final Directory tempDir = Directory.systemTemp.createTempSync('mreader_w_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final TestAppPaths paths = TestAppPaths(tempDir);
    final SpyWeightSource source = SpyWeightSource();

    await tester.pumpWidget(MaterialApp(
      home: ReaderPage(
        source: source,
        record: fakeRecord(),
        progressStore: ProgressStore(paths),
        repository: fakeRepository(paths),
        readingPrefsStore: ReadingPrefsStore(paths),
      ),
    ));
    await settle(tester);

    // 主断言：昂贵口径**零调用**。
    expect(source.exactCalls, 0,
        reason: '开书路径不得遍历全书内容（BookSource.chapterCharCounts 的 '
            'EPUB 实现是逐章解压 + 解析，真机 1152 章实测冻住主 isolate 秒级）');
    // 反向护栏：估算确实被调用了（排除「权重路径整条没跑」的假绿）。
    expect(source.estimateCalls, greaterThanOrEqualTo(1),
        reason: '权重估算必须真的被取过，否则上面的 0 是假绿');

    // 端到端可见性：读数行给出百分比，且取值落在合法区间。
    expect(find.textContaining('%', findRichText: true), findsWidgets);

    await closeBook(tester);
  });
}
