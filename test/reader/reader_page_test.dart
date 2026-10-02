// `test/reader/reader_page_test.dart`：阅读页 widget 测试（`RD-03` / `RD-04` / `NAV-01`）。
//
// 用可注入的假 [BookSource]（不碰真实解析）以获得**可控**的章节表，聚焦验收点。
//
// ⚠️ 测试体里的**真异步 IO** 必须包在 `tester.runAsync` 里；而 widget 内部
// （`initState` / 回调）发起的真异步 IO 在 `testWidgets` 的 FakeAsync 区**不会自行推进**，
// 且载入期 `CircularProgressIndicator` 是无限动画 → `pumpAndSettle` 会**超时挂死**。
// 故统一用 [_settle]（`runAsync` 让出真实事件循环 + 多轮 `pump` 交替推进），**不用** `pumpAndSettle`。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/diagnostics/perf_log.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/pagination/paged_scroller.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/reader/reader_page.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/ui/glass_kit.dart';

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

/// 可控的假内容源（`BookSource` 假实现）：章数 / 每章段落数可注入（默认 3 章 × 20 段，
/// 标题 第一/二/三章）。
///
/// 每章默认给足 20 段，使整本内容**明显高于视口**——这样「恢复/跳章」必须真的滚动，
/// 断言「第一章不可见」才有意义（内容过矮时整屏全可见，断言会失真）。
/// 章数超过 3 时标题按中文数字顺延（第六章 / 第二十章…），href 恒为 `h{序号}`。
class _FakeSource implements BookSource {
  _FakeSource({
    List<int>? paragraphCounts,
    Set<int>? hangIndices,
    Map<int, Completer<void>>? gates,
  })  : paragraphCounts = paragraphCounts ?? const <int>[20, 20, 20],
        hangIndices = hangIndices ?? const <int>{},
        gates = gates ?? const <int, Completer<void>>{};

  /// 每章段落数（下标 = 章下标；长度 = 章数）。
  final List<int> paragraphCounts;

  /// 永不返回内容的章下标（`content` 挂起）——用来稳定构造「某些章始终未加载」：
  /// 首帧批次之外的章永不驻留 → 布局不再变化、占位高不被实测值替换，
  /// 恢复期布局可冻结（见回归②：章高模型 seek 的收敛前提；回归②b：未落定即关书）。
  final Set<int> hangIndices;

  /// 可释放的加载闸门：`content(i)` 先 `await gates[i].future` 再返回——
  /// 「该章暂时取不到、测试显式放行后才到货」（回归④：模拟上方章稍后补齐，
  /// 观测占位→真实合入是否挪动视口）。与 [hangIndices] 的区别：hang 永不完成，
  /// gate 由测试择机 `complete()` 放行。
  final Map<int, Completer<void>> gates;

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
    if (hangIndices.contains(chapterIndex)) {
      // 永不完成：该章正文永远取不到 → 永远停留在估算占位高。
      return Completer<ChapterContent>().future;
    }
    final Completer<void>? gate = gates[chapterIndex];
    if (gate != null) {
      // 回归④：闸门放行前该章到不了货（放行后立即返回）。
      await gate.future;
      if (disposed) return ChapterContent.paragraphs(const <String>[]);
    }
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
  SearchBookSpec? get searchSpec => null;

  @override
  Future<int?> totalCharCount() async => null;

  @override
  Future<List<int>?> chapterCharCounts() async => null;

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
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
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

      // `UI-03`（M2a-T04）：目录壳层是玻璃底部弹窗，不是 Material bottom sheet。
      expect(find.byType(GlassSheet, skipOffstage: false), findsOneWidget);
      // `UI-04`：列表行垫在 OpaqueContentSurface 上（玻璃只留外壳）。
      expect(
        find.ancestor(
          of: find.byType(ListTile),
          matching: find.byType(OpaqueContentSurface),
        ),
        findsWidgets,
      );
      expect(
        isGlassWidget(find.byType(ListTile).evaluate().first.widget),
        isFalse,
      );
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

