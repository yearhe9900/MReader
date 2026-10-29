// `lib/meta/cover_store.dart` 单测：物化幂等 / 换封面删旧 / 孤儿 GC（含 .bak 兄弟）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/meta/cover_store.dart';
import 'package:mreader/model/book_meta.dart';
import 'package:mreader/platform/app_paths.dart';

import 'meta_fixtures.dart';

/// 只把数据目录指向一个临时目录的 [AppPaths] 假体（不依赖 path_provider）。
class _TempPaths implements AppPaths {
  _TempPaths(this.root);

  final Directory root;

  @override
  Future<Directory> dataDir() async => root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir =
        Directory('${root.path}${Platform.pathSeparator}$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

String _join(Directory dir, String name) =>
    '${dir.path}${Platform.pathSeparator}$name';

Future<List<String>> _names(Directory dir) async {
  final List<String> out = <String>[];
  await for (final FileSystemEntity e in dir.list(followLinks: false)) {
    if (e is File) out.add(e.path.split(Platform.pathSeparator).last);
  }
  out.sort();
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _TempPaths paths;
  late FileCoverStore store;
  late Directory covers;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mreader_covers_');
    paths = _TempPaths(root);
    store = FileCoverStore(paths);
    covers = await paths.subDir(FileCoverStore.coverDirName);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('materialize：保留真实格式 + 生成缩略图；幂等不产生孤儿', () async {
    final StoredCover stored = await store.materialize(
      bookId: 'bk1',
      pending: PendingCover(kTinyPng, CoverFormat.png),
    );
    expect(stored.fileName, 'bk1.cover.png');
    expect(await _names(covers), <String>['bk1.cover.png', 'bk1.thumb.png']);

    // 幂等：同 bookId 再物化一次，仍是 2 个文件（不堆孤儿）。
    await store.materialize(
      bookId: 'bk1',
      pending: PendingCover(kTinyPng, CoverFormat.png),
    );
    expect(await _names(covers), <String>['bk1.cover.png', 'bk1.thumb.png']);

    expect(await store.readFull(stored), kTinyPng);
    expect(await store.readThumb(stored), isNotNull);
  });

  test('materialize：格式变化时清掉旧扩展名文件', () async {
    await store.materialize(
      bookId: 'bk2',
      pending: PendingCover(kTinyPng, CoverFormat.png),
    );
    final StoredCover jpeg = await store.materialize(
      bookId: 'bk2',
      pending: PendingCover(kTinyJpeg, CoverFormat.jpeg),
    );
    expect(jpeg.fileName, 'bk2.cover.jpg');
    expect(await _names(covers), <String>['bk2.cover.jpg']);
  });

  test('replaceWithUserPick：写入新图并删除旧文件', () async {
    final StoredCover old = await store.materialize(
      bookId: 'bk3',
      pending: PendingCover(kTinyPng, CoverFormat.png),
    );
    expect(await _names(covers), contains('bk3.cover.png'));

    final StoredCover now = await store.replaceWithUserPick(
      bookId: 'bk3',
      bytes: kTinyJpeg,
      previous: old,
    );
    expect(now.fileName, 'bk3.cover.jpg');
    expect(await _names(covers), <String>['bk3.cover.jpg'],
        reason: '旧 png 与旧缩略图应被清除');
  });

  test('delete：移除封面 + 缩略图 + 兄弟文件；NoCover/SyntheticCover 空操作', () async {
    final StoredCover stored = await store.materialize(
      bookId: 'bk4',
      pending: PendingCover(kTinyPng, CoverFormat.png),
    );
    // 造一个 .bak 兄弟，验证 delete 一并移除。
    await File(_join(covers, 'bk4.cover.png.bak')).writeAsBytes(<int>[1]);

    await store.delete(const NoCover());
    await store.delete(const SyntheticCover('sc'));
    expect(await _names(covers), contains('bk4.cover.png'), reason: '空操作不应删文件');

    await store.delete(stored);
    expect(await _names(covers), isEmpty);
  });

  test('purgeOrphans：只删孤儿，兄弟/缩略图随基封面处置，幂等', () async {
    for (final String name in <String>[
      'a.cover.png', // 被引用
      'a.cover.png.bak', // 兄弟 -> 随基保留
      'a.thumb.png', // 缩略图 -> 随基保留
      'b.cover.jpg', // 孤儿
      'b.cover.jpg.tmp', // 孤儿兄弟 -> 一起删
      'b.thumb.jpg', // 孤儿缩略图 -> 一起删
      'c.thumb.png', // 无对应基封面 -> 孤儿
    ]) {
      await File(_join(covers, name)).writeAsBytes(<int>[1, 2, 3]);
    }
    // covers/ 之外的文件：绝不能被触碰。
    final File outside = File(_join(root, 'outside.txt'));
    await outside.writeAsBytes(<int>[9]);

    final int removed =
        await store.purgeOrphans(referencedFileNames: <String>{'a.cover.png'});
    expect(removed, 4);
    expect(await _names(covers),
        <String>['a.cover.png', 'a.cover.png.bak', 'a.thumb.png']);
    expect(await outside.exists(), isTrue, reason: 'covers/ 之外永不触碰');

    expect(
      await store.purgeOrphans(referencedFileNames: <String>{'a.cover.png'}),
      0,
    );
  });

  test('readFull / readThumb：非 StoredCover 返回 null', () async {
    expect(await store.readFull(const NoCover()), isNull);
    expect(await store.readThumb(const NoCover()), isNull);
    expect(await store.readFull(const SyntheticCover('sc')), isNull);
    expect(await store.readFull(const StoredCover('missing.cover.png')), isNull);
  });

  test('extensionOf：真实格式 -> 扩展名（不看源扩展名）', () {
    expect(FileCoverStore.extensionOf(CoverFormat.jpeg), 'jpg');
    expect(FileCoverStore.extensionOf(CoverFormat.png), 'png');
    expect(FileCoverStore.extensionOf(CoverFormat.webp), 'webp');
    expect(FileCoverStore.extensionOf(CoverFormat.gif), 'gif');
    expect(FileCoverStore.extensionOf(CoverFormat.bmp), 'bmp');
    expect(FileCoverStore.extensionOf(CoverFormat.unknown), 'img');
  });
}
