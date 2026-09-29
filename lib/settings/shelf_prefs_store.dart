// 书架偏好持久化（分组筛选 + 排序）。
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
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-09-29 拍板：**筛选项由「阅读状态」改为「分组」**
// ══════════════════════════════════════════════════════════════════════════════
// 原 `ShelfReadingFilter { unread, reading, finished }`（单选）整体删除——
// 书架顶部 chips 改为「**全部** + 各分组名」，筛选值变成**分组 id**
// （`null` = 全部）。分组本身由 `ShelfLayoutStore` 持有（`BookGroup`），
// 本文件只记「用户当前在看哪个分组」。
//
// 旧 `shelf_prefs.json` 的 `filters` 键（阅读状态语义）**直接忽略、不迁移**：
// 旧值（`finished` / `reading` / `unread`）在新语义下不是合法的分组 id，
// 强行映射只会造出假分组；忽略后行为等价于「回到全部」，损失仅是「记住的
// 筛选态」这一个视图状态，用户再点一下即可。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

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

  /// **手动顺序**：顺序真值存于 `ShelfLayoutStore`（`shelf_layout.json` 的
  /// `order`），本枚举只记「当前用哪种排法」。
  ///
  /// 写入侧曾是书架拖拽重排（2026-09-29 已删）；本项保留以便继续消费历史
  /// `order` 数据，菜单顺序即 `values` 顺序，既有四项的相对次序不动。
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
    this.groupId,
    this.sortField = ShelfSortField.importedAt,
    this.sortAscending = false,
  });

  /// 当前选中的分组 id（**单选**；`null` = 「全部」，即不按分组筛选）。
  ///
  /// 注意这是**分组 id 而非名字**：分组可重名（本模型不禁止），只有 id 稳定。
  final String? groupId;

  /// 排序字段。
  final ShelfSortField sortField;

  /// 是否升序（默认降序 = 新的在前）。
  final bool sortAscending;

  /// 是否处于筛选态（用于「全部」chip 的选中态）。
  bool get hasGroup => groupId != null;

  /// 复制并覆盖部分字段。
  ///
  /// 注意 [groupId] 为可空：**无法用它显式置空**（`null` = 不修改）。
  /// 回到「全部」走 [ShelfPrefsStore.setGroup] 传 `null`，它直接构造新对象。
  ShelfPrefs copyWith({
    String? groupId,
    ShelfSortField? sortField,
    bool? sortAscending,
  }) {
    return ShelfPrefs(
      groupId: groupId ?? this.groupId,
      sortField: sortField ?? this.sortField,
      sortAscending: sortAscending ?? this.sortAscending,
    );
  }

  /// 序列化。
  ///
  /// `group` 为 `null`（全部）时**省略该键**——不写 `"group": null`，
  /// 让「全部」状态的文件保持最小形态。
  Map<String, Object?> toJson() => <String, Object?>{
        if (groupId != null) 'group': groupId,
        'sortField': sortField.name,
        'sortAscending': sortAscending,
      };

  /// 由持久化 JSON 还原；字段缺失 / 类型异常时逐项回退默认值。
  ///
  /// 旧版 `filters` 键（阅读状态）**忽略**，见文件头注。
  static ShelfPrefs fromJson(Object? json) {
    if (json is! Map) {
      return const ShelfPrefs();
    }
    final Object? rawGroup = json['group'];
    final String? groupId =
        (rawGroup is String && rawGroup.isNotEmpty) ? rawGroup : null;
    final Object? rawAscending = json['sortAscending'];
    return ShelfPrefs(
      groupId: groupId,
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

  /// 选中分组（**单选**）；传 `null` 回到「全部」。
  ///
  /// 再点**已选中**的 chips 也走这里传 `null`（交互层的「再点取消」语义）。
  Future<void> setGroup(String? groupId) {
    if (_prefs.groupId == groupId) {
      return Future<void>.value();
    }
    if (groupId == null) {
      // `copyWith` 的可空参数无法显式置空 → 直接构造新值对象。
      return _update(
        ShelfPrefs(
          groupId: null,
          sortField: _prefs.sortField,
          sortAscending: _prefs.sortAscending,
        ),
      );
    }
    return _update(_prefs.copyWith(groupId: groupId));
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
