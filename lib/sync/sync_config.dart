// WebDAV 同步连接配置模型（PRD §10 / `SYNC-01`）。
//
// 五要素（`SYNC-01`）：`url` / `account` / `password` / 远端目录（默认 `mreader`）
// / 设备名；**`password` 不在本模型内**（`DATA-02` 结构性保证）——配置 JSON 只存
// 连接信息，密码经 `SyncPasswordVault` 走 SecureStore，备份包 / 导出搜不到密码。
//
// 远端目录语义（PRD §10.3）：所有远端路径都落在 `{webdavUrl}/{dir}/` 之下；
// 目录不存在由 `WebdavClient` 逐级 MKCOL 自动创建（`SYNC-01` ③）。

/// 服务商预设（`SYNC-01`：支持多家服务商预设；点选回填服务器地址）。
class WebdavPreset {
  /// 创建预设。
  const WebdavPreset({
    required this.name,
    required this.url,
    required this.hint,
  });

  /// 展示名（如「坚果云」）。
  final String name;

  /// 回填的服务器地址。
  final String url;

  /// 补充说明（组脚注用；自托管类预设需要用户按提示改地址）。
  final String hint;
}

/// WebDAV 连接配置（不可变值对象；**不含密码**）。
class SyncConfig {
  /// 创建连接配置（[dir] / [deviceName] 缺省走默认值）。
  SyncConfig({
    required this.url,
    required this.account,
    String? dir,
    String? deviceName,
  })  : dir = _normalizeDir(dir),
        deviceName = _normalizeDeviceName(deviceName);

  /// 远端目录默认值（PRD §10.3：`dir` 默认 `mreader`）。
  static const String defaultDir = 'mreader';

  /// 设备名默认值（用于 `backup-{yyyy-MM-dd}-{device}.zip` 命名，§10.3）。
  static const String defaultDeviceName = 'MReader';

  /// 服务商预设（`SYNC-01`）：前两家是 concrete 地址；自托管（Nextcloud /
  /// 群晖等）给**模板地址**，用户按脚注提示改成自己的域名与用户名。
  static const List<WebdavPreset> presets = <WebdavPreset>[
    WebdavPreset(
      name: '坚果云',
      url: 'https://dav.jianguoyun.com/dav/',
      hint: '坚果云 WebDAV 服务，账号密码在坚果云「设置 → 安全选项 → 应用密码」生成。',
    ),
    WebdavPreset(
      name: '坚果云备用',
      url: 'https://dav2.jianguoyun.com/dav/',
      hint: '部分账号（企业版 / 旧版）使用备用地址。',
    ),
    WebdavPreset(
      name: 'Nextcloud / 群晖',
      url: 'https://nas.example.com:5001/remote.php/dav/files/用户名/',
      hint: '自托管模板：把域名与「用户名」改成你自己的；群晖默认端口 5001。',
    ),
  ];

  /// 服务器地址（WebDAV 根，如 `https://dav.jianguoyun.com/dav/`）。
  final String url;

  /// 账号（用户名 / 邮箱）。
  final String account;

  /// 远端目录（相对 `url`；已归一：去首尾斜杠，空回退 [defaultDir]）。
  final String dir;

  /// 设备名（备份文件命名等；空回退 [defaultDeviceName]）。
  final String deviceName;

  /// 归一远端目录：去首尾 `/`，空则回退 [defaultDir]。
  static String _normalizeDir(String? raw) {
    final String trimmed = (raw ?? '').trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? defaultDir : trimmed;
  }

  /// 归一设备名：空回退 [defaultDeviceName]。
  static String _normalizeDeviceName(String? raw) {
    final String trimmed = (raw ?? '').trim();
    return trimmed.isEmpty ? defaultDeviceName : trimmed;
  }

  /// 落盘 JSON（**结构性不含 password**——`DATA-02` ①）。
  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'account': account,
        'dir': dir,
        'deviceName': deviceName,
      };

  /// 由持久化 JSON 还原；结构异常（缺 url / account）返 `null`。
  static SyncConfig? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? url = json['url'];
    final Object? account = json['account'];
    if (url is! String || url.trim().isEmpty || account is! String) {
      return null;
    }
    return SyncConfig(
      url: url.trim(),
      account: account,
      dir: json['dir'] is String ? json['dir'] as String : null,
      deviceName:
          json['deviceName'] is String ? json['deviceName'] as String : null,
    );
  }

  /// 保存前校验；通过返 `null`，否则返**面向用户的中文错误**（`SYNC-01` ②）。
  String? validate() {
    final Uri? uri = Uri.tryParse(url.trim());
    if (url.trim().isEmpty ||
        uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '服务器地址需为完整的 http(s) 地址（如 https://dav.jianguoyun.com/dav/）';
    }
    if (account.trim().isEmpty) {
      return '请填写账号';
    }
    if (dir.contains('..')) {
      return '远端目录不能包含 ..';
    }
    return null;
  }
}
