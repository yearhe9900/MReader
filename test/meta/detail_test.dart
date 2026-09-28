// `META-08` / `META-09`：书籍详情页与元数据手动编辑测试（M2a-T03）。
//
// 覆盖：
// · META-08 ① 字段与解析结果一致（EPUB fixture + TXT 各一本进详情页）
// · META-08 ② 来源标记可见（TXT 书名/作者标「文件名推断」）
// · META-08 ③ 封面区与简介区不透明、无玻璃嵌套（UI-04 红线）
// · META-08 ④ 无简介显示占位「暂无简介」
// · META-09 ① 改书名/作者 → 重载 index 一致（重启保留）+ 书架与详情页同步
// · META-09 ② 换封面后旧封面文件被删（META-06 ①）
// · META-09 ③ 恢复自动值 → 值回自动结果、来源回原值
// · META-09 ④ 二次 importFile 同内容不覆写 user 值
//
// ⚠️ FakeAsync 铁律：仓储 IO 用纯 `test()` + 临时目录；`testWidgets` 体内
// **不 await 真异步 IO**——导入放 `tester.runAsync`，widget 内发起的 IO 用
// [_settle]（runAsync 与 pump 交替）排空（同 `test/ui/shelf_page_test.dart`）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mreader/format/book_registry.dart';
import 'package:mreader/format/book_source.dart';
import 'package:mreader/library/book_record.dart';
import 'package:mreader/library/library_repository.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/meta/meta_editor.dart';
import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/reader/progress_store.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';
import 'package:mreader/ui/book_card.dart';
import 'package:mreader/ui/book_detail_page.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/shelf_page.dart';

import '../test_config.dart';
import 'meta_fixtures.dart';

/// 临时目录实现 [AppPaths]（与 `test/ui/shelf_page_test.dart` 同形），仅用于测试。
class _TestAppPaths implements AppPaths {
  _TestAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir =
        Directory('${_root.path}${Platform.pathSeparator}$name');
    await dir.create(recursive: true);
    return dir;
  }
}

/// 合法 UTF-8 的 TXT 字节。
Uint8List _utf8TxtBytes(String content) =>
    Uint8List.fromList(utf8.encode(content));

/// 现解一次取 `BookMeta`（`META-08 ①` 的对照基准）；`load()` 后必 `dispose()`。
Future<BookMeta> _parse(Uint8List bytes, String fileName) async {
  final BookSource source = await openBook(fileName: fileName, bytes: bytes);
  try {
    return await source.load();
  } finally {
    await source.dispose();
  }
}

/// 让 widget 内发起的**真异步 IO** 完成，并推进若干帧（同 shelf_page_test）。
Future<void> _settle(WidgetTester tester, {int rounds = 40}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// 按书名找到书卡。
Finder _cardOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(BookCard));

/// 全树范围找详情页（覆盖栈里的路由也要揪出来）。
Finder _detailPages() => find.byType(BookDetailPage, skipOffstage: false);

/// 在详情页范围内找文本（书架同名文本在栈下，范围限定避免误配）。
Finder _inDetail(Finder matching) =>
    find.descendant(of: _detailPages(), matching: matching);

