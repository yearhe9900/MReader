// 阅读页图片页模式（CBZ / PDF 出图，`FMT-02`，M2b-T02）的 widget 测试。
//
// 用可注入的假 [BookSource]（每页一章、`imagePages` 单元素）聚焦三个验收点：
// · ① 打开按页顺序显示（整页图、不走段落渲染）；
// · ② 缩放入口：点页 → 全屏 `InteractiveViewer` 查看器（「不糊」= 原始字节解码）；
// · ③ 进度按页：目录跳页后存档 `chapterHref` = 页条目路径。
//
// ⚠️ 与 `reader_page_test.dart` 同款纪律：测试体真异步 IO 包 `runAsync`，
// 统一用 [_settle] 推进，**不用 `pumpAndSettle`**（载入期无限动画会挂死）。
import 'dart:io';
import 'dart:typed_data';

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
import 'package:mreader/typography/typeset.dart';

import 'reader_harness.dart';
import '../meta/meta_fixtures.dart';
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

/// 假图片内容源：3 页（每页一章），`readResource` 恒给真实 1×1 PNG。
class _ImageSource implements BookSource {
  static const List<String> pages = <String>['p/1.png', 'p/2.png', 'p/3.png'];

  bool disposed = false;

  @override
  String get implId => 'dart-fake-img';

  @override
  Future<BookMeta> load() async => const BookMeta(
        title: '图片书',
        titleOrigin: MetaOrigin.metadata,
        author: '假作者',
        authorOrigin: MetaOrigin.metadata,
        intro: '',
        introOrigin: MetaOrigin.none,
        cover: NoCover(),
        coverOrigin: MetaOrigin.none,
        language: '',
      );

  @override
  Future<List<Chapter>> chapters() async => <Chapter>[
        for (int i = 0; i < pages.length; i++)
          Chapter(href: pages[i], title: '第 ${i + 1} 页', level: 0, locate: ''),
      ];

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= pages.length) {
      return const ChapterContent.imagePages(<String>[]);
    }
    return ChapterContent.imagePages(<String>[pages[chapterIndex]]);
  }

  @override
  SourceCapabilities capabilities() => const SourceCapabilities(
        hasImages: true,
        hasFootnotes: false,
        reflowable: false,
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
  Future<List<int>?> chapterCharCounts() async => null;

  @override
  Future<List<int>?> chapterWeightEstimates() async => null;

  @override
  Future<Uint8List?> readResource(String href) async => kTinyPng;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 记录最后一次存档的进度存储（`FMT-02` 验收③断言缝）。
class _SpyProgressStore extends ProgressStore {
  _SpyProgressStore(super.paths);

  ReadingProgress? last;

  @override
  Future<void> save(ReadingProgress progress) async {
    last = progress;
    await super.save(progress);
  }
}

/// 交替推进「真实事件循环」与「假异步帧」（同 `reader_page_test.dart`）。
Future<void> _settle(WidgetTester tester, {int rounds = 60}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump(const Duration(milliseconds: 8));
  }
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  group('ReaderPage 图片页模式（FMT-02）', () {
    late Directory tempDir;
    late _SpyProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_imgpages_');
      final AppPaths paths = _TestAppPaths(tempDir);
      progressStore = _SpyProgressStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: FileCoverStore(paths));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Widget buildApp() => MaterialApp(
          home: ReaderPage(
            source: _ImageSource(),
            record: const BookRecord(
              bookId: 'imgbook001',
              fileName: '测试漫画.cbz',
              filePath: 'imgbook001.cbz',
              title: '测试漫画',
              author: '假作者',
              format: 'cbz',
              cover: NoCover(),
              importedAt: 1,
            ),
            progressStore: progressStore,
            repository: repo,
          ),
        );

    testWidgets('验收①：打开 CBZ 按页顺序显示（整页图，不走段落渲染）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 首屏 = 第 1 页整页图；图片页不出现段落 widget（与段落互斥）。
      expect(
          find.byKey(const Key('reader-image-page:p/1.png')), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      expect(find.byType(InlineParagraph), findsNothing);
    });

    testWidgets('验收②入口：点页 → 全屏缩放查看器（InteractiveViewer）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 打在图片**顶部**而非中心：这本假漫画按 800×800 铺开，整页图 rect 实测
      // 高 800（top 60 / bottom 860），**中心 y=460 已超出 600 的测试屏**。
      // `tester.tap` 打的是元素中心 ⇒ 命中的是别的 widget，点按静默失效。
      // 2026-10-06 正文避让系统栏后 viewport 变矮（469），该假设更容易不成立——
      // 但这是**测试的取点假设**随视口变化，与被测行为（点页 → 缩放查看器）无关。
      final Rect imageRect =
          tester.getRect(find.byKey(const Key('reader-image-page:p/1.png')));
      await tester.tapAt(
          Offset(imageRect.left + imageRect.width / 2, imageRect.top + 20));
      await tester.pumpAndSettle(); // 路由转场（无无限动画，可 settle）

      expect(find.byKey(const Key('reader-image-zoom')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('缩放查看'), findsOneWidget);

      // 返回阅读页。
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-image-zoom')), findsNothing);
    });

    testWidgets('验收③：进度按页——目录跳第 3 页后存档 chapterHref = 页路径',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 目录跳到第 3 页。
      await showChrome(tester);
      await tester.tap(find.byIcon(Icons.list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 3 页'));
      await tester.pumpAndSettle();
      await _settle(tester);
      await tester.pumpAndSettle();

      // 目标页整页可见（FMT-02 ① 按页跳转）。
      expect(
          find.byKey(const Key('reader-image-page:p/3.png')), findsOneWidget);

      // 触发一次用户滚动收尾 → 走 RC1 闸门落盘 → 按页存档。
      await tester.drag(find.byType(ListView), const Offset(0, -24));
      await _settle(tester);
      await tester.pumpAndSettle();

      final ReadingProgress? saved = progressStore.last;
      expect(saved, isNotNull, reason: '滚动收尾后应有一次真实落盘');
      expect(saved!.chapterHref, 'p/3.png',
          reason: 'FMT-02 ③ 进度按页：chapterHref = 页条目路径');
      expect(saved.chapterIndex, 2);
    });
  });
}
