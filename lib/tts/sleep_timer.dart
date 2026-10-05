import 'dart:async';

/// 定时停止计时器（TTS-05）。
///
/// 只负责「到点回调」——停朗读、持久化设定都在调用方（阅读页）完成：
/// · 分钟数的合法性（10~180、10 步进）由 `TtsSettings.clampSleep` 归一，
///   本类收 `Duration`，测试可直接用秒级短时长（**不引入 fake_async**）；
/// · 计时是进程内的：重启后是否恢复由持久化的 `sleepMinutes` 决定
///   （重启保留的是**设定值**，不恢复剩余时间）。
class SleepTimer {
  /// 创建计时器；[onFire] 在到点时于主 isolate 同步调用。
  SleepTimer({required this.onFire});

  /// 到点回调（阅读页接 `停止朗读`）。
  final void Function() onFire;

  Timer? _timer;
  DateTime? _endsAt;

  /// 是否正在计时。
  bool get isActive => _timer != null;

  /// 剩余时长；未计时返回 [Duration.zero]。
  Duration get remaining {
    final DateTime? endsAt = _endsAt;
    if (endsAt == null) {
      return Duration.zero;
    }
    final Duration left = endsAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 按分钟开始计时；`minutes <= 0` 视为关闭（取消现有计时）。
  void startMinutes(int minutes) {
    if (minutes <= 0) {
      cancel();
      return;
    }
    start(Duration(minutes: minutes));
  }

  /// 开始计时；会先取消既有计时（重设语义）。
  void start(Duration duration) {
    cancel();
    if (duration <= Duration.zero) {
      return;
    }
    _endsAt = DateTime.now().add(duration);
    _timer = Timer(duration, _fire);
  }

  /// 取消计时（不触发回调）。
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
  }

  void _fire() {
    _timer = null;
    _endsAt = null;
    onFire();
  }
}
