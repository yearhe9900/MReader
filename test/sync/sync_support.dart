// `M4-T03`：`test/sync/` 共用测试基建（自 M4-T02 `progress_sync_test` 抽出，
// 各测试文件 import 使用，**勿再复制一份**）。
//
// - [TestAppPaths]：临时目录实现 `AppPaths`（与 `test/reader/progress_store_test.dart`
//   同款）；
// - [MemorySecureStore]：内存版 `SecureStore`（密码不落盘，仅测试用）；
// - [MockDav]：内存版 WebDAV 服务端（PROPFIND / GET / PUT / MKCOL 四方法 +
//   `failStatus` 注错 + `seed` / `textOf`），纯 `test()` 真 socket 直连。
import 'dart:convert';
import 'dart:io';

import 'package:mreader/platform/app_paths.dart';
import 'package:mreader/platform/secure_store.dart';

/// 临时目录实现 [AppPaths]（仅测试）。
class TestAppPaths implements AppPaths {
  TestAppPaths(this._root);
  final Directory _root;

  @override
  Future<Directory> dataDir() async => _root;

  @override
  Future<Directory> subDir(String name) async {
    final Directory dir = Directory(
      '${_root.path}${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }
}

/// 内存版 [SecureStore]（密码不落盘，仅测试用）。
class MemorySecureStore implements SecureStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => _data.containsKey(key);

  @override
  bool get isSecure => false;

  @override
  String get securityNotice => '测试内存存储';
}

class _DavFile {
  _DavFile(this.body, this.mtime);
  List<int> body;

  /// `null` = 远端不返回 `getlastmodified`（PROPFIND 响应里省略该元素）。
  DateTime? mtime;
}

/// 内存版 WebDAV 服务端。
///
/// 文件键 = **percent-encode 后**的绝对路径（与 `WebdavClient` 拼 URL 的
/// `Uri.encodeComponent` 逐段口径一致；`r.uri.path` 原样带回请求行）。
class MockDav {
  /// 创建服务端（[rootDir] = `SyncConfig.dir`，默认 `mreader`）。
  MockDav({this.rootDir = 'mreader'});

  /// 远端根目录段。
  final String rootDir;

  final Map<String, _DavFile> _files = <String, _DavFile>{};

  /// 请求流水（`'GET /mreader/...'`），断言「跳过不下载」等用。
  final List<String> calls = <String>[];

  /// 非 `null` 时所有请求回这个状态码（制造 500 等通道失败）。
  int? failStatus;

  HttpServer? _server;

  /// 启动并返回 `SyncConfig.url` 用的根地址（无路径）。
  Future<String> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
    _server = server;
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  /// 播种远端文件（[under] 为已解码相对路径，如 `bookProgress/三体_刘慈欣.json`）。
  ///
  /// [mtime] 为 `null` 时 PROPFIND 不带 `getlastmodified`（测「时间戳缺失」分支）。
  void seed(String under, String content, DateTime? mtime) {
    _files[_key(under)] = _DavFile(utf8.encode(content), mtime);
  }

  /// 读远端文件内容（未播种 / 已被 PUT 覆盖后的现值）。
  String? textOf(String under) {
    final _DavFile? file = _files[_key(under)];
    return file == null ? null : utf8.decode(file.body);
  }

  /// 解码相对路径 → 与客户端同口径的 percent-encoded 键。
  String _key(String under) =>
      '/${<String>[rootDir, ...under.split('/')]
          .map(Uri.encodeComponent)
          .join('/')}';

  Future<void> _handle(HttpRequest request) async {
    calls.add('${request.method} ${request.uri.path}');
    try {
      final int? failure = failStatus;
      if (failure != null) {
        request.response.statusCode = failure;
        await request.response.close();
        return;
      }
      final String path = request.uri.path;
      switch (request.method) {
        case 'PROPFIND':
          final _DavFile? file = _files[path];
          if (file == null) {
            request.response.statusCode = 404;
          } else {
            request.response.statusCode = 207;
            final DateTime? mtime = file.mtime;
            request.response.write(
              '<?xml version="1.0" encoding="utf-8"?>'
              '<d:multistatus xmlns:d="DAV:"><d:response>'
              '<d:href>$path</d:href><d:propstat><d:prop>'
              '${mtime == null ? '' : '<d:getlastmodified>${HttpDate.format(mtime)}</d:getlastmodified>'}'
              '<d:resourcetype/>'
              '</d:prop></d:propstat></d:response></d:multistatus>',
            );
          }
        case 'GET':
          final _DavFile? file = _files[path];
          if (file == null) {
            request.response.statusCode = 404;
          } else {
            request.response.statusCode = 200;
            request.response.add(file.body);
          }
        case 'PUT':
          final List<int> body = await request
              .fold<List<int>>(<int>[], (List<int> a, List<int> c) {
            a.addAll(c);
            return a;
          });
          _files[path] = _DavFile(body, DateTime.now().toUtc());
          request.response.statusCode = 201;
        case 'MKCOL':
          request.response.statusCode = 201; // 已存在也回 201，客户端均接受。
        default:
          request.response.statusCode = 405;
      }
      await request.response.close();
    } catch (_) {
      // 测试内主动关服 / 断言抛出导致的写失败：忽略。
    }
  }
}
