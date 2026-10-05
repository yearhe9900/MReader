// 段落朗读驱动（`TTS-01`，M3-T06）：逐段送引擎 → 读完推进 → 章末跨章。
//
// 推进语义（PRD §9.2 / TTS-01 验收）：
//   ① 从指定 (章, 段) 起读；
//   ② 读完自动进下一章——章内扫不到可读段 → `chapterIndex + 1` 从头再扫；
//   ③ 纯标点 / 空白段跳过（[shouldSpeakParagraph]，在 onActive 之前就跳，
//      不高亮、不发声）；
// 结局语义靠 [TtsSpeakResult] 区分：只有 `done` 推进，`cancelled` 是主动
// 停止 / 暂停（引擎层已把 stop 归为 cancelled，见 system_tts.dart 文件头）。
//
// 与进度的关系（PRD §9.4 / RD-04）：控制器**不写任何进度**——朗读推进只通过
// reader 侧的跟随滚动汇入既有 `(章节索引, 章内位置)` 模型，不产生第二套真值。
import 'dart:async';

import '../reader/selection_overlay.dart' show plainParagraphText;
import 'tts_engine.dart';

/// 段落朗读控制器（引擎 + 章内容加载器注入，纯 Dart 可单测）。
class TtsController {
  /// [engine] / [loadChapter] / [chapterCount] 走位置参数（私有字段无法作
  /// 命名初始化形参——`this._x` 仅限位置参数，同 `high_perf_registry.dart`）。
  TtsController(
    this._engine,
    this._loadChapter,
    this._chapterCount, {
    this.onActive,
    this.onDone,
    this.onError,
    this.onChanged,
  });

  final TtsEngine _engine;
  final Future<List<String>?> Function(int chapterIndex) _loadChapter;
  final int _chapterCount;

  /// 当前朗读段变化（每段发声**之前**回调一次——高亮与跟随滚动的驱动源）。
  final void Function(int chapterIndex, int paraIndex)? onActive;

  /// 全书读完（最后一章最后一个可读段读完）。
  final void Function()? onDone;

  /// 致命错误（引擎报错 / 正文载入失败）：消息原样上抛，UI 层负责展示。
  final void Function(String message)? onError;

  /// 运行态任何变化（start / stop / pause / resume / 完结）——UI 刷新按钮。
  final void Function()? onChanged;

  bool _running = false;
  bool _paused = false;
  bool? _inited;

  /// 代数：start / stop / resume 各 ++ 一次，旧循环见到代数不匹配即退出
  /// （作废在途推进，防「停止后又推进一段」）。
  int _gen = 0;

  int _chapter = 0;
  int _para = 0;

  /// 会话进行中（含暂停——暂停保留高亮与当前位置）。
  bool get isRunning => _running;

  bool get isPaused => _paused;

  /// 活动态：正在发声（非暂停）。
  bool get isActive => _running && !_paused;

  /// 当前朗读段（未在朗读 → null）。
  ({int chapterIndex, int paraIndex})? get current =>
      _running ? (chapterIndex: _chapter, paraIndex: _para) : null;

  /// 从 (chapterIndex, paraIndex) 开始朗读（`TTS-01` ①）。
  ///
  /// 返回 `false` = 引擎不可用（PRD §15.3：调用方给「本机未安装语音引擎」
  /// 中文提示）；返回 `true` 已开读（首段经 [onActive] 回调上抛）。
  Future<bool> start(int chapterIndex, int paraIndex) async {
    if (_running) await stop();
    final bool available = _inited ??= await _engine.init();
    if (!available) return false;
    _chapter = _chapterCount > 0
        ? chapterIndex.clamp(0, _chapterCount - 1)
        : chapterIndex;
    _para = paraIndex < 0 ? 0 : paraIndex;
    _running = true;
    _paused = false;
    _gen++;
    onChanged?.call();
    unawaited(_run(_gen));
    return true;
  }

  /// 停止朗读并清位（高亮由 UI 侧随 onChanged 撤除）。
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _paused = false;
    _gen++; // 作废在途推进：引擎 cancel 结局到达时直接退出
    onChanged?.call();
    await _engine.stop();
  }

  /// 暂停（`TTS-02` ③ 的对偶面 / M3-T08 面板入口）：停引擎、**留位**当前段。
  Future<void> pause() async {
    if (!isActive) return;
    _paused = true;
    onChanged?.call();
    await _engine.stop(); // 在途 speak → cancelled → 循环留在当前段退出
  }

  /// 恢复：**重读当前段**（段内进度引擎不可知，从段首重来是唯一稳定语义）。
  Future<void> resume() async {
    if (!_running || !_paused) return;
    _paused = false;
    _gen++; // 旧循环若仍悬挂于上一次 speak，作废之
    onChanged?.call();
    unawaited(_run(_gen));
  }

  /// 设置语速（透传引擎；`TTS-04`① 语速面板接线）。
  Future<void> setRate(double rate) => _engine.setRate(rate);

  /// 当前可用音色（透传引擎；`TTS-04`② 音色面板接线）。
  Future<List<TtsVoice>> getVoices() => _engine.getVoices();

  /// 选音色（透传引擎；`null` = 系统默认）。
  Future<void> setVoice(TtsVoice? voice) => _engine.setVoice(voice);

  Future<void> _run(int gen) async {
    while (_running && gen == _gen) {
      final List<String>? paragraphs = await _loadChapter(_chapter);
      if (!_running || gen != _gen) return;
      if (paragraphs == null) {
        _fail('本章正文载入失败，朗读已停止');
        return;
      }

      // 从当前位置起找第一个可读段（`TTS-01` ③ 纯标点 / 空白跳过）。
      int p = _para;
      while (p < paragraphs.length && !shouldSpeakParagraph(paragraphs[p])) {
        p++;
      }
      if (p >= paragraphs.length) {
        // 章内读完 → 下一章（`TTS-01` ② 跨章续读）。
        _chapter += 1;
        _para = 0;
        if (_chapter >= _chapterCount) {
          _finishDone();
          return;
        }
        continue;
      }

      _para = p;
      onActive?.call(_chapter, _para);
      final TtsSpeakResult result =
          await _engine.speak(plainParagraphText(paragraphs[p]).trim());
      if (!_running || gen != _gen) return;

      switch (result) {
        case TtsSpeakResult.done:
          _para = p + 1; // 推进下一段
        case TtsSpeakResult.cancelled:
          if (_paused) return; // 主动暂停：留位等 resume 重读本段
          // 仍在跑却收到 cancel = 平台侧打断（音频焦点被抢等）→ 停会话，
          // 不算错误（按钮随 onChanged 回到「未朗读」态）。
          _running = false;
          _paused = false;
          onChanged?.call();
          return;
        case TtsSpeakResult.error:
          _fail('朗读出错，已停止');
          return;
      }
    }
  }

  void _finishDone() {
    _running = false;
    _paused = false;
    onChanged?.call();
    onDone?.call();
  }

  void _fail(String message) {
    _running = false;
    _paused = false;
    onChanged?.call();
    onError?.call(message);
  }
}
