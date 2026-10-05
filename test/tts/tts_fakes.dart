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

  /// 可用音色（测试可注入；默认两枚中文/英文）。
  List<TtsVoice> voices = <TtsVoice>[
    const TtsVoice(name: 'zh-fake', locale: 'zh-CN'),
    const TtsVoice(name: 'en-fake', locale: 'en-US'),
  ];

  /// 最近一次 `setVoice` 收到的音色（null = 恢复系统默认）。
  TtsVoice? lastVoice;

  /// `setVoice` 被调用的次数。
  int setVoiceCalls = 0;

  /// 最近一次 `setRate` 收到的语速。
  double? lastRate;

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
  Future<void> setRate(double rate) async => lastRate = rate;

  @override
  Future<List<TtsVoice>> getVoices() async => List<TtsVoice>.of(voices);

  @override
  Future<void> setVoice(TtsVoice? voice) async {
    setVoiceCalls++;
    lastVoice = voice;
  }

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
