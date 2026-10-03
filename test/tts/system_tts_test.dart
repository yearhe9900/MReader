// `TTS-01` 系统引擎降级面（M3-T06）：测试进程无 flutter_tts 平台实现 →
// `MissingPluginException` → init 返回 false、speak 以 error 结局不悬挂。
//
// 这正是 Linux 等无引擎平台的运行时形态（PRD §15.3：UI 层给中文提示，
// 不静默失败——提示接线由 `tts_ui_test.dart` 验收）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/tts/system_tts.dart';
import 'package:mreader/tts/tts_engine.dart';

void main() {
  // FlutterTts 构造内 `setMethodCallHandler` 要求 binding 已初始化
  // （platform_channel.dart:589 断言）——纯 test() 文件需显式 ensure。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('init：无平台实现 → false，且结果缓存（重复调用同值）', () async {
    final SystemTts tts = SystemTts();
    expect(await tts.init(), isFalse);
    expect(await tts.init(), isFalse); // 第二次走缓存，不重探测
  });

  test('speak：平台调用失败 → error 结局，不悬挂', () async {
    final SystemTts tts = SystemTts();
    final TtsSpeakResult result = await tts.speak('你好');
    expect(result, TtsSpeakResult.error);
  });

  test('stop：无实现平台静默容错（不抛出）', () async {
    final SystemTts tts = SystemTts();
    await expectLater(tts.stop(), completes);
  });

  test('setRate：无实现平台静默容错（不抛出）', () async {
    final SystemTts tts = SystemTts();
    await expectLater(tts.setRate(0.5), completes);
  });
}
