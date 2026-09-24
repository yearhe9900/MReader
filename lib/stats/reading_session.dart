// `M2b-T08`：阅读会话采集内核（`STAT-01` / `STAT-02`）——**纯 Dart 数据层**，
// 不 import Flutter / dart:io，可在 isolate 与单测中直接使用。落盘在
// `session_store.dart`（JSON 按月分片 + 原子写入，`DATA-01`）。
//
// 模型字段 ↔ PRD `STAT-02` 明细字段（沿用工程 camelCase JSON 惯例，同 `RD-04`）：
//   id        ↔ `id`（稳定唯一；由 `bookId + startedAt` **确定性派生**，
//                故同一批记录反复合并天然幂等，`STAT-08`）
//   bookId    ↔ `book_id`；dayKey ↔ `day_key`（`YYYY-MM-DD`，**本地时区**，专用于聚合）
//   startedAt ↔ `started_at`（毫秒，专用于排序与「最近阅读时刻」）
//   duration  ↔ `duration`（**秒**，有效阅读时长；**禁止 ≤ 0 的记录**落盘）
//   endedAt   —— 结束时间戳（毫秒，任务书要求）
//   start/end —— 起止语义坐标 (chapterHref, chapterPos)（对齐 `RD-04` 进度语义，
//                任务书要求；跨 0 点拆天时按「边界前最后一次活跃事件」的坐标取值，
//                拆分接缝两侧坐标一致，不虚构边界处的未知位置）。
//
// 会话切分口径（任务书 + `STAT-01`）：
//   · **活跃事件驱动**：`noteActivity` 记录交互（进入阅读页时调用一次即起表）；
//   · 相邻活跃**空闲超过 [sessionIdleTimeoutMs]（3 分钟，`Q12`）即切会话**——
//     前段只计到「最后活跃 + 3 分钟」（空闲宽限），后段自新活跃重新起算；
//   · 单段内空闲 ≤ 3 分钟**照常计时**（`STAT-01`：连续 N 分钟无交互才暂停计时）；
//     故段内有效时长连续 = `endedAt - startedAt`；
//   · 退出阅读页 / 切后台 = `finish` 收尾（`STAT-01`：停止计时并落库；
//     翻页**不**触发写库）；不带收尾时刻时按「最后活跃 + 3 分钟宽限」收口；
//   · **跨 0 点的会话按实际秒数拆成两条**，两条各有自己的 `dayKey`（`STAT-02` ①）。
//
// 口径说明（最保守处置，见回报）：`STAT-01` ③「恢复交互后继续累计」在本实现里
// 落为**切会话后新会话继续累计**（任务书明文「空闲超过 3 分钟即切会话」优先）——
// 总时长 / 按天归属 / 按书归属与「同会话暂停续计」完全一致，仅明细条数不同。
// 另：时长按**整秒向下取整**（不虚报），拆天两段各自取整，合计可能比整段少
// 不足 2 秒（`STAT-01` ①「误差 ≤ 5s」容差内）。

/// 空闲超时（毫秒）：连续 3 分钟无活跃即切会话 / 暂停计时（`STAT-01` N=3，`Q12`）。
const int sessionIdleTimeoutMs = 3 * 60 * 1000;

/// 会话记录的 `day_key`（`YYYY-MM-DD`，**本地时区**，`STAT-02`）。
String sessionDayKey(int timestampMs) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 会话起止语义坐标（`chapterHref` = 章节稳定身份 + `chapterPos` = 章内 0~1）。
class SessionPosition {
  SessionPosition({required this.chapterHref, required double chapterPos})
      : chapterPos = chapterPos.clamp(0.0, 1.0).toDouble();

  /// 章内稳定身份（`Chapter.href`，同 `RD-04`）。
  final String chapterHref;

  /// 章内进度 `0.0 ~ 1.0`（构造时自动 clamp）。
  final double chapterPos;

  Map<String, Object?> toJson() => <String, Object?>{
        'chapterHref': chapterHref,
        'chapterPos': chapterPos,
      };

