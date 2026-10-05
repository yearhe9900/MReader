// 在线 TTS 配置页（`TTS-07`，M3-T09）：URL 模板 / OpenAI 兼容双模式 +
// 请求头 + 编码 + 密钥 + 音频缓存管理。
//
// 形制复用 `AI-01` Provider 配置页（PRD §8.2「TTS 复用」的界面落点）：
// 玻璃顶栏（导航层）+ [OpaqueContentSurface] 不透明内容；分组卡片与行复用
// [SettingsGroupCard] / [SettingsTile]；保存前 [OnlineTtsConfig.validate]
// 中文校验弹窗；API Key 不回显、不进配置 JSON（`DATA-02`，经
// [OnlineTtsStore] → `AiKeyVault` 安全存储）。
//
// 引擎切换（系统 / 在线）在朗读设置面板（`TtsSettingsSheet`），本页只管
// 「怎么连」；页脚提示两者的关系。
import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/provider_config.dart';
import '../ai/provider_store.dart';
import '../tts/online_tts.dart';
import 'glass_kit.dart';
import 'home_shell.dart' show kShellBottomInset;
import 'settings_kit.dart';

/// 页面内容左右留白（与设置页同一左边缘口径）。
const double _kPageInset = 16;

/// 在线 TTS 配置页（单页表单，新建 / 编辑同一形态——只有一套配置）。
class TtsSettingsPage extends StatefulWidget {
  /// 创建页面（[aiStore] 可空 = 未接线 AI → 隐藏「从 AI 配置导入」）。
  const TtsSettingsPage({
    super.key,
    required this.store,
    this.aiStore,
  });

  /// 在线 TTS 配置存储。
  final OnlineTtsStore store;

  /// AI 配置存储（导入 baseUrl / apiKey 复用，PRD §8.2「TTS 复用」）。
  final ProviderStore? aiStore;

