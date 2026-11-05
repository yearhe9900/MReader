// 开发者选项：入口 + 子页开关（禁裸 Material Switch 的契约落点）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/ai_client.dart';
import 'package:mreader/ai/provider_store.dart';
import 'package:mreader/ai/secure_key_store.dart';
import 'package:mreader/platform/secure_store_io.dart';
import 'package:mreader/settings/developer_options.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/settings/settings_store.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';
import 'package:mreader/ui/mi_like_ui/mi_like_ui.dart' show MiSwitch;
import 'package:mreader/ui/settings_page.dart';

import '../test_config.dart';

Widget host(Widget home) => MaterialApp(
      home: GlassScopeProvider(
        config: glassTierConfigFor(GlassQualityTier.off),
        child: home,
      ),
    );

void main() {
  capTestTimeout();
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);
  tearDown(() => DeveloperOptions.pdfUseRustKernel = false);

  late Directory tempDir;
  late SettingsStore settings;
  late ProviderStore aiStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mreader_devopts_');
    settings = SettingsStore(tempDir);
    aiStore = ProviderStore(
      tempDir,
      AiKeyVault(FileSecureStore(directory: tempDir)),
    );
    await settings.load();
    await aiStore.load();
    DeveloperOptions.pdfUseRustKernel = false;
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget page() => SettingsPage(
        settings: settings,
        aiStore: aiStore,
        aiClient: AiClient(),
      );

  testWidgets('「我的」页有开发者选项入口；子页可切换 PDF 内核开关',
      (WidgetTester tester) async {
    await tester.pumpWidget(host(page()));
    await tester.pumpAndSettle();
    expect(find.text('开发者选项'), findsOneWidget);

    await tester.tap(find.text('开发者选项'));
    await tester.pumpAndSettle();
    expect(find.text('PDF 使用 Rust 内核'), findsOneWidget);
    expect(find.byType(MiSwitch), findsOneWidget);

    await tester.tap(find.text('PDF 使用 Rust 内核'));
    await tester.pumpAndSettle();
    expect(DeveloperOptions.pdfUseRustKernel, isTrue);
  });
}
