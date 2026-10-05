// `M4-T01`：WebDAV 同步通道（PRD §10 / `SYNC-01` / `SYNC-07`）。
//
// 依赖策略（与 `ai/ai_client.dart` 同）：只用 `dart:io` HttpClient + `xml` 解析
// PROPFIND multistatus，**不加 http/dio 依赖**。通道只做一遍——T02~T06（进度 /
// 条目 / 备份 / 触发 / 统计）全部复用本类，`STAT-08` 也复用它（PRD §17 明确理由）。
//
// 职责：
//   · PROPFIND / MKCOL / GET / PUT / DELETE + Basic 认证；
//   · 「测试连接」（`SYNC-01` ①②）+ 远端目录**逐级自动创建**（`SYNC-01` ③：
//     目录不存在 → 逐级 MKCOL，已存在 405 视作成功）；
//   · 错误分类（`SYNC-07` 禁止静默失败）：401 / 404 / 网络不可达 / 磁盘满 →
//     中文可读 [SyncException]；`retryable` 只标超时 / 网络 / 5xx（同 `AiException`）。
//
// 路径语义：远端根 = `{config.url}/{config.dir}/`（PRD §10.3），下列方法的
// `under` 均**相对这个根**（如 `bookProgress/书名_作者.json`）；段逐个
// percent-encode，中文书名 / 空格安全。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'sync_config.dart';

/// 可读错误分类（`SYNC-07`：401 / 404 / 网络不可达 / 磁盘满等）。
enum SyncErrorKind {
  /// 401 / 403：凭据无效或无权限（不可重试）。
  unauthorized,

  /// 404：地址 / 路径不存在（不可重试）。
  notFound,

  /// 507：远端磁盘空间不足（不可重试——重试只会再失败）。
  diskFull,

  /// 5xx：服务端错误（可重试）。
  server,

  /// 连接失败 / DNS / 断网（可重试）。
  network,

  /// 连接或响应超时（可重试）。
  timeout,

  /// 用户主动取消（`SYNC-05` ③；不可重试——重试违背取消意图）。
  cancelled,

  /// 其余未归类（不可重试）。
  unknown,
}

/// 同步异常：带分类 + 状态码 + 中文可读信息（直接回显给用户，`SYNC-07`）。
class SyncException implements Exception {
  SyncException(this.kind, {this.statusCode, String? message})
      : message = message ?? _defaultMessage(kind, statusCode);

  /// 错误分类。
  final SyncErrorKind kind;

  /// HTTP 状态码（机制失败为 `null`）。
  final int? statusCode;

  /// 中文可读信息（含服务端返回的错误细节）。
  final String message;

  /// 仅超时 / 网络 / 5xx 可重试（401 · 404 · 507 不可重试）。
  bool get retryable =>
      kind == SyncErrorKind.timeout ||
      kind == SyncErrorKind.network ||
      kind == SyncErrorKind.server;

  static String _defaultMessage(SyncErrorKind kind, int? status) {
    return switch (kind) {
      SyncErrorKind.unauthorized => '账号或密码错误（${status ?? 401}）',
      SyncErrorKind.notFound => '地址不存在（404），请检查服务器地址',
      SyncErrorKind.diskFull => '远端磁盘空间不足（507）',
      SyncErrorKind.server => '服务端错误（${status ?? 500}）',
      SyncErrorKind.network => '网络不可达，请检查网络连接',
      SyncErrorKind.timeout => '连接超时',
      SyncErrorKind.cancelled => '已取消',
      SyncErrorKind.unknown => '同步失败',
    };
  }

  @override
  String toString() => 'SyncException($kind, $statusCode): $message';
}

/// 远端目录项（PROPFIND 结果；[path] 相对远端根，已解码）。
class WebdavEntry {
  /// 创建目录项。
  const WebdavEntry({
    required this.path,
    this.lastModified,
    required this.isCollection,
  });

