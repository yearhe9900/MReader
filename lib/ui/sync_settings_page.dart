// WebDAV 同步设置页（`SYNC-01` 五要素配置 + 测试连接 + `SYNC-07` 失败可见）。
//
// 形制（`UI-04` 红线）：玻璃顶栏（导航层）+ [OpaqueContentSurface] 不透明内容；
// 分组卡片与行复用 [SettingsGroupCard] / [SettingsTile]（与设置页 / AI 设置页同口径）。
//
// 结构（单配置，无列表页）：
//   · 服务商预设（`SYNC-01`：多家服务商预设，点选回填地址）；
//   · 服务器组：url / 账号 / 密码 / 远端目录 / 设备名（`SYNC-01` 五要素）；
//   · 连接组：测试连接（成功 / 分类可读错误 + 可重试，`SYNC-01` ①②③、`SYNC-07`）；
//   · 安全组：`DATA-02` ③ 非安全存储时**必须**明文告知；
//   · 已配置时的删除（连带删密码，见 [SyncConfigStore.remove]）。
//
// `DATA-02` ①：配置落盘 JSON 不含 password（[SyncConfig.toJson] 结构性不含），
// 密码单独经 [SyncPasswordVault]（SecureStore）；本页不做任何密码日志输出。
import 'package:flutter/material.dart';

import '../sync/sync_config.dart';
import '../sync/sync_config_store.dart';
import '../sync/webdav_client.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'settings_kit.dart';

/// 页面内容左右留白（与设置页同一左边缘口径）。
const double _kPageInset = 16;

/// WebDAV 同步设置页（新建 / 编辑共用；单配置）。
class SyncSettingsPage extends StatefulWidget {
  /// 创建同步设置页（依赖显式注入，非全局单例）。
  const SyncSettingsPage({
    super.key,
    required this.store,
    required this.client,
  });

  /// 同步配置存储（配置 / 密码门面）。
  final SyncConfigStore store;

  /// WebDAV 客户端（测试连接；组合根实例）。
  final WebdavClient client;

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _account;
  late final TextEditingController _password;
  late final TextEditingController _dir;
  late final TextEditingController _device;

  /// 是否已有存储的密码（决定「留空保持」提示与删除联动）。
  bool _hasStoredPassword = false;

