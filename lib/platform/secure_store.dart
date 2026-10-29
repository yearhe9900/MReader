// 凭据存取抽象接口（PRD §15.1 平台能力抽象 / §6.1 `DATA-02`）。
// 用途：AI Provider 的 `apiKey`（PRD §8.2）、WebDAV 密码等机密。
//
// 约束（`DATA-02`）：① 凭据**不得**明文落盘（无安全存储的平台除外，但须显式标注）；
// ② 凭据**不得**出现在日志中；③ 凭据**不得**进入备份包；④ 未配置系统安全存储的
// 平台，必须能向上暴露「是否真安全」，以便 UI 明确标注为「明文存储」并告知用户。
abstract interface class SecureStore {
  /// 读取指定键的凭据；不存在时返回 `null`。
  Future<String?> read(String key);

  /// 写入（覆盖）指定键的凭据。
  Future<void> write(String key, String value);

  /// 删除指定键的凭据；键不存在时不报错（幂等）。
  Future<void> delete(String key);

  /// 判断指定键是否存在。
  Future<bool> containsKey(String key);

  /// 当前实现是否使用**真正的系统安全存储**（Android Keystore / iOS Keychain /
  /// 桌面密钥库）。
  ///
  /// 为 `false` 时凭据是**明文**落盘的（仅限应用私有目录），UI 必须据此向用户
  /// 展示 [securityNotice]（对齐 `DATA-02` ③）。
  bool get isSecure;

  /// 面向用户的、可读的中文安全说明；UI 在 [isSecure] 为 `false` 时展示。
  String get securityNotice;
}