  /// 相对远端根的路径（根自身为空串；段已 percent-decode）。
  final String path;

  /// `getlastmodified`（RFC1123 → [DateTime]）；解析失败为 `null`。
  final DateTime? lastModified;

  /// 是否为目录（`resourcetype` 含 `collection`）。
  final bool isCollection;
}

/// 大文件传输的取消控制（`SYNC-05` ③；调用方创建并持有，显式传入）。
///
/// 取消是**协作式**的：[WebdavClient.uploadStream] 在分块间、
/// [WebdavClient.downloadToFile] 在事件间检查 [cancelled]，命中即中止并抛
/// `SyncErrorKind.cancelled`（不可重试——重试违背取消意图）。
class TransferControl {
  /// 是否已被取消。
  bool get cancelled => _cancelled;

  /// 请求取消（幂等）。
  void cancel() => _cancelled = true;

  bool _cancelled = false;
}

/// WebDAV 客户端（进程内共享，显式注入；`main()` 组合根构造）。
class WebdavClient {
  /// 创建客户端；[timeoutSeconds] 作用于每个网络阶段（连接 / 响应 / 读体）。
  WebdavClient({HttpClient? httpClient, this.timeoutSeconds = 30})
      : _http = httpClient ?? (HttpClient()..userAgent = 'MReader');

  /// 单阶段超时（秒）。
  final int timeoutSeconds;

  final HttpClient _http;

  /// PROPFIND 请求体（只要 `getlastmodified` + `resourcetype` 两个属性）。
  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:getlastmodified/><d:resourcetype/>'
      '</d:prop></d:propfind>';

  /// 关闭底层连接池（进程退出 / 测试 tearDown 用；幂等）。
  void close() => _http.close(force: true);

  // ───────────────────────────────────────────────────────────────────────────
  // 公开通道（`SYNC-01` + T02~T06 复用面）
  // ───────────────────────────────────────────────────────────────────────────

  /// 测试连接（`SYNC-01` ①②③）：
  ///   ① 对 `config.url` 发 PROPFIND（Depth 0）验证地址与凭据；
  ///   ② 401 / 404 等经 [SyncException] 给出可读中文错误；
  ///   ③ 对远端目录逐级 MKCOL——**目录不存在时自动创建**。
  Future<void> testConnection({
    required SyncConfig config,
    required String password,
  }) async {
    final Uri site = _siteUri(config);
    final ({int status, List<int> body}) resp =
        await _send(config, password, 'PROPFIND', site, depth: '0');
    _ensureOk(resp.status, resp.body);
    await ensureDirectory(config, password);
  }

  /// 从 `config.url` 起逐级创建远端目录（`{url}/{dir}/{under}`；`SYNC-01` ③）。
  ///
  /// 每一级单独 MKCOL：已存在（405）视作成功；逐级创建保证父级总在前面出现，
  /// 因此正常路径不会遇到 409。T02~T04 建 `bookProgress/`、`stats/`、`books/`
  /// 等子目录也走本方法。
  Future<void> ensureDirectory(
    SyncConfig config,
    String password, {
    String under = '',
  }) async {
    final String base = _noSlash(config.url);
    final List<String> segments = <String>[
      ..._segments(config.dir),
      ..._segments(under),
    ];
    String accumulated = '';
    for (final String segment in segments) {
      accumulated = accumulated.isEmpty ? segment : '$accumulated/$segment';
      final ({int status, List<int> body}) resp = await _send(
        config,
        password,
        'MKCOL',
        Uri.parse('$base/$accumulated'),
        depth: '0',
      );
      if (resp.status == HttpStatus.methodNotAllowed) {
        continue; // 目录已存在（`SYNC-01` ③：不存在才创建）。
      }
      _ensureOk(resp.status, resp.body);
    }
  }

