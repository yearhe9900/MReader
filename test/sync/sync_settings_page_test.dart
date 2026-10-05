// `M4-T01`：同步设置页 widget 测试（`SYNC-01` 五要素界面 / 预设回填 /
// 测试连接成功与错误可见 `SYNC-07` / `DATA-02` ③ 明文标注）+ 设置页入口接线。
//
// 三条测试口径（沿用既有测试的既定做法）：
//   ① 宿主钉「关」档（`settings_page_test.dart` 的 `host(tier, …)` 同款）——
//      玻璃档浮层在 `flutter test` 软件光栅下每帧数百 ms 真实异步开销，
//      需要弹层交互的用例一律在关档跑（关档退化走 Material 对话框）；
//   ② 测试体内**真异步 IO**（落盘 / 读密码）必须用交替 `runAsync` / `pump`
//      排空（`settleReal` 口径）；
//   ③ **真实 socket 断言不进 widget 测试**：`TestWidgetsFlutterBinding` 装了
//      `HttpOverrides`，把 suite 内所有 `HttpClient` 请求拦成 400（框架自警：
//      "all HTTP requests will return status code 400"）——故「测试连接」三个用例
//      注入 [_StubWebdavClient] 只验**结果如何呈现**；状态码 → 分类的真网络语义在
//      纯 `test()` 的 `webdav_client_test.dart` 逐条覆盖（`SYNC-01` ①②③ / `SYNC-07`）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/sync/sync_config.dart';
import 'package:mreader/sync/sync_config_store.dart';
import 'package:mreader/sync/webdav_client.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/settings_page.dart';
import 'package:mreader/ui/sync_settings_page.dart';

import '../test_config.dart';

/// 钉「关」档宿主（同 `settings_page_test.dart`）。
Widget host(GlassQualityTier tier, Widget home) {
  return MaterialApp(
    home: GlassScopeProvider(
      config: glassTierConfigFor(tier),
      child: home,
    ),
  );
}

/// 记录调用参数 / 按需抛错的 [WebdavClient] 测试替身。
///
/// 为什么不用真 socket：`TestWidgetsFlutterBinding` 装了 `HttpOverrides`，
/// suite 内所有 `HttpClient` 请求都会被拦成 400（框架自警原文，见文件头口径③）。
/// 本替身只验「UI 如何呈现结果」；状态码 → 分类的真网络语义在纯 `test()` 的
/// `webdav_client_test.dart` 覆盖。
class _StubWebdavClient extends WebdavClient {
  _StubWebdavClient({this.toThrow});

  /// 非 `null` 时 `testConnection` 抛出它（模拟服务端 / 网络失败）。
  final SyncException? toThrow;

  /// 最近一次调用的配置（断言表单是否被正确传递）。
  SyncConfig? lastConfig;

  /// 最近一次调用的密码（表单值或已存密码）。
  String? lastPassword;

