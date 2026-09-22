// `IsolateRunner` 护栏单测（纯 Dart `test()`，不涉及 widget / FakeAsync）。
//
// 目标：证明「顶层纯函数 + 可序列化入参」可往返；而「不可序列化入参 / 捕获闭包」
// 会**明确失败**（不静默）——这是 `M2a-T06`（`PERF-01` 接线）的前置护栏。
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/task/isolate_runner.dart';

int _doubleInt(int x) => x * 2;

String _reverse(String s) => String.fromCharCodes(s.runes.toList().reversed);

int _ignoreArgument(Object? _) => 1;

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
  });
}
