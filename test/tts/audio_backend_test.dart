// 平台后端契约：桌面工厂降级；真机实现的「init 一次性守卫」与
// 多轮 open / publish / close 全链路。
//
// ⚠️ 钉住的风险：`AudioService.init` 自带 `assert(_cacheManager == null)`——
// 进程内只能 init 一次，多轮朗读会话必须复用同一 handler（静态守卫），本测试
// 连续 open 两次即验证不重 init（否则 debug 下直接断言炸）。
//
// 口径：测试宿主为 Windows 桌面 → 无平台通道，audio_service 落 NoOp 默认实现、
// audio_session 落「Unsupported platform」防御分支，全链路在零原生环境下跑通；
// 真机失败路径（清单缺失 → PlatformException → `_failed` 终态降级）本机不可
// 复现，属代码审查项。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/platform/audio_service.dart';

void main() {
  // AudioService.init 首行即 ensureInitialized——先立测试 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  final bool mobile = Platform.isAndroid || Platform.isIOS;

  test('工厂按平台分派：桌面 → 降级档（仅前台朗读，§15.3 拍板）', () async {
    final SystemAudioBackend backend = createSystemAudioBackend();
    if (mobile) {
      expect(backend, isA<MobileSystemAudioBackend>());
      expect(backend.isSupported, isTrue);
    } else {
      expect(backend, isA<UnsupportedSystemAudioBackend>());
      expect(backend.isSupported, isFalse);
      // 降级档一切零副作用：open 回 false、publish/close 不抛。
      expect(await backend.open(), isFalse);
      backend.publishNowPlaying(id: 'b', title: 't', subtitle: 's');
      backend.publishPlaying(true);
      await backend.close();
    }
  });

  test('真机后端：多轮 open / 上屏 / close 走通，init 只有一次', () async {
    final MobileSystemAudioBackend backend = MobileSystemAudioBackend();
    expect(await backend.open(), isTrue);
    expect(await backend.open(), isTrue); // 二次不 init（assert 守卫）
    backend.publishNowPlaying(id: 'b1', title: '书名', subtitle: '第1章');
    backend.publishPlaying(true);
    backend.publishPlaying(false);
    await backend.close();
    // 会话可再来一轮（open → close 交替）。
    expect(await backend.open(), isTrue);
    backend.publishPlaying(true);
    await backend.close();
    // 事件流可订阅（broadcast，多轮会话各听各的）。
    expect(backend.events, isA<Stream<SystemAudioEvent>>());
  });
}
