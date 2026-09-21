// 凭据的**降级**实现（PRD `DATA-02` ③）。
//
// 定位：M1-T01 只提供「接口 + 降级实现」。系统密钥库插件（Android Keystore /
// iOS Keychain / 桌面 libsecret / kwallet）留到 M4 接入（见排期 M1-T01 备注）。
// Linux 等无可用密钥库的平台按 `DATA-02` ③「明确标注为明文存储并告知用户」，
// 由 [isSecure] / [securityNotice] 暴露给 UI。
//
// ⚠️ 安全提醒：本实现为**明文存储**。严禁把凭据内容写入任何日志——
// 本文件内不做任何 print / debugPrint，异常信息也不携带凭据值。
import 'dart:io';

import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'secure_store.dart';

/// 文件降级实现：把凭据集合以明文 JSON 存于应用私有目录。
///
/// 底层复用 [JsonStore] → [AtomicFile]，因此凭据文件的写入同样满足 `DATA-01`
/// 的原子写入与损坏回退语义。
class FileSecureStore implements SecureStore {
  /// 用应用数据目录下的一个 JSON 文件承载「键 → 凭据」映射。
  FileSecureStore({
    required Directory directory,
    String fileName = 'credentials.json',
  }) : _store = JsonStore(
          AtomicFile('${directory.path}${Platform.pathSeparator}$fileName'),
        );

  final JsonStore _store;

  @override
  bool get isSecure => false;

  @override
  String get securityNotice =>
      '当前平台未接入系统安全存储，AI 密钥与 WebDAV 密码将以明文保存在本机应用私有目录。'
      '请勿在共享设备上保存敏感凭据。';

  @override
  Future<String?> read(String key) async {
    final Map<String, String> all = await _readAll();
    return all[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final Map<String, String> all = await _readAll();
    if (all[key] == value) {
      return; // 值未变化，避免无谓写盘。
    }
    all[key] = value;
    await _writeAll(all);
  }

  @override
  Future<void> delete(String key) async {
    final Map<String, String> all = await _readAll();
    if (!all.containsKey(key)) {
      return; // 键不存在，幂等返回。
    }
    all.remove(key);
    await _writeAll(all);
  }

  @override
  Future<bool> containsKey(String key) async {
    final Map<String, String> all = await _readAll();
    return all.containsKey(key);
  }

  /// 读取全部凭据；文件缺失 / 损坏时返回空映射（回退逻辑由 [JsonStore] 处理）。
  Future<Map<String, String>> _readAll() async {
    final Object? decoded = await _store.read();
    if (decoded is! Map) {
      return <String, String>{};
    }
    final Map<String, String> result = <String, String>{};
    decoded.forEach((Object? key, Object? value) {
      if (key is String && value is String) {
        result[key] = value;
      }
    });
    return result;
  }

  Future<void> _writeAll(Map<String, String> all) =>
      _store.write(all);
}
