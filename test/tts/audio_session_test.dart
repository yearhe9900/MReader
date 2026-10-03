// `TTS-03` 编排语义（M3-T07）：会话生命周期 / 系统事件翻译 / 焦点暂停恢复 /
// 降级不崩——假后端纯 Dart 驱动。
//
// 口径：事件经 broadcast 流异步送达，emit 后用 [pumpEventQueue] 排空；
// 期望值一律硬编码字面量（契约纪律）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/audio_service.dart';
import 'package:mreader/tts/audio_session.dart';

/// 假后端：open 结果可编程、可挂起（竞态用）、调用与上屏全记录。
class FakeSystemAudioBackend implements SystemAudioBackend {
  FakeSystemAudioBackend({this.openResult = true});

  bool openResult;

  /// 非空时 [open] 挂在该 completer 上（begin 在途 / end 作废的竞态注入）。
  Completer<bool>? openGate;

  int openCalls = 0;
  int closeCalls = 0;
  bool playing = false;
  ({String id, String title, String subtitle})? nowPlaying;

  final StreamController<SystemAudioEvent> _events =
      StreamController<SystemAudioEvent>.broadcast();

  @override
  bool get isSupported => true;

  @override
  Stream<SystemAudioEvent> get events => _events.stream;

  @override
  Future<bool> open() async {
    openCalls++;
    final Completer<bool>? gate = openGate;
    if (gate != null) return gate.future;
    return openResult;
  }

  @override
  void publishNowPlaying({
    required String id,
    required String title,
    required String subtitle,
  }) {
    nowPlaying = (id: id, title: title, subtitle: subtitle);
  }

  @override
  void publishPlaying(bool value) {
    playing = value;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    playing = false;
  }

  void emit(SystemAudioEvent event) => _events.add(event);
}

