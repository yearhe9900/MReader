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

/// 阅读状态筛选维度（**单选**：至多一个生效；`null` = 不筛选）。
///
/// 2026-09-29 由多选 `Set` 改为单值——对齐 anx-reader 的单选语义
/// （`providers/book_filters.dart:5` 的 `ReadingStatusFilter { none, finished,
/// reading, notStarted }`，其 `none` 在本项目即 `null`）。
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
  author,

  /// **手动顺序**：由书架拖拽重排决定，顺序真值存于 `ShelfLayoutStore`
  /// （`shelf_layout.json` 的 `order`），本枚举只记「当前用哪种排法」。
  ///
  /// 放在枚举末尾：菜单顺序即 `values` 顺序，既有四项的相对次序不动。
  manual;

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
    this.filter,
    this.sortField = ShelfSortField.importedAt,
    this.sortAscending = false,
  });

  /// 生效的阅读状态筛选（**单选**；`null` = 不筛选）。
  final ShelfReadingFilter? filter;

  /// 排序字段。
  final ShelfSortField sortField;

  /// 是否升序（默认降序 = 新的在前）。
  final bool sortAscending;

  /// 是否处于筛选态（用于「清除筛选」入口的显隐）。
  bool get hasFilter => filter != null;

  /// 复制并覆盖部分字段。
  ///
  /// 注意 [filter] 为可空：**无法用它显式置空**（`null` = 不修改）。
  /// 清除筛选走 [ShelfPrefsStore.clearFilters]，它直接构造新对象。
  ShelfPrefs copyWith({
    ShelfReadingFilter? filter,
    ShelfSortField? sortField,
    bool? sortAscending,
  }) {
    return ShelfPrefs(
      filter: filter ?? this.filter,
      sortField: sortField ?? this.sortField,
      sortAscending: sortAscending ?? this.sortAscending,
    );
  }

  /// 序列化。
  ///
  /// 键名沿用 `filters`（list 形态、**恒 0 或 1 个元素**）：与多选时代的
  /// 落盘格式完全兼容，旧文件无需迁移——解析时只取首个合法值（见 [fromJson]）。
  Map<String, Object?> toJson() => <String, Object?>{
        'filters': <String>[
          if (filter != null) filter!.name,
        ],
        'sortField': sortField.name,
        'sortAscending': sortAscending,
      };

  /// 由持久化 JSON 还原；字段缺失 / 类型异常时逐项回退默认值。
  ///
  /// 旧版多选文件（多个维度）按**首个合法值**收敛为单选，其余丢弃。
  static ShelfPrefs fromJson(Object? json) {
    if (json is! Map) {
      return const ShelfPrefs();
    }
    final Object? rawFilters = json['filters'];
    ShelfReadingFilter? filter;
    if (rawFilters is List) {
      for (final Object? item in rawFilters) {
        final ShelfReadingFilter? parsed =
            ShelfReadingFilter.fromName(item is String ? item : null);
        if (parsed != null) {
          filter = parsed; // 单选：多选旧文件取**首个**合法值，其余丢弃。
          break;
        }
      }
    }
    final Object? rawAscending = json['sortAscending'];
    return ShelfPrefs(
      filter: filter,
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

  /// 切换筛选（**单选**，与 anx `ReadingStatusFilterNotifier.toggle` 同语义）：
  /// 点**未选中**的维度 → 选中它（顶掉原值）；点**已选中**的 → 取消（回 `null`）。
  Future<void> toggleFilter(ShelfReadingFilter filter) {
    final ShelfReadingFilter? next =
        _prefs.filter == filter ? null : filter;
    if (next == null) {
      return clearFilters();
    }
    return _update(_prefs.copyWith(filter: next));
  }

  /// 清除筛选（回「全部」）。
  Future<void> clearFilters() {
    if (_prefs.filter == null) {
      return Future<void>.value();
    }
    // `copyWith` 的可空参数无法显式置空 → 直接构造新值对象。
    return _update(
      ShelfPrefs(
        filter: null,
        sortField: _prefs.sortField,
        sortAscending: _prefs.sortAscending,
      ),
    );
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
