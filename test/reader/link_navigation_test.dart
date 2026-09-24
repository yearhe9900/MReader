// `test/reader/link_navigation_test.dart`：链接跳转与返回（`CNT-04c`）。
//
// 三条验收：
//   ① 点脚注上标跳到注释段；
//   ② 能返回原位置（浮动「返回」按钮弹栈恢复，栈空隐藏）；
//   ③ 目标不存在静默忽略，不跳、不崩。
// 另覆盖跨文件 href（可带 `#fragment`）→ 反查 Chapter → 先跳章再章内定位。
//
// ⚠️ FakeAsync 陷阱同 `reader_page_test.dart`：widget 内部真异步 IO（进度保存）
// 在 FakeAsync 区不自行推进 → 统一用 [_settle]（runAsync 让出 + pump 交替），
// 不用 `pumpAndSettle`。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';

import '../test_config.dart';

/// 临时目录实现 [AppPaths]，仅用于测试。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir = Directory(
      '${_root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}

/// 带链接 / 锚点标记的假内容源（`BookSource` 假实现，`CNT-04c`）：2 章。
///
/// 第 1 章：脚注引用 `[1]`（章内 `#note1`）、坏链接 `[坏]`（`#missing` 不存在）、
/// 跨文件链接 `[2]`（`h2#note2`）；章尾有注释段 `\x00ID:note1\x00`。
/// 第 2 章：注释段 `\x00ID:note2\x00`。
/// 每章给足段落使内容明显高于视口——跳转必须真的滚动，断言才有意义。
class _LinkFakeSource implements BookSource {
  bool disposed = false;

  @override
  String get implId => 'dart-fake-link';

  @override
  Future<BookMeta> load() async => const BookMeta(
        title: '内嵌书名',
        titleOrigin: MetaOrigin.metadata,
        author: '内嵌作者',
        authorOrigin: MetaOrigin.metadata,
        intro: '',
        introOrigin: MetaOrigin.none,
        cover: NoCover(),
        coverOrigin: MetaOrigin.none,
        language: 'zh',
      );

  @override
  Future<List<Chapter>> chapters() async => disposed
      ? const <Chapter>[]
      : const <Chapter>[
          Chapter(href: 'h1', title: '第一章', level: 0, locate: ''),
          Chapter(href: 'h2', title: '第二章', level: 0, locate: ''),
        ];

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    if (disposed) return ChapterContent.paragraphs(const <String>[]);
    if (chapterIndex == 0) {
      return ChapterContent.paragraphs(<String>[
        '第一章开头段落。',
        '这里有一个脚注引用 \x00A:#note1\x00[1]\x00A\x00，继续正文。',
        '这里有一个坏链接 \x00A:#missing\x00[坏]\x00A\x00，继续正文。',
        '这里有一个跨文件链接 \x00A:h2#note2\x00[2]\x00A\x00，继续正文。',
        for (int p = 1; p <= 10; p++) '第一章填充段落 $p。',
        '\x00ID:note1\x00这是注释一的内容。',
        '第一章结尾段落。',
      ]);
    }
    return ChapterContent.paragraphs(<String>[
      '第二章开头段落。',
      '\x00ID:note2\x00这是注释二的内容。',
      for (int p = 1; p <= 10; p++) '第二章填充段落 $p。',
      '第二章结尾段落。',
    ]);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: false,
        hasFootnotes: true,
        reflowable: true,
        searchable: false,
        charCountSupported: false,
      );

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) =>
      const Stream<SearchEvent>.empty();

  @override
  SearchBookSpec? get searchSpec => null;

  @override
  Future<int?> totalCharCount() async => null;

  @override
  Future<Uint8List?> readResource(String href) async => null;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 交替推进「真实事件循环」与「假异步帧」（同 reader_page_test 的 _settle）。
Future<void> _settle(WidgetTester tester, {int rounds = 60}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump(const Duration(milliseconds: 8));
  }
}

/// 找到可见文本包含 [needle] 的 RichText（段落是 Text.rich，find.text 不匹配）。
Finder _richTextContaining(String needle) => find.byWidgetPredicate(
      (Widget w) => w is RichText && w.text.toPlainText().contains(needle),
    );

