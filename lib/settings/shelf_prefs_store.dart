// 书架偏好持久化（阅读状态筛选 + 排序）。
//
// 与 [SettingsStore] / [PerfPrefsStore] **同一形制**，勿另创写法：
//   · 落盘一律经 `JsonStore` → `AtomicFile`（`DATA-01` 原子写入）；
//   · 跨页面共享用「进程内共享实例 + 监听回调」，页面 `initState` 订阅、
//     `dispose` 退订、回调内 `setState`（**不引入 Provider / Riverpod**）；
//   · **不使用可变全局单例**：实例在 `main()` 显式创建并构造注入。
//
// 为什么单独一个文件而不是塞进 `Settings`：`Settings` 是**阅读偏好**
// （主题 / 字号 / 行距），改动会触发阅读页重排；书架筛选属于**列表视图偏好**，
// 生命周期与波及面都不同，混在一起会让「改字号」意外重写书架状态。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 阅读状态筛选维度（**可多选**；空集 = 不筛选）。
enum ShelfReadingFilter {
  /// 未开始（`readProgress` 为空或 `0`）。
  unread,

  /// 在读（`0 < readProgress < 1`）。
  reading,

  /// 已读完（`readProgress >= 1`）。
  finished;

  /// 由持久化字符串解析；未知值返回 `null`（由调用方丢弃）。
  static ShelfReadingFilter? fromName(String? name) {
    for (final ShelfReadingFilter value in ShelfReadingFilter.values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }
}

/// 书架排序字段。
enum ShelfSortField {
  /// 导入时间。
  importedAt,

  /// 最近阅读时间（从未读过者排最后）。
  lastReadAt,

  /// 书名。
  title,

  /// 作者。
  author;

  /// 由持久化字符串解析；未知或缺失时回退 [ShelfSortField.importedAt]。
  static ShelfSortField fromName(String? name) {
    for (final ShelfSortField value in ShelfSortField.values) {
      if (value.name == name) {
        return value;
      }
    }
    return ShelfSortField.importedAt;
  }
}

/// 书架偏好的值对象（不可变）。
class ShelfPrefs {
  /// 创建书架偏好。
  const ShelfPrefs({
    this.filters = const <ShelfReadingFilter>{},
    this.sortField = ShelfSortField.importedAt,
    this.sortAscending = false,
  });

  /// 生效的筛选维度集合。
  final Set<ShelfReadingFilter> filters;

  /// 排序字段。
  final ShelfSortField sortField;

  /// 是否升序（默认降序 = 新的在前）。
  final bool sortAscending;

  /// 是否处于筛选态（用于「清除筛选」入口的显隐）。
  bool get hasFilter => filters.isNotEmpty;

  /// 复制并覆盖部分字段。
  ShelfPrefs copyWith({
    Set<ShelfReadingFilter>? filters,
    ShelfSortField? sortField,
    bool? sortAscending,
  }) {
    return ShelfPrefs(
      filters: filters ?? this.filters,
      sortField: sortField ?? this.sortField,
      sortAscending: sortAscending ?? this.sortAscending,
    );
  }

  /// 序列化。
  Map<String, Object?> toJson() => <String, Object?>{
        'filters': filters.map((ShelfReadingFilter f) => f.name).toList(),
        'sortField': sortField.name,
        'sortAscending': sortAscending,
      };

  /// 由持久化 JSON 还原；字段缺失 / 类型异常时逐项回退默认值。
  static ShelfPrefs fromJson(Object? json) {
    if (json is! Map) {
      return const ShelfPrefs();
    }
    final Object? rawFilters = json['filters'];
    final Set<ShelfReadingFilter> filters = <ShelfReadingFilter>{};
    if (rawFilters is List) {
      for (final Object? item in rawFilters) {
        final ShelfReadingFilter? parsed =
            ShelfReadingFilter.fromName(item is String ? item : null);
        if (parsed != null) {
          filters.add(parsed);
        }
      }
    }
    final Object? rawAscending = json['sortAscending'];
    return ShelfPrefs(
      filters: filters,
      sortField: ShelfSortField.fromName(json['sortField'] as String?),
      sortAscending: rawAscending is bool ? rawAscending : false,
    );
  }
}

/// 书架偏好持久化服务（进程内共享，显式注入）。
class ShelfPrefsStore {
  /// 创建偏好服务（`dataDir` 通常来自 `AppPaths.dataDir()`）。
  ShelfPrefsStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}shelf_prefs.json',
          ),
        );

  final JsonStore _store;

  ShelfPrefs _prefs = const ShelfPrefs();
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前偏好（只读快照）。未 [load] 时返回默认值。
  ShelfPrefs get prefs => _prefs;

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 从磁盘加载；文件缺失或损坏时回退默认值（回退语义见 [JsonStore]）。
  Future<void> load() async {
    final Object? json = await _store.read();
    _prefs = ShelfPrefs.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 切换一个筛选维度（多选：已在集合中则移除）。
  Future<void> toggleFilter(ShelfReadingFilter filter) {
    final Set<ShelfReadingFilter> next = <ShelfReadingFilter>{..._prefs.filters};
    if (!next.remove(filter)) {
      next.add(filter);
    }
    return _update(_prefs.copyWith(filters: next));
  }

  /// 清空全部筛选。
  Future<void> clearFilters() {
    if (_prefs.filters.isEmpty) {
      return Future<void>.value();
    }
    return _update(_prefs.copyWith(filters: const <ShelfReadingFilter>{}));
  }

  /// 设置排序字段；点同一字段则**翻转方向**（列表类界面的通行手感）。
  Future<void> setSortField(ShelfSortField field) {
    if (_prefs.sortField == field) {
      return _update(_prefs.copyWith(sortAscending: !_prefs.sortAscending));
    }
    return _update(_prefs.copyWith(sortField: field, sortAscending: false));
  }

  /// 显式设置排序方向。
  Future<void> setSortAscending(bool ascending) {
    if (_prefs.sortAscending == ascending) {
      return Future<void>.value();
    }
    return _update(_prefs.copyWith(sortAscending: ascending));
  }

  /// 订阅偏好变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订偏好变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 更新内存状态 → 通知监听者 → 原子落盘。
  Future<void> _update(ShelfPrefs next) async {
    _prefs = next;
    _notify();
    await _store.write(next.toJson());
  }

  /// 通知所有监听者；遍历副本以容忍回调内的订阅 / 退订。
  void _notify() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
