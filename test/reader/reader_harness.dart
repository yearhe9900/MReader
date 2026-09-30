// `test/reader/` 共享测试装具（复制自 `reader_page_test.dart` 的私有实现，
// 供本目录多个测试文件复用；非 `*_test.dart`，不会被 `flutter test` 当用例执行）。
//
// ⚠️ 测试体里的**真异步 IO** 必须包在 `tester.runAsync` 里；而 widget 内部
// （`initState` / 回调）发起的真异步 IO 在 `testWidgets` 的 FakeAsync 区**不会自行推进**，
// 且载入期 `CircularProgressIndicator` 是无限动画 → `pumpAndSettle` 会**超时挂死**。
// 故统一用 [settle]（`runAsync` 让出真实事件循环 + 多轮 `pump` 交替推进），
// **不用** `pumpAndSettle` 收尾（弹层开关等无无限动画处可用 `pumpAndSettle`）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/platform/app_paths.dart';

/// 临时目录实现 [AppPaths]，仅用于测试。
class TestAppPaths implements AppPaths {
  TestAppPaths(this._root);
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

/// 可控的假内容源（`BookSource` 假实现）：章数 / 每章段落数可注入
/// （默认 3 章 × 20 段，标题 第一/二/三章，href 恒为 `h{序号}`）。
///
/// 每章默认给足 20 段，使整本内容**明显高于视口**——跳章必须真的滚动，
// 「第 N 章不可见」类断言才有意义。
class FakeBookSource implements BookSource {
  FakeBookSource({
    List<int>? paragraphCounts,
    Set<int>? hangIndices,
    Map<int, Completer<void>>? gates,
  })  : paragraphCounts = paragraphCounts ?? const <int>[20, 20, 20],
        hangIndices = hangIndices ?? const <int>{},
        gates = gates ?? const <int, Completer<void>>{};

  /// 每章段落数（下标 = 章下标；长度 = 章数）。
  final List<int> paragraphCounts;

  /// 永不返回内容的章下标（`content` 挂起）。
  final Set<int> hangIndices;

  /// 可释放的加载闸门：`content(i)` 先 `await gates[i].future` 再返回。
  final Map<int, Completer<void>> gates;

  bool disposed = false;

  /// 中文数字标题（1~29；测试用书最多 20 章）。
  static String titleAt(int index) {
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
  Future<List<Chapter>> chapters() async {
    if (disposed) return const <Chapter>[];
    return <Chapter>[
      for (int i = 0; i < paragraphCounts.length; i++)
        Chapter(href: 'h${i + 1}', title: titleAt(i), level: 0, locate: ''),
    ];
  }

  @override
  Future<ChapterContent> content(int chapterIndex) async {
    if (disposed) return ChapterContent.paragraphs(const <String>[]);
    if (hangIndices.contains(chapterIndex)) {
      // 永不完成：该章正文永远取不到。
      return Completer<ChapterContent>().future;
    }
    final Completer<void>? gate = gates[chapterIndex];
    if (gate != null) {
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
Future<void> settle(WidgetTester tester, {int rounds = 60}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump(const Duration(milliseconds: 8));
  }
}

/// 测试用书的库记录（3 章假书固定搭配）。
BookRecord fakeRecord() => const BookRecord(
      bookId: 'testbook01',
      fileName: '测试.txt',
      filePath: 'testbook01.txt',
      title: '书架书名',
      author: '书架作者',
      format: 'txt',
      cover: NoCover(),
      importedAt: 1,
    );

/// 构造书库仓库（进度回写 `markRead` 需要）。
LibraryRepository fakeRepository(AppPaths paths) =>
    LibraryRepository(paths: paths, coverStore: FileCoverStore(paths));

/// 关书（换异类 widget 把树拆掉）并排空 dispose 发起的假区保存。
///
/// ⚠️ `pumpWidget` 对**同类型无 key** 的 widget 走 `Widget.canUpdate` →
/// Element/State **复用**（`initState`/`dispose` 都不跑）——「关书」必须先换
/// 异类 widget（同 `reader_page_test.dart` 回归①注释）；随后排空假区保存：
/// `AtomicFile._tails` 按路径串行，活区同路径 IO 必须等它排空，否则跨区死锁。
Future<void> closeBook(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)));
  await settle(tester, rounds: 20);
}