/// [needle] 所在段落的顶部 y（全局坐标）。
double _topOf(WidgetTester tester, String needle) =>
    tester.getTopLeft(_richTextContaining(needle)).dy;

/// 视口（正文滚动区）顶部 y。
double _viewportTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(ListView)).dy;

/// 精确点击 [needle] 字形（链接文字）：用 [RenderParagraph.getBoxesForSelection]
/// 取字形盒中心，避免点到行内空白导致命中失败（`CNT-04b` 教训）。
Future<void> _tapGlyph(WidgetTester tester, String needle) async {
  final Finder finder = _richTextContaining(needle);
  expect(finder, findsOneWidget);
  final RenderParagraph para = tester.renderObject<RenderParagraph>(finder);
  final String plain = para.text.toPlainText();
  final int start = plain.indexOf(needle);
  expect(start, greaterThanOrEqualTo(0));
  final List<TextBox> boxes = para.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + needle.length),
  );
  expect(boxes, isNotEmpty);
  await tester.tapAt(para.localToGlobal(boxes.first.toRect().center));
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('CNT-04c 链接跳转与返回', () {
    late Directory tempDir;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_link_nav_');
      final AppPaths paths = _TestAppPaths(tempDir);
      progressStore = ProgressStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: FileCoverStore(paths));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    BookRecord record() => const BookRecord(
          bookId: 'linkbook01',
          fileName: '链接书.epub',
          filePath: 'linkbook01.epub',
          title: '链接书',
          author: '作者',
          format: 'epub',
          cover: NoCover(),
          importedAt: 1,
        );

    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: _LinkFakeSource(),
            record: record(),
            progressStore: progressStore,
            repository: repo,
          ),
        );

    testWidgets('验收①：点脚注上标 [1] 跳到注释段', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await _tapGlyph(tester, '[1]');
      await _settle(tester);

      // 注释段对齐视口顶部（段落定位精确）。
      expect(
        _topOf(tester, '这是注释一的内容'),
        closeTo(_viewportTop(tester), 5),
      );
      // 已压栈 → 浮动「返回」按钮出现。
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('验收②：点「返回」回到原位置，栈空后按钮隐藏',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 记录跳转前「[1] 段顶 - 视口顶」的偏移。
      final double before = _topOf(tester, '[1]') - _viewportTop(tester);

      await _tapGlyph(tester, '[1]');
      await _settle(tester);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // 弹栈恢复。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await _settle(tester);

      // 原位置精确落回（同一相对偏移）。
      expect(
        _topOf(tester, '[1]') - _viewportTop(tester),
        closeTo(before, 5),
      );
      // 栈空 → 「返回」按钮隐藏。
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('验收③：目标不存在静默忽略，不跳不崩不压栈',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      final double before = _topOf(tester, '[坏]') - _viewportTop(tester);

      await _tapGlyph(tester, '[坏]');
      await _settle(tester);

      // 不抛异常。
      expect(tester.takeException(), isNull);
      // 位置不动。
      expect(
        _topOf(tester, '[坏]') - _viewportTop(tester),
        closeTo(before, 5),
      );
      // 没跳 → 没压栈 → 无「返回」按钮。
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('跨文件 href 带 #fragment：跳到第 2 章注释段，再返回第 1 章',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      final double before = _topOf(tester, '[2]') - _viewportTop(tester);

      await _tapGlyph(tester, '[2]');
      await _settle(tester);

      // 反查 Chapter 命中第 2 章，且 #note2 段落对齐视口顶。
      expect(
        _topOf(tester, '这是注释二的内容'),
        closeTo(_viewportTop(tester), 5),
      );
      expect(find.textContaining('第2章'), findsWidgets);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // 返回原位置：回到第 1 章 [2] 段。
      await tester.tap(find.byIcon(Icons.arrow_back));
      await _settle(tester);

      expect(
        _topOf(tester, '[2]') - _viewportTop(tester),
        closeTo(before, 5),
      );
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });
  });
}
