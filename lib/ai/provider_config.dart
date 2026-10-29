// AI Provider 配置模型（PRD §8.2 / `AI-01`）。
//
// OpenAI 兼容四要素 + 可选扩展（自定义 header / 超时 / 生成参数 / 用途）。
// **`apiKey` 不在本模型内**（`DATA-02`）：配置只描述「连哪里、用什么模型」，
// 密钥经 `AiKeyVault` 走系统安全存储，**不落本文件的 JSON**——备份包 / 配置
// 导出搜不到 Key（`DATA-02` ① 的结构性保证）。

/// 配置用途（PRD §8.2 `useFor`：对话 / 翻译 / 摘要 / 嵌入）。
enum AiUseCase {
  /// 对话（跟书问答等）。
  chat('对话'),

  /// 翻译（划词翻译）。
  translate('翻译'),

  /// 摘要（章节 / 全书摘要）。
  summarize('摘要'),

  /// 嵌入（向量检索预留；当前 BM25 链路不发）。
  embed('嵌入');

  const AiUseCase(this.label);

  /// 中文展示名。
  final String label;

  /// 由持久化解析；未知值返 `null`（逐项容错）。
  static AiUseCase? tryParse(String? name) {
    for (final AiUseCase c in AiUseCase.values) {
      if (c.name == name) {
        return c;
      }
    }
    return null;
  }
}

/// 一套 OpenAI 兼容 Provider 配置（不可变值对象）。
class AiProviderConfig {
  AiProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.customHeaders = const <String, String>{},
    this.timeoutSeconds = defaultTimeoutSeconds,
    this.maxTokens,
    this.temperature,
    this.useFor = const <AiUseCase>{},
  });

  /// 默认超时（秒，PRD §8.2）。
  static const int defaultTimeoutSeconds = 60;

  /// 稳定 id（新建时派生；编辑不变——密钥按 id 挂靠）。
  final String id;

  /// 配置名（如「自建 One-API」「DeepSeek」）。
  final String name;

  /// OpenAI 兼容 base URL（如 `https://api.deepseek.com/v1`）。
  final String baseUrl;

  /// 模型名。
  final String model;

  /// 自定义请求头（部分中转需额外头；**不得**放凭据——凭据只在 `Authorization`）。
  final Map<String, String> customHeaders;

  /// 超时（秒）。
  final int timeoutSeconds;

  /// `max_tokens`；`null` = 不传（由服务端默认）。
  final int? maxTokens;

  /// `temperature`；`null` = 不传（由服务端默认）。
  final double? temperature;

  /// 该配置用于哪些功能（空 = 暂不承担任何功能）。
  final Set<AiUseCase> useFor;

  AiProviderConfig copyWith({
    String? name,
    String? baseUrl,
    String? model,
    Map<String, String>? customHeaders,
    int? timeoutSeconds,
    int? maxTokens,
    double? temperature,
    Set<AiUseCase>? useFor,
    bool clearMaxTokens = false,
    bool clearTemperature = false,
  }) {
    return AiProviderConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      customHeaders: customHeaders ?? this.customHeaders,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      maxTokens: clearMaxTokens ? null : (maxTokens ?? this.maxTokens),
      temperature:
          clearTemperature ? null : (temperature ?? this.temperature),
      useFor: useFor ?? this.useFor,
    );
  }

  /// 落盘 JSON（**不含 apiKey**）。
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'customHeaders': customHeaders,
        'timeoutSeconds': timeoutSeconds,
        if (maxTokens != null) 'maxTokens': maxTokens,
        if (temperature != null) 'temperature': temperature,
        'useFor': <String>[for (final AiUseCase u in useFor) u.name],
      };

  /// 由持久化 JSON 还原；结构异常返 `null`（坏条目由 store 跳过）。
  static AiProviderConfig? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? name = json['name'];
    final Object? baseUrl = json['baseUrl'];
    final Object? model = json['model'];
    if (id is! String || id.isEmpty || name is! String || baseUrl is! String || model is! String) {
      return null;
    }
    final Map<String, String> headers = <String, String>{};
    final Object? rawHeaders = json['customHeaders'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((Object? k, Object? v) {
        if (k is String && v is String) {
          headers[k] = v;
        }
      });
    }
    final Set<AiUseCase> useFor = <AiUseCase>{};
    final Object? rawUseFor = json['useFor'];
    if (rawUseFor is List) {
      for (final Object? u in rawUseFor) {
        final AiUseCase? parsed = AiUseCase.tryParse(u is String ? u : null);
        if (parsed != null) {
          useFor.add(parsed);
        }
      }
    }
    final Object? timeout = json['timeoutSeconds'];
    final Object? maxTokens = json['maxTokens'];
    final Object? temperature = json['temperature'];
    return AiProviderConfig(
      id: id,
      name: name,
      baseUrl: baseUrl,
      model: model,
      customHeaders: headers,
      timeoutSeconds: timeout is num && timeout > 0
          ? timeout.toInt()
          : defaultTimeoutSeconds,
      maxTokens: maxTokens is num ? maxTokens.toInt() : null,
      temperature: temperature is num ? temperature.toDouble() : null,
      useFor: useFor,
    );
  }

  /// 保存前校验；通过返 `null`，否则返**面向用户的中文错误**（`AI-01` ②）。
  String? validate() {
    if (name.trim().isEmpty) {
      return '请填写配置名称';
    }
    final Uri? uri = Uri.tryParse(baseUrl.trim());
    if (baseUrl.trim().isEmpty ||
        uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'Base URL 需为完整的 http(s) 地址（如 https://api.deepseek.com/v1）';
    }
    if (model.trim().isEmpty) {
      return '请填写模型名';
    }
    if (timeoutSeconds <= 0) {
      return '超时需为正整数秒';
    }
    if (maxTokens != null && maxTokens! <= 0) {
      return 'max_tokens 需为正整数';
    }
    if (temperature != null && (temperature! < 0 || temperature! > 2)) {
      return 'temperature 取值范围为 0 ~ 2';
    }
    return null;
  }

  /// 实际请求端点：`baseUrl` 去尾斜杠 + `/chat/completions`。
  Uri get chatCompletionsUri {
    final String base =
        baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/chat/completions');
  }

  @override
  bool operator ==(Object other) =>
      other is AiProviderConfig && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
