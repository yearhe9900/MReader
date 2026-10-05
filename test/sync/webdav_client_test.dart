// `M4-T01`：WebdavClient 通道测试（`SYNC-01` ①②③ / `SYNC-07` 失败可见）。
//
// 用本机 `HttpServer` 模拟 WebDAV 服务端（同 `ai_client_test.dart` 的 `_serve`
// 口径）：均为纯 `test()`（无 FakeAsync 区），真实 socket 异步可正常排空。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/webdav_client.dart';

/// 起一个一次性本地 mock；返回根地址（`http://127.0.0.1:port`，**无路径**，
/// 与 [SyncConfig.url] 可直接拼接目录）。
Future<(String, HttpServer)> _serve(
  Future<void> Function(HttpRequest request) handler,
) async {
  final HttpServer server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) async {
    try {
      await handler(request);
    } catch (_) {
      // 测试内主动关服 / 断言抛出导致的写失败：忽略。
    }
  });
  return ('http://127.0.0.1:${server.port}', server);
}

/// 最小 multistatus：根目录 + 一个 percent-encoded 中文名文件。
const String _multistatus =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">'
    '<d:response><d:href>/mreader/</d:href><d:propstat><d:prop>'
    '<d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>'
    '<d:resourcetype><d:collection/></d:resourcetype>'
    '</d:prop></d:propstat></d:response>'
    '<d:response>'
    '<d:href>/mreader/bookProgress/'
    '%E4%B8%89%E4%BD%93_%E5%88%98%E6%85%88%E6%AC%A3.json</d:href>'
    '<d:propstat><d:prop>'
    '<d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>'
    '<d:resourcetype/>'
    '</d:prop></d:propstat></d:response>'
    '</d:multistatus>';

/// 空 multistatus（测试连接只看状态码，不解析条目）。
const String _emptyMultistatus =
    '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>';