  /// 防御式反序列化：非 `Map` / 字段缺失或类型不对 → `null`。
  static SessionPosition? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? chapterHref = json['chapterHref'];
    final Object? chapterPos = json['chapterPos'];
    if (chapterHref is! String || chapterPos is! num) {
      return null;
    }
    return SessionPosition(
      chapterHref: chapterHref,
      chapterPos: chapterPos.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionPosition &&
          runtimeType == other.runtimeType &&
          chapterHref == other.chapterHref &&
          chapterPos == other.chapterPos;

  @override
  int get hashCode => Object.hash(chapterHref, chapterPos);

  @override
  String toString() =>
      'SessionPosition($chapterHref, ${chapterPos.toStringAsFixed(3)})';
}

/// 一条会话明细记录（不可变；`STAT-02` 落盘粒度 = **按天拆分后**的记录）。
class ReadingSession {
  ReadingSession({
    required this.id,
    required this.bookId,
    required this.dayKey,
    required this.startedAt,
    required this.endedAt,
    required this.duration,
    required this.start,
    required this.end,
  });

  /// 稳定唯一 id：`<startedAt 毫秒>_<bookId>`（确定性派生，并集合并幂等）。
  ///
  /// 故意**不含** `endedAt` / `duration`：同一逻辑会话在两台设备上收尾时刻略异时
  /// 仍应视为同一 id（`STAT-08`「同 id 取较大时长」），否则同步会双计。
  static String makeId(String bookId, int startedAtMs) => '${startedAtMs}_$bookId';

  /// 稳定唯一 id。
  final String id;

  /// 归属书籍（`BookRecord.bookId`）。
  final String bookId;

  /// 归属天（`YYYY-MM-DD`，本地时区；**跨 0 点拆天后每条各归各天**）。
  final String dayKey;

  /// 开始时间戳（Unix 毫秒）。
  final int startedAt;

  /// 结束时间戳（Unix 毫秒）；采集器产出的记录满足
  /// `duration == (endedAt - startedAt) ~/ 1000`。
  final int endedAt;

  /// **有效阅读时长（秒）**——已扣除超过 3 分钟的空闲（`STAT-01`）。
  /// 落盘**禁止 ≤ 0**（`STAT-02` ②）。
  final int duration;

  /// 起点语义坐标。
  final SessionPosition start;

  /// 终点语义坐标。
  final SessionPosition end;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'bookId': bookId,
        'dayKey': dayKey,
        'startedAt': startedAt,
        'endedAt': endedAt,
        'duration': duration,
        'start': start.toJson(),
        'end': end.toJson(),
      };

  /// 防御式反序列化：非 `Map` / 必填字段缺失或类型错误 → `null`（坏条目静默跳过）。
  static ReadingSession? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? bookId = json['bookId'];
    final Object? dayKey = json['dayKey'];
    final Object? startedAt = json['startedAt'];
    final Object? endedAt = json['endedAt'];
    final Object? duration = json['duration'];
    if (id is! String ||
        bookId is! String ||
        dayKey is! String ||
        startedAt is! num ||
        endedAt is! num ||
        duration is! num) {
      return null;
    }
    final SessionPosition? start = SessionPosition.fromJson(json['start']);
    final SessionPosition? end = SessionPosition.fromJson(json['end']);
    if (start == null || end == null) {
      return null;
    }
    return ReadingSession(
      id: id,
      bookId: bookId,
      dayKey: dayKey,
      startedAt: startedAt.toInt(),
      endedAt: endedAt.toInt(),
      duration: duration.toInt(),
      start: start,
      end: end,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReadingSession &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          bookId == other.bookId &&
          dayKey == other.dayKey &&
          startedAt == other.startedAt &&
          endedAt == other.endedAt &&
          duration == other.duration &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(
        id,
        bookId,
        dayKey,
        startedAt,
        endedAt,
        duration,
        start,
        end,
      );

  @override
  String toString() => 'ReadingSession($id, $bookId, $dayKey, '
      '$startedAt~$endedAt, ${duration}s)';
}

/// 一次活跃事件（翻页 / 滚动 / 点按 / 进入阅读页……任一交互）。
class ReadingActivity {
  const ReadingActivity({required this.at, required this.position});