/// fixture EPUB 的绝对路径。
String _fixturePath(String name) =>
    'test${Platform.pathSeparator}fixtures${Platform.pathSeparator}$name';

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  // ==========================================================================
  // meta_editor 纯函数
  // ==========================================================================
  group('meta_editor 纯函数', () {
    test('originLabel：四值闭合文案，none 显「未知」', () {
      expect(originLabel(MetaOrigin.metadata), '元数据');
      expect(originLabel(MetaOrigin.filename), '文件名推断');
      expect(originLabel(MetaOrigin.user), '用户自定义');
      expect(originLabel(MetaOrigin.none), '未知');
    });

    test('validateEdits：空书名 / 空作者非法（META-01 不留空串）', () {
      expect(validateEdits(title: '三体', author: '刘慈欣'), isNull);
      expect(validateEdits(title: '   ', author: '刘慈欣'), isNotNull);
      expect(validateEdits(title: '三体', author: ''), isNotNull);
      expect(validateEdits(title: '三体', author: '  '), isNotNull);
    });

    test('applyEdits：仅值实际变化的字段置 user，未改字段来源不动', () {
      const BookRecord current = BookRecord(
        bookId: 'b1',
        fileName: '三体.txt',
        filePath: 'b1.txt',
        title: '三体',
        author: '刘慈欣',
        format: 'txt',
        cover: NoCover(),
        importedAt: 1,
        intro: '',
        titleOrigin: MetaOrigin.filename,
        authorOrigin: MetaOrigin.filename,
        introOrigin: MetaOrigin.none,
        coverOrigin: MetaOrigin.none,
      );

      // 只改书名 → 仅 titleOrigin 置 user，其余来源保持。
      final BookRecord onlyTitle = applyEdits(
        current,
        title: '三体（修订）',
        author: '刘慈欣',
        intro: '',
      );
      expect(onlyTitle.title, '三体（修订）');
      expect(onlyTitle.titleOrigin, MetaOrigin.user);
      expect(onlyTitle.authorOrigin, MetaOrigin.filename, reason: '未改字段来源不动');
      expect(onlyTitle.introOrigin, MetaOrigin.none);

      // 三字段全改 → 全置 user；输入 trim。
      final BookRecord all = applyEdits(
        current,
        title: '  新书名 ',
        author: ' 新作者',
        intro: '新简介',
      );
      expect(all.title, '新书名');
      expect(all.author, '新作者');
      expect(all.intro, '新简介');
      expect(all.titleOrigin, MetaOrigin.user);
      expect(all.authorOrigin, MetaOrigin.user);
      expect(all.introOrigin, MetaOrigin.user);
      expect(all.coverOrigin, MetaOrigin.none, reason: '封面不由文本编辑改动');

      // 无变化 → 同一实例（来源全部保持）。
      final BookRecord same = applyEdits(
        current,
        title: '三体',
        author: '刘慈欣',
        intro: '',
      );
      expect(identical(same, current), isTrue);
    });

    test('restoreFromMeta：值回 auto、四来源回解析值（META-09 ③）', () {
      const BookRecord userEdited = BookRecord(
        bookId: 'b1',
        fileName: '三体.txt',
        filePath: 'b1.txt',
        title: '我改的书名',
        author: '我改的作者',
        format: 'txt',
        cover: NoCover(),
        importedAt: 1,
        intro: '我改的简介',
        titleOrigin: MetaOrigin.user,
        authorOrigin: MetaOrigin.user,
        introOrigin: MetaOrigin.user,
        coverOrigin: MetaOrigin.user,
      );
      final BookMeta meta = BookMeta(
        title: '三体',
        titleOrigin: MetaOrigin.filename,
        author: '刘慈欣',
        authorOrigin: MetaOrigin.filename,
        intro: '',
        introOrigin: MetaOrigin.none,
        cover: const NoCover(),
        coverOrigin: MetaOrigin.none,
        language: '',
        auto: const BookMetaAuto(
          title: '三体',
          author: '刘慈欣',
          intro: '',
        ),
      );

      final BookRecord restored = restoreFromMeta(userEdited, meta);
      expect(restored.title, '三体');
      expect(restored.author, '刘慈欣');
      expect(restored.intro, '');
      expect(restored.titleOrigin, MetaOrigin.filename, reason: '回解析值而非 user');
      expect(restored.authorOrigin, MetaOrigin.filename);
      expect(restored.introOrigin, MetaOrigin.none);
      expect(restored.coverOrigin, MetaOrigin.none);
    });

    test('needsOriginBackfill：仅四来源全 none 的旧条目触发', () {
      // 旧索引条目：四个来源键整体缺失 → 读成 none → 需回填。
      final BookRecord legacy = BookRecord.fromJson(<String, Object?>{
        'bookId': 'b1',
        'fileName': 'a.txt',
        'filePath': 'b1.txt',
        'title': 'A',
        'author': 'B',
        'format': 'txt',
        'cover': <String, Object?>{'kind': 'none'},
        'importedAt': 1,
      });
      expect(legacy.titleOrigin, MetaOrigin.none);
      expect(legacy.intro, '');
      expect(needsOriginBackfill(legacy), isTrue);

      // 新导入 TXT：书名来源已是 filename（其余 none）→ 不触发（有界 IO）。
      const BookRecord fresh = BookRecord(
        bookId: 'b2',
        fileName: 'a.txt',
        filePath: 'b2.txt',
        title: 'A',
        author: '未知作者',
        format: 'txt',
        cover: NoCover(),
        importedAt: 1,
        titleOrigin: MetaOrigin.filename,
      );
      expect(needsOriginBackfill(fresh), isFalse);
    });
  });

  // ==========================================================================
  // 仓储集成（纯 test + 临时目录）
  // ==========================================================================
  group('META-08/09 仓储集成', () {
    late Directory tempDir;
    late _TestAppPaths paths;
    late FileCoverStore coverStore;
    late LibraryRepository repo;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_detail_');
      paths = _TestAppPaths(tempDir);
      coverStore = FileCoverStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: coverStore);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('META-08① EPUB 导入：记录字段与四来源与解析结果一致', () async {
      final Uint8List bytes =
          await File(_fixturePath('fx06_linear_no.epub')).readAsBytes();
      final BookMeta meta = await _parse(bytes, 'fx06_linear_no.epub');
      final ImportResult res = await repo.importFile(
        bytes: bytes,
        fileName: 'fx06_linear_no.epub',
      );
      expect(res.isNew, isTrue);

      final BookRecord r = res.record;
      expect(r.title, meta.title);
      expect(r.author, meta.author);
      expect(r.intro, meta.intro);
      expect(r.titleOrigin, meta.titleOrigin);
      expect(r.authorOrigin, meta.authorOrigin);
      expect(r.introOrigin, meta.introOrigin);
      expect(r.coverOrigin, meta.coverOrigin);
      expect(r.format, 'epub');
    });

    test('META-08② TXT 导入：书名/作者来源标 filename（文件名推断）', () async {
      final ImportResult res = await repo.importFile(
        bytes: _utf8TxtBytes('三体正文。'),
        fileName: '三体 作者：刘慈欣.txt',
      );
      final BookRecord r = res.record;
      expect(r.title, '三体');
      expect(r.author, '刘慈欣');
      expect(r.titleOrigin, MetaOrigin.filename);
      expect(r.authorOrigin, MetaOrigin.filename);
      expect(originLabel(r.authorOrigin), '文件名推断');
      expect(r.intro, '');
      expect(r.introOrigin, MetaOrigin.none);
      expect(r.coverOrigin, MetaOrigin.none);
      expect(needsOriginBackfill(r), isFalse, reason: '新导入不触发回填');
    });

    test('META-09① 保存后重载 index 一致（重启保留）', () async {
      final ImportResult res = await repo.importFile(
        bytes: _utf8TxtBytes('三体正文。'),
        fileName: '三体 作者：刘慈欣.txt',
      );
      final BookRecord edited = applyEdits(
        res.record,
        title: '三体（修订版）',
        author: '刘慈欣',
        intro: '地球往事三部曲之一。',
      );
      expect(edited.titleOrigin, MetaOrigin.user);
      expect(edited.authorOrigin, MetaOrigin.filename, reason: '作者未变，来源不动');
      expect(edited.introOrigin, MetaOrigin.user);
      await repo.updateRecord(edited);

      // 新实例重载 = 重启后读盘。
      final LibraryRepository repo2 =
          LibraryRepository(paths: paths, coverStore: coverStore);
      final List<BookRecord> books = await repo2.loadBooks();
      expect(books, hasLength(1));
      expect(books.single.title, '三体（修订版）');
      expect(books.single.author, '刘慈欣');
      expect(books.single.intro, '地球往事三部曲之一。');
      expect(books.single.titleOrigin, MetaOrigin.user);
      expect(books.single.introOrigin, MetaOrigin.user);
      expect(books.single.authorOrigin, MetaOrigin.filename);
    });

    test('META-09④ 二次 importFile 同内容不覆写 user 值', () async {
      final Uint8List bytes = _utf8TxtBytes('三体正文。');
      final ImportResult first =
          await repo.importFile(bytes: bytes, fileName: '三体 作者：刘慈欣.txt');
      await repo.updateRecord(
        applyEdits(first.record, title: '我的三体', author: '我', intro: ''),
      );

      // 同内容再次导入：判重命中，返回既有记录、不覆写。
      final ImportResult second =
          await repo.importFile(bytes: bytes, fileName: '三体 作者：刘慈欣.txt');
      expect(second.isNew, isFalse);
      expect(second.record.title, '我的三体');
      expect(second.record.titleOrigin, MetaOrigin.user);
      expect(second.record.author, '我');
      expect(second.record.authorOrigin, MetaOrigin.user);

      final List<BookRecord> books = await repo.loadBooks();
      expect(books.single.title, '我的三体', reason: '索引未被重导入覆写');
    });

    test('META-09③ 恢复自动值：值回自动结果、来源回原值', () async {
      final Uint8List bytes = _utf8TxtBytes('三体正文。');
      final ImportResult res =
          await repo.importFile(bytes: bytes, fileName: '三体 作者：刘慈欣.txt');
      await repo.updateRecord(
        applyEdits(
          res.record,
          title: '乱改的书名',
          author: '某人',
          intro: '乱改的简介',
        ),
      );

      // 详情页「恢复自动值」路径：重新解析 → restoreFromMeta → updateRecord。
      final BookMeta meta = await _parse(bytes, '三体 作者：刘慈欣.txt');
      final List<BookRecord> before = await repo.loadBooks();
      final BookRecord restored =
          restoreFromMeta(before.single, meta).copyWith(cover: before.single.cover);
      await repo.updateRecord(restored);

      final List<BookRecord> books = await repo.loadBooks();
      expect(books.single.title, '三体');
      expect(books.single.author, '刘慈欣');
      expect(books.single.intro, '');
      expect(books.single.titleOrigin, MetaOrigin.filename, reason: '来源回原值而非 user');
      expect(books.single.authorOrigin, MetaOrigin.filename);
      expect(books.single.introOrigin, MetaOrigin.none);
      expect(books.single.coverOrigin, MetaOrigin.none);
    });

    test('META-09② 换封面：旧封面文件被删、来源置 user（META-06 ①）', () async {
      final ImportResult res = await repo.importFile(
        bytes: _utf8TxtBytes('三体正文。'),
        fileName: '三体.txt',
      );
      // 手动造一个已落盘封面（不依赖 fixture 是否带图）。
      final StoredCover oldCover = await coverStore.materialize(
        bookId: res.record.bookId,
        pending: PendingCover(kTinyPng, CoverFormat.png),
      );
      final BookRecord withCover =
          res.record.copyWith(cover: oldCover, coverOrigin: MetaOrigin.metadata);
      await repo.updateRecord(withCover);

      final String oldPath =
          '${tempDir.path}${Platform.pathSeparator}covers'
          '${Platform.pathSeparator}${oldCover.fileName}';
      expect(await File(oldPath).exists(), isTrue, reason: '前置：旧封面已落盘');

      // 详情页换封面路径：replaceWithUserPick → copyWith → updateRecord。
      final StoredCover picked = await coverStore.replaceWithUserPick(
        bookId: res.record.bookId,
        bytes: kTinyJpeg,
        previous: oldCover,
      );
      await repo.updateRecord(
        withCover.copyWith(cover: picked, coverOrigin: MetaOrigin.user),
      );

      expect(await File(oldPath).exists(), isFalse,
          reason: 'META-06①：被替换的旧封面文件必须删除');
      final String newPath =
          '${tempDir.path}${Platform.pathSeparator}covers'
          '${Platform.pathSeparator}${picked.fileName}';
      expect(await File(newPath).exists(), isTrue, reason: '新封面已落盘');

      final List<BookRecord> books = await repo.loadBooks();
      expect(books.single.coverOrigin, MetaOrigin.user);
      expect((books.single.cover as StoredCover).fileName, picked.fileName);
    });
  });

  // ==========================================================================
  // 详情页 widget（META-08 ①②③④ + META-09① 编辑链路）
  // ==========================================================================
  group('BookDetailPage', () {
    late Directory tempDir;
    late LibraryRepository repo;
    late FileCoverStore coverStore;
    late ProgressStore progressStore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mreader_detail_ui_');
      final AppPaths paths = _TestAppPaths(tempDir);
      coverStore = FileCoverStore(paths);
      repo = LibraryRepository(paths: paths, coverStore: coverStore);
      progressStore = ProgressStore(paths);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Widget buildApp() => MaterialApp(
          home: ShelfPage(
            repository: repo,
            coverStore: coverStore,
            progressStore: progressStore,
            shelfPrefs: ShelfPrefsStore(tempDir),
          ),
        );

    testWidgets('META-08 ①②④ TXT：字段齐全、来源标「文件名推断」、无简介占位',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(
          bytes: _utf8TxtBytes('三体正文。'),
          fileName: '三体 作者：刘慈欣.txt',
        ),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(_cardOf('三体'));
      await _settle(tester);

      // ① 入口：一次点击恰好一个详情页。
      expect(_detailPages(), findsOneWidget);

      // ① 字段齐全：书名 / 作者 / 格式 / 大小 / 进度 / 分组 / 统计入口。
      expect(_inDetail(find.text('三体')), findsOneWidget);
      expect(_inDetail(find.text('刘慈欣')), findsOneWidget);
      expect(_inDetail(find.text('TXT')), findsOneWidget);
      expect(_inDetail(find.text('文件大小')), findsOneWidget);
      expect(_inDetail(find.text('未开始')), findsOneWidget);
      expect(_inDetail(find.text('分组')), findsOneWidget);
      expect(_inDetail(find.text('未分组')), findsOneWidget);
      expect(_inDetail(find.text('单书统计')), findsOneWidget);

      // ② 来源标记可见：书名与作者都标「文件名推断」。
      expect(_inDetail(find.text('文件名推断')), findsNWidgets(2));

      // ④ 无简介显示占位而非空白。
      expect(_inDetail(find.text('暂无简介')), findsOneWidget);

      // ③ 玻璃红线：顶栏玻璃属导航层；内容整体不透明、树上无内容层玻璃。
      // 范围限定到详情页——书架玻璃化（M2a-T04）后全树有 2 个 GlassTopBar /
      // OpaqueContentSurface（书架在栈下 offstage 也会被 skipOffstage:false 数到）。
      expect(_inDetail(find.byType(GlassTopBar, skipOffstage: false)),
          findsOneWidget);
      expect(_inDetail(find.byType(OpaqueContentSurface)), findsOneWidget);
      expect(find.byType(GlassCard, skipOffstage: false), findsNothing);
      expect(find.byType(GlassContainer, skipOffstage: false), findsNothing);
      expect(find.byType(GlassListTile, skipOffstage: false), findsNothing);
      expect(find.byType(GlassGroupedSection, skipOffstage: false), findsNothing);
    });

    testWidgets('META-08① EPUB：详情页字段与解析结果一致',
        (WidgetTester tester) async {
      final Uint8List bytes = (await tester.runAsync(
        () => File(_fixturePath('fx06_linear_no.epub')).readAsBytes(),
      ))!;
      final BookMeta meta = (await tester.runAsync(
        () => _parse(bytes, 'fx06_linear_no.epub'),
      ))!;
      await tester.runAsync(
        () => repo.importFile(bytes: bytes, fileName: 'fx06_linear_no.epub'),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      await tester.tap(find.byType(BookCard));
      await _settle(tester);
      expect(_detailPages(), findsOneWidget);

      expect(_inDetail(find.text(meta.title)), findsOneWidget);
      expect(_inDetail(find.text(meta.author)), findsOneWidget);
      expect(_inDetail(find.text('EPUB')), findsOneWidget);
      // 来源标记与解析结果同文案。
      expect(_inDetail(find.text(originLabel(meta.titleOrigin))), findsWidgets);
      expect(_inDetail(find.text(originLabel(meta.authorOrigin))), findsWidgets);
    });

    testWidgets('META-09① 编辑链路：详情页保存 → 显示 user 标记 → 书架同步',
        (WidgetTester tester) async {
      await tester.runAsync(
        () => repo.importFile(
          bytes: _utf8TxtBytes('三体正文。'),
          fileName: '三体 作者：刘慈欣.txt',
        ),
      );
      await tester.pumpWidget(buildApp());
      await _settle(tester);

      // 进详情页 → 进编辑态。
      await tester.tap(_cardOf('三体'));
      await _settle(tester);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await _settle(tester);
      // 简介输入框在 ListView 折叠区下方，首屏只见书名 / 作者两个。
      expect(find.byType(TextField), findsNWidgets(2));

      // 改书名（作者不改 → 其来源不动）。
      await tester.enterText(find.byType(TextField).at(0), '三体（修订版）');
      await tester.pump();

      // 滚到底部：简介多行输入框存在（四个可编辑字段之一）。
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      expect(find.byType(TextField), findsNWidgets(3));

      // 保存（按钮在 ListView 外的底部操作区，恒可见）。
      await tester.tap(find.text('保存'));
      await _settle(tester);

      // 详情页立即同步：新书名 + 「用户自定义」标记；作者仍标「文件名推断」。
      expect(_inDetail(find.text('三体（修订版）')), findsOneWidget);
      expect(_inDetail(find.text('用户自定义')), findsWidgets);
      expect(_inDetail(find.text('文件名推断')), findsWidgets);

      // 返回书架：卡片同步显示新书名（pop 后刷新）。
      // 顶栏返回键的可点性在 glass 接入层（M2a-T04）另测，此处直 pop 验证同步链路。
      final NavigatorState nav = Navigator.of(tester.element(_detailPages()));
      nav.pop();
      // 退场动画：只推假帧（_settle 的 runAsync 交替不驱动 transition）。
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // 书架 pop 后刷新是真 IO：_settle 让出真实事件循环排空。
      await _settle(tester);
      expect(_detailPages(), findsNothing);
      expect(_cardOf('三体（修订版）'), findsOneWidget);
      expect(find.byType(BookCard), findsOneWidget);
    });
  });
}
