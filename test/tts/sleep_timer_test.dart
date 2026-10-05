// `TTS-05` 定时停止计时器（M3-T08）。
//
// 验收映射：到点自动停的**计时面**（PRD TTS-05 ① 的时序底座）——「停朗读」
// 动作在调用方（`ReaderPage._onSleepFire`），分钟合法性在 `TtsSettings.clampSleep`。
//
// 口径：真实短时长（**不引入 fake_async**——它不在 pubspec 依赖里）；
// 时序留足余量（计划 30ms、等待 150ms）防慢机抖动。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/tts/sleep_timer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('到点触发一次回调并自清（isActive/remaining 复位）', () async {
    int fired = 0;
    final SleepTimer timer = SleepTimer(onFire: () => fired++);

    timer.start(const Duration(milliseconds: 30));
    expect(timer.isActive, isTrue);
    expect(timer.remaining, greaterThan(Duration.zero));

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(fired, 1);
    expect(timer.isActive, isFalse);
    expect(timer.remaining, Duration.zero);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fired, 1); // 不会重复触发
  });

  test('取消不触发回调', () async {
    int fired = 0;
    final SleepTimer timer = SleepTimer(onFire: () => fired++)
      ..start(const Duration(milliseconds: 30));

    timer.cancel();
    expect(timer.isActive, isFalse);
    expect(timer.remaining, Duration.zero);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fired, 0);
  });

  test('重设覆盖旧计时：只按新计划触发一次', () async {
    int fired = 0;
    final SleepTimer timer = SleepTimer(onFire: () => fired++)
      ..start(const Duration(milliseconds: 200));
    timer.start(const Duration(milliseconds: 30));

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fired, 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(fired, 1); // 旧 200ms 计时已随重设取消
  });

  test('startMinutes(0) 与非正时长 = 关闭', () async {
    int fired = 0;
    final SleepTimer timer = SleepTimer(onFire: () => fired++)
      ..start(const Duration(milliseconds: 50));
    timer.startMinutes(0); // 关闭既有计时
    expect(timer.isActive, isFalse);

    timer.start(Duration.zero); // 非正时长直接忽略
    expect(timer.isActive, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fired, 0);
  });
}
