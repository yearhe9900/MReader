// `ShelfLayoutStore` 纯逻辑测试（L3：手动顺序 + 文件夹）。
//
// 全部是 `test()`，无 `testWidgets`——不涉及 FakeAsync 铁律，可照常 await 真 IO。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/shelf_layout_store.dart';

void main() {
  late Directory tempDir;
  late ShelfLayoutStore store;
  late File layoutFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mreader_layout_');
    store = ShelfLayoutStore(tempDir);
    layoutFile = File(
      '${tempDir.path}${Platform.pathSeparator}shelf_layout.json',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ShelfLayout', () {
    test('默认空布局；fromJson 对非 Map 输入回退空', () {
      expect(const ShelfLayout().isEmpty, isTrue);
      expect(ShelfLayout.fromJson(null).isEmpty, isTrue);
      expect(ShelfLayout.fromJson('nope').isEmpty, isTrue);
      expect(ShelfLayout.fromJson(<Object?>[]).isEmpty, isTrue);
    });

    test('fromJson 丢弃坏条目：无 id 的文件夹、非字符串的 bookId', () {
      final ShelfLayout layout = ShelfLayout.fromJson(<String, Object?>{
        'order': <Object?>['a', 42, '', 'b'],
        'folders': <Object?>[
          <String, Object?>{'name': '没有 id'},
          <String, Object?>{
            'id': 'f1',
            'name': '有效',
            'bookIds': <Object?>['x', 7, 'y'],
          },
        ],
      });
      expect(layout.order, <String>['a', 'b']);
      expect(layout.folders, hasLength(1));
      expect(layout.folders.single.bookIds, <String>['x', 'y']);
    });

    test('folderOf / folderedBookIds', () {
      const ShelfLayout layout = ShelfLayout(
        folders: <BookFolder>[
          BookFolder(id: 'f1', name: '甲', bookIds: <String>['a', 'b']),
          BookFolder(id: 'f2', name: '乙', bookIds: <String>['c']),
        ],
      );
      expect(layout.folderOf('b')?.id, 'f1');
      expect(layout.folderOf('c')?.id, 'f2');
      expect(layout.folderOf('z'), isNull);
      expect(layout.folderedBookIds, <String>{'a', 'b', 'c'});
    });

    test('toJson / fromJson 往返一致', () {
      const ShelfLayout layout = ShelfLayout(
        order: <String>['a', 'b'],
        folders: <BookFolder>[
          BookFolder(id: 'f1', name: '甲', bookIds: <String>['c']),
        ],
      );
      final ShelfLayout round = ShelfLayout.fromJson(layout.toJson());
      expect(round.order, layout.order);
      expect(round.folders.single.id, 'f1');
      expect(round.folders.single.name, '甲');
      expect(round.folders.single.bookIds, <String>['c']);
    });
  });

  group('ShelfLayoutStore', () {
    test('初始为空；load 前 layout 即空布局（不是 null）', () {
      expect(store.layout.isEmpty, isTrue);
      expect(store.isLoaded, isFalse);
    });

    test('setOrder 落盘，重新 load 可还原', () async {
      await store.setOrder(<String>['c', 'a', 'b']);
      expect(store.layout.order, <String>['c', 'a', 'b']);

      final ShelfLayoutStore reopened = ShelfLayoutStore(tempDir);
      await reopened.load();
      expect(reopened.layout.order, <String>['c', 'a', 'b']);
      expect(reopened.isLoaded, isTrue);
    });

    test('createFolder 返回 id 且成员按传入顺序排列', () async {
      final String id = await store.createFolder(
        name: '科幻',
        bookIds: <String>['a', 'b'],
      );
      expect(id, isNotEmpty);
      expect(store.layout.folders, hasLength(1));
      expect(store.layout.folders.single.id, id);
      expect(store.layout.folders.single.name, '科幻');
      expect(store.layout.folders.single.bookIds, <String>['a', 'b']);
    });

    test('两个文件夹 id 不重复', () async {
      final String first =
          await store.createFolder(name: '甲', bookIds: <String>['a']);
      final String second =
          await store.createFolder(name: '乙', bookIds: <String>['b']);
      expect(first, isNot(second));
    });

    test('addToFolder 保证归属唯一：从原文件夹摘出', () async {
      final String f1 =
          await store.createFolder(name: '甲', bookIds: <String>['a', 'b']);
      final String f2 =
          await store.createFolder(name: '乙', bookIds: <String>['c']);

      await store.addToFolder(f2, <String>['b']);

      final BookFolder first = store.layout.folders
          .firstWhere((BookFolder f) => f.id == f1);
      final BookFolder second = store.layout.folders
          .firstWhere((BookFolder f) => f.id == f2);
      expect(first.bookIds, <String>['a']);
      expect(second.bookIds, <String>['c', 'b']);
      // 一本书只属于一个文件夹。
      expect(store.layout.folderOf('b')?.id, f2);
    });

    test('addToFolder 对已在目标文件夹里的书不产生重复项', () async {
      final String f1 =
          await store.createFolder(name: '甲', bookIds: <String>['a']);
      await store.addToFolder(f1, <String>['a']);
      expect(store.layout.folders.single.bookIds, <String>['a']);
    });

    test('addToFolder 目标不存在时空操作', () async {
      await store.addToFolder('不存在', <String>['a']);
      expect(store.layout.isEmpty, isTrue);
    });

    test('removeFromFolder 把书退回散书区', () async {
      final String id =
          await store.createFolder(name: '甲', bookIds: <String>['a', 'b']);
      await store.removeFromFolder(id, <String>['a']);
      expect(store.layout.folders.single.bookIds, <String>['b']);
      expect(store.layout.folderOf('a'), isNull);
    });

    test('renameFolder 生效；空白名被拒绝（保持原名）', () async {
      final String id =
          await store.createFolder(name: '旧名', bookIds: <String>['a']);

      await store.renameFolder(id, '新名');
      expect(store.layout.folders.single.name, '新名');

      await store.renameFolder(id, '   ');
      expect(store.layout.folders.single.name, '新名');
    });

    test('setFolderOrder 改写文件夹内顺序', () async {
      final String id = await store.createFolder(
        name: '甲',
        bookIds: <String>['a', 'b', 'c'],
      );
      await store.setFolderOrder(id, <String>['c', 'a', 'b']);
      expect(store.layout.folders.single.bookIds, <String>['c', 'a', 'b']);
    });

    test('setFolderOrder 过滤非成员 id（防误插）', () async {
      final String id =
          await store.createFolder(name: '甲', bookIds: <String>['a', 'b']);
      await store.setFolderOrder(id, <String>['b', '外人', 'a']);
      expect(store.layout.folders.single.bookIds, <String>['b', 'a']);
    });

    test('dissolveFolder 移除文件夹（书回到散书区）', () async {
      final String id =
          await store.createFolder(name: '甲', bookIds: <String>['a']);
      await store.dissolveFolder(id);
      expect(store.layout.folders, isEmpty);
      expect(store.layout.folderOf('a'), isNull);
    });

    test('prune 清掉孤儿 bookId 与随之变空的文件夹', () async {
      final String keep =
          await store.createFolder(name: '保留', bookIds: <String>['a', 'b']);
      await store.createFolder(name: '全删', bookIds: <String>['x', 'y']);
      await store.setOrder(<String>['a', 'x', 'b']);

      await store.prune(<String>{'a', 'b'});

      expect(store.layout.order, <String>['a', 'b']);
      expect(store.layout.folders, hasLength(1));
      expect(store.layout.folders.single.id, keep);
      expect(store.layout.folders.single.bookIds, <String>['a', 'b']);
    });

    test('prune 无实际变化时不写盘（文件内容逐字不变）', () async {
      await store.setOrder(<String>['a']);
      final String before = await layoutFile.readAsString();

      await store.prune(<String>{'a', 'b'});

      expect(await layoutFile.readAsString(), before);
    });

    test('监听：变更时通知，退订后不再通知', () async {
      int hits = 0;
      void listener() => hits++;

      store.addListener(listener);
      await store.setOrder(<String>['a']);
      expect(hits, 1);

      store.removeListener(listener);
      await store.setOrder(<String>['b']);
      expect(hits, 1);
    });

    test('load 时通知一次（页面 initState 订阅后能拿到首帧状态）', () async {
      int hits = 0;
      store.addListener(() => hits++);
      await store.load();
      expect(hits, 1);
    });

    test('文件损坏时回退空布局且不抛', () async {
      await layoutFile.writeAsString('{ 不是合法 JSON');
      await store.load();
      expect(store.layout.isEmpty, isTrue);
    });
  });
}
