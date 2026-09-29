// `GlassNavScaffold` **顶栏避让**回归（2026-09-29）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 这个测试在防什么
// ══════════════════════════════════════════════════════════════════════════════
// 真机截图实证的 bug（批次① `06063c8` 引入、批次② `0991c43` 加了筛选栏后显形）：
// `GlassNavScaffold` 没传 `extendBody`，吃了玻璃库的默认值 `true` →
// `glass_scaffold.dart:487-489` 走 `Positioned.fill`，**正文铺满整屏、从 y=0 起、
// 完全不避让顶栏** → 书架筛选栏被顶进状态栏、网格首行封面被顶栏盖住。
//
// 库文档 `:153` / `:83` 声称会「automatically add a top spacer」，但 1.7.0 全文
// grep 只有三处文字、**零处实现**——以代码为准。修法 = 显式传 `extendBody: false`
// （走 `:491-494` 的 `top: topPad + appBarHeight`）。
//
// 断言口径：测试窗口的 `MediaQuery.padding.top` 默认为 0，故正文 top 应 = 顶栏
// `toolbarHeight`(44)；用 `>= 44` 而非 `== 44`，容忍宿主注入状态栏内边距的情形。
// ══════════════════════════════════════════════════════════════════════════════
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/settings/perf_prefs_store.dart';
import 'package:mreader/ui/glass_kit.dart';
import 'package:mreader/ui/glass_runtime.dart';
import 'package:mreader/ui/glass_scope.dart';

import '../test_config.dart';

/// 钉档宿主：`MaterialApp` + `GlassScopeProvider`（`config` 覆盖 = 测试钉档）。
Widget host(GlassQualityTier tier, Widget home) {
  return MaterialApp(
    home: GlassScopeProvider(
      config: glassTierConfigFor(tier),
      child: home,
    ),
  );
}

/// 正文标记：直接量它的 top 即可知道正文有没有避让顶栏。
const ValueKey<String> kBodyMarker = ValueKey<String>('body-marker');

Widget _body() =>
    const ColoredBox(key: kBodyMarker, color: Color(0xFFFF0000));

void main() {
  capTestTimeout(); // 30s 超时兜底（见 test/test_config.dart）。
  setUp(GlassRuntime.resetForTest);
  tearDown(GlassRuntime.resetForTest);

  testWidgets('玻璃档：正文必须在顶栏下方（extendBody: false 回归）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        GlassQualityTier.high,
        GlassNavScaffold(
          appBar: const GlassTopBar(title: Text('书架')),
          body: _body(),
        ),
      ),
    );

    final double top =
        tester.getTopLeft(find.byKey(kBodyMarker)).dy;
    expect(
      top,
      greaterThan(0),
      reason:
          '正文不得从 y=0 开始——那会把书架筛选栏顶进状态栏、'
          '网格首行封面被顶栏盖住（真机截图实证的 bug）',
    );
    expect(
      top,
      greaterThanOrEqualTo(44),
      reason: '正文 top 至少等于顶栏 toolbarHeight(44)（+ 状态栏内边距）',
    );
  });

  testWidgets('关档：Material Scaffold 同样避让顶栏（功能完整可用）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        GlassQualityTier.off,
        GlassNavScaffold(
          appBar: const GlassTopBar(title: Text('书架')),
          body: _body(),
        ),
      ),
    );

    final double top =
        tester.getTopLeft(find.byKey(kBodyMarker)).dy;
    expect(top, greaterThanOrEqualTo(44));
  });

  testWidgets('无顶栏时正文从顶部开始（不凭空多出留白）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        GlassQualityTier.high,
        GlassNavScaffold(body: _body()),
      ),
    );

    final double top =
        tester.getTopLeft(find.byKey(kBodyMarker)).dy;
    expect(
      top,
      0,
      reason: 'appBar == null 时库走 top: 0；本项目不得额外补留白',
    );
  });
}
