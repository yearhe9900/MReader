// 测试超时兜底（2026-09-23，应对「挂死一个白等 10 分钟」）。
//
// 根因（读框架源码实锤）：`flutter test --timeout 30s` 只改 runner 的**默认**
// 超时；而 `testWidgets` 注册时显式传 `timeout: binding.defaultTestTimeout`
// （flutter_test/src/widget_tester.dart:204），其值为 **10 分钟**
// （AutomatedTestWidgetsFlutterBinding，binding.dart:2239）——显式值压过 CLI
// 默认，故 `tool/test.sh` 的 `--timeout 30s` 对 testWidgets 一直无效，
// 挂死一个测试就白等满 10 分钟（超时后 `_pendingAsyncTasks` 还会泄漏到
// 下一个用例，触发次生的 Reentrant / PathAccessException 级联失败）。
//
// 用法：含 testWidgets 的测试文件在 `main()` **第一行**调用 [capTestTimeout]，
// 把显式兜底压到 30s（与 `tool/test.sh --timeout 30s` 的排查纪律一致）。
// 纯 `test()` 文件无需接入——CLI 默认值对它们本来就生效。
import 'package:flutter_test/flutter_test.dart';

/// 把 `testWidgets` 的兜底超时压到 [seconds] 秒（默认 30s）。
///
/// 必须在该测试文件注册任何 `testWidgets` **之前**调用（`testWidgets` 在
/// 注册时读取 `binding.defaultTestTimeout`），故约定放 `main()` 第一行。
void capTestTimeout({int seconds = 30}) {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    binding.defaultTestTimeout = Timeout(Duration(seconds: seconds));
  }
}