  /// 事件时刻（Unix 毫秒）。
  final int at;

  /// 事件时刻的阅读位置。
  final SessionPosition position;
}

/// 活跃事件驱动的会话采集器（`STAT-01`；纯 Dart，无计时器 / 无 IO——
/// 时刻由调用方注入，故可确定性单测）。
///
/// 用法：进入阅读页后每次交互 `noteActivity` 一次；退出阅读页 / 切后台 /
/// 会话需落库时 `finish`，拿回**已按 0 点拆天、已剔除 `duration <= 0`** 的记录。
class SessionTracker {
  SessionTracker({required this.bookId, this.idleLimitMs = sessionIdleTimeoutMs});

  /// 归属书籍。
  final String bookId;

  /// 空闲超时（毫秒）：超过即切会话 / 停止计时（默认 3 分钟）。
  final int idleLimitMs;

  final List<ReadingActivity> _activities = <ReadingActivity>[];

  /// 记录一次活跃事件（[at] 为 Unix 毫秒）。
  void noteActivity({
    required int at,
    required String chapterHref,
    required double chapterPos,
  }) {
    _activities.add(ReadingActivity(
      at: at,
      position: SessionPosition(chapterHref: chapterHref, chapterPos: chapterPos),
    ));
  }

  /// 收尾并产出会话记录（幂等读取：不清空已采集事件，可重复调用结果一致）。
  ///
  /// [at]   —— 收尾时刻（退出阅读页 / 切后台的时刻）；缺省按
  ///           「最后活跃 + [idleLimitMs] 宽限」收口（`STAT-01` ②）。
  /// [chapterHref] / [chapterPos] —— 收尾时的阅读位置（可选；只影响末条记录
  ///           的终点坐标，缺省取边界前最后一次活跃事件的坐标）。
  ///
  /// 产出规则：空闲 > [idleLimitMs] 切会话（前段只计到最后活跃 + 宽限）；
  /// 跨本地 0 点按实际秒数拆成多条；`duration <= 0` 的条目**不产出**（`STAT-02` ②）。
  List<ReadingSession> finish({
    int? at,
    String? chapterHref,
    double? chapterPos,
  }) {
    // 事件乱序时防御性排序（正常调用天然递增）。
    final List<ReadingActivity> events = List<ReadingActivity>.of(_activities)
      ..sort((ReadingActivity a, ReadingActivity b) => a.at.compareTo(b.at));
    if (events.isEmpty) {
      return <ReadingSession>[];
    }
    final SessionPosition? closePos = chapterHref == null
        ? null
        : SessionPosition(chapterHref: chapterHref, chapterPos: chapterPos ?? 0.0);

    final List<ReadingSession> out = <ReadingSession>[];
    int segStart = 0;
    for (int i = 1; i <= events.length; i++) {
      // 空闲**超过** idleLimitMs 才切（等于不切，「超过 3 分钟」口径）。
      final bool idleSplit =
          i < events.length && events[i].at - events[i - 1].at > idleLimitMs;
      if (i < events.length && !idleSplit) {
        continue;
      }
      final bool isLast = i == events.length;
      final int endMs = _segmentEnd(
        events,
        segStart,
        i - 1,
        isLast ? at : null,
      );
      out.addAll(_emit(
        events,
        segStart,
        i - 1,
        endMs,
        isLast ? closePos : null,
      ));
      segStart = i;
    }
    return out;
  }

  /// 一段连续有效阅读的收尾时刻：
  /// `min(收尾时刻, 最后活跃 + 空闲宽限)`，且**不早于最后活跃**。
  /// 被空闲切分的段没有收尾时刻 → 只计「最后活跃 + 宽限」。
  int _segmentEnd(
    List<ReadingActivity> events,
    int from,
    int to,
    int? closeAt,
  ) {
    final int lastAt = events[to].at;
    final int capped = lastAt + idleLimitMs;
    int end = (closeAt != null && closeAt < capped) ? closeAt : capped;
    return end < lastAt ? lastAt : end;
  }

