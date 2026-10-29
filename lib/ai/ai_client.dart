// AI 通用客户端底座（PRD `AI-08` 流式 / 可取消 / 可重试 / 并发上限 / 错误分类）。
//
// 依赖策略：只用 `dart:io` HttpClient（SSE 自解析），**不加 pubspec 依赖**——
// 全仓 lib 无既有 HTTP 层，这里是唯一出口，六个 AI 功能共用。
//
// 职责边界（底座一次做对，功能层不再各写一套）：流式（POST
// {baseUrl}/chat/completions，stream:true，逐 delta yield 文本）；可取消
// （[AiCall.cancel] → abort + 关流，`AI-08` ①）；错误分类（[AiErrorKind]
// 区分 401/404/超时/网络不可达等可读错误，`AI-01` ②；[AiException.retryable]
// 只标「超时 / 网络 / 5xx」，401·404 不可重试，重试由 UI 一键触发、**不自动
// 重试**以免放大配额消耗）；并发闸上限 2 超出排队（`AI-08` ③ 快速连点不并发
// 多请求）；连接超时 + 事件间隔超时均取 config.timeoutSeconds（默认 60）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'provider_config.dart';

/// 可读错误分类（`AI-01` ②：区分 401 / 404 / 超时 / 网络不可达）。
enum AiErrorKind {
  /// 401 / 403：密钥无效或无权限（不可重试）。
  unauthorized,

  /// 404：接口地址不存在（不可重试，提示查 Base URL）。
  notFound,

  /// 400 / 422：请求被服务端拒绝（不可重试，回显服务端说明）。
  badRequest,

  /// 5xx：服务端错误（可重试）。
  server,

  /// 连接失败 / DNS / 断网（可重试）。
  network,

  /// 连接或事件间隔超时（可重试）。
  timeout,

  /// 用户主动取消（不重试）。
  cancelled,

  /// 其余未归类（不可重试）。
  unknown,
}

/// AI 调用异常：带分类 + 状态码 + 是否可重试 + 中文可读信息。
class AiException implements Exception {
  AiException(this.kind, {this.statusCode, String? message})
      : message = message ?? _defaultMessage(kind, statusCode);

  final AiErrorKind kind;
  final int? statusCode;

  /// 中文可读信息（直接回显给用户）。
  final String message;

  /// 仅超时 / 网络 / 5xx 可重试（`AI-08`：401·404 不可重试）。
  bool get retryable =>
      kind == AiErrorKind.timeout ||
      kind == AiErrorKind.network ||
      kind == AiErrorKind.server;

  static String _defaultMessage(AiErrorKind kind, int? status) {
    return switch (kind) {
      AiErrorKind.unauthorized => 'API Key 无效或无权限（${status ?? 401}）',
      AiErrorKind.notFound => '接口地址不存在（404），请检查 Base URL',
      AiErrorKind.badRequest => '请求被拒绝（${status ?? 400}）',
      AiErrorKind.server => '服务端错误（${status ?? 500}）',
      AiErrorKind.network => '网络不可达，请检查网络连接',
      AiErrorKind.timeout => '请求超时',
      AiErrorKind.cancelled => '已取消',
      AiErrorKind.unknown => '请求失败',
    };
  }

  @override
  String toString() => 'AiException($kind, $statusCode): $message';
}

/// 一条对话消息。
class AiMessage {
  const AiMessage(this.role, this.content);

  /// `system` / `user` / `assistant`。
  final String role;
  final String content;

  Map<String, Object?> toJson() => <String, Object?>{'role': role, 'content': content};
}

/// 一次可取消的流式调用句柄。
class AiCall {
  AiCall(this.stream, this._cancel);

  /// 增量文本流（错误以 [AiException] 走 onError；取消则静默 close）。
  final Stream<String> stream;

  final void Function() _cancel;

  /// 中止调用（`AI-08` ① 任一功能可中途取消）。幂等。
  void cancel() => _cancel();
}

/// OpenAI 兼容 chat 客户端（进程内共享，显式注入）。
class AiClient {
  AiClient({HttpClient? httpClient, int maxConcurrent = 2})
      : _http = httpClient ?? HttpClient(),
        _maxConcurrent = maxConcurrent.clamp(1, 2);

