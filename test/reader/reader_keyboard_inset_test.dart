// 「搜索页进书剧烈闪动」护栏。
//
// ## 机制
//
// 搜索页点书开读时**输入法还在收起途中**：阅读页 `Scaffold` 默认
// `resizeToAvoidBottomInset: true` ⇒ body 随键盘收起动画**逐帧变高** ⇒
// `_syncPageConfig` 的 `pageHeight` 每帧变 ⇒ 整章反复重排 = 剧烈闪动。
//
// ## 两条护栏
//
// ① 结构钉：阅读页 `Scaffold.resizeToAvoidBottomInset == false`（键盘不改
//    正文排版区，与 `extendBody*` 同属 `TYP-09`「正文一像素不动」契约）；
// ② 行为钉：注入 `viewInsets.bottom`（模拟键盘）后正文排版区**尺寸不变**。
//
// 搜索态点结果先收键盘 + 冻结布局的护栏随「就地搜索态」搬到
// `test/ui/shelf_page_test.dart`（搜索不再有独立页）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import 'reader_harness.dart';
import '../test_config.dart';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('键盘不改正文排版区（搜索页进书剧烈闪动护栏）', () {
    late Directory tempDir;
    late TestAppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_kb_');
      paths = TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = fakeRepository(paths);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildApp({EdgeInsets viewInsets = EdgeInsets.zero}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(viewInsets: viewInsets),
            child: ReaderPage(
              source: FakeBookSource(),
              record: fakeRecord(),
              progressStore: progressStore,
              repository: repo,
            ),
          ),
        );

    test('源码钉：阅读页热路径不得订阅全量 MediaQuery（键盘期逐帧重建的病根）', () {
      // `MediaQuery.of` 对 viewInsets 也建立依赖：键盘收起期逐帧触发重建——
      // 阅读页 build（整棵正文树）与 PageRenderer（每页）都必须改用按需订阅
      // / 非订阅式读取。注释行豁免（文档里允许提到该 API 名）。
      for (final String path in <String>[
        'lib/reader/reader_page.dart',
        'lib/reader/pagination/page_renderer.dart',
      ]) {
        final Iterable<String> codeLines = File(path)
            .readAsStringSync()
            .split('\n')
            .where((String l) => !l.trimLeft().startsWith('//'));
        expect(
          codeLines.any((String l) => l.contains('MediaQuery.of(')),
          isFalse,
          reason: '$path 热路径出现全量 MediaQuery 订阅：键盘收起期会逐帧重建',
        );
      }
    });

    testWidgets('结构钉：阅读页 Scaffold 键盘免疫', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      final Scaffold scaffold =
          tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.resizeToAvoidBottomInset,
        isFalse,
        reason: '键盘收起动画会让 body 逐帧变高 → 逐帧重排 = 剧烈闪动；'
            '正文区无输入框，应与 extendBody* 同款钉死',
      );
    });

    testWidgets('行为钉：注入键盘 inset 后正文排版区尺寸不变',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);
      final Size before = tester.getSize(find.byType(PagedScroller));

      await tester.pumpWidget(
          buildApp(viewInsets: const EdgeInsets.only(bottom: 300)));
      await settle(tester);
      final Size after = tester.getSize(find.byType(PagedScroller));

      expect(after, before,
          reason: '键盘 inset 不得改变正文排版区（否则开书转场期逐帧重排闪动）');
    });

  });
}
