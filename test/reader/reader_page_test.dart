// `test/reader/reader_page_test.dart`：阅读页 widget 测试（`RD-03` / `RD-04` / `NAV-01`）。
//
// 用可注入的假 [BookSource]（不碰真实解析）以获得**可控**的章节表，聚焦验收点。
//
// ⚠️ 测试体里的**真异步 IO** 必须包在 `tester.runAsync` 里；而 widget 内部
// （`initState` / 回调）发起的真异步 IO 在 `testWidgets` 的 FakeAsync 区**不会自行推进**，
// 且载入期 `CircularProgressIndicator` 是无限动画 → `pumpAndSettle` 会**超时挂死**。
// 故统一用 [_settle]（`runAsync` 让出真实事件循环 + 多轮 `pump` 交替推进），**不用** `pumpAndSettle`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_progress.dart';

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

/// 可控的假书源：3 章，标题固定为 第一章 / 第二章 / 第三章。
///
/// 每章给足 20 段，使整本内容**明显高于视口**——这样「恢复/跳章」必须真的滚动，
/// 断言「第一章不可见」才有意义（内容过矮时整屏全可见，断言会失真）。
class _FakeSource implements BookSource {
  bool disposed = false;

  /// 每章段落数（刻意大于一屏）。
  static const int _paragraphsPerChapter = 20;

  static const List<Chapter> _chapters = <Chapter>[
    Chapter(href: 'h1', title: '第一章', level: 0, locate: ''),
    Chapter(href: 'h2', title: '第二章', level: 0, locate: ''),
    Chapter(href: 'h3', title: '第三章', level: 0, locate: ''),
  ];

  @override
  String get implId => 'dart-fake';

  @override
  Future<BookMeta> load() async => const BookMeta(
        title: '内嵌书名', // 与 record.title 不同，用于证明 RD-03 取 record.title
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
  Future<List<Chapter>> chapters() async =>
      disposed ? const <Chapter>[] : List<Chapter>.of(_chapters);

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    if (disposed) return ChapterContent.paragraphs(const <String>[]);
    return ChapterContent.paragraphs(<String>[
      for (int p = 1; p <= _paragraphsPerChapter; p++)
        '第${chapterIndex + 1}章正文$p',
    ]);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: false,
        hasFootnotes: false,
        reflowable: true,
        searchable: false,
        charCountSupported: false,
      );

  @override
  Stream<SearchEvent> search(String query, {required CancelToken cancel}) =>
      const Stream<SearchEvent>.empty();

  @override
  Future<int?> totalCharCount() async => null;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 交替推进「真实事件循环」与「假异步帧」，直到 widget 内部的真异步 IO 完成。
///
/// `runAsync` 让出真实事件循环（让 `dart:io` 完成），`pump` 驱动帧 / post-frame 回调。
Future<void> _settle(WidgetTester tester, {int rounds = 60}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump(const Duration(milliseconds: 8));
  }
}

void main() {
  group('ReaderPage', () {
    late Directory tempDir;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_reader_');
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
          bookId: 'testbook01',
          fileName: '测试.txt',
          filePath: 'testbook01.txt',
          title: '书架书名', // RD-03：AppBar 应取这个，而非内嵌书名
          author: '书架作者',
          format: 'txt',
          cover: NoCover(),
          importedAt: 1,
        );

    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: _FakeSource(),
            record: record(),
            progressStore: progressStore,
            repository: repo,
          ),
        );

    testWidgets('RD-03 副标题为「第N章 · X%」，不含 implId 诊断信息',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 标题取书库记录标题（而非内嵌书名）
      expect(find.text('书架书名'), findsOneWidget);
      expect(find.text('内嵌书名'), findsNothing);

      // 不含诊断信息（implId `dart-fake` / 旧格式 `N 章 · dart-*`）
      expect(find.textContaining('dart-'), findsNothing);

      // 首章标题（正文目视）+ 进度百分比可见
      expect(find.text('第一章'), findsOneWidget);
      expect(find.textContaining('%'), findsWidgets);
      expect(find.textContaining('第1章'), findsWidgets);
    });

    testWidgets('NAV-01 目录：当前章高亮，点击第 3 项跳到第 3 章',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 打开目录
      await tester.tap(find.byIcon(Icons.list));
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNWidgets(3));
      // 当前章（第 1 章）高亮
      expect(
          tester.widget<ListTile>(find.byType(ListTile).at(0)).selected, isTrue);
      expect(
          tester.widget<ListTile>(find.byType(ListTile).at(2)).selected, isFalse);

      // 点击第 3 项 → 跳到第 3 章
      await tester.tap(find.text('第三章'));
      await tester.pumpAndSettle(); // 关闭弹窗 + 触发跳章
      await _settle(tester); // 推进跳章的异步保存 / 迭代校正
      await tester.pumpAndSettle(); // 收敛滚动落点

      // 弹窗关闭、正文滚到第三章、副标题显示「第3章」
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('第三章'), findsOneWidget);
      expect(find.textContaining('第3章'), findsWidgets);
    });

    testWidgets('RD-04 打开时按 href 恢复上次章节（href 优先于 index）',
        (WidgetTester tester) async {
      // 预置进度：href 指向第 3 章，但 chapterIndex 谎报为 0 → 应以 href 为准。
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h3',
            chapterIndex: 0,
            chapterPos: 0.0,
            updatedAt: 1,
          ),
        ),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 落到第 3 章：第三章可见，且第一章已滚出视口（内容高于一屏，证明真的滚动了）
      expect(find.text('第三章'), findsOneWidget);
      expect(find.textContaining('第3章'), findsWidgets);
      expect(find.text('第一章'), findsNothing);
    });

    testWidgets('RD-04 无进度时回落到第 1 章开头', (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(find.text('第一章'), findsOneWidget);
      expect(find.textContaining('第1章'), findsWidgets);
      expect(find.text('第三章'), findsNothing);
    });

    testWidgets('RD-04 同版面 localHint：跳到第 3 章保存后再打开精确落回第 3 章',
        (WidgetTester tester) async {
      // 第一次打开：跳到第 3 章（触发保存，进度带同版面 localHint）。
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(find.byIcon(Icons.list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第三章'));
      await tester.pumpAndSettle();
      await _settle(tester);
      await tester.pumpAndSettle();

      late ReadingProgress? saved;
      await tester.runAsync(() async {
        saved = await progressStore.load('testbook01');
      });
      expect(saved, isNotNull);
      expect(saved!.chapterIndex, 2);
      expect(saved!.chapterHref, 'h3');
      expect(saved!.localHint, isNotNull);

      // 第二次打开：同版面 → 用 initialScrollOffset 精确恢复。
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      expect(find.text('第三章'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);
    });
  });
}