  /// 把一段 `[events[from].at, endMs]`（段内连续有效阅读）按本地 0 点拆成记录。
  List<ReadingSession> _emit(
    List<ReadingActivity> events,
    int from,
    int to,
    int endMs,
    SessionPosition? closePos,
  ) {
    final int startMs = events[from].at;
    if (endMs < startMs) {
      return <ReadingSession>[];
    }
    final List<int> bounds = <int>[
      startMs,
      ..._midnightsBetween(startMs, endMs),
      endMs,
    ];
    final List<ReadingSession> out = <ReadingSession>[];
    for (int k = 0; k + 1 < bounds.length; k++) {
      // 整秒向下取整（不虚报）；`duration <= 0` 禁止落盘（`STAT-02` ②）。
      final int seconds = (bounds[k + 1] - bounds[k]) ~/ 1000;
      if (seconds <= 0) {
        continue;
      }
      final bool lastPiece = k + 2 == bounds.length;
      out.add(ReadingSession(
        id: ReadingSession.makeId(bookId, bounds[k]),
        bookId: bookId,
        dayKey: sessionDayKey(bounds[k]),
        startedAt: bounds[k],
        endedAt: bounds[k + 1],
        duration: seconds,
        start: _positionAt(events, from, to, bounds[k]),
        end: (lastPiece && closePos != null)
            ? closePos
            : _positionAt(events, from, to, bounds[k + 1]),
      ));
    }
    return out;
  }

  /// 边界时刻处的语义坐标 = **边界前最后一次活跃事件**的坐标（接缝两侧一致；
  /// 段首边界即首事件，恒有取值）。
  SessionPosition _positionAt(
    List<ReadingActivity> events,
    int from,
    int to,
    int boundaryMs,
  ) {
    SessionPosition pos = events[from].position;
    for (int i = from; i <= to; i++) {
      if (events[i].at > boundaryMs) {
        break;
      }
      pos = events[i].position;
    }
    return pos;
  }

  /// `(startMs, endMs)` 开区间内的所有本地 0 点时刻（毫秒）。
  List<int> _midnightsBetween(int startMs, int endMs) {
    final List<int> out = <int>[];
    final DateTime start = DateTime.fromMillisecondsSinceEpoch(startMs);
    DateTime midnight = DateTime(start.year, start.month, start.day + 1);
    while (midnight.millisecondsSinceEpoch < endMs) {
      final int ms = midnight.millisecondsSinceEpoch;
      if (ms > startMs) {
        out.add(ms);
      }
      midnight = DateTime(midnight.year, midnight.month, midnight.day + 1);
    }
    return out;
  }
}

/// 聚合结果：`day_key` 与 `book_id` 两组内存索引（`STAT-02`；单遍扫描，
/// 杜绝「函数包裹列」式失效聚合，`Q11`）。
class StatsIndex {
  /// 单遍扫描 [sessions] 建索引；`duration <= 0` 的记录跳过（禁写口径同源）。
  factory StatsIndex.of(Iterable<ReadingSession> sessions) {
    final Map<String, int> byDay = <String, int>{};
    final Map<String, int> byBook = <String, int>{};
    int total = 0;
    for (final ReadingSession s in sessions) {
      if (s.duration <= 0) {
        continue;
      }
      byDay.update(s.dayKey, (int v) => v + s.duration, ifAbsent: () => s.duration);
      byBook.update(s.bookId, (int v) => v + s.duration, ifAbsent: () => s.duration);
      total += s.duration;
    }
    return StatsIndex._(byDay, byBook, total);
  }

  const StatsIndex._(this.secondsByDay, this.secondsByBook, this.totalSeconds);

  /// 按天汇总的**有效阅读秒数**（键 = `day_key`）。
  final Map<String, int> secondsByDay;

  /// 按书汇总的**有效阅读秒数**（键 = `bookId`）。
  final Map<String, int> secondsByBook;

  /// 全部记录的有效阅读秒数合计。
  final int totalSeconds;
}
