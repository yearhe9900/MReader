// 在线 TTS 引擎（`TTS-07`，M3-T09）：URL 模板 / OpenAI 兼容 `audio/speech`
// 双模式取音频 → 本地缓存 → 文件播放。
//
// 验收映射（PRD `TTS-07`）：
//   ① 配置后能播放：[OnlineTts.speak] 取到音频（缓存或网络）后交
//      [TtsAudioPlayer] 播放，播完回 `done` 让 controller 推进下一段；
//   ② 同一段文本二次朗读命中音频缓存：[buildCacheKey] 请求指纹 →
//      [TtsAudioCache] 文件命中即不再发请求；
//   ③ 失败重试有限次后自动暂停并提示：可重试错误（超时 / 断连 / 5xx /
//      429）最多 [maxAttempts] 次，仍失败回 `error` → controller
//      `pauseOnError` 挂起会话（留位当前段）+ UI toast（`tts_controller.dart`）。
//
// 依赖策略：HTTP 走 `dart:io` HttpClient（同 `ai_client.dart`，不加网络依赖）；
// 播放加 `audioplayers`（PRD §15.4「音频播放插件」，官方自带 Windows / Linux
// 实现）。**「流式播放」口径**：先整段下载入缓存、再从本地文件播放（验收
// ①② 的最短路径）；边下边播属增强项，未实现——不宣称支持。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';

import '../ai/secure_key_store.dart';
import '../platform/secure_store_io.dart';
import '../storage/atomic_file.dart';
import '../storage/json_store.dart';
import 'audio_cache.dart';
import 'tts_engine.dart';

/// 在线 TTS 请求形态（PRD §9.1「URL 模板或 OpenAI 兼容 `audio/speech`」）。
enum OnlineTtsMode {
  /// 自定义 URL 模板（GET，`{text}` 占位）。
  urlTemplate('URL 模板'),

  /// OpenAI 兼容 `POST {baseUrl}/audio/speech`（PRD §8.2「TTS 复用」）。
  openaiSpeech('OpenAI 兼容');

  const OnlineTtsMode(this.label);

  /// 中文展示名。
  final String label;

  /// 由持久化解析；未知值回落 URL 模板。
  static OnlineTtsMode tryParse(String? name) {
    for (final OnlineTtsMode m in OnlineTtsMode.values) {
      if (m.name == name) return m;
    }
    return OnlineTtsMode.urlTemplate;
  }
}

/// `{text}` 占位的百分号编码字符集（`TTS-07`「编码」）。
enum OnlineTtsEncoding {
  /// UTF-8（默认）。
  utf8('UTF-8'),

  /// GBK（部分国产老接口要求；经 `charset` 包编码）。
  gbk('GBK');

  const OnlineTtsEncoding(this.label);

  /// 中文展示名。
  final String label;

  /// 由持久化解析；未知值回落 UTF-8。
  static OnlineTtsEncoding tryParse(String? name) {
    for (final OnlineTtsEncoding e in OnlineTtsEncoding.values) {
      if (e.name == name) return e;
    }
    return OnlineTtsEncoding.utf8;
  }
}

