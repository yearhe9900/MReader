// 后台播放与系统集成编排（`TTS-03`）。
//
// 职责：把 [SystemAudioBackend] 的系统事件翻译成朗读侧动作，把朗读侧状态上屏到
// 通知栏 / 锁屏；**不持有 TtsController**——播控动作经回调（[onPlay] / [onPause] /
// …）注入，纯 Dart + 假后端即可全量单测。
//
// `TTS-03` 验收映射：① 锁屏继续朗读 = 后端的前台服务 / 后台音频（清单 + 插件），
// 编排层无感；② 通知栏播放/暂停/上一章/下一章 = play/pause/skip 事件；③ 耳机媒体键
// 与通知栏共用同一 media session → 同一事件口；④ 来电暂停 = [SystemAudioEvent.focusLost]
// （仅当在播才暂停、且记「因焦点暂停」），挂断恢复 = [SystemAudioEvent.focusGained]
// 且带该标记才续播（用户先手暂停的不被焦点事件抢走）；耳机拔出（becomingNoisy）
// = 暂停且**不**自动恢复。
//
// 降级：后端 [SystemAudioBackend.open] 返回 `false`（桌面平台 / 插件初始化失败）
// → [begin] 回 `false`，朗读照常仅前台——不提示（PRD §15.3 拍板）。
import 'dart:async';

import '../platform/audio_service.dart';

/// 朗读会话与系统媒体层的编排器（每阅读页一个实例）。
class TtsAudioSession {
  /// [backend] 注入缝（测试传假后端；缺省走 [createSystemAudioBackend] 工厂）。
  TtsAudioSession({SystemAudioBackend? backend})
      : _backend = backend ?? createSystemAudioBackend();

  final SystemAudioBackend _backend;

  StreamSubscription<SystemAudioEvent>? _sub;

  /// 会话是否在册（begin 成功 → true；end 后 false，期间事件一律忽略）。
  bool _active = false;

  /// 朗读侧当前是否在播（焦点事件的判定基准；由 [setPlaying] 刷新）。
  bool _playing = false;

  /// 是否「因焦点丢失而暂停」——只有这个标记下 [SystemAudioEvent.focusGained]
  /// 才触发续播（用户手暂停 → 事件照常到达但不续播）。
  bool _interrupted = false;

  /// 会话代数：[begin] 在途时被 [end] 作废（开读后立刻停止的竞态）用——
  /// open 已把插件拉起，若不管会让孤儿会话挂着通知与音频焦点。
  int _epoch = 0;

  String _bookId = '';
  String _bookTitle = '';

  // ── 系统侧 → 朗读侧（reader 注入；未注入 = 忽略）───────────────────────

  /// 请求开读 / 续播（通知栏播放键、耳机键、焦点恢复）。
  void Function()? onPlay;

  /// 请求暂停（通知栏暂停键、耳机键、焦点丢失、耳机拔出）。
  void Function()? onPause;

  /// 请求停止整个朗读会话。
  void Function()? onStop;

  /// 跳上一章 / 下一章（通知栏 / 耳机曲目键映射）。
  void Function()? onSkipToPrevious;
  void Function()? onSkipToNext;

  /// 后台能力是否已启用（false = 降级仅前台朗读）。
  bool get isActive => _active;

  /// 开启会话（每轮朗读开始时调一次）：开后端 → 订阅事件 → 上元数据与在播态。
  ///
  /// 返回 `false` = 后台能力不可用（降级，调用方无需提示）。
  Future<bool> begin({
    required String bookId,
    required String bookTitle,
    required String chapterTitle,
  }) async {
    if (_active) {
      // 已在册（重启朗读等）：刷新元数据与在播态即可。
      _bookId = bookId;
      _bookTitle = bookTitle;
      _publishNowPlaying(chapterTitle);
      setPlaying(true);
      return true;
    }
    final int epoch = ++_epoch;
    if (!await _backend.open()) return false;
    if (epoch != _epoch) {
      // open 在途被 end 作废：收回刚拉起的插件（焦点 / 服务），不挂孤儿会话。
      await _backend.close();
      return false;
    }
    _sub ??= _backend.events.listen(_onEvent);
    _bookId = bookId;
    _bookTitle = bookTitle;
    _active = true;
    _interrupted = false;
    _publishNowPlaying(chapterTitle);
    setPlaying(true);
    return true;
  }

  /// 当前章变化 → 更新锁屏 / 通知栏副标题（未在册则忽略）。
  void updateChapter(String chapterTitle) {
    if (!_active) return;
    _publishNowPlaying(chapterTitle);
  }

  /// 朗读态变化 → 通知栏播放/暂停钮（未在册则忽略）。
  void setPlaying(bool playing) {
    if (!_active) return;
    _playing = playing;
    _backend.publishPlaying(playing);
  }

  /// 结束会话（停止朗读 / 读完 / 退出阅读页）：撤通知、放焦点。
  Future<void> end() async {
    _epoch++; // 作废在途 begin（即便本就未在册也须作废，防孤儿会话）
    if (!_active) return;
    _active = false; // 先关闸：close 引发的回流事件一律不再进 [_onEvent]。
    _playing = false;
    _interrupted = false;
    // 断订阅防泄漏：回调闭包持 reader State，页销毁后不得再被事件钉住。
    await _sub?.cancel();
    _sub = null;
    await _backend.close();
  }

  /// 元数据：title = 书名（稳定主标），subtitle = 当前章（动态副标）。
  void _publishNowPlaying(String chapterTitle) {
    _backend.publishNowPlaying(
      id: _bookId,
      title: _bookTitle,
      subtitle: chapterTitle,
    );
  }

  /// 系统事件翻译（守卫：非在册态整段忽略）。
  void _onEvent(SystemAudioEvent event) {
    if (!_active) return;
    switch (event) {
      case SystemAudioEvent.play:
        _interrupted = false; // 用户显式播放 = 放弃焦点暂停标记
        onPlay?.call();
      case SystemAudioEvent.pause:
        _interrupted = false;
        onPause?.call();
      case SystemAudioEvent.stop:
        _interrupted = false;
        onStop?.call();
      case SystemAudioEvent.skipToNext:
        onSkipToNext?.call();
      case SystemAudioEvent.skipToPrevious:
        onSkipToPrevious?.call();
      case SystemAudioEvent.focusLost:
        // 仅在播才暂停（手暂停后来电不重复暂停），且只记一次标记。
        if (!_playing || _interrupted) return;
        _interrupted = true;
        onPause?.call();
      case SystemAudioEvent.focusGained:
        if (!_interrupted) return; // 非焦点暂停（手暂停 / 耳机拔出）不续播
        _interrupted = false;
        onPlay?.call();
      case SystemAudioEvent.becomingNoisy:
        if (!_playing) return;
        onPause?.call(); // 拔耳机只暂停，不置标记 → 不自动恢复
    }
  }
}