  /// 列出 `under` 目录（Depth 1）；404 → [SyncException] `notFound`。
  ///
  /// 返回条目（含目录自身，`path` 为相对远端根的已解码路径）。
  Future<List<WebdavEntry>> list(
    SyncConfig config,
    String password,
    String under,
  ) async {
    final Uri uri = _uri(config, under);
    final ({int status, List<int> body}) resp =
        await _send(config, password, 'PROPFIND', uri, depth: '1');
    _ensureOk(resp.status, resp.body);
    return _parseMultistatus(resp.body, _rootUri(config));
  }

  /// 单项状态（Depth 0）；404 → `null`（不抛——「不存在」是正常查询结果）。
  Future<WebdavEntry?> stat(
    SyncConfig config,
    String password,
    String under,
  ) async {
    final Uri uri = _uri(config, under);
    final ({int status, List<int> body}) resp =
        await _send(config, password, 'PROPFIND', uri, depth: '0');
    if (resp.status == HttpStatus.notFound) {
      return null;
    }
    _ensureOk(resp.status, resp.body);
    final List<WebdavEntry> entries =
        _parseMultistatus(resp.body, _rootUri(config));
    return entries.isEmpty ? null : entries.first;
  }

  /// 下载文件（GET）；404 → [SyncException] `notFound`。
  Future<List<int>> download(
    SyncConfig config,
    String password,
    String under,
  ) async {
    final Uri uri = _uri(config, under);
    final ({int status, List<int> body}) resp =
        await _send(config, password, 'GET', uri);
    _ensureOk(resp.status, resp.body);
    return resp.body;
  }

  /// 上传文件（PUT，整包字节）；大文件 / 取消 / 进度走 [uploadStream]；
  /// 507 → `diskFull` 可读错误（`SYNC-07` 磁盘满）。
  Future<void> upload(
    SyncConfig config,
    String password,
    String under,
    List<int> bytes,
  ) async {
    final Uri uri = _uri(config, under);
    final ({int status, List<int> body}) resp = await _send(
      config,
      password,
      'PUT',
      uri,
      bodyBytes: bytes,
      contentType: 'application/octet-stream',
      depth: '0',
    );
    _ensureOk(resp.status, resp.body);
  }

  /// 删除文件 / 目录（DELETE）；404 视作成功（幂等——目标已不在）。
  Future<void> delete(
    SyncConfig config,
    String password,
    String under,
  ) async {
    final Uri uri = _uri(config, under);
    final ({int status, List<int> body}) resp =
        await _send(config, password, 'DELETE', uri, depth: '0');
    if (resp.status == HttpStatus.notFound) {
      return;
    }
    _ensureOk(resp.status, resp.body);
  }

