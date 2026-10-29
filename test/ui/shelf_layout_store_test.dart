// `ShelfLayoutStore` 纯逻辑测试（手动顺序 + **分组归属**，`P2-02`）。
//
// 全部是 `test()`，无 `testWidgets`——不涉及 FakeAsync 铁律，可照常 await 真 IO。
//
// 「分组取代文件夹」后：类名 / 方法名 / 落盘键名全部是分组语义，
// 另有「旧 `folders` 键兼容」与「按名归组」两组用例。
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

    test('fromJson 丢弃坏条目：无 id 的分组、非字符串的 bookId', () {
      final ShelfLayout layout = ShelfLayout.fromJson(<String, Object?>{
        'order': <Object?>['a', 42, '', 'b'],
        'groups': <Object?>[
          <String, Object?>{'name': '没有 id'},
          <String, Object?>{
            'id': 'g1',
            'name': '有效',
            'bookIds': <Object?>['x', 7, 'y'],
          },
        ],
      });
      expect(layout.order, <String>['a', 'b']);
      expect(layout.groups, hasLength(1));
      expect(layout.groups.single.bookIds, <String>['x', 'y']);
    });

    test('fromJson 兼容旧 `folders` 键（2026-09-29 前的落盘格式）', () {
      final ShelfLayout layout = ShelfLayout.fromJson(<String, Object?>{
        'order': <Object?>['a'],
        'folders': <Object?>[
          <String, Object?>{
            'id': 'f1',
            'name': '合集',
            'bookIds': <Object?>['a', 'b'],
          },
        ],
      });
      expect(layout.groups, hasLength(1));
      expect(layout.groups.single.id, 'f1');
      expect(layout.groups.single.name, '合集');
      expect(layout.groups.single.bookIds, <String>['a', 'b']);
      // 旧若含非法名 → 回退缩为「未命名分组」（沿用旧「未命名文件夹」口径）。
      final ShelfLayout unnamed = ShelfLayout.fromJson(<String, Object?>{
        'folders': <Object?>[
          <String, Object?>{'id': 'f2', 'name': ''},
        ],
      });
      expect(unnamed.groups.single.name, '未命名分组');
    });

    test('groupOf / groupedBookIds', () {
      const ShelfLayout layout = ShelfLayout(
        groups: <BookGroup>[
          BookGroup(id: 'g1', name: '甲', bookIds: <String>['a', 'b']),
          BookGroup(id: 'g2', name: '乙', bookIds: <String>['c']),
        ],
      );
      expect(layout.groupOf('b')?.id, 'g1');
      expect(layout.groupOf('c')?.id, 'g2');
      expect(layout.groupOf('z'), isNull);
      expect(layout.groupedBookIds, <String>{'a', 'b', 'c'});
    });

    test('groupById / groupByName（同名取第一个）', () {
      const ShelfLayout layout = ShelfLayout(
        groups: <BookGroup>[
          BookGroup(id: 'g1', name: '玄幻', bookIds: <String>['a']),
          BookGroup(id: 'g2', name: '玄幻', bookIds: <String>['b']),
        ],
      );
      expect(layout.groupById('g2')?.name, '玄幻');
      expect(layout.groupById('不存在'), isNull);
      expect(layout.groupByName(' 玄幻 ')?.id, 'g1'); // 首尾空白被裁掉
      expect(layout.groupByName('没有'), isNull);
    });

    test('toJson 写 `groups` 键（非旧 `folders`）且往返一致', () {
      const ShelfLayout layout = ShelfLayout(
        order: <String>['a', 'b'],
        groups: <BookGroup>[
          BookGroup(id: 'g1', name: '甲', bookIds: <String>['c']),
        ],
      );
      final Map<String, Object?> json = layout.toJson();
      expect(json.containsKey('groups'), isTrue);
      expect(json.containsKey('folders'), isFalse);

      final ShelfLayout round = ShelfLayout.fromJson(json);
      expect(round.order, layout.order);
      expect(round.groups.single.id, 'g1');
      expect(round.groups.single.name, '甲');
      expect(round.groups.single.bookIds, <String>['c']);
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

    test('createGroup 返回 id 且成员按传入顺序排列', () async {
      final String id = await store.createGroup(
        name: '科幻',
        bookIds: <String>['a', 'b'],
      );
      expect(id, isNotEmpty);
      expect(store.layout.groups, hasLength(1));
      expect(store.layout.groups.single.id, id);
      expect(store.layout.groups.single.name, '科幻');
      expect(store.layout.groups.single.bookIds, <String>['a', 'b']);
    });

    test('createGroup 空名 / 纯空白 → 落「未命名分组」（不留空名 chip）', () async {
      await store.createGroup(name: '   ', bookIds: <String>['a']);
      expect(store.layout.groups.single.name, '未命名分组');
    });

    test('两个分组 id 不重复', () async {
      final String first =
          await store.createGroup(name: '甲', bookIds: <String>['a']);
      final String second =
          await store.createGroup(name: '乙', bookIds: <String>['b']);
      expect(first, isNot(second));
    });

    test('assignToGroup 保证归属唯一：从原分组摘出', () async {
      final String g1 =
          await store.createGroup(name: '甲', bookIds: <String>['a', 'b']);
      final String g2 =
          await store.createGroup(name: '乙', bookIds: <String>['c']);

      await store.assignToGroup(g2, <String>['b']);

      final BookGroup first =
          store.layout.groups.firstWhere((BookGroup g) => g.id == g1);
      final BookGroup second =
          store.layout.groups.firstWhere((BookGroup g) => g.id == g2);
      expect(first.bookIds, <String>['a']);
      expect(second.bookIds, <String>['c', 'b']);
      // 一本书只属于一个分组。
      expect(store.layout.groupOf('b')?.id, g2);
    });

    test('assignToGroup 对已在目标分组里的书不产生重复项', () async {
      final String g1 =
          await store.createGroup(name: '甲', bookIds: <String>['a']);
      await store.assignToGroup(g1, <String>['a']);
      expect(store.layout.groups.single.bookIds, <String>['a']);
    });

    test('assignToGroup 目标不存在时空操作', () async {
      await store.assignToGroup('不存在', <String>['a']);
      expect(store.layout.isEmpty, isTrue);
    });

    test('assignByName：同名并入已有分组，不新建第二个', () async {
      final String g1 =
          await store.createGroup(name: '玄幻', bookIds: <String>['a']);

      final String? returned = await store.assignByName('b', ' 玄幻 ');

      expect(returned, g1);
      expect(store.layout.groups, hasLength(1));
      expect(store.layout.groups.single.bookIds, <String>['a', 'b']);
    });

    test('assignByName：名字不存在则新建分组并归入', () async {
      final String? id = await store.assignByName('a', '玄幻');
      expect(id, isNotNull);
      expect(store.layout.groups, hasLength(1));
      expect(store.layout.groups.single.name, '玄幻');
      expect(store.layout.groupOf('a')?.id, id);
    });

    test('assignByName：空名 / 纯空白被拒绝（不建组、不改归属）', () async {
      expect(await store.assignByName('a', '   '), isNull);
      expect(store.layout.isEmpty, isTrue);
    });

    test('assignByName：把书从原分组挪到新名分组（归属唯一）', () async {
      await store.assignByName('a', '甲');
      await store.assignByName('a', '乙');
      expect(store.layout.groups, hasLength(2));
      expect(store.layout.groupOf('a')?.name, '乙');
      // 甲组已空但仍在（空组由 prune 清理，不在本方法的职责内）。
      expect(
        store.layout.groups.firstWhere((BookGroup g) => g.name == '甲').bookIds,
        isEmpty,
      );
    });

    test('removeFromGroup 把书移出分组（变未分组）', () async {
      final String id =
          await store.createGroup(name: '甲', bookIds: <String>['a', 'b']);
      await store.removeFromGroup(id, <String>['a']);
      expect(store.layout.groups.single.bookIds, <String>['b']);
      expect(store.layout.groupOf('a'), isNull);
    });

    test('renameGroup 生效；空白名被拒绝（保持原名）', () async {
      final String id =
          await store.createGroup(name: '旧名', bookIds: <String>['a']);

      await store.renameGroup(id, '新名');
      expect(store.layout.groups.single.name, '新名');

      await store.renameGroup(id, '   ');
      expect(store.layout.groups.single.name, '新名');
    });

    test('deleteGroup 移除分组（书变未分组）', () async {
      final String id =
          await store.createGroup(name: '甲', bookIds: <String>['a']);
      await store.deleteGroup(id);
      expect(store.layout.groups, isEmpty);
      expect(store.layout.groupOf('a'), isNull);
    });

    test('prune 清掉孤儿 bookId 与随之变空的分组', () async {
      final String keep =
          await store.createGroup(name: '保留', bookIds: <String>['a', 'b']);
      await store.createGroup(name: '全删', bookIds: <String>['x', 'y']);
      await store.setOrder(<String>['a', 'x', 'b']);

      await store.prune(<String>{'a', 'b'});

      expect(store.layout.order, <String>['a', 'b']);
      expect(store.layout.groups, hasLength(1));
      expect(store.layout.groups.single.id, keep);
      expect(store.layout.groups.single.bookIds, <String>['a', 'b']);
    });

    test('写入的是 `groups` 键：落盘文件不含旧 `folders` 键', () async {
      await store.createGroup(name: '玄幻', bookIds: <String>['a']);
      final String raw = await layoutFile.readAsString();
      expect(raw.contains('"groups"'), isTrue);
      expect(raw.contains('"folders"'), isFalse);
    });

    test('旧 `folders` 文件可被 load 读出，并在下次写盘后归一为 `groups`', () async {
      await layoutFile.writeAsString(
        '{"order":["a"],"folders":[{"id":"f1","name":"合集","bookIds":["a"]}]}',
      );
      await store.load();
      expect(store.layout.groups.single.name, '合集');

      await store.renameGroup('f1', '改名');
      final String raw = await layoutFile.readAsString();
      expect(raw.contains('"groups"'), isTrue);
      expect(raw.contains('"folders"'), isFalse);
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
