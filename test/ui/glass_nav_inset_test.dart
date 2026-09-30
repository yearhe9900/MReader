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
//
// ══════════════════════════════════════════════════════════════════════════════
// 2026-09-29 追加：`extendBody` 参数化（「全浮动头部」批）
// ══════════════════════════════════════════════════════════════════════════════
// 负责人「标题栏也参考图片，内容可以 edge to edge」+ 拍板「全浮动头部」后，
// `GlassNavScaffold` 把 `extendBody` 暴露为参数（**默认仍 `false`**，即上面
// 三条契约不变——多数页面的正文继续避让顶栏）；书架页显式传 `true`：
// 正文铺满全屏、滚动时从浮动玻璃头部下穿过，顶栏下内容透出磨砂模糊
// （`GlassScrollEdgeStyle.blur` = `UI-02` ② 的正式落地），首行保护改由页面
// 自己的 `padding.top` 承担（`shelfGridPadding`，见 `shelf_page_test`）。
// 下面两条锁「传 true 时正文确实从 y=0 起」（玻璃档 + 关档）。
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

  testWidgets('extendBody: true → 正文铺满全屏（edge-to-edge，书架浮动头部形态）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        GlassQualityTier.high,
        GlassNavScaffold(
          extendBody: true,
          appBar: const GlassTopBar(title: Text('书架')),
          body: _body(),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.byKey(kBodyMarker)).dy,
      0,
      reason: 'extendBody: true 时正文从 y=0 起、从顶栏下穿过'
          '（`UI-02` ② 磨砂模糊）；首行保护改由页面 padding.top 承担',
    );
  });

  testWidgets('关档 extendBody: true → Material Scaffold 同样穿顶栏', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        GlassQualityTier.off,
        GlassNavScaffold(
          extendBody: true,
          appBar: const GlassTopBar(title: Text('书架')),
          body: _body(),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.byKey(kBodyMarker)).dy,
      0,
      reason: '关档走 Material `Scaffold.extendBodyBehindAppBar`，语义与玻璃档一致',
    );
  });
}
