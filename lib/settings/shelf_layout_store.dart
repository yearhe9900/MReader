// 书架**布局**持久化（手动排序顺序 + 文件夹归属）——L3 拖拽交互的真值。
//
// 与 [ShelfPrefsStore] **同一形制**，勿另创写法：
//   · 落盘一律经 `JsonStore` → `AtomicFile`（`DATA-01` 原子写入）；
//   · 跨页面共享用「进程内共享实例 + 监听回调」，页面 `initState` 订阅、
//     `dispose` 退订、回调内 `setState`（**不引入 Provider / Riverpod**）；
//   · **不使用可变全局单例**：实例在 `main()` 显式创建并构造注入。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么是**独立文件**，而不是给 `BookRecord` 加字段（2026-09-28 拍板）
// ══════════════════════════════════════════════════════════════════════════════
// 1. `BookRecord` 是**书目元数据**（书名 / 作者 / 封面 / 导入时间…），由
//    `BookIndex` 统一落在 `index.json`；拖拽顺序与文件夹归属是**列表视图布局**，
//    语义正交。混进 `BookRecord` 会让每次拖拽都要把整份 `index.json`
//    （含全部元数据）重写一遍。
// 2. **零旧索引兼容成本**：不动 `BookRecord` 的序列化，就不存在
//    「旧 `index.json` 缺新字段」的迁移问题（这是拍板时明确要规避的风险）。
// 3. 与 [ShelfPrefsStore] 同一生命周期（都是书架的视图状态），但**仍分文件**：
//    改一次筛选不该连带重写布局数据。
//
// ⚠️ **孤儿引用**：书目被删（`LibraryRepository.deleteBook`）后，本文件里可能
// 残留其 `bookId`。处置是**两道**——渲染期按当前书目过滤（见 `shelf_page`
// 的 `_visibleBooks` / `_liveFolders`），加上删书后显式 [ShelfLayoutStore.prune]
// 落盘清理。**不假设两者总是一致**。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';

/// 一个书架文件夹。
///
/// [bookIds] 的**顺序即文件夹内的展示顺序**（文件夹内拖拽重排直接改写它）。
class BookFolder {
  /// 创建文件夹。
  const BookFolder({
    required this.id,
    required this.name,
    this.bookIds = const <String>[],
  });

  /// 文件夹 id（由 [ShelfLayoutStore] 生成，全局唯一）。
  final String id;

  /// 显示名。
  final String name;

  /// 归属书目（有序）。
  final List<String> bookIds;

  /// 复制并覆盖部分字段。
  BookFolder copyWith({String? name, List<String>? bookIds}) => BookFolder(
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
  static BookFolder? fromJson(Object? json) {
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
    return BookFolder(
      id: rawId,
      name: rawName is String && rawName.isNotEmpty ? rawName : '未命名文件夹',
      bookIds: bookIds,
    );
  }
}

/// 书架布局的值对象（不可变）。
class ShelfLayout {
  /// 创建布局。
  const ShelfLayout({
    this.order = const <String>[],
    this.folders = const <BookFolder>[],
  });

  /// 手动顺序下 bookId 的显式次序。
  ///
  /// **不在本列表中的书**由渲染方自行兜底（见 `shelf_page`：按导入时间降序追加），
  /// 因此本列表**允许不完整**——新导入的书不必立刻改写这里。
  final List<String> order;

  /// 文件夹（顺序即书架上的展示顺序）。
  final List<BookFolder> folders;

  /// 是否空布局（无顺序、无文件夹）。
  bool get isEmpty => order.isEmpty && folders.isEmpty;

  /// 已归属任一文件夹的 bookId 集合。
  Set<String> get folderedBookIds => <String>{
        for (final BookFolder folder in folders) ...folder.bookIds,
      };

  /// 某书所属的文件夹；不属于任何文件夹时返回 `null`。
  ///
  /// 归属**唯一**：写入侧（[ShelfLayoutStore.addToFolder]）保证一本书不会
  /// 同时出现在两个文件夹里，这里按「先命中先返回」读取。
  BookFolder? folderOf(String bookId) {
    for (final BookFolder folder in folders) {
      if (folder.bookIds.contains(bookId)) {
        return folder;
      }
    }
    return null;
  }

  /// 复制并覆盖部分字段。
  ShelfLayout copyWith({List<String>? order, List<BookFolder>? folders}) =>
      ShelfLayout(
        order: order ?? this.order,
        folders: folders ?? this.folders,
      );

  /// 序列化。
  Map<String, Object?> toJson() => <String, Object?>{
        'order': order,
        'folders': folders
            .map((BookFolder folder) => folder.toJson())
            .toList(growable: false),
      };

  /// 由持久化 JSON 还原；顶层类型异常时整体回退空布局。
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
    final List<BookFolder> folders = <BookFolder>[];
    final Object? rawFolders = json['folders'];
    if (rawFolders is List) {
      for (final Object? item in rawFolders) {
        final BookFolder? folder = BookFolder.fromJson(item);
        if (folder != null) {
          folders.add(folder);
        }
      }
    }
    return ShelfLayout(order: order, folders: folders);
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

  /// 文件夹 id 的防撞计数（同一微秒内连续建文件夹时兜底）。
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

  /// 写入显式顺序（散书区拖拽重排的结果）。
  Future<void> setOrder(List<String> bookIds) =>
      _update(_layout.copyWith(order: List<String>.of(bookIds)));

