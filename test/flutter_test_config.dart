// 全局测试引导：**每个测试文件执行前**先初始化 Rust 解析内核。
//
// 2026-10-26 起解析实现唯一化（内核是 EPUB / TXT / MOBI / CBZ 的唯一实现，纯 Dart
// 源与「失败回落」一并删除）：任何**真实开书**的用例（导入 / 书库 / 详情页 / 搜索 /
// 统计 / 冒烟）都必须先 `RustLib.init()`，否则 FRB 抛
// 「flutter_rust_bridge has not been initialized」。
//
// 本文件由 `flutter_test` 自动加载（同目录及子目录所有测试），故只需写一处。
// 初始化失败**不中断**：本机没构建原生库时，依赖内核的用例会以明确报错失败
//（而不是每个文件各自 skip）；纯逻辑用例（fake 源 / 几何 / 存储）不受影响照常跑。
import 'dart:async';

import 'package:mreader/src/rust/frb_generated.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  try {
    await RustLib.init();
  } catch (error) {
    // 无原生库（未跑 `flutter build` 的 Rust 阶段）：让依赖内核的用例自己暴露。
    // ignore: avoid_print
    print('[test] RustLib.init 失败，依赖内核的用例将失败：$error');
  }
  await testMain();
}
