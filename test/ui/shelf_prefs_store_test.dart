// `ShelfPrefsStore` 纯逻辑测试：**分组筛选**（2026-09-29 改版，`P2-02`）。
//
// 背景：筛选项原为「阅读状态」（`ShelfReadingFilter { unread, reading, finished }`，
// 单选），现按拍板改为**分组**——`groupId` 为 `null` 表示「全部」，非空表示
// 只看该分组；旧 `filters` 键（阅读状态语义）**忽略不迁移**。
//
// 全部是 `test()`，无 `testWidgets`——不涉及 FakeAsync 铁律，可照常 await 真 IO。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';

void main() {
  late Directory tempDir;
  late ShelfPrefsStore store;
  late File prefsFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mreader_shelf_prefs_');
    store = ShelfPrefsStore(tempDir);
    prefsFile = File(
      '${tempDir.path}${Platform.pathSeparator}shelf_prefs.json',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ShelfPrefs 分组筛选', () {
    test('默认「全部」：groupId 为 null、hasGroup 为 false', () {
      expect(const ShelfPrefs().groupId, isNull);
      expect(const ShelfPrefs().hasGroup, isFalse);
    });

    test('setGroup：选中 → 换另一个（顶掉）→ 传 null 回「全部」', () async {
      await store.setGroup('g1');
      expect(store.prefs.groupId, 'g1');
      expect(store.prefs.hasGroup, isTrue);

      await store.setGroup('g2');
      expect(store.prefs.groupId, 'g2'); // 单选：不叠加

      await store.setGroup(null);
      expect(store.prefs.groupId, isNull);
      expect(store.prefs.hasGroup, isFalse);
    });

    test('setGroup 传同一个 id 是空操作（不产生多余写盘）', () async {
      await store.setGroup('g1');
      final String before = await prefsFile.readAsString();
      await store.setGroup('g1');
      expect(await prefsFile.readAsString(), before);
    });

    test('setGroup(null) 切换分组时不影响排序字段与方向', () async {
      await store.setSortField(ShelfSortField.title); // 非默认字段
      await store.setGroup('g1');
      await store.setGroup(null);
      expect(store.prefs.sortField, ShelfSortField.title);
      expect(store.prefs.sortAscending, isFalse);
    });

    test('toJson：无分组时**不写** group 键；有分组时写 id', () {
      expect(
        const ShelfPrefs().toJson().containsKey('group'),
        isFalse,
      );
      expect(const ShelfPrefs(groupId: 'g1').toJson()['group'], 'g1');
    });

    test('toJson / fromJson 往返一致', () {
      const ShelfPrefs prefs = ShelfPrefs(
        groupId: 'g9',
        sortField: ShelfSortField.author,
        sortAscending: true,
      );
      final ShelfPrefs back = ShelfPrefs.fromJson(prefs.toJson());
      expect(back.groupId, 'g9');
      expect(back.sortField, ShelfSortField.author);
      expect(back.sortAscending, isTrue);
    });

    test('fromJson 非法 group 值回退「全部」（非字符串 / 空串）', () {
      expect(
        ShelfPrefs.fromJson(<String, Object?>{'group': 42}).groupId,
        isNull,
      );
      expect(
        ShelfPrefs.fromJson(<String, Object?>{'group': ''}).groupId,
        isNull,
      );
      expect(
        ShelfPrefs.fromJson(<String, Object?>{'group': 'g1'}).groupId,
        'g1',
      );
    });

    test('旧 `filters` 键（阅读状态）被忽略：不映射成假分组，仅保留排序', () {
      final ShelfPrefs prefs = ShelfPrefs.fromJson(<String, Object?>{
        'filters': <Object?>['finished'],
        'sortField': 'title',
        'sortAscending': true,
      });
      expect(prefs.groupId, isNull); // 不把 'finished' 当分组 id
      expect(prefs.sortField, ShelfSortField.title);
      expect(prefs.sortAscending, isTrue);
    });

    test('非 Map / 字段缺失时逐项回退默认值', () {
      expect(ShelfPrefs.fromJson(null).groupId, isNull);
      expect(ShelfPrefs.fromJson('nope').sortField, ShelfSortField.importedAt);
      expect(ShelfPrefs.fromJson(<String, Object?>{}).sortAscending, isFalse);
    });
  });

  group('ShelfPrefsStore 排序', () {
    test('setSortField：换字段 → 重置为降序；同字段 → 翻转方向', () async {
      await store.setSortField(ShelfSortField.title);
      expect(store.prefs.sortField, ShelfSortField.title);
      expect(store.prefs.sortAscending, isFalse);

      await store.setSortField(ShelfSortField.title);
      expect(store.prefs.sortAscending, isTrue);

      await store.setSortField(ShelfSortField.author);
      expect(store.prefs.sortField, ShelfSortField.author);
      expect(store.prefs.sortAscending, isFalse); // 换字段即重置
    });

    test('setSortAscending：同值空操作，异值写盘', () async {
      await store.setSortAscending(false);
      expect(store.prefs.sortAscending, isFalse);

      await store.setSortAscending(true);
      expect(store.prefs.sortAscending, isTrue);
    });
  });

  group('ShelfPrefsStore 落盘与监听', () {
    test('落盘后新实例 load 能恢复分组与排序', () async {
      await store.setGroup('g7');
      await store.setSortField(ShelfSortField.lastReadAt);

      final ShelfPrefsStore reopened = ShelfPrefsStore(tempDir);
      await reopened.load();
      expect(reopened.prefs.groupId, 'g7');
      expect(reopened.prefs.sortField, ShelfSortField.lastReadAt);
      expect(reopened.isLoaded, isTrue);
    });

    test('监听：变更时通知，退订后不再通知', () async {
      int hits = 0;
      void listener() => hits++;

      store.addListener(listener);
      await store.setGroup('g1');
      expect(hits, 1);

      store.removeListener(listener);
      await store.setGroup('g2');
      expect(hits, 1);
    });

    test('load 时通知一次（页面 initState 订阅后能拿到首帧状态）', () async {
      int hits = 0;
      store.addListener(() => hits++);
      await store.load();
      expect(hits, 1);
    });

    test('文件损坏时回退默认值且不抛', () async {
      await prefsFile.writeAsString('{ 不是合法 JSON');
      await store.load();
      expect(store.prefs.groupId, isNull);
      expect(store.prefs.sortField, ShelfSortField.importedAt);
    });
  });
}
