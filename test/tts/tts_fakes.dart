// `TTS` 测试共用假引擎：speak 挂起等手动结局，记录送入文本（非 `*_test.dart`，
// 不会被 `flutter test` 当用例执行）。
import 'dart:async';

import 'package:mreader/tts/tts_engine.dart';

/// 可控假引擎（controller / widget 测试共用）。
class FakeTtsEngine implements TtsEngine {
  /// `init()` 返回值（false = 模拟无语音引擎平台，PRD §15.3 路径）。
  bool initResult = true;

  int initCalls = 0;

  /// 已送引擎的朗读文本（顺序 = 朗读顺序）。
  final List<String> spoken = <String>[];

  /// 当前在途的 speak（null = 无段落在读）。
  Completer<TtsSpeakResult>? pending;

  @override
  Future<bool> init() async {
    initCalls++;
    return initResult;
  }

  @override
  Future<TtsSpeakResult> speak(String text) {
    spoken.add(text);
    final Completer<TtsSpeakResult> completer = Completer<TtsSpeakResult>();
    pending = completer;
    return completer.future;
  }

  @override
  Future<void> stop() async => _settle(TtsSpeakResult.cancelled);

  @override
  Future<void> setRate(double rate) async {}

  /// 手动推进：当前段**正常读完**（controller 应推进下一段）。
  void completeCurrent() => _settle(TtsSpeakResult.done);

  /// 手动推进：当前段**引擎报错**（controller 应停止并 onError）。
  void failCurrent() => _settle(TtsSpeakResult.error);

  void _settle(TtsSpeakResult result) {
    final Completer<TtsSpeakResult>? completer = pending;
    pending = null;
    completer?.complete(result);
  }
}