  @override
  State<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<TtsSettingsPage> {
  late final TextEditingController _urlTemplate;
  late final TextEditingController _headers;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _voice;
  late final TextEditingController _format;
  late final TextEditingController _timeout;
  late final TextEditingController _apiKey;

  late OnlineTtsMode _mode;
  late OnlineTtsEncoding _encoding;

  /// 是否已有存储的密钥（决定「留空保持」提示）。
  bool _hasStoredKey = false;

  /// 缓存计数代际（清理后 +1 触发 FutureBuilder 重查）。
  int _cacheEpoch = 0;

  @override
  void initState() {
    super.initState();
    final OnlineTtsConfig c = widget.store.value;
    _mode = c.mode;
    _encoding = c.textEncoding;
    _urlTemplate = TextEditingController(text: c.urlTemplate);
    _headers = TextEditingController(text: formatHeaderLines(c.headers));
    _baseUrl = TextEditingController(text: c.baseUrl);
    _model = TextEditingController(text: c.model);
    _voice = TextEditingController(text: c.voice);
    _format = TextEditingController(text: c.audioFormat);
    _timeout = TextEditingController(text: '${c.timeoutSeconds}');
    _apiKey = TextEditingController();
    widget.store.readApiKey().then((String? key) {
      if (mounted) {
        setState(() => _hasStoredKey = key != null && key.isNotEmpty);
      }
    });
  }

  @override
  void dispose() {
    _urlTemplate.dispose();
    _headers.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _voice.dispose();
    _format.dispose();
    _timeout.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// 保存（校验通过才落盘；key 留空保持已存值——同 `AI-01` 口径）。
  Future<void> _save() async {
    final ({Map<String, String> headers, String? error}) parsed =
        parseHeaderLines(_headers.text);
    if (parsed.error != null) {
      await _showError('无法保存', parsed.error!);
      return;
    }
    final OnlineTtsConfig config = OnlineTtsConfig(
      mode: _mode,
      urlTemplate: _urlTemplate.text.trim(),
      headers: parsed.headers,
      textEncoding: _encoding,
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      voice: _voice.text.trim(),
      audioFormat: _format.text.trim(),
      timeoutSeconds: int.tryParse(_timeout.text.trim()) ??
          OnlineTtsConfig.defaultTimeoutSeconds,
    );
    final String? error = config.validate();
    if (error != null) {
      await _showError('无法保存', error);
      return;
    }
    await widget.store.setConfig(config);
    final String key = _apiKey.text.trim();
    if (key.isNotEmpty) {
      await widget.store.writeApiKey(key);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 从 AI 配置导入 baseUrl + apiKey（`AI-01` 多套 → 选一套）。
  Future<void> _importFromAi() async {
    final ProviderStore? aiStore = widget.aiStore;
    if (aiStore == null) return;
    final AiProviderConfig? picked = await GlassOverlays.showAlert<
        AiProviderConfig?>(
      context: context,
      title: '从 AI 配置导入',
      message: '选择要复用的服务配置：地址与密钥将写入在线 TTS。',
      actions: <GlassDialogAction>[
        for (final AiProviderConfig c in aiStore.configs)
          GlassDialogAction(
            label: c.name,
            onPressed: () => Navigator.pop(context, c),
          ),
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(context, null),
        ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _mode = OnlineTtsMode.openaiSpeech;
      _baseUrl.text = picked.baseUrl;
    });
    final String? key = await aiStore.readApiKey(picked.id);
    if (key != null && key.isNotEmpty) {
      await widget.store.writeApiKey(key);
    }
    if (mounted) {
      setState(() => _hasStoredKey = _hasStoredKey || (key?.isNotEmpty ?? false));
    }
  }

  /// 清理音频缓存（`TTS-07` ② 的管理面）。
  Future<void> _clearCache() async {
    await widget.store.cache.clear();
    if (mounted) {
      setState(() => _cacheEpoch++);
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
    final ProviderStore? aiStore = widget.aiStore;
    return GlassNavScaffold(
      appBar: GlassTopBar(
        title: const Text('在线 TTS'),
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
            _buildModeGroup(),
            if (_mode == OnlineTtsMode.urlTemplate) ...<Widget>[
              _buildTemplateGroup(),
            ] else ...<Widget>[
              _buildOpenAiGroup(aiStore),
              _buildKeyGroup(),
            ],
            _buildGeneralGroup(),
            _buildCacheGroup(),
            _buildHintGroup(),
          ],
        ),
      ),
    );
  }

  /// 「模式」组：URL 模板 / OpenAI 兼容二选一。
  Widget _buildModeGroup() {
    return SettingsGroupCard(
      header: '模式',
      footer: 'URL 模板适合自建 / 第三方朗读接口；OpenAI 兼容走 audio/speech 端点，可复用 AI 的地址与密钥。',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ChoiceChip(
                key: const Key('tts-online-mode-url'),
                label: Text(OnlineTtsMode.urlTemplate.label),
                selected: _mode == OnlineTtsMode.urlTemplate,
                onSelected: (_) => setState(() => _mode = OnlineTtsMode.urlTemplate),
              ),
              ChoiceChip(
                key: const Key('tts-online-mode-openai'),
                label: Text(OnlineTtsMode.openaiSpeech.label),
                selected: _mode == OnlineTtsMode.openaiSpeech,
                onSelected: (_) =>
                    setState(() => _mode = OnlineTtsMode.openaiSpeech),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 「URL 模板」组：模板 + 编码 + 请求头。
  Widget _buildTemplateGroup() {
    return SettingsGroupCard(
      header: 'URL 模板',
      footer: '{text} 会被替换为朗读文本（按所选编码百分号编码）；每行一个请求头。',
      children: <Widget>[
        _field('URL 模板', _urlTemplate, hint: 'https://example.com/tts?q={text}'),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '编码',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    key: const Key('tts-online-enc-utf8'),
                    label: Text(OnlineTtsEncoding.utf8.label),
                    selected: _encoding == OnlineTtsEncoding.utf8,
                    onSelected: (_) =>
                        setState(() => _encoding = OnlineTtsEncoding.utf8),
                  ),
                  ChoiceChip(
                    key: const Key('tts-online-enc-gbk'),
                    label: Text(OnlineTtsEncoding.gbk.label),
                    selected: _encoding == OnlineTtsEncoding.gbk,
                    onSelected: (_) =>
                        setState(() => _encoding = OnlineTtsEncoding.gbk),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        _field(
          '请求头（每行「名称: 值」，可选）',
          _headers,
          hint: 'Authorization: Bearer xxx',
          maxLines: 4,
        ),
      ],
    );
  }

  /// 「OpenAI 兼容」组：地址 / 模型 / 音色 / 格式 + 导入入口。
  Widget _buildOpenAiGroup(ProviderStore? aiStore) {
    return SettingsGroupCard(
      header: 'OpenAI 兼容',
      footer: '请求 POST {Base URL}/audio/speech；语速跟随朗读设置的语速滑块。',
      children: <Widget>[
        _field('Base URL', _baseUrl, hint: 'https://api.openai.com/v1'),
        const Divider(height: 1),
        _field('模型', _model, hint: OnlineTtsConfig.defaultModel),
        const Divider(height: 1),
        _field('音色', _voice, hint: OnlineTtsConfig.defaultVoice),
        const Divider(height: 1),
        _field('音频格式', _format, hint: OnlineTtsConfig.defaultFormat),
        if (aiStore != null) ...<Widget>[
          const Divider(height: 1),
          SettingsTile(
            key: const Key('tts-online-import-ai'),
            icon: Icons.plagiarism_outlined,
            accent: SettingsAccents.blue,
            title: '从 AI 配置导入',
            subtitle: aiStore.configs.isEmpty
                ? '尚未配置 AI 服务（先在 AI 设置中添加）'
                : '复用所选配置的地址与密钥',
            onTap: aiStore.configs.isEmpty ? null : _importFromAi,
          ),
        ],
      ],
    );
  }

  /// 「API Key」组（OpenAI 模式；不回显，`DATA-02`）。
  Widget _buildKeyGroup() {
    return SettingsGroupCard(
      header: 'API Key',
      footer: _hasStoredKey
          ? '已保存密钥；输入框留空则保持不变。密钥不进备份、不进日志。'
          : widget.store.keySecurityNotice,
      children: <Widget>[
        _field(
          'API Key',
          _apiKey,
          hint: _hasStoredKey ? '••••（留空保持不变）' : 'sk-…',
          obscure: true,
        ),
      ],
    );
  }

  /// 「通用」组：超时。
  Widget _buildGeneralGroup() {
    return SettingsGroupCard(
      header: '通用',
      children: <Widget>[
        _field('超时（秒）', _timeout, hint: '60', numeric: true),
      ],
    );
  }

  /// 「音频缓存」组：计数 + 清理（`TTS-07` ②）。
  Widget _buildCacheGroup() {
    return SettingsGroupCard(
      header: '音频缓存',
      footer: '同一段文本二次朗读直接命中本地音频，不重复请求。',
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.library_music_outlined),
          title: const Text('清理音频缓存'),
          subtitle: FutureBuilder<int>(
            key: Key('tts-online-cache-count-$_cacheEpoch'),
            future: widget.store.cache.count(),
            builder: (BuildContext context, AsyncSnapshot<int> snap) {
              final int? n = snap.data;
              if (n == null) return const Text('统计中…');
              return Text('已缓存 $n 段音频');
            },
          ),
          trailing: TextButton(
            key: const Key('tts-online-clear-cache'),
            onPressed: _clearCache,
            child: const Text('清理'),
          ),
        ),
      ],
    );
  }

  /// 页脚提示卡：引擎切换入口在朗读设置面板。
  Widget _buildHintGroup() {
    return SettingsGroupCard(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Text(
            '保存后，在阅读页「朗读设置」里把引擎切到「在线 TTS」即可生效。',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 单字段行（label 小字 + 无边框 TextField；同 `AI-01` 编辑页口径）。
  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
    bool numeric = false,
    int maxLines = 1,
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
            maxLines: maxLines,
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