  @override
  Future<void> testConnection({
    required SyncConfig config,
    required String password,
  }) async {
    lastConfig = config;
    lastPassword = password;
    final SyncException? error = toThrow;
    if (error != null) {
      throw error;
    }
  }
}

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  late Directory dir;
  late SyncPasswordVault vault;
  late SyncConfigStore store;
  late WebdavClient client;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mreader_sync_page_');
    vault = SyncPasswordVault(FileSecureStore(directory: dir));
    store = SyncConfigStore(dir, vault);
    await store.load();
    client = WebdavClient(timeoutSeconds: 5);
  });

  tearDown(() async {
    client.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// 内容较高（多组卡片）：拉高视口避免懒加载回收（同 `ai_settings_page_test`）。
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(2400, 3600);
    addTearDown(tester.view.reset);
  }

  /// 交替 runAsync / pump，排空 widget 内发起的真异步 IO（落盘 / 读密码 / socket）。
  Future<void> settleReal(WidgetTester tester, {int rounds = 40}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// [using] 覆盖默认 [client]——「测试连接」用例注入 [_StubWebdavClient]（口径③）。
  Widget buildApp({WebdavClient? using}) => host(
        GlassQualityTier.off,
        SyncSettingsPage(store: store, client: using ?? client),
      );

  /// 依次填 url / 账号 / 密码三个字段（表单顺序：服务器组前三行）。
  Future<void> fillCredentials(
    WidgetTester tester, {
    required String url,
  }) async {
    await tester.enterText(find.byType(TextField).at(0), url);
    await tester.enterText(find.byType(TextField).at(1), 'acc');
    await tester.enterText(find.byType(TextField).at(2), 'pw');
    await tester.pump();
  }

  group('同步设置页 · 界面与配置（`SYNC-01`）', () {
    testWidgets('初始：五要素字段与服务商预设在场，未配置', (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(find.text('同步设置'), findsOneWidget);
      for (final String label in <String>[
        '服务器地址',
        '账号',
        '密码',
        '远端目录',
        '设备名',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺字段：$label');
      }
      expect(find.text('服务商预设'), findsOneWidget);
      expect(find.text('坚果云'), findsOneWidget);
      expect(find.text('坚果云备用'), findsOneWidget);
      // 远端目录默认 mreader（`SYNC-01` / PRD §10.3）。
      expect(
        tester.widget<TextField>(find.byType(TextField).at(3)).controller!.text,
        'mreader',
      );
      expect(store.isConfigured, isFalse);
      expect(find.text('删除同步配置'), findsNothing);
    });

    testWidgets('`DATA-02` ③：明文降级时「密码存储」显示明文告知', (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(store.vault.isSecure, isFalse);
      expect(find.text('密码存储'), findsOneWidget);
      expect(find.textContaining('明文保存'), findsOneWidget);
    });

    testWidgets('点预设回填服务器地址并选中（`SYNC-01` 多家服务商预设）',
        (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('坚果云'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        'https://dav.jianguoyun.com/dav/',
      );
      expect(
        tester
            .widget<FilterChip>(
              find.ancestor(
                of: find.text('坚果云'),
                matching: find.byType(FilterChip),
              ),
            )
            .selected,
        isTrue,
      );
      // 预设脚注切换为该家服务商的说明（用脚注独有的「安全选项」措辞断言，
      // 避免与密码字段 hint「应用密码 / 登录密码」撞词）。
      expect(find.textContaining('安全选项'), findsOneWidget);
    });

    testWidgets('空表单点保存 → 中文校验弹窗（`SYNC-01` ②）', (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await settleReal(tester);

      expect(
        find.textContaining('服务器地址需为完整的 http(s) 地址'),
        findsOneWidget,
      );
      expect(store.isConfigured, isFalse, reason: '校验不过不落盘');
    });

    testWidgets('已配置：字段回填 + 密码不回显（留空保持，`DATA-02`）',
        (WidgetTester tester) async {
      tall(tester);
      await tester.runAsync(() async {
        await store.save(
          SyncConfig(
            url: 'https://dav.jianguoyun.com/dav/',
            account: 'u@example.com',
            deviceName: '小米',
          ),
        );
        await store.writePassword('stored-pw');
      });
      await tester.pumpWidget(buildApp());
      await settleReal(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        'https://dav.jianguoyun.com/dav/',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'u@example.com',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(4)).controller!.text,
        '小米',
      );
      expect(find.textContaining('已保存密码'), findsOneWidget);
      expect(find.text('stored-pw'), findsNothing, reason: '密码不铺在界面上');
      expect(find.text('删除同步配置'), findsOneWidget);
    });
  });

  group('同步设置页 · 测试连接（`SYNC-01` ①②③ / `SYNC-07`）', () {
    testWidgets('401 → 分类错误可见（含服务端细节），不可重试保持「测试」',
        (WidgetTester tester) async {
      tall(tester);
      final _StubWebdavClient stub = _StubWebdavClient(
        toThrow: SyncException(
          SyncErrorKind.unauthorized,
          statusCode: 401,
          message: '账号或密码错误（401）：Invalid credentials',
        ),
      );
      await tester.pumpWidget(buildApp(using: stub));
      await tester.pumpAndSettle();
      await fillCredentials(tester, url: 'https://dav.example.com/dav/');

      await tester.tap(find.widgetWithText(TextButton, '测试'));
      await settleReal(tester, rounds: 60);

      expect(find.textContaining('账号或密码错误（401）'), findsOneWidget);
      expect(find.textContaining('Invalid credentials'), findsOneWidget);
      // 401 不可重试：按钮保持「测试」而非「重试」。
      expect(find.widgetWithText(TextButton, '测试'), findsOneWidget);
      expect(find.text('连接成功，远端目录已就绪。'), findsNothing);
      // 表单值正确传入通道（url 仅 trim，尾斜杠保留——WebdavClient 内部再去）。
      expect(stub.lastConfig?.url, 'https://dav.example.com/dav/');
      expect(stub.lastConfig?.account, 'acc');
      expect(stub.lastPassword, 'pw');
    });

    testWidgets('500 → 错误可见且提供「重试」（`SYNC-07` 手动重试）',
        (WidgetTester tester) async {
      tall(tester);
      final _StubWebdavClient stub = _StubWebdavClient(
        toThrow: SyncException(SyncErrorKind.server, statusCode: 500),
      );
      await tester.pumpWidget(buildApp(using: stub));
      await tester.pumpAndSettle();
      await fillCredentials(tester, url: 'https://dav.example.com/dav/');

      await tester.tap(find.widgetWithText(TextButton, '测试'));
      await settleReal(tester, rounds: 60);

      expect(find.textContaining('服务端错误（500）'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);
    });

    testWidgets('测试连接成功 → 显示成功文案；默认目录随配置传入（①③）',
        (WidgetTester tester) async {
      tall(tester);
      // MKCOL 自动创建目录的请求语义在 `webdav_client_test.dart`（真 socket）
      // 覆盖；此处只验成功结果的呈现与配置传递。
      final _StubWebdavClient stub = _StubWebdavClient();
      await tester.pumpWidget(buildApp(using: stub));
      await tester.pumpAndSettle();
      await fillCredentials(tester, url: 'https://dav.example.com/dav/');

      await tester.tap(find.widgetWithText(TextButton, '测试'));
      await settleReal(tester, rounds: 60);

      expect(find.textContaining('连接成功，远端目录已就绪'), findsOneWidget);
      expect(stub.lastConfig?.dir, 'mreader', reason: '远端目录默认 mreader');
      expect(stub.lastPassword, 'pw');
    });
  });

  group('设置页入口接线（`SYNC-01` 配置入口）', () {
    late PerfPrefsStore perfPrefs;
    late SettingsStore settings;
    late ProviderStore aiStore;

    setUp(() async {
      perfPrefs = PerfPrefsStore(dir);
      settings = SettingsStore(dir);
      aiStore = ProviderStore(dir, AiKeyVault(FileSecureStore(directory: dir)));
      await perfPrefs.load();
      await settings.load();
      await aiStore.load();
    });

    testWidgets('传入 syncStore/syncClient → 「同步备份」组与入口行在场（未配置）',
        (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(
        host(
          GlassQualityTier.off,
          SettingsPage(
            perfPrefs: perfPrefs,
            settings: settings,
            aiStore: aiStore,
            aiClient: AiClient(),
            syncStore: store,
            syncClient: client,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('同步备份'), findsOneWidget);
      expect(find.text('WebDAV 同步'), findsOneWidget);
      expect(find.text('未配置'), findsOneWidget);
    });

    testWidgets('已配置 → 入口行显示「已配置」', (WidgetTester tester) async {
      tall(tester);
      await tester.runAsync(
        () => store.save(SyncConfig(url: 'https://x/dav/', account: 'a')),
      );
      await tester.pumpWidget(
        host(
          GlassQualityTier.off,
          SettingsPage(
            perfPrefs: perfPrefs,
            settings: settings,
            aiStore: aiStore,
            aiClient: AiClient(),
            syncStore: store,
            syncClient: client,
          ),
        ),
      );
      await settleReal(tester, rounds: 6);

      expect(find.text('同步备份'), findsOneWidget);
      expect(find.text('已配置'), findsOneWidget);
    });

    testWidgets('未传（可选依赖）→ 同步组整体隐藏（降级口径）', (WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(
        host(
          GlassQualityTier.off,
          SettingsPage(
            perfPrefs: perfPrefs,
            settings: settings,
            aiStore: aiStore,
            aiClient: AiClient(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('同步备份'), findsNothing);
      expect(find.text('WebDAV 同步'), findsNothing);
    });
  });
}
