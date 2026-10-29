// AI API Key 门面（PRD `DATA-02`）。
//
// 底层是 `platform/secure_store.dart` 的 [SecureStore]（当前实现
// `FileSecureStore` = 应用私有目录明文；M4 接系统密钥库后自动升级）。本门面
// 只负责三件事：① 每套配置一把 Key，按稳定 `configId` 挂靠（前缀 `ai.key.`）；
// ② **Key 永不出现在配置 JSON / 日志**——读写只经本类；③ 把「是否真安全」与
// 中文说明透传给 UI（`DATA-02` ③ 明文标注）。
import '../platform/secure_store.dart';

/// AI 密钥读写门面。
class AiKeyVault {
  /// 用底层 [SecureStore] 构造（组合根注入，见 `lib/main.dart`）。
  AiKeyVault(this._store);

  final SecureStore _store;

  /// 键前缀（与 WebDAV 等其它凭据隔离命名空间）。
  static const String prefix = 'ai.key.';

  /// 某套配置的密钥存储键。
  static String keyNameFor(String configId) => '$prefix$configId';

  /// 读取配置的 API Key；未配置返 `null`。
  Future<String?> read(String configId) => _store.read(keyNameFor(configId));

  /// 写入（覆盖）配置的 API Key；空串视作删除（不存空凭据）。
  Future<void> write(String configId, String apiKey) async {
    if (apiKey.isEmpty) {
      await _store.delete(keyNameFor(configId));
      return;
    }
    await _store.write(keyNameFor(configId), apiKey);
  }

  /// 删除配置的 API Key（幂等）。
  Future<void> delete(String configId) => _store.delete(keyNameFor(configId));

  /// 当前平台是否为**真正的系统安全存储**（`false` = 明文，UI 须标注）。
  bool get isSecure => _store.isSecure;

  /// 明文存储时的用户告知文案（`DATA-02` ③）。
  String get securityNotice => _store.securityNotice;
}
