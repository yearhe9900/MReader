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
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/src/rust/frb_generated.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  try {
    await RustLib.init();
  } catch (error) {
    // 无原生库（未跑 `flutter build` 的 Rust 阶段）：让依赖内核的用例自己暴露。
    // ignore: avoid_print
    print('[test] RustLib.init 失败，依赖内核的用例将失败：$error');
  }

  // 全局 `testWidgets` 超时兜底（30s）——**注册前**设，才对本文件树下所有用例生效。
  //
  // 根因（同 `test_config.dart` 文件头）：`testWidgets` 注册时读
  // `binding.defaultTestTimeout`（`AutomatedTestWidgetsFlutterBinding` 默认 **10 分钟**），
  // 压过 CLI 的 `flutter test --timeout 30s` ⇒ 挂死一个用例就白等 10 分钟。全仓 88 个
  // 含 `testWidgets` 的文件里有 26 个没调 `capTestTimeout()`，在这里统一补上；
  // 已调的文件会在自己的 `main()` 里再压一次（同值，幂等）。
  //
  // ⚠️ 只改超时上限，不动 `setUp(sharedPaginationSchedulers.clear)`——那条由
  // `capTestTimeout()` 按文件注册，与超时是两回事。
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    binding.defaultTestTimeout = const Timeout(Duration(seconds: 30));
  }

  // ⚠️ 绑定初始化会顺手装上 flutter_test 的**假 HttpClient**（`initInstances` →
  // `setupHttpOverrides()`，把 `HttpOverrides.global` 换成拦一切真实请求的 mock）。
  // 本仓 `test/sync`、`test/tts`、`test/ai` 有**真起本地服务器**的用例，被 mock
  // 一拦全变 400（实测 `test/sync` 71 个用例集体红）。它们此前不坏，正是因为
  // 纯 `test()` 文件从不初始化绑定 ⇒ 这里把全局还原回去，行为与改造前一致；
  // 本仓也没有任何用例依赖那个 mock（都用注入的假客户端 / 真本地服务器）。
  HttpOverrides.global = null;

  await testMain();
}