  /// 新建文件夹并收进 [bookIds]，返回新文件夹 id。
  ///
  /// 收进来的书会**先**从原有文件夹摘出（保证归属唯一）。
  Future<String> createFolder({
    required String name,
    required List<String> bookIds,
  }) async {
    final String id = _newFolderId();
    final List<BookFolder> folders = _stripFromFolders(
      _layout.folders,
      bookIds.toSet(),
    );
    folders.add(
      BookFolder(
        id: id,
        name: name,
        bookIds: List<String>.of(bookIds),
      ),
    );
    await _update(_layout.copyWith(folders: folders));
    return id;
  }

  /// 重命名文件夹（空名或纯空白被拒绝，保持原名）。
  Future<void> renameFolder(String folderId, String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return Future<void>.value();
    }
    return _update(
      _layout.copyWith(
        folders: <BookFolder>[
          for (final BookFolder folder in _layout.folders)
            if (folder.id == folderId)
              folder.copyWith(name: trimmed)
            else
              folder,
        ],
      ),
    );
  }

  /// 把 [bookIds] 加入指定文件夹（追加到末尾；已在此文件夹则不动）。
  ///
  /// 这些书会**先**从其它文件夹摘出——一本书同时只属于一个文件夹。
  Future<void> addToFolder(String folderId, List<String> bookIds) {
    final int index =
        _layout.folders.indexWhere((BookFolder f) => f.id == folderId);
    if (index < 0) {
      return Future<void>.value();
    }
    final Set<String> incoming = bookIds.toSet();
    final List<BookFolder> folders =
        _stripFromFolders(_layout.folders, incoming, exceptId: folderId);
    final BookFolder target = folders[index];
    final List<String> merged = <String>[
      ...target.bookIds,
      for (final String id in bookIds)
        if (!target.bookIds.contains(id)) id,
    ];
    folders[index] = target.copyWith(bookIds: merged);
    return _update(_layout.copyWith(folders: folders));
  }

  /// 把 [bookIds] 移出所属文件夹（回到散书区）。
  Future<void> removeFromFolder(String folderId, List<String> bookIds) {
    final Set<String> removing = bookIds.toSet();
    return _update(
      _layout.copyWith(
        folders: <BookFolder>[
          for (final BookFolder folder in _layout.folders)
            if (folder.id == folderId)
              folder.copyWith(
                bookIds: folder.bookIds
                    .where((String id) => !removing.contains(id))
                    .toList(),
              )
            else
              folder,
        ],
      ),
    );
  }

  /// 改写文件夹内部的展示顺序（文件夹内拖拽重排的结果）。
  ///
  /// [bookIds] 提供**完整**的目标顺序；与现有成员集合不一致时以传入者为准
  /// （仅保留确实属于该文件夹的 id，防止误插）。
  Future<void> setFolderOrder(String folderId, List<String> bookIds) {
    final int index =
        _layout.folders.indexWhere((BookFolder f) => f.id == folderId);
    if (index < 0) {
      return Future<void>.value();
    }
    final Set<String> members = _layout.folders[index].bookIds.toSet();
    final List<String> next = <String>[
      for (final String id in bookIds)
        if (members.contains(id)) id,
    ];
    final List<BookFolder> folders = List<BookFolder>.of(_layout.folders);
    folders[index] = folders[index].copyWith(bookIds: next);
    return _update(_layout.copyWith(folders: folders));
  }

  /// 解散文件夹（书本回到散书区，顺序不变）。
  Future<void> dissolveFolder(String folderId) {
    if (!_layout.folders.any((BookFolder f) => f.id == folderId)) {
      return Future<void>.value();
    }
    return _update(
      _layout.copyWith(
        folders: _layout.folders
            .where((BookFolder f) => f.id != folderId)
            .toList(growable: false),
      ),
    );
  }

  /// 清理孤儿引用（书目已从书架删除）。
  ///
  /// 顺带清掉**变空的文件夹**——书都删光了，空壳没有存在意义。
  /// 无实际变化时**不写盘**（避免每次启动都白写一次）。
  Future<void> prune(Set<String> validBookIds) async {
    final List<String> order = _layout.order
        .where((String id) => validBookIds.contains(id))
        .toList();
    final List<BookFolder> folders = <BookFolder>[];
    for (final BookFolder folder in _layout.folders) {
      final List<String> kept = folder.bookIds
          .where((String id) => validBookIds.contains(id))
          .toList();
      if (kept.isNotEmpty) {
        folders.add(folder.copyWith(bookIds: kept));
      }
    }
    if (_sameStringList(order, _layout.order) &&
        _sameFolders(folders, _layout.folders)) {
      return;
    }
    await _update(_layout.copyWith(order: order, folders: folders));
  }

  /// 订阅布局变更。
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 退订布局变更。
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// 生成不冲突的文件夹 id。
  ///
  /// 用「微秒时间戳转 36 进制」而非 `Random`：可读、单调、无需额外依赖；
  /// 同一微秒内重复调用时由 [_idSeq] 兜底加后缀。
  String _newFolderId() {
    final String base = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    String id = 'f$base';
    while (_layout.folders.any((BookFolder folder) => folder.id == id)) {
      _idSeq++;
      id = 'f${base}_$_idSeq';
    }
    return id;
  }

  /// 把 [bookIds] 从各文件夹摘出（[exceptId] 指定的那个跳过）。
  static List<BookFolder> _stripFromFolders(
    List<BookFolder> folders,
    Set<String> bookIds, {
    String? exceptId,
  }) {
    if (bookIds.isEmpty) {
      return List<BookFolder>.of(folders);
    }
    return <BookFolder>[
      for (final BookFolder folder in folders)
        if (folder.id == exceptId)
          folder
        else
          folder.copyWith(
            bookIds: folder.bookIds
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

  /// 两组文件夹是否逐项相等（含各自成员顺序）。
  static bool _sameFolders(List<BookFolder> a, List<BookFolder> b) {
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
