// 系统 TTS 引擎（flutter_tts 4.2.5 包装；`TTS-01`）。
//
// 三个平台事实（读包源码钉死，非文档转述）：
//   · `speak()` 的 future **立即返回**（invokeMethod 确认即回），读完靠
//     `setCompletionHandler`（平台 `onDone` → `speak.onComplete`）；
//   · `stop()` 触发 `setCancelHandler`（Android `onStop` 非暂停分支 →
//     `speak.onCancel`）——**不是** completion，controller 据此区分
//     「读完推进」与「主动停止」；
//   · 包**无 linux 实现**（无 `linux/` 目录、pubspec 无条目）→ Linux 上
//     任何 invokeMethod 抛 `MissingPluginException` → [init] 返回 `false`
//     → UI 层中文提示（PRD §15.3 不静默失败）。
import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import 'tts_engine.dart';

/// 系统 TTS：把 flutter_tts 的 handler 语义收敛成 [TtsEngine] 契约。
class SystemTts implements TtsEngine {
  SystemTts() : _tts = FlutterTts() {
    _tts.setCompletionHandler(() => _finish(TtsSpeakResult.done));
    _tts.setCancelHandler(() => _finish(TtsSpeakResult.cancelled));
    _tts.setErrorHandler((dynamic _) => _finish(TtsSpeakResult.error));
  }

  final FlutterTts _tts;

  /// 在途 speak 的完结器（同一时刻至多一段在读）。
  Completer<TtsSpeakResult>? _pending;

  /// 探测结果缓存（`false` 恒定：Linux 无实现，重试无意义）。
  bool? _available;

  @override
  Future<bool> init() async {
    final bool? cached = _available;
    if (cached != null) return cached;
    try {
      // 无害探测：stop 在各实现上都是空闲无操作；无实现平台在此抛出。
      await _tts.stop();
      _available = true;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  @override
  Future<TtsSpeakResult> speak(String text) async {
    final Completer<TtsSpeakResult> completer = Completer<TtsSpeakResult>();
    // 上一段的结局若尚未送达（不应发生：controller 顺序驱动），先作废，
    // 保证「一个 completer 对应一次 utterance」。
    _finish(TtsSpeakResult.cancelled);
    _pending = completer;
    try {
      await _tts.speak(text);
    } catch (_) {
      // 平台侧调用失败（如无实现）：本段以 error 结局，不悬挂。
      _finish(TtsSpeakResult.error);
    }
    return completer.future;
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
      // 正常路径：平台随后回调 speak.onCancel → _finish(cancelled)。
      // 少数平台可能不回调，兜底在下一个 microtask 解挂在途 speak，
      // 避免 controller 悬挂（若回调已先到，此时 _pending 已空，无副作用）。
      scheduleMicrotask(_cancelPending);
    } catch (_) {
      _finish(TtsSpeakResult.cancelled);
    }
  }

  @override
  Future<void> setRate(double rate) async {
    try {
      await _tts.setSpeechRate(rate);
    } catch (_) {
      // 语速设置失败不打断朗读（引擎缺省语率继续）。
    }
  }

  void _finish(TtsSpeakResult result) {
    final Completer<TtsSpeakResult>? completer = _pending;
    _pending = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  void _cancelPending() => _finish(TtsSpeakResult.cancelled);
}
