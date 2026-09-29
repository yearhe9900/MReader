// 书架**布局**持久化（手动排序顺序 + 书的分组归属）。
//
// 与 [ShelfPrefsStore] **同一形制**，勿另创写法：
//   · 落盘一律经 `JsonStore` → `AtomicFile`（`DATA-01` 原子写入）；
//   · 跨页面共享用「进程内共享实例 + 监听回调」，页面 `initState` 订阅、
//     `dispose` 退订、回调内 `setState`（**不引入 Provider / Riverpod**）；
//   · **不使用可变全局单例**：实例在 `main()` 显式创建并构造注入。
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-09-29 拍板：**分组取代文件夹**、移除拖拽归类
// ══════════════════════════════════════════════════════════════════════════════
// 原「文件夹」（`BookFolder`）与需求 `P2-02`「书架分组」在数据形状上完全同构
// ——都是「一个名字 + 一组书，且**一本书归属唯一**」——故不新起第二套归类系统，
// 直接把模型改名为分组（`BookGroup`）：
//   · 书架的归类入口不再是拖拽，而是**书籍详情页的「分组」行**（选择 / 新建）；
//   · 书架顶部按分组筛选（「全部」+ 各分组名），网格平铺展示，无文件夹卡与内页；
//   · 旧 `shelf_layout.json` 的 `folders` 键**读取兼容**（见 [ShelfLayout.fromJson]），
//     写盘改 `groups` —— 旧数据一个不丢。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么是**独立文件**，而不是给 `BookRecord` 加字段（2026-09-28 拍板，仍有效）
// ══════════════════════════════════════════════════════════════════════════════
// 1. `BookRecord` 是**书目元数据**（书名 / 作者 / 封面 / 导入时间…），由
//    `BookIndex` 统一落在 `index.json`；分组归属与手动顺序是**列表视图状态**，
//    语义正交。混进 `BookRecord` 会让改一次分组都要把整份 `index.json`
//    （含全部元数据）重写一遍。
// 2. **零旧索引兼容成本**：不动 `BookRecord` 的序列化，就不存在
//    「旧 `index.json` 缺新字段」的迁移问题（这是拍板时明确要规避的风险）。
// 3. 与 [ShelfPrefsStore] 同一生命周期（都是书架的视图状态），但**仍分文件**：
//    改一次筛选不该连带重写布局数据。
//
// ⚠️ **孤儿引用**：书目被删（`LibraryRepository.deleteBook`）后，本文件里可能
// 残留其 `bookId`。处置是**两道**——渲染期按当前书目过滤（见 `shelf_page`
// 的 `_visibleBooks`），加上删书后显式 [ShelfLayoutStore.prune] 落盘清理。
// **不假设两者总是一致**。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 一个书架分组（原「文件夹」，2026-09-29 改名）。
///
/// **一本书只属于一个分组**（归属唯一，由 [ShelfLayoutStore.assignToGroup]
/// 与 [ShelfLayoutStore.createGroup] 的摘出逻辑保证）；不在任何分组里的书视为
/// 「未分组」，在书架的「全部」里正常展示。
class BookGroup {
  /// 创建分组。
  const BookGroup({
    required this.id,
    required this.name,
    this.bookIds = const <String>[],
  });

  /// 分组 id（由 [ShelfLayoutStore] 生成，全局唯一）。
  final String id;

  /// 显示名（书架筛选 chip 与详情页显示的就是它）。
  final String name;

  /// 归属书目（顺序 = 加入顺序）。
  final List<String> bookIds;

  /// 复制并覆盖部分字段。
  BookGroup copyWith({String? name, List<String>? bookIds}) => BookGroup(
        id: id,
        name: name ?? this.name,
        bookIds: bookIds ?? this.bookIds,
      );

