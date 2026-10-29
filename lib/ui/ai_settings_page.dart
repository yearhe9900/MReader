// AI 设置页（`AI-01` 配置管理 + `AI-09` 全局开关 / 最保守模式 +
// `DATA-02` ③ 安全标注 + `AI-08` 测试连接可读错误）。
//
// 形制（`UI-04` 红线）：玻璃顶栏（导航层）+ [OpaqueContentSurface] 不透明内容；
// 分组卡片与行复用 [SettingsGroupCard] / [SettingsTile]（与设置页同口径）。
//
// 结构：
//   · 列表页 [AiSettingsPage]：AI 功能开关组（启用 / 最保守模式）+ 服务配置组
//     （每套一行 + 添加）+ 安全组（isSecure 为 false 时**明文标注** `DATA-02` ③）；
//   · 编辑页 [AiProviderEditPage]：字段 + 用途 chips + 测试连接（错误分类回显、
//     可重试）+ 删除；**API Key 不回显**，留空保持已存值。
//
// `DATA-02` ①：配置落盘 JSON 不含 apiKey（[AiProviderConfig.toJson] 结构性不含），
// 密钥单独经 [AiKeyVault]（SecureStore）；本页不做任何 key 日志输出。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/provider_config.dart';
import '../ai/provider_store.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'settings_kit.dart';

/// 页面内容左右留白（与设置页同一左边缘口径）。
const double _kPageInset = 16;

/// AI 设置列表页。
class AiSettingsPage extends StatefulWidget {
  /// 创建 AI 设置页（依赖显式注入，非全局单例）。
  const AiSettingsPage({
    super.key,
    required this.store,
    required this.client,
  });

  /// AI 配置存储（开关 / 配置列表 / 密钥门面）。
  final ProviderStore store;

  /// AI 客户端（编辑页「测试连接」复用组合根实例）。
  final AiClient client;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 打开编辑页（[config] 为 null = 新建）。
  Future<void> _openEditor(AiProviderConfig? config) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AiProviderEditPage(
          store: widget.store,
          client: widget.client,
          config: config,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AiPrefs prefs = widget.store.prefs;
    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: const Text('AI 设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
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
            _buildToggleGroup(prefs),
            _buildProviderGroup(prefs),
            _buildSecurityGroup(),
          ],
        ),
      ),
    );
  }

  /// 「AI 功能」组：全局开关 + 最保守模式（`AI-09`）。
  Widget _buildToggleGroup(AiPrefs prefs) {
    return SettingsGroupCard(
      header: 'AI 功能',
      children: <Widget>[
        SettingsTile(
          icon: Icons.auto_awesome_outlined,
          accent: SettingsAccents.purple,
          title: '启用 AI 功能',
          subtitle: '关闭后所有 AI 入口隐藏，不发送任何请求',
          trailing: Switch(
            value: prefs.aiEnabled,
            onChanged: (bool v) => widget.store.setAiEnabled(v),
          ),
          onTap: () => widget.store.setAiEnabled(!prefs.aiEnabled),
        ),
        SettingsTile(
          icon: Icons.shield_outlined,
          accent: SettingsAccents.orange,
          title: '最保守模式',
          subtitle: '仅发送选中的文本，不携带章节或整书内容',
          trailing: Switch(
            value: prefs.selectionOnly,
            onChanged: (bool v) => widget.store.setSelectionOnly(v),
          ),
          onTap: () => widget.store.setSelectionOnly(!prefs.selectionOnly),
        ),
      ],
    );
  }

  /// 「服务配置」组：每套一行 + 添加入口（`AI-01` ③ 多套可分别指定用途）。
  Widget _buildProviderGroup(AiPrefs prefs) {
    return SettingsGroupCard(
      header: '服务配置',
      footer: prefs.configs.isEmpty
          ? '尚未配置 AI 服务。添加至少一套配置后，翻译 / 摘要等功能才可用。'
          : null,
      children: <Widget>[
        for (final AiProviderConfig c in prefs.configs)
          SettingsTile(
            icon: Icons.dns_outlined,
            accent: SettingsAccents.blue,
            title: c.name,
            subtitle: '${c.baseUrl} · ${c.model}',
            value: c.useFor.isEmpty
                ? '未指定用途'
                : c.useFor.map((AiUseCase u) => u.label).join(' / '),
            onTap: () => _openEditor(c),
          ),
        SettingsTile(
          icon: Icons.add_outlined,
          accent: SettingsAccents.green,
          title: '添加配置',
          onTap: () => _openEditor(null),
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
          title: '密钥存储',
          subtitle: secure
              ? '密钥写入系统安全存储，不进备份、不进日志'
              : widget.store.vault.securityNotice,
        ),
      ],
    );
  }
}

