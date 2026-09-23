// `test/reader/reader_page_test.dart`：阅读页 widget 测试（`RD-03` / `RD-04` / `NAV-01`）。
//
// 用可注入的假 [BookSource]（不碰真实解析）以获得**可控**的章节表，聚焦验收点。
//
// ⚠️ 测试体里的**真异步 IO** 必须包在 `tester.runAsync` 里；而 widget 内部
// （`initState` / 回调）发起的真异步 IO 在 `testWidgets` 的 FakeAsync 区**不会自行推进**，
// 且载入期 `CircularProgressIndicator` 是无限动画 → `pumpAndSettle` 会**超时挂死**。
// 故统一用 [_settle]（`runAsync` 让出真实事件循环 + 多轮 `pump` 交替推进），**不用** `pumpAndSettle`。
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

/// 可控的假书源：章数 / 每章段落数可注入（默认 3 章 × 20 段，标题 第一/二/三章）。
///
/// 每章默认给足 20 段，使整本内容**明显高于视口**——这样「恢复/跳章」必须真的滚动，
/// 断言「第一章不可见」才有意义（内容过矮时整屏全可见，断言会失真）。
/// 章数超过 3 时标题按中文数字顺延（第六章 / 第二十章…），href 恒为 `h{序号}`。
class _FakeSource implements BookSource {
  _FakeSource({List<int>? paragraphCounts})
      : paragraphCounts =
            paragraphCounts ?? const <int>[20, 20, 20];

  /// 每章段落数（下标 = 章下标；长度 = 章数）。
  final List<int> paragraphCounts;

  bool disposed = false;

