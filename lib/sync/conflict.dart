// 阅读进度同步的冲突判定（`SYNC-02` / PRD §10.2「取更新」）。
//
// **纯函数、零 IO**——只做判定，落盘与传输由 `progress_sync.dart` 执行。
//
// 判定顺序必须按 §10.2，不可简化：① 远端文件修改时间 <= 本地同步时间 → 直接
// 跳过（验收③）；② 比较章节索引，更大者胜；③ 索引相同比较章内位置，更靠后
// 者胜；④ 完全相同不写入，仅更新时间戳。
//
// 设计理由（§10.2）：单纯比时间戳会在「设备时钟不准」时丢失进度；纯比位置
// 又无法处理「回退重读」。两者串联才既能防丢、又能防回退覆盖。
import '../reader/reading_progress.dart';

/// 冲突判定结果（§10.2 四步的输出）。
enum ConflictDecision {
  /// ① 远端 mtime <= 本地同步时间 → 远端不比上次同步新，直接跳过。
  skipRemote,

  /// ②③ 远端位置更靠后 → 覆盖本地（`SYNC-02` 验收①「后读覆盖先读」）。
  takeRemote,

  /// ②③ 本地位置更靠后 → 保留本地，不被远端回退（验收②）。
  keepLocal,

  /// ④ 语义完全相同 → 不写入，仅更新时间戳。
  identical,
}

/// 步骤① 闸门：远端文件修改时间是否**不晚于**本地同步时间（旧 / 齐平即跳过）。
/// [remoteModified] 为 `null`（未返回 / 解析失败）时**放行**（返 `false`）——
/// 拿不到时间戳就不做时间否决，交给位置比较防丢。
bool isRemoteStale({
  required DateTime? remoteModified,
  required int localSyncedAt,
}) {
  if (remoteModified == null) {
    return false;
  }
  return remoteModified.toUtc().millisecondsSinceEpoch <= localSyncedAt;
}

/// 「取更新」完整判定（§10.2 四步，按序执行）。
/// - [local] / [remote]：本地 / 远端进度（调用方保证均非空——单侧缺失由
///   引擎直接走「下载 / 上传」，不构成冲突）；
/// - [remoteModified]：远端文件修改时间（可为 `null`）；[localSyncedAt]：
///   本地**上次同步时间**（Unix 毫秒，从未同步为 0）。
ConflictDecision resolveProgressConflict({
  required ReadingProgress local,
  required ReadingProgress remote,
  required DateTime? remoteModified,
  required int localSyncedAt,
}) {
  // ① 时间闸门。
  if (isRemoteStale(
    remoteModified: remoteModified,
    localSyncedAt: localSyncedAt,
  )) {
    return ConflictDecision.skipRemote;
  }

  // ② 章节索引：更大者胜。
  if (remote.chapterIndex != local.chapterIndex) {
    return remote.chapterIndex > local.chapterIndex
        ? ConflictDecision.takeRemote
        : ConflictDecision.keepLocal;
  }

  // ③ 索引相同 → 章内位置：更靠后者胜（容差同 `ReadingProgress.hasSameSemantics`）。
  final double diff = remote.chapterPos - local.chapterPos;
  if (diff > 1e-6) {
    return ConflictDecision.takeRemote;
  }
  if (diff < -1e-6) {
    return ConflictDecision.keepLocal;
  }

  // ④ 完全相同。
  return ConflictDecision.identical;
}