  /// 流式上传（PUT 定长 + 取消 + 进度；`SYNC-05` ③：大文件可取消且有进度）。
  ///
  /// 与 [upload]（整包字节）互补：书籍文件等大对象走本方法——[source] 分块
  /// 写入请求体，每块前检查 [control] 取消、写后回调 [onProgress]（[sent]
  /// 为已写字节、第二参为 [contentLength] 总长）。取消 / 源出错经 `abort`
  /// 断连（不留半截 PUT），抛出的 [SyncException] 原样上抛。
  Future<void> uploadStream(
    SyncConfig config,
    String password,
    String under,
    Stream<List<int>> source, {
    required int contentLength,
    TransferControl? control,
    void Function(int sent, int total)? onProgress,
  }) async {
    final Uri uri = _uri(config, under);
    final Duration limit = Duration(seconds: timeoutSeconds);
    try {
      final HttpClientRequest request =
          await _http.openUrl('PUT', uri).timeout(limit);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${config.account}:$password'))}',
      );
      request.headers.contentType =
          ContentType.parse('application/octet-stream');
      request.contentLength = contentLength;
      int sent = 0;
      final Stream<List<int>> watched = source.map((List<int> chunk) {
        if (control?.cancelled ?? false) {
          throw SyncException(SyncErrorKind.cancelled);
        }
        sent += chunk.length;
        onProgress?.call(sent, contentLength);
        return chunk;
      });
      try {
        // 不加 .timeout：传输时长随文件大小增长，进度回调即活动看门狗。
        await request.addStream(watched);
      } catch (error, st) {
        // 源出错 / 取消：请求未收尾——挂空 `done` 吞掉异步错误后再断连
        //（否则 `abort` 让 `done` 以异常 complete，会成为 unhandled error）。
        request.done.ignore();
        request.abort(error, st);
        rethrow;
      }
      if (control?.cancelled ?? false) {
        // 取消发生在**最后一个分块**的回调里：body 已写完但不发 close，仍中断。
        final SyncException cancelled = SyncException(SyncErrorKind.cancelled);
        request.done.ignore();
        request.abort(cancelled, StackTrace.current);
        throw cancelled;
      }
      final HttpClientResponse response = await request.close().timeout(limit);
      final List<int> body = await response
          .fold<List<int>>(<int>[], (List<int> acc, List<int> chunk) {
        acc.addAll(chunk);
        return acc;
      }).timeout(limit);
      _ensureOk(response.statusCode, body);
    } on SyncException {
      rethrow;
    } on TimeoutException {
      throw SyncException(SyncErrorKind.timeout);
    } on IOException {
      throw SyncException(SyncErrorKind.network);
    } catch (_) {
      throw SyncException(SyncErrorKind.unknown);
    }
  }

  /// 下载到文件（GET → 同目录 `.part` 临时文件 → 完整后原子替换 [target]）。
  ///
  /// `SYNC-05` ③：[onProgress] 按已收字节回调（第二参 = `Content-Length`，
  /// 未知为 -1）；[control] 取消即中止，半截 `.part` 一并清理、**目标文件
  /// 保持原样**。非 2xx 先读完响应体再按状态抛可读错误（带服务端细节）。
  Future<void> downloadToFile(
    SyncConfig config,
    String password,
    String under,
    File target, {
    TransferControl? control,
    void Function(int received, int total)? onProgress,
  }) async {
    final Uri uri = _uri(config, under);
    final Duration limit = Duration(seconds: timeoutSeconds);
    final File part = File('${target.path}.part');
    try {
      final HttpClientRequest request =
          await _http.openUrl('GET', uri).timeout(limit);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${config.account}:$password'))}',
      );
      final HttpClientResponse response = await request.close().timeout(limit);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final List<int> body = await response.fold<List<int>>(
          <int>[],
          (List<int> acc, List<int> chunk) {
            acc.addAll(chunk);
            return acc;
          },
        ).timeout(limit);
        throw _statusError(response.statusCode, body);
      }
      final int total = response.contentLength;
      final Directory parent = part.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      int received = 0;
      final IOSink sink = part.openWrite();
      try {
        // Stream.timeout 是**事件间**空闲超时：大文件慢速下载不受总时长限制。
        await for (final List<int> chunk in response.timeout(limit)) {
          if (control?.cancelled ?? false) {
            throw SyncException(SyncErrorKind.cancelled);
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      // 完整才动目标：先删旧（Windows `rename` 不覆盖已存在目标）再改名到位。
      final File existing = File(target.path);
      if (await existing.exists()) {
        await existing.delete();
      }
      await part.rename(target.path);
    } on SyncException {
      await _deleteQuiet(part);
      rethrow;
    } on TimeoutException {
      await _deleteQuiet(part);
      throw SyncException(SyncErrorKind.timeout);
    } on FileSystemException {
      // 磁盘满 / 无权限 / 路径非法——与网络失败分开报（`SYNC-07` 可读原因）。
      await _deleteQuiet(part);
      throw SyncException(
        SyncErrorKind.unknown,
        message: '保存下载文件失败，请检查磁盘空间',
      );
    } on IOException {
      await _deleteQuiet(part);
      throw SyncException(SyncErrorKind.network);
    } catch (_) {
      await _deleteQuiet(part);
      throw SyncException(SyncErrorKind.unknown);
    }
  }

  /// 静默删除临时文件（best-effort：不存在 / 被占用都不覆盖主结果）。
  Future<void> _deleteQuiet(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 清理失败不覆盖主错误；半截 .part 下次写入会被整文件截断重写。
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 传输层
  // ───────────────────────────────────────────────────────────────────────────

  /// 发一次请求并读完响应体；机制失败（拒连 / 超时 / TLS）在此归类，
  /// **状态码不在此判错**——由调用方按语义用 [_ensureOk] / 特判处理。
  Future<({int status, List<int> body})> _send(
    SyncConfig config,
    String password,
    String method,
    Uri uri, {
    List<int>? bodyBytes,
    String? contentType,
    String depth = '0',
  }) async {
    final Duration limit = Duration(seconds: timeoutSeconds);
    try {
      final HttpClientRequest request = await _http.openUrl(method, uri)
          .timeout(limit);
      request.followRedirects = false; // WebDAV 语义：3xx 当作可读错误上报。
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${config.account}:$password'))}',
      );
      // dart:io 无 WebDAV 的 Depth 常量（`HttpHeaders` 只有标准头）——字面量。
      request.headers.set('Depth', depth);
      // PROPFIND 必须带 XML 请求体（声明要哪些属性），否则部分服务器 400/411。
      final List<int>? payload = bodyBytes ??
          (method == 'PROPFIND' ? utf8.encode(_propfindBody) : null);
      if (payload != null) {
        if (method == 'PROPFIND') {
          request.headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8');
        } else if (contentType != null) {
          request.headers.contentType = ContentType.parse(contentType);
        }
        request.contentLength = payload.length;
        request.add(payload);
      }
      final HttpClientResponse response = await request.close().timeout(limit);
      final List<int> body = await response
          .fold<List<int>>(<int>[], (List<int> acc, List<int> chunk) {
        acc.addAll(chunk);
        return acc;
      }).timeout(limit);
      return (status: response.statusCode, body: body);
    } on SyncException {
      rethrow;
    } on TimeoutException {
      throw SyncException(SyncErrorKind.timeout);
    } on IOException {
      // SocketException / HttpException / HandshakeException 等：网络不可达。
      throw SyncException(SyncErrorKind.network);
    } catch (_) {
      throw SyncException(SyncErrorKind.unknown);
    }
  }

  /// 2xx 通过；否则抛映射后的 [SyncException]（`SYNC-07` 可读原因）。
  void _ensureOk(int status, List<int> body) {
    if (status >= 200 && status < 300) {
      return;
    }
    throw _statusError(status, body);
  }

  /// 状态码 → 分类 + 中文文案（附服务端返回的错误细节）。
  SyncException _statusError(int status, List<int> body) {
    final SyncErrorKind kind;
    final String base;
    switch (status) {
      case HttpStatus.unauthorized:
        kind = SyncErrorKind.unauthorized;
        base = '账号或密码错误（401）';
      case HttpStatus.forbidden:
        kind = SyncErrorKind.unauthorized;
        base = '无权限访问（403），请检查账号权限';
      case HttpStatus.notFound:
        kind = SyncErrorKind.notFound;
        base = '地址不存在（404），请检查服务器地址与远端目录';
      case 507: // Insufficient Storage（RFC 4918）
        kind = SyncErrorKind.diskFull;
        base = '远端磁盘空间不足（507），请清理云端空间';
      default:
        if (status >= 500) {
          kind = SyncErrorKind.server;
          base = '服务端错误（$status）';
        } else {
          kind = SyncErrorKind.unknown;
          base = '请求被拒绝（$status）';
        }
    }
    final String detail = _errorDetail(body);
    return SyncException(
      kind,
      statusCode: status,
      message: detail.isEmpty ? base : '$base：$detail',
    );
  }

  /// 从错误响应体提取可读细节（剥 XML 标签，截 160 字；空体返空串）。
  String _errorDetail(List<int> body) {
    if (body.isEmpty) {
      return '';
    }
    final String raw = utf8.decode(body, allowMalformed: true);
    final String text = raw
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) {
      return '';
    }
    return text.length <= 160 ? text : '${text.substring(0, 160)}…';
  }

  // ───────────────────────────────────────────────────────────────────────────
  // URL 拼接与 PROPFIND 解析
  // ───────────────────────────────────────────────────────────────────────────

  /// `config.url` 去尾斜杠。
  Uri _siteUri(SyncConfig config) => Uri.parse(_noSlash(config.url));

  /// 远端根 `{url}/{dir}`。
  Uri _rootUri(SyncConfig config) => _uri(config, '');

  /// `{url}/{dir}/{under}`；段逐个 [Uri.encodeComponent]（中文 / 空格安全）。
  Uri _uri(SyncConfig config, String under) {
    final String base = _noSlash(config.url);
    final List<String> segments = <String>[
      ..._segments(config.dir),
      ..._segments(under),
    ];
    if (segments.isEmpty) {
      return Uri.parse(base);
    }
    return Uri.parse('$base/${segments.join('/')}');
  }

  static String _noSlash(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  /// 拆路径段（去空段）并逐段 percent-encode。
  static List<String> _segments(String path) => path
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.encodeComponent)
      .toList();

  /// 解析 PROPFIND multistatus（207）；`rootPath` = 远端根的编码路径，
  /// 用于把 href 归一成**相对根**的已解码路径。
  List<WebdavEntry> _parseMultistatus(List<int> body, Uri rootUri) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(body, allowMalformed: true));
    } catch (_) {
      return const <WebdavEntry>[]; // 响应不可解析：按空结果处理（不编造条目）。
    }
    final String rootPath =
        rootUri.path.replaceAll(RegExp(r'/+$'), '');
    final List<WebdavEntry> entries = <WebdavEntry>[];
    for (final XmlElement resp
        in doc.findAllElements('response', namespace: '*')) {
      final String? hrefText = resp
          .findAllElements('href', namespace: '*')
          .firstOrNull
          ?.innerText
          .trim();
      if (hrefText == null || hrefText.isEmpty) {
        continue;
      }
      final Uri href;
      try {
        // 绝对 URL / 绝对路径 / 相对引用都能 resolve 到绝对地址。
        href = Uri.parse(hrefText);
      } catch (_) {
        continue;
      }
      final String relPath = _relativePath(href.path, rootPath);
      entries.add(
        WebdavEntry(
          path: _decodePath(relPath),
          lastModified: _parseHttpDate(
            resp
                .findAllElements('getlastmodified', namespace: '*')
                .firstOrNull
                ?.innerText,
          ),
          isCollection:
              resp.findAllElements('collection', namespace: '*').isNotEmpty,
        ),
      );
    }
    return entries;
  }

  /// href 路径 → 相对远端根的编码路径（去根前缀、去首尾斜杠）。
  static String _relativePath(String hrefPath, String rootPath) {
    String path = hrefPath;
    if (rootPath.isNotEmpty && path.startsWith(rootPath)) {
      path = path.substring(rootPath.length);
    }
    return path.replaceAll(RegExp(r'^/+|/+$'), '');
  }

  /// 逐段 percent-decode；坏转义原样保留（不因单段损坏丢整个条目）。
  static String _decodePath(String encoded) {
    return encoded.split('/').map((String segment) {
      try {
        return Uri.decodeComponent(segment);
      } catch (_) {
        return segment;
      }
    }).join('/');
  }

  /// RFC1123 日期 → [DateTime]；空 / 非法返 `null`。
  static DateTime? _parseHttpDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return HttpDate.parse(raw.trim());
    } catch (_) {
      return null;
    }
  }
}
