// 后台播放与系统集成后端（`TTS-03`，M3-T07）。
//
// 分层：本文件 = **平台适配层**（audio_service + audio_session 的唯一引用点，
// 同 `pdf_engine.dart` 的注入缝纪律）；生命周期 / 焦点语义的编排在
// `lib/tts/audio_session.dart`（纯 Dart，可注入假后端单测）。
//
// 平台支持矩阵（PRD §15.3，v2.6 负责人拍板）：
//   · Android / iOS → 全功能（通知栏 / 锁屏 / 耳机媒体键 / 音频焦点）；
//   · Linux / macOS / Windows → **降级「仅前台朗读」**（[createSystemAudioBackend]
//     直接返回 [UnsupportedSystemAudioBackend]，不触碰任何平台通道）。
//
// 失败契约（不可重试）：[MobileSystemAudioBackend.open] 首次失败即永久降级——
// `AudioService.init` 半途抛错会污染其静态态（`_cacheManager` 先置后抛），
// 再次 init 必撞 `assert(_cacheManager == null)`，故失败缓存为终态。
// 任何失败都只影响「后台能力」，朗读本身照常（仅前台）——不弹错、不崩溃。
import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart' as asvc;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 系统侧事件（通知栏按钮 / 耳机媒体键 / 音频焦点）——后端 → 编排层单向流。
enum SystemAudioEvent {
  /// 播放（通知栏「播放」、耳机键、焦点恢复后的续播请求）。
  play,

  /// 暂停（通知栏「暂停」、耳机键）。
  pause,

  /// 停止（系统侧终止播放请求；通知栏无停钮，预留耳机长按等路径）。
  stop,

  /// 下一章（通知栏 / 耳机「下一曲」映射）。
  skipToNext,

  /// 上一章（通知栏 / 耳机「上一曲」映射）。
  skipToPrevious,

  /// 音频焦点丢失（来电等打断开始——`TTS-03` ④ 前半）。
  focusLost,

  /// 音频焦点恢复且系统建议续播（挂断后——`TTS-03` ④ 后半）。
  focusGained,

  /// 耳机拔出（`becomingNoisy`：暂停，且**不**自动恢复）。
  becomingNoisy,
}

/// 系统音频后端抽象（真机实现 / 降级实现 / 测试桩三态同接口）。
abstract class SystemAudioBackend {
  /// 平台是否具备后台播放能力（降级档恒 `false`）。
  bool get isSupported;

  /// 系统侧事件流（broadcast；降级档为空流）。
  Stream<SystemAudioEvent> get events;

  /// 建立会话：init 插件（进程内一次）+ 配置语音会话 + 激活音频焦点。
  ///
  /// 返回 `false` = 后台能力不可用（降级仅前台朗读，调用方不提示不重试）。
  Future<bool> open();

  /// 更新锁屏 / 通知栏元数据（书名 + 当前章）。
  void publishNowPlaying({
    required String id,
    required String title,
    required String subtitle,
  });

  /// 播放态上屏：`true` = 暂停钮 + playing；`false` = 播放钮 + 非 playing。
  void publishPlaying(bool playing);

  /// 结束会话：撤通知（idle）+ 释放音频焦点。可与 [open] 交替多轮。
  Future<void> close();
}

/// 工厂：仅 Android / iOS 出全功能实现；桌面平台降级（§15.3 拍板）。
///
// 不用 `kIsWeb`：Web 工程已删（Q24），`dart:io` 在支持的五平台均可用。
SystemAudioBackend createSystemAudioBackend() {
  if (Platform.isAndroid || Platform.isIOS) {
    return MobileSystemAudioBackend();
  }
  return UnsupportedSystemAudioBackend();
}

/// 降级档（Linux / macOS / Windows）：「仅前台朗读」——一切调用零副作用。
class UnsupportedSystemAudioBackend implements SystemAudioBackend {
  @override
  bool get isSupported => false;

  @override
  Stream<SystemAudioEvent> get events => const Stream<SystemAudioEvent>.empty();

  @override
  Future<bool> open() async => false;

  @override
  void publishNowPlaying({
    required String id,
    required String title,
    required String subtitle,
  }) {}

  @override
  void publishPlaying(bool playing) {}

  @override
  Future<void> close() async {}
}

/// 真机实现（Android / iOS）：
///   · [asvc.AudioService] → 前台服务 / 通知栏 / 锁屏 / 媒体键
///     （Android 宿主须按包 README 声明清单并让 Activity 继承
///     `AudioServiceActivity`——已落 `MainActivity.kt` / `AndroidManifest.xml`）；
///   · [AudioSession] → 音频焦点（`speech()` 配方）与 `becomingNoisy`。
///
/// **插件句柄是进程级静态**（`AudioService.init` 自带
/// `assert(_cacheManager == null)`，一进程只许 init 一次）：多次开书各自
/// new 后端实例也共享同一 handler / 事件总线；[open] / [close] 可多轮交替。
class MobileSystemAudioBackend implements SystemAudioBackend {
  static final StreamController<SystemAudioEvent> _events =
      StreamController<SystemAudioEvent>.broadcast();

