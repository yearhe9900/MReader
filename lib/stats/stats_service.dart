// 统计服务（`STAT-03` 的数据侧——进程内唯一实例 + 监听回调）。
//
// 职责：载入 / 刷新会话明细（经 [SessionStore]，`STAT-02` 分片存储唯一入口）；
// [ingest] 回吐会话（关书 / 切后台 → 合并落库 + 刷新 + 通知，`STAT-01` 的
// **唯一写入入口**，采集侧只管 `finish` 不碰存储）；持有「起始日期」配置
// （`STAT-03` ③，落 `stats/stats-config.json`——与会话分片**分文件**，改起始
// 日期不重写会话分片）；暴露 [overview] 与 [sessions]（供周期聚合复用）；
// [clearAll] 清空统计（`STAT-03` ④：只删会话分片，书架 / 进度 / 书签 / 笔记
// 与起始日期配置一概不动）。
//
// 跨页面共享用**监听回调**（`void Function()` 列表），UI 配 `StatefulWidget +
// setState`（§15.5 禁 Riverpod / Provider）；「进程内单例」= 组合根（`main.dart`）
// 创建唯一实例经 `HomeShell` 注入——不加静态全局，与其它存储注入纪律一致。
//
// 本文件属 `lib/stats/`：纯 Dart（零 Flutter 插件，`STAT-02` ⑤）。
import 'dart:io';

import '../platform/app_paths.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'aggregator.dart';
import 'reading_session.dart';
import 'session_store.dart';

/// 统计服务。
class StatsService {
  /// [paths] 为应用数据根（与 `SessionStore` 同源）。
  StatsService(AppPaths paths)
      : _paths = paths,
        _store = SessionStore(paths);

  final AppPaths _paths;
  final SessionStore _store;

  /// 起始日期配置文件名（`<dataDir>/stats/stats-config.json`）。
  static const String configFile = 'stats-config.json';

  final List<void Function()> _listeners = <void Function()>[];

  List<ReadingSession> _sessions = const <ReadingSession>[];
  String? _sinceDay;
  bool _loaded = false;

  /// 是否已完成首次载入（页面据此在转圈与内容间二选一）。
  bool get isLoaded => _loaded;

  /// 全部会话明细（起始日期**不过滤**；T11~T13 的周期聚合自行按需过滤）。
  List<ReadingSession> get sessions => _sessions;

  /// 起始日期（`YYYY-MM-DD`，本地时区）；`null` = 不限（统计全部）。
  String? get sinceDay => _sinceDay;

  /// 总览三指标（起始日期过滤 + `duration > 0`，`STAT-03`）。
  OverviewStats get overview =>
      aggregateOverview(_sessions, sinceDay: _sinceDay);

  /// 注册变更监听（页面 `setState` 用）；重复注册无效化由调用方自律。
  void addListener(void Function() listener) => _listeners.add(listener);

  /// 移除监听（页面 `dispose` 必须调用）。
  void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  void _notify() {
    // 快照遍历：监听器在回调里增删自身不破坏本次通知。
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// 载入（或刷新）全部会话明细 + 起始日期配置；完成即通知；可重复调用
  /// （阅读页退出后回刷统计页即走这里）。
  Future<void> load() async {
    _sessions = await _store.loadAll();
    _sinceDay = await _readSinceDay();
    _loaded = true;
    _notify();
  }

  /// 回吐会话（关书 / 切后台时调用；`STAT-01` 写入的唯一入口）：按 `id` 并集
  /// 合并进月分片（`STAT-08` 幂等，`duration <= 0` 由存储侧丢弃）→ 重载 → 通知。
  /// 尚未 [load] 时先载入（防用空表当真值）；写失败静默（落库失败不影响阅读）。
  Future<void> ingest(Iterable<ReadingSession> sessions) async {
    if (sessions.isEmpty) return;
    if (!_loaded) await load();
    try {
      await _store.merge(sessions);
    } catch (_) {
      return; // 写失败静默：内存保持与磁盘一致的旧数据。
    }
    _sessions = await _store.loadAll();
    _notify();
  }

  /// 设置起始日期（`null` = 不限）；落盘 + 通知。
  Future<void> setSinceDate(DateTime? date) async {
    _sinceDay = date == null ? null : sessionDayKey(date.millisecondsSinceEpoch);
    await _writeSinceDay(_sinceDay);
    _notify();
  }

  /// 清空全部统计数据（`STAT-03` ④）：删会话分片、内存归零、通知；**不动**
  /// 书架 / 进度 / 书签 / 笔记 / 起始日期配置。
  Future<void> clearAll() async {
    await _store.clearAll();
    _sessions = const <ReadingSession>[];
    _notify();
  }

  // ------------------------------------------------------------------
  // 起始日期配置（stats-config.json）
  // ------------------------------------------------------------------

  Future<JsonStore> _configStore() async {
    final Directory dir = await _paths.subDir(SessionStore.dirName);
    return JsonStore(
      AtomicFile('${dir.path}${Platform.pathSeparator}$configFile'),
    );
  }

  Future<String?> _readSinceDay() async {
    try {
      final Object? json = await (await _configStore()).read();
      if (json is Map) {
        final Object? value = json['sinceDay'];
        if (value is String || value == null) {
          return value as String?;
        }
      }
      return null;
    } catch (_) {
      return null; // 配置坏了按「不限」处理（缓存/配置读失败不阻断页面）
    }
  }

  Future<void> _writeSinceDay(String? value) async {
    try {
      await (await _configStore()).write(<String, Object?>{'sinceDay': value});
    } catch (_) {
      // 写失败静默：起始日期是展示口径配置，不值得让页面操作失败。
    }
  }
}