/// 配置编辑页（新建 / 编辑共用）。
class AiProviderEditPage extends StatefulWidget {
  /// 创建编辑页；[config] 为 null = 新建。
  const AiProviderEditPage({
    super.key,
    required this.store,
    required this.client,
    this.config,
  });

  /// AI 配置存储。
  final ProviderStore store;

  /// AI 客户端（测试连接）。
  final AiClient client;

  /// 被编辑的配置；null = 新建。
  final AiProviderConfig? config;

  @override
  State<AiProviderEditPage> createState() => _AiProviderEditPageState();
}

class _AiProviderEditPageState extends State<AiProviderEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _timeout;
  late final TextEditingController _maxTokens;
  late final TextEditingController _temperature;
  late final TextEditingController _headers;

  /// 用途勾选（四选多）。
  late Set<AiUseCase> _useFor;

  /// 是否已有存储的密钥（决定「留空保持」提示与删除联动）。
  bool _hasStoredKey = false;

  bool _testing = false;
  String? _testError;
  bool _testRetryable = false;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final AiProviderConfig? c = widget.config;
    _name = TextEditingController(text: c?.name ?? '');
    _baseUrl = TextEditingController(text: c?.baseUrl ?? '');
    _apiKey = TextEditingController();
    _model = TextEditingController(text: c?.model ?? '');
    _timeout = TextEditingController(text: '${c?.timeoutSeconds ?? AiProviderConfig.defaultTimeoutSeconds}');
    _maxTokens = TextEditingController(text: c?.maxTokens?.toString() ?? '');
    _temperature = TextEditingController(text: c?.temperature?.toString() ?? '');
    _headers = TextEditingController(
      text: c == null || c.customHeaders.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(c.customHeaders),
    );
    _useFor = Set<AiUseCase>.of(c?.useFor ?? const <AiUseCase>{});
    if (c != null) {
      widget.store.readApiKey(c.id).then((String? key) {
        if (mounted) {
          setState(() => _hasStoredKey = key != null && key.isNotEmpty);
        }
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _timeout.dispose();
    _maxTokens.dispose();
    _temperature.dispose();
    _headers.dispose();
    super.dispose();
  }

  /// 由当前表单构造配置（新建时补 id；校验由 [AiProviderConfig.validate] 给出）。
  AiProviderConfig _buildConfig() {
    final Map<String, String> customHeaders = _parseHeaders();
    return AiProviderConfig(
      id: widget.config?.id ?? ProviderStore.newId(),
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      customHeaders: customHeaders,
      timeoutSeconds: int.tryParse(_timeout.text.trim()) ??
          AiProviderConfig.defaultTimeoutSeconds,
      maxTokens: int.tryParse(_maxTokens.text.trim()),
      temperature: double.tryParse(_temperature.text.trim()),
      useFor: _useFor,
    );
  }

  /// 自定义头合法则转 map（空文本 = 空 map）；合法性由 [_headerError] 前置校验。
  Map<String, String> _parseHeaders() {
    final String raw = _headers.text.trim();
    if (raw.isEmpty) {
      return const <String, String>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return <String, String>{
          for (final MapEntry<Object?, Object?> e in decoded.entries)
            if (e.key is String && e.value is String)
              e.key! as String: e.value! as String,
        };
      }
    } catch (_) {
      // 落到下方返回空（_headerError 已先行拦截，正常到不了这里）。
    }
    return const <String, String>{};
  }

  /// 自定义头校验：非空文本必须是「所有键值均为字符串」的 JSON 对象。
  String? _headerError() {
    final String raw = _headers.text.trim();
    if (raw.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map &&
          decoded.entries.every(
            (MapEntry<Object?, Object?> e) =>
                e.key is String && e.value is String,
          )) {
        return null;
      }
    } catch (_) {
      // 非 JSON → 报错。
    }
    return '自定义请求头需为 JSON 对象，如 {"X-Org": "…"}';
  }

  /// 保存（`AI-01` ①：校验通过才落盘；key 留空保持已存值）。
  Future<void> _save() async {
    final String? headerError = _headerError();
    if (headerError != null) {
      await _showError('无法保存', headerError);
      return;
    }
    final AiProviderConfig config = _buildConfig();
    final String? error = config.validate();
    if (error != null) {
      await _showError('无法保存', error);
      return;
    }
    await widget.store.saveConfig(config);
    final String key = _apiKey.text.trim();
    if (key.isNotEmpty) {
      await widget.store.vault.write(config.id, key);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 删除（确认后连带删密钥，见 [ProviderStore.removeConfig]）。
  Future<void> _delete() async {
    final AiProviderConfig? config = widget.config;
    if (config == null) {
      return;
    }
    final bool? ok = await GlassOverlays.showAlert<bool>(
      context: context,
      title: '删除配置',
      message: '删除「${config.name}」及其密钥？此操作不可撤销。',
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
    await widget.store.removeConfig(config.id);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 测试连接（`AI-01` ①②：成功提示 / 分类可读错误 + 可重试）。
  Future<void> _test() async {
    if (_testing) {
      return;
    }
    final String? headerError = _headerError();
    if (headerError != null) {
      setState(() {
        _testOk = false;
        _testRetryable = false;
        _testError = headerError;
      });
      return;
    }
    final AiProviderConfig config = _buildConfig();
    final String? error = config.validate();
    if (error != null) {
      setState(() {
        _testOk = false;
        _testRetryable = false;
        _testError = error;
      });
      return;
    }
    String? key = _apiKey.text.trim();
    if (key.isEmpty) {
      key = await widget.store.readApiKey(config.id);
    }
    if (key == null || key.isEmpty) {
      setState(() {
        _testOk = false;
        _testRetryable = false;
        _testError = '请先填写 API Key';
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
      await widget.client.testConnection(config: config, apiKey: key);
      if (mounted) {
        setState(() {
          _testing = false;
          _testOk = true;
        });
      }
    } on AiException catch (e) {
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
        title: Text(widget.config == null ? '添加配置' : '编辑配置'),
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
            SettingsGroupCard(
              header: '基本配置',
              children: <Widget>[
                _field('配置名称', _name, hint: '如 OpenAI / DeepSeek'),
                const Divider(height: 1),
                _field('Base URL', _baseUrl, hint: 'https://api.openai.com/v1'),
                const Divider(height: 1),
                _field('模型', _model, hint: '如 gpt-4o-mini'),
              ],
            ),
            SettingsGroupCard(
              header: 'API Key',
              footer: _hasStoredKey
                  ? '已保存密钥；输入框留空则保持不变。密钥不进备份、不进日志。'
                  : '密钥保存在系统安全存储，不进备份、不进日志（`DATA-02`）。',
              children: <Widget>[
                _field(
                  'API Key',
                  _apiKey,
                  hint: _hasStoredKey ? '••••（留空保持不变）' : 'sk-…',
                  obscure: true,
                ),
              ],
            ),
            SettingsGroupCard(
              header: '参数（可选）',
              children: <Widget>[
                _field('超时（秒）', _timeout, hint: '60', numeric: true),
                const Divider(height: 1),
                _field('最大输出 tokens', _maxTokens, hint: '留空 = 服务端默认', numeric: true),
                const Divider(height: 1),
                _field('温度', _temperature, hint: '0~2，留空 = 服务端默认', numeric: true),
                const Divider(height: 1),
                _field('自定义请求头（JSON，可选）', _headers, hint: '{"X-Org": "…"}'),
              ],
            ),
            SettingsGroupCard(
              header: '用途',
              footer: '翻译 / 摘要等功能从勾选了对应用途的配置中取第一套；TTS 在线引擎复用同一地址与密钥。',
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final AiUseCase use in AiUseCase.values)
                        FilterChip(
                          label: Text(use.label),
                          selected: _useFor.contains(use),
                          showCheckmark: false,
                          onSelected: (bool selected) {
                            setState(() {
                              if (selected) {
                                _useFor.add(use);
                              } else {
                                _useFor.remove(use);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
            _buildTestGroup(),
            if (widget.config != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SettingsGroupCard(
                  children: <Widget>[
                    SettingsTile(
                      icon: Icons.delete_outline,
                      accent: SettingsAccents.gray,
                      title: '删除此配置',
                      subtitle: '连同其密钥一起删除',
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

  /// 「测试连接」组：按钮 + 结果行（成功 / 分类错误 + 可重试时「重试」）。
  Widget _buildTestGroup() {
    final ThemeData theme = Theme.of(context);
    return SettingsGroupCard(
      header: '连接',
      children: <Widget>[
        ListTile(
          title: const Text('测试连接'),
          subtitle: _testing
              ? const Text('请求中…')
              : _testOk
                  ? Text(
                      '连接成功，接口可达。',
                      style: TextStyle(color: theme.colorScheme.primary),
                    )
                  : _testError == null
                      ? const Text('发一次最小请求验证地址、密钥与模型名')
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

  /// 单字段行（label 小字 + 无边框 TextField；整卡即 Material 祖先）。
  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
    bool numeric = false,
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
            keyboardType: numeric ? TextInputType.number : null,
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
