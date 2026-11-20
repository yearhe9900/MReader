// 书架滚动帧率压测的 `flutter drive` 驱动（收尾壳）。
//
// 帧时序由集成测试内 `addTimingsCallback` 自行采集并落盘
// （`integration_test/shelf_scroll_bench_test.dart`），这里只负责跑完收集退出。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
