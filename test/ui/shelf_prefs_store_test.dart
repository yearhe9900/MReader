// `ShelfPrefsStore` 纯逻辑测试：阅读状态筛选的**单选**语义（2026-09-29 改版）。
//
// 背景：筛选原为多选 `Set`（chips 可叠加、命中任一即保留），现按拍板改为
// **单选**——同一时刻至多一个维度生效，对齐 anx-reader
// （`providers/book_filters.dart` 的 `ReadingStatusFilter { none, ... }`）。
//
// 全部是 `test()`，无 `testWidgets`——不涉及 FakeAsync 铁律，可照常 await 真 IO。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/shelf_prefs_store.dart';

void main() {
  late Directory tempDir;
  late ShelfPrefsStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mreader_shelf_prefs_');
    store = ShelfPrefsStore(tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ShelfPrefs 单选筛选', () {
    test('默认无筛选；hasFilter 为 false', () {
      expect(const ShelfPrefs().filter, isNull);
      expect(const ShelfPrefs().hasFilter, isFalse);
    });

    test('toggleFilter：选中→切另一个顶掉→再点同一个取消', () async {
      await store.toggleFilter(ShelfReadingFilter.reading);
      expect(store.prefs.filter, ShelfReadingFilter.reading);

      // 单选核心：切到另一个维度时，旧值被**顶掉**而不是叠加。
      await store.toggleFilter(ShelfReadingFilter.finished);
      expect(store.prefs.filter, ShelfReadingFilter.finished);

      // 再点已选中的 → 取消回 null（与 anx toggle 同语义）。
      await store.toggleFilter(ShelfReadingFilter.finished);
      expect(store.prefs.filter, isNull);
      expect(store.prefs.hasFilter, isFalse);
    });

    test('clearFilters 清空筛选但保留排序', () async {
      await store.setSortField(ShelfSortField.title);
      await store.toggleFilter(ShelfReadingFilter.unread);
      await store.clearFilters();

      expect(store.prefs.filter, isNull);
      expect(store.prefs.sortField, ShelfSortField.title);
    });

    test('clearFilters 在无筛选时空操作（不重写文件也行）', () async {
      await store.clearFilters();
      expect(store.prefs.filter, isNull);
    });
  });

  group('ShelfPrefs 序列化', () {
    test('toJson：filters 恒为 0 或 1 个元素的 list', () {
      expect(
        const ShelfPrefs().toJson()['filters'],
        isEmpty,
      );
      expect(
        const ShelfPrefs(filter: ShelfReadingFilter.finished).toJson()['filters'],
        <String>['finished'],
      );
    });

    test('往返一致（filter / sortField / sortAscending）', () {
      const ShelfPrefs prefs = ShelfPrefs(
        filter: ShelfReadingFilter.reading,
        sortField: ShelfSortField.title,
        sortAscending: true,
      );
      final ShelfPrefs back = ShelfPrefs.fromJson(prefs.toJson());
      expect(back.filter, ShelfReadingFilter.reading);
      expect(back.sortField, ShelfSortField.title);
      expect(back.sortAscending, isTrue);
    });

    test('旧版多选文件收敛为单选：只取首个合法值', () {
      final ShelfPrefs back = ShelfPrefs.fromJson(<String, Object?>{
        'filters': <Object?>['finished', 'reading', 'bogus'],
        'sortField': 'author',
        'sortAscending': true,
      });
      expect(back.filter, ShelfReadingFilter.finished);
      expect(back.sortField, ShelfSortField.author);
      expect(back.sortAscending, isTrue);
    });

    test('非 Map / 缺字段回退默认值', () {
      expect(ShelfPrefs.fromJson(null).filter, isNull);
      expect(ShelfPrefs.fromJson('nope').filter, isNull);
      expect(ShelfPrefs.fromJson(<Object?>[]).filter, isNull);
      // filters 是非 list 或含非字符串 → 逐项丢弃。
      expect(
        ShelfPrefs.fromJson(<String, Object?>{'filters': 'reading'}).filter,
        isNull,
      );
      expect(
        ShelfPrefs.fromJson(
          <String, Object?>{'filters': <Object?>[42, null]},
        ).filter,
        isNull,
      );
    });
  });

  group('ShelfPrefsStore 落盘', () {
    test('toggle 后由新实例 load 恢复单选值', () async {
      await store.toggleFilter(ShelfReadingFilter.finished);

      final ShelfPrefsStore reloaded = ShelfPrefsStore(tempDir);
      await reloaded.load();
      expect(reloaded.prefs.filter, ShelfReadingFilter.finished);
      expect(reloaded.isLoaded, isTrue);
    });

    test('清空后落盘，新实例 load 无筛选', () async {
      await store.toggleFilter(ShelfReadingFilter.reading);
      await store.clearFilters();

      final ShelfPrefsStore reloaded = ShelfPrefsStore(tempDir);
      await reloaded.load();
      expect(reloaded.prefs.filter, isNull);
    });
  });
}
