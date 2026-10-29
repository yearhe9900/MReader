// `SYNC-05` 验收 ①②③ + `SYNC-07`：书籍文件上传 / 下载测试。
//
// 内存 WebDAV 服务端与临时目录 / 凭据假件在 `sync_support.dart`：均为纯
// `test()`（无 FakeAsync 区），真实 socket 异步可正常排空。
//
// 取消用例依赖 `File.openRead` 的 64KB 分块（dart:io `_blockSize`）：
// 200KB 文件 ≥ 4 块，首进度即取消 → 第 2 块前抛 `cancelled`，确定性。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/sync/book_upload.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';

import 'sync_support.dart';

void main() {
  late Directory tempDir;
  late SyncConfigStore configStore;
  late BookUploadPrefsStore prefs;
  late WebdavClient client;
  late MockDav dav;
  late BookUploadEngine engine;

  /// 造一本内容确定的书（[size] 字节）。
  Future<File> makeBook(String name, int size) async {
    final File file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(List<int>.generate(size, (int i) => i % 251));
    return file;
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('mreader_bookup_');
    prefs = BookUploadPrefsStore(tempDir);
    await prefs.load();
    configStore = SyncConfigStore(
      tempDir,
      SyncPasswordVault(MemorySecureStore()),
    );
    client = WebdavClient(timeoutSeconds: 5);
    dav = MockDav();
    final String base = await dav.start();
    await configStore.save(SyncConfig(url: base, account: 'acc'));
    await configStore.writePassword('pw');
    engine = BookUploadEngine(
      client: client,
      prefs: prefs,
      configStore: configStore,
    );
  });

  tearDown(() async {
    client.close();
    await dav.stop();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('开关（`SYNC-05` ①：默认不传书籍文件）', () {
    test('默认关 → 上传 / 下载都 skipped，零请求', () async {
      expect(prefs.enabled, isFalse, reason: 'book_upload.json 缺失 = 默认关');
      final File book = await makeBook('book.epub', 1024);

      final BookUploadOutcome up = await engine.uploadBook(book);
      expect(up.action, BookTransferAction.skipped);
      expect(up.fileName, 'book.epub');

      final BookUploadOutcome down = await engine.downloadBook(
        'book.epub',
        File('${tempDir.path}${Platform.pathSeparator}dl.epub'),
      );
      expect(down.action, BookTransferAction.skipped);

      expect(dav.calls, isEmpty, reason: '开关关不发任何请求');
    });

    test('开关持久化：setEnabled 后新实例 load 读回', () async {
      await prefs.setEnabled(true);
      final BookUploadPrefsStore reopened = BookUploadPrefsStore(tempDir);
      await reopened.load();
      expect(reopened.enabled, isTrue);
    });
  });

  group('上传（`SYNC-05` ②③）', () {
    test('开启后上传成功：MKCOL + PUT 落远端，进度到达总长', () async {
      await prefs.setEnabled(true);
      final File book = await makeBook('book.epub', 200 * 1024);
      final List<(int, int)> progress = <(int, int)>[];

      final BookUploadOutcome outcome = await engine.uploadBook(
        book,
        onProgress: (int sent, int total) => progress.add((sent, total)),
      );

      expect(outcome.action, BookTransferAction.uploaded,
          reason: outcome.reason ?? '');
      expect(dav.calls.contains('MKCOL /mreader'), isTrue);
      expect(dav.calls.contains('MKCOL /mreader/books'), isTrue);
      expect(
        dav.calls.contains('PUT /mreader/books/book.epub'),
        isTrue,
      );
      final List<int>? stored = dav.bytesOf('books/book.epub');
      expect(stored, isNotNull);
      expect(stored!.length, 200 * 1024, reason: '远端收到完整字节');
      expect(progress, isNotEmpty);
      expect(progress.last.$1, 200 * 1024, reason: '末次进度 = 已发总长');
      expect(progress.last.$2, 200 * 1024, reason: '总长 = 文件大小');
    });

    test('首进度即取消 → cancelled，远端无完整文件（`SYNC-05` ③）', () async {
      await prefs.setEnabled(true);
      final File book = await makeBook('big.epub', 200 * 1024);
      final TransferControl control = TransferControl();
      bool first = true;

      final BookUploadOutcome outcome = await engine.uploadBook(
        book,
        control: control,
        onProgress: (int sent, int total) {
          if (first) {
            first = false;
            control.cancel();
          }
        },
      );

      expect(outcome.action, BookTransferAction.cancelled,
          reason: outcome.reason ?? '');
      expect(outcome.reason, '已取消');
      final List<int>? stored = dav.bytesOf('books/big.epub');
      expect(
        stored == null || stored.length < 200 * 1024,
        isTrue,
        reason: '取消后远端不得有完整文件',
      );
    });

    test('未配置 WebDAV → failed + 可读原因', () async {
      await prefs.setEnabled(true);
      final Directory freshDir =
          Directory.systemTemp.createTempSync('mreader_fresh_');
      try {
        final BookUploadEngine fresh = BookUploadEngine(
          client: client,
          prefs: prefs,
          configStore: SyncConfigStore(
            freshDir,
            SyncPasswordVault(MemorySecureStore()),
          ),
        );
        final File book = await makeBook('a.epub', 16);
        final BookUploadOutcome outcome = await fresh.uploadBook(book);
        expect(outcome.action, BookTransferAction.failed);
        expect(outcome.reason, '尚未配置 WebDAV 同步');
        expect(dav.calls, isEmpty);
      } finally {
        freshDir.deleteSync(recursive: true);
      }
    });

    test('本地文件不存在 → failed（零请求）', () async {
      await prefs.setEnabled(true);
      final BookUploadOutcome outcome = await engine.uploadBook(
        File('${tempDir.path}${Platform.pathSeparator}nope.epub'),
      );
      expect(outcome.action, BookTransferAction.failed);
      expect(outcome.reason, '书籍文件不存在');
      expect(dav.calls, isEmpty);
    });
  });

  group('下载（`SYNC-05` ②③）', () {
    test('下载成功：字节一致、进度到满、无 .part 残留、目标目录自动创建', () async {
      await prefs.setEnabled(true);
      final List<int> source =
          List<int>.generate(150 * 1024, (int i) => i % 251);
      dav.seedBytes('books/dl.epub', source, DateTime.utc(2026, 10, 5));
      final File target = File(
        '${tempDir.path}${Platform.pathSeparator}'
        'sub${Platform.pathSeparator}dl.epub',
      );
      final List<(int, int)> progress = <(int, int)>[];

      final BookUploadOutcome outcome = await engine.downloadBook(
        'dl.epub',
        target,
        onProgress: (int received, int total) => progress.add((received, total)),
      );

      expect(outcome.action, BookTransferAction.downloaded,
          reason: outcome.reason ?? '');
      final List<int> saved = await target.readAsBytes();
      expect(saved, source, reason: '下载字节与远端一致');
      expect(progress, isNotEmpty);
      expect(progress.last.$1, 150 * 1024, reason: '末次进度 = 已收总长');
      expect(progress.last.$2, 150 * 1024, reason: '总长 = Content-Length');
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('远端无此书 → failed + 可读 404（`SYNC-07`）', () async {
      await prefs.setEnabled(true);
      final BookUploadOutcome outcome = await engine.downloadBook(
        'missing.epub',
        File('${tempDir.path}${Platform.pathSeparator}m.epub'),
      );
      expect(outcome.action, BookTransferAction.failed);
      expect(outcome.reason, contains('404'));
    });

    test('非法文件名（`..`）→ failed 且零请求', () async {
      await prefs.setEnabled(true);
      final BookUploadOutcome outcome = await engine.downloadBook(
        '..',
        File('${tempDir.path}${Platform.pathSeparator}x.epub'),
      );
      expect(outcome.action, BookTransferAction.failed);
      expect(outcome.reason, '非法文件名');
      expect(dav.calls, isEmpty);
    });
  });
}