  /// 存具体类型而非 [asvc.AudioHandler]：接口面的 `mediaItem` /
  /// `playbackState` 是只读 `ValueStream`，上屏要走 `BehaviorSubject.add`。
  static _ReaderAudioHandler? _handler;
  static AudioSession? _session;
  static bool _failed = false;

  @override
  bool get isSupported => true;

  @override
  Stream<SystemAudioEvent> get events => _events.stream;

  @override
  Future<bool> open() async {
    if (_failed) return false; // 终态：失败不重试（见文件头失败契约）。
    try {
      if (_handler == null) {
        _handler = await asvc.AudioService.init(
          builder: () => _ReaderAudioHandler(_events.add),
          // artwork 缓存注入空 stub：MediaItem 恒无 artUri，缓存不可达；默认
          // DefaultCacheManager 构造即建临时目录 + 起异步 IO（测试环境必炸）。
          cacheManager: const _NullArtCacheManager(),
          config: const asvc.AudioServiceConfig(
            androidNotificationChannelId: 'com.mreader.app.channel.tts',
            androidNotificationChannelName: '朗读播放',
            androidNotificationChannelDescription: '锁屏与通知栏的朗读控制',
            // Android 12+ 后台重启前台服务受限：暂停期间服务保持前台
            // （包 README 指引），通知常驻可续播；停止朗读时随 idle 撤除。
            androidStopForegroundOnPause: false,
          ),
        );
        final AudioSession session = await AudioSession.instance;
        _session = session;
        // 语音朗读配方（iOS: playback + spokenAudio；Android: speech/media，
        // willPauseWhenDucked → 焦点事件统一为暂停-恢复，无 duck 分支）。
        await session.configure(const AudioSessionConfiguration.speech());
        session.interruptionEventStream.listen(_onInterruption);
        session.becomingNoisyEventStream
            .listen((_) => _events.add(SystemAudioEvent.becomingNoisy));
      }
      // 激活焦点：flutter_tts 自己的焦点请求不经过 audio_session（空 listener），
      // 打断事件只能由本会话的焦点监听产生——每轮会话都必须激活一次。
      final bool? ok = await _session?.setActive(true);
      if (ok == false) return false; // 焦点被拒（如通话中）→ 本轮降级。
      return true;
    } catch (_) {
      _failed = true;
      _handler = null;
      return false;
    }
  }

  /// 焦点事件 → 系统事件（begin 的 `duck` 忽略——`speech()` 配方下不会出现）。
  void _onInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      if (event.type == AudioInterruptionType.duck) return;
      _events.add(SystemAudioEvent.focusLost);
    } else if (event.type == AudioInterruptionType.pause) {
      // 结束事件带 `pause` = 系统建议续播（Android 恒如此；iOS 为 shouldResume）。
      _events.add(SystemAudioEvent.focusGained);
    }
  }

  @override
  void publishNowPlaying({
    required String id,
    required String title,
    required String subtitle,
  }) {
    _handler?.mediaItem.add(asvc.MediaItem(
      id: id,
      title: title,
      artist: subtitle,
    ));
  }

  @override
  void publishPlaying(bool playing) {
    final _ReaderAudioHandler? handler = _handler;
    if (handler == null) return;
    handler.playbackState.add(asvc.PlaybackState(
      processingState: asvc.AudioProcessingState.ready,
      playing: playing,
      controls: <asvc.MediaControl>[
        asvc.MediaControl.skipToPrevious,
        playing ? asvc.MediaControl.pause : asvc.MediaControl.play,
        asvc.MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      updatePosition: Duration.zero,
      speed: 1.0,
    ));
  }

  @override
  Future<void> close() async {
    final _ReaderAudioHandler? handler = _handler;
    if (handler == null || _failed) return;
    try {
      // 直接发 idle（等价 `stop()` 的效果但不回流 stop 事件给编排层——
      // 结束由 close 调用方发起，避免二次 stop）：撤通知、停前台服务。
      handler.playbackState.add(asvc.PlaybackState(
        processingState: asvc.AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
      ));
      await _session?.setActive(false); // 释放焦点（下轮 open 再激活）。
    } catch (_) {
      // 关场失败不外抛：通知残留可被下轮会话覆盖。
    }
  }
}

/// audio_service 回调 → 系统事件（通知栏 / 锁屏 / 媒体键的入站口）。
class _ReaderAudioHandler extends asvc.BaseAudioHandler {
  _ReaderAudioHandler(this._emit);

  final void Function(SystemAudioEvent) _emit;

  @override
  Future<void> play() async => _emit(SystemAudioEvent.play);

  @override
  Future<void> pause() async => _emit(SystemAudioEvent.pause);

  @override
  Future<void> stop() async => _emit(SystemAudioEvent.stop);

  @override
  Future<void> skipToNext() async => _emit(SystemAudioEvent.skipToNext);

  @override
  Future<void> skipToPrevious() async => _emit(SystemAudioEvent.skipToPrevious);
}

/// artwork 缓存空 stub（[asvc.AudioService.init] 必填参数）：MediaItem 恒无
/// artUri → 全部成员不可达，`noSuchMethod` 兜底免写 11 个接口方法。
class _NullArtCacheManager implements BaseCacheManager {
  const _NullArtCacheManager();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('artwork 缓存不应被调用（MediaItem 无 artUri）');
}