  final HttpClient _http;
  final int _maxConcurrent;

  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 流式对话。返回句柄即可增量消费 + 随时 cancel。
  AiCall chatStream({
    required AiProviderConfig config,
    required String apiKey,
    required List<AiMessage> messages,
    Map<String, String>? extraBody,
  }) {
    final StreamController<String> controller = StreamController<String>();
    bool cancelled = false;
    HttpClientRequest? live;

    Future<void> run() async {
      try {
        if (!await _acquire(() => cancelled)) {
          return; // 排队期间已取消。
        }
        try {
          if (cancelled) {
            return;
          }
          final HttpClientRequest request =
              await _openRequest(config, apiKey, stream: true);
          if (cancelled) {
            request.abort();
            return;
          }
          live = request;
          request.add(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'model': config.model,
                'messages': messages.map((AiMessage m) => m.toJson()).toList(),
                'stream': true,
                if (config.maxTokens != null) 'max_tokens': config.maxTokens,
                if (config.temperature != null)
                  'temperature': config.temperature,
                ...?extraBody,
              }),
            ),
          );
          final HttpClientResponse response = await request.close().timeout(
                Duration(seconds: config.timeoutSeconds),
              );
          await _consumeSse(
            response,
            config,
            controller,
            () => cancelled,
          );
        } finally {
          _release();
        }
      } on AiException catch (error) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(error);
        }
      } on TimeoutException {
        if (!cancelled && !controller.isClosed) {
          controller.addError(AiException(AiErrorKind.timeout));
        }
      } on SocketException {
        if (!cancelled && !controller.isClosed) {
          controller.addError(AiException(AiErrorKind.network));
        }
      } on HttpException catch (error) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(
            AiException(AiErrorKind.network, message: '网络传输失败：${error.message}'),
          );
        }
      } catch (error) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(AiException(AiErrorKind.unknown, message: '$error'));
        }
      } finally {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }

    unawaited(run());
    return AiCall(controller.stream, () {
      cancelled = true;
      live?.abort();
      if (!controller.isClosed) {
        controller.close();
      }
    });
  }

  /// 测试连接（`AI-01` ①）：非流式最小请求（max_tokens:1）。
  /// 成功正常返回；失败抛 [AiException]（分类同流式）。
  Future<void> testConnection({
    required AiProviderConfig config,
    required String apiKey,
  }) async {
    if (!await _acquire(() => false)) {
      throw AiException(AiErrorKind.cancelled);
    }
    try {
      final HttpClientRequest request = await _openRequest(
        config,
        apiKey,
        stream: false,
      ).timeout(Duration(seconds: config.timeoutSeconds));
      request.add(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'model': config.model,
            'messages': const <Map<String, Object?>>[
              <String, Object?>{'role': 'user', 'content': 'ping'},
            ],
            'max_tokens': 1,
            'stream': false,
          }),
        ),
      );
      final HttpClientResponse response = await request.close().timeout(
            Duration(seconds: config.timeoutSeconds),
          );
      if (response.statusCode == HttpStatus.ok) {
        await response.drain<void>();
        return;
      }
      throw await _statusError(response, config.timeoutSeconds);
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw AiException(AiErrorKind.timeout);
    } on SocketException {
      throw AiException(AiErrorKind.network);
    } on HttpException catch (error) {
      throw AiException(AiErrorKind.network, message: '网络传输失败：${error.message}');
    }
  }

  // ---------------------------------------------------------------- 内部

  Future<HttpClientRequest> _openRequest(
    AiProviderConfig config,
    String apiKey, {
    required bool stream,
  }) async {
    final HttpClientRequest request = await _http.postUrl(config.chatCompletionsUri);
    request.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    // 自定义头在标准头之后逐项覆盖（允许用户自定义，如组织 ID）。
    config.customHeaders.forEach(request.headers.set);
    request.headers.set('Accept', stream ? 'text/event-stream' : 'application/json');
    _http.connectionTimeout = Duration(seconds: config.timeoutSeconds);
    return request;
  }

  /// 读 SSE 流 → 逐 delta yield；非 2xx 走 [_statusError] 分类。
  Future<void> _consumeSse(
    HttpClientResponse response,
    AiProviderConfig config,
    StreamController<String> controller,
    bool Function() isCancelled,
  ) async {
    if (response.statusCode != HttpStatus.ok) {
      throw await _statusError(response, config.timeoutSeconds);
    }
    await for (final String line in response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(Duration(seconds: config.timeoutSeconds))) {
      if (isCancelled() || controller.isClosed) {
        break;
      }
      if (!line.startsWith('data:')) {
        continue; // event:/注释行忽略。
      }
      final String data = line.substring(5).trim();
      if (data == '[DONE]') {
        break;
      }
      try {
        final Object? decoded = jsonDecode(data);
        if (decoded is Map) {
          final Object? choices = decoded['choices'];
          if (choices is List && choices.isNotEmpty) {
            final Object? first = choices.first;
            if (first is Map) {
              final Object? delta = first['delta'];
              final Object? content = delta is Map ? delta['content'] : null;
              if (content is String && content.isNotEmpty) {
                controller.add(content);
              }
            }
          }
        }
      } catch (_) {
        // 单帧解析失败不中断整流（容错）。
      }
    }
  }

  /// 非 2xx → 分类异常；读 body 提取服务端 error.message 作可读细节。
  Future<AiException> _statusError(HttpClientResponse response, int timeout) async {
    String? detail;
    try {
      final String body = await response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(Duration(seconds: timeout))
          .join('\n');
      final int cut = body.length > 500 ? 500 : body.length;
      final String snippet = body.substring(0, cut);
      try {
        final Object? decoded = jsonDecode(snippet);
        if (decoded is Map && decoded['error'] is Map) {
          final Object? msg = (decoded['error'] as Map)['message'];
          if (msg is String && msg.isNotEmpty) {
            detail = msg;
          }
        }
      } catch (_) {
        detail = snippet.isEmpty ? null : snippet;
      }
    } catch (_) {
      // 读 body 失败不掩盖状态码本身。
    }
    final int code = response.statusCode;
    final AiErrorKind kind = switch (code) {
      HttpStatus.unauthorized || HttpStatus.forbidden => AiErrorKind.unauthorized,
      HttpStatus.notFound => AiErrorKind.notFound,
      HttpStatus.badRequest || 422 => AiErrorKind.badRequest,
      >= 500 => AiErrorKind.server,
      _ => AiErrorKind.unknown,
    };
    final String base = AiException._defaultMessage(kind, code);
    return AiException(
      kind,
      statusCode: code,
      message: detail == null ? base : '$base：$detail',
    );
  }

  /// 并发闸（上限 [_maxConcurrent]，超出排队）。返回 false = 排队期间已取消
  /// （拿到 slot 后才判 → 立即释放移交，不留悬挂 waiter）。
  Future<bool> _acquire(bool Function() isCancelled) async {
    if (isCancelled()) {
      return false;
    }
    if (_active < _maxConcurrent) {
      _active++;
      return true;
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    if (isCancelled()) {
      _release(); // slot 直接移交下一位，不占用。
      return false;
    }
    return true;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(); // slot 直接移交排队者。
    } else {
      _active--;
    }
  }
}