  /// 序列化。
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'bookIds': bookIds,
      };

  /// 由 JSON 还原；`id` 缺失或非法时返回 `null`（由调用方丢弃该条）。
  ///
  /// 容错口径与 [ShelfPrefs.fromJson] 一致：**能救的字段救，救不了的丢**，
  /// 绝不因为一条坏数据让整个布局文件失效。
  static BookGroup? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? rawId = json['id'];
    if (rawId is! String || rawId.isEmpty) {
      return null;
    }
    final Object? rawName = json['name'];
    final List<String> bookIds = <String>[];
    final Object? rawBooks = json['bookIds'];
    if (rawBooks is List) {
      for (final Object? item in rawBooks) {
        if (item is String && item.isNotEmpty) {
          bookIds.add(item);
        }
      }
    }
    return BookGroup(
      id: rawId,
      name: rawName is String && rawName.isNotEmpty ? rawName : '未命名分组',
      bookIds: bookIds,
    );
  }
}

/// 书架布局的值对象（不可变）。
class ShelfLayout {
  /// 创建布局。
  const ShelfLayout({
    this.order = const <String>[],
    this.groups = const <BookGroup>[],
  });

  /// 手动顺序下 bookId 的显式次序。
  ///
  /// **不在本列表中的书**由渲染方自行兜底（见 `shelf_page`：按导入时间降序追加），
  /// 因此本列表**允许不完整**——新导入的书不必立刻改写这里。
  ///
  /// 写入侧曾是拖拽重排（2026-09-29 已删），现仅消费历史数据。
  final List<String> order;

  /// 分组（**顺序 = 书架筛选 chip 的展示顺序**，即创建顺序）。
  final List<BookGroup> groups;

  /// 是否空布局（无顺序、无分组）。
  bool get isEmpty => order.isEmpty && groups.isEmpty;

  /// 已归入任一分组的 bookId 集合。
  Set<String> get groupedBookIds => <String>{
        for (final BookGroup group in groups) ...group.bookIds,
      };

  /// 某书所属的分组；未分组时返回 `null`。
  ///
  /// 归属**唯一**：写入侧（[ShelfLayoutStore.assignToGroup]）保证一本书不会
  /// 同时出现在两个分组里，这里按「先命中先返回」读取。
  BookGroup? groupOf(String bookId) {
    for (final BookGroup group in groups) {
      if (group.bookIds.contains(bookId)) {
        return group;
      }
    }
    return null;
  }

  /// 按 id 找分组；不存在返回 `null`。
  BookGroup? groupById(String groupId) {
    for (final BookGroup group in groups) {
      if (group.id == groupId) {
        return group;
      }
    }
    return null;
  }

  /// 按名字找分组（同名取第一个）；不存在返回 `null`。
  BookGroup? groupByName(String name) {
    final String trimmed = name.trim();
    for (final BookGroup group in groups) {
      if (group.name == trimmed) {
        return group;
      }
    }
    return null;
  }

  /// 复制并覆盖部分字段。
  ShelfLayout copyWith({List<String>? order, List<BookGroup>? groups}) =>
      ShelfLayout(
        order: order ?? this.order,
        groups: groups ?? this.groups,
      );

  /// 序列化。
  Map<String, Object?> toJson() => <String, Object?>{
        'order': order,
        'groups': groups
            .map((BookGroup group) => group.toJson())
            .toList(growable: false),
      };

  /// 由持久化 JSON 还原；顶层类型异常时整体回退空布局。
  ///
  /// **旧键兼容**：2026-09-29 之前落盘的是 `folders`（同名同形的「文件夹」），
  /// 故 `groups` 缺失时回退读 `folders` —— 旧数据无损升级，下次写盘自动归一。
  static ShelfLayout fromJson(Object? json) {
    if (json is! Map) {
      return const ShelfLayout();
    }
    final List<String> order = <String>[];
    final Object? rawOrder = json['order'];
    if (rawOrder is List) {
      for (final Object? item in rawOrder) {
        if (item is String && item.isNotEmpty) {
          order.add(item);
        }
      }
    }
    final List<BookGroup> groups = <BookGroup>[];
    final Object? rawGroups = json['groups'] ?? json['folders'];
    if (rawGroups is List) {
      for (final Object? item in rawGroups) {
        final BookGroup? group = BookGroup.fromJson(item);
        if (group != null) {
          groups.add(group);
        }
      }
    }
    return ShelfLayout(order: order, groups: groups);
  }
}