void main() {
  late FakeSystemAudioBackend backend;
  late TtsAudioSession session;
  late List<String> log;

  setUp(() {
    backend = FakeSystemAudioBackend();
    log = <String>[];
    // 箭头闭包在 cascade 赋值里须再包一层括号（`=> expr..next` 会被解析成
    // 对 expr 开级联 → void 上找不到 setter / setter 不属于 void）。
    session = TtsAudioSession(backend: backend)
      ..onPlay = (() => log.add('play'))
      ..onPause = (() => log.add('pause'))
      ..onStop = (() => log.add('stop'))
      ..onSkipToNext = (() => log.add('next'))
      ..onSkipToPrevious = (() => log.add('prev'));
  });

  group('会话生命周期（TTS-03）', () {
    test('begin 上元数据与在播态，end 撤场且此后事件不再进', () async {
      expect(
        await session.begin(
          bookId: 'b1',
          bookTitle: '书名',
          chapterTitle: '第1章',
        ),
        isTrue,
      );
      expect(session.isActive, isTrue);
      expect(backend.openCalls, 1);
      expect(
        backend.nowPlaying,
        (id: 'b1', title: '书名', subtitle: '第1章'),
      );
      expect(backend.playing, isTrue);

      session.updateChapter('第2章');
      expect(backend.nowPlaying!.subtitle, '第2章');
      session.setPlaying(false);
      expect(backend.playing, isFalse);

      await session.end();
      expect(session.isActive, isFalse);
      expect(backend.closeCalls, 1);
      await session.end(); // 幂等：二次 end 不再关
      expect(backend.closeCalls, 1);

      backend.emit(SystemAudioEvent.play);
      await pumpEventQueue();
      expect(log, <String>[]); // 断订阅：回调闭包不再被事件钉住
    });

    test('重复 begin 不重开后端，刷新元数据与在播态', () async {
      await session.begin(
        bookId: 'b1',
        bookTitle: '书名',
        chapterTitle: '第1章',
      );
      session.setPlaying(false);
      expect(
        await session.begin(
          bookId: 'b1',
          bookTitle: '书名',
          chapterTitle: '第9章',
        ),
        isTrue,
      );
      expect(backend.openCalls, 1);
      expect(backend.nowPlaying!.subtitle, '第9章');
      expect(backend.playing, isTrue);
      await session.end();
    });

    test('未 begin 的 updateChapter / setPlaying / 事件全为零副作用', () async {
      session.updateChapter('第1章');
      session.setPlaying(true);
      expect(backend.nowPlaying, isNull);
      expect(backend.playing, isFalse);

      backend.emit(SystemAudioEvent.play);
      await pumpEventQueue();
      expect(log, <String>[]);
      expect(backend.closeCalls, 0);
    });

    test('降级：open 失败 → begin false、不在册、调用无副作用不抛', () async {
      backend.openResult = false;
      expect(
        await session.begin(
          bookId: 'b1',
          bookTitle: '书名',
          chapterTitle: '第1章',
        ),
        isFalse,
      );
      expect(session.isActive, isFalse);
      expect(backend.nowPlaying, isNull);

      session.setPlaying(true);
      session.updateChapter('第2章');
      expect(backend.playing, isFalse);
      await session.end();
      expect(backend.closeCalls, 0); // 未在册不碰后端
    });

    test('begin 在途被 end 作废：收回后端，不留孤儿会话', () async {
      backend.openGate = Completer<bool>();
      final Future<bool> pending = session.begin(
        bookId: 'b1',
        bookTitle: '书名',
        chapterTitle: '第1章',
      );
      await session.end(); // open 未回：仅作废代数
      backend.openGate!.complete(true);

      expect(await pending, isFalse);
      expect(backend.closeCalls, 1); // open 已拉起 → 由作废分支收回
      expect(session.isActive, isFalse);
      expect(backend.nowPlaying, isNull); // 从未上屏
    });
  });

  group('系统事件翻译（TTS-03 ②③④）', () {
    test('通知栏 / 媒体键：play / pause / stop / 上一章 / 下一章逐路映射', () async {
      await session.begin(
        bookId: 'b1',
        bookTitle: '书名',
        chapterTitle: '第1章',
      );
      for (final SystemAudioEvent event in <SystemAudioEvent>[
        SystemAudioEvent.play,
        SystemAudioEvent.pause,
        SystemAudioEvent.stop,
        SystemAudioEvent.skipToNext,
        SystemAudioEvent.skipToPrevious,
      ]) {
        backend.emit(event);
        await pumpEventQueue();
      }
      expect(
        log,
        <String>['play', 'pause', 'stop', 'next', 'prev'],
      );
      await session.end();
    });

    test('焦点：在播才暂停且只记一次，恢复后可再来一轮（④）', () async {
      await session.begin(
        bookId: 'b1',
        bookTitle: '书名',
        chapterTitle: '第1章',
      );

      backend.emit(SystemAudioEvent.focusLost);
      await pumpEventQueue();
      backend.emit(SystemAudioEvent.focusLost); // 重复丢失幂等
      await pumpEventQueue();
      expect(log, <String>['pause']);

      backend.emit(SystemAudioEvent.focusGained);
      await pumpEventQueue();
      expect(log, <String>['pause', 'play']);

      backend.emit(SystemAudioEvent.focusLost); // 第二轮照样工作
      await pumpEventQueue();
      expect(log, <String>['pause', 'play', 'pause']);
      await session.end();
    });

    test('用户先手暂停：焦点丢失 / 恢复都不触发（④ 反面）', () async {
      await session.begin(
        bookId: 'b1',
        bookTitle: '书名',
        chapterTitle: '第1章',
      );
      session.setPlaying(false);

      backend.emit(SystemAudioEvent.focusLost);
      await pumpEventQueue();
      backend.emit(SystemAudioEvent.focusGained);
      await pumpEventQueue();
      expect(log, <String>[]);
      await session.end();
    });

    test('打断中用户按播放键：清焦点标记，之后 focusGained 不重复续播', () async {
      await session.begin(
        bookId: 'b1',
        bookTitle: '书名',
        chapterTitle: '第1章',
      );

      backend.emit(SystemAudioEvent.focusLost);
      await pumpEventQueue();
      backend.emit(SystemAudioEvent.play); // 通话中用户手动续播
      await pumpEventQueue();
      backend.emit(SystemAudioEvent.focusGained); // 挂断
      await pumpEventQueue();

      expect(log, <String>['pause', 'play']);
      await session.end();
    });

    test('耳机拔出：暂停且不自动恢复（becomingNoisy）', () async {
      await session.begin(
        bookId: 'b1',
        bookTitle: '书名',
        chapterTitle: '第1章',
      );

      backend.emit(SystemAudioEvent.becomingNoisy);
      await pumpEventQueue();
      backend.emit(SystemAudioEvent.focusGained);
      await pumpEventQueue();

      expect(log, <String>['pause']);
      await session.end();
    });
  });
}