  /// 中文数字标题（1~29；测试用书最多 20 章）。
  static String _titleAt(int index) {
    const List<String> digits = <String>[
      '一', '二', '三', '四', '五', '六', '七', '八', '九',
    ];
    final int n = index + 1;
    if (n < 10) return '第${digits[n - 1]}章';
    if (n == 10) return '第十章';
    if (n < 20) return '第十${digits[n - 11]}章';
    return n == 20 ? '第二十章' : '第二十${digits[n - 21]}章';
  }

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
  Future<List<Chapter>> chapters() async {
    if (disposed) return const <Chapter>[];
    return <Chapter>[
      for (int i = 0; i < paragraphCounts.length; i++)
        Chapter(href: 'h${i + 1}', title: _titleAt(i), level: 0, locate: ''),
    ];
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    if (disposed) return ChapterContent.paragraphs(const <String>[]);
    return ChapterContent.paragraphs(<String>[
      for (int p = 1; p <= paragraphCounts[chapterIndex]; p++)
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
  Future<Uint8List?> readResource(String href) async => null;

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

/// 可计数的进度存储：`save` 次数 = `_saveProgress` 真实落盘次数。
///
/// `RC1` 写盘闸门的可注入断言缝——「恢复未收敛期间一次都不许写」直接看计数。
class _CountingProgressStore extends ProgressStore {
  _CountingProgressStore(super.paths);

  int saveCount = 0;

  @override
  Future<void> save(ReadingProgress progress) async {
    saveCount++;
    await super.save(progress);
  }
}

void main() {
  group('ReaderPage', () {
    late Directory tempDir;
    late AppPaths paths;
    late ProgressStore progressStore;
    late LibraryRepository repo;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mreader_reader_');
      paths = _TestAppPaths(tempDir);
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

    Widget buildApp({BookSource? source, ProgressStore? store}) => MaterialApp(
          home: ReaderPage(
            source: source ?? _FakeSource(),
            record: record(),
            progressStore: store ?? progressStore,
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

    // ── 进度漂移回归（#36：RC1~RC4）────────────────────────────────────

    testWidgets('回归①：开→关循环 8 次，(chapterIndex, chapterPos) 不累积偏离',
        (WidgetTester tester) async {
      final _CountingProgressStore counting = _CountingProgressStore(paths);
      // 播种语义目标：第 2 章 0.5（无 localHint，首开走估算 + 语义校正路径）。
      await tester.runAsync(
        () => counting.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h2',
            chapterIndex: 1,
            chapterPos: 0.5,
            updatedAt: 1,
          ),
        ),
      );

      for (int cycle = 1; cycle <= 8; cycle++) {
        await tester.pumpWidget(buildApp(store: counting));
        await _settle(tester, rounds: 40);
        // 关书：dispose() 触发一次受闸门裁决的保存。
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));

        final ReadingProgress? snap =
            await tester.runAsync<ReadingProgress?>(() => counting.load('testbook01'));
        expect(snap, isNotNull, reason: '第 $cycle 轮关书后应有存档');
        expect(snap!.chapterIndex, 1,
            reason: '第 $cycle 轮：章不得漂移（多次进出偏离原章节的直接回归）');
        expect(snap.chapterPos, inInclusiveRange(0.4, 0.6),
            reason: '第 $cycle 轮：章内位置不得累积偏离播种目标 0.5');

        if (cycle == 1) {
          // 首轮确有真实写盘（证明本循环是「restore → save → restore…」在写，
          // 而不是「全员被闸门拦下」的假绿）。
          expect(counting.saveCount, greaterThanOrEqualTo(1));
          // 注入「已加载集合变化后同一像素指向别处」的脏 localHint
          //（RC1/RC2 的历史产物）：语义字段保持 (1, 0.5)——
          // 新实现必须用语义坐标自我纠正回来，旧实现会把落点错章写回存档。
          final LocalLayoutHint hint = snap.localHint!;
          await tester.runAsync(
            () => counting.save(
              snap.copyWith(
                localHint: LocalLayoutHint(
                  scrollOffset: hint.scrollOffset + 600,
                  fontSize: hint.fontSize,
                  lineHeight: hint.lineHeight,
                  viewportWidth: hint.viewportWidth,
                  viewportHeight: hint.viewportHeight,
                ),
              ),
            ),
          );
        }
      }
    });

    testWidgets('回归②：恢复未收敛期间 _saveProgress 零落盘，存档原封不动',
        (WidgetTester tester) async {
      final _CountingProgressStore counting = _CountingProgressStore(paths);
      // 播种存档（带 updatedAt 哨兵：被重写过就能看出来）。
      await tester.runAsync(
        () => counting.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h6',
            chapterIndex: 5,
            chapterPos: 0.5,
            updatedAt: 1,
          ),
        ),
      );
      expect(counting.saveCount, 1); // 播种本身

      // 20 章：第 6 章(下标5)前的真实章极高(150 段)、它与第 7 章极矮(2 段)——
      // 首帧批次只载入 [4,5,6]，章序比例估算永远落不到第 6 章可见处，
      // 校正 8 帧耗尽仍未收敛（`target == null` 到最后一帧）。
      final List<int> counts = List<int>.generate(
        20,
        (int i) => (i == 5 || i == 6) ? 2 : 150,
      );
      await tester.pumpWidget(
        buildApp(source: _FakeSource(paragraphCounts: counts), store: counting),
      );
      await _settle(tester);

      // 恢复未收敛 → 一次都不许写（RC1：误差不得当真值写回）。
      expect(counting.saveCount, 1, reason: '未收敛期间不得有任何写盘');

      // 关书：dispose() 的保存同样被闸门拦下。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(counting.saveCount, 1, reason: 'dispose 保存也必须过写盘闸门');

      final ReadingProgress? saved =
          await tester.runAsync<ReadingProgress?>(() => counting.load('testbook01'));
      expect(saved, isNotNull);
      expect(saved!.updatedAt, 1, reason: '播种值原封未动 = 恢复误差从未落盘');
      expect(saved.chapterIndex, 5);
      expect(saved.chapterPos, 0.5);
    });

    testWidgets('回归③：语义坐标恢复——存第 2 章 0.5，重开仍落回第 2 章 0.5 附近',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h2',
            chapterIndex: 1,
            chapterPos: 0.5,
            updatedAt: 1,
          ),
        ),
      );

      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 几何断言：落点在第 2 章中部——章标题明显滚出视口顶（≥300px），
      // 且第 1 章已卸载、副标题切到「第2章」。
      expect(find.text('第二章'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);
      expect(find.textContaining('第2章'), findsWidgets);
      final double titleTop = tester.getTopLeft(find.text('第二章')).dy;
      final double viewportTop = tester.getTopLeft(find.byType(ListView)).dy;
      expect(titleTop - viewportTop, lessThan(-300),
          reason: '应落在章中部而非章首（chapterPos≈0.5 已生效）');

      // 关书回读：语义坐标仍在 (1, 0.5±0.1)。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      final ReadingProgress? saved =
          await tester.runAsync<ReadingProgress?>(() => progressStore.load('testbook01'));
      expect(saved, isNotNull);
      expect(saved!.chapterIndex, 1);
      expect(saved.chapterPos, inInclusiveRange(0.4, 0.6));
    });
  });
}