void main() {
  const String password = 'pw';
  const String account = 'acc';

  late WebdavClient client;
  HttpServer? active;

  setUp(() {
    client = WebdavClient(timeoutSeconds: 5);
  });

  tearDown(() async {
    client.close();
    final HttpServer? server = active;
    active = null;
    if (server != null) {
      await server.close(force: true);
    }
  });

  SyncConfig config(String base, {String dir = 'mreader'}) =>
      SyncConfig(url: base, account: account, dir: dir);

  String expectedAuth() =>
      'Basic ${base64Encode(utf8.encode('$account:$password'))}';

  group('测试连接（`SYNC-01` ①②③）', () {
    test('PROPFIND 验凭据 + 目录已存在（MKCOL 405）→ 成功', () async {
      final List<String> calls = <String>[];
      late String? auth;
      late String? depth;
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          calls.add('${r.method} ${r.uri.path}');
          if (r.method == 'PROPFIND') {
            auth = r.headers.value(HttpHeaders.authorizationHeader);
            depth = r.headers.value('Depth');
            r.response.statusCode = 207;
            r.response.write(_emptyMultistatus);
          } else {
            r.response.statusCode = 405; // 目录已存在。
          }
          await r.response.close();
        },
      );
      active = server;

      await client.testConnection(config: config(base), password: password);

      expect(calls.length, 2, reason: '一次 PROPFIND + 一次 MKCOL');
      expect(calls[0], startsWith('PROPFIND'));
      expect(calls[1], 'MKCOL /mreader');
      expect(auth, expectedAuth(), reason: '必须带 Basic 认证头');
      expect(depth, '0', reason: '测试连接用 Depth 0');
    });

    test('目录不存在 → 逐级 MKCOL 自动创建（`SYNC-01` ③）', () async {
      final List<String> calls = <String>[];
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async {
          calls.add('${r.method} ${r.uri.path}');
          if (r.method == 'PROPFIND') {
            r.response.statusCode = 207;
            r.response.write(_emptyMultistatus);
          } else {
            r.response.statusCode = 201; // 目录创建成功。
          }
          await r.response.close();
        },
      );
      active = server;

      await client.testConnection(
        config: config(base, dir: 'mreader/today'),
        password: password,
      );

      expect(calls, <String>[
        'PROPFIND /',
        'MKCOL /mreader',
        'MKCOL /mreader/today',
      ]);
    });

    test('401 → unauthorized 可读、不可重试（`SYNC-01` ② / `SYNC-07`）', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        r.response.statusCode = 401;
        r.response.write('Invalid credentials');
        await r.response.close();
      });
      active = server;

      try {
        await client.testConnection(config: config(base), password: password);
        fail('401 应抛 SyncException');
      } on SyncException catch (e) {
        expect(e.kind, SyncErrorKind.unauthorized);
        expect(e.statusCode, 401);
        expect(e.message, contains('账号或密码错误（401）'));
        expect(e.message, contains('Invalid credentials'), reason: '回显服务端细节');
        expect(e.retryable, isFalse, reason: '凭据错误重试无意义');
      }
    });

    test('404 → notFound 可读（`SYNC-07`）', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        r.response.statusCode = 404;
        await r.response.close();
      });
      active = server;

      try {
        await client.testConnection(config: config(base), password: password);
        fail('404 应抛 SyncException');
      } on SyncException catch (e) {
        expect(e.kind, SyncErrorKind.notFound);
        expect(e.statusCode, 404);
        expect(e.message, contains('404'));
        expect(e.retryable, isFalse);
      }
    });
  });

  group('机制失败（`SYNC-07`：网络不可达 / 超时可重试）', () {
    test('端口无监听 → network 可重试', () async {
      final HttpServer dead =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final int port = dead.port;
      await dead.close(force: true);

      try {
        await client.testConnection(
          config: config('http://127.0.0.1:$port'),
          password: password,
        );
        fail('连接被拒应抛 SyncException');
      } on SyncException catch (e) {
        expect(e.kind, SyncErrorKind.network);
        expect(e.message, contains('网络不可达'));
        expect(e.retryable, isTrue);
      }
    });

    test('服务端挂起不回 → timeout 可重试', () async {
      client.close();
      client = WebdavClient(timeoutSeconds: 1);
      final (String base, HttpServer server) = await _serve(
        (HttpRequest r) async => Completer<void>().future, // 挂住不回。
      );
      active = server;

      try {
        await client.testConnection(config: config(base), password: password);
        fail('挂起应抛 SyncException');
      } on SyncException catch (e) {
        expect(e.kind, SyncErrorKind.timeout);
        expect(e.message, contains('超时'));
        expect(e.retryable, isTrue);
      }
    });

    test('500 → server 可重试，且响应体细节附在 message（可读原因）', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        r.response.statusCode = 500;
        r.response.write('<error><message>disk hiccup</message></error>');
        await r.response.close();
      });
      active = server;

      try {
        await client.testConnection(config: config(base), password: password);
        fail('500 应抛 SyncException');
      } on SyncException catch (e) {
        expect(e.kind, SyncErrorKind.server);
        expect(e.statusCode, 500);
        expect(e.message, contains('服务端错误（500）'));
        expect(e.message, contains('disk hiccup'), reason: '剥标签后的服务端细节');
        expect(e.retryable, isTrue);
      }
    });
  });

  group('list / stat（PROPFIND 解析）', () {
    test('list：Depth 1 + 解析 href / getlastmodified / collection', () async {
      late String? depth;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        depth = r.headers.value('Depth');
        r.response.statusCode = 207;
        r.response.write(_multistatus);
        await r.response.close();
      });
      active = server;

      final List<WebdavEntry> entries =
          await client.list(config(base), password, '');

      expect(depth, '1');
      expect(entries.length, 2);
      // 条目 0：根目录自身。
      expect(entries[0].path, '');
      expect(entries[0].isCollection, isTrue);
      expect(
        entries[0].lastModified,
        HttpDate.parse('Wed, 21 Oct 2015 07:28:00 GMT'),
      );
      // 条目 1：percent-encoded 中文名 → 解码后的相对路径。
      expect(entries[1].path, 'bookProgress/三体_刘慈欣.json');
      expect(entries[1].isCollection, isFalse);
      expect(
        entries[1].lastModified,
        HttpDate.parse('Wed, 21 Oct 2015 07:28:00 GMT'),
      );
    });

    test('stat：404 → null；命中 → 条目（相对根路径归一）', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        if (r.uri.path.endsWith('missing.json')) {
          r.response.statusCode = 404;
        } else {
          r.response.statusCode = 207;
          r.response.write(
            '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/mreader/bookProgress/ok.json</d:href>'
            '<d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>'
            '</d:response></d:multistatus>',
          );
        }
        await r.response.close();
      });
      active = server;

      final SyncConfig c = config(base);
      expect(await client.stat(c, password, 'missing.json'), isNull);
      final WebdavEntry? entry =
          await client.stat(c, password, 'bookProgress/ok.json');
      expect(entry, isNotNull);
      expect(entry!.path, 'bookProgress/ok.json');
      expect(entry.isCollection, isFalse);
    });
  });

  group('upload / download / delete（PUT / GET / DELETE）', () {
    test('upload：PUT 字节原样到达，带 Basic 认证', () async {
      late String? auth;
      late String? path;
      late List<int>? body;
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        auth = r.headers.value(HttpHeaders.authorizationHeader);
        path = r.uri.path;
        body = await r.fold<List<int>>(<int>[], (List<int> a, List<int> c) {
          a.addAll(c);
          return a;
        });
        r.response.statusCode = 201;
        await r.response.close();
      });
      active = server;

      await client.upload(
        config(base),
        password,
        'bookProgress/三体_刘慈欣.json',
        utf8.encode('{"pos":42}'),
      );

      expect(path, '/mreader/bookProgress/%E4%B8%89%E4%BD%93_%E5%88%98%E6%85%88%E6%AC%A3.json',
          reason: '段逐个 encodeComponent（中文 → percent-encoding）');
      expect(utf8.decode(body!), '{"pos":42}');
      expect(auth, expectedAuth());
    });

    test('507 → diskFull 可读、不可重试（`SYNC-07` 磁盘满）', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        r.response.statusCode = 507;
        await r.response.close();
      });
      active = server;

      try {
        await client.upload(config(base), password, 'x.json', <int>[1]);
        fail('507 应抛 SyncException');
      } on SyncException catch (e) {
        expect(e.kind, SyncErrorKind.diskFull);
        expect(e.statusCode, 507);
        expect(e.message, contains('磁盘空间不足'));
        expect(e.retryable, isFalse);
      }
    });

    test('download 返回字节；delete 遇 404 幂等成功', () async {
      final (String base, HttpServer server) = await _serve((HttpRequest r) async {
        if (r.method == 'GET') {
          r.response.statusCode = 200;
          r.response.write('hello-webdav');
        } else {
          r.response.statusCode = 404; // 目标已不在（幂等）。
        }
        await r.response.close();
      });
      active = server;

      final SyncConfig c = config(base);
      final List<int> bytes = await client.download(c, password, 'a.txt');
      expect(utf8.decode(bytes), 'hello-webdav');
      await client.delete(c, password, 'a.txt'); // 404 不抛。
    });
  });
}
