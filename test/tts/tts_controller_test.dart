// `TTS-01` 推进策略（M3-T06）：起读 / 跨章 / 纯标点跳过 / 停止 / 暂停恢复 /
// 引擎不可用 / 错误与载入失败——纯 Dart 驱动（FakeTtsEngine 手动结局）。
//
// 口径：`_run` 推进全走 microtask 链，用 [pumpEventQueue] 排空；期望值一律
// 硬编码字面量（契约纪律）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/tts/tts_controller.dart';

import 'tts_fakes.dart';

void main() {
  group('TtsController 推进（TTS-01）', () {
    test('① 从指定段起读：onActive 先于发声，current 记位', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final List<(int, int)> actives = <(int, int)>[];
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['甲', '乙', '丙'],
        1,
        onActive: (int c, int p) => actives.add((c, p)),
      );

      expect(await tts.start(0, 1), isTrue);
      await pumpEventQueue();

      expect(engine.spoken, <String>['乙']);
      expect(actives, <(int, int)>[(0, 1)]);
      expect(tts.isRunning, isTrue);
      expect(tts.current, (chapterIndex: 0, paraIndex: 1));
      await tts.stop();
    });

    test('③ 纯标点 / 空白段跳过：不高亮不发声', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final List<(int, int)> actives = <(int, int)>[];
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['正文一', '。！？……——', '———', '　', '正文二'],
        1,
        onActive: (int c, int p) => actives.add((c, p)),
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();
      expect(engine.spoken, <String>['正文一']);

      engine.completeCurrent();
      await pumpEventQueue();

      expect(engine.spoken, <String>['正文一', '正文二']);
      expect(actives, <(int, int)>[(0, 0), (0, 4)]); // 中间三段全跳
      await tts.stop();
    });

    test('② 章内读完自动进下一章，末章读完 onDone', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final List<(int, int)> actives = <(int, int)>[];
      int doneCount = 0;
      final List<List<String>> chapters = <List<String>>[
        <String>['甲', '乙'],
        <String>['！？', '丙'], // 首段纯标点 → 跨章后也跳过
      ];
      final TtsController tts = TtsController(
        engine,
        (int i) async => chapters[i],
        2,
        onActive: (int c, int p) => actives.add((c, p)),
        onDone: () => doneCount++,
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();
      expect(engine.spoken, <String>['甲']);

      engine.completeCurrent();
      await pumpEventQueue();
      expect(engine.spoken, <String>['甲', '乙']);

      engine.completeCurrent();
      await pumpEventQueue();
      expect(engine.spoken, <String>['甲', '乙', '丙']);
      expect(actives, <(int, int)>[(0, 0), (0, 1), (1, 1)]); // (1,0) 被跳

      engine.completeCurrent();
      await pumpEventQueue();
      expect(doneCount, 1);
      expect(tts.isRunning, isFalse);
      expect(tts.current, isNull);
    });

    test('stop：作废在途推进，不读下一段', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['甲', '乙'],
        1,
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();
      expect(engine.spoken, hasLength(1));

      await tts.stop();
      await pumpEventQueue();

      expect(engine.spoken, hasLength(1)); // 第二段没有被读
      expect(tts.isRunning, isFalse);
      expect(tts.current, isNull);
    });

    test('pause 留位不推进；resume 从段首重读本段', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['甲', '乙'],
        1,
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();
      expect(engine.spoken, <String>['甲']);

      await tts.pause();
      await pumpEventQueue();
      expect(tts.isRunning, isTrue);
      expect(tts.isPaused, isTrue);
      expect(tts.current, (chapterIndex: 0, paraIndex: 0));
      expect(engine.spoken, hasLength(1)); // 留位：没有推进到「乙」

      await tts.resume();
      await pumpEventQueue();
      expect(engine.spoken, <String>['甲', '甲']); // 段首重读
      expect(tts.isPaused, isFalse);
      await tts.stop();
    });

    test('init 不可用：start 返回 false，不发声', () async {
      final FakeTtsEngine engine = FakeTtsEngine()..initResult = false;
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['甲'],
        1,
      );

      expect(await tts.start(0, 0), isFalse);
      await pumpEventQueue();

      expect(engine.spoken, isEmpty);
      expect(tts.isRunning, isFalse);
      expect(engine.initCalls, 1);
    });

    test('引擎报错：onError 上抛并停止', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final List<String> errors = <String>[];
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['甲', '乙'],
        1,
        onError: errors.add,
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();
      engine.failCurrent();
      await pumpEventQueue();

      expect(errors, <String>['朗读出错，已停止']);
      expect(tts.isRunning, isFalse);
      expect(engine.spoken, hasLength(1));
    });

    test('正文载入失败：onError 上抛并停止', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final List<String> errors = <String>[];
      Future<List<String>?> nullLoader(int i) async => null;
      final TtsController tts = TtsController(
        engine,
        nullLoader,
        1,
        onError: errors.add,
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();

      expect(errors, <String>['本章正文载入失败，朗读已停止']);
      expect(tts.isRunning, isFalse);
      expect(engine.spoken, isEmpty);
    });
  });

  group('pauseOnError（TTS-07 ③ 自动暂停）', () {
    test('开：报错挂起留位当前段 + 中文提示，resume 重读本段', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final List<String> errors = <String>[];
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['甲', '乙'],
        1,
        onError: errors.add,
        pauseOnError: true,
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();
      engine.failCurrent();
      await pumpEventQueue();

      expect(errors, <String>['朗读出错，已暂停']);
      expect(tts.isRunning, isTrue); // 会话不收
      expect(tts.isPaused, isTrue); // 挂起等 resume
      expect(tts.current, (chapterIndex: 0, paraIndex: 0)); // 留位本段
      expect(engine.spoken, hasLength(1)); // 未推进「乙」

      await tts.resume();
      await pumpEventQueue();
      expect(engine.spoken, <String>['甲', '甲']); // 段首重读
      await tts.stop();
    });

    test('关（系统引擎默认语义）：报错即停止（M3-T08 行为不回潮）', () async {
      final FakeTtsEngine engine = FakeTtsEngine();
      final List<String> errors = <String>[];
      final TtsController tts = TtsController(
        engine,
        (int i) async => <String>['甲'],
        1,
        onError: errors.add,
      );

      expect(await tts.start(0, 0), isTrue);
      await pumpEventQueue();
      engine.failCurrent();
      await pumpEventQueue();

      expect(errors, <String>['朗读出错，已停止']);
      expect(tts.isRunning, isFalse);
      expect(tts.isPaused, isFalse);
    });
  });
}
