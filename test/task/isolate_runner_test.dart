// `IsolateRunner` 护栏单测（`PERF-01` 接线前置；纯 Dart `test()`，无 widget / FakeAsync）。
//
// 目标：证明「顶层纯函数 + 可序列化入参」可往返；而「不可序列化入参 / 捕获闭包」
// 会**明确失败**（不静默）。另证明两条接线契约：① 任务**确实跑在新 isolate**
// （`debugName` 取证）；② `runWithFallback` 的诚实降级（派发失败 → 同一任务回落
// 本 isolate 现跑）。
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/task/isolate_runner.dart';

int _doubleInt(int x) => x * 2;

String _reverse(String s) => String.fromCharCodes(s.runes.toList().reversed);

int _ignoreArgument(Object? _) => 1;

/// 回报「我在哪个 isolate」（tag@debugName）。
String _whereTag(Object? _) => 'x@${Isolate.current.debugName}';

/// 恒抛的任务（模拟远端意外失败）。
int _alwaysThrows(int x) => throw StateError('boom $x');

/// 不可跨 isolate 传递的持有者（内含 [ReceivePort]）。
class _NonSendable {
  final ReceivePort port = ReceivePort();
  int value = 7;
  void close() => port.close();
}

/// 执行 [action]：**同步抛**或**异步抛**都算通过；没抛则判失败。
Future<void> _expectThrows(Future<Object?> Function() action) async {
  try {
    await action();
  } catch (_) {
    return; // 抛了（无论同步/异步）→ 符合预期。
  }
  fail('期望抛出错误，但调用成功返回了');
}

void main() {
  group('IsolateRunner', () {
    test('顶层纯函数：数值 / 字符串往返', () async {
      const IsolateRunner runner = IsolateRunner();
      expect(await runner.run<int, int>(_doubleInt, 21), 42);
      expect(await runner.run<String, String>(_reverse, 'abc'), 'cba');
    });

    test('不可序列化入参（ReceivePort）→ 明确失败，不静默', () async {
      const IsolateRunner runner = IsolateRunner();
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);
      await _expectThrows(() => runner.run<Object?, int>(_ignoreArgument, port));
    });

    test('捕获闭包（捕获含 ReceivePort 的 this）→ 明确失败', () async {
      const IsolateRunner runner = IsolateRunner();
      final _NonSendable holder = _NonSendable();
      addTearDown(holder.close);
      // 该闭包捕获 holder（不可跨 isolate 传递），派发时应当失败。
      Future<int> closure(int x) async => holder.value + x;
      await _expectThrows(() => runner.run<int, int>(closure, 1));
    });

    test('任务跑在独立 isolate（debugName 取证）', () async {
      const IsolateRunner runner = IsolateRunner();
      final String who = await runner.run<Object?, String>(
        _whereTag,
        null,
        debugLabel: 'mreader-probe',
      );
      expect(who, 'x@mreader-probe',
          reason: '任务里的 Isolate.current.debugName 应是派发标签，'
              '证明执行位置不是调用方 isolate');
    });

    test('runWithFallback：派发失败（入参不可传）→ 同一任务回落本 isolate 现跑', () async {
      const IsolateRunner runner = IsolateRunner();
      final ReceivePort port = ReceivePort();
      addTearDown(port.close);
      final String mainTag = Isolate.current.debugName ?? '';
      // run 必失败（ReceivePort 不可跨 isolate），runWithFallback 应回落：
      // 同一任务在**本** isolate 现跑 —— 任务里的 debugName 与测试侧一致（无派发标签）。
      final String got =
          await runner.runWithFallback<Object?, String>(_whereTag, port);
      expect(got, 'x@$mainTag');
    });

    test('runWithFallback：任务远端意外抛出 → 回落重跑，错误以原类型冒出', () async {
      const IsolateRunner runner = IsolateRunner();
      await expectLater(
        runner.runWithFallback<int, int>(_alwaysThrows, 7),
        throwsA(isA<StateError>()
            .having((StateError e) => e.message, 'message', 'boom 7')),
      );
    });
  });
}