/// 文本按 [encoding] 转字节后做百分号编码（只保留 RFC 3986 unreserved）。
///
/// GBK 不可映射字符（如 emoji）由 `charset` 编码器给替换单字节；真正抛
/// 异常的极端输入回退 UTF-8——**绝不抛异常**（一个字符不炸整段朗读）。
String percentEncodeText(String text, OnlineTtsEncoding encoding) {
  List<int> bytes;
  if (encoding == OnlineTtsEncoding.gbk) {
    try {
      bytes = gbk.encode(text);
    } catch (_) {
      bytes = utf8.encode(text);
    }
  } else {
    bytes = utf8.encode(text);
  }
  final StringBuffer out = StringBuffer();
  for (final int b in bytes) {
    final bool unreserved = (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        (b >= 0x30 && b <= 0x39) ||
        b == 0x2D ||
        b == 0x5F ||
        b == 0x2E ||
        b == 0x7E;
    if (unreserved) {
      out.writeCharCode(b);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// 解析多行「名称: 值」请求头文本（设置页输入形态）。
///
/// 空文本 = 空头；任一行缺冒号或名称为空 → [error] 给面向用户的中文提示。
({Map<String, String> headers, String? error}) parseHeaderLines(String raw) {
  final Map<String, String> headers = <String, String>{};
  for (final String line in raw.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final int colon = trimmed.indexOf(':');
    if (colon <= 0) {
      return (
        headers: const <String, String>{},
        error: '请求头每行需为「名称: 值」格式',
      );
    }
    headers[trimmed.substring(0, colon).trim()] =
        trimmed.substring(colon + 1).trim();
  }
  return (headers: headers, error: null);
}

/// [parseHeaderLines] 的逆变换（编辑页回显）。
String formatHeaderLines(Map<String, String> headers) =>
    headers.entries.map((MapEntry<String, String> e) => '${e.key}: ${e.value}').join('\n');

/// 一次在线 TTS 请求的三要素。
typedef OnlineTtsRequest = ({
  Uri uri,
  Map<String, String> headers,
  List<int>? body,
});

/// 在线 TTS 配置值对象（不可变；`TTS-07`「URL 模板 + 请求头 + 编码」）。
class OnlineTtsConfig {
  /// 创建配置（默认 = 未配置的 URL 模板模式）。
  const OnlineTtsConfig({
    this.mode = OnlineTtsMode.urlTemplate,
    this.urlTemplate = '',
    this.headers = const <String, String>{},
    this.textEncoding = OnlineTtsEncoding.utf8,
    this.baseUrl = '',
    this.model = defaultModel,
    this.voice = defaultVoice,
    this.audioFormat = defaultFormat,
    this.timeoutSeconds = defaultTimeoutSeconds,
  });

  /// OpenAI 兼容默认模型。
  static const String defaultModel = 'tts-1';

  /// OpenAI 兼容默认音色。
  static const String defaultVoice = 'alloy';

  /// 默认音频格式。
  static const String defaultFormat = 'mp3';

  /// 默认超时（秒）。
  static const int defaultTimeoutSeconds = 60;

  /// 请求形态。
  final OnlineTtsMode mode;

  /// URL 模板（[OnlineTtsMode.urlTemplate]；须含 `{text}`）。
  final String urlTemplate;

  /// 附加请求头（两种模式通用；凭据只在 `Authorization` 或服务方指定头）。
  final Map<String, String> headers;

  /// `{text}` 百分号编码字符集（`TTS-07`「编码」）。
  final OnlineTtsEncoding textEncoding;

  /// OpenAI 兼容 base URL（如 `https://api.openai.com/v1`）。
  final String baseUrl;

  /// OpenAI 兼容模型名。
  final String model;

  /// 音色名。
  final String voice;

  /// 返回音频格式（`response_format` / 端点约定）。
  final String audioFormat;

  /// 请求超时（秒）。
  final int timeoutSeconds;

  /// 复制并覆盖部分字段。
  OnlineTtsConfig copyWith({
    OnlineTtsMode? mode,
    String? urlTemplate,
    Map<String, String>? headers,
    OnlineTtsEncoding? textEncoding,
    String? baseUrl,
    String? model,
    String? voice,
    String? audioFormat,
    int? timeoutSeconds,
  }) {
    return OnlineTtsConfig(
      mode: mode ?? this.mode,
      urlTemplate: urlTemplate ?? this.urlTemplate,
      headers: headers ?? this.headers,
      textEncoding: textEncoding ?? this.textEncoding,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      voice: voice ?? this.voice,
      audioFormat: audioFormat ?? this.audioFormat,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    );
  }

  /// 落盘 JSON（等于默认值的键省略，同 `TtsSettings` 最小形态）。
  Map<String, Object?> toJson() => <String, Object?>{
        if (mode != OnlineTtsMode.urlTemplate) 'mode': mode.name,
        if (urlTemplate.isNotEmpty) 'urlTemplate': urlTemplate,
        if (headers.isNotEmpty) 'headers': headers,
        if (textEncoding != OnlineTtsEncoding.utf8)
          'textEncoding': textEncoding.name,
        if (baseUrl.isNotEmpty) 'baseUrl': baseUrl,
        if (model != defaultModel) 'model': model,
        if (voice != defaultVoice) 'voice': voice,
        if (audioFormat != defaultFormat) 'audioFormat': audioFormat,
        if (timeoutSeconds != defaultTimeoutSeconds)
          'timeoutSeconds': timeoutSeconds,
      };

  /// 由持久化 JSON 还原；字段缺失 / 类型异常逐项回退默认值。
  static OnlineTtsConfig fromJson(Object? json) {
    if (json is! Map) return const OnlineTtsConfig();
    final Object? rawMode = json['mode'];
    final Object? rawTemplate = json['urlTemplate'];
    final Object? rawEnc = json['textEncoding'];
    final Object? rawBaseUrl = json['baseUrl'];
    final Object? rawModel = json['model'];
    final Object? rawVoice = json['voice'];
    final Object? rawFormat = json['audioFormat'];
    final Object? rawTimeout = json['timeoutSeconds'];
    final Map<String, String> headers = <String, String>{};
    final Object? rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((Object? k, Object? v) {
        if (k is String && v is String) headers[k] = v;
      });
    }
    return OnlineTtsConfig(
      mode: OnlineTtsMode.tryParse(rawMode is String ? rawMode : null),
      urlTemplate: rawTemplate is String ? rawTemplate : '',
      headers: headers,
      textEncoding:
          OnlineTtsEncoding.tryParse(rawEnc is String ? rawEnc : null),
      baseUrl: rawBaseUrl is String ? rawBaseUrl : '',
      model: rawModel is String && rawModel.isNotEmpty
          ? rawModel
          : defaultModel,
      voice:
          rawVoice is String && rawVoice.isNotEmpty ? rawVoice : defaultVoice,
      audioFormat: rawFormat is String && rawFormat.isNotEmpty
          ? rawFormat
          : defaultFormat,
      timeoutSeconds: rawTimeout is num && rawTimeout > 0
          ? rawTimeout.toInt()
          : defaultTimeoutSeconds,
    );
  }

  /// 保存前校验；通过返 `null`，否则返**面向用户的中文错误**。
  String? validate() {
    if (mode == OnlineTtsMode.urlTemplate) {
      final String template = urlTemplate.trim();
      if (template.isEmpty) return '请填写 URL 模板';
      if (!template.contains('{text}')) return 'URL 模板需包含 {text} 占位符';
      final Uri? probe = Uri.tryParse(template.replaceAll('{text}', 'x'));
      if (probe == null ||
          !probe.isAbsolute ||
          (probe.scheme != 'http' && probe.scheme != 'https')) {
        return 'URL 模板需为完整的 http(s) 地址（如 https://example.com/tts?q={text}）';
      }
    } else {
      final String base = baseUrl.trim();
      final Uri? uri = Uri.tryParse(base);
      if (base.isEmpty ||
          uri == null ||
          !uri.isAbsolute ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        return 'Base URL 需为完整的 http(s) 地址（如 https://api.openai.com/v1）';
      }
      if (model.trim().isEmpty) return '请填写模型名';
      if (voice.trim().isEmpty) return '请填写音色';
    }
    if (timeoutSeconds <= 0) return '超时需为正整数秒';
    return null;
  }

  /// 语速（flutter_tts 口径 0.5 = 正常速）→ OpenAI `speed`（0.25~4.0）。
  static double speedForRate(double rate) {
    if (rate.isNaN || rate.isInfinite) return 1.0;
    return (rate / 0.5).clamp(0.25, 4.0);
  }

  /// 组装请求（校验由 [validate] 前置；`{text}` 按 [textEncoding] 编码）。
  OnlineTtsRequest buildRequest({
    required String text,
    required double rate,
    String? apiKey,
  }) {
    if (mode == OnlineTtsMode.urlTemplate) {
      final String url =
          urlTemplate.replaceAll('{text}', percentEncodeText(text, textEncoding));
      return (uri: Uri.parse(url), headers: headers, body: null);
    }
    final String base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return (
      uri: Uri.parse('$base/audio/speech'),
      headers: <String, String>{
        ...headers,
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: utf8.encode(jsonEncode(<String, Object?>{
        'model': model.trim(),
        'voice': voice.trim(),
        'input': text,
        'response_format': audioFormat,
        'speed': speedForRate(rate),
      })),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineTtsConfig &&
      other.mode == mode &&
      other.urlTemplate == urlTemplate &&
      _mapEq(other.headers, headers) &&
      other.textEncoding == textEncoding &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.voice == voice &&
      other.audioFormat == audioFormat &&
      other.timeoutSeconds == timeoutSeconds;

  @override
  int get hashCode => Object.hash(
        mode,
        urlTemplate,
        Object.hashAllUnordered(headers.entries
            .map((MapEntry<String, String> e) => Object.hash(e.key, e.value))),
        textEncoding,
        baseUrl,
        model,
        voice,
        audioFormat,
        timeoutSeconds,
      );

  static bool _mapEq(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, String> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}

/// 在线 TTS 配置持久化 + 音频缓存门面（进程内共享，显式注入）。
///
/// 与 [TtsSettingsStore] 同一形制（`JsonStore` → `AtomicFile` + 监听回调）；
/// **apiKey 不进配置 JSON**（`DATA-02`）：经 [AiKeyVault]（SecureStore）按固定
/// id 挂靠，落盘文件里搜不到密钥。
class OnlineTtsStore {
  /// 创建存储（`dataDir` 通常来自 `AppPaths.dataDir()`）。
  OnlineTtsStore(Directory dataDir)
      : _store = JsonStore(
          AtomicFile(
            '${dataDir.path}${Platform.pathSeparator}online_tts.json',
          ),
        ),
        _vault = AiKeyVault(FileSecureStore(directory: dataDir)),
        cache = TtsAudioCache(
          Directory('${dataDir.path}${Platform.pathSeparator}tts_audio'),
        );

  /// 密钥挂靠 id（`AiKeyVault` 命名空间内稳定）。
  static const String configId = 'online-tts';

  final JsonStore _store;
  final AiKeyVault _vault;

  /// 音频缓存（`TTS-07` ②；目录 `<dataDir>/tts_audio`）。
  final TtsAudioCache cache;

  OnlineTtsConfig _value = const OnlineTtsConfig();
  bool _loaded = false;
  final List<void Function()> _listeners = <void Function()>[];

  /// 当前配置（只读快照）。未 [load] 时返回默认值。
  OnlineTtsConfig get value => _value;

  /// 是否已完成一次加载。
  bool get isLoaded => _loaded;

  /// 密钥是否真安全存储（`DATA-02` ③ 明文标注）。
  bool get keyIsSecure => _vault.isSecure;

  /// 明文存储时的用户告知文案。
  String get keySecurityNotice => _vault.securityNotice;

  /// 从磁盘加载；文件缺失或损坏回退默认值。
  Future<void> load() async {
    final Object? json = await _store.read();
    _value = OnlineTtsConfig.fromJson(json);
    _loaded = true;
    _notify();
  }

  /// 保存配置（等值短路 → 不落盘）。
  Future<void> setConfig(OnlineTtsConfig next) async {
    if (next == _value) return;
    _value = next;
    _notify();
    await _store.write(next.toJson());
  }

  /// 读 API Key（OpenAI 兼容模式）；未配置返 `null`。
  Future<String?> readApiKey() => _vault.read(configId);

  /// 写 API Key（空串 = 删除）。
  Future<void> writeApiKey(String apiKey) => _vault.write(configId, apiKey);

  /// 订阅配置变更。
  void addListener(void Function() listener) => _listeners.add(listener);

  /// 退订配置变更。
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

/// 播放抽象：完成回调驱动引擎结局（同 flutter_tts completion 语义）。
abstract class TtsAudioPlayer {
  /// 播放本地音频文件；自然播完调 [onDone]。
  Future<void> play(File file, {required void Function() onDone});

  /// 停止播放（不回调 [onDone]）。
  Future<void> stop();

  /// 释放平台资源。
  Future<void> dispose();
}

/// `audioplayers` 实现（PRD §15.4「音频播放插件」）。
class AudioplayersAudioPlayer implements TtsAudioPlayer {
  /// 创建播放器并订阅播完事件。
  AudioplayersAudioPlayer() {
    _subscription = _player.onPlayerComplete.listen((_) {
      final void Function()? callback = _onDone;
      _onDone = null;
      callback?.call();
    });
  }

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _subscription;
  void Function()? _onDone;

  @override
  Future<void> play(File file, {required void Function() onDone}) async {
    // 换段：先停掉上一段（stop 不触发 onPlayerComplete），再挂新回调。
    await _player.stop();
    _onDone = onDone;
    await _player.play(DeviceFileSource(file.path));
  }

  @override
  Future<void> stop() async {
    _onDone = null;
    try {
      await _player.stop();
    } catch (_) {
      // 平台侧未初始化时的空闲停止按无操作处理。
    }
  }

  @override
  Future<void> dispose() async {
    _onDone = null;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _player.dispose();
    } catch (_) {}
  }
}

/// 在线 TTS：HTTP 取音频（带缓存与有限重试）→ 本地文件播放。
///
/// [TtsEngine] 契约内的结局映射：播完 `done`；[stop] 或换段作废 `cancelled`；
/// 重试耗尽 / 配置无效 / 非可重试 HTTP 状态 `error`（controller 据
/// `pauseOnError` 自动暂停并提示，`TTS-07` ③）。
class OnlineTts implements TtsEngine {
  /// 用配置存储构造；[player] / [client] 可注入（测试用假播放器）。
  OnlineTts(this.store, {TtsAudioPlayer? player, HttpClient? client})
      : _player = player ?? AudioplayersAudioPlayer() {
    _client = client;
  }

  /// 单段最多尝试次数（含首次；`TTS-07` ③「有限次」）。
  static const int maxAttempts = 3;

  /// 配置存储（每段取最新值——配置页改动即时生效）。
  final OnlineTtsStore store;

  final TtsAudioPlayer _player;
  HttpClient? _client;

  /// 在途 speak 的完结器（同一时刻至多一段在读，同 [SystemTts]）。
  Completer<TtsSpeakResult>? _pending;

  /// 当前语速（flutter_tts 口径；OpenAI 模式转 `speed`，模板模式忽略）。
  double _rate = TtsDefaults.normalRate;

  @override
  Future<bool> init() async {
    // 配置随时可改：**不缓存**探测结果（controller 的 `_inited` 由调用方
    // 在失败后丢弃控制器重建，见 `ReaderPage._toggleTts`）。
    if (!store.isLoaded) await store.load();
    return store.value.validate() == null;
  }

  @override
  Future<TtsSpeakResult> speak(String text) async {
    final Completer<TtsSpeakResult> completer = Completer<TtsSpeakResult>();
    _finish(_pending, TtsSpeakResult.cancelled); // 作废上一段结局
    _pending = completer;
    try {
      final File? file = await _fetch(text);
      // 已被 stop / 换段作废 → 不再播（结局由作废方填，此处落到末行回读）。
      if (identical(_pending, completer)) {
        if (file == null) {
          _finish(completer, TtsSpeakResult.error);
        } else {
          await _player.play(
            file,
            onDone: () => _finish(completer, TtsSpeakResult.done),
          );
        }
      }
    } catch (_) {
      _finish(completer, TtsSpeakResult.error);
    }
    return completer.future;
  }

  @override
  Future<void> stop() async {
    _finish(_pending, TtsSpeakResult.cancelled);
    await _player.stop();
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
  }

  /// 在线音色在配置页配置，不走引擎查询 → 空列表（面板隐藏音色区，
  /// 同系统引擎无实现平台的诚实降级口径）。
  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];

  @override
  Future<void> setVoice(TtsVoice? voice) async {
    // 音色由配置页写入 config.voice，此处无操作。
  }

  /// 释放播放器与自有 HTTP 客户端（换引擎 / 关页时调用）。
  Future<void> dispose() async {
    _finish(_pending, TtsSpeakResult.cancelled);
    await _player.dispose();
    _client?.close(force: true);
    _client = null;
  }

  /// 按 [_rate] 当前值 + 配置指纹 + 文本 生成缓存键（sha256 hex）。
  ///
  /// apiKey **不进指纹**（同一服务同一文本的音频与密钥无关）。
  static String buildCacheKey(
    OnlineTtsConfig config, {
    required double rate,
    required String text,
  }) {
    final StringBuffer buf = StringBuffer()
      ..write(config.mode.name)
      ..write('|')
      ..write(config.urlTemplate)
      ..write('|')
      ..write(config.baseUrl)
      ..write('|')
      ..write(config.model)
      ..write('|')
      ..write(config.voice)
      ..write('|')
      ..write(config.audioFormat)
      ..write('|')
      ..write(config.textEncoding.name)
      ..write('|')
      ..write(config.mode == OnlineTtsMode.openaiSpeech
          ? OnlineTtsConfig.speedForRate(rate)
          : '')
      ..write('|');
    final List<String> keys = config.headers.keys.toList()..sort();
    for (final String k in keys) {
      buf
        ..write(k)
        ..write(':')
        ..write(config.headers[k])
        ..write('\n');
    }
    buf.write(text);
    return sha256.convert(utf8.encode(buf.toString())).toString();
  }

  /// 取音频：缓存命中直接回；未命中带重试请求并落缓存。
  ///
  /// 返回 `null` = 重试耗尽或非可重试失败（调用方回 `error` 结局）。
  Future<File?> _fetch(String text) async {
    final OnlineTtsConfig config = store.value;
    if (config.validate() != null) return null;
    final String key = buildCacheKey(config, rate: _rate, text: text);
    final File? hit = await store.cache.find(key);
    if (hit != null) return hit;
    final String? apiKey = config.mode == OnlineTtsMode.openaiSpeech
        ? await store.readApiKey()
        : null;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final _HttpResult result = await _send(config, text, apiKey)
            .timeout(Duration(seconds: config.timeoutSeconds));
        if (result.status == 200 && result.bytes.isNotEmpty) {
          await store.cache.store(key, result.bytes);
          return await store.cache.find(key);
        }
        // 4xx（除 429）为不可重试：立即失败（同 `AI-08` 分类口径）。
        if (!_isRetryableStatus(result.status) || attempt == maxAttempts) {
          return null;
        }
      } catch (_) {
        // 超时 / 断连可重试；末次仍失败 → 放弃。
        if (attempt == maxAttempts) return null;
      }
      await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
    }
    return null;
  }

  static bool _isRetryableStatus(int status) => status >= 500 || status == 429;

  Future<_HttpResult> _send(
    OnlineTtsConfig config,
    String text,
    String? apiKey,
  ) async {
    final OnlineTtsRequest request =
        config.buildRequest(text: text, rate: _rate, apiKey: apiKey);
    final HttpClient client = _client ??= HttpClient();
    final HttpClientRequest req = request.body == null
        ? await client.getUrl(request.uri)
        : await client.postUrl(request.uri);
    request.headers.forEach(req.headers.set);
    if (request.body != null) {
      req.headers.contentType = ContentType.json;
      req.add(request.body!);
    }
    final HttpClientResponse response = await req.close();
    final List<int> bytes = await response.fold<List<int>>(
      <int>[],
      (List<int> acc, List<int> chunk) => acc..addAll(chunk),
    );
    return _HttpResult(response.statusCode, Uint8List.fromList(bytes));
  }

  void _finish(Completer<TtsSpeakResult>? expected, TtsSpeakResult result) {
    final Completer<TtsSpeakResult>? pending = _pending;
    if (pending == null || !identical(pending, expected) || pending.isCompleted) {
      return;
    }
    _pending = null;
    pending.complete(result);
  }
}

/// 默认语速常量（0.5 = 正常速，与 `TtsSettings.defaultRate` 同值；
/// 独立声明避免引擎层反向依赖设置存储）。
abstract final class TtsDefaults {
  /// 正常速（flutter_tts 口径）。
  static const double normalRate = 0.5;
}

/// HTTP 响应（状态码 + 全量字节）。
class _HttpResult {
  const _HttpResult(this.status, this.bytes);

  final int status;
  final Uint8List bytes;
}
