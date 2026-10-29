// §10.2 四步 / `SYNC-02` 验收①②③：「取更新」冲突判定单测。
//
// 纯 `test()`、零 IO——`conflict.dart` 是纯函数，不碰网络与磁盘。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/reader/reading_progress.dart';
import 'package:mreader/sync/conflict.dart';

ReadingProgress _p({
  String bookId = 'b1',
  String chapterHref = 'c#3',
  int chapterIndex = 3,
  double chapterPos = 0.5,
  int updatedAt = 1700000000000,
}) =>
    ReadingProgress(
      bookId: bookId,
      chapterHref: chapterHref,
      chapterIndex: chapterIndex,
      chapterPos: chapterPos,
      updatedAt: updatedAt,
    );

/// 2015-10-21 07:28:00 GMT（远端文件常用的参考 mtime）。
final DateTime _remoteTime = DateTime.utc(2015, 10, 21, 7, 28);

void main() {
  group('① 时间闸门 isRemoteStale（远端 mtime <= 本地同步时间 → 跳过）', () {
    test('远端 mtime 早于本地同步时间 → 陈旧（验收③）', () {
      expect(
        isRemoteStale(
          remoteModified: _remoteTime,
          localSyncedAt: _remoteTime.millisecondsSinceEpoch + 1,
        ),
        isTrue,
      );
    });

    test('远端 mtime 与本地同步时间相同 → 陈旧（<= 含等于，F7 口径）', () {
      expect(
        isRemoteStale(
          remoteModified: _remoteTime,
          localSyncedAt: _remoteTime.millisecondsSinceEpoch,
        ),
        isTrue,
      );
    });

    test('远端 mtime 晚于本地同步时间 → 放行', () {
      expect(
        isRemoteStale(
          remoteModified: _remoteTime,
          localSyncedAt: _remoteTime.millisecondsSinceEpoch - 1,
        ),
        isFalse,
      );
    });

    test('远端 mtime 缺失（服务器未返回）→ 放行，交给位置比较防丢', () {
      expect(
        isRemoteStale(remoteModified: null, localSyncedAt: 0),
        isFalse,
      );
    });
  });

  group('步骤① 串联：远端更旧时直接跳过，哪怕位置更靠后', () {
    test('远端 mtime 早于同步时间 → skipRemote（即使远端索引更大）', () {
      final ConflictDecision decision = resolveProgressConflict(
        local: _p(chapterIndex: 2, chapterPos: 0.1),
        remote: _p(chapterIndex: 9, chapterPos: 0.9),
        remoteModified: _remoteTime,
        localSyncedAt: _remoteTime.millisecondsSinceEpoch + 1000,
      );
      expect(decision, ConflictDecision.skipRemote);
    });

    test('mTime 缺失时不否决 → 落到位置比较，远端更大 → takeRemote', () {
      final ConflictDecision decision = resolveProgressConflict(
        local: _p(chapterIndex: 2),
        remote: _p(chapterIndex: 9),
        remoteModified: null,
        localSyncedAt: DateTime.now().millisecondsSinceEpoch,
      );
      expect(decision, ConflictDecision.takeRemote);
    });
  });

  group('步骤② 章节索引：更大者胜', () {
    test('远端索引更大 → takeRemote（验收①「后读覆盖先读」）', () {
      expect(
        resolveProgressConflict(
          local: _p(chapterIndex: 3, chapterPos: 0.9),
          remote: _p(chapterIndex: 5, chapterPos: 0.0),
          remoteModified: _remoteTime,
          localSyncedAt: 0,
        ),
        ConflictDecision.takeRemote,
      );
    });

    test('本地索引更大 → keepLocal（验收②「不被远端回退」）', () {
      expect(
        resolveProgressConflict(
          local: _p(chapterIndex: 8),
          remote: _p(chapterIndex: 5),
          remoteModified: _remoteTime,
          localSyncedAt: 0,
        ),
        ConflictDecision.keepLocal,
      );
    });
  });

  group('步骤③ 索引相同 → 比章内位置', () {
    test('远端章内位置更靠后 → takeRemote', () {
      expect(
        resolveProgressConflict(
          local: _p(chapterPos: 0.25),
          remote: _p(chapterPos: 0.75),
          remoteModified: _remoteTime,
          localSyncedAt: 0,
        ),
        ConflictDecision.takeRemote,
      );
    });

    test('本地章内位置更靠后 → keepLocal', () {
      expect(
        resolveProgressConflict(
          local: _p(chapterPos: 0.75),
          remote: _p(chapterPos: 0.25),
          remoteModified: _remoteTime,
          localSyncedAt: 0,
        ),
        ConflictDecision.keepLocal,
      );
    });

    test('位置差在容差内 → 视作相同 → identical', () {
      expect(
        resolveProgressConflict(
          local: _p(chapterPos: 0.5),
          remote: _p(chapterPos: 0.5 + 1e-9),
          remoteModified: _remoteTime,
          localSyncedAt: 0,
        ),
        ConflictDecision.identical,
      );
    });
  });

  group('步骤④ 完全相同 → identical（不写入，仅更新时间戳）', () {
    test('语义字段全同 → identical（updatedAt 不参与判定）', () {
      expect(
        resolveProgressConflict(
          local: _p(updatedAt: 1700000000000),
          remote: _p(updatedAt: 1600000000000),
          remoteModified: _remoteTime,
          localSyncedAt: 0,
        ),
        ConflictDecision.identical,
      );
    });
  });
}