  bool _testing = false;
  String? _testError;
  bool _testRetryable = false;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final SyncConfig? c = widget.store.config;
    _url = TextEditingController(text: c?.url ?? '');
    _account = TextEditingController(text: c?.account ?? '');
    _password = TextEditingController();
    _dir = TextEditingController(text: c?.dir ?? SyncConfig.defaultDir);
    _device =
        TextEditingController(text: c?.deviceName ?? SyncConfig.defaultDeviceName);
    // 预设回填 / 手改地址都会重算选中态与脚注。
    _url.addListener(_onUrlChanged);
    if (c != null) {
      widget.store.readPassword().then((String? password) {
        if (mounted) {
          setState(
            () => _hasStoredPassword = password != null && password.isNotEmpty,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    _account.dispose();
    _password.dispose();
    _dir.dispose();
    _device.dispose();
    super.dispose();
  }

  void _onUrlChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 由当前表单构造配置（校验由 [SyncConfig.validate] 给出）。
  SyncConfig _buildConfig() => SyncConfig(
        url: _url.text.trim(),
        account: _account.text.trim(),
        dir: _dir.text,
        deviceName: _device.text,
      );

  /// 当前 url 命中的预设；无命中返 `null`。
  WebdavPreset? _matchedPreset() {
    final String url = _url.text.trim();
    if (url.isEmpty) {
      return null;
    }
    for (final WebdavPreset preset in SyncConfig.presets) {
      if (url == preset.url || url == _stripSlash(preset.url)) {
        return preset;
      }
    }
    return null;
  }

  static String _stripSlash(String url) => url.replaceAll(RegExp(r'/+$'), '');

  /// 点预设 → 回填地址（`SYNC-01` 多家服务商预设）。
  void _applyPreset(WebdavPreset preset) {
    _url.text = preset.url; // 触发 listener → setState 重算选中态。
  }

  /// 保存（校验通过才落盘；密码留空保持已存值）。
  Future<void> _save() async {
    final SyncConfig config = _buildConfig();
    final String? error = config.validate();
    if (error != null) {
      await _showError('无法保存', error);
      return;
    }
    await widget.store.save(config);
    final String password = _password.text;
    if (password.isNotEmpty) {
      await widget.store.writePassword(password);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 删除（确认后连带删密码，见 [SyncConfigStore.remove]）。
  Future<void> _delete() async {
    if (!widget.store.isConfigured) {
      return;
    }
    final bool? ok = await GlassOverlays.showAlert<bool>(
      context: context,
      title: '删除同步配置',
      message: '删除服务器地址、账号与已存密码？此操作不可撤销。',
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(context, false),
        ),
        GlassDialogAction(
          label: '删除',
          isDestructive: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (ok != true || !mounted) {
      return;
    }
    await widget.store.remove();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 测试连接（`SYNC-01` ①②③ + `SYNC-07`：分类可读错误 + 可重试）。
  ///
  /// 走 [WebdavClient.testConnection]：PROPFIND 验地址与凭据 → 远端目录逐级
  /// MKCOL（不存在则自动创建）。
  Future<void> _test() async {
    if (_testing) {
      return;
    }
    final SyncConfig config = _buildConfig();
    final String? error = config.validate();
    if (error != null) {
      setState(() {
        _testOk = false;
        _testRetryable = false;
        _testError = error;
      });
      return;
    }
    String? password = _password.text;
    if (password.isEmpty) {
      password = await widget.store.readPassword();
    }
    if (password == null || password.isEmpty) {
      setState(() {
        _testOk = false;
        _testRetryable = false;
        _testError = '请先填写密码';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testOk = false;
      _testError = null;
      _testRetryable = false;
    });
    try {
      await widget.client.testConnection(config: config, password: password);
      if (mounted) {
        setState(() {
          _testing = false;
          _testOk = true;
        });
      }
    } on SyncException catch (e) {
      if (mounted) {
        setState(() {
          _testing = false;
          _testOk = false;
          _testError = e.message;
          _testRetryable = e.retryable;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testing = false;
          _testOk = false;
          _testError = '$e';
        });
      }
    }
  }

  Future<void> _showError(String title, String message) async {
    await GlassOverlays.showAlert<void>(
      context: context,
      title: title,
      message: message,
      actions: <GlassDialogAction>[
        GlassDialogAction(
          label: '知道了',
          isPrimary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: const Text('同步设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: OpaqueContentSurface(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            _kPageInset,
            16,
            _kPageInset,
            kShellBottomInset,
          ),
          children: <Widget>[
            _buildPresetGroup(),
            _buildServerGroup(),
            _buildRemoteGroup(),
            _buildTestGroup(),
            _buildSecurityGroup(),
            if (widget.store.isConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SettingsGroupCard(
                  children: <Widget>[
                    SettingsTile(
                      icon: Icons.delete_outline,
                      accent: SettingsAccents.gray,
                      title: '删除同步配置',
                      subtitle: '连同已存密码一起删除',
                      onTap: _delete,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 「服务商预设」组（`SYNC-01`：多家服务商预设）。
  Widget _buildPresetGroup() {
    final WebdavPreset? matched = _matchedPreset();
    return SettingsGroupCard(
      header: '服务商预设',
      footer: matched?.hint ??
          '点选预设回填服务器地址；自托管（Nextcloud / 群晖等）请按模板改成自己的域名与用户名。',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final WebdavPreset preset in SyncConfig.presets)
                FilterChip(
                  label: Text(preset.name),
                  selected: _url.text.trim() == preset.url ||
                      _url.text.trim() == _stripSlash(preset.url),
                  showCheckmark: false,
                  onSelected: (_) => _applyPreset(preset),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 「服务器」组（`SYNC-01` 前三要素：url / 账号 / 密码）。
  Widget _buildServerGroup() {
    return SettingsGroupCard(
      header: '服务器',
      footer: _hasStoredPassword
          ? '已保存密码；输入框留空则保持不变。密码不进备份、不进日志。'
          : '密码保存在系统安全存储，不进备份、不进日志。',
      children: <Widget>[
        _field(
          '服务器地址',
          _url,
          hint: 'https://dav.jianguoyun.com/dav/',
        ),
        const Divider(height: 1),
        _field('账号', _account, hint: '用户名 / 邮箱'),
        const Divider(height: 1),
        _field(
          '密码',
          _password,
          hint: _hasStoredPassword ? '••••（留空保持不变）' : '应用密码 / 登录密码',
          obscure: true,
        ),
      ],
    );
  }

  /// 「远端目录与设备」组（`SYNC-01` 后两要素：目录默认 `mreader` / 设备名）。
  Widget _buildRemoteGroup() {
    return SettingsGroupCard(
      header: '远端目录与设备',
      footer: '所有同步数据都存放在 {服务器地址}/{远端目录}/ 下；目录不存在时自动创建。',
      children: <Widget>[
        _field('远端目录', _dir, hint: SyncConfig.defaultDir),
        const Divider(height: 1),
        _field(
          '设备名',
          _device,
          hint: '如 Xiaomi-Phone；用于备份文件命名（backup-日期-设备名.zip）',
        ),
      ],
    );
  }

  /// 「连接」组：测试按钮 + 结果行（成功 / 分类错误 + 可重试时「重试」，`SYNC-07`）。
  Widget _buildTestGroup() {
    final ThemeData theme = Theme.of(context);
    return SettingsGroupCard(
      header: '连接',
      children: <Widget>[
        ListTile(
          title: const Text('测试连接'),
          subtitle: _testing
              ? const Text('连接中…')
              : _testOk
                  ? Text(
                      '连接成功，远端目录已就绪。',
                      style: TextStyle(color: theme.colorScheme.primary),
                    )
                  : _testError == null
                      ? const Text('验证地址与凭据，并自动创建缺失的远端目录')
                      : Text(
                          _testError!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
          trailing: _testing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: _test,
                  child: Text(_testRetryable ? '重试' : '测试'),
                ),
        ),
      ],
    );
  }

  /// 「安全」组（`DATA-02` ③：非安全存储时**必须**明文告知）。
  Widget _buildSecurityGroup() {
    final bool secure = widget.store.vault.isSecure;
    return SettingsGroupCard(
      header: '安全',
      children: <Widget>[
        SettingsTile(
          icon: secure ? Icons.lock_outline : Icons.warning_amber_outlined,
          accent: secure ? SettingsAccents.green : SettingsAccents.gray,
          title: '密码存储',
          subtitle: secure
              ? '密码写入系统安全存储，不进备份、不进日志'
              : widget.store.vault.securityNotice,
        ),
      ],
    );
  }

  /// 单字段行（label 小字 + 无边框 TextField；整卡即 Material 祖先）。
  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          TextField(
            controller: controller,
            obscureText: obscure,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              border: InputBorder.none,
            ),
          ),
        ],
      ),
    );
  }
}