    testWidgets('RD-04 同版面 localHint：重开 seed 首帧落回第 3 章（backlog① 方案 A）',
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
      final LocalLayoutHint hint = saved!.localHint!;
      // 防假绿：第 3 章在书尾附近，seed 像素必明显大于 0——
      // 若 seed 为 0，下面的 seed 断言与「旧实现从 0 起跳」就没有区分力。
      expect(hint.scrollOffset, greaterThan(0));

      // ⚠️ 真·关书再开：`pumpWidget` 对**同类型无 key** 的 widget 走
      // `Widget.canUpdate` → Element/State **复用**（`initState`/`dispose` 都不跑）。
      // 直接再 pumpWidget(buildApp()) 的「第二次打开」是假绿——树根本没换、
      // controller 是第一次的（原版断言即栽在这个坑里）。必须先换异类 widget
      // 把树拆掉（同回归①②③），再排空 dispose 发起的假区保存（`AtomicFile._tails`
      // 按路径串行，活区同路径 IO 必须等它排空，否则跨区死锁）。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await _settle(tester, rounds: 20);

      // 第二次打开：同版面 → 用 initialScrollOffset 做首帧 seed。
      // 这正是 backlog① 方案 A 的直接验收场景：3 章书恢复 target=2 而首帧
      // 只载 [1,2] → `coversPrefix(2)=false`（「冷启动读中段」的普遍形态），
      // 走的是**回退分支**；旧实现该分支 `ScrollController()` 从 0 起跳，
      // 用户先看到「前几页」再被拉到「当前页」。
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 第二次打开：分页模式 seed 按**语义坐标**（窗口位×页高 + 章内比例×
      // 页高）落在目标章占位块——像素 hint 不再直接搬用，但「首帧不从 0 起跳」
      // 的验收不变（旧 ListView 实现此分支从 0 起跳 → 用户先看到前几页）。
      final PagedScroller paged =
          tester.widget<PagedScroller>(find.byType(PagedScroller));
      final ScrollController? seedController = paged.controller;
      expect(seedController, isNotNull);
      // 目标下标 2、3 章书窗口 [1,2] → 窗口位 1；章内比例 = 存档 chapterPos。
      final double expectedSeed =
          (1 + saved!.chapterPos.clamp(0.0, 1.0)) * paged.config.pageHeight;
      expect(
        seedController!.initialScrollOffset,
        expectedSeed,
        reason: '分页 seed 必须按语义坐标落在目标章占位块（窗口位×页高+章内比例×页高），不得从 0 起跳',
      );
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
        // 先排空 dispose 发起的**假区**保存再做后续活区 IO：`AtomicFile._tails`
        // 按路径串行化，假区保存的完成回调只有 pump 能排空；活区同路径写若
        // 在其排空前入队，会 await 队尾 gate 永久挂起（跨区死锁 → 30s 超时）。
        await _settle(tester, rounds: 20);
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
          // 关书那次保存**不得丢掉像素快照**：`Scrollable` 子节点先于本 State
          // 卸载、控制器已 detach → 现场读不到 offset，实现必须回退本会话最后
          // 可信快照（`_lastLocalHint`）。用 null 覆盖会让下次开书失去首帧精确落点。
          expect(snap.localHint, isNotNull,
              reason: 'dispose 保存必须带上最后可信的版面快照（不得被 null 覆盖）');
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

    testWidgets('回归②：深章节恢复必须收敛（分页一次落位，语义坐标写回）',
        (WidgetTester tester) async {
      final _CountingProgressStore counting = _CountingProgressStore(paths);
      // 播种存档：目标第 6 章（下标 5）章中 0.5。
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

      // 构造「深章节 + 上方有真实长章」：20 章里**只有首帧批次 `[4, 5, 6]` 能返回
      // 内容**，其余章（含目标章上方的 0~3）一律**永远挂起** → 后台补齐第一批就卡住，
      // 布局冻结在「0~3 用占位高 + 第 5 章(下标 4) 真实长章 + 目标章(下标 5)」上。
      //
      // **旧实现**（2026-09-23 探针实测）：恢复期 `maxScrollExtent` 在 26157 ↔ 290816
      // 之间振荡——懒构建下它是「已布局子项均值 × 剩余项数」的**外推估计值**，站在
      // 第 5 章里就被外推成「全书皆长章」。于是估算落点（`maxExtent × 5.5/20`）在
      // 7193 ↔ 79974 之间来回跳，8 帧耗尽仍不收敛、停在书尾占位区；目标章 box 始终
      // 未构建（`_chapterPointOffset(5, ·)` 恒 `null`）→ `RC1` 闸门关闭、零落盘。
      // 真机同型故障：2026-09-28 绍宋（447 章 EPUB）`[perf]` 日志 —— 8 帧全
      // `kind=estimate`、`restore.end converged=false sampled=false`、遮罩 1248ms。
      //
      // **新实现**（分页一次落位）：恢复 seed 落目标章占位块，prime 按 offsetFor
      // 精确算偏移单跳落位（首屏突发盖不住目标字符时挂估算落位，空闲帧补完后
      // 二次精确收敛）。本用例锁死「必须收敛且写盘」——
      // 这也正是修复前后的行为差异（旧断言是 `find.text('第六章') findsNothing` +
      // 零落盘，前提已被本次修复消除，故整条改写）。
      final List<int> counts = List<int>.generate(20, (int i) {
        if (i == 4) return 400; // 目标章上方唯一的真实长章：旧实现的估算落点被它拽偏
        if (i == 5 || i == 6) return 2; // 首帧批次里目标章与下一章极矮
        return 150;
      });
      final Set<int> hung = <int>{
        for (int i = 0; i < counts.length; i++)
          if (i < 4 || i > 6) i,
      };
      await tester.pumpWidget(
        buildApp(
          source: _FakeSource(paragraphCounts: counts, hangIndices: hung),
          store: counting,
        ),
      );
      await _settle(tester);

      // 非空验证：书确实开了（分页容器就位）且内容确实渲染（排除空壳假绿）。
      expect(find.byType(PagedScroller), findsOneWidget);
      expect(find.byType(RichText, skipOffstage: false), findsWidgets,
          reason: '应有内容渲染（占位章也算），排除空壳假绿');

      // 收敛断言：目标章标题与正文都进了树（旧实现两者皆无）。
      expect(find.text('第六章'), findsOneWidget,
          reason: '分页一次落位必须把目标章带进布局窗口并落定');
      // 注：正文段落由 `InlineParagraph` 渲染为 `Text.rich`（RichText），
      // `find.textContaining` 默认**不匹配富文本**，必须显式 `findRichText: true`。
      expect(find.textContaining('第6章正文', findRichText: true), findsWidgets,
          reason: '目标章正文应可见（收敛的直接证据）');

      // 收敛 → 语义坐标必须写回（与旧「零落盘」相反）。
      expect(counting.saveCount, greaterThanOrEqualTo(2),
          reason: '恢复收敛后必须写回（播种 1 + 本次 ≥1）');
      final ReadingProgress? saved =
          await tester.runAsync<ReadingProgress?>(() => counting.load('testbook01'));
      expect(saved, isNotNull);
      expect(saved!.chapterIndex, 5);
      expect(saved.chapterPos, inInclusiveRange(0.4, 0.6),
          reason: '落点语义坐标必须回到播种目标 0.5 附近');

      // 关书（位置已收敛，dispose 保存照常过闸门）。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      // 排空假区保存（AtomicFile._tails 跨区死锁防线，同回归①注释）。
      await _settle(tester, rounds: 20);
    });

    testWidgets('回归②b：恢复校正未落定即关书 → 一次都不写盘（RC1 闸门）',
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
      PerfLog.records.clear(); // 只认本次会话的 paged 打点

      // 目标章（下标 5）超长 → 首屏突发（kFirstPaintBudget=16ms）盖不住 0.5
      // 处字符，prime 走估算分支挂 `_pendingLand`（打点 `paged.estimate`），
      // `RC1` 闸门保持关闭；空闲帧还要排很久才可能精确落位——本用例看到
      // 估算打点后立即关书，抓的就是「未落定」这个窗口（旧实现同型手法是
      // 「遮罩在位」；分页一次落位无遮罩，改抓打点）。
      await tester.pumpWidget(
        buildApp(
          source: _FakeSource(
            paragraphCounts:
                List<int>.generate(20, (int i) => i == 5 ? 10000 : 20),
          ),
          store: counting,
        ),
      );

      // 轮询 PerfLog 到「估算落位挂起」= 恢复**未落定**进行中（抓到即证明
      // 尚未落定——这同时是非空验证，排除「什么都没发生」的假绿）。
      bool sawEstimate = false;
      for (int i = 0; i < 60 && !sawEstimate; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)));
        await tester.pump(const Duration(milliseconds: 8));
        for (final String line in PerfLog.records) {
          if (line.contains('paged.estimate')) {
            sawEstimate = true;
            break;
          }
        }
      }
      expect(sawEstimate, isTrue,
          reason: '须抓在恢复落位中途（否则本用例失去意义）');
      expect(find.byType(PagedScroller), findsOneWidget,
          reason: '分页容器应已就位（书确实开了，排除空壳假绿）');

      // 校正未落定即关书：dispose 的保存必须被闸门拦下（`_positionConverged`
      // 与 `_positionSampled` 都还没置位）。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await _settle(tester, rounds: 20);
      expect(counting.saveCount, 1, reason: '未落定的恢复位置不得写盘');

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
      final double viewportTop =
          tester.getTopLeft(find.byType(PagedScroller)).dy;
      expect(titleTop - viewportTop, lessThan(-300),
          reason: '应落在章中部而非章首（chapterPos≈0.5 已生效）');

      // 关书回读：语义坐标仍在 (1, 0.5±0.1)。
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      // 排空假区保存（AtomicFile._tails 跨区死锁防线，同回归①注释）；
      // 不排空则 tearDown deleteSync 会撞上未关闭的写句柄（PathAccessException）。
      await _settle(tester, rounds: 20);
      final ReadingProgress? saved =
          await tester.runAsync<ReadingProgress?>(() => progressStore.load('testbook01'));
      expect(saved, isNotNull);
      expect(saved!.chapterIndex, 1);
      expect(saved.chapterPos, inInclusiveRange(0.4, 0.6));
    });

    testWidgets('方案B（分页改写）：恢复一次落位——全程无遮罩、无跳变，直接落目标章（backlog①）',
        (WidgetTester tester) async {
      // 播种进度指向第 3 章（恢复目标非书首）。
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h3',
            chapterIndex: 2,
            chapterPos: 0.0,
            updatedAt: 1,
          ),
        ),
      );

      await tester.pumpWidget(buildApp());
      // 逐帧轮询中间态。旧 ListView 实现契约 = 校正期间**有**遮罩（盖住跳动）；
      // 分页实现契约相反 = **一次落位**——seed 已把首帧放在目标章占位块上，
      // 恢复全程不得出现遮罩，也不得闪现书首内容（「前几页 → 当前页」跳变）。
      final Finder mask = find.byKey(const Key('reader-restore-mask'));
      bool sawMask = false;
      bool sawWrongChapter = false;
      for (int i = 0; i < 90; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)));
        await tester.pump(const Duration(milliseconds: 8));
        if (mask.evaluate().isNotEmpty) sawMask = true;
        // 窗口只含 [1,2]：出现「第一章」= 布局落到了书首，属错误跳变。
        if (find.text('第一章').evaluate().isNotEmpty) sawWrongChapter = true;
      }
      expect(sawMask, isFalse,
          reason: '分页一次落位：恢复期间不得出现遮罩（旧方案B 遮罩契约已反转）');
      expect(sawWrongChapter, isFalse,
          reason: '恢复期间不得闪现书首内容（「前几页 → 当前页」跳变）');

      await _settle(tester);
      // 非空验证：恢复确实落到了目标章（排除「什么都没发生」的假绿）。
      expect(find.text('第三章'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);
    });

    testWidgets('回归④：占位→真实合入不得挪动视口（上方章高度回填后语义重锚）',
        (WidgetTester tester) async {
      // 5 章：第 2 章极矮（2 段），其余 20 段；**第 1 章挂闸门**——首帧预取
      // 与后台补齐都卡在闸门处，上方高度停留在估算占位值直到测试放行。
      final Completer<void> gate0 = Completer<void>();
      final _FakeSource source = _FakeSource(
        paragraphCounts: const <int>[2, 20, 20, 20, 20],
        gates: <int, Completer<void>>{0: gate0},
      );
      // 播种：恢复到第 2 章（下标 1）章首——上方第 1 章（下标 0）恰为占位高。
      await tester.runAsync(
        () => progressStore.save(
          ReadingProgress(
            bookId: 'testbook01',
            chapterHref: 'h2',
            chapterIndex: 1,
            chapterPos: 0.0,
            updatedAt: 1,
          ),
        ),
      );

      await tester.pumpWidget(buildApp(source: source));
      await _settle(tester);

      // 落定：记「第 2 章标题顶 − 视口顶」间距 d1（第 1 章仍是估算占位高）。
      final Finder title = find.text('第二章');
      final Finder viewport = find.byType(PagedScroller);
      expect(title, findsOneWidget, reason: '恢复应落到第 2 章');
      final double d1 =
          tester.getTopLeft(title).dy - tester.getTopLeft(viewport).dy;

      // 放行第 1 章：真实高度（2 段，很矮）合入 → 上方瞬间缩短数百像素。
      // 旧实现在合入后不重锚：像素偏移不动、同一 offset 指向别处 → 视口
      // 内容整体后移，用户看到「当前章跳走」（实机「进书从 40 多章跳到
      // 300 多章」即此漂移在长书上的放大形态）。
      gate0.complete();
      await _settle(tester);

      final double d2 =
          tester.getTopLeft(title).dy - tester.getTopLeft(viewport).dy;
      // 断言主句放最前：修前红时直接报出 d1/d2 实测漂移量。
      expect((d2 - d1).abs(), lessThanOrEqualTo(2),
          reason: '占位→真实合入改变上方高度后必须语义重锚；'
              'd1=$d1 d2=$d2（旧实现在此漂移数百像素）');
      // 非空验证：第 1 章真的补齐了（真实标题 + 正文渲染；占位块只显示
      // 「第 1 章 · 载入中…」且无正文段落，均不匹配下列文本）。
      expect(find.text('第一章', skipOffstage: false), findsOneWidget,
          reason: '闸门放行后第 1 章应以真实内容落库渲染');
      expect(
        find.textContaining('第1章正文1', findRichText: true,
            skipOffstage: false),
        findsWidgets,
        reason: '第 1 章正文应已渲染（排除 d1==d2 的「什么都没发生」假绿）',
      );
    });
  });
}