/// 书架布局持久化服务（进程内共享，显式注入）。
class ShelfLayoutStore {
  /// 创建布局服务（`dataDir` 通常来自 `AppPaths.dataDir()`）。
  ShelfLayoutStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}shelf_layout.json',
          ),
        );

  final JsonStore _store;

  ShelfLayout _layout = const ShelfLayout();
  bool _loaded = false;

  /// 分组 id 的防撞计数（同一微秒内连续建分组时兜底）。
  int _idSeq = 0;

  final List<void Function()> _listeners = <void Function()>[];

  /// 当前布局（只读快照）。未 [load] 时返回空布局。
  ShelfLayout get layout => _layout;

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 从磁盘加载；文件缺失或损坏时回退空布局（回退语义见 [JsonStore]）。
  Future<void> load() async {
    final Object? json = await _store.read();
    _layout = ShelfLayout.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 写入显式顺序（历史拖拽重排的数据；当前无 UI 写入口）。
  Future<void> setOrder(List<String> bookIds) =>
      _update(_layout.copyWith(order: List<String>.of(bookIds)));

  /// 新建分组并收进 [bookIds]，返回新分组 id。
  ///
  /// 收进来的书会**先**从原有分组摘出（保证归属唯一）。
  Future<String> createGroup({
    required String name,
    required List<String> bookIds,
  }) async {
    final String id = _newGroupId();
    final List<BookGroup> groups = _stripFromGroups(
      _layout.groups,
      bookIds.toSet(),
    );
    groups.add(
      BookGroup(
        id: id,
        name: name.trim().isEmpty ? '未命名分组' : name.trim(),
        bookIds: List<String>.of(bookIds),
      ),
    );
    await _update(_layout.copyWith(groups: groups));
    return id;
  }

  /// 把**单本**书按名字归组：同名分组已存在则并入，否则新建。
  ///
  /// 详情页「分组」入口用这一个方法覆盖「选已有分组」与「新建分组」两种动作
  /// （先查 [ShelfLayout.groupByName] 再决定走哪条，逻辑留在本层便于单测）。
  /// 空名 / 纯空白被拒绝，返回 `null`。
  Future<String?> assignByName(String bookId, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final BookGroup? existing = _layout.groupByName(trimmed);
    if (existing != null) {
      await assignToGroup(existing.id, <String>[bookId]);
      return existing.id;
    }
    return createGroup(name: trimmed, bookIds: <String>[bookId]);
  }

  /// 重命名分组（空名或纯空白被拒绝，保持原名）。
  Future<void> renameGroup(String groupId, String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return Future<void>.value();
    }
    return _update(
      _layout.copyWith(
        groups: <BookGroup>[
          for (final BookGroup group in _layout.groups)
            if (group.id == groupId)
              group.copyWith(name: trimmed)
            else
              group,
        ],
      ),
    );
  }

  /// 把 [bookIds] 归入指定分组（追加到末尾；已在此分组则不动）。
  ///
  /// 这些书会**先**从其它分组摘出——一本书同时只属于一个分组。
  Future<void> assignToGroup(String groupId, List<String> bookIds) {
    final int index =
        _layout.groups.indexWhere((BookGroup g) => g.id == groupId);
    if (index < 0) {
      return Future<void>.value();
    }
    final Set<String> incoming = bookIds.toSet();
    final List<BookGroup> groups =
        _stripFromGroups(_layout.groups, incoming, exceptId: groupId);
    final BookGroup target = groups[index];
    final List<String> merged = <String>[
      ...target.bookIds,
      for (final String id in bookIds)
        if (!target.bookIds.contains(id)) id,
    ];
    groups[index] = target.copyWith(bookIds: merged);
    return _update(_layout.copyWith(groups: groups));
  }

  /// 把 [bookIds] 移出所属分组（成为「未分组」）。
  Future<void> removeFromGroup(String groupId, List<String> bookIds) {
    final Set<String> removing = bookIds.toSet();
    return _update(
      _layout.copyWith(
        groups: <BookGroup>[
          for (final BookGroup group in _layout.groups)
            if (group.id == groupId)
              group.copyWith(
                bookIds: group.bookIds
                    .where((String id) => !removing.contains(id))
                    .toList(),
              )
            else
              group,
        ],
      ),
    );
  }

  /// 删除分组（书变为「未分组」，顺序不变）。
  Future<void> deleteGroup(String groupId) {
    if (!_layout.groups.any((BookGroup g) => g.id == groupId)) {
      return Future<void>.value();
    }
    return _update(
      _layout.copyWith(
        groups: _layout.groups
            .where((BookGroup g) => g.id != groupId)
            .toList(growable: false),
      ),
    );
  }

  /// 清理孤儿引用（书目已从书架删除）。
  ///
  /// 顺带清掉**变空的分组**——书都删光了，空壳没有存在意义（书架筛选 chip
  /// 因此天然只列出「真的有书」的分组）。
  /// 无实际变化时**不写盘**（避免每次启动都白写一次）。
  Future<void> prune(Set<String> validBookIds) async {
    final List<String> order = _layout.order
        .where((String id) => validBookIds.contains(id))
        .toList();
    final List<BookGroup> groups = <BookGroup>[];
    for (final BookGroup group in _layout.groups) {
      final List<String> kept = group.bookIds
          .where((String id) => validBookIds.contains(id))
          .toList();
      if (kept.isNotEmpty) {
        groups.add(group.copyWith(bookIds: kept));
      }
    }
    if (_sameStringList(order, _layout.order) &&
        _sameGroups(groups, _layout.groups)) {
      return;
    }
    await _update(_layout.copyWith(order: order, groups: groups));
  }

  /// 订阅布局变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订布局变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 生成不冲突的分组 id。
  ///
  /// 用「微秒时间戳转 36 进制」而非 `Random`：可读、单调、无需额外依赖；
  /// 同一微秒内重复调用时由 [_idSeq] 兜底加后缀。前缀 `g` = group（旧数据
  /// 的 `f` 前缀 id 照常读入、不冲突）。
  String _newGroupId() {
    final String base = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    String id = 'g$base';
    while (_layout.groups.any((BookGroup group) => group.id == id)) {
      _idSeq++;
      id = 'g${base}_$_idSeq';
    }
    return id;
  }

  /// 把 [bookIds] 从各分组摘出（[exceptId] 指定的那个跳过）。
  static List<BookGroup> _stripFromGroups(
    List<BookGroup> groups,
    Set<String> bookIds, {
    String? exceptId,
  }) {
    if (bookIds.isEmpty) {
      return List<BookGroup>.of(groups);
    }
    return <BookGroup>[
      for (final BookGroup group in groups)
        if (group.id == exceptId)
          group
        else
          group.copyWith(
            bookIds: group.bookIds
                .where((String id) => !bookIds.contains(id))
                .toList(),
          ),
    ];
  }

  /// 两个字符串列表是否逐项相等。
  static bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 两组分组是否逐项相等（含各自成员顺序）。
  static bool _sameGroups(List<BookGroup> a, List<BookGroup> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].name != b[i].name) return false;
      if (!_sameStringList(a[i].bookIds, b[i].bookIds)) return false;
    }
    return true;
  }

  /// 更新内存状态 → 通知监听者 → 原子落盘。
  Future<void> _update(ShelfLayout next) async {
    _layout = next;
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
